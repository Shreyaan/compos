;;; popper-test.scm --- popups are ordinary buffers in ordinary windows.
;;;
;;; The tests call the commands and read the windows. The popups are
;;; *zz-pop-...* buffers by a test list, so the stock list does not decide.

(domain! 'testing)
(effects! '(write display))

(define t--pop-a "*zz-pop-a*")
(define t--pop-b "*zz-pop-b*")
(define t--pop-c "*zz-pop-c*")
(define t--pop-work "*zz-pop-work*")

;; one window on the work buffer, the test's own list; everything put back
(define (t--pop-with thunk)
  (let ((refs popper-reference-buffers))
    (set! popper-reference-buffers '("\\*zz-pop-[abc]\\*"))
    (layout-target-set! #f)
    (when (float-open?) (float-close!))
    (for-each buffer-create (list t--pop-a t--pop-b t--pop-c t--pop-work))
    (switch-to-buffer! t--pop-work)
    (run-command "delete-other-windows")
    (let ((out (thunk)))
      (set! popper-reference-buffers refs)
      (switch-to-buffer! "*scratch*")
      (run-command "delete-other-windows")
      (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
                (list t--pop-a t--pop-b t--pop-c t--pop-work))
      out)))

(define (t--pop-bottom? win)
  (let ((r (assoc win (window-rects))))
    ;; (WIN BUFFER X Y W H): the window spans the frame and ends at its bottom
    (and r (< (nth 2 r) 0.01) (> (nth 4 r) 0.99) (> (+ (nth 3 r) (nth 5 r)) 0.99))))

(deftest 'a-popup-is-named-by-the-list-or-by-its-own-status
  "a regexp or a mode in the list makes a popup; toggle-type's status wins"
  (lambda ()
    (t--pop-with
      (lambda ()
        (check-true! (popper-popup? t--pop-a) "the regexp matches")
        (check-false! (popper-popup? t--pop-work) "another name is not a popup")
        (set! popper-reference-buffers (list 'zz-pop-mode))
        (buffer-set-local! t--pop-work 'mode-name "zz-pop-mode")
        (check-true! (popper-popup? t--pop-work) "a mode in the list matches")
        (buffer-set-local! t--pop-work 'popper-popup-status 'raised)
        (check-false! (popper-popup? t--pop-work) "raised, the buffer is ordinary")
        (buffer-set-local! t--pop-work 'popper-popup-status #f)
        (buffer-set-local! t--pop-work 'mode-name #f)))))

(deftest 'a-popup-shows-in-an-ordinary-window-at-the-bottom
  "display-buffer splits the frame's root; the window is selected and is not a float"
  (lambda ()
    (t--pop-with
      (lambda ()
        (let* ((me (active-window))
               (w (display-buffer t--pop-a)))
          (check-equal! (length (window-list)) 2 "one new window")
          (check-false! (equal? w me) "not the work window")
          (check-equal! (window-buffer w) t--pop-a "it shows the popup")
          (check-equal! (active-window) w "the popup window has the selection")
          (check-true! (t--pop-bottom? w) "across the bottom of the frame")
          (check-false! (float-open?) "nothing floats")
          (check-false! (buffer-local t--pop-a 'window-class) "the buffer wears no float class")
          (check-equal! (window-buffer me) t--pop-work "the work stays in its window")
          (check-equal! (layout-visible-buffers) (list t--pop-work) "the layout does not count it"))))))

(deftest 'toggle-closes-the-popup-and-shows-the-latest-again
  "the close deletes the window a popup display made; the next toggle shows it again"
  (lambda ()
    (t--pop-with
      (lambda ()
        (let ((me (active-window)))
          (display-buffer t--pop-a)
          (run-command "popper-toggle")
          (check-equal! (length (window-list)) 1 "the popup window goes")
          (check-equal! (window-buffer (active-window)) t--pop-work "the work shows")
          (check-true! (buffer-known? t--pop-a) "the popup buffer lives")
          (run-command "popper-toggle")
          (check-equal! (window-buffer (popper-window)) t--pop-a "the latest popup comes back")
          (check-equal! (window-buffer me) t--pop-work "in its own window again"))))))

(deftest 'closing-a-popup-over-a-popup-shows-the-one-under-it
  "a popup shown over another covers it; the close shows it, and the next close deletes the window"
  (lambda ()
    (t--pop-with
      (lambda ()
        (let ((w (display-buffer t--pop-a)))
          (check-equal! (display-buffer t--pop-b) w "the second popup takes the popup window")
          (check-equal! (length (window-list)) 2 "no third window")
          (run-command "popper-toggle")
          (check-equal! (window-buffer w) t--pop-a "the popup under it comes back")
          (check-equal! (length (window-list)) 2 "in the same window")
          (run-command "popper-toggle")
          (check-equal! (length (window-list)) 1 "the next close deletes the window")
          (check-equal! (window-buffer (active-window)) t--pop-work "the work shows"))))))

(deftest 'closing-a-popup-restores-the-buffer-under-it-in-that-window
  "in the only window, the close shows the popup under it, then the work buffer from the history"
  (lambda ()
    (t--pop-with
      (lambda ()
        (let ((me (active-window)))
          ;; the reader switches to a popup in the work window
          (switch-to-buffer! t--pop-a)
          (check-equal! (display-buffer t--pop-b) me "a popup display reuses the window of a popup")
          (run-command "popper-toggle")
          (check-equal! (window-buffer me) t--pop-a "the popup under it comes back")
          (run-command "popper-toggle")
          (check-equal! (length (window-list)) 1 "the last window stays")
          (check-equal! (window-buffer me) t--pop-work "and shows the buffer under the popups"))))))

(deftest 'cycle-shows-each-other-popup-in-the-popup-window
  "with a popup open, each cycle shows another popup there; the presses reach them all"
  (lambda ()
    (t--pop-with
      (lambda ()
        (display-buffer t--pop-c)
        (display-buffer t--pop-b)
        (let ((w (display-buffer t--pop-a))
              (seen '()))
          (run-command "popper-cycle")
          (set! seen (cons (window-buffer w) seen))
          (run-command "popper-cycle")
          (set! seen (cons (window-buffer w) seen))
          (run-command "popper-cycle")
          (set! seen (cons (window-buffer w) seen))
          (check-equal! (length (window-list)) 2 "every popup takes the one popup window")
          (check-true! (and (member t--pop-b seen) (member t--pop-c seen) (member t--pop-a seen) #t)
                       "three presses reach every popup"))))))

(deftest 'cycle-with-no-popup-open-shows-the-latest
  "no popup on screen: cycle shows the latest one"
  (lambda ()
    (t--pop-with
      (lambda ()
        (display-buffer t--pop-a)
        (run-command "popper-toggle")
        (check-false! (popper-window) "no popup shows")
        (run-command "popper-cycle")
        (check-equal! (window-buffer (popper-window)) t--pop-a "the latest popup shows")))))

(deftest 'toggle-type-makes-a-popup-ordinary-and-back
  "a raised popup takes a work window; a lowered buffer shows at the bottom"
  (lambda ()
    (t--pop-with
      (lambda ()
        (let ((me (active-window)))
          (display-buffer t--pop-a)
          (run-command "popper-toggle-type")
          (check-false! (popper-popup? t--pop-a) "the buffer is ordinary now")
          (check-false! (popper-window) "no popup window stays")
          (let ((w (window-showing t--pop-a)))
            (check-true! (and w #t) "a window shows it")
            (check-true! (member t--pop-a (layout-visible-buffers)) "as a work window")
            (select-window! w)
            (run-command "popper-toggle-type")
            (check-true! (popper-popup? t--pop-a) "a popup again")
            (let ((p (window-showing t--pop-a)))
              (check-true! (and p (t--pop-bottom? p)) "at the bottom of the frame"))
            (check-equal! (window-buffer me) t--pop-work "the work window keeps the work")))))))

(deftest 'a-look-at-a-popup-takes-the-preview-rule
  "a preview of a popup buffer goes beside the reader, not to the popup window"
  (lambda ()
    (t--pop-with
      (lambda ()
        (let ((me (active-window)))
          (preview-show t--pop-a 'other)
          (check-equal! (active-window) me "a look moves no focus")
          (check-equal! (window-owner (window-showing t--pop-a)) me "the reader's window owns the look")
          (check-false! (buffer-local t--pop-a 'window-class) "and nothing floats")
          (preview-end #f))))))
