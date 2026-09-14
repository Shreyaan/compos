;;; display-buffer-test.scm --- where a buffer goes: the action chain.
;;;
;;; display-buffer tries the rule for the name, the base action, then the
;;; fallback: reuse-window, mode-window, pop-up-window, use-some-window,
;;; same-window.
;;; The thresholds decide a split; the tests set them, so the frame's
;;; size does not.

(domain! 'testing)
(effects! '(write display))

(define t--db-dir (string-append (compos-home) "/display-test"))

(define (t--db-file name text)
  (let ((p (string-append t--db-dir "/" name)))
    (write-file! p text)
    p))

;; one window on *scratch*, the stock rules, the thresholds of the test;
;; everything put back after
(define (t--db-with thresholds thunk)
  (make-directory! t--db-dir)
  (let ((rules *display-buffer-alist*)
        (base *display-buffer-base-action*)
        (fallback *display-buffer-fallback-action*)
        (h split-height-threshold)
        (w split-width-threshold))
    (set! split-height-threshold (car thresholds))
    (set! split-width-threshold (cadr thresholds))
    (set! *display-buffer-base-action* '())
    (layout-target-set! #f)
    (when (popup-open?) (popup-close!))
    (set-frame-local! 'pinned-group #f)
    (set-frame-local! 'current-group #f)
    (switch-to-buffer-here! "*scratch*")
    (run-command "delete-other-windows")
    (let ((out (thunk)))
      (for-each (lambda (b)
                  (when (or (string-prefix? "*zz-db" b) (string-prefix? t--db-dir b))
                    (buffer-kill! b)))
                (buffer-list))
      (set! *display-buffer-alist* rules)
      (set! *display-buffer-base-action* base)
      (set! *display-buffer-fallback-action* fallback)
      (set! split-height-threshold h)
      (set! split-width-threshold w)
      (set! *peek-recent* '())
      (switch-to-buffer! "*scratch*")
      (run-command "delete-other-windows")
      out)))

(define t--db-wide '(1000 1))     ; beside always, below never
(define t--db-tall '(1 1000))     ; below always
(define t--db-never '(1000 1000)) ; no split by size

(define (t--db-rect win) (assoc win (window-rects)))

(deftest 'a-buffer-with-no-rule-takes-the-fallback-chain
  "the chain is reuse, mode, pop-up, use-some, same; a rule's action goes first"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (check-equal! (display-buffer-actions-for "*zz-db-none*")
                      '(reuse-window mode-window pop-up-window use-some-window same-window)
                      "the fallback")
        (add-display-rule! "*zz-db-ruled*" 'same-window)
        (check-equal! (car (display-buffer-actions-for "*zz-db-ruled*")) 'same-window
                      "a name rule first")
        (check-equal! (car (display-buffer-actions-for "*zz-db-none*" '(category preview)))
                      'reuse-window "the preview category first")
        (set! *display-buffer-base-action* '(same-window))
        (check-equal! (car (display-buffer-actions-for "*zz-db-none*")) 'same-window
                      "with no rule the base action comes first")
        (check-equal! (cadr (display-buffer-actions-for "*zz-db-none*")) 'reuse-window
                      "and the fallback after it")
        (check-equal! (car (display-buffer-actions-for "*zz-db-ruled*")) 'same-window
                      "a rule still comes before the base action")))))

;; One window per mode: the second buffer of a mode takes the window the
;; first one holds, instead of splitting a pane of its own for it.
(deftest 'a-second-buffer-of-a-mode-takes-the-window-the-first-one-holds
  "mode-window keeps a group to one window per mode"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (buffer-create "*zz-db-a*")
        (buffer-create "*zz-db-b*")
        (with-current-buffer "*zz-db-a*" (lambda () (set-mode! "text-mode")))
        (with-current-buffer "*zz-db-b*" (lambda () (set-mode! "text-mode")))
        (let ((first (display-buffer "*zz-db-a*")))
          (check-equal! (window-mode first) "text-mode" "the mode came with it")
          (check-equal! (display-buffer "*zz-db-b*") first
                        "the same mode took the same window")
          (check-equal! (window-buffer first) "*zz-db-b*" "and replaced it there")
          (buffer-create "*zz-db-c*")
          (with-current-buffer "*zz-db-c*" (lambda () (set-mode! "fundamental-mode")))
          (check-false! (equal? (display-buffer "*zz-db-c*") first)
                        "another mode does not take that window"))))))

;; A target layout is no licence for two panes of one mode: with a column
;; still free, the second buffer of a mode takes the first one's pane.
(deftest 'a-target-layout-does-not-give-one-mode-two-panes
  "one window per mode outranks the target's spare capacity"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (buffer-create "*zz-db-a*")
        (buffer-create "*zz-db-b*")
        (with-current-buffer "*zz-db-a*" (lambda () (set-mode! "text-mode")))
        (with-current-buffer "*zz-db-b*" (lambda () (set-mode! "text-mode")))
        (layout-target-set! 'columns)
        (let ((first (display-buffer "*zz-db-a*")))
          (check-equal! (display-buffer "*zz-db-b*") first
                        "the second buffer of the mode took the first one's pane")
          (check-equal! (length (window-list)) 2 "the free column stayed free"))
        (layout-target-set! #f)))))

(deftest 'pop-up-window-splits-beside-and-selects-nothing
  "one wide window: the buffer takes a new window beside it; point stays"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (let ((me (active-window)))
          (buffer-create "*zz-db-a*")
          (let ((win (display-buffer "*zz-db-a*")))
            (check-equal! (length (window-list)) 2 "two windows")
            (check-equal! (active-window) me "the selected window did not change")
            (check-equal! (current-buffer) "*scratch*" "nor the current buffer")
            (check-equal! (window-buffer win) "*zz-db-a*" "the new window shows it")
            (check-true! (not (equal? win me)) "and it is not the selected one")
            (check-equal! (nth 3 (t--db-rect win)) (nth 3 (t--db-rect me)) "beside: the same top")
            (check-true! (> (nth 2 (t--db-rect win)) (nth 2 (t--db-rect me))) "to the right")
            (check-equal! (cadr (window-quit-restore win)) 'window "noted as a window the display made")))))))

(deftest 'pop-up-window-splits-below-when-the-window-is-tall
  "the height threshold wins over the width one, as in Emacs"
  (lambda ()
    (t--db-with t--db-tall
      (lambda ()
        (let ((me (active-window)))
          (buffer-create "*zz-db-a*")
          (let ((win (display-buffer "*zz-db-a*")))
            (check-equal! (length (window-list)) 2 "two windows")
            (check-equal! (nth 2 (t--db-rect win)) (nth 2 (t--db-rect me)) "below: the same left")
            (check-true! (> (nth 3 (t--db-rect win)) (nth 3 (t--db-rect me))) "under it")))))))

(deftest 'the-sole-window-splits-below-whatever-its-size
  "no threshold is met, but a frame with one window still gets a second"
  (lambda ()
    (t--db-with t--db-never
      (lambda ()
        (let ((me (active-window)))
          (buffer-create "*zz-db-a*")
          (let ((win (display-buffer "*zz-db-a*")))
            (check-equal! (length (window-list)) 2 "two windows")
            (check-true! (> (nth 3 (t--db-rect win)) (nth 3 (t--db-rect me))) "the new one below")))))))

(deftest 'reuse-window-finds-the-window-that-shows-it
  "a second display of the same buffer makes no window"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (buffer-create "*zz-db-a*")
        (let ((first (display-buffer "*zz-db-a*")))
          (check-equal! (display-buffer "*zz-db-a*") first "the same window")
          (check-equal! (length (window-list)) 2 "still two"))))))

(deftest 'use-some-window-takes-another-window-when-no-split-fits
  "two windows, no room to split: the other window shows it, and quit puts back what it showed"
  (lambda ()
    (t--db-with t--db-never
      (lambda ()
        (let ((me (active-window)))
          (buffer-create "*zz-db-a*")
          (buffer-create "*zz-db-b*")
          (let ((other (display-buffer "*zz-db-a*")))
            (check-equal! (length (window-list)) 2 "the sole window split once")
            (let ((win (display-buffer "*zz-db-b*")))
              (check-equal! win other "the other window is used")
              (check-equal! (length (window-list)) 2 "no third window")
              (check-equal! (window-buffer other) "*zz-db-b*" "and shows the second buffer")
              (check-equal! (active-window) me "point stays")
              (check-equal! (cadr (window-quit-restore win)) 'other "noted as a window the display took")
              (check-equal! (caddr (window-quit-restore win)) "*zz-db-a*" "with what it showed")
              (window-quit-restore! win)
              (check-equal! (window-buffer other) "*zz-db-a*" "quit puts the first buffer back"))))))))

(deftest 'a-target-layout-fills-capacity-before-replacing
  "an explicit two-pane target grows once, then uses the other pane"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (let ((home (current-buffer)))
          (buffer-create "*zz-db-a*")
          (buffer-create "*zz-db-b*")
          (layout-target-set! 'two-pane)
          (display-buffer "*zz-db-a*")
          (check-equal! (length (window-list)) 2 "underfilled target grows")
          (check-equal! (current-buffer) home "passive display preserves focus")
          (let ((other (window-showing "*zz-db-a*")))
            (check-equal! (display-buffer "*zz-db-b*") other "full target replaces the other pane")
            (check-equal! (length (window-list)) 2 "capacity is respected")
            (check-equal! (current-buffer) home "replacement preserves focus"))
          (layout-target-set! #f)
          (check-equal! (caddr (display-buffer-actions-for "*zz-db-b*")) 'pop-up-window
                        "free restores sensible splitting"))))))

(deftest 'same-window-is-the-last-resort-and-inhibit-keeps-it-out
  "with the same window inhibited and nothing else, the display fails rather than covers"
  (lambda ()
    (t--db-with t--db-never
      (lambda ()
        (set! *display-buffer-alist* (list (list "*zz-db" 'same-window '())))
        (buffer-create "*zz-db-a*")
        (let ((me (active-window)))
          (check-equal! (display-buffer "*zz-db-a*") me "a same-window rule shows it here")
          (check-equal! (current-buffer) "*zz-db-a*" "and it is current")
          (check-equal! (length (window-list)) 1 "no split"))
        (set! *display-buffer-alist* (list (list "*zz-db" '(same-window) '())))
        (set! *display-buffer-fallback-action* '())
        (buffer-create "*zz-db-b*")
        (check-false! (display-buffer "*zz-db-b*" '(inhibit-same-window #t))
                      "inhibited, with no other action, there is no window")
        (set! *display-buffer-fallback-action*
              '(reuse-window pop-up-window use-some-window same-window))))))

(deftest 'pop-to-buffer-shows-and-selects
  "display-buffer selects nothing; pop-to-buffer selects the window it used"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (let ((me (active-window)))
          (buffer-create "*zz-db-a*")
          (let ((win (pop-to-buffer "*zz-db-a*")))
            (check-equal! (active-window) win "the new window is selected")
            (check-true! (not (equal? win me)) "and it is another window")
            (check-equal! (current-buffer) "*zz-db-a*" "the buffer is current")))))))

(deftest 'quit-window-deletes-the-window-the-display-made
  "q in a popped-up listing closes its window and kills it; the layout is what it was"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (let ((me (active-window)))
          (buffer-create "*zz-db-a*")
          (pop-to-buffer "*zz-db-a*")
          (run-command "quit-window")
          (check-equal! (length (window-list)) 1 "one window again")
          (check-equal! (active-window) me "the one the reader had")
          (check-false! (buffer-exists? "*zz-db-a*") "the listing is killed"))))))

(deftest 'display-buffer-other-window-never-covers-the-selected-window
  "with two windows and no room, the other window is used, never this one"
  (lambda ()
    (t--db-with t--db-never
      (lambda ()
        (let ((me (active-window)))
          (buffer-create "*zz-db-a*")
          (buffer-create "*zz-db-b*")
          (display-buffer "*zz-db-a*")
          (let ((win (display-buffer-other-window! "*zz-db-b*")))
            (check-true! (not (equal? win me)) "another window")
            (check-equal! (window-buffer me) "*scratch*" "this one still shows scratch")
            (check-equal! (active-window) me "and is still selected")))))))

(deftest 'an-old-popup-rule-takes-an-ordinary-window
  "nothing floats: a rule written for the popup goes through the window chain"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (buffer-create "*zz-db-side*")
        (add-display-rule! "*zz-db-side*" 'popup)
        (let ((win (display-buffer "*zz-db-side*")))
          (check-false! (popup-open?) "no popup opened")
          (check-equal! (window-buffer win) "*zz-db-side*"
                        "an ordinary window shows it"))))))

(deftest 'a-peek-follows-the-preview-rule
  "a peek goes through the window chain"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (let ((a (t--db-file "a.txt" "alpha\n"))
              (b (t--db-file "b.txt" "beta\n"))
              (me (active-window)))
          (peek-file! a)
          (check-false! (popup-open?) "stock: no popup")
          (check-equal! (length (window-list)) 2 "a window beside")
          (check-equal! (active-window) me "point stays")
          (check-true! (peek-buffer? a) "it is a peek")
          (let ((win (window-showing a)))
            (check-true! (and win (not (equal? win me))) "in the other window")
            (peek-file! b)
            (check-equal! (length (window-list)) 2 "the next peek takes the same window")
            (check-equal! (window-buffer win) b "and shows the second file")
            (check-false! (buffer-exists? a) "the first peek is gone")
            (check-equal! (active-window) me "point still stays"))
          (peek-dismiss!)
          (check-equal! (length (window-list)) 1 "dismissed: the window the peek made is gone")
          (check-false! (buffer-exists? b) "and the peek with it"))))))

(deftest 'mode-preference-survives-a-temporary-cover
  "display reuses the work window beneath a special buffer"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (for-each (lambda (b)
                    (buffer-create b)
                    (buffer-set-local! b 'mode-name "text-mode"))
                  '("*zz-db-a*" "*zz-db-b*"))
        (let ((win (display-buffer "*zz-db-a*")))
          (buffer-create "*zz-db-cover*")
          (buffer-set-local! "*zz-db-cover*" 'mode-name "help-mode")
          (buffer-set-local! "*zz-db-cover*" 'special #t)
          (display-buffer-in-window! win "*zz-db-cover*")
          (check-equal! (window-preferred-mode win) "text-mode" "the cover keeps the preference")
          (check-true! (window-prefers-buffer? win "*zz-db-b*") "the next work buffer matches")
          (window-tree-set! (window-tree))
          (set! win (window-showing "*zz-db-cover*"))
          (check-equal! (window-preferred-mode win) "text-mode" "restoring the tree keeps the preference")
          (check-equal! (display-buffer "*zz-db-b*") win "the stack receives the next work buffer"))))))

(deftest 'free-layout-switch-reuses-the-same-mode-window
  "ordinary switching reuses a matching window without a target layout"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (for-each (lambda (b)
                    (buffer-create b)
                    (buffer-set-local! b 'mode-name "text-mode"))
                  '("*zz-db-a*" "*zz-db-b*"))
        (let ((source (active-window)) (win (display-buffer "*zz-db-a*")))
          (switch-to-buffer! "*zz-db-b*")
          (check-equal! (active-window) win "the matching window is selected")
          (check-equal! (window-buffer source) "*scratch*" "the source stays unchanged")
          (check-equal! (window-buffer win) "*zz-db-b*" "the buffer opens in the matching stack"))))))

(deftest 'a-listing-keeps-its-own-mode-preference
  "a special listing is a mode destination, not automatically a temporary cover"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (buffer-create "*zz-db-list*")
        (buffer-set-local! "*zz-db-list*" 'mode-name "Dired")
        (buffer-set-local! "*zz-db-list*" 'special #t)
        (display-buffer-in-window! (active-window) "*zz-db-list*")
        (check-equal! (window-preferred-mode (active-window)) "Dired"
                      "directory buffers cycle with directories")))))
