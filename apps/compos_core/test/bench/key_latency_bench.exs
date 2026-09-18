# Phase 3 step 2 measurement: how long one key takes end to end through
# KeyDispatch.handle_key/1, a bound motion key and a prefix key. Not part
# of the suite (no _test suffix); run it by name:
#   cd apps/compos_core && mix test test/bench/key_latency_bench.exs
defmodule Compos.KeyLatencyBench do
  use Compos.Case, async: false
  alias Compos.Core.{KeyDispatch, Session}

  defp series(n, key) do
    for _ <- 1..n do
      t0 = System.monotonic_time(:microsecond)
      KeyDispatch.handle_key(key)
      System.monotonic_time(:microsecond) - t0
    end
  end

  defp stats(xs) do
    s = Enum.sort(xs)
    at = fn q -> Enum.at(s, min(length(s) - 1, round(q * (length(s) - 1)))) end
    %{n: length(s), p50: at.(0.5), p95: at.(0.95), p99: at.(0.99), max: List.last(s)}
  end

  test "one key, measured" do
    {:ok, _} =
      Session.eval(
        ~s{(begin (buffer-create "zz-key-bench") (buffer-append! "zz-key-bench" (string-join (map (lambda (i) "aaaaaaaaaa") (iota 200)) "")) (switch-to-buffer! "zz-key-bench") (goto-char! 0) #t)}
      )

    series(50, "C-f")
    forward = stats(series(500, "C-f"))
    prefix = stats(Enum.map(1..250, fn _ -> hd(series(1, "C-x")) + hd(series(1, "C-g")) end))
    IO.puts("\nkey latency us: C-f #{inspect(forward)}\n                C-x then C-g (sum) #{inspect(prefix)}")
    assert forward.p50 < 50_000
  end
end
