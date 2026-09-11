defmodule Compos.Core.Desktop do
  @moduledoc """
  Desktop save/restore owns presentation only: frames, window trees, faces,
  and declared Scheme globals. Buffer processes checkpoint and restore their
  own state independently.
  """

  use GenServer

  require Logger

  alias Compos.Core.{Editor, Events, Session}

  @debounce 1_500

  # The desktop must never wait on the Session for long. The Session runs one
  # form at a time, so a slow shell command or agent turn parks every caller
  # behind it. The globals are small and change rarely, so a save that cannot
  # read them writes the last values it read.
  @globals_timeout 2_000

  # Putting the globals back is not on a keystroke path, so it waits as long
  # as a restore does.
  @install_timeout 30_000

  # How long to wait before asking a replacement Session for its attention
  # again. The new one loads the whole stdlib before it answers.
  @reseed_retry 1_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def path,
    do: Application.get_env(:compos_core, :desktop_path, Path.expand("~/.compos/desktop.etf"))

  @doc "Synchronous snapshot to disk (also used by tests)."
  def save_now, do: GenServer.call(__MODULE__, :save)

  @doc "Restore from disk over the current editor state."
  def restore_now, do: GenServer.call(__MODULE__, :restore, 30_000)

  # --- server ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    Events.subscribe_editor()
    send(self(), :watch_session)
    if Application.get_env(:compos_core, :desktop_autorestore, true), do: send(self(), :restore)
    {:ok, %{timer: nil, globals: [], session: nil, scheme_stale?: false}}
  end

  @impl true
  def handle_call(:save, _from, state) do
    {result, state} = do_save(state)
    {:reply, result, state}
  end

  def handle_call(:restore, _from, state) do
    {result, state} = do_restore(state)
    {:reply, result, state}
  end

  @impl true
  def handle_info({:editor_change, _}, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:noreply, %{state | timer: Process.send_after(self(), :flush, @debounce)}}
  end

  def handle_info(:flush, state) do
    {_result, state} = do_save(state)
    {:noreply, %{state | timer: nil}}
  end

  def handle_info(:restore, state) do
    {_result, state} = do_restore(state)
    {:noreply, state}
  end

  def handle_info(:watch_session, state),
    do: {:noreply, %{state | session: watch_session()}}

  def handle_info({:DOWN, ref, :process, _dead, reason}, %{session: {_watched, ref}} = state) do
    Logger.error(
      "desktop: the Session stopped (#{inspect(reason)}). Its replacement boots a new " <>
        "interpreter that holds the defvar defaults, so this process holds the only " <>
        "copy of the persisted globals until it takes them back."
    )

    send(self(), :reseed)
    {:noreply, %{state | session: nil, scheme_stale?: true}}
  end

  def handle_info(:reseed, state) do
    if is_nil(Process.whereis(Session)) do
      Process.send_after(self(), :reseed, @reseed_retry)
      {:noreply, state}
    else
      {:noreply, reseed(state)}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    do_save(state)
    :ok
  end

  # --- snapshot --------------------------------------------------------------

  # Presentation only. Each buffer owns its durable state and writes its own
  # checkpoint on a debounce after a change, so the desktop sweeps nothing.
  defp do_save(state) do
    # v2: every frame's layout, in frame-MRU order (head = most recent).
    # desktop_view is read-only (S15): saving must not run the render
    # walk, which writes viewport tops back into the tree.
    views = for fid <- Editor.frame_list(), do: {fid, Editor.desktop_view(fid)}

    frames =
      for {fid, view} <- views do
        %{id: fid, tree: serialize(view.tree), active_buffer: view.active_buffer}
      end

    {globals, state} = scheme_globals(state)

    desktop = %{
      version: 3,
      frames: frames,
      globals: globals
    }

    file = path()
    rotate_backup(file)
    Compos.Core.BufferStore.atomic_write(file, :erlang.term_to_binary(desktop))
    {:ok, state}
  rescue
    e ->
      Logger.warning("desktop save failed: #{Exception.message(e)}")
      {:error, state}
  end

  @backup_every 600
  @backup_keep 50

  # The desktop file is rewritten seconds after every change, so a bad state
  # overwrites the only copy before anyone notices. A dated copy at most every
  # ten minutes bounds a loss to that window; fifty copies bound the disk.
  defp rotate_backup(file) do
    if File.exists?(file) do
      dir = Path.join(Path.dirname(file), "desktop-backups")
      File.mkdir_p!(dir)
      backups = dir |> Path.join("desktop-*.etf") |> Path.wildcard() |> Enum.sort()

      fresh? =
        case List.last(backups) do
          nil ->
            false

          last ->
            case File.stat(last, time: :posix) do
              {:ok, %{mtime: t}} -> System.os_time(:second) - t < @backup_every
              _ -> false
            end
        end

      unless fresh? do
        stamp = Calendar.strftime(NaiveDateTime.utc_now(), "%Y%m%d-%H%M%S")
        File.cp(file, Path.join(dir, "desktop-" <> stamp <> ".etf"))
        Enum.each(Enum.drop(backups, -(@backup_keep - 1)), &File.rm/1)
      end
    end

    :ok
  rescue
    e ->
      Logger.warning("desktop backup rotation failed: #{Exception.message(e)}")
      :ok
  end

  # the leaf carries the per-window point and scroll state — saved so
  # each window reopens at its own spot, pinned if the reader pinned it
  defp serialize(%{type: :leaf, buffer: b} = leaf) do
    {:leaf, b, Map.get(leaf, :top, 0), Map.get(leaf, :point, 0), Map.get(leaf, :manual, false),
     Map.get(leaf, :ctop, 0), Map.get(leaf, :history, [])}
  end

  defp serialize(%{type: :split, dir: dir, children: [a, b]} = split),
    do: {:split, dir, Map.get(split, :ratio, 0.5), serialize(a), serialize(b)}

  defp serializable?(v) when is_function(v) or is_pid(v) or is_reference(v) or is_port(v),
    do: false

  defp serializable?(v) when is_list(v), do: Enum.all?(v, &serializable?/1)
  defp serializable?(v) when is_tuple(v), do: v |> Tuple.to_list() |> Enum.all?(&serializable?/1)

  defp serializable?(v) when is_map(v),
    do: Enum.all?(v, fn {k, val} -> serializable?(k) and serializable?(val) end)

  defp serializable?(_), do: true

  # Scheme state that must outlive a restart. The desktop carries the
  # values and reads none of them: priv/editor.scm says which globals ride
  # along (persist-global!) and hands them over as one list. Filtered the
  # same way locals are — a global holding a pid or a fun is dropped, not
  # written.
  #
  # The read happens only against the interpreter this process seeded. A
  # Session that died and came back answers every one of these with its
  # defvar default, and a save that believes that answer writes the empty
  # set over the good file: on 2026-09-11 that lost 35 groups, the group
  # graveyard, both connector catalogs and every history in one autosave.
  # Until the replacement takes the globals back, a save writes the set
  # this process already holds.
  defp scheme_globals(%{scheme_stale?: true} = state) do
    Logger.warning("desktop: the Scheme world has not taken the globals back; saved the last set")
    {state.globals, state}
  end

  defp scheme_globals(state) do
    if same_session?(state) do
      read_globals(state)
    else
      Logger.error("desktop: the Session changed under this process; saved the last globals")
      send(self(), :reseed)
      {state.globals, %{state | session: nil, scheme_stale?: true}}
    end
  end

  defp read_globals(state) do
    case Session.call_named("desktop-globals", [], nil, @globals_timeout) do
      {:ok, globals} when is_list(globals) ->
        globals = Enum.filter(globals, &serializable?/1)
        {globals, %{state | globals: globals}}

      _ ->
        {state.globals, state}
    end
  catch
    :exit, _ ->
      Logger.warning("desktop: Session busy, saved the previous globals")
      {state.globals, state}
  end

  # --- the Scheme world's copy ------------------------------------------------
  #
  # Every persisted global lives in a Scheme variable, and the Session owns
  # the interpreter those variables live in. A Session restart therefore
  # empties all of them at once while the frames, buffers and windows on the
  # Elixir side carry on unchanged. Watch the Session, put the values back
  # when a replacement boots, and hold every save to the last good set in
  # the meantime.

  defp watch_session do
    case Process.whereis(Session) do
      nil ->
        Process.send_after(self(), :watch_session, 200)
        nil

      pid ->
        {pid, Process.monitor(pid)}
    end
  end

  defp same_session?(%{session: {pid, _ref}}), do: Process.whereis(Session) == pid
  defp same_session?(_state), do: true

  defp reseed(state) do
    state = %{state | session: watch_session()}

    cond do
      not await_session() ->
        Process.send_after(self(), :reseed, @reseed_retry)
        state

      install_globals(state.globals) ->
        Logger.info(
          "desktop: put #{length(state.globals)} globals back into the new interpreter"
        )

        restore_window_runtime()
        %{state | scheme_stale?: false}

      true ->
        Process.send_after(self(), :reseed, @reseed_retry)
        state
    end
  end

  # A replacement Session registers its name before init/1 loads the stdlib,
  # and the published interpreter handle is still the dead one until that
  # load ends. Ask the process itself, which answers only once it is booted.
  defp await_session do
    GenServer.call(Session, :await_boot, 60_000)
    true
  catch
    :exit, _ -> false
  end

  defp install_globals([]), do: true

  defp install_globals(globals) do
    case Session.call_named("desktop-globals!", [globals], nil, @install_timeout) do
      {:ok, _} ->
        true

      other ->
        Logger.warning("desktop: the globals did not install: #{inspect(other)}")
        false
    end
  catch
    :exit, reason ->
      Logger.warning("desktop: the globals did not install: #{inspect(reason)}")
      false
  end

  # Mode setup, keymaps and overlays are Scheme too, so a new interpreter
  # leaves every on-screen buffer without them. This is the same rebuild a
  # restore runs, over the buffers a window shows.
  defp restore_window_runtime do
    Editor.list_windows_all()
    |> Enum.map(fn {_win, name, _frame} -> name end)
    |> Enum.uniq()
    |> Enum.each(&Compos.Core.restore_runtime/1)
  end

  # --- restore ---------------------------------------------------------------

  defp do_restore(state) do
    with {:ok, bin} <- File.read(path()),
         %{} = desktop <- :erlang.binary_to_term(bin) do
      # Hold the file's globals before anything else can fail. A save that
      # runs next writes what this process holds, so the values must be
      # here even when the install below never happens.
      state = %{state | globals: desktop[:globals] || []}

      restore_frames(desktop)

      # Runtime setup reads persisted policy. Group modelines, for example,
      # validate buffer membership against the durable group record table.
      # Restore globals before setup so valid IDs are not treated as dangling
      # and written back as empty buffer locals.
      #
      # An install that fails leaves the Scheme world empty, so mark it and
      # retry: a save must not copy that emptiness to disk.
      state = %{state | scheme_stale?: not install_globals(state.globals)}
      if state.scheme_stale?, do: Process.send_after(self(), :reseed, @reseed_retry)

      # Waking installs literal buffer state. Runtime-only mode machinery is
      # rebuilt only after the Editor call has returned, avoiding a
      # Session -> Editor deadlock during tree construction.
      restore_window_runtime()

      # Faces are not restored. themes.scm persists the theme NAME and
      # derives the faces at boot, so a theme edit applies on restart.
      # Replaying the saved face table put the previous session's colours
      # over the freshly derived theme.

      Session.message("Desktop restored")
      {:ok, state}
    else
      {:error, :enoent} -> {:ok, state}
      _ -> {:error, state}
    end
  rescue
    e ->
      Logger.warning("desktop restore failed: #{Exception.message(e)}")
      {:error, state}
  end

  # v2: recreate every saved frame and lay its tree back; reversed so the
  # MRU head attaches last and ends up last-active. A browser that connected
  # before restore ran gets its same-id frame overwritten and re-renders.
  # v1 (single :tree key): one frame, restored into the default.
  defp restore_frames(%{frames: frames}) do
    for %{id: fid, tree: tree, active_buffer: active} <- Enum.reverse(frames) do
      {:ok, ^fid} = Editor.attach_frame(fid)
      Editor.restore_tree(tree, active, fid)
    end
  end

  defp restore_frames(%{tree: tree} = desktop),
    do: Editor.restore_tree(tree, desktop[:active_buffer])

  defp restore_frames(_), do: :ok
end
