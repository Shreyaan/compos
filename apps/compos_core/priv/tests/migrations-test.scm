;;; migrations-test.scm --- one-shot buffer migrations run once and stamp.

(domain! 'testing)
(effects! '(write))

(define t--mg-buf "zz-migrations")

(define (t--mg! text)
  (test-buffer! t--mg-buf text)
  (buffer-set-local! t--mg-buf 'migrations #f)
  t--mg-buf)

(define (t--mg-done!) (when (buffer-known? t--mg-buf) (buffer-kill! t--mg-buf)))

(deftest 'a-migration-runs-once-per-buffer-and-is-stamped
  "the pass runs what the buffer has not seen; a second pass runs nothing"
  (lambda ()
    (let ((buf (t--mg! ""))
          (runs 0)
          (held *buffer-migrations*))
      (define-buffer-migration! 'zz-count "2026-09-19"
        (lambda (b) (set! runs (+ runs 1))))
      (define-buffer-migration! 'zz-throws "2026-09-19"
        (lambda (b) (error "a migration that fails")))
      (let ((ran (migrate-buffer! buf)))
        (check-true! (and (member 'zz-count ran) #t) "the new migration ran")
        (check-true! (and (member 'zz-throws ran) #t) "the failing one was tried")
        (check-equal! runs 1 "once")
        (check-true! (and (member 'zz-count (buffer-migrations-done buf)) #t) "and is stamped")
        (check-true! (and (member 'zz-throws (buffer-migrations-done buf)) #t)
                     "a failure is stamped too: it does not run on every restore"))
      (check-equal! (migrate-buffer! buf) '() "the second pass runs nothing")
      (check-equal! runs 1 "still once")
      (set! *buffer-migrations* held)
      (t--mg-done!))))

(deftest 'the-chat-record-migration-reads-the-old-turn-pairs-once
  "'chat-turns becomes the record and the old local goes"
  (lambda ()
    (let ((buf (t--mg! "")))
      (buffer-set-local! buf 'chat-turns '(("user" "hi") ("assistant" "hello")))
      (migrate-buffer! buf)
      (check-equal! (length (buffer-local buf 'chat-wire-turns)) 2 "two turns in the record")
      (check-equal! (plist-get (car (buffer-local buf 'chat-wire-turns)) 'role) "user" "in order")
      (check-false! (buffer-local buf 'chat-turns) "the old local is gone")
      (t--mg-done!))))

(deftest 'the-marker-migration-strips-the-marker-and-finds-a-missing-mark
  "a chat from before the marker left the input loses the bytes; one with no mark gets it"
  (lambda ()
    (let ((buf (t--mg! (string-append "old talk" *chat-input-marker* "draft"))))
      (migrate-buffer! buf)
      (check-equal! (buffer-local buf 'agent-saved-mark) 8 "the mark stands after the talk")
      (check-equal! (buffer-text buf) "old talkdraft" "the marker bytes are gone, the draft stays")
      (check-equal! (buffer-local buf 'agent-marker-bytes) 0 "and the input starts at the mark")
      (check-equal! (migrate-buffer! buf) '() "the pass is stamped")
      (t--mg-done!))))

(deftest 'the-companion-migration-turns-companion-of-into-a-group
  "both ends get the group tag"
  (lambda ()
    (let ((buf (t--mg! ""))
          (doc (test-buffer! "zz-migrations-doc" "")))
      (buffer-set-local! doc 'group #f)
      (buffer-set-local! buf 'companion-of doc)
      (migrate-buffer! buf)
      (check-equal! (buffer-local buf 'group) doc "the chat joins the document's group")
      (check-equal! (buffer-local doc 'group) doc "and the document names it too")
      (buffer-kill! doc)
      (t--mg-done!))))

(deftest 'the-shell-mode-migration-renames-the-mode
  "an old desktop says shell-mode; the buffer wakes as term-mode"
  (lambda ()
    (let ((buf (t--mg! "")))
      (buffer-set-local! buf 'mode-name "shell-mode")
      (migrate-buffer! buf)
      (check-equal! (buffer-local buf 'mode-name) "term-mode" "renamed")
      (t--mg-done!))))
