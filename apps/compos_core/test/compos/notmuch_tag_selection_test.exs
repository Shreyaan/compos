defmodule Compos.NotmuchTagSelectionTest do
  use ExUnit.Case, async: false
  alias Compos.Core.{KeyDispatch, Session}

  defp eval!(code) do
    {:ok, result} = Session.eval(code)
    result
  end

  setup do
    eval!(~S"""
    (begin
      (define zz-tag-old-run nm--run)
      (define zz-tag-old-search nm--search-json)
      (define zz-tag-old-preview notmuch-auto-preview)
      (define zz-tag-old-paths *nm-db-paths*)
      (define zz-tag-calls '())
      (define zz-tag-fetches 0)
      (set! notmuch-auto-preview #f)
      (set! nm--search-json
        (lambda (query limit)
          (set! zz-tag-fetches (+ zz-tag-fetches 1))
          (map (lambda (id)
                 (list 'thread id 'subject id 'authors "Test" 'date_relative "Today"
                       'tags '("inbox"))) '("one" "two"))))
      (set! nm--run
        (lambda (args)
          (set! zz-tag-calls (append zz-tag-calls (list args)))
          (cond
            ((string-prefix? "count " args) "10000\n")
            ((equal? args "config get database.path") "/test/mail\n")
            ((string-prefix? "search --output=tags" args) "inbox\nunread\n")
            (else ""))))
      (when (buffer-exists? "*notmuch*") (buffer-kill! "*notmuch*"))
      (run-command "notmuch-inbox"))
    """)

    on_exit(fn ->
      eval!(~S"""
      (begin
        (minibuffer-cancel!)
        (when (buffer-exists? "*notmuch*") (buffer-kill! "*notmuch*"))
        (set! nm--run zz-tag-old-run)
        (set! nm--search-json zz-tag-old-search)
        (set! notmuch-auto-preview zz-tag-old-preview)
        (set! *nm-db-paths* zz-tag-old-paths))
      """)
    end)

    :ok
  end

  defp narrow do
    eval!(
      ~S|(begin (nm--query-push! "*notmuch*" "from:alice") (nm--refresh! "*notmuch*") (set! zz-tag-calls '()) (set! zz-tag-fetches 0))|
    )
  end

  defp submit(key, tag) do
    KeyDispatch.handle_key(key)
    eval!("(minibuffer-change! #{inspect(tag)})")
    KeyDispatch.handle_key("RET")
  end

  test "unfiltered inbox refuses select all without any external work" do
    eval!("(begin (set! zz-tag-calls '()) (set! zz-tag-fetches 0))")
    KeyDispatch.handle_key("*")
    assert eval!("zz-tag-calls") == "()"
    assert eval!("zz-tag-fetches") == "0"
    assert eval!(~S|(nm--any-marked? "*notmuch*")|) == "#f"
  end

  test "select and clear a ten thousand message query do no external work" do
    narrow()
    KeyDispatch.handle_key("*")
    assert eval!(~S|(list-marks "*notmuch*")|) == ~s{(("one" "*") ("two" "*"))}
    assert eval!(~S|(nm--marked-query "*notmuch*")|) == ~s{"( ( tag:inbox ) and from:alice )"}
    KeyDispatch.handle_key("U")
    assert eval!(~S|(list-marks "*notmuch*")|) == "()"
    assert eval!("zz-tag-calls") == "()"
    assert eval!("zz-tag-fetches") == "0"
  end

  test "individual marks survive refresh and second star clears them in inbox" do
    KeyDispatch.handle_key("m")
    eval!(~S|(nm--refresh! "*notmuch*")|)
    assert eval!(~S|(list-marks "*notmuch*")|) == ~s{(("one" "*"))}
    KeyDispatch.handle_key("*")
    assert eval!(~S|(nm--any-marked? "*notmuch*")|) == "#f"
  end

  test "bulk add targets the entire selected query and then clears selection" do
    narrow()
    KeyDispatch.handle_key("*")
    submit("+", "investments")

    assert eval!(~S|(car (filter (lambda (cmd) (string-prefix? "tag " cmd)) zz-tag-calls))|) ==
             ~s{"tag '+investments' -- '( ( tag:inbox ) and from:alice )'"}

    assert eval!(~S|(nm--any-marked? "*notmuch*")|) == "#f"
  end

  test "deselecting a row from all excludes that thread with no round trip" do
    narrow()
    KeyDispatch.handle_key("*")
    KeyDispatch.handle_key("m")
    assert eval!("zz-tag-calls") == "()"
    assert eval!("zz-tag-fetches") == "0"
    assert eval!(~S|(list-marks "*notmuch*")|) == ~s{(("two" "*"))}
    submit("+", "invoice")

    assert eval!(~S|(car (filter (lambda (cmd) (string-prefix? "tag " cmd)) zz-tag-calls))|) ==
             ~s{"tag '+invoice' -- '( ( tag:inbox ) and from:alice ) and not ( thread:one )'"}
  end

  test "remove tag gets unread from the full selection rather than point" do
    narrow()
    KeyDispatch.handle_key("*")
    assert eval!(~S|(member "unread" (nm--th-tags (nm--thread-at "*notmuch*")))|) == "#f"
    submit("-", "unread")

    assert eval!(~S|(car zz-tag-calls)|) ==
             ~s{"search --output=tags -- '( ( tag:inbox ) and from:alice )'"}

    assert eval!(~S|(cadr zz-tag-calls)|) ==
             ~s{"tag '-unread' -- '( ( tag:inbox ) and from:alice )'"}
  end

  test "individual selection scopes bulk action to selected thread and search" do
    KeyDispatch.handle_key("m")
    submit("+", "invoice")

    assert eval!(~S|(member "tag '+invoice' -- '( tag:inbox ) and ( thread:one )'" zz-tag-calls)|) !=
             "#f"
  end

  test "no selection still adds only to point" do
    submit("+", "invoice")
    assert eval!(~S|(member "tag '+invoice' -- thread:one" zz-tag-calls)|) != "#f"
  end

  test "filter changes clear selection without resurrecting it on back" do
    narrow()
    KeyDispatch.handle_key("*")
    eval!(~S|(nm--query-push! "*notmuch*" "tag:unread")|)
    assert eval!(~S|(nm--any-marked? "*notmuch*")|) == "#f"
    eval!(~S|(nm--query-pop! "*notmuch*")|)
    assert eval!(~S|(nm--any-marked? "*notmuch*")|) == "#f"
  end

  test "show selected opens the selection query and back restores the filter" do
    narrow()
    KeyDispatch.handle_key("m")
    KeyDispatch.handle_key("F")

    assert eval!(~S|(nm--query-of "*notmuch*")|) ==
             ~s{"( ( tag:inbox ) and from:alice ) and ( thread:one )"}

    KeyDispatch.handle_key("q")
    assert eval!(~S|(nm--query-of "*notmuch*")|) == ~s{"( tag:inbox ) and from:alice"}
  end

  test "reload preserves local selection but switching account invalidates it" do
    narrow()
    KeyDispatch.handle_key("*")
    eval!(~S|(set-mode! "notmuch-mode")|)
    assert eval!(~S|(nm--any-marked? "*notmuch*")|) == "#t"

    eval!(
      ~S|(let ((old notmuch-profile)) (set! notmuch-profile "other") (nm--selection "*notmuch*") (set! notmuch-profile old))|
    )

    assert eval!(~S|(nm--any-marked? "*notmuch*")|) == "#f"
  end

  test "archive follows the marks and dispatches only after confirmation" do
    KeyDispatch.handle_key("m")
    assert eval!(~S|(list-marks "*notmuch*")|) == ~s{(("one" "*"))}
    KeyDispatch.handle_key("a")
    assert eval!(~S|(filter (lambda (cmd) (string-prefix? "tag " cmd)) zz-tag-calls)|) == "()"
    eval!(~S|(minibuffer-change! "yes")|)
    KeyDispatch.handle_key("RET")

    assert eval!(~S|(filter (lambda (cmd) (string-prefix? "tag " cmd)) zz-tag-calls)|) ==
             ~s{("tag -inbox -- '( tag:inbox ) and ( thread:one )'")}
  end

  test "header counts selected threads and identifies selection beyond loaded rows" do
    KeyDispatch.handle_key("m")
    assert eval!(~S|(nm--search-meta "*notmuch*")|) =~ "1 thread selected"
    KeyDispatch.handle_key("U")
    refute eval!(~S|(nm--search-meta "*notmuch*")|) =~ "selected"
    narrow()
    KeyDispatch.handle_key("*")
    assert eval!(~S|(nm--search-meta "*notmuch*")|) =~ "All 10000 matching messages selected"
    assert eval!("zz-tag-fetches") == "0"
    assert eval!("zz-tag-calls") == "()"
    KeyDispatch.handle_key("m")

    assert eval!(~S|(nm--search-meta "*notmuch*")|) =~
             "All matching messages selected except 1 thread"
  end
end
