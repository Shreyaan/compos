;;; completion.scm --- completion while you type
;;;
;;; editor.scm's capf framework answers "what completes here". It never
;;; asks: M-/ is the only caller. This package is the asking. A mode
;;; opts in with (capf-auto-watch! BUF) from its mode hook, and from
;;; then on typing in that buffer offers what M-/ would have offered.
;;;
;;; The watch is the on-change! + debounce! pattern the checkers use, so
;;; a burst of keys costs one collect, not one per key.
;;;
;;; Only a mode whose sources answer synchronously opts in. An
;;; asynchronous source returns #f and shows the popup later from its
;;; own callback, so the collect falls through to dabbrev, dabbrev
;;; paints, and the server's answer replaces it a moment later. M-/
;;; hides that; typing would show it on every key. lsp-mode therefore
;;; stays manual until a source can answer 'pending.

(domain! 'editing)
(effects! '(write))

(defgroup 'completion "Completion at point.")

(defcustom 'completion-auto #t
  "Offer completions while you type, in the modes that ask for it."
  'group 'completion 'type 'boolean)

(defcustom 'completion-auto-delay 150
  "Milliseconds of quiet typing before completion asks."
  'group 'completion 'type 'number)

(defcustom 'completion-auto-prefix 2
  "The fewest characters before point that make completion ask."
  'group 'completion 'type 'number)

;; The popup belongs to a frame, and completion-show! measures the range
;; it replaces against that frame's own buffer, not against a buffer a
;; caller scoped with with-current-buffer. So ask only while the frame
;; still stands on BUF: anywhere else the range would name another file,
;; and accepting it would cut that file instead. The test doubles as the
;; one that matters anyway -- a popup in a buffer nobody looks at is
;; noise, and the user may have walked away during the debounce.
(define (capf-auto-fire! buf)
  "offer completions in BUF now, or take the popup away"
  (when (and completion-auto (buffer-known? buf) (equal? (current-buffer) buf))
    (let ((r (capf-collect (capf-sources))))
      (if (and (pair? r)
               (pair? (caddr r))
               (>= (- (point) (car r)) completion-auto-prefix))
          (completion-show! (car r) (cadr r) (caddr r))
          (completion-dismiss!)))))

;; Only a person typing forward asks. An agent edit, an undo and a
;; delete all leave the popup alone: the popup's own DEL narrows it.
(define (capf-auto--changed! buf inserted deleted source)
  (when (and completion-auto
             (equal? source "user")
             (equal? deleted 0)
             (string? inserted)
             (not (equal? inserted "")))
    (debounce! (string-append "capf-auto:" buf)
               completion-auto-delay
               (lambda (b) (capf-auto-fire! b))
               buf)))

(define (capf-auto-watch! buf)
  "ask for completions while you type in BUF; a mode calls this once"
  (unless (buffer-local buf 'capf-auto-watch)
    (desktop-skip! buf 'capf-auto-watch)
    (buffer-set-local! buf 'capf-auto-watch
      (on-change! buf
        (lambda (pos inserted deleted source)
          (capf-auto--changed! buf inserted deleted source))))))
