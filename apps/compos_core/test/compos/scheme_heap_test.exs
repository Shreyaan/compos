defmodule Compos.SchemeHeapTest do
  @moduledoc """
  Compos.Core.SchemeHeap: the heap bound on a process that evaluates Scheme.

  A Scheme loop that builds data without end used to take every byte of the
  machine. The bound kills that one process instead, names the limit to its
  caller, and leaves the serial lane available for the next job.
  """

  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Compos.Core.{Lane, SchemeHeap}

  setup do
    previous = Application.get_env(:compos_core, :scheme_heap_limit_mb)
    on_exit(fn -> Application.put_env(:compos_core, :scheme_heap_limit_mb, previous) end)
    :ok
  end

  defp with_limit(mb, fun) do
    Application.put_env(:compos_core, :scheme_heap_limit_mb, mb)
    fun.()
  end

  test "the bound reads as words and as spawn options" do
    with_limit(16, fn ->
      assert SchemeHeap.limit_mb() == 16
      assert SchemeHeap.limit_words() == div(16 * 1024 * 1024, 8)
      assert [{:max_heap_size, %{size: size, kill: true}}] = SchemeHeap.spawn_opts()
      assert size == SchemeHeap.limit_words()

      # the flag lands on a real process, so an evaluating process carries it
      task =
        Task.async(fn ->
          SchemeHeap.apply_to_self()
          Process.info(self(), :max_heap_size)
        end)

      assert {:max_heap_size, %{size: ^size, kill: true, error_logger: true}} =
               Task.await(task)
    end)
  end

  test "zero turns the bound off, so an operator can still run an unbounded job" do
    with_limit(0, fn ->
      assert SchemeHeap.limit_mb() == nil
      assert SchemeHeap.limit_words() == nil
      assert SchemeHeap.spawn_opts() == []
      assert SchemeHeap.apply_to_self() == :ok
    end)
  end

  test "a runaway job dies at the bound, names the limit, and the lane serves the next caller" do
    with_limit(8, fn ->
      lane = {:heap_test, System.unique_integer([:positive])}

      runaway = fn _from ->
        {:reply, Enum.reduce(1..50_000_000, [], fn i, acc -> [i | acc] end)}
      end

      log =
        capture_log(fn ->
          assert {:error, message} = Lane.run(lane, runaway, 30_000, "runaway")
          assert message =~ "runaway"
          assert message =~ "8 MB heap limit"
          send(self(), {:message, message})
        end)

      assert log =~ "8 MB heap limit"

      # the serial worker survived its job: the next caller still runs
      assert Lane.run(lane, fn _ -> {:reply, :alive} end, 5_000, "after") == :alive
    end)
  end
end
