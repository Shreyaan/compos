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

  test "headless file functions preserve account, pagination, and fresh move parents" do
    eval!("(define *google-test-native-original* google-http!)")
    on_exit(fn -> Session.eval("(set! google-http! *google-test-native-original*)") end)

    eval!(
      ~S[(set! google-http! (lambda (a m u p b)
      (set! *google-test-calls* (cons (list a m u p b) *google-test-calls*))
      '(ok #t status 200 data (id "file1" name "Document" mimeType "application/vnd.google-apps.document" parents ("old-parent")))))]
    )

    source = Editor.current_buffer()
    eval!(~S[(google-files "alpha" "root" "O'Reilly" "page2" "docs")])
    assert eval!("(plist-get (nth 3 (car *google-test-calls*)) 'pageToken)") == ~s["page2"]

    assert eval!("(plist-get (nth 3 (car *google-test-calls*)) 'q)") =~
             "application/vnd.google-apps.document"

    eval!(~S[(google-file-move! "beta" "file1" "new-parent")])
    assert eval!("(car (car *google-test-calls*))") == ~s["beta"]

    assert eval!("(plist-get (nth 3 (car *google-test-calls*)) 'removeParents)") ==
             ~s["old-parent"]

    eval!(~S[(google-file-copy! "alpha" "file1" "root" "Copy")])
    assert eval!("(plist-get (nth 4 (car *google-test-calls*)) 'name)") == ~s["Copy"]
    eval!(~S[(google-file-rename! "alpha" "file1" "Renamed")])
    assert eval!("(plist-get (nth 4 (car *google-test-calls*)) 'name)") == ~s["Renamed"]
    eval!(~S[(google-folder-create! "alpha" "root" "Folder")])
    assert eval!("(plist-get (nth 4 (car *google-test-calls*)) 'parents)") == ~s[("root")]
    eval!(~S[(google-file-trash! "alpha" "file1")])
    assert eval!("(plist-get (nth 4 (car *google-test-calls*)) 'trashed)") == "#t"
    assert Editor.current_buffer() == source
    assert Editor.all_minibuffers() == []

    assert eval!(~S[(plist-get (catalog-entry 'function "google-file-trash!") 'effects)]) =~
             "destroy"
  end

  test "headless move stops on lookup failure and does not mutate a same-parent file" do
    eval!("(define *google-test-native-original* google-http!)")
    on_exit(fn -> Session.eval("(set! google-http! *google-test-native-original*)") end)
    eval!(~S[(set! google-http! (lambda (a m u p b)
      (set! *google-test-calls* (cons (list a m u p b) *google-test-calls*))
      '(ok #f status 403 error "Permission denied")))])
    assert eval!(~S[(plist-get (google-file-move! "alpha" "file1" "dest") 'ok)]) == "#f"
    assert eval!("(length *google-test-calls*)") == "1"
    eval!(~S[(set! google-http! (lambda (a m u p b)
      (set! *google-test-calls* (cons (list a m u p b) *google-test-calls*))
      '(ok #t data (name "File" parents ("dest")))))])
    eval!(~S[(google-file-move! "alpha" "file1" "dest")])

    assert eval!(
             ~S[(length (filter (lambda (call) (equal? (cadr call) "PATCH")) *google-test-calls*))]
           ) == "0"
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

  test "Drive opens as a directory and RET and up retain account and folder ownership" do
    eval!(
      ~S[(set! *google-transport* (lambda (a m u p b k)
      (set! *google-test-calls* (cons (list a m u p b) *google-test-calls*))
      (k '(ok #t data (files ((id "folder1" name "Projects" mimeType "application/vnd.google-apps.folder")))))))]
    )

    eval!(~S[(google-open "alpha" "drive")])
    root = Editor.current_buffer()
    assert Buffer.get_local(root, "mode-name") == "Dired"
    assert Buffer.text(root) =~ "Projects/"
    assert eval!("(plist-get (nth 3 (car *google-test-calls*)) 'q)") =~ "'root' in parents"
    KeyDispatch.handle_key("RET")
    child = Editor.current_buffer()
    assert Buffer.get_local(child, "google-parent") == "folder1"
    assert Buffer.get_local(child, "google-account") == "alpha"
    assert Buffer.text(child) =~ "My Drive/Projects"
    eval!(~S[(set-mode! "google-drive-mode")])
    KeyDispatch.handle_key("^")
    assert Editor.current_buffer() == root
    KeyDispatch.handle_key("m")
    KeyDispatch.handle_key("x")
    KeyDispatch.handle_key("y")

    assert eval!(
             ~S[(length (filter (lambda (call) (equal? (cadr call) "PATCH")) *google-test-calls*))]
           ) == "1"

    assert eval!(
             ~S[(plist-get (nth 4 (car (filter (lambda (call) (equal? (cadr call) "PATCH")) *google-test-calls*))) 'trashed)]
           ) == "#t"

    assert Buffer.get_local(root, "google-account") == "alpha"
  end

  test "all Google file indexes share dired keys and copy via a named folder picker" do
    for service <- ["drive", "docs", "sheets", "slides", "forms", "script"] do
      eval!("(google-open \"alpha\" #{Jason.encode!(service)})")
      assert Buffer.get_local(Editor.current_buffer(), "mode-name") == "Dired"
    end

    eval!(~S[(google-open "alpha" "docs")])
    source = Editor.current_buffer()
    KeyDispatch.handle_key("m")
    KeyDispatch.handle_key("C")
    KeyDispatch.handle_key("RET")

    assert eval!(
             ~S[(length (filter (lambda (call) (equal? (cadr call) "POST")) *google-test-calls*))]
           ) == "0"

    KeyDispatch.handle_key("y")

    assert eval!(
             ~S[(length (filter (lambda (call) (equal? (cadr call) "POST")) *google-test-calls*))]
           ) == "1"

    assert eval!(
             ~S[(nth 2 (car (filter (lambda (call) (equal? (cadr call) "POST")) *google-test-calls*)))]
           ) ==
             ~s["https://www.googleapis.com/drive/v3/files/file1/copy"]

    assert Buffer.get_local(source, "google-account") == "alpha"
  end

  test "R renames through prompts and move uses Drive parent updates" do
    eval!(~S[(google-open "alpha" "sheets")])
    source = Editor.current_buffer()
    KeyDispatch.handle_key("R")
    Enum.each(String.graphemes("Rename"), &KeyDispatch.handle_key/1)
    KeyDispatch.handle_key("RET")
    Enum.each(String.graphemes("Renamed sheet"), &KeyDispatch.handle_key/1)
    KeyDispatch.handle_key("RET")
    KeyDispatch.handle_key("y")

    assert eval!(
             ~S[(plist-get (nth 4 (car (filter (lambda (call) (equal? (cadr call) "PATCH")) *google-test-calls*))) 'name)]
           ) == ~s["Renamed sheet"]

    eval!(~S[(define *google-test-folder-picker* google--folder-pick)])
    on_exit(fn -> Session.eval("(set! google--folder-pick *google-test-folder-picker*)") end)
    eval!(~S[(set! google--folder-pick (lambda (account k) (k "destination" "Projects")))])

    eval!(
      ~S[(google--file-transfer (current-buffer) '((id "file1" name "Sheet" parents ("old-folder"))) #f)]
    )

    KeyDispatch.handle_key("y")

    assert eval!(
             ~S[(plist-get (nth 3 (car (filter (lambda (call) (equal? (cadr call) "PATCH")) *google-test-calls*))) 'addParents)]
           ) == ~s["destination"]

    assert eval!(
             ~S[(plist-get (nth 3 (car (filter (lambda (call) (equal? (cadr call) "PATCH")) *google-test-calls*))) 'removeParents)]
           ) == ~s["old-folder"]

    assert Buffer.get_local(source, "google-account") == "alpha"
  end

  test "cancelled trash makes no request and failed trash preserves its flag" do
    eval!(~S[(google-open "alpha" "slides")])
    source = Editor.current_buffer()
    KeyDispatch.handle_key("d")
    KeyDispatch.handle_key("x")
    KeyDispatch.handle_key("n")

    assert eval!(
             ~S[(length (filter (lambda (call) (equal? (cadr call) "PATCH")) *google-test-calls*))]
           ) == "0"

    eval!(
      ~S[(set! *google-transport* (lambda (a m u p b k) (k '(ok #f error "Permission denied"))))]
    )

    KeyDispatch.handle_key("x")
    KeyDispatch.handle_key("y")
    assert eval!(~S[(list-marked (current-buffer) "D")]) == ~s[("file1")]
    assert Buffer.get_local(source, "google-file-busy") == false
  end

  test "Google Dired has an unmarkable parent row and reapplies the real mode" do
    eval!(~S[(google-open "alpha" "docs")])
    buf = Editor.current_buffer()
    assert Buffer.get_local(buf, "mode-name") == "Dired"
    assert Buffer.text(buf) =~ ".."
    eval!(~S[(set-mode! "Dired")])
    eval!(~S[(list-goto-index! (current-buffer) 0)])
    assert eval!(~S[(plist-get (list-current (current-buffer)) 'google-up)]) == "#t"
    KeyDispatch.handle_key("m")
    assert eval!(~S[(list-marks (current-buffer))]) == "()"
    eval!(~S[(list-goto-index! (current-buffer) 0)])
    KeyDispatch.handle_key("RET")
    assert Buffer.get_local(Editor.current_buffer(), "google-service") == "drive"
    assert Buffer.get_local(Editor.current_buffer(), "mode-name") == "Dired"
  end

  test "Google directories stay in one window and q q pops history without killing them" do
    eval!(~S[(buffer-create "*Google origin*")])
    eval!(~S[(switch-to-buffer-here! "*Google origin*")])
    eval!(~S[(set-window-prev-buffers! (active-window) '())])
    window = eval!("(active-window)")
    windows = eval!("(length (window-list))")
    eval!(~S[(google-open "alpha" "drive")])
    root = Editor.current_buffer()
    eval!(~S[(google-open "alpha" "drive" "child")])
    child = Editor.current_buffer()
    assert eval!("(active-window)") == window
    assert eval!("(length (window-list))") == windows
    KeyDispatch.handle_key("q")
    assert Editor.current_buffer() == root
    KeyDispatch.handle_key("q")
    assert Editor.current_buffer() == "*Google origin*"
    assert eval!("(active-window)") == window
    assert eval!("(buffer-exists? #{Jason.encode!(root)})") == "#t"
    assert eval!("(buffer-exists? #{Jason.encode!(child)})") == "#t"
  end

  test "filesystem Dired still navigates without a provider" do
    dir = Path.join(System.tmp_dir!(), "google-dired-local-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "child"))

    on_exit(fn ->
      for name <- Compos.Core.list_buffers(), is_binary(name), String.starts_with?(name, dir) do
        Compos.Core.kill_buffer(name)
      end

      File.rm_rf!(dir)
    end)

    eval!("(dired-open #{Jason.encode!(dir)})")
    assert Buffer.get_local(Editor.current_buffer(), "mode-name") == "Dired"
    assert Buffer.get_local(Editor.current_buffer(), "dired-provider") in [nil, false]
    eval!(~S[(list-goto-index! (current-buffer) 0)])
    KeyDispatch.handle_key("^")
    assert Buffer.get_local(Editor.current_buffer(), "dired-dir") != dir
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
