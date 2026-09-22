;;; window-history-test.scm --- a window remembers its own past across a
;;; tile, and a kill refills the window from that past.
;;;
;;; The tiler builds every window from one survivor, and a split copies
;;; the survivor's history. The build repairs that: each new pane takes
;;; the history of the pane that showed its buffer. A kill then shows
;;; the buffer the pane showed before, and never a buffer another
;;; window of the frame shows.

(domain! 'testing)
(effects! '(write display))

(tests-need-a-disposable-editor!
  "re-arranges the frame's windows and kills buffers")

(define t--wh-a "zz-wh-a")
(define t--wh-b "zz-wh-b")
(define t--wh-c "zz-wh-c")
(define t--wh-d "zz-wh-d")
(define t--wh-e "zz-wh-e")
(define t--wh-all (list t--wh-a t--wh-b t--wh-c t--wh-d t--wh-e))

;; two windows: the left one on b after a, the right one on d after c
(define (t--wh-setup!)
  (layout-target-set! #f)
  (for-each (lambda (b) (test-buffer! b "")) t--wh-all)
  (delete-other-windows!)
  (switch-to-buffer! t--wh-a)
  (switch-to-buffer! t--wh-b)
  (split-window! 'h 0.5)
  (other-window!)
  (switch-to-buffer! t--wh-c)
  (switch-to-buffer! t--wh-d))

(define (t--wh-done!)
  (layout-target-set! #f)
  (delete-other-windows!)
  (switch-to-buffer! "*scratch*")
  (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b))) t--wh-all))

(deftest 'a-tile-keeps-each-panes-own-history
  "after a tile the pane on b still remembers a, and the pane on d remembers c"
  (lambda ()
    (t--wh-setup!)
    (tile-windows! 'columns (list t--wh-b t--wh-d))
    (check-equal! (length (window-list)) 2 "two panes")
    (check-equal! (car (window-prev-buffers (window-showing t--wh-b))) t--wh-a
                  "the pane on b remembers a")
    (check-equal! (car (window-prev-buffers (window-showing t--wh-d))) t--wh-c
                  "the pane on d remembers c, not the survivor's past")
    (t--wh-done!)))

(deftest 'a-kill-after-a-tile-refills-the-pane-from-its-own-past
  "kill d in its pane: the pane shows c, the layout stays"
  (lambda ()
    (t--wh-setup!)
    (tile-windows! 'two-pane (list t--wh-b t--wh-d))
    (let ((win (window-showing t--wh-d)))
      (buffer-kill! t--wh-d)
      (check-equal! (length (window-list)) 2 "the window stays")
      (check-true! (window-exists? win) "the same window")
      (check-equal! (window-buffer win) t--wh-c "and shows the buffer it showed before d"))
    (t--wh-done!)))

(deftest 'a-refill-never-shows-what-another-window-shows
  "the pane's past leads with a buffer the other window shows: the next one takes the place"
  (lambda ()
    (for-each (lambda (b) (test-buffer! b "")) t--wh-all)
    (layout-target-set! #f)
    (delete-other-windows!)
    (switch-to-buffer! t--wh-b)
    (switch-to-buffer! t--wh-a)
    (split-window! 'h 0.5)
    (other-window!)
    ;; the right window: d after a, so its past is (a b ...) and a is on the left
    (switch-to-buffer! t--wh-d)
    (let ((win (active-window)))
      (check-equal! (car (window-prev-buffers win)) t--wh-a "the pane's past leads with a")
      (buffer-kill! t--wh-d)
      (check-equal! (length (window-list)) 2 "the window stays")
      (check-equal! (window-buffer win) t--wh-b "a is on the left already, so b takes the place")
      (check-false! (equal? (window-buffer win) t--wh-a) "not a twice"))
    (t--wh-done!)))

(deftest 'a-fresh-pane-after-a-tile-remembers-the-pane-that-went-away
  "tile b with e, which no window showed: e's pane takes the past of the pane on d, d first"
  (lambda ()
    (t--wh-setup!)
    (tile-windows! 'columns (list t--wh-b t--wh-e))
    (let ((past (window-prev-buffers (window-showing t--wh-e))))
      (check-equal! (car past) t--wh-d "the pane that went away showed d")
      (check-equal! (cadr past) t--wh-c "and remembered c"))
    (t--wh-done!)))
