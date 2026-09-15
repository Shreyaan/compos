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
      (listing-preview-dismiss! (chat-list-buffer))
      (define *zz-dp-calls* '())
      (advice-add! 'listing-preview! 'before 'zz-dp
        (lambda (owner b) (set! *zz-dp-calls* (cons b *zz-dp-calls*)))))
    """)

    on_exit(fn ->
      eval!(~S"""
      (begin
        (chat-list--cancel-preview!)
        (chat-list--cancel-search!)
        (advice-remove! 'chat-list--scan 'zz-search-gate)
        (advice-remove! 'listing-preview! 'zz-dp)
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

  test "up and down move immediately without previews" do
    press("n")
    stale = eval!("(chat-list--preview-request)")
    press(["n", "p"])
    # Returning to the same row must not revive an older queued request.
    eval!("(chat-list--preview-now! '#{stale})")
    assert eval!(~S{(list-current "*chat-list*")}) == ~s("*zz-dp-b*")
    assert eval!("*zz-dp-calls*") == "()"
    Process.sleep(450)
    assert eval!("*zz-dp-calls*") == "()"
    assert eval!("(frame-local 'listing-preview-owner)") == "#f"
  end

  test "typing updates input before drawing the filtered list and preview" do
    press(["/", "C-a", "C-k"])
    press(String.graphemes("zz-dp-c"))
    assert eval!(~S{(plist-get (minibuffer-state) 'input)}) == ~s("zz-dp-c")
    eventually(fn -> eval!(~S{(list-current "*chat-list*")}) == ~s("*zz-dp-c*") end)
    assert eval!("*zz-dp-calls*") == "()"
    Process.sleep(450)
    assert eval!("*zz-dp-calls*") == "()"
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

  test "transcript-only matches arrive asynchronously without refetching the list" do
    Buffer.append("*zz-dp-c*", " hiddenneedle", source: :editor)
    press(["/", "C-a", "C-k"])
    press(String.graphemes("hiddenneedle"))
    assert eval!(~S{(plist-get (minibuffer-state) 'input)}) == ~s("hiddenneedle")
    eventually(fn -> eval!(~S{(list-current "*chat-list*")}) == ~s("*zz-dp-c*") end)
    assert eval!(~S{(chat-list-hit "*zz-dp-c*")}) =~ "hiddenneedle"
    press("C-g")
    assert eval!(~S{(list-query "*chat-list*")}) == ~s("hiddenneedle")
    assert eval!(~S{(chat-list-hit "*zz-dp-c*")}) =~ "hiddenneedle"
  end

  test "typing cancels a blocked transcript scan and rejects its old results" do
    Buffer.append("*zz-dp-c*", " hiddenneedle", source: :editor)

    eval!(~S"""
    (begin
      (define *zz-search-started* #f)
      (define *zz-search-release* #f)
      (advice-add! 'chat-list--scan 'before 'zz-search-gate
        (lambda (q cache)
          (set! *zz-search-started* q)
          (wait-until (lambda () *zz-search-release*) 2000))))
    """)

    press(["/", "C-a", "C-k"])
    press(String.graphemes("hiddenneedle"))
    eventually(fn -> eval!("*zz-search-started*") == ~s("hiddenneedle") end)
    eval!("(define *zz-old-search-task* *chat-list-search-task*)")
    # This key must finish while the worker remains blocked on its gate.
    press("x")
    assert eval!("(task-alive? *zz-old-search-task*)") == "#f"
    assert eval!(~S{(plist-get (minibuffer-state) 'input)}) == ~s("hiddenneedlex")
    eval!("(set! *zz-search-release* #t)")

    eventually(fn ->
      eval!("(and (pair? *chat-list-hits*) (car *chat-list-hits*))") == ~s("hiddenneedlex")
    end)

    assert eval!(~S{(list-entries "*chat-list*")}) == "()"
    press("C-g")
  end
  test "title matches precede transcript hits and a finished scan keeps the query" do
    Buffer.set_local("*zz-dp-c*", "chat-summary", "rankingneedle")
    Buffer.append("*zz-dp-a*", " rankingneedle", source: :editor)
    press(["/", "C-a", "C-k"])
    press(String.graphemes("rankingneedle"))
    eventually(fn -> eval!(~S{(chat-list-hit "*zz-dp-a*")}) != "#f" end)
    assert eval!(~S{(list-query "*chat-list*")}) == ~s("rankingneedle")
    assert eval!(~S{(filter string? (list-entries "*chat-list*"))}) == ~s{("*zz-dp-c*" "*zz-dp-a*")}
    press("C-g")
  end

  test "closing applies the pending query and retains it" do
    press(["/", "C-a", "C-k"])
    press(String.graphemes("nothingmatches"))
    press("C-g")
    Process.sleep(300)
    assert eval!(~S{(list-query "*chat-list*")}) == ~s("nothingmatches")
    assert eval!(~S{(list-query "*chat-list*")}) == ~s("nothingmatches")
  end

  test "RET flushes pending title filtering before choosing a chat" do
    Buffer.set_local("*zz-dp-c*", "chat-summary", "pendingneedle")
    press(["/", "C-a", "C-k"])
    press(String.graphemes("pendingneedle"))
    press("RET")
    assert eval!("(current-buffer)") == ~s("*zz-dp-c*")
    assert eval!("*chat-list-search-request*") == "#f"
  end

end
