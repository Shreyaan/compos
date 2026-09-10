defmodule Compos.Core.BufferStore do
  @moduledoc """
  Durable buffer catalog.

  Buffer contents belong to the buffer checkpoint in `buffers/`; this process
  only indexes those checkpoints and keeps the cross-process MRU history. A
  buffer may therefore be present here without consuming a process.
  """

  use GenServer

  require Logger

  alias Compos.Core.{Buffer, Editor, Proc}

  @catalog_version 1

  # The catalog rows live in a public table, not in the process state: a
  # buffer list reads a row fact for every cell of every row, and a
  # hundred rows must not queue a thousand messages here.
  @table :compos_buffer_catalog

  # A local this big or smaller is indexed with its buffer's row. The
  # ones above it (a chat's block index, a list's row cache) stay in the
  # checkpoint, and a reader that wants one pays for the file.
  @local_index_bytes 1024

  # The facts a row read answers from the catalog. Every other key falls
  # through to the checkpoint.
  @fact_keys ~w(id path size modified read_only point mark buffer_version)a

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The catalog table."
  def table, do: @table

  def dir, do: Path.join(Compos.Core.home(), "buffers")
  def catalog_path, do: Path.join(dir(), "catalog.etf")
  def checkpoint_path(id), do: Path.join(dir(), id <> ".etf")

  def lookup(name), do: row(name)
  def lookup_id(id), do: row({:id, id})
  def load(name), do: GenServer.call(__MODULE__, {:load, name})
  def load_id(id), do: GenServer.call(__MODULE__, {:load_id, id})
  def known?(name), do: row(name) != nil

  # A row read never waits on this process. The table is made in `init`,
  # so a hot swap of this module into a running daemon finds none: the
  # read asks the process, exactly as it did before the table existed,
  # until a restart makes one.
  defp row(key) do
    case :ets.whereis(@table) do
      :undefined -> GenServer.call(__MODULE__, {:lookup, key})
      _ -> from_table(key)
    end
  end

  defp from_table(key) do
    case :ets.lookup(@table, key) do
      [{^key, meta}] -> meta
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  One row fact of a buffer, as `{:ok, value}`, or `:error` when the
  catalog holds no such fact.

  A buffer list draws a row per name it shows and asks each row for its
  path, its size, its state and a local or two. For a dormant buffer
  every one of those reads used to load the whole checkpoint file: the
  text, the locals and the overlays, to answer one small field.
  """
  def fact(name, key) when key in @fact_keys do
    case row(name) do
      %{^key => value} -> {:ok, value}
      _ -> :error
    end
  end

  def fact(_name, _key), do: :error

  @doc """
  One indexed buffer-local: `{:ok, VALUE}`, `:absent` when the buffer
  holds no such local, or `:error` when the catalog cannot say and the
  checkpoint must answer.
  """
  def local(name, key) do
    case row(name) do
      %{locals: locals, local_keys: keys} ->
        cond do
          Map.has_key?(locals, key) -> {:ok, Map.get(locals, key)}
          key in keys -> :error
          true -> :absent
        end

      _ ->
        :error
    end
  end

  @doc """
  Every buffer-local of a dormant buffer, but only when the catalog holds
  them all: a buffer with one local too big to index answers `:error`, and
  its checkpoint gives the complete map.
  """
  def locals(name) do
    case row(name) do
      %{locals: locals, local_keys: keys} when map_size(locals) == length(keys) -> {:ok, locals}
      _ -> :error
    end
  end

  @doc """
  The row facts of one checkpoint. `metadata/1` in `Compos.Core.Buffer`
  builds the same shape from a live buffer's state, so a checkpoint write
  and a boot scan index the same facts.
  """
  def facts(%{} = checkpoint) do
    locals = if is_map(checkpoint[:locals]), do: checkpoint[:locals], else: %{}

    %{
      path: checkpoint[:path],
      size: byte_size(checkpoint[:text] || ""),
      modified: checkpoint[:modified],
      read_only: checkpoint[:read_only],
      point: checkpoint[:point],
      mark: checkpoint[:mark],
      buffer_version: checkpoint[:buffer_version],
      locals: small_locals(locals),
      local_keys: Map.keys(locals)
    }
  end

  @doc "The locals small enough to index with their buffer's row."
  def small_locals(locals) do
    for {k, v} <- locals, :erlang.external_size(v) <= @local_index_bytes, into: %{}, do: {k, v}
  end

  def names, do: GenServer.call(__MODULE__, :names)
  def history, do: GenServer.call(__MODULE__, :history)
  def note(meta), do: GenServer.call(__MODULE__, {:note, meta})
  def touch(name), do: GenServer.cast(__MODULE__, {:touch, name})
  def forget(name), do: GenServer.call(__MODULE__, {:forget, name})
  def renamed(old, meta), do: GenServer.call(__MODULE__, {:renamed, old, meta})

  def idle_expired(name, id, generation),
    do: GenServer.cast(__MODULE__, {:idle_expired, name, id, generation})

  @impl true
  def init(_) do
    File.mkdir_p!(dir())
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    disk = scan_checkpoints()
    Enum.each(disk, fn {_name, meta} -> put_row(meta) end)

    history =
      case read_term(catalog_path()) do
        %{version: @catalog_version, history: h} when is_list(h) -> h
        _ -> []
      end
      |> Enum.filter(&Map.has_key?(disk, &1))

    {:ok,
     %{
       entries: disk,
       ids: Map.new(disk, fn {_name, meta} -> {meta.id, meta} end),
       history: history ++ (Map.keys(disk) -- history)
     }}
  end

  @impl true
  def handle_call({:lookup, {:id, id}}, _from, state), do: {:reply, state.ids[id], state}

  def handle_call({:lookup, name}, _from, state), do: {:reply, state.entries[name], state}

  def handle_call({:load, name}, _from, state) do
    value =
      case state.entries[name] do
        %{checkpoint: path} -> read_term(path)
        _ -> nil
      end

    {:reply, value, state}
  end

  def handle_call({:load_id, id}, _from, state) do
    value =
      case state.ids[id] do
        %{checkpoint: path} -> read_term(path)
        _ -> nil
      end

    {:reply, value, state}
  end

  def handle_call(:names, _from, state), do: {:reply, Map.keys(state.entries), state}
  def handle_call(:history, _from, state), do: {:reply, state.history, state}

  def handle_call({:note, meta}, _from, state) do
    put_row(meta)

    state = %{
      state
      | entries: Map.put(state.entries, meta.name, meta),
        ids: Map.put(state.ids, meta.id, meta)
    }

    persist_catalog(state)
    {:reply, :ok, state}
  end

  def handle_call({:forget, name}, _from, state) do
    case state.entries[name] do
      %{id: id} ->
        # A kill never erases. The checkpoint and the history log move to
        # the graveyard, and the burial line keeps the id -> name mapping
        # that recovery needs.
        entomb(id, name)

      _ ->
        :ok
    end

    drop_row(state.entries[name])

    state = %{
      state
      | entries: Map.delete(state.entries, name),
        ids:
          case state.entries[name] do
            %{id: id} -> Map.delete(state.ids, id)
            _ -> state.ids
          end,
        history: List.delete(state.history, name)
    }

    persist_catalog(state)
    {:reply, :ok, state}
  end

  def handle_call({:renamed, old, meta}, _from, state) do
    drop_row(state.entries[old])
    put_row(meta)
    entries = state.entries |> Map.delete(old) |> Map.put(meta.name, meta)
    history = Enum.map(state.history, &if(&1 == old, do: meta.name, else: &1))

    state = %{
      state
      | entries: entries,
        ids: Map.put(state.ids, meta.id, meta),
        history: Enum.uniq(history)
    }

    persist_catalog(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:touch, name}, %{history: [name | _]} = state), do: {:noreply, state}

  def handle_cast({:touch, name}, state) do
    history = Enum.take([name | List.delete(state.history, name)], 500)
    state = %{state | history: history}
    persist_catalog(state)
    {:noreply, state}
  end

  def handle_cast({:idle_expired, name, id, generation}, state) do
    if safe_to_evict?(name, id, generation) do
      # Never wait on a buffer from the catalog process: checkpointing calls
      # back here to publish its metadata. The worker preserves that ordering
      # and leaves the catalog free to receive the note.
      Task.start(fn ->
        case Registry.lookup(Compos.Core.BufferRegistry, name) do
          [{pid, _}] ->
            if Buffer.prepare_evict(name, generation),
              do: DynamicSupervisor.terminate_child(Compos.Core.BufferSupervisor, pid)

          [] ->
            :ok
        end
      end)
    end

    {:noreply, state}
  end

  defp safe_to_evict?(name, id, generation) do
    displayed =
      if Process.whereis(Editor),
        do: Enum.any?(Editor.list_windows_all(), fn {_win, b, _frame} -> b == name end),
        else: false

    active_process = Proc.running?(name)

    case Registry.lookup(Compos.Core.BufferRegistry, name) do
      [{_pid, _}] ->
        info = Buffer.eviction_info(name)
        agent = info.locals["agent-slug"] || info.locals["chat-agent"]
        pinned = info.locals["buffer-pinned"] not in [nil, false]
        active_agent = is_binary(agent) and Compos.Core.Agent.running?(agent)

        info.id == id and info.idle_gen == generation and not displayed and not active_process and
          not active_agent and not pinned

      _ ->
        false
    end
  catch
    :exit, _ -> false
  end

  def graveyard_dir, do: Path.join(dir(), "dead")

  def graveyard_log, do: Path.join(dir(), "graveyard.log")

  defp entomb(id, name) do
    src = checkpoint_path(id)

    moved_checkpoint =
      if File.exists?(src) do
        File.mkdir_p!(graveyard_dir())
        File.rename(src, Path.join(graveyard_dir(), id <> ".etf")) == :ok
      else
        false
      end

    moved_log = Compos.Core.BufferHistoryStore.entomb(id)

    if moved_checkpoint or moved_log do
      line = "#{DateTime.to_iso8601(DateTime.utc_now())} #{id} #{name}\n"
      File.write(graveyard_log(), line, [:append])
    end

    :ok
  rescue
    e ->
      Logger.warning("could not entomb #{name}: #{Exception.message(e)}")
      :ok
  end

  # The writers. Only this process writes the table, and it writes the row
  # before it answers the call that made it: a caller that noted a change
  # reads the change back.
  defp put_row(%{name: name, id: id} = meta) do
    :ets.insert(@table, {name, meta})
    :ets.insert(@table, {{:id, id}, meta})
    :ok
  end

  defp put_row(_), do: :ok

  defp drop_row(%{name: name, id: id}) do
    :ets.delete(@table, name)
    :ets.delete(@table, {:id, id})
    :ok
  end

  defp drop_row(_), do: :ok

  defp scan_checkpoints do
    Path.wildcard(Path.join(dir(), "*.etf"))
    |> Enum.reject(&(&1 == catalog_path()))
    |> Enum.reduce(%{}, fn path, acc ->
      case read_term(path) do
        %{version: 1, id: id, name: name} = checkpoint when is_binary(id) and is_binary(name) ->
          if String.starts_with?(name, " "),
            do: acc,
            else:
              Map.put(
                acc,
                name,
                Map.merge(
                  %{id: id, name: name, checkpoint: path},
                  facts(checkpoint)
                )
              )

        _ ->
          acc
      end
    end)
  end

  defp read_term(path) do
    with {:ok, bin} <- File.read(path) do
      :erlang.binary_to_term(bin)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp persist_catalog(state) do
    atomic_write(
      catalog_path(),
      :erlang.term_to_binary(%{version: @catalog_version, history: state.history})
    )
  rescue
    e -> Logger.warning("buffer catalog save failed: #{Exception.message(e)}")
  end

  def atomic_write(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))
    File.write!(tmp, bytes, [:binary])
    File.rename!(tmp, path)
    :ok
  end
end
