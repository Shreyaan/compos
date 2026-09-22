;;; winner-test.scm --- winner-undo returns the arrangement a relayout
;;; destroyed, and the layout engine leaves the restored arrangement alone.

(domain! 'testing)
(effects! '(write))

(tests-need-a-disposable-editor!
  "re-arranges the frame's windows and sets the frame's layout target")

(define t--wn-a "zz-wn-a")
(define t--wn-b "zz-wn-b")

(define (t--wn-rect buf)
  (let loop ((rs (window-rects)))
    (cond ((null? rs) #f)
          ((equal? (nth 1 (car rs)) buf) (car rs))
          (else (loop (cdr rs))))))

;; a above b: the rows layout, made by hand
(define (t--wn-stacked?)
  (let ((ra (t--wn-rect t--wn-a)) (rb (t--wn-rect t--wn-b)))
    (and ra rb (equal? (nth 2 ra) (nth 2 rb)) (< (nth 3 ra) (nth 3 rb)))))

(define (t--wn-setup!)
  (layout-target-set! #f)
  (for-each (lambda (b) (test-buffer! b "")) (list t--wn-a t--wn-b))
  (delete-other-windows!)
  (switch-to-buffer! t--wn-a)
  (split-window! 'v 0.5)
  (other-window!)
  (switch-to-buffer! t--wn-b)
  (set-frame-local! 'winner-ring '())
  (set-frame-local! 'winner-pos #f))

;; a command as the key loop runs it: the pre- and post-command steps
(define (t--wn-command! thunk)
  (winner--pre-command!)
  (thunk)
  (winner--post-command!))

(define (t--wn-done!)
  (layout-target-set! #f)
  (delete-other-windows!)
  (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
            (list t--wn-a t--wn-b)))

(deftest 'winner-undo-returns-the-arrangement-a-layout-command-destroyed
  "the shortcut path: tile, undo, and the configuration hook keeps the restored tree"
  (lambda ()
    (t--wn-setup!)
    (check-true! (t--wn-stacked?) "the hand-made arrangement stacks a above b")
    (t--wn-command! (window-layout-command 'columns))
    (check-equal! (length (frame-local 'winner-ring)) 1 "the command's arrangement change entered the ring once")
    (check-equal! (layout-target) 'columns "the command sets the target")
    (check-true! (not (t--wn-stacked?)) "columns put a beside b")
    (winner-previous!)
    (check-true! (t--wn-stacked?) "undo brings the stacked arrangement back")
    (window-configuration-changed!)
    (check-true! (t--wn-stacked?) "the configuration hook leaves the restored arrangement alone")
    (t--wn-done!)))

(deftest 'winner-undo-returns-the-arrangement-the-layout-prompt-destroyed
  "the prompt path: preview, confirm, undo"
  (lambda ()
    (t--wn-setup!)
    (let ((saved (window-tree)))
      (window-layout-preview-without-history! "columns" (list t--wn-a t--wn-b))
      (window-layout-preview-without-history! "rows" (list t--wn-a t--wn-b))
      (window-layout-choose! saved "columns" (list t--wn-a t--wn-b))
      (check-equal! (layout-target) 'columns "the choice sets the target")
      (check-true! (not (t--wn-stacked?)) "columns put a beside b")
      (check-equal! (length (frame-local 'winner-ring)) 1 "the previews never entered the ring")
      (winner-previous!)
      (check-true! (t--wn-stacked?) "undo returns to before the prompt")
      (window-configuration-changed!)
      (check-true! (t--wn-stacked?) "the configuration hook leaves it alone")
      (winner-next!)
      (check-true! (not (t--wn-stacked?)) "redo brings the chosen layout back"))
    (t--wn-done!)))

(deftest 'winner-undo-under-a-target-keeps-the-restored-arrangement
  "the engine re-arranges when the panes change; a winner walk is not a change of panes"
  (lambda ()
    (t--wn-setup!)
    (t--wn-command! (lambda () (tile-visible-windows! 'two-pane (list t--wn-b t--wn-a))))
    (check-true! (not (t--wn-stacked?)) "the layout put the panes side by side")
    (layout-target-set! #f)
    (winner-previous!)
    (check-true! (t--wn-stacked?) "undo brings the stacked arrangement back")
    (window-configuration-changed!)
    (check-true! (t--wn-stacked?) "the configuration hook leaves the restored arrangement alone")
    (t--wn-done!)))

(deftest 'winner-records-nothing-under-a-look-or-a-stack-entry
  "a preview and a stack entry that is popped leave the ring as it was"
  (lambda ()
    (t--wn-setup!)
    (t--wn-command! (lambda () (preview-show t--wn-a 'other)))
    (t--wn-command! (lambda () (preview-end #f)))
    (t--wn-command!
      (lambda ()
        (let ((token (arrangement-push! 'zz-wn)))
          (delete-other-windows!)
          (arrangement-pop! token))))
    (window-configuration-changed!)
    (check-equal! (frame-local 'winner-ring) '() "the ring is empty")
    (check-true! (t--wn-stacked?) "and the arrangement is the one before")
    (t--wn-command! (lambda () (delete-other-windows!) (split-window! 'h 0.5)))
    (check-equal! (length (frame-local 'winner-ring)) 1 "one command, one entry")
    (t--wn-done!)))
