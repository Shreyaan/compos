;;; group-cycle-test.scm --- one key walks a group's buffers, most recently
;;; used first, and flips between the last two the way Alt-Tab flips between
;;; two windows. A pane walks its own kind: the mode it names, else every
;;; buffer that is not a chat, and a pane showing a chat walks the chats.
;;; The walk never leaves the group and never leaves the window.
;;;
;;; No test presses a key: the binding is read from the map as data, and the
;;; walk is driven by its command.

(domain! 'testing)
(effects! '(write))

(define *group-cycle-test-bufs*
  (list "*zz-cyc-one*" "*zz-cyc-two*" "*zz-cyc-three*" "*zz-cyc-hidden*"
        "*zz-cyc-other*" "*zz-cyc-work-a*" "*zz-cyc-work-b*" "*zz-cyc-work-there*"))

(define (group-cycle-test-reset!)
  (window-cycle-mode! (active-window) #f)
  (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
            *group-cycle-test-bufs*)
  (for-each (lambda (name)
              (when (group-record-by-name name) (group-record-delete! name)))
            (list "zz-cyc-here" "zz-cyc-there")))

(define (group-cycle-test-chat! name group-id)
  (test-buffer! name "")
  (buffer-set-local! name 'mode-name "chat-mode")
  (buffer-set-local! name 'group-id group-id)
  name)

(define (group-cycle-test-work! name group-id mode)
  (test-buffer! name "")
  (when mode (buffer-set-local! name 'mode-name mode))
  (group-add-buffers-to! (list name) group-id)
  name)

;; one group of three chats and two work buffers, another holding one of
;; each, touched oldest first, so the walk starts on three
(define (group-cycle-test-open!)
  (group-cycle-test-reset!)
  (let ((here (group-record-create! "zz-cyc-here"))
        (there (group-record-create! "zz-cyc-there")))
    (group-cycle-test-chat! "*zz-cyc-one*" here)
    (group-cycle-test-chat! "*zz-cyc-two*" here)
    (group-cycle-test-chat! "*zz-cyc-three*" here)
    (group-cycle-test-chat! "*zz-cyc-other*" there)
    (group-cycle-test-work! "*zz-cyc-work-a*" here "text-mode")
    (group-cycle-test-work! "*zz-cyc-work-b*" here #f)
    (group-cycle-test-work! "*zz-cyc-work-there*" there #f)
    (switch-to-buffer! "*zz-cyc-other*")
    (switch-to-buffer! "*zz-cyc-work-there*")
    (switch-to-buffer! "*zz-cyc-work-b*")
    (switch-to-buffer! "*zz-cyc-work-a*")
    (switch-to-buffer! "*zz-cyc-one*")
    (switch-to-buffer! "*zz-cyc-two*")
    (switch-to-buffer! "*zz-cyc-three*")
    (list here there)))

(define (group-cycle-test-mine)
  (filter (lambda (b) (string-prefix? "*zz-cyc-" b)) (group-cycle-ring)))

(deftest 'group-cycle-walks-the-chats-most-recent-first
  "in a chat pane the ring is this chat, then the group's other open chats"
  (lambda ()
    (group-cycle-test-open!)
    (check-equal! (group-cycle-mode) "chat-mode"
                  "a pane showing a chat names chat-mode by itself")
    (check-equal! (group-cycle-test-mine)
                  (list "*zz-cyc-three*" "*zz-cyc-two*" "*zz-cyc-one*")
                  "this chat leads, the rest follow by use")
    (group-cycle-test-reset!)))

(deftest 'group-cycle-walks-the-work-buffers-in-a-work-pane
  "anything that is not a chat walks the group's other non-chat buffers"
  (lambda ()
    (group-cycle-test-open!)
    (switch-to-buffer! "*zz-cyc-work-a*")
    (check-false! (group-cycle-mode) "no mode named, so every non-chat buffer")
    (check-equal! (group-cycle-test-mine)
                  (list "*zz-cyc-work-a*" "*zz-cyc-work-b*")
                  "the work buffers of this group, most recent first")
    (check-false! (member "*zz-cyc-three*" (group-cycle-ring))
                  "a chat is never in a work pane's ring")
    (group-cycle-test-reset!)))

(deftest 'group-cycle-takes-the-mode-a-pane-names
  "name a mode on the pane and the walk is that mode's buffers alone"
  (lambda ()
    (group-cycle-test-open!)
    (switch-to-buffer! "*zz-cyc-work-a*")
    (window-cycle-mode! (active-window) "text-mode")
    (check-equal! (group-cycle-mode) "text-mode" "the pane names it")
    (check-equal! (group-cycle-test-mine) (list "*zz-cyc-work-a*")
                  "only the buffer in that mode")
    (window-cycle-mode! (active-window) #f)
    (check-equal! (group-cycle-test-mine)
                  (list "*zz-cyc-work-a*" "*zz-cyc-work-b*")
                  "take the naming away and every non-chat buffer is back")
    (group-cycle-test-reset!)))

(deftest 'group-cycle-never-leaves-the-group
  "another group's buffers are not in the ring, however recently used"
  (lambda ()
    (group-cycle-test-open!)
    (check-false! (member "*zz-cyc-other*" (group-cycle-ring))
                  "the chat of the other group stays out")
    (switch-to-buffer! "*zz-cyc-work-a*")
    (check-false! (member "*zz-cyc-work-there*" (group-cycle-ring))
                  "and so does its work buffer")
    (switch-to-buffer! "*zz-cyc-other*")
    (check-equal! (group-cycle-test-mine) (list "*zz-cyc-other*")
                  "one chat there, and no way across")
    (group-cycle! 1)
    (check-equal! (current-buffer) "*zz-cyc-other*" "a lone buffer does not move")
    (group-cycle-test-reset!)))

(deftest 'group-cycle-leaves-a-context-only-buffer-out
  "a buffer kept as context only is not a place the walk stops"
  (lambda ()
    (group-cycle-test-open!)
    (group-cycle-test-chat! "*zz-cyc-hidden*" (buffer-group "*zz-cyc-three*"))
    (buffer-context-only! "*zz-cyc-hidden*")
    (switch-to-buffer! "*zz-cyc-three*")
    (check-false! (member "*zz-cyc-hidden*" (group-cycle-ring)) "out of the ring")
    (group-cycle-test-reset!)))

(deftest 'group-cycle-flips-between-the-last-two
  "one step lands on the buffer you came from; a fresh walk brings you back"
  (lambda ()
    (group-cycle-test-open!)
    (group-cycle! 1)
    (check-equal! (current-buffer) "*zz-cyc-two*" "the most recently used other chat")
    (group-cycle! 1)
    (check-equal! (current-buffer) "*zz-cyc-three*" "and back, the way Alt-Tab flips")
    (group-cycle-test-reset!)))

(deftest 'group-cycle-repeat-goes-one-deeper
  "pressing again without another command between walks past the last buffer"
  (lambda ()
    (group-cycle-test-open!)
    (group-cycle! 1)
    (check-equal! (current-buffer) "*zz-cyc-two*" "one deep")
    ;; the editor marks a repeat by last-command, which only a key press
    ;; sets; the walk's own state is what the repeat reads
    (set! *group-cycle-pos* (modulo (+ *group-cycle-pos* 1) (length *group-cycle-ring*)))
    (switch-to-buffer! (list-ref *group-cycle-ring* *group-cycle-pos*))
    (check-equal! (current-buffer) "*zz-cyc-one*" "two deep, down the same ring")
    (group-cycle-test-reset!)))

(deftest 'group-cycle-has-its-commands
  "the walk, its other way, and the naming of a pane's mode are commands"
  (lambda ()
    (check-true! (procedure? (command-function "group-next-buffer")) "the walk")
    (check-true! (procedure? (command-function "group-previous-buffer")) "the other way")
    (check-true! (procedure? (command-function "window-cycle-mode")) "the naming")))
