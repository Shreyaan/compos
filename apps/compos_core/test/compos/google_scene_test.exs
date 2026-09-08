defmodule Compos.GoogleSceneTest do
  use ExUnit.Case, async: false
  alias Compos.Core.{Session, Editor, Buffer, KeyDispatch}

  defp eval!(code) do
    assert {:ok, value} = Session.eval(code)
    value
  end

  setup do
    eval!("(define *google-test-saved-transport* *google-transport*)")
    eval!("(define *google-test-saved-submit* *google-submit-transport*)")
    eval!(~S[(set! *google-submit-transport* (lambda (a r raw k)
      (google-request a (plist-get r 'service) (plist-get r 'method) (plist-get r 'path)
        (plist-get r 'params) (plist-get r 'body) k)))])
    eval!("(define *google-test-calls* '())")

    eval!(~S'''
    (set! *google-transport*
      (lambda (account method url params body k)
        (set! *google-test-calls* (cons (list account method url params body) *google-test-calls*))
        (k '(ok #t data (files ((id "file1" name "First document" mimeType "application/vnd.google-apps.document")) nextPageToken "next")))))
    ''')

    Editor.minibuffer_close()
    Editor.set_pending([])

    on_exit(fn ->
      Session.eval("(set! *google-transport* *google-test-saved-transport*)")
      Session.eval("(set! *google-submit-transport* *google-test-saved-submit*)")
      Session.eval(~S[(set! google-default-account "")])
      Editor.minibuffer_close()
      Editor.set_pending([])

      for name <- Compos.Core.list_buffers(),
          is_binary(name),
          String.starts_with?(name, "*Google") do
        Compos.Core.kill_buffer(name)
      end
    end)

    :ok
  end

  test "workspace c opens the OAuth consent URL through the browser API after mode restore" do
    eval!("(define *google-test-client-original* google--client)")
    eval!("(define *google-test-oauth-original* google-oauth-start!)")
    eval!("(define *google-test-tab-original* tab-open)")

    on_exit(fn ->
      Session.eval("(set! google--client *google-test-client-original*)")
      Session.eval("(set! google-oauth-start! *google-test-oauth-original*)")
      Session.eval("(set! tab-open *google-test-tab-original*)")
    end)

    eval!(~S[(set! google--client (lambda () "test-client"))])
    eval!(~S[(set! google-oauth-start! (lambda (client scopes)
      '(ok #t url "https://accounts.google.com/o/oauth2/v2/auth?test=1")))])
    eval!(~S[(define *google-test-opened-url* #f)])
    eval!(~S[(set! tab-open (lambda (url) (set! *google-test-opened-url* url)))])
    eval!(~S[(run-command "google")])
    eval!(~S[(set-mode! "google-mode")])
    KeyDispatch.handle_key("c")

    assert eval!("*google-test-opened-url*") ==
             ~s["https://accounts.google.com/o/oauth2/v2/auth?test=1"]
  end

  test "bundled package opens account-owned lists and restores their mode" do
    eval!(~S[(google-open "alpha" "docs")])
    first = Editor.current_buffer()
    assert Buffer.text(first) =~ "First document"
    assert Buffer.get_local(first, "google-account") == "alpha"
    eval!(~S[(google-open "beta" "docs")])
    second = Editor.current_buffer()
    refute first == second
    assert Buffer.get_local(first, "google-account") == "alpha"
    assert Buffer.get_local(second, "google-account") == "beta"
    eval!(~S[(set-mode! "google-service-mode")])
    assert Buffer.get_local(second, "google-account") == "beta"
    assert Buffer.text(second) =~ "First document"
  end

  test "search escapes Drive literals and pagination reaches the API" do
    eval!(~S[(google-open "alpha" "docs")])
    eval!(~S[(buffer-set-local! (current-buffer) 'google-query "O'Reilly\\notes")])
    eval!(~S[(run-command "google-refresh")])
    assert eval!("(plist-get (nth 3 (car *google-test-calls*)) 'q)") =~ "O\\\\'Reilly"
    eval!(~S[(local-set-key "<f9>" "google-next-page")])
    KeyDispatch.handle_key("<f9>")
    assert eval!("(plist-get (nth 3 (car *google-test-calls*)) 'pageToken)") == ~s["next"]
    eval!(~S[(run-command "google-first-page")])
    assert eval!("(plist-get (nth 3 (car *google-test-calls*)) 'pageToken)") == "#f"
  end

  test "failed refresh preserves rows and displays an error" do
    eval!(~S[(google-open "alpha" "docs")])
    buf = Editor.current_buffer()

    eval!(
      ~S[(set! *google-transport* (lambda (a m u p b k) (k '(ok #f error "Permission denied"))))]
    )

    eval!(~S[(run-command "google-refresh")])
    assert Buffer.text(buf) =~ "First document"
    assert Buffer.text(buf) =~ "Permission denied"
  end

  test "request drafts bind their original account and never execute on restore" do
    eval!(~S[(google-draft "alpha" (car google--operations))])
    buf = Editor.current_buffer()
    request = Jason.decode!(Buffer.text(buf))
    assert request["service"] == "docs"
    assert request["body"]["title"] == "Untitled"
    eval!(~S[(set! google-default-account "beta")])
    eval!(~S[(set-mode! "google-request-mode")])
    assert eval!("*google-test-calls*") == "()"
    eval!(~S[(local-set-key "<f9>" "google-submit")])
    KeyDispatch.handle_key("<f9>")
    assert eval!("*google-test-calls*") == "()"
    KeyDispatch.handle_key("y")
    assert eval!("(car (car *google-test-calls*))") == ~s["alpha"]
  end

  test "mail drafts encode unicode and keep header injection out of MIME" do
    json =
      eval!(
        ~S[(json-encode (google-mail-draft "alpha" "you@example.com\r\nBcc:bad@example.com" "Hello 🌏" "Unicode body λ"))]
      )

    {:ok, inner} = Jason.decode(json)
    op = Jason.decode!(inner)
    mime = Base.url_decode64!(op["body"]["message"]["raw"], padding: false)
    refute mime =~ "\r\nBcc:"
    assert mime =~ "Content-Type: text/plain; charset=UTF-8"
    assert mime =~ Base.encode64("Unicode body λ")
    assert op["path"] == "/users/me/drafts"
  end

  test "Gmail metadata hydration preserves message order when responses arrive out of order" do
    eval!(~S[(define *google-test-pending* '())])
    eval!(~S[(define *google-test-mail-rows* #f)])
    eval!(~S[(set! *google-transport* (lambda (a m u p b k)
      (set! *google-test-pending* (cons k *google-test-pending*))))])
    eval!(~S[(google--mail-rows "alpha" '((id "first") (id "second"))
      (lambda (rows) (set! *google-test-mail-rows* rows)))])

    eval!(
      ~S[((car *google-test-pending*) '(ok #t data (payload
      (headers ((name "Subject" value "Second message") (name "From" value "second@example.com"))))))]
    )

    assert eval!("*google-test-mail-rows*") == "#f"

    eval!(
      ~S[((cadr *google-test-pending*) '(ok #t data (payload
      (headers ((name "Subject" value "First message") (name "From" value "first@example.com"))))))]
    )

    assert eval!("(map google--row-title *google-test-mail-rows*)") ==
             ~s[("First message" "Second message")]

    assert eval!("(map google--row-detail *google-test-mail-rows*)") ==
             ~s[("first@example.com" "second@example.com")]
  end

  test "all templates resolve a real service and declare public metadata" do
    assert eval!("(length google--operations)") != "0"

    assert eval!(
             "(null? (filter (lambda (op) (not (google--service (plist-get op 'service)))) google--operations))"
           ) == "#t"

    assert eval!(~S[(plist-get (catalog-entry 'function "google-request") 'domain)]) ==
             ~s["google"]
  end

  test "a later search wins when older requests finish last" do
    eval!(~S[(define *google-test-pending* '())])

    eval!(
      ~S[(set! *google-transport* (lambda (a m u p b k) (set! *google-test-pending* (cons k *google-test-pending*))))]
    )

    eval!(~S[(google-open "alpha" "docs")])
    buf = Editor.current_buffer()
    eval!(~S[(buffer-set-local! (current-buffer) 'google-query "new search")])
    eval!(~S[(run-command "google-refresh")])
    eval!(~S[((car *google-test-pending*) '(ok #t data (files ((id "new" name "New result")))))])

    eval!(
      ~S[((cadr *google-test-pending*) '(ok #t data (files ((id "old" name "Stale result")))))]
    )

    assert Buffer.text(buf) =~ "New result"
    refute Buffer.text(buf) =~ "Stale result"
  end

  test "selected document IDs and revisions populate edit requests" do
    eval!(
      ~S[(google--show-result "alpha" "docs" "Document" '(documentId "doc-123" revisionId "revision-7"))]
    )

    result =
      eval!(
        ~S[(json-encode (google--context-operation (cadr google--operations) (current-buffer)))]
      )

    {:ok, json} = Jason.decode(result)
    op = Jason.decode!(json)
    assert op["path"] == "/documents/doc-123:batchUpdate"
    assert op["body"]["writeControl"]["requiredRevisionId"] == "revision-7"
  end

  test "mail, contacts, task lists and calendars have distinct list contracts" do
    for {service, parent, path, key} <- [
          {"gmail", false, "/users/me/messages", "messages"},
          {"contacts", false, "/people/me/connections", "connections"},
          {"tasks", false, "/users/@me/lists", "items"},
          {"tasks", "list-a", "/lists/list-a/tasks", "items"},
          {"calendar", false, "/users/me/calendarList", "items"},
          {"calendar", "a@example.com", "/calendars/a%40example.com/events", "items"}
        ] do
      eval!(~S[(buffer-create "*Google contracts*")])

      eval!(
        "(buffer-set-local! \"*Google contracts*\" 'google-service #{Jason.encode!(service)})"
      )

      eval!(
        "(buffer-set-local! \"*Google contracts*\" 'google-parent #{if parent, do: Jason.encode!(parent), else: "#f"})"
      )

      result = eval!(~S[(json-encode (google--list-spec "*Google contracts*"))])
      {:ok, json} = Jason.decode(result)
      spec = Jason.decode!(json)
      assert spec["path"] == path
      assert spec["key"] == key
    end
  end
end
