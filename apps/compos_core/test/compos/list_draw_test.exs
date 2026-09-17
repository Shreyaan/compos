defmodule Compos.ListDrawTest do
  @moduledoc """
  One list draw is few buffer changes. Every change is a frame refresh
  and a render, and a draw of twelve changes made the view jump: a render
  between the delete and the write saw an empty buffer and reset the
  window's top.
  """

  use Compos.Case

  alias Compos.Core.{Buffer, Events}

  defp count_changes(ref, n \\ 0) do
    receive do
      {:buffer_change, ^ref, _} -> count_changes(ref, n + 1)
    after
      300 -> n
    end
  end

  test "a list template supplies text and semantic fields through the shared pretty switch" do
    eval!(~S"""
    (begin
      (define *zz-template-pretty* #t)
      (define-list-mode! "zz-template-mode"
        (list 'buffer "*zz-template*" 'no-marks #t
              'rows (lambda (buf) '("café"))
              'text-template (lambda (buf row)
                (list (list row "sample-name" 8 'end "")
                      (list "ready" "sample-status" 6 'end "  ")))
              'pretty (lambda (buf) *zz-template-pretty*)))
      (list-mode-show! "zz-template-mode"))
    """)
    assert Buffer.text("*zz-template*") =~ "café      ready "
    assert inspect(Buffer.get_local("*zz-template*", "render-records"), limit: :infinity) =~ "sample-status"
    eval!(~S{(begin (set! *zz-template-pretty* #f) (list-redraw! "*zz-template*"))})
    assert Buffer.text("*zz-template*") =~ "café  ready"
    refute Buffer.text("*zz-template*") =~ "café      ready"
    Compos.Core.kill_buffer("*zz-template*")
  end

  test "set_locals writes several locals with one change" do
    name = "*zz-locals-#{System.unique_integer([:positive])}*"
    {:ok, ^name} = Compos.Core.create_buffer(name)
    ref = Buffer.ref(name)
    Events.subscribe(ref)

    eval!(~s{(buffer-set-locals! "#{name}" (list 'a 1 'b "two" 'c '(3)))})

    assert Buffer.get_local(name, "a") == 1
    assert Buffer.get_local(name, "b") == "two"
    assert Buffer.get_local(name, "c") == [3]
    assert count_changes(ref) == 1
    Compos.Core.kill_buffer(name)
  end

  test "a list redraw is at most eight buffer changes" do
    eval!(~s{(begin (load-tests-once!) (list-mode-show! "zz-page-mode") #t)})
    ref = Buffer.ref("*zz-page*")
    Events.subscribe(ref)

    eval!(~s{(list-redraw! "*zz-page*")})

    changes = count_changes(ref)
    assert changes <= 8, "a redraw made #{changes} buffer changes"
    assert Buffer.text("*zz-page*") =~ "row 49"
    eval!(~s{(buffer-kill! "*zz-page*")})
  end

  test "a redraw that changes nothing changes nothing" do
    eval!(~s{(begin (load-tests-once!) (list-mode-show! "zz-page-mode") #t)})
    eval!(~s{(list-redraw! "*zz-page*")})
    ref = Buffer.ref("*zz-page*")
    Events.subscribe(ref)

    eval!(~s{(list-redraw! "*zz-page*")})

    changes = count_changes(ref)
    assert changes == 0, "a still redraw made #{changes} buffer changes"
    eval!(~s{(buffer-kill! "*zz-page*")})
  end
end
