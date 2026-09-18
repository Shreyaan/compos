# Measurement only: what the mark of one frame GC sweep costs after boot
# and a workload, against the mark it replaced (copy every row out of
# ETS), and whether both find the same live frames.
#   cd apps/compos_core && MIX_ENV=test mix test test/bench/gc_sweep_bench.exs
defmodule Compos.GcSweepBench do
  use Compos.Case, async: false
  alias Compos.Core.{Session, Editor, Buffer}
  alias Compos.Scheme.Env

  defp us(fun) do
    t0 = System.monotonic_time(:microsecond)
    r = fun.()
    {System.monotonic_time(:microsecond) - t0, r}
  end

  defp roots do
    [
      :ets.tab2list(Compos.Core.SchemeAPI.commands_table()),
      :ets.tab2list(:compos_escaped_closures),
      Editor.all_minibuffers(),
      Enum.map(Compos.Core.list_buffers(), fn n ->
        if Buffer.exists?(n), do: Buffer.locals(n), else: %{}
      end)
    ]
  end

  # the reference mark (the mark before 2026-09-19): copy every row out
  # of ETS, then walk the values
  defp snapshot(%Env{tid: tid, local: local}) do
    shared =
      :ets.tab2list(tid)
      |> Enum.reduce(%{}, fn
        {{:frame, ref}, parent}, acc -> Map.update(acc, ref, {%{}, parent}, fn {vars, _} -> {vars, parent} end)
        {{:var, ref, name}, val}, acc -> Map.update(acc, ref, {%{name => val}, :unknown}, fn {vars, p} -> {Map.put(vars, name, val), p} end)
        _, acc -> acc
      end)
      |> Map.new(fn {ref, {vars, parent}} -> {ref, {vars, parent, :ets}} end)

    Enum.reduce(local, shared, fn {ref, {vars, parent}}, acc -> Map.put(acc, ref, {vars, parent, :local}) end)
  end

  defp mark_now(store, global, roots) do
    frames = snapshot(store)
    work = Enum.reduce(roots, [global], &Env.closure_refs/2)
    {frames, mark(frames, work, MapSet.new())}
  end

  defp mark(_f, [], seen), do: seen

  defp mark(f, [r | rest], seen) do
    if MapSet.member?(seen, r) do
      mark(f, rest, seen)
    else
      case Map.fetch(f, r) do
        :error ->
          mark(f, rest, MapSet.put(seen, r))

        {:ok, {vars, parent, _}} ->
          w = if parent in [nil, :unknown], do: rest, else: [parent | rest]
          w = Enum.reduce(vars, w, fn {_n, v}, a -> Env.closure_refs(v, a) end)
          mark(f, w, MapSet.put(seen, r))
      end
    end
  end

  # the mark the GC runs now: Env.edges/1, bodies never copied
  defp mark_edges(store, global, roots) do
    {graph, _shared} = Env.edges(store)
    work = Enum.reduce(roots, [global], &Env.closure_refs/2)
    {graph, walk(graph, work, MapSet.new())}
  end

  defp walk(_e, [], seen), do: seen

  defp walk(e, [r | rest], seen) do
    if MapSet.member?(seen, r),
      do: walk(e, rest, seen),
      else: walk(e, Map.get(e, r, []) ++ rest, MapSet.put(seen, r))
  end

  test "one sweep, measured" do
    {:ok, _} =
      Session.eval(~s{(begin
        (for-each
          (lambda (i)
            (let ((b (string-append "zz-gc-bench-" (number->string i))))
              (buffer-create b)
              (buffer-append! b (string-join (map (lambda (j) (number->string j)) (iota 300)) " "))))
          (iota 40))
        (for-each (lambda (i) (map (lambda (x) (* x x)) (iota 20))) (iota 2000))
        #t)})

    interp = Session.interp()
    store = interp.store
    rs = roots()
    frames_n = Env.frame_count(store)
    words = :ets.info(store.tid, :memory)
    rows = :ets.info(store.tid, :size)

    med = fn xs -> Enum.at(Enum.sort(xs), div(length(xs), 2)) end

    runs =
      for _ <- 1..15 do
        :erlang.garbage_collect()
        {a, {_, ln}} = us(fn -> mark_now(store, interp.global, rs) end)
        :erlang.garbage_collect()
        {b, {_, le}} = us(fn -> mark_edges(store, interp.global, rs) end)
        :erlang.garbage_collect()
        {c, _} = us(fn -> snapshot(store) end)
        {a, b, c, ln, le}
      end

    t_now = med.(Enum.map(runs, &elem(&1, 0)))
    t_edges = med.(Enum.map(runs, &elem(&1, 1)))
    t_edges2 = Enum.max(Enum.map(runs, &elem(&1, 1)))
    t_snap = med.(Enum.map(runs, &elem(&1, 2)))
    {_, _, _, live_now, live_edges} = List.last(runs)
    t_roots = 0
    IO.puts("now max #{div(Enum.max(Enum.map(runs, &elem(&1, 0))), 1000)} ms")

    same = MapSet.equal?(live_now, live_edges)
    diff = MapSet.size(MapSet.symmetric_difference(live_now, live_edges))

    IO.puts("""

    store: #{frames_n} frames, #{rows} rows, #{div(words * 8, 1_048_576)} MB
    roots collect: #{div(t_roots, 1000)} ms
    snapshot alone: median #{div(t_snap, 1000)} ms
    mark now (snapshot + walk): median #{div(t_now, 1000)} ms, live #{MapSet.size(live_now)}
    mark by edges: median #{div(t_edges, 1000)} ms, max #{div(t_edges2, 1000)} ms, live #{MapSet.size(live_edges)}
    same live set: #{same} (symmetric difference #{diff})
    """)

    assert same
  end
end
