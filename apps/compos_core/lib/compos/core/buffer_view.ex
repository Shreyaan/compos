defmodule Compos.Core.BufferView do
  @moduledoc """
  The buffer read model: one public ETS row per known buffer, live or
  dormant, holding what a reader needs and no process to ask for it.

  A live buffer publishes its own row and is its only writer. Every other
  process reads the row directly, so a render never queues behind a
  reparse, a checkpoint, or a save in the buffer that it draws. Before
  this, `Compos.Core.Editor` called each visible buffer from inside its own
  `handle_call`, which made one busy buffer stall every client.

  A dormant buffer has a row too: the facts of its last checkpoint (path,
  size, modified, read_only, point, mark, version), the locals small
  enough to index, and the names of the rest. `Compos.Core.BufferStore`
  writes those rows from the checkpoint directory at boot; a buffer that
  stops leaves one behind, written here on its `DOWN` from the live row it
  published. A reader therefore never asks which of the two it holds: a
  fact reads the same way for both, and only the text and a local too big
  to index reach the files of a dormant buffer.

  This process owns the TABLE and nothing else. It creates the table, and
  it settles the row of a buffer that dies. It runs no buffer code and
  holds no buffer state, so a buffer crash cannot take the read model with
  it.

  A live row holds the rope handle, not the flattened text. The rope is an
  immutable Rustler resource: every edit returns a new handle, so a reader
  may hold one and call the NIF while the writer edits on. The reader
  flattens the bytes in its OWN process, which moves that O(n) copy off the
  serial path. The writer publishes `bin` as well whenever it already holds
  the flattened text, and `text/1` takes it when it is there.

  A name with no row is not an error: it is a name nobody knows, or a live
  buffer in the moment after this process restarted. The reader falls back
  to the buffer process for the second case.
  """

  use GenServer

  alias Compos.Core.Buffer.Ref
  alias Compos.Core.{BufferStore, Rope}

  @table :compos_buffer_view

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The read model table."
  def table, do: @table

  @doc """
  Watch PID so its row settles when it goes. A buffer calls this once,
  from `init`, with its id, so a row another buffer took under the same
  name after a rename is never touched on its behalf.
  """
  def track(pid, name, id \\ nil), do: GenServer.cast(__MODULE__, {:track, pid, name, id})

  @doc "Drop NAME's row. The rename path calls this for the name it leaves."
  def forget(name) do
    case lookup(name) do
      [{^name, %{id: id}}] -> :ets.delete(@table, {:id, id})
      _ -> :ok
    end

    :ets.delete(@table, name)
    :ok
  rescue
    # the table is gone (see `lookup/1`) — there is no row to drop
    ArgumentError -> :ok
  end

  @doc "Publish VIEW under its own name, and under its id for `Ref` readers."
  def put(%{name: name, id: id} = view) do
    :ets.insert(@table, [{name, view}, {{:id, id}, name}])
    :ok
  rescue
    # A publish runs inside a buffer callback. If this process died and took
    # the table with it, the buffer must carry on and let its readers fall
    # back to calling it. The rows return when this process restarts.
    ArgumentError -> :ok
  end

  @doc """
  Publish a dormant VIEW only when its name has no row. The boot scan
  writes rows this way, so a checkpoint never writes over the row of a
  buffer that is already live.
  """
  def put_new(%{name: name, id: id} = view) do
    :ets.insert_new(@table, [{name, view}, {{:id, id}, name}])
  rescue
    ArgumentError -> false
  end

  @doc "Whether VIEW is the row of a live buffer. A row from before the flag holds a rope."
  def live?(view), do: Map.get(view, :live, Map.has_key?(view, :rope))

  @doc "VIEW for a name or a `Ref`. `:error` when the buffer has no row."
  def fetch(%Ref{id: id}) do
    case lookup({:id, id}) do
      [{_, name}] -> fetch(name)
      [] -> :error
    end
  end

  def fetch(name) when is_binary(name) do
    case lookup(name) do
      [{^name, view}] -> {:ok, view}
      [] -> :error
    end
  end

  def fetch(_), do: :error

  # A read against a table that does not exist raises. That happens only
  # between this process dying and its supervisor restarting it, and the
  # honest answer in that window is "no row", not a crash in the reader.
  defp lookup(key) do
    :ets.lookup(@table, key)
  rescue
    ArgumentError -> []
  end

  @doc "Whether NAME has a row, live or dormant, without copying it."
  def has_row?(name) when is_binary(name) do
    :ets.select(@table, [{{name, :_}, [], [true]}]) != []
  rescue
    ArgumentError -> false
  end

  def has_row?(_), do: false

  @doc "The names of every dormant row."
  def dormant_names do
    :ets.select(@table, [{{:"$1", %{live: false}}, [{:is_binary, :"$1"}], [:"$1"]}])
  rescue
    ArgumentError -> []
  end

  @doc "Project several fields and locals from one published row without copying unrelated state."
  def project(name, fields, keys) when is_binary(name) do
    value = fn map, key ->
      {:andalso, {:is_map_key, key, map}, {:map_get, key, map}}
    end

    values =
      Enum.map(fields, &value.(:"$1", &1)) ++
        Enum.map(keys, &value.({:map_get, :locals, :"$1"}, &1))

    case :ets.select(@table, [{{name, :"$1"}, [], [values]}]) do
      [values] when is_list(values) -> {:ok, values}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc "One field of a buffer's view, or nil when it has no row."
  def get(name, key) do
    case field(name, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  @doc """
  One field of a buffer's view, as `{:ok, value}`, or `:error` when the
  buffer has no row or the row lacks the key.

  The match spec projects the field inside ETS, so the caller copies that
  field and nothing else. `fetch/1` copies the whole row: every local,
  every overlay range, every fold. A read of one small local from a chat
  with forty thousand overlay ranges copied all of them, on every delta
  the stream sent, and one lane passed its heap limit that way.
  """
  def field(%Ref{id: id}, key) do
    case lookup({:id, id}) do
      [{_, name}] -> field(name, key)
      [] -> :error
    end
  end

  def field(name, key) when is_binary(name) and is_atom(key) do
    # the guard keeps a missing KEY out of the body: a body that raises
    # answers the atom EXIT, not a failed match
    spec = [{{name, :"$1"}, [{:is_map_key, key, :"$1"}], [{:map_get, key, :"$1"}]}]

    case :ets.select(@table, spec) do
      [value] -> {:ok, value}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  def field(_, _), do: :error

  @doc """
  One key of a buffer's `locals` map, projected inside ETS: a read of one
  small local from a buffer whose locals map holds a large value under
  another key (a chat's block index, a list-mode's row cache) must not
  copy that other value to find this one.

  `{:ok, VALUE}` when the row holds the local, `:absent` when it has a
  row and no such local, `:unindexed` when a dormant row names the local
  but holds it in the checkpoint (too big to index), `:error` when it has
  no row. The caller needs the misses apart: a live row is the whole
  truth about its buffer, so an absent key there is nil and no other
  store may answer for it.
  """
  def local(%Ref{id: id}, key) do
    case lookup({:id, id}) do
      [{_, name}] -> local(name, key)
      [] -> :error
    end
  end

  def local(name, key) when is_binary(name) do
    spec = [
      {{name, :"$1"},
       [
         {:andalso, {:is_map_key, :locals, :"$1"}, {:is_map_key, key, {:map_get, :locals, :"$1"}}}
       ], [{:map_get, key, {:map_get, :locals, :"$1"}}]}
    ]

    case :ets.select(@table, spec) do
      [value] ->
        {:ok, value}

      [] ->
        case field(name, :local_keys) do
          {:ok, keys} -> if key in keys, do: :unindexed, else: :absent
          :error -> if has_row?(name), do: :absent, else: :error
        end
    end
  rescue
    ArgumentError -> :error
  end

  def local(_, _), do: :error

  @doc """
  The buffer text. The writer's flattened copy when it published one,
  otherwise flattened here, in the calling process.
  """
  def text(%{bin: bin}) when is_binary(bin), do: bin
  def text(%{rope: rope}), do: Rope.to_binary(rope)

  @doc """
  Every tag's overlay ranges, as one list.

  The row holds the per-tag map, because that is what the buffer already
  has. Flattening it belongs to the reader: an edit adjusts every range,
  so a writer that flattened would pay per keystroke for a shape only a
  render wants.
  """
  def overlays(%{overlays: by_tag}), do: by_tag |> Map.values() |> Enum.concat()

  @doc "Every tag's folded lines, as one sorted list."
  def hidden(%{hidden: by_tag}), do: by_tag |> Map.values() |> Enum.concat() |> Enum.sort()

  @doc """
  The render payload for one window, or nil when the buffer has no live
  row: a dormant buffer draws empty rather than waking for a render.

  Same shape as `Buffer.render_snapshot/2`, computed from the row. The
  geometry is the WINDOW's: a stored per-window point wins over the buffer
  point, and it is clamped on read because undo swaps a whole rope under
  stored positions.
  """
  def snapshot(name, win_id \\ nil) do
    case fetch(name) do
      {:ok, view} -> if live?(view), do: snapshot_of(view, win_id), else: nil
      :error -> nil
    end
  end

  @doc "The render payload for a view already in hand."
  def snapshot_of(view, win_id) do
    {point, mark} =
      case win_id && view.win_points[win_id] do
        %{point: p, mark: m} -> {clamp(p, view.size), m && clamp(m, view.size)}
        _ -> {view.point, view.mark}
      end

    cursor_line = Rope.byte_to_line(view.rope, point)

    %{
      text: text(view),
      rope: view.rope,
      fontification: Map.get(view, :fontification, []),
      point: point,
      mark: mark,
      version: view.version,
      modified: view.modified,
      locals: view.locals,
      overlays: overlays(view),
      overlay_gen: view.overlay_gen,
      hidden: hidden(view),
      # A hot-loaded daemon can still hold rows published under the first
      # display-range name. Preserve that narrowing until the owner republishes.
      narrow_range: Map.get(view, :narrow_range, Map.get(view, :display_range)),
      path: view.path,
      read_only: view.read_only,
      total_lines: Rope.line_count(view.rope),
      cursor_line: cursor_line,
      line: cursor_line + 1,
      col: point - Rope.line_to_byte(view.rope, cursor_line)
    }
  end

  defp clamp(pos, size), do: pos |> max(0) |> min(size)

  # --- server ----------------------------------------------------------------

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    # A restart starts with an empty table and an empty watch list, and a
    # buffer only publishes when something about it changes. Adopt every live
    # buffer now: ask it to republish, and watch it again. Otherwise the model
    # heals one edit at a time, and the buffers that died meanwhile leave rows
    # nobody deletes. The dormant rows come back from the checkpoint scan.
    watched =
      Compos.Core.BufferRegistry
      |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.reduce(%{}, fn {key, pid}, acc ->
        send(pid, :republish_view)

        {name, id} =
          case {key, Map.get(acc, pid)} do
            {name, nil} when is_binary(name) -> {name, nil}
            {{:id, id}, nil} -> {nil, id}
            {name, {_, id}} when is_binary(name) -> {name, id}
            {{:id, id}, {name, _}} -> {name, id}
          end

        unless Map.has_key?(acc, pid), do: Process.monitor(pid)
        Map.put(acc, pid, {name, id})
      end)

    send(self(), :reindex)
    {:ok, watched}
  end

  @impl true
  def handle_cast({:track, pid, name, id}, watched) do
    if Map.has_key?(watched, pid) do
      {:noreply, watched}
    else
      Process.monitor(pid)
      {:noreply, Map.put(watched, pid, {name, id})}
    end
  end

  @impl true
  def handle_info(:reindex, watched) do
    # At a cold boot the store is not up yet; its own init writes the rows.
    if Process.whereis(BufferStore), do: BufferStore.reindex()
    {:noreply, watched}
  end

  def handle_info({:DOWN, _mref, :process, pid, _reason}, watched) do
    {tracked, watched} = Map.pop(watched, pid)

    case tracked do
      {name, id} when is_binary(name) -> settle(name, id)
      _ -> :ok
    end

    {:noreply, watched}
  end

  def handle_info(_, watched), do: {:noreply, watched}

  # A buffer stopped. Its live row becomes the dormant row of its last
  # checkpoint, from the row's own facts when the checkpoint holds them
  # and from the file when the buffer died with an unwritten change. A
  # killed buffer (`discard`) and a buffer that keeps no checkpoint leave
  # no row. A rename moved the row under a new name while we still hold
  # the old one, so the row is settled by the name it claims and only
  # when it carries the dead buffer's id.
  defp settle(name, id) do
    case lookup(name) do
      [{^name, %{id: row_id} = view}] when id in [nil, row_id] ->
        cond do
          not live?(view) ->
            :ok

          Map.get(view, :discard, false) or not Map.get(view, :persistent, true) ->
            forget(name)

          true ->
            case BufferStore.row_of_view(view) do
              nil -> forget(name)
              row -> put(row)
            end
        end

      _ ->
        :ok
    end
  end
end
