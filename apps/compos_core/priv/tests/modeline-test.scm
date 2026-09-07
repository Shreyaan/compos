;;; modeline-test.scm — buffer modelines keep compact names.

(domain! 'testing)
(effects! '(write execute))

(define t--modeline-root
  (string-append (compos-home) "/zz-modeline-project"))

(define (t--modeline-reset!)
  (shell-command->string (string-append "rm -rf " t--modeline-root)))

(deftest 'a-project-file-keeps-a-project-relative-buffer-modeline-name
  "the buffer modeline stays compact while the frame bar owns the full path"
  (lambda ()
    (t--modeline-reset!)
    (make-directory! (string-append t--modeline-root "/.git"))
    (let ((path (string-append t--modeline-root "/lib/example.scm")))
      (make-directory! (string-append t--modeline-root "/lib"))
      (write-file! path "(display \"example\")\n")
      (visit path)
      (dashboard--sync! path)
      (check-equal! (buffer-modeline-name path) "lib/example.scm"
                    "the buffer modeline policy returns project coordinates")
      (check-equal! (buffer-local path 'modeline-name) "lib/example.scm"
                    "the rendered buffer modeline stores the compact name")
      (buffer-kill! path))
    (t--modeline-reset!)))

(deftest 'a-non-file-buffer-keeps-its-buffer-name-in-the-modeline
  "the file path policy does not rename a non-file buffer"
  (lambda ()
    (let ((buf "*zz-modeline-non-file*"))
      (test-buffer! buf "")
      (check-equal! (buffer-modeline-name buf) buf
                    "the non-file buffer keeps its name")
      (buffer-kill! buf))))

(deftest 'a-chat-shows-its-working-directory-in-the-modeline
  "the chat modeline shows the directory where its tools run"
  (lambda ()
    (let ((buf "*chat:zz-modeline-directory*")
          (dir (string-append (compos-home) "/")))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "chat-mode")
      (buffer-set-local! buf 'default-directory dir)
      (dashboard--sync! buf)
      (check-equal! (buffer-directory buf) dir
                    "the chat has its own working directory")
      (check-equal! (buffer-local buf 'modeline-project)
                    (abbreviate-file-name dir)
                    "the compact modeline shows that directory")
      (buffer-kill! buf))))

;; the dashboard line pulls the summary and the jj line from state, so a
;; buffer with no file shows both when it has them
(define (t--dseg-value blocks key)
  (let loop ((bs blocks))
    (cond ((null? bs) #f)
          ((and (pair? (car bs))
                (equal? (plist-get (car bs) 'tag) "div")
                (let ((kids (plist-get (car bs) 'children)))
                  (and (pair? kids)
                       (equal? (plist-get (car kids) 'text) key))))
           (cadr (car (plist-get (cadr (plist-get (car bs) 'children)) 'segs))))
          (else (loop (cdr bs))))))

(deftest 'a-chat-shows-its-running-summary-in-the-dashboard-line
  "the summary segment carries the chat-summary local; a chat without one shows no segment"
  (lambda ()
    (let ((buf "*chat:zz-modeline-summary*"))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "chat-mode")
      (check-equal! (t--dseg-value (dashboard-line-blocks buf) "summary") #f
                    "no summary yet, no segment")
      (buffer-set-local! buf 'chat-summary "The user is testing the bar.")
      (let* ((blocks (dashboard-line-blocks buf))
             (wide (car (reverse blocks)))
             (kids (plist-get wide 'children)))
        (check-equal! (length kids) 1
                      "the summary has no redundant label")
        (check-equal! (cadr (car (plist-get (car kids) 'segs)))
                      "The user is testing the bar."
                      "the segment shows the paragraph"))
      ;; the summary takes the one wide slot; the jj line steps back
      (let ((dir "/zz-modeline-sum-repo/") (root "/zz-modeline-sum-repo")
            (lines *jj-lines*) (roots *jj-dir-roots*))
        (buffer-set-local! buf 'default-directory dir)
        (set! *jj-dir-roots* (cons (list dir root) *jj-dir-roots*))
        (set! *jj-lines* (cons (list root "jj: open") *jj-lines*))
        (check-equal! (t--dseg-value (dashboard-line-blocks buf) "jj") #f
                      "no jj segment beside a summary")
        (set! *jj-lines* lines)
        (set! *jj-dir-roots* roots))
      (buffer-kill! buf))))

(deftest 'a-chat-without-a-file-shows-the-jj-line-of-its-directory
  "the jj segment comes from the per-root cache through the buffer's directory; a plain list does not live in a repo"
  (lambda ()
    (let ((buf "*chat:zz-modeline-jj*")
          (dir "/zz-modeline-jj-repo/sub/")
          (root "/zz-modeline-jj-repo")
          (lines *jj-lines*)
          (roots *jj-dir-roots*))
      (test-buffer! buf "")
      (buffer-set-local! buf 'default-directory dir)
      (set! *jj-dir-roots* (cons (list dir root) *jj-dir-roots*))
      (set! *jj-lines* (cons (list root "jj: the open change") *jj-lines*))
      (check-equal! (jj-modeline-line buf) #f
                    "a buffer that is not a file, a listing, or a chat shows no jj line")
      (buffer-set-local! buf 'mode-name "chat-mode")
      (check-equal! (jj-modeline-line buf) "jj: the open change"
                    "the line comes from the cache, not from a shell call")
      (check-equal! (t--dseg-value (dashboard-line-blocks buf) "jj") "jj: the open change"
                    "the dashboard line shows it")
      (set! *jj-lines* lines)
      (set! *jj-dir-roots* roots)
      (buffer-kill! buf))))

(deftest 'a-chats-title-is-the-first-summary-and-does-not-move
  "the first label the running summary writes becomes the title; later paragraphs move the summary only, and the bar and the list rows show the title"
  (lambda ()
    (let ((buf "*chat:zz-modeline-title*"))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "chat-mode")
      (buffer-set-local! buf 'chat-turn-active #t)   ; no archive write here
      (buffer-set-local! buf 'agent-saved-mark 0)
      (buffer-set-local! buf 'agent-blocks '())
      (chat-summary-land! buf "Adding titles to chats.")
      (chat-summary-land! buf "Rewriting the dashboard segment.")
      (check-equal! (buffer-local buf 'chat-title) "Adding titles to chats."
                    "the title is the label the chat wrote first")
      (check-equal! (chat-title-of buf) "Adding titles to chats."
                    "and a second paragraph does not move it")
      (check-equal! (buffer-local buf 'chat-summary) "Rewriting the dashboard segment."
                    "the running summary is still the latest")
      (let* ((blocks (dashboard-line-blocks buf))
             (wide (car (reverse blocks)))
             (kids (plist-get wide 'children)))
        (check-equal! (cadr (car (plist-get (car kids) 'segs)))
                      "Adding titles to chats."
                      "the bar names the chat, not what it is doing now"))
      (check-equal! (chat-prompt-label buf) "Adding titles to chats."
                    "and every list row leads with the same name")
      (buffer-kill! buf))))

(deftest 'the-summary-log-interleaves-summaries-and-jj-lines-by-time
  "every paragraph lands in chat-summary-log; the entries merge with the repo's line history in time order"
  (lambda ()
    (let ((buf "*chat:zz-modeline-log*")
          (dir "/zz-modeline-log-repo/") (root "/zz-modeline-log-repo")
          (lines *jj-lines*) (roots *jj-dir-roots*) (hist *jj-history*))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "chat-mode")
      (buffer-set-local! buf 'chat-turn-active #t)   ; no archive write here
      (buffer-set-local! buf 'agent-saved-mark 0)
      (buffer-set-local! buf 'agent-blocks '())
      (buffer-set-local! buf 'default-directory dir)
      (set! *jj-dir-roots* (cons (list dir root) *jj-dir-roots*))
      (set! *jj-lines* (cons (list root "jj: second") *jj-lines*))
      (set! *jj-history* (list (list root 2000 "jj: second") (list root 1000 "jj: first")))
      (buffer-set-local! buf 'chat-summary "from before the log")
      (check-equal! (map caddr (buffer-summary-log-entries buf))
                    '("from before the log" "jj: first" "jj: second")
                    "a chat from before the log shows its one paragraph, undated")
      (chat-turn-push! buf "user" "the request")
      (chat-summary-land! buf "first paragraph")
      (chat-turn-push! buf "assistant" "the answer")
      (chat-summary-land! buf "second paragraph")
      (check-equal! (buffer-local buf 'chat-summary) "second paragraph"
                    "the bar's local is the latest")
      (check-equal! (map cadr (buffer-local buf 'chat-summary-log))
                    '("second paragraph" "first paragraph")
                    "the log keeps every paragraph, newest first")
      (check-equal! (map (lambda (turn) (plist-get turn 'role)) (chat-record buf))
                    '("status" "assistant" "status" "user")
                    "summary statuses keep their transcript position")
      (check-equal! (map (lambda (turn) (plist-get turn 'role)) (chat-model-record buf))
                    '("assistant" "user")
                    "status turns are absent from model-facing history")
      (check-equal!
        (map (lambda (turn) (plist-get turn 'role))
             (chat-drop-oldest-conversation-turns (chat-record buf) 1))
        '("status" "assistant" "status")
        "compaction drops conversation turns without consuming statuses")
      (check-equal!
        (map car (chat-parse-transcript
                   (string-append "\n"
                     (chat-turns-text (reverse (chat-record buf))))))
        '("user" "status" "assistant" "status")
        "the archive transcript preserves status ordering")
      (check-false! (string-contains? (chat-model-flatten buf) "first paragraph")
                    "ACP seed text excludes status turns too")
      (check-equal! (map caddr (buffer-local buf 'agent-blocks))
                    '("status" "status")
                    "each summary is a distinct rendered status block")
      (check-false! (string-contains? (chat-summary--tail buf) "first paragraph")
                    "the next running summary does not summarize old statuses")
      (let ((entries (buffer-summary-log-entries buf)))
        (check-equal! (map cadr entries) '(jj jj summary summary)
                      "old jj lines come first, today's summaries after")
        (check-equal! (caddr (car entries)) "jj: first" "oldest first"))
      (let ((markdown (buffer-summary-log--markdown buf)))
        (check-false! (string-contains? markdown "** summary")
                      "summary rows do not repeat the summary label")
        (check-true! (string-contains? markdown "** jj")
                     "jj rows keep their distinguishing label"))
      (check-equal! (plist-get (car (reverse (dashboard-line-blocks buf))) 'click)
                    "summary-log"
                    "the wide segment opens the log")
      (set! *jj-lines* lines)
      (set! *jj-dir-roots* roots)
      (set! *jj-history* hist)
      (buffer-kill! buf))))

;; The companion directory is chat identity: the chat-mode setup stamps it
;; once from the directory the chat was born in, and no later change to the
;; group or the born directory moves it.
(deftest 'a-chat-stamps-its-companion-directory-once-at-birth
  "the chat's directory is the git root of the spawner's directory, fixed at birth"
  (lambda ()
    (t--modeline-reset!)
    (make-directory! (string-append t--modeline-root "/lib"))
    (shell-command->string "git init -q" t--modeline-root)
    (let ((buf "*chat:zz-modeline-stamp*")
          (born (string-append t--modeline-root "/lib/")))
      (test-buffer! buf "")
      (buffer-set-local! buf 'default-directory born)
      (with-current-buffer buf (lambda () (set-mode! "chat-mode")))
      (check-equal! (buffer-local buf 'chat-directory)
                    (string-append (git-root born) "/")
                    "the setup stamps the git root of the born directory")
      (check-equal! (buffer-directory buf) (buffer-local buf 'chat-directory)
                    "the chat works in that directory")
      ;; the born directory moves; the companion does not
      (buffer-set-local! buf 'default-directory (string-append (compos-home) "/"))
      (with-current-buffer buf (lambda () (set-mode! "chat-mode")))
      (check-equal! (buffer-directory buf) (string-append (git-root born) "/")
                    "a second setup keeps the stamp")
      (buffer-kill! buf))
    (t--modeline-reset!)))

(deftest 'a-chat-outside-a-repo-stamps-its-born-directory
  "with no git root the born directory itself is the companion directory"
  (lambda ()
    (let ((buf "*chat:zz-modeline-stamp-plain*")
          (born (string-append (compos-home) "/zz-modeline-plain/")))
      (make-directory! born)
      (test-buffer! buf "")
      (buffer-set-local! buf 'default-directory born)
      (with-current-buffer buf (lambda () (set-mode! "chat-mode")))
      (check-equal! (buffer-local buf 'chat-directory) born
                    "the born directory is the stamp")
      (buffer-kill! buf))))

;; A silent buffer costs nothing: post-command! rebuilds the dashboard of
;; the buffer the command ran in, and of no other buffer.
(deftest 'post-command-syncs-the-dashboard-of-the-current-buffer-only
  "an inactive buffer's dashboard line stays as it was after a command elsewhere"
  (lambda ()
    (let ((here "*zz-modeline-here*")
          (other "*zz-modeline-other*"))
      (test-buffer! here "")
      (test-buffer! other "")
      (dashboard--sync! other)
      (let ((before (buffer-local other 'dashboard-line)))
        (buffer-set-local! other 'minor-modes '("zz-silent-mode"))
        (with-current-buffer here (lambda () (post-command!)))
        (check-equal! (buffer-local other 'dashboard-line) before
                      "the other buffer's line did not rebuild")
        (check-true! (string? (buffer-local here 'dashboard-line))
                     "the current buffer's line did")
        (dashboard--sync! other)
        (check-true! (string-contains? (buffer-local other 'dashboard-line) "zz-silent")
                     "a sync asked for by name rebuilds it"))
      (buffer-kill! here)
      (buffer-kill! other))))
