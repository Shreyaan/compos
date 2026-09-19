;;; popper.scm --- popups: buffers you call up and send away, after popper.el.
;;;
;;; A popup is an ordinary buffer in an ordinary window. The list
;;; popper-reference-buffers names the buffers that are popups: a string
;;; is a regexp on the buffer name, a symbol is a major mode (a derived
;;; mode matches too), and a procedure takes the name and answers.
;;;
;;; A display of a popup goes through display-buffer. The rule here sends
;;; it to the bottom of the frame: to the window that shows a popup
;;; already, else to a new window split from the root of the frame. The
;;; popup window then has the selection, as in popper. It has normal
;;; focus and takes every window command. The layout does not tile it
;;; (window-work-buffer?).
;;;
;;; popper-toggle closes the popup on screen, or shows the latest popup
;;; again. popper-cycle shows the next popup in the popup window.
;;; popper-toggle-type makes the popup an ordinary buffer, or makes the
;;; current buffer a popup.
;;;
;;; A close is the quit-window restore: the window shows the buffer the
;;; popup covered, or the window goes when a popup display made it. When
;;; the buffer under a popup is a popup too, that popup comes back, and
;;; its own close deletes the window.

(domain! 'windows)
(effects! '(read))

;; Empty by default: no buffer is a popup until the list names it. The
;; popper README example is '("\\*Messages\\*" "Output\\*$" help-mode).
(defcustom 'popper-reference-buffers '()
  "The buffers that are popups. A string is a regexp on the buffer name, a symbol is a major mode, and a procedure takes the name. popper-toggle-type overrides the list for one buffer. Example: '(\"\\\\*Messages\\\\*\" help-mode)."
  'group 'windows 'type 'list)

;; the share of the frame a new popup window takes (popper-window-height)
(define popper-window-height (/ 1 3))

;; the list's answer for BUF
(define (popper--reference? buf)
  (let ((mode (buffer-local buf 'mode-name)))
    (let loop ((refs popper-reference-buffers))
      (cond ((null? refs) #f)
            ((cond ((string? (car refs)) (re-match? (car refs) buf))
                   ((symbol? (car refs))
                    (and (string? mode) (derived-mode? mode (symbol->string (car refs)))))
                   ((procedure? (car refs)) ((car refs) buf))
                   (else #f))
             #t)
            (else (loop (cdr refs)))))))

;; A popup. The buffer's own status wins over the list: popper-toggle-type
;; writes 'popper-popup-status, 'popup or 'raised. A hidden buffer, a peek
;; and a float are never popups: each has its own window.
(define (popper-popup? buf)
  (and (string? buf) (buffer-known? buf)
       (not (string-prefix? " " buf))
       (not (peek-buffer? buf))
       (not (float--class? buf))
       (let ((status (buffer-local buf 'popper-popup-status)))
         (cond ((equal? status 'popup) #t)
               ((equal? status 'raised) #f)
               (else (popper--reference? buf))))))

;; the window of the latest popup on screen: the selected window when it
;; shows a popup, else the first window that shows one, or #f
(define (popper-window)
  (if (popper-popup? (window-buffer (active-window)))
      (active-window)
      (let loop ((ws (window-list)))
        (cond ((null? ws) #f)
              ((popper-popup? (cadr (car ws))) (car (car ws)))
              (else (loop (cdr ws)))))))

;; the popups, most recent first: the buffer ring is the record of use
(define (popper-buffers)
  (filter popper-popup? (buffer-list-mru)))

;;; --- the display ---------------------------------------------------------------

;; A display of a popup that is not a look takes the popper rule.
(define (popper-display-control? name alist)
  (and (not *display-preview*)
       (not (plist-get alist 'category))
       (popper-popup? name)))

;; popper-select-popup-at-bottom: the window that shows NAME, else the
;; popup window, else a new window across the bottom of the frame. The
;; window is selected.
(define-display-action! 'popper-bottom
  (lambda (name alist)
    (let ((win (or (window-showing name)
                   (popper-window)
                   (split-root! 'v (- 1 popper-window-height)))))
      (when win
        (unless (equal? (window-buffer win) name)
          (display-buffer-in-window! win name))
        (select-window! win))
      win)))

(add-display-rule! popper-display-control? 'popper-bottom)
(set! *display-buffer-outside-layout*
  (cons 'popper-bottom (remove (lambda (a) (equal? a 'popper-bottom))
                               *display-buffer-outside-layout*)))
(set! window-work-buffer? (lambda (buf) (not (popper-popup? buf))))

;;; --- close, toggle, cycle ----------------------------------------------------------

;; Close the popup in WIN (quit-window). The window shows the buffer the
;; popup covered, or it goes when a popup display made it. A popup that
;; comes back this way stands in a window that popups made, so its
;; record says so: its own close deletes the window. With no record, the
;; window shows the last buffer of its history that is not a popup, as
;; Emacs switch-to-prev-buffer does, or it goes.
(define (popper-close! win)
  (let* ((rec (window-restore win))
         (kind (and rec (car rec)))
         (under (and (equal? kind 'other) (cadr rec)))
         (other? (pair? (cdr (window-list))))
         (past (filter (lambda (b) (not (popper-popup? b))) (window-eligible-history win))))
    (cond ((and under (buffer-known? under))
           (display-buffer-in-window! win under)
           (when (popper-popup? under) (set-window-restore! win '(window #f #f)))
           #t)
          ((and (equal? kind 'window) other?) (delete-window-id! win) #t)
          ((pair? past)
           (display-buffer-in-window! win (car past))
           (set-window-restore! win #f)
           #t)
          (other? (delete-window-id! win) #t)
          (else (message "The popup is the last window") #f))))

;; the latest popup that no window shows
(define (popper-latest)
  (let loop ((bs (popper-buffers)))
    (cond ((null? bs) #f)
          ((window-showing (car bs)) (loop (cdr bs)))
          (else (car bs)))))

(define-command "popper-toggle" "Close the popup on screen, or show the latest popup again"
  (lambda ()
    (let ((w (popper-window)))
      (cond (w (popper-close! w))
            ((popper-latest) (display-buffer (popper-latest)))
            (else (message "No popup"))))))

;; The next popup is the one used least recently, so each press shows a
;; popup that did not show for longest, and the presses reach them all.
(define-command "popper-cycle" "Show the next popup in the popup window"
  (lambda ()
    (let ((w (popper-window))
          (others (let ((bs (popper-buffers)))
                    (filter (lambda (b) (not (window-showing b))) bs))))
      (cond ((null? others)
             (if w (message "No other popup") (message "No popup")))
            (w (display-buffer (car (reverse others))))
            (else (display-buffer (car others)))))))

;; popper-toggle-type. A popup becomes an ordinary buffer: its popup
;; window closes and the display chain shows it in a work window. Any
;; other buffer becomes a popup: its window goes back to what it showed
;; before, and the buffer shows at the bottom.
(define-command "popper-toggle-type" "Make this popup an ordinary buffer, or make this buffer a popup"
  (lambda ()
    (let ((buf (current-buffer))
          (win (active-window)))
      (if (popper-popup? buf)
          (begin
            (buffer-set-local! buf 'popper-popup-status 'raised)
            (when (equal? (window-buffer win) buf) (popper-close! win))
            (pop-to-buffer buf)
            (message (string-append buf " is an ordinary buffer now")))
          (begin
            (buffer-set-local! buf 'popper-popup-status 'popup)
            (when (equal? (window-buffer win) buf) (window-unwind-or-close! win))
            (display-buffer buf)
            (message (string-append buf " is a popup now")))))))

;; popper's README keys: C-` toggles, M-` cycles, C-M-` changes the type
(global-set-key "C-`" "popper-toggle")
(global-set-key "M-`" "popper-cycle")
(global-set-key "C-M-`" "popper-toggle-type")

(catalog-meta! 'command "popper-toggle" 'domain 'windows 'effects '(write display))
(catalog-meta! 'command "popper-cycle" 'domain 'windows 'effects '(write display))
(catalog-meta! 'command "popper-toggle-type" 'domain 'windows 'effects '(write display))

(public! 'popper-popup?
  "(popper-popup? NAME) — #t when NAME is a popup: its own status, else popper-reference-buffers")
(public! 'popper-window
  "(popper-window) — the window of the latest popup on screen, or #f")
(public! 'popper-buffers
  "(popper-buffers) — the popups, most recent first")
(effects! '(write display))
(public! 'popper-close!
  "(popper-close! WIN) — close the popup in WIN: show the buffer it covered, or delete the window a popup display made")
