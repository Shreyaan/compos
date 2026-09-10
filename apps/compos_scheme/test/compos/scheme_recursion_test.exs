defmodule Compos.SchemeRecursionTest do
  @moduledoc """
  A function that calls itself with no base case stops as a Scheme error.

  Before this bound, such a function grew the heap until `max_heap_size`
  killed the process: seconds of work, several hundred megabytes of RSS,
  and a message that named the heap instead of the recursion. The editor is
  meant to run for weeks, so a mistake in one command must cost a message.
  """

  use ExUnit.Case, async: true

  alias Compos.Scheme

  defp interp(src) do
    {:ok, _, interp} = Scheme.eval_string(Scheme.new(), src)
    interp
  end

  test "a function that calls itself with no base case stops with an error" do
    interp = interp("(define (runaway n) (+ 1 (runaway n)))")

    assert {:error, message} = Scheme.eval_string(interp, "(runaway 1)")
    assert message =~ "recursion is too deep"
    assert message =~ "more than #{Scheme.Eval.max_recursion_depth()} nested calls"
  end

  # The closure has no name of its own, so the message names it by the
  # first form of its body. That is what finds it in a source file.
  test "the error names the body that recursed" do
    interp = interp("(define (runaway n) (+ 1 (runaway n)))")

    assert {:error, message} = Scheme.eval_string(interp, "(runaway 1)")
    assert message =~ "(+ 1 (runaway n))"
  end

  # The bound reads the process stack, which a tail call does not grow, so
  # iteration count cannot trip it. This is the test that would fail if the
  # bound ever became a counter of applications.
  test "a tail loop of three million iterations does not trip the bound" do
    interp = interp("(define (t n) (if (= n 0) 'done (t (- n 1))))")

    assert {:ok, {:sym, "done"}, _} = Scheme.eval_string(interp, "(t 3000000)")
  end

  # Deep is not the same as runaway: a non-tail walk over a long list must
  # still finish. 20,000 is far past anything the editor's own Scheme does.
  test "a non-tail recursion of twenty thousand frames finishes" do
    interp = interp("(define (sum n) (if (= n 0) 0 (+ n (sum (- n 1)))))")

    assert {:ok, 200_010_000, _} = Scheme.eval_string(interp, "(sum 20000)")
  end

  # The point of the bound is what a mistake costs. The old failure grew the
  # process to 134 million words before max_heap_size killed it; the guard
  # stops the same function at about 2.5 million (20 MB), in under 100 ms.
  test "the runaway costs a fraction of the heap the bound used to take" do
    interp = interp("(define (runaway n) (+ 1 (runaway n)))")

    {:ok, task} =
      Task.start_link(fn ->
        receive do
          {:go, from} ->
            Scheme.eval_string(interp, "(runaway 1)")
            {:heap_size, heap} = Process.info(self(), :heap_size)
            send(from, {:heap_words, heap})
        end
      end)

    send(task, {:go, self()})
    assert_receive {:heap_words, heap}, 30_000

    assert heap < 10_000_000, "the runaway kept #{heap} words of heap"
  end

  test "the bound can be turned off" do
    Application.put_env(:compos_scheme, :max_recursion_depth, 0)
    on_exit(fn -> Application.delete_env(:compos_scheme, :max_recursion_depth) end)

    assert Scheme.Eval.max_recursion_depth() == 0
    interp = interp("(define (sum n) (if (= n 0) 0 (+ n (sum (- n 1)))))")

    assert {:ok, 500_500, _} = Scheme.eval_string(interp, "(sum 1000)")
  end
end
