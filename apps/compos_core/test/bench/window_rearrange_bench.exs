# Phase 2 window design measurement: how long one window rearrangement
# takes, p50 over 30 runs, through the same Scheme entry points the
# commands use. Not part of the suite (no _test suffix); run it by name:
#   cd apps/compos_core && mix test test/bench/window_rearrange_bench.exs
defmodule Compos.WindowRearrangeBench do
  use Compos.Case, async: false
  alias Compos.Core.Session

  @runs 30

  defp ev!(code) do
    case Session.eval(code) do
      {:ok, v} -> String.trim(v, "\"")
      other -> flunk("eval failed: #{inspect(other)}\n#{code}")
    end
  end

  # the p50 of RUNS evaluations of the CODE pair A then B, each timed alone
  defp series(a, b) do
    xs =
      for i <- 1..@runs do
        code = if rem(i, 2) == 0, do: a, else: b
        t0 = System.monotonic_time(:microsecond)
        ev!(code)
        System.monotonic_time(:microsecond) - t0
      end

    s = Enum.sort(xs)
    %{p50: Enum.at(s, div(@runs, 2)), max: List.last(s)}
  end

  test "window rearrangement, measured" do
    dir = Path.join(System.tmp_dir!(), "zz-rearrange-bench")
    File.mkdir_p!(dir)
    for n <- ["a.txt", "b.txt"], do: File.write!(Path.join(dir, n), String.duplicate("line\n", 200))

    ev!("""
    (begin
      (customize-set! 'autolayout-mode #f)
      (layout-target-set! #f)
      (for-each (lambda (b) (buffer-create b) (buffer-append! b "text\\n"))
                (list "zz-rb-a1" "zz-rb-a2" "zz-rb-b1" "zz-rb-b2"))
      (delete-other-windows!)
      (switch-to-buffer! "zz-rb-a1")
      (group-create-and-enter! "zz-rb-ga" (list "zz-rb-a1" "zz-rb-a2") #f)
      (group-create-and-enter! "zz-rb-gb" (list "zz-rb-b1" "zz-rb-b2") #f)
      (delete-other-windows!)
      (split-window! 'h 0.5)
      #t)
    """)

    ga = ev!(~s{(group-resolve-id "zz-rb-ga")})
    gb = ev!(~s{(group-resolve-id "zz-rb-gb")})
    group = series(~s{(switch-to-group! "#{ga}")}, ~s{(switch-to-group! "#{gb}")})

    fa = Path.join(dir, "a.txt")
    peek = series(~s{(peek-file! "#{fa}")}, ~s{(peek-dismiss!)})

    ev!(~s{(begin (delete-other-windows!) (ibuffer-open! #f #f #f #f '(pretty #f info #t group-by group)) #t)})
    owner = ev!("(current-buffer)")

    listing =
      series(
        ~s{(listing-preview! "#{owner}" "zz-rb-b1")},
        ~s{(listing-preview! "#{owner}" "zz-rb-b2")}
      )

    ev!(~s{(begin (run-command "quit-window") (delete-other-windows!) (switch-to-buffer! "zz-rb-b1") (split-window! 'h 0.5) #t)})

    layout =
      series(
        ~s{(window-layout-choose! (window-tree) "columns")},
        ~s{(window-layout-choose! (window-tree) "rows")}
      )

    winner = series("(winner-previous!)", "(winner-next!)")

    IO.puts(
      "\nwindow rearrange us (p50/max over #{@runs}):" <>
        "\n  group switch      #{inspect(group)}" <>
        "\n  peek show/dismiss #{inspect(peek)}" <>
        "\n  listing preview   #{inspect(listing)}" <>
        "\n  layout choose     #{inspect(layout)}" <>
        "\n  winner undo/redo  #{inspect(winner)}"
    )

    assert group.p50 < 1_000_000
  end
end
