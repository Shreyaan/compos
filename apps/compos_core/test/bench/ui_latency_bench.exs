# The Phase 4 measurement of docs/SIMPLIFY-AUDIT.md: how long an eval on the
# :ui lane waits while a stub agent streams 1,500 chunks into its chat, and
# how long the same eval waits when it is queued on that chat's own buffer
# lane, which is what one serial Scheme world would impose on a keystroke.
# Not part of the suite (no _test suffix); run it by name:
#
#   cd apps/compos_core && mix test test/bench/ui_latency_bench.exs
#
defmodule Compos.UiLatencyBench do
  use Compos.Case, async: false
  alias Compos.Core.Session

  defp ev!(code, lane \\ :ui) do
    {:ok, out} = Session.eval(code, nil, 60_000, lane)
    out
  end

  defp series(n, lane) do
    for _ <- 1..n do
      t0 = System.monotonic_time(:microsecond)
      ev!("(+ 1 1)", lane)
      System.monotonic_time(:microsecond) - t0
    end
  end

  defp stats(xs) do
    s = Enum.sort(xs)
    at = fn q -> Enum.at(s, min(length(s) - 1, round(q * (length(s) - 1)))) end
    %{n: length(s), p50: at.(0.5), p95: at.(0.95), p99: at.(0.99), max: List.last(s)}
  end

  test "ui lane latency under an agent turn" do
    n = 1500
    chunk = ~S[(type chunk text "one line of streamed prose, forty chars.\n")]
    turn = "((" <> String.duplicate(chunk <> " ", n) <> "))"
    s = ev!(~s[(execute* "" '(backend "stub" script (#{turn})))]) |> String.trim("\"")
    buf = ev!(~s[(agent-buf "#{s}")]) |> String.trim("\"")
    idle = stats(series(300, :ui))
    t_turn = System.monotonic_time(:millisecond)
    Session.eval(~s[(agent-prompt! "#{s}" "go")], nil, 60_000, :ui)
    ui = stats(series(300, :ui))
    same = stats(series(60, {:buffer, buf}))
    turn_ms = System.monotonic_time(:millisecond) - t_turn
    lines = ev!(~s[(length (string-split (buffer-text "#{buf}") "\\n"))])
    IO.puts("""
    BENCH chunks=#{n} turn_wall_ms=#{turn_ms} chat_lines=#{lines}
    BENCH ui_idle #{inspect(idle)}
    BENCH ui_under_turn #{inspect(ui)}
    BENCH buffer_lane_under_turn #{inspect(same)}
    """)
  end
end
