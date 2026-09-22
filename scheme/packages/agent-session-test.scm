;;; agent-session-test.scm --- queued messages: preview, walk, delete one.
;;;
;;; A message sent mid-turn is queued, not run, and shows as a muted row
;;; above the input (chat-view-tree, 'chat-queued). Up on an empty draft
;;; used to skip straight past those rows into the chat's own sent
;;; history, so the only way to see or drop one was chat-unqueue guessing
;;; "the newest" blind. Up now walks the queued rows first, newest to
;;; oldest, then falls through into sent history; chat-unqueue removes
;;; whichever row that walk is standing on.

(domain! 'testing)
(effects! '(read))

(define t--as-buf "*zz-agent-session*")

(define (t--as-chat! queued)
  (test-buffer! t--as-buf "transcript\n")
  (buffer-set-local! t--as-buf 'mode-name "chat-mode")
  (buffer-set-local! t--as-buf 'render-mode "agent")
  (buffer-set-local! t--as-buf 'agent-saved-mark (buffer-size t--as-buf))
  (buffer-set-local! t--as-buf 'chat-history-ring '())
  (chat-history-reset! t--as-buf)
  (buffer-set-local! t--as-buf 'chat-queued-pos #f)
  (buffer-set-local! t--as-buf 'chat-queued-draft #f)
  (buffer-set-local! t--as-buf 'chat-queued (if (null? queued) #f queued))
  t--as-buf)

(effects! '(write))

(deftest 'up-on-an-empty-draft-previews-the-newest-queued-row-first
  "queued rows sit closer to the input than sent history does"
  (lambda ()
    (let ((buf (t--as-chat! (list "first queued" "second queued"))))
      (with-current-buffer buf
        (lambda ()
          (end-of-buffer!)
          (run-command "chat-history-previous")
          (check-equal! (chat-input-text buf) "second queued" "the newest queued row shows first")
          (run-command "chat-history-previous")
          (check-equal! (chat-input-text buf) "first queued" "then the older one")
          (run-command "chat-history-next")
          (check-equal! (chat-input-text buf) "second queued" "down walks back toward the input")
          (run-command "chat-history-next")
          (check-equal! (chat-input-text buf) "" "and returns to the empty draft")))
      (buffer-kill! buf))))

(deftest 'a-typed-draft-is-not-hijacked-by-the-queue
  "the walk only opens on an empty draft, never over what you are typing"
  (lambda ()
    (let ((buf (t--as-chat! (list "queued"))))
      (with-current-buffer buf
        (lambda ()
          (buffer-append! buf "not sent yet")
          (end-of-buffer!)
          (run-command "chat-history-previous")
          (check-equal! (chat-input-text buf) "not sent yet"
                        "typing in progress stays put, queued or not")))
      (buffer-kill! buf))))

(deftest 'chat-unqueue-drops-the-row-the-walk-is-standing-on
  "not always the newest -- whichever row Up left you looking at"
  (lambda ()
    (let ((buf (t--as-chat! (list "first queued" "second queued"))))
      (with-current-buffer buf
        (lambda ()
          (end-of-buffer!)
          (run-command "chat-history-previous")
          (run-command "chat-history-previous")
          (check-equal! (chat-input-text buf) "first queued" "standing on the older row")
          (run-command "chat-unqueue")
          (check-equal! (buffer-local buf 'chat-queued) (list "second queued")
                        "only that row left the queue")
          (check-equal! (chat-input-text buf) "first queued"
                        "and it landed back in the input, ready to edit or resend")
          (check-false! (buffer-local buf 'chat-queued-pos) "the walk ends: there is nothing left to stand on")))
      (buffer-kill! buf))))

(deftest 'chat-unqueue-without-a-walk-takes-the-newest
  "the un-walked default matches what chat-unqueue always did"
  (lambda ()
    (let ((buf (t--as-chat! (list "older" "newer"))))
      (with-current-buffer buf
        (lambda ()
          (run-command "chat-unqueue")
          (check-equal! (buffer-local buf 'chat-queued) (list "older") "the newest left")
          (check-equal! (chat-input-text buf) "newer" "and came back to the input")))
      (buffer-kill! buf))))

(deftest 'chat-unqueue-with-nothing-queued-says-so
  "no crash, no silent no-op -- a message names the empty queue"
  (lambda ()
    (let ((buf (t--as-chat! '())))
      (with-current-buffer buf
        (lambda ()
          (run-command "chat-unqueue")
          (check-equal! (chat-input-text buf) "" "nothing changed in the input")))
      (buffer-kill! buf))))
