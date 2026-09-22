;;; window-walk-test.scm --- Cmd-up and Cmd-down walk the frame's context.
;;;
;;; The walk is the escape hatch. It steps the pane through every buffer of
;;; the group, most recent first, and it skips nothing a buffer can be: a
;;; chat, a view, the scratch are all places it stops. No test names the
;;; real binding; a binding is a preference.

(domain! 'testing)
(effects! '(write))
(tests-need-a-disposable-editor! "creates a group and walks its buffers")

(define *walk-test-bufs*
  (list "zz-walk-work" "zz-walk-chat" "zz-walk-view" "zz-walk-other"))

(define (walk-test-reset!)
  (when (minibuffer-state) (minibuffer-cancel!))
  (delete-other-windows!)
  (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b))) *walk-test-bufs*)
  (for-each (lambda (name)
              (when (group-record-by-name name) (group-record-delete! name)))
            (list "zz-walk-group")))

;; one group of four buffers: a work buffer, a chat, a view, and one more.
;; The fill pool declines the chat and the view; the walk must not.
(define (walk-test-open!)
  (walk-test-reset!)
  (for-each (lambda (b) (test-buffer! b "walk\n")) *walk-test-bufs*)
  (group-create-and-enter! "zz-walk-group" *walk-test-bufs* #f)
  (buffer-set-local! "zz-walk-chat" 'mode-name "chat-mode")
  (buffer-set-local! "zz-walk-chat" 'group-id (frame-group))
  (buffer-set-local! "zz-walk-view" 'special #t)
  (delete-other-windows!)
  (switch-to-buffer-here! "zz-walk-work")
  (window-buffer (active-window)))

(deftest 'the-walk-reaches-every-buffer-of-the-group
  "the ring the Cmd-arrows step is the group's own MRU, and it drops nothing"
  (lambda ()
    (check-equal! (walk-test-open!) "zz-walk-work" "the pane starts on the work buffer")
    (let ((ring (window-walk-ring)))
      (check-equal! (car ring) "zz-walk-work" "the pane's own buffer leads the ring")
      (check-true! (and (member "zz-walk-chat" ring) #t) "a chat is on the ring")
      (check-true! (and (member "zz-walk-view" ring) #t) "so is a view")
      (check-true! (and (member "zz-walk-other" ring) #t) "and the fourth buffer")
      (check-false! (member "zz-walk-chat" (filter window-fill-primary? (window-fill-buffers)))
                    "the pane fill pool still declines the chat")
      (check-false! (member "zz-walk-view" (filter window-fill-primary? (window-fill-buffers)))
                    "and the view"))
    (walk-test-reset!)))

(deftest 'the-walk-steps-the-pane-along-the-ring
  "one step down shows the next buffer of the ring in the same pane, and up comes back"
  (lambda ()
    (check-equal! (walk-test-open!) "zz-walk-work" "the pane starts on the work buffer")
    (let ((ring (window-walk-ring))
          (win (active-window)))
      (check-true! (window-walk! 1) "the step reports that it moved")
      (check-equal! (window-buffer win) (nth 1 ring)
                    "the pane moved one along, and it is the same pane")
      (check-true! (window-walk! -1) "and back")
      (check-equal! (window-buffer win) (car ring) "up returns to where the walk started"))
    (walk-test-reset!)))

(deftest 'the-walk-goes-round-the-ring-and-comes-home
  "the ring is cyclic and it is a snapshot: a full turn arrives where it started"
  (lambda ()
    (check-equal! (walk-test-open!) "zz-walk-work" "the pane starts on the work buffer")
    (let* ((win (active-window))
           (ring (window-walk-ring))
           (n (length ring))
           (seen (let loop ((i 0) (out '()))
                   (if (>= i n)
                       (reverse out)
                       (begin (window-walk! 1)
                              (loop (+ i 1) (cons (window-buffer win) out)))))))
      (check-equal! (window-buffer win) (car ring) "the last step comes home")
      (for-each (lambda (b)
                  (check-true! (and (member b seen) #t)
                               (string-append "the walk stopped on " b)))
                ring))
    (walk-test-reset!)))

(deftest 'the-walk-never-leaves-the-group-of-the-pane
  "every buffer on the ring belongs to the group the pane's buffer belongs to"
  (lambda ()
    (check-equal! (walk-test-open!) "zz-walk-work" "the pane starts on the work buffer")
    (test-buffer! "zz-walk-outside" "outside\n")
    (buffer-remove-group! "zz-walk-outside" (frame-group))
    (switch-to-buffer-here! "zz-walk-work")
    (let ((gid (buffer-group "zz-walk-work")))
      (check-true! (and gid #t) "the pane's buffer has a group")
      (check-false! (member "zz-walk-outside" (window-walk-ring))
                    "a buffer outside the group is not on the ring")
      (for-each (lambda (b)
                  (check-true! (buffer-in-group? b gid)
                               (string-append b " belongs to the pane's group")))
                (window-walk-ring)))
    (when (buffer-known? "zz-walk-outside") (buffer-kill! "zz-walk-outside"))
    (walk-test-reset!)))
