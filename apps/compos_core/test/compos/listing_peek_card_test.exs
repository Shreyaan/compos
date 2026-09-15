defmodule Compos.ListingPeekCardTest do
  use ExUnit.Case, async: false
  alias Compos.Core.{Editor, KeyDispatch, Session}
  defp eval!(code, frame) do
    assert {:ok, result} = Session.eval(code, frame)
    result
  end
  for command <- ["ibuffer", "ichat"] do
    @command command
    test "#{command} floats an isolated nonfocusable card and q only dismisses it" do
      previous = Editor.last_active_frame()
      {:ok, frame} = Editor.attach_frame(nil)
      try do
        eval!("""
        (test-buffer! "*zz-card-source*" "unchanged")
        (test-buffer! "*zz-card-target*" "Preview body <script>not executable</script>")
        (buffer-set-local! "*zz-card-target*" 'mode-name "chat-mode")
        (switch-to-buffer-here! "*zz-card-source*")
        (define *card-home* (active-window))
        (global-set-key "<f9>" "#{@command}")
        """, frame)
        KeyDispatch.handle_key(frame, "<f9>")
        eval!("""
        (define *card-owner* (window-buffer (active-window)))
        (buffer-set-locals! *card-owner* '(ibuffer-grouping none ibuffer-sort name))
        (list-set-query! *card-owner* "zz-card-target" #t)
        (ibuffer-goto-first-row! *card-owner*)
        (listing-preview! *card-owner* "*zz-card-target*")
        (define *card-copy* (popup-buffer))
        """, frame)
        assert eval!("(equal? (active-window) *card-home*)", frame) == "#t"
        assert eval!("(buffer-read-only? *card-copy*)", frame) == "#t"
        assert eval!("(window-focusable? (popup-window))", frame) == "#f"
        assert eval!("(buffer-local *card-copy* 'window-class)", frame) =~ "listing-peek"
        assert eval!("(buffer-local *card-copy* 'window-style)", frame) =~ "--peek-source-window:"
        assert eval!("(buffer-local *card-copy* 'mode-name)", frame) == "\"chat-mode\""
        assert eval!("(buffer-local \"*zz-card-target*\" 'window-class)", frame) == "#f"
        assert eval!("(buffer-local *card-copy* 'popup-keys)", frame) == "#f"
        KeyDispatch.handle_key(frame, "q")
        assert eval!("(equal? (current-buffer) *card-owner*)", frame) == "#t"
        assert eval!("(buffer-known? *card-copy*)", frame) == "#f"
        eval!("(listing-preview-schedule! *card-owner* \"*zz-card-target*\")", frame)
        Process.sleep(250)
        assert eval!("(popup-open?)", frame) == "#f"
        if @command == "ibuffer" do
          # Even up at the first row is an explicit request to look again.
          KeyDispatch.handle_key(frame, "<up>")
          Process.sleep(250)
          assert eval!("(popup-open?)", frame) == "#t"
          KeyDispatch.handle_key(frame, "p")
          assert eval!("(popup-open?)", frame) == "#f"
          KeyDispatch.handle_key(frame, "<up>")
          Process.sleep(250)
          assert eval!("(popup-open?)", frame) == "#f"
          KeyDispatch.handle_key(frame, "p")
          assert eval!("(popup-open?)", frame) == "#t"
          KeyDispatch.handle_key(frame, "q")
        end
        KeyDispatch.handle_key(frame, "q")
        assert eval!("(current-buffer)", frame) == "\"*zz-card-source*\""
      after
        eval!("""
        (listing-preview-dismiss! *card-owner*)
        (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
          (list "*zz-card-source*" "*zz-card-target*" *card-owner*))
        (global-unset-key "<f9>")
        """, frame)
        Editor.delete_frame(frame)
        Editor.select_frame(previous)
      end
    end
  end
end
