;;; detail.scm --- a list opens its rows into one window, and keeps it.
;;;
;;; Every table whose rows are their own buffer needs the same thing:
;;; Sentry issues, WhatsApp chats, MCP servers, Google items. RET on a row
;;; shows that row's buffer beside the list, and the NEXT row takes the
;;; same window. Each row is a new buffer name, so display-buffer's
;;; reuse-window never matches: without this the layout grows a pane per
;;; row, or the row has to be a peek to stay in one place.
;;;
;;; A detail is not a peek. It is kept, it is writable, and it stays when
;;; the list goes. Three things make it:
;;;
;;;   THE WINDOW IS REMEMBERED, per list, the way a peek remembers its own
;;;     (docs/PEEK.md). The first row picks one through the display chain
;;;     as category detail; every row after it retakes that window. This is
;;;     the one place a window is remembered rather than chosen at display
;;;     time, and the memory lapses on its own.
;;;   THE LIST OWNS WHAT IT OPENED: the detail is the list's child
;;;     (dismiss.scm), so q on the list takes the detail with it, and the
;;;     details opened from one list are each other's siblings.
;;;   C-` WALKS THE SIBLINGS in the detail window, most recent first. Three
;;;     rows opened is three buffers to flip through without going back to
;;;     the list. It is chat-mode's key doing chat-mode's job for any list.
;;;
;;; A list that rewrites ONE detail buffer per row (notmuch's *mail*, the
;;; telemetry event) needs none of this: reuse-window already finds the
;;; name. Such a list may still call display-buffer-detail! for the window,
;;; and the walk then has one buffer and says so.

(domain! 'windows)
(effects! '(read))

(define *detail-windows* '())   ;; ((OWNER WINDOW) ...)

;; the window the list OWNER opens its rows into, while it is still one to
;; use: a live work window, not the asking window, and not holding the list
(define (detail-window &optional owner)
  (let* ((o (or owner (window-buffer (active-window))))
         (hit (assoc o *detail-windows*))
         (win (and hit (cadr hit))))
    (and win
         (member win (display--work-windows))
         (not (equal? win (active-window)))
         (not (equal? (window-buffer win) o))
         win)))

;; the list this detail was opened from, or #f
(define (detail-owner &optional buf)
  (let ((b (or buf (current-buffer))))
    (and (boundp 'buffer-parent) (buffer-parent b))))

;; the walk order: this buffer, then the other details of the same list,
;; most recently used first. Open buffers only, exactly as a chat pane walks.
(define (detail-ring)
  (let* ((buf (current-buffer))
         (owner (detail-owner buf))
         (kin (if (and owner (boundp 'buffer-children)) (buffer-children owner) '()))
         (open (buffer-list)))
    (cons buf
          (filter (lambda (b) (and (member b kin)
                                   (member b open)
                                   (not (equal? b buf))))
                  (buffer-list-mru)))))

(public! 'detail-window
  "(detail-window [OWNER]) — the window the list OWNER opens its rows into, or #f")
(public! 'detail-owner
  "(detail-owner [BUF]) — the list BUF was opened from, or #f")

(effects! '(write display))

(define (detail-window-forget! owner)
  (set! *detail-windows*
        (filter (lambda (e) (not (equal? (car e) owner))) *detail-windows*)))

(define (detail-window-note! owner win)
  (detail-window-forget! owner)
  (set! *detail-windows* (cons (list owner win) *detail-windows*))
  win)

;; the list owns what it opened, and what it opened knows the key that
;; walks its siblings
(define (detail-adopt! owner name)
  (when (and (boundp 'buffer-child!)
             (buffer-known? owner) (buffer-known? name)
             (not (equal? owner name))
             (not (equal? (detail-owner name) owner)))
    (buffer-child! owner name))
  (unless (minor-mode-on? name "detail-mode")
    (enable-minor-mode! name "detail-mode"))
  name)

;; show NAME in the window OWNER opens its rows into, keep that window for
;; the next row, and select nothing: point stays in the list. OWNER names
;; the list, and defaults to the buffer that is asking.
(define (display-buffer-detail! name &optional owner)
  (let* ((o (or owner (window-buffer (active-window))))
         (shown (window-showing-other name (active-window)))
         (kept (and (not shown) (detail-window o)))
         (win (cond
                (shown shown)
                (kept (group-layout-save-before-cover! name)
                      (window-display! (lambda () (display-buffer-in-window! kept name))))
                (else (display-buffer name '(category detail inhibit-same-window #t))))))
    (when win
      (detail-window-note! o win)
      (detail-adopt! o name))
    win))

;;; --- the walk -------------------------------------------------------------------

(define *detail-ring* '())
(define *detail-pos* 0)

;; The first press lands on the buffer you came from and each further press
;; goes one deeper; any other command ends the walk. Two details and the key
;; flips between them.
(define (detail-cycle! dir)
  (unless (member (last-command) '("detail-next" "detail-previous"))
    (set! *detail-ring* (detail-ring))
    (set! *detail-pos* 0))
  (let ((live (filter buffer-known? *detail-ring*)))
    (unless (= (length live) (length *detail-ring*))
      (set! *detail-ring* live)
      (when (>= *detail-pos* (length live)) (set! *detail-pos* 0))))
  (let ((n (length *detail-ring*)))
    (if (< n 2)
        (message "No other detail open from this list")
        (begin
          (set! *detail-pos* (modulo (+ *detail-pos* dir) n))
          (switch-to-buffer! (list-ref *detail-ring* *detail-pos*))))))

(define-command "detail-next"
  "Walk the details opened from this list, most recently used first"
  (lambda () (detail-cycle! 1)))

(define-command "detail-previous"
  "Walk the details opened from this list, the other way"
  (lambda () (detail-cycle! -1)))

;; the key is the detail's own, so it shadows the global popup toggle only
;; while you stand in a detail, the way chat-mode shadows it in a chat
(register-minor-mode! "detail-mode" (lambda (buf) #t) (lambda (buf) #t))
(minor-mode-keys! "detail-mode" '(("C-`" "detail-next") ("C-M-`" "detail-previous")))

(public! 'display-buffer-detail!
  "(display-buffer-detail! NAME [OWNER]) — show NAME in the one window the list OWNER opens its rows into, keep that window for the next row, and select nothing")
(public! 'detail-window-forget!
  "(detail-window-forget! OWNER) — drop the window OWNER opens its rows into; the next row picks one again")
