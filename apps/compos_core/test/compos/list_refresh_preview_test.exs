defmodule Compos.ListRefreshPreviewTest do
  use ExUnit.Case, async: false
  alias Compos.Core.{Editor, Session}
  defp eval!(code, frame) do
    assert {:ok, result} = Session.eval(code, frame)
    result
  end
  test "ordinary list refresh previews a changed selection, but not background refreshes" do
    previous = Editor.last_active_frame()
    {:ok, frame} = Editor.attach_frame(nil)
    try do
      eval!("""
      (define *rf-rows* '("alpha" "beta" "gamma"))
      (define *rf-calls* '())
      (define-list-mode! "zz-refresh-preview-mode"
        (list 'buffer "*zz-refresh-preview*"
          'rows (lambda (buf) *rf-rows*)
          'columns (lambda (buf) '(("name" #f)))
          'cells (lambda (buf row) (list row))
          'title (lambda (buf) "Rows")
          'preview (lambda (buf row) (set! *rf-calls* (cons row *rf-calls*)))))
      (list-mode-show! "zz-refresh-preview-mode")
      (list-goto-index! "*zz-refresh-preview*" 0)
      (set! *rf-calls* '())
      (set! *rf-rows* '("beta" "gamma"))
      (list-refresh! "*zz-refresh-preview*")
      """, frame)
      assert eval!("*rf-calls*", frame) == ~s{("beta")}
      eval!(~S{(list-refresh! "*zz-refresh-preview*")}, frame)
      assert eval!("*rf-calls*", frame) == ~s{("beta")}
      eval!("""
      (test-buffer! "*zz-refresh-other*" "other")
      (switch-to-buffer-here! "*zz-refresh-other*")
      (set! *rf-rows* '("gamma"))
      (list-refresh! "*zz-refresh-preview*")
      """, frame)
      assert eval!("*rf-calls*", frame) == ~s{("beta")}
    after
      eval!(~S{(for-each buffer-kill! '("*zz-refresh-preview*" "*zz-refresh-other*"))}, frame)
      Editor.delete_frame(frame)
      Editor.select_frame(previous)
    end
  end
end
