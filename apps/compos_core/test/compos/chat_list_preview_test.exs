defmodule Compos.ChatListPreviewTest do
  use ExUnit.Case, async: false
  alias Compos.Core.{Buffer, Editor, KeyDispatch, Session}

  defp eval!(code) do
    {:ok, value} = Session.eval(code, nil, 30_000)
    value
  end

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp eventually(fun, tries \\ 150)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, tries) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, tries - 1)
        )
  end

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()
    Editor.set_window_buffer("*scratch*")

    for name <- ["*zz-dp-a*", "*zz-dp-b*", "*zz-dp-c*"] do
      Compos.Core.create_buffer(name, text: "transcript")
      Buffer.set_local(name, "mode-name", "chat-mode")
    end

    eval!("(set! chat-list-preview-delay-ms 400)")
    press(["C-x", "C-c"])

    eval!(~S"""
    (begin
      (buffer-set-locals! "*chat-list*" '(ibuffer-grouping none ibuffer-sort name))
      (list-set-query! "*chat-list*" "zz-dp-" #t)
      (ibuffer-goto-first-row! "*chat-list*")
      (chat-list--cancel-preview!)
      (window-preview-buffer! "*scratch*" (chat-list-preview-window))
      (define *zz-dp-calls* '())
      (advice-add! 'window-preview-buffer! 'before 'zz-dp
        (lambda (b &optional win) (set! *zz-dp-calls* (cons b *zz-dp-calls*)))))
    """)

    on_exit(fn ->
      eval!(~S"""
      (begin
        (chat-list--cancel-preview!)
        (advice-remove! 'window-preview-buffer! 'zz-dp)
        (set! chat-list-preview-delay-ms 150)
        (when (window-showing "*chat-list*") (chat-list-back!))
        (set! *mb-list-buffer* #f)
        (set! *mb-list-prompt* #f))
      """)

      Editor.minibuffer_close()

      for name <- ["*zz-dp-a*", "*zz-dp-b*", "*zz-dp-c*", "*chat-list*"],
          do: Compos.Core.kill_buffer(name)
    end)

    :ok
  end

  test "up and down move immediately but preview only the final row" do
    press("n")
    stale = eval!("(chat-list--preview-request)")
    press(["n", "p"])
    # Returning to the same row must not revive an older queued request.
    eval!("(chat-list--preview-now! '#{stale})")
    assert eval!(~S{(list-current "*chat-list*")}) == ~s("*zz-dp-b*")
    assert eval!("*zz-dp-calls*") == "()"
    eventually(fn -> eval!("*zz-dp-calls*") == ~s{("*zz-dp-b*")} end)
    assert eval!("(window-buffer (chat-list-preview-window))") == ~s("*zz-dp-b*")
  end

  test "typing filters immediately and delays the preview" do
    press("/")
    press(String.graphemes("zz-dp-c"))
    assert eval!(~S{(list-current "*chat-list*")}) == ~s("*zz-dp-c*")
    assert eval!("*zz-dp-calls*") == "()"
    eventually(fn -> eval!("*zz-dp-calls*") == ~s{("*zz-dp-c*")} end)
  end

  test "leaving cancels pending and already-queued previews" do
    press("n")
    request = eval!("(chat-list--preview-request)")
    press("q")
    assert eval!("(chat-list--preview-request)") == "#f"
    tree = Editor.render_state().tree
    # Exercise a callback already handed to the UI lane before cancellation.
    eval!("(chat-list--preview-now! '#{request})")
    Process.sleep(450)
    assert Editor.render_state().tree == tree
    assert eval!("*zz-dp-calls*") == "()"
  end
end
