defmodule Compos.NotmuchMailboxesTest do
  use ExUnit.Case, async: false

  alias Compos.Core.{KeyDispatch, Session}

  defp eval!(code) do
    {:ok, result} = Session.eval(code)
    result
  end

  setup do
    eval!(~S"""
    (begin
      (define zz-nm-saved-searches nm--saved-searches)
      (define zz-nm-all-tags nm--all-tags)
      (define zz-nm-db-path nm--db-path)
      (define zz-nm-shell shell-command->string)
      (define zz-nm-profile notmuch-profile)
      (define zz-nm-host notmuch-host)
      (define zz-nm-requests '())
      (set! notmuch-host "test-host")
      (set! notmuch-profile "test-profile")
      (set! nm--all-tags (lambda () '()))
      (set! nm--saved-searches
        (lambda () '(("inbox" "tag:inbox") ("unread" "tag:unread"))))
      (set! nm--db-path (lambda () "/test/mail"))
      (set! shell-command->string
        (lambda (cmd callback)
          (set! zz-nm-requests (append zz-nm-requests (list (list cmd callback))))))
      (when (buffer-exists? "*mailboxes*") (buffer-kill! "*mailboxes*"))
      (buffer-create "*zz-nm-origin*")
      (switch-to-buffer! "*zz-nm-origin*")
      (local-set-key "C-c C-9" "notmuch"))
    """)

    on_exit(fn ->
      eval!(~S"""
      (begin
        (set! nm--saved-searches zz-nm-saved-searches)
        (set! nm--all-tags zz-nm-all-tags)
        (set! nm--db-path zz-nm-db-path)
        (set! shell-command->string zz-nm-shell)
        (set! notmuch-profile zz-nm-profile)
        (set! notmuch-host zz-nm-host)
        (for-each (lambda (b) (when (buffer-exists? b) (buffer-kill! b)))
                  '("*mailboxes*" "*zz-nm-origin*")))
      """)
    end)

    :ok
  end

  defp open_mailboxes do
    KeyDispatch.handle_key("C-c")
    KeyDispatch.handle_key("C-9")
  end

  defp deliver(index, output) do
    eval!("((cadr (list-ref zz-nm-requests #{index})) #{inspect(output)})")
  end

  test "opening and navigation do not wait for counts, which use one batch" do
    open_mailboxes()
    assert eval!(~S|(current-buffer)|) == ~s{"*mailboxes*"}
    assert eval!(~S|(length zz-nm-requests)|) == "1"
    assert eval!(~S|(buffer-text "*mailboxes*")|) =~ "loading counts"
    assert eval!(~S|(list-current "*mailboxes*")|) == ~s{("inbox" "tag:inbox" #f #f)}
    assert eval!(~S|(car (car zz-nm-requests))|) =~ "count --batch"

    assert eval!(~S|(nm--hello-count-queries (nm--saved-searches))|) ==
             ~s{("tag:inbox" "( tag:inbox ) and tag:unread" "tag:unread" "( tag:unread ) and tag:unread")}

    eval!(~S|(local-set-key "C-c C-8" "list-next")|)
    KeyDispatch.handle_key("C-c")
    KeyDispatch.handle_key("C-8")
    eval!(~S|(switch-to-buffer! "*zz-nm-origin*")|)
    deliver(0, "5\n2\n2\n2\n")
    assert eval!(~S|(current-buffer)|) == ~s{"*zz-nm-origin*"}
    assert eval!(~S|(list-current "*mailboxes*")|) == ~s{("unread" "tag:unread" 2 2)}
    refute eval!(~S|(buffer-text "*mailboxes*")|) =~ "loading counts"
  end

  test "the latest refresh wins when callbacks arrive out of order" do
    open_mailboxes()
    eval!(~S|(run-command "notmuch-hello-refresh")|)
    deliver(1, "9\n3\n3\n3\n")
    deliver(0, "5\n2\n2\n2\n")
    assert eval!(~S|(car (list-entries "*mailboxes*"))|) == ~s{("inbox" "tag:inbox" 9 3)}
  end

  test "an account switch rejects old results before and after the next fetch" do
    open_mailboxes()
    eval!(~S|(set! notmuch-profile "other-profile")|)
    deliver(0, "5\n2\n2\n2\n")
    assert eval!(~S|(car (list-entries "*mailboxes*"))|) == ~s{("inbox" "tag:inbox" #f #f)}
    eval!(~S|(run-command "notmuch-hello-refresh")|)
    deliver(1, "8\n1\n1\n1\n")
    deliver(0, "5\n2\n2\n2\n")
    assert eval!(~S|(car (list-entries "*mailboxes*"))|) == ~s{("inbox" "tag:inbox" 8 1)}
  end

  test "failed and incomplete counts remain unknown and can be retried" do
    open_mailboxes()
    deliver(0, "ssh: connection failed\n")
    assert eval!(~S|(buffer-text "*mailboxes*")|) =~ "counts unavailable"
    assert eval!(~S|(car (list-entries "*mailboxes*"))|) == ~s{("inbox" "tag:inbox" #f #f)}
    eval!(~S|(run-command "notmuch-hello-refresh")|)
    deliver(1, "5\n2\n")
    assert eval!(~S|(buffer-text "*mailboxes*")|) =~ "counts unavailable"
    eval!(~S|(run-command "notmuch-hello-refresh")|)
    deliver(2, "0\n0\n0\n0\n")
    assert eval!(~S|(car (list-entries "*mailboxes*"))|) == ~s{("inbox" "tag:inbox" 0 0)}
  end

  test "restoring the mode restarts counts without accepting the lost request" do
    open_mailboxes()

    eval!(~S"""
    (begin
      (kill-local-variable! 'nm-hello-status "*mailboxes*")
      (kill-local-variable! 'nm-hello-request "*mailboxes*")
      (set-mode! "notmuch-hello-mode"))
    """)

    assert eval!(~S|(length zz-nm-requests)|) == "2"
    deliver(0, "5\n2\n2\n2\n")
    assert eval!(~S|(car (list-entries "*mailboxes*"))|) == ~s{("inbox" "tag:inbox" #f #f)}
    deliver(1, "7\n1\n1\n1\n")
    assert eval!(~S|(car (list-entries "*mailboxes*"))|) == ~s{("inbox" "tag:inbox" 7 1)}
  end

  test "a killed and recreated mailbox buffer rejects the old request" do
    open_mailboxes()
    eval!(~S|(begin (buffer-kill! "*mailboxes*") (run-command "notmuch"))|)
    deliver(0, "5\n2\n2\n2\n")
    assert eval!(~S|(car (list-entries "*mailboxes*"))|) == ~s{("inbox" "tag:inbox" #f #f)}
    deliver(1, "6\n1\n1\n1\n")
    assert eval!(~S|(car (list-entries "*mailboxes*"))|) == ~s{("inbox" "tag:inbox" 6 1)}
  end

  test "account tags appear without saved searches and existing tag searches are not duplicated" do
    eval!(
      ~S|(set! nm--all-tags (lambda () '("inbox" "unread" "investments" "invoice" "Follow up")))|
    )

    open_mailboxes()

    assert eval!(~S|(map car (list-entries "*mailboxes*"))|) ==
             ~s{("inbox" "unread" "investments" "invoice" "Follow up")}

    deliver(0, "5\n2\n2\n2\n7\n3\n4\n1\n6\n0\n")

    assert eval!(
             ~S|(map (lambda (row) (list (car row) (list-ref row 2) (list-ref row 3))) (list-entries "*mailboxes*"))|
           ) ==
             ~s{(("inbox" 5 2) ("unread" 2 2) ("investments" 7 3) ("invoice" 4 1) ("Follow up" 6 0))}
  end

  test "switching accounts discovers only the new account's tags" do
    eval!(
      ~S|(set! nm--all-tags (lambda () (if (equal? notmuch-profile "test-profile") '("investments") '("candidates"))))|
    )

    open_mailboxes()
    eval!(~S|(begin (set! notmuch-profile "recruiting") (run-command "notmuch-hello-refresh"))|)

    assert eval!(~S|(map car (list-entries "*mailboxes*"))|) ==
             ~s{("inbox" "unread" "candidates")}

    deliver(0, "5\n2\n2\n2\n7\n3\n")

    assert eval!(~S|(map car (list-entries "*mailboxes*"))|) ==
             ~s{("inbox" "unread" "candidates")}

    deliver(1, "5\n2\n2\n2\n8\n1\n")
    assert eval!(~S|(list-ref (list-entries "*mailboxes*") 2)|) =~ ~s{"candidates"}
  end

  test "tag queries quote spaces and embedded quotes literally" do
    assert eval!(~S|(nm--tag-query "Follow up")|) == ~S|"tag:\"Follow up\""|
    assert eval!(~S|(nm--tag-query "a\"b")|) == ~S|"tag:\"a\"\"b\""|
  end
end
