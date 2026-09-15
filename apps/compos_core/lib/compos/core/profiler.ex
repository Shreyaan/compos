defmodule Compos.Core.Profiler do
  @moduledoc """
  One command, measured.

  `M-x profile` arms the editor. The next command runs with the BEAM's
  `call_time` tracer set over every loaded `Compos.*` module, so the
  profile says which function spent the time, how often it ran, which
  processes did the work, and what the VM paid in reductions, garbage
  and memory.

  This module is mechanism. `priv/packages/profile.scm` owns the policy:
  when to arm, what the report says, and where it shows.

  Tracing is not free. A traced command runs slower than the same command
  untraced, so read the shares before the wall clock.

  The before snapshot lives in one public ETS table that a small holder
  process owns, the way `SysMon` keeps its previous sample: a lane worker
  that dies must not take the table with it. That holder is also the
  tracer. The tracer is the one process a trace leaves out, and the
  Scheme session is the process the profile is about, so the tracer has
  to be somebody else. A `call_time` pattern sends no trace messages; the
  holder drops anything that arrives anyway.
  """

  alias Compos.Core.SysMon

  @table :compos_profiler
  @holder :compos_profiler_holder

  # the editor's own code. Measuring is not the command's work, so the
  # profiler stays out of its own profile.
  @prefixes ["Elixir.Compos."]
  @deny [__MODULE__]

  # a profile names the functions that spent time; the long tail is noise
  @top_functions 300
  @top_processes 40

  @doc """
  Arm the tracer and take the before snapshot.

  PREFIXES names the modules to cover by the start of their full atom
  name. Arming twice is safe: the first arming is dropped.
  """
  def start(prefixes \\ @prefixes)

  def start([]), do: start(@prefixes)

  def start(prefixes) when is_list(prefixes) do
    cancel()
    mods = modules(prefixes)
    tracer = tracer()
    put(:mods, mods)
    put(:procs, process_snapshot())
    put(:vm, vm_counters())
    put(:at_ms, System.os_time(:millisecond))

    # setting the pattern zeroes the counters; nothing counts until the
    # processes carry the call flag, so the flag goes on last
    Enum.each(mods, fn m -> :erlang.trace_pattern({m, :_, :_}, true, [:local, :call_time]) end)

    put(:t0, System.monotonic_time(:microsecond))
    :erlang.trace(:all, true, [:call, {:tracer, tracer}])
    :ok
  end

  @doc "True while a profile is armed."
  def armed?, do: is_list(get(:mods))

  @doc """
  Disarm and answer one profile as a Scheme plist.

  Answers `false` when nothing was armed.
  """
  def stop do
    t1 = System.monotonic_time(:microsecond)
    :erlang.trace(:all, false, [:call])
    mods = get(:mods)

    if is_list(mods) do
      t0 = get(:t0) || t1
      before = get(:procs) || %{}
      vm0 = get(:vm) || vm_counters()
      at_ms = get(:at_ms) || System.os_time(:millisecond)

      functions = Enum.flat_map(mods, &function_rows/1)
      untrace(mods)
      procs = process_rows(before)
      clear()

      report(%{
        wall_us: t1 - t0,
        at_ms: at_ms,
        modules: length(mods),
        functions: functions,
        processes: procs,
        vm0: vm0,
        vm1: vm_counters()
      })
    else
      false
    end
  end

  @doc "Disarm and forget the snapshot. True when a profile was armed."
  def cancel do
    :erlang.trace(:all, false, [:call])
    mods = get(:mods)
    untrace(mods || [])
    clear()
    is_list(mods)
  end

  # --- the report --------------------------------------------------------------

  defp report(r) do
    traced_us = Enum.reduce(r.functions, 0, fn f, acc -> acc + f.us end)
    calls = Enum.reduce(r.functions, 0, fn f, acc -> acc + f.calls end)
    hot = r.functions |> Enum.sort_by(fn f -> -f.us end) |> Enum.take(@top_functions)

    SysMon.to_plist(%{
      wall_us: r.wall_us,
      at_ms: r.at_ms,
      traced_us: traced_us,
      calls: calls,
      modules: r.modules,
      functions_seen: length(r.functions),
      functions: hot,
      processes: r.processes,
      reductions: r.vm1.reductions - r.vm0.reductions,
      gcs: r.vm1.gcs - r.vm0.gcs,
      gc_words: r.vm1.gc_words - r.vm0.gc_words,
      memory: r.vm1.memory - r.vm0.memory,
      memory_processes: r.vm1.processes - r.vm0.processes,
      memory_binary: r.vm1.binary - r.vm0.binary
    })
  end

  # --- the functions -----------------------------------------------------------

  defp modules(prefixes) do
    :code.all_loaded()
    |> Enum.map(fn {m, _} -> m end)
    |> Enum.reject(fn m -> m in @deny end)
    |> Enum.filter(fn m ->
      name = Atom.to_string(m)
      Enum.any?(prefixes, fn p -> String.starts_with?(name, p) end)
    end)
  end

  defp untrace(mods) do
    Enum.each(mods, fn m -> :erlang.trace_pattern({m, :_, :_}, false, [:local, :call_time]) end)
  end

  defp function_rows(m) do
    label = inspect(m)

    Enum.reduce(functions(m), [], fn {f, a}, acc ->
      case call_time({m, f, a}) do
        {0, _} -> acc
        {count, us} -> [%{module: label, function: "#{f}/#{a}", calls: count, us: us} | acc]
      end
    end)
  end

  defp functions(m) do
    m.module_info(:functions)
  rescue
    _ -> []
  end

  # call_time counts per traced process: one function, one row per process
  defp call_time(mfa) do
    case :erlang.trace_info(mfa, :call_time) do
      {:call_time, rows} when is_list(rows) ->
        Enum.reduce(rows, {0, 0}, fn {_pid, count, s, us}, {c, t} ->
          {c + count, t + s * 1_000_000 + us}
        end)

      _ ->
        {0, 0}
    end
  end

  # --- the processes -----------------------------------------------------------

  defp process_snapshot do
    Enum.reduce(Process.list(), %{}, fn pid, acc ->
      case Process.info(pid, [:reductions, :memory]) do
        [{:reductions, r}, {:memory, m}] -> Map.put(acc, pid, {r, m})
        _ -> acc
      end
    end)
  end

  # a process the command never woke made no reductions and is left out;
  # a process born during the command counts everything it did
  defp process_rows(before) do
    Process.list()
    |> Enum.map(fn pid -> process_row(pid, before) end)
    |> Enum.reject(fn row -> row == nil end)
    |> Enum.sort_by(fn row -> -row.reductions end)
    |> Enum.take(@top_processes)
  end

  defp process_row(pid, before) do
    case Process.info(pid, [:reductions, :memory, :registered_name, :initial_call]) do
      info when is_list(info) ->
        {r0, m0} = Map.get(before, pid, {0, 0})
        reductions = max(info[:reductions] - r0, 0)

        if reductions == 0 do
          nil
        else
          %{
            name: process_name(pid, info),
            pid: pid |> :erlang.pid_to_list() |> to_string(),
            reductions: reductions,
            memory: info[:memory] - m0
          }
        end

      _ ->
        nil
    end
  end

  defp process_name(pid, info) do
    case info[:registered_name] do
      name when is_atom(name) and name != nil -> inspect(name)
      _ -> initial_call(pid, info[:initial_call])
    end
  end

  # proc_lib processes (GenServer, Task, Supervisor) hide their real entry
  # point behind proc_lib:init_p; the translation reads the dictionary
  defp initial_call(pid, {:proc_lib, :init_p, _}) do
    case :proc_lib.translate_initial_call(pid) do
      {m, f, a} -> "#{inspect(m)}.#{f}/#{a}"
      _ -> "?"
    end
  rescue
    _ -> "?"
  end

  defp initial_call(_pid, {m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
  defp initial_call(_pid, _), do: "?"

  defp vm_counters do
    {reds, _} = :erlang.statistics(:reductions)
    {gcs, gc_words, _} = :erlang.statistics(:garbage_collection)
    mem = :erlang.memory()

    %{
      reductions: reds,
      gcs: gcs,
      gc_words: gc_words,
      memory: mem[:total],
      processes: mem[:processes],
      binary: mem[:binary]
    }
  end

  # --- the snapshot ------------------------------------------------------------

  defp get(key) do
    case :ets.lookup(table(), key) do
      [{^key, value}] -> value
      _ -> nil
    end
  end

  defp put(key, value), do: :ets.insert(table(), {key, value})

  defp clear, do: :ets.delete_all_objects(table())

  # the table lives in a holder process that only waits; a second caller
  # that races the first finds the table on its retry
  defp table do
    case :ets.whereis(@table) do
      :undefined ->
        start_holder()
        table()

      tid ->
        tid
    end
  end

  defp tracer do
    table()

    case Process.whereis(@holder) do
      pid when is_pid(pid) -> pid
      _ -> self()
    end
  end

  defp start_holder do
    parent = self()

    pid =
      spawn(fn ->
        try do
          :ets.new(@table, [:named_table, :public, :set])
          Process.register(self(), @holder)
          send(parent, {:profiler_table, :ok})
          hold()
        rescue
          _ -> send(parent, {:profiler_table, :exists})
        end
      end)

    receive do
      {:profiler_table, _} -> :ok
    after
      1_000 -> Process.exit(pid, :kill)
    end
  end

  # the table dies with the holder; the holder only sleeps, and drops the
  # trace messages a future flag might send it
  defp hold do
    receive do
      :stop -> :ok
      _ -> hold()
    end
  end
end
