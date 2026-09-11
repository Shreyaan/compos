;;; chat-cycle-test.scm --- C-` walks this group's chats alone, most recently
;;; used first, and flips between the last two the way Alt-Tab flips between
;;; two windows. The walk never leaves the group.
;;;
;;; No test presses a key: the binding is read from chat-mode's map as data,
;;; and the walk is driven by its command.

(domain! 'testing)
(effects! '(write))

(define *chat-cycle-test-bufs*
  '("*zz-cyc-one*" "*zz-cyc-two*" "*zz-cyc-three*" "*zz-cyc-hidden*"
    "*zz-cyc-other*" "*zz-cyc-plain*"))

(define (chat-cycle-test-reset!)
  (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
            *chat-cycle-test-bufs*)
  (for-each (lambda (name)
              (when (group-record-by-name name) (group-record-delete! name)))
            '("zz-cyc-here" "zz-cyc-there")))

(define (chat-cycle-test-chat! name group-id)
  (test-buffer! name "")
  (buffer-set-local! name 'mode-name "chat-mode")
  (buffer-set-local! name 'group-id group-id)
  name)

;; three chats in this group and one in another, plus an ordinary buffer,
;; touched oldest first, so the most recently used chat here is three and the
;; walk starts there
(define (chat-cycle-test-open!)
  (chat-cycle-test-reset!)
  (let ((here (group-record-create! "zz-cyc-here"))
        (there (group-record-create! "zz-cyc-there")))
    (test-buffer! "*zz-cyc-plain*" "")
    (chat-cycle-test-chat! "*zz-cyc-one*" here)
    (chat-cycle-test-chat! "*zz-cyc-two*" here)
    (chat-cycle-test-chat! "*zz-cyc-three*" here)
    (chat-cycle-test-chat! "*zz-cyc-other*" there)
    (switch-to-buffer! "*zz-cyc-plain*")
    (switch-to-buffer! "*zz-cyc-other*")
    (switch-to-buffer! "*zz-cyc-one*")
    (switch-to-buffer! "*zz-cyc-two*")
    (switch-to-buffer! "*zz-cyc-three*")
    (list here there)))

(define (chat-cycle-test-mine)
  (filter (lambda (b) (string-prefix? "*zz-cyc-" b)) (chat-cycle-ring)))

(deftest 'chat-cycle-walks-the-chats-most-recent-first
  "the ring is this chat, then this group's other open chats, most recent first"
  (lambda ()
    (chat-cycle-test-open!)
    (check-equal! (chat-cycle-test-mine)
                  '("*zz-cyc-three*" "*zz-cyc-two*" "*zz-cyc-one*")
                  "this chat leads, the rest follow by use")
    (check-false! (member "*zz-cyc-plain*" (chat-cycle-ring))
                  "a buffer that is not a chat stays out")
    (chat-cycle-test-reset!)))

(deftest 'chat-cycle-never-leaves-the-group
  "another group's chat is not in the ring, however recently it was used"
  (lambda ()
    (chat-cycle-test-open!)
    (check-false! (member "*zz-cyc-other*" (chat-cycle-ring))
                  "the chat of the other group stays out")
    ;; and from over there the walk is that group's own, which is one chat
    (switch-to-buffer! "*zz-cyc-other*")
    (check-equal! (chat-cycle-test-mine) '("*zz-cyc-other*")
                  "one chat there, and no way across")
    (chat-cycle! 1)
    (check-equal! (current-buffer) "*zz-cyc-other*" "a lone chat does not move")
    (chat-cycle-test-reset!)))

(deftest 'chat-cycle-leaves-a-context-only-chat-out
  "a chat kept as context only is not a place the walk stops"
  (lambda ()
    (chat-cycle-test-open!)
    (chat-cycle-test-chat! "*zz-cyc-hidden*" (buffer-group "*zz-cyc-three*"))
    (buffer-context-only! "*zz-cyc-hidden*")
    (switch-to-buffer! "*zz-cyc-three*")
    (check-false! (member "*zz-cyc-hidden*" (chat-cycle-ring)) "out of the ring")
    (chat-cycle-test-reset!)))

(deftest 'chat-cycle-flips-between-the-last-two-chats
  "one step lands on the chat you came from; a fresh walk brings you back"
  (lambda ()
    (chat-cycle-test-open!)
    (chat-cycle! 1)
    (check-equal! (current-buffer) "*zz-cyc-two*" "the most recently used other chat")
    (chat-cycle! 1)
    (check-equal! (current-buffer) "*zz-cyc-three*" "and back, the way Alt-Tab flips")
    (chat-cycle-test-reset!)))

(deftest 'chat-cycle-repeat-goes-one-deeper
  "pressing again without another command between walks past the last chat"
  (lambda ()
    (chat-cycle-test-open!)
    (chat-cycle! 1)
    (check-equal! (current-buffer) "*zz-cyc-two*" "one deep")
    ;; the editor marks a repeat by last-command, which only a key press
    ;; sets; the walk's own state is what the repeat reads
    (set! *chat-cycle-pos* (modulo (+ *chat-cycle-pos* 1) (length *chat-cycle-ring*)))
    (switch-to-buffer! (list-ref *chat-cycle-ring* *chat-cycle-pos*))
    (check-equal! (current-buffer) "*zz-cyc-one*" "two deep, down the same ring")
    (chat-cycle-test-reset!)))

(deftest 'chat-cycle-is-chat-modes-own-key
  "C-` runs the walk in a chat and keeps its global meaning elsewhere"
  (lambda ()
    (check-equal! (keymap-lookup (mode-keymap "chat-mode") "C-`") "chat-cycle"
                  "the chat map binds it")
    (check-true! (procedure? (command-function "chat-cycle")) "the walk is a command")
    (check-true! (procedure? (command-function "chat-cycle-back"))
                 "and so is the other way, for M-x")))
