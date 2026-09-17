defmodule Compos.NotmuchSceneTest do
  @moduledoc """
  The semantic scene path through real key dispatch.

  Notmuch policy stays in `priv/tests/notmuch-test.scm`. This test binds a
  test-only key to the production command and proves that GUI dispatch routes
  it by the scene's `show` role, without asserting the production binding.
  """

  use Compos.Case, async: false

  alias Compos.Core.{KeyDispatch, Session}

  setup do
    eval!(~S"""
    (begin
      (define *zz-notmuch-old-run* nm--run)
      (define *zz-notmuch-old-search* nm--search-json)
      (define *zz-notmuch-old-auto-preview* notmuch-auto-preview)
      (define *zz-notmuch-old-preview-delay* notmuch-preview-delay)
      (set! notmuch-preview-delay 0)
      (define *zz-notmuch-calls* '())
      (set! notmuch-auto-preview #t)
      (set! nm--run
        (lambda (args)
          (set! *zz-notmuch-calls* (append *zz-notmuch-calls* (list args)))
          (cond
            ((string-prefix? "search --output=tags" args)
             "unread\ninbox\n")
            ((string-prefix? "search" args)
             "[{\"thread\":\"zz-thread\",\"timestamp\":1786065644,\"date_relative\":\"Today\",\"matched\":1,\"total\":1,\"authors\":\"Alice\",\"subject\":\"Role routed mail\",\"query\":[\"id:zz-message\"],\"tags\":[\"inbox\"]},{\"thread\":\"zz-thread-2\",\"timestamp\":1785979244,\"date_relative\":\"Yesterday\",\"matched\":1,\"total\":1,\"authors\":\"Bob\",\"subject\":\"Reloaded selection\",\"query\":[\"id:zz-message-2\"],\"tags\":[\"inbox\"]}]")
            ((string-prefix? "count " args) "5\n")
            ((string-prefix? "show" args)
             "[[[{\"id\":\"zz-message\",\"match\":true,\"excluded\":false,\"filename\":[\"/tmp/zz-message\"],\"timestamp\":1786065644,\"date_relative\":\"Today\",\"tags\":[\"inbox\"],\"duplicate\":1,\"body\":[{\"id\":1,\"content-type\":\"text/plain\",\"content\":\"The routed body.\\n\"}],\"headers\":{\"Subject\":\"Role routed mail\",\"From\":\"Alice <alice@example.com>\",\"To\":\"reader@example.com\",\"Date\":\"Thu, 07 Aug 2026 06:50:44 +0530\"}},[]]]]")
            (else ""))))
      (for-each
        (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
        '("*notmuch*" "*mail*" "*chat:zz-notmuch-scene*"))
      (delete-other-windows!))
    """)

    on_exit(fn ->
      eval!(~S"""
      (begin
        (set! nm--run *zz-notmuch-old-run*)
        (set! nm--search-json *zz-notmuch-old-search*)
        (set! notmuch-auto-preview *zz-notmuch-old-auto-preview*)
        (set! notmuch-preview-delay *zz-notmuch-old-preview-delay*)
        (let ((id (group-resolve-id "zz-notmuch-scene")))
          (when id (group-dissolve! id)))
        (set! *scenes*
          (remove (lambda (entry) (equal? (car entry) "zz-notmuch-scene")) *scenes*))
        (for-each
          (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
          '("*notmuch*" "*mail*" "*chat:zz-notmuch-scene*"))
        (delete-other-windows!))
      """)
    end)

    :ok
  end

  test "opening the inbox immediately previews its first thread and keeps focus" do
    eval!(~S|(local-set-key "C-c C-6" "notmuch-inbox")|)
    KeyDispatch.handle_key("C-c")
    KeyDispatch.handle_key("C-6")

    assert eval!(~S|(current-buffer)|) == ~s{"*notmuch*"}
    assert eval!(~S|(list-index "*notmuch*")|) == "0"
    assert eval!(~S|(buffer-local "*mail*" 'notmuch-thread)|) == ~s{"zz-thread"}
    assert eval!(~S|(buffer-text "*mail*")|) =~ "The routed body."
    assert eval!(~S|(window-showing "*mail*")|) != "#f"
    assert eval!(~S|(member "tag -unread -- thread:zz-thread" *zz-notmuch-calls*)|) != "#f"
  end

  test "a preview read-tag failure leaves focus in the index" do
    eval!(~S|(run-command "notmuch-inbox")|)

    eval!(
      ~S|(set! nm--run (lambda (args) (if (string-prefix? "tag " args) (error "write denied") (*zz-notmuch-old-run* args))))|
    )

    # The view already exists; force the open path to fail only at the write.
    eval!(~S|(define zz-open-thread nm--open-thread!)|)

    eval!(
      ~S|(set! nm--open-thread! (lambda (id subject &rest opts) (switch-to-buffer! "*mail*")))|
    )

    try do
      assert {:error, _} = Session.eval(~S|(nm--preview! "*notmuch*")|)
      assert eval!(~S|(current-buffer)|) == ~s{"*notmuch*"}
    after
      eval!(~S|(set! nm--open-thread! zz-open-thread)|)
    end
  end

  test "dismissal closes the visible thread before invoking mail back" do
    eval!(~S|(run-command "notmuch-inbox")|)
    assert eval!(~S|(buffer-parent "*mail*")|) == ~s{"*notmuch*"}
    index = eval!(~S|(list-index "*notmuch*")|)
    KeyDispatch.handle_key("q")
    assert eval!(~S|(buffer-known? "*mail*")|) == "#f"
    assert eval!(~S|(current-buffer)|) == ~s{"*notmuch*"}
    assert eval!(~S|(list-index "*notmuch*")|) == index
    assert eval!(~S|(buffer-known? "*notmuch*")|) == "#t"
    KeyDispatch.handle_key("q")
    assert eval!(~S|(buffer-derived-mode? (current-buffer) "notmuch-hello-mode")|) == "#t"
  end

  test "dismissal from a selected thread preserves the search" do
    eval!(~S|(run-command "notmuch-inbox")|)
    eval!(~S|(select-window! (window-showing "*mail*"))|)
    KeyDispatch.handle_key("q")
    assert eval!(~S|(buffer-known? "*mail*")|) == "#f"
    assert eval!(~S|(buffer-known? "*notmuch*")|) == "#t"
    assert eval!(~S|(window-showing "*notmuch*")|) != "#f"
  end

  test "reopening a cached inbox replaces the previous thread preview" do
    eval!(~S"""
    (begin
      (run-command "notmuch-inbox")
      (run-command "notmuch-next")
      (local-set-key "C-c C-6" "notmuch-inbox"))
    """)

    assert eval!(~S|(buffer-local "*mail*" 'notmuch-thread)|) == ~s{"zz-thread-2"}
    KeyDispatch.handle_key("C-c")
    KeyDispatch.handle_key("C-6")
    assert eval!(~S|(current-buffer)|) == ~s{"*notmuch*"}
    assert eval!(~S|(list-index "*notmuch*")|) == "0"
    assert eval!(~S|(buffer-local "*mail*" 'notmuch-thread)|) == ~s{"zz-thread"}
  end

  test "opening respects disabled auto preview" do
    eval!(~S|(begin (set! notmuch-auto-preview #f) (run-command "notmuch-inbox"))|)
    assert eval!(~S|(buffer-exists? "*mail*")|) == "#f"
    assert eval!(~S|(length (window-list))|) == "1"

    assert eval!(~S|(filter (lambda (call) (string-prefix? "tag " call)) *zz-notmuch-calls*)|) ==
             "()"
  end

  test "read/unread toggles persist with auto preview enabled" do
    eval!(~S"""
    (begin
      (define zz-read-unread #t)
      (define zz-read-run nm--run)
      (set! nm--run
        (lambda (args)
          (cond
            ((equal? args "tag +unread -- thread:zz-thread") (set! zz-read-unread #t))
            ((equal? args "tag -unread -- thread:zz-thread") (set! zz-read-unread #f)))
          (zz-read-run args)))
      (set! nm--search-json
        (lambda (query limit)
          (list (list 'thread "zz-thread" 'subject "Read state" 'authors "Alice"
                      'date_relative "Today"
                      'tags (if zz-read-unread '("inbox" "unread") '("inbox"))))))
      (run-command "notmuch-inbox")
      (local-set-key "C-c C-5" "notmuch-toggle-unread"))
    """)

    assert eval!("zz-read-unread") == "#f"

    KeyDispatch.handle_key("C-c")
    KeyDispatch.handle_key("C-5")
    assert eval!("zz-read-unread") == "#t"
    assert eval!(~S|(member "unread" (nm--th-tags (nm--thread-at "*notmuch*")))|) != "#f"

    KeyDispatch.handle_key("C-c")
    KeyDispatch.handle_key("C-5")
    assert eval!("zz-read-unread") == "#f"
    assert eval!(~S|(member "unread" (nm--th-tags (nm--thread-at "*notmuch*")))|) == "#f"
    assert eval!(~S|(current-buffer)|) == ~s{"*notmuch*"}
  end

  test "open routes to the scene's show role through key dispatch" do
    eval!(~S"""
    (begin
      (define-scene! "zz-notmuch-scene"
        '(h 0.32 (as index (ensure "*notmuch*" "notmuch-inbox"))
                 (as show (ensure "*mail*" "notmuch-show-current"))
                 (as chat group-chat)))
      (scene-open! "zz-notmuch-scene")
      (select-window! (scene-window 'index))
      (local-set-key "C-c C-9" "notmuch-open-thread"))
    """)

    KeyDispatch.handle_key("C-c")
    KeyDispatch.handle_key("C-9")

    assert eval!(~S|(current-buffer)|) == ~s{"*notmuch*"}
    assert eval!(~S|(buffer-text "*notmuch*")|) =~ "5 messages"
    assert eval!(~S|(active-window)|) == eval!(~S|(scene-window 'index)|)
    assert eval!(~S|(window-buffer (scene-window 'index))|) == ~s{"*notmuch*"}
    assert eval!(~S|(buffer-text (scene-buffer 'show))|) =~ "The routed body."
    assert eval!(~S|(window-buffer (scene-window 'chat))|) == ~s{"*chat:zz-notmuch-scene*"}
  end

  test "a mode key opens the tag menu and applies its selection" do
    eval!(~S"""
    (begin
      (run-command "notmuch-inbox")
      (local-set-key "C-c C-8" "notmuch-filter-by-tag"))
    """)

    KeyDispatch.handle_key("C-c")
    KeyDispatch.handle_key("C-8")

    assert eval!(~S|(minibuffer-selected)|) == ~s{"unread"}
    KeyDispatch.handle_key("RET")

    assert eval!(~S|(nm--query-of "*notmuch*")|) == ~s{"( tag:inbox ) and tag:unread"}
  end

  test "the highlighted row follows key dispatch and survives mode reload" do
    eval!(~S"""
    (begin
      (run-command "notmuch-inbox")
      (local-set-key "C-c C-7" "notmuch-next"))
    """)

    KeyDispatch.handle_key("C-c")
    KeyDispatch.handle_key("C-7")

    assert eval!(~S|(nm--th-id (nm--thread-at "*notmuch*"))|) == ~s{"zz-thread-2"}
    assert eval!(selected_row_overlay?()) == "#t"
    assert eval!(selected_row_covers_both_lines?()) == "#t"

    eval!(~S|(with-current-buffer "*notmuch*" (lambda () (set-mode! "notmuch-mode")))|)

    assert eval!(~S|(nm--th-id (nm--thread-at "*notmuch*"))|) == ~s{"zz-thread-2"}
    assert eval!(selected_row_overlay?()) == "#t"
    assert eval!(selected_row_covers_both_lines?()) == "#t"
  end

  test "backslash restores the row where a filter was entered" do
    eval!(~S"""
    (begin
      (run-command "notmuch-inbox")
      (list-goto-index! "*notmuch*" 1))
    """)

    KeyDispatch.handle_key("m")
    KeyDispatch.handle_key("F")

    assert eval!(~S|(list-index "*notmuch*")|) == "0"

    KeyDispatch.handle_key("\\")

    assert eval!(~S|(nm--query-of "*notmuch*")|) == ~s{"tag:inbox"}
    assert eval!(~S|(list-index "*notmuch*")|) == "1"
  end

  test "mail back pops one filter and restores its row" do
    eval!(~S"""
    (begin
      (set! notmuch-auto-preview #f)
      (run-command "notmuch-inbox")
      (list-goto-index! "*notmuch*" 1)
      (nm--query-push! "*notmuch*" "from:alice")
      (nm--refresh! "*notmuch*")
      (list-goto-index! "*notmuch*" 0)
      (nm--query-push! "*notmuch*" "tag:unread")
      (nm--refresh! "*notmuch*")
      (local-set-key "C-c C-4" "notmuch-back"))
    """)

    KeyDispatch.handle_key("C-c")
    KeyDispatch.handle_key("C-4")
    assert eval!(~S|(nm--query-of "*notmuch*")|) == ~s{"( tag:inbox ) and from:alice"}
    assert eval!(~S|(current-buffer)|) == ~s{"*notmuch*"}
    KeyDispatch.handle_key("C-c")
    KeyDispatch.handle_key("C-4")
    assert eval!(~S|(nm--query-of "*notmuch*")|) == ~s{"tag:inbox"}
    assert eval!(~S|(list-index "*notmuch*")|) == "1"
  end

  defp selected_row_overlay? do
    ~S"""
    (let ((p (buffer-point "*notmuch*")))
      (pair?
        (filter
          (lambda (overlay)
            (and (equal? (list-ref overlay 2) "select")
                 (<= (car overlay) p)
                 (< p (cadr overlay))))
          (buffer-overlays "*notmuch*"))))
    """
  end

  defp selected_row_covers_both_lines? do
    ~S"""
    (let* ((text (buffer-text "*notmuch*"))
           (subject (string-index text "Reloaded selection"))
           (author (string-index text "Bob")))
      (pair?
        (filter
          (lambda (overlay)
            (and (equal? (list-ref overlay 2) "select")
                 (<= (car overlay) subject)
                 (< subject (cadr overlay))
                 (<= (car overlay) author)
                 (< author (cadr overlay))))
          (buffer-overlays "*notmuch*"))))
    """
  end
end
