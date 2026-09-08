defmodule Compos.NotmuchAttachmentsTest do
  use ExUnit.Case, async: false
  alias Compos.Core.{KeyDispatch, Session}

  defp eval!(code) do
    {:ok, result} = Session.eval(code)
    result
  end

  setup do
    eval!(~S"""
    (begin
      (define zz-attachment-old-show nm--show-msgs)
      (define zz-attachment-old-open nm--open-attachment!)
      (define zz-attachment-old-visit visit)
      (define zz-attachment-old-profile notmuch-profile)
      (define zz-attachment-opened #f)
      (define zz-attachment-chosen #f)
      (define zz-attachment-msg
        '(id "message-one" headers (Subject "Report" From "Sender" Date "Today")
          body ((id 1 content-type "multipart/mixed" content
                 ((id 2 content-type "multipart/alternative" content
                   ((id 3 content-type "text/plain" content "Plain body")
                    (id 4 content-type "text/html" content "<p>HTML body</p>")))
                  (id 5 content-type "application/pdf" filename "report & <q>.pdf")
                  (id 6 content-type "text/plain" filename "letter.txt" content "Attached text")
                  (id 7 content-type "text/html" filename "page.html" content "Attached HTML"))))))
      (set! notmuch-profile "attachment-account")
      (set! nm--show-msgs (lambda (thread) (list zz-attachment-msg)))
      (set! nm--open-attachment! (lambda (a) (set! zz-attachment-chosen a)))
      (set! visit (lambda (path) (set! zz-attachment-opened path)))
      (when (buffer-exists? "*mail*") (buffer-kill! "*mail*"))
      (buffer-create "*mail*")
      (switch-to-buffer! "*mail*")
      (buffer-set-local! "*mail*" 'notmuch-thread "thread-one")
      (buffer-set-local! "*mail*" 'notmuch-subject "Report")
      (set-mode! "notmuch-show-mode")
      (local-set-key "C-c C-3" "notmuch-open-attachment"))
    """)

    on_exit(fn ->
      eval!(~S"""
      (begin
        (minibuffer-cancel!)
        (set! nm--show-msgs zz-attachment-old-show)
        (set! nm--open-attachment! zz-attachment-old-open)
        (set! visit zz-attachment-old-visit)
        (set! notmuch-profile zz-attachment-old-profile)
        (when (buffer-exists? "*mail*") (buffer-kill! "*mail*")))
      """)
    end)

    :ok
  end

  test "nested attachments are visible in HTML and text without replacing the body" do
    html = eval!(~S|(nm--msg-html zz-attachment-msg)|)
    assert html =~ "report &amp; &lt;q&gt;.pdf"
    assert html =~ "letter.txt"
    assert html =~ "page.html"
    assert html =~ "HTML body"
    refute html =~ "Attached HTML"
    text = eval!(~S|(nm--msg-render zz-attachment-msg)|)
    assert text =~ "report & <q>.pdf"
    assert text =~ "letter.txt"
    assert text =~ "Plain body"
    refute text =~ "Attached text"
  end

  test "attachment picker uses the exact part and the account captured by the message" do
    eval!(~S|(set! notmuch-profile "another-account")|)
    KeyDispatch.handle_key("C-c")
    KeyDispatch.handle_key("C-3")
    eval!(~S|(minibuffer-change! "2. letter.txt")|)
    KeyDispatch.handle_key("RET")
    chosen = eval!("zz-attachment-chosen")
    assert chosen =~ "letter.txt"
    assert chosen =~ "--part=6"
    assert chosen =~ "id:message-one"
    assert chosen =~ "attachment-account"
    refute chosen =~ "another-account"
  end

  test "mode reload rebuilds attachment metadata" do
    eval!(~S"""
    (begin
      (kill-local-variable! 'notmuch-attachments "*mail*")
      (set-mode! "notmuch-show-mode"))
    """)

    assert eval!(~S|(length (buffer-local "*mail*" 'notmuch-attachments))|) == "3"
  end

  test "download preserves binary bytes and confines the filename to its new directory" do
    eval!(~S|(zz-attachment-old-open (list "../payload.bin" "printf '\000\377ABC'"))|)
    path = await_open(200)
    assert Path.basename(path) == "payload.bin"
    assert File.read!(path) == <<0, 255, 65, 66, 67>>
    File.rm_rf!(Path.dirname(path))
  end

  defp await_open(0), do: flunk("attachment download did not open")

  defp await_open(n) do
    case eval!("zz-attachment-opened") do
      "#f" ->
        Process.sleep(10)
        await_open(n - 1)

      value ->
        Jason.decode!(value)
    end
  end
end
