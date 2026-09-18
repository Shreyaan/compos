;;; window.scm --- windows: display-buffer, popups, peek, layouts, special-mode, tiling.
;;;
;;; Emacs's window.el, in one file: the display-buffer chain and its actions,
;;; the popup and the look, peek, the mode layouts, special-mode and
;;; quit-window, winner, and the tiling commands. init.scm loads it second,
;;; before dired: a list mode derives from special-mode at load.

(domain! 'files)
(effects! '(read))

;;; --- display-buffer & popups (popper) ----------------------------------------
;;; *display-buffer-alist* says WHERE a buffer goes. It is Emacs' alist of
;;; the same name, in the shape this editor needs: a list of
;;;
;;;   (PATTERN ACTION PARAMS)
;;;
;;; read in order, first match wins. PATTERN is a substring of the buffer
;;; name, or (category KIND) for a kind of display the caller names
;;; ((category preview) is a peek; (category foreign) is a buffer from
;;; outside the frame's group). ACTION is one action name or a list
;;; of them, tried in order; the display-buffer section below lists them.
;;; The two this editor started with:
;;;
;;;   'same    show it in the selected window (same-window)
;;;   'popup   a side window: one per frame, reused, and it floats
;;;
;;; A buffer with no rule takes *display-buffer-base-action* and then
;;; *display-buffer-fallback-action*: reuse a window that shows it, split
;;; a window big enough, use another window, else this one.
;;; PARAMS is a plist, and every key has a default, so a rule says only
;;; what it wants to change:
;;;
;;;   'side   'right | 'left | 'top | 'bottom | 'center
;;;           default right, or bottom on compact frames
;;;           'center floats a fixed modal in the middle of the frame
;;;   'size   the share of the frame it takes     default one third
;;;
;;; A popup floats over the frame — see popup-float! for what that means
;;; and what it deliberately does not change. `C-\`` toggles it and
;;; `C-M-\`` settles it into the layout, on the side it already floats on.

(define *window-third* (/ 1 3))

;; The main layouts read these. They are plain defines here, because
;; editor.scm loads before custom.scm; layouts.scm makes them customs.
;; The main pane's share of the frame, and how the other panes arrange
;; beside it: 'column stacks them, 'grid tiles them.
(define window-layout-main-ratio (- 1 *window-third*))
(define window-layout-stack 'column)

(define *display-buffer-defaults* (list 'side 'right 'size *window-third*))

;; Packages can make the default responsive without changing explicit display
;; rules. layouts.scm chooses bottom on compact frames and right otherwise.
(define popup-default-side (lambda () 'right))

(define *display-buffer-alist*
  ;; nothing floats. No stock rule names the popup, so a listing, the
  ;; messages, a shell take the window chain like any other buffer
  (list
        ;; a detail a list opens from one of its rows takes another
        ;; window and KEEPS it (packages/detail.scm): reuse a window
        ;; before growing the layout by a pane per row
        (list '(category detail) '(reuse-window use-some-window pop-up-window) '())
        ;; a preview takes another window, and buffer replacement puts
        ;; the window back. A buffer from outside the frame's group
        ;; takes a window the same way.
        ;; Last, so a rule for a name wins, and a rule of your own
        ;; (add-display-rule! conses in front) wins too
        (list '(category preview) '(reuse-window use-some-window pop-up-window) '())
        (list '(category foreign) '(reuse-window use-some-window pop-up-window) '())))

;; A buffer from outside the frame's group. groups.scm answers; with no
;; groups, no buffer is foreign. A display of a foreign buffer that names
;; no category of its own is a display of category foreign, and the
;; stock rule sends it to the popup. A rule of your own for
;; (category foreign) routes it elsewhere; a pane that shows it then
;; takes the frame out of the group.
(define display-foreign? (lambda (name) #f))

(define (display--alist-with-category name alist)
  (if (and (not (plist-get alist 'category)) (display-foreign? name))
      (append (list 'category 'foreign) alist)
      alist))

;; PARAMS is optional, so every rule written before the params existed
;; still reads the same and takes the defaults
(define (add-display-rule! pattern action &optional params)
  (set! *display-buffer-alist*
    (cons (list pattern action (if params params '()))
          *display-buffer-alist*)))

;; a rule matches a name by substring, or a category the caller passed in
;; ALIST as 'category; a rule written (category . KIND) reads the same
(define (display-rule-match? condition name alist)
  (cond ((string? condition) (string-contains? name condition))
        ((and (pair? condition) (equal? (car condition) 'category))
         (let ((kind (cdr condition)))
           (equal? (if (pair? kind) (car kind) kind)
                   (plist-get alist 'category))))
        (else #f)))

;; the rule for NAME, or a rule with no action: the chain then starts
;; at the base action
(define (display-rule-for name &optional alist)
  (let ((a (or alist '())))
    (let loop ((rules *display-buffer-alist*))
      (cond ((null? rules) (list name '() '()))
            ((display-rule-match? (car (car rules)) name a) (car rules))
            (else (loop (cdr rules)))))))

(define (display-action-for name &optional alist)
  (let ((actions (display-buffer-actions-for name alist)))
    (if (null? actions) #f (car actions))))

;; a rule's own value, else the default for that key
(define (display-rule-param name key)
  (let* ((rule (display-rule-for name))
         (rest (cdr (cdr rule)))
         (params (if (null? rest) '() (car rest)))
         (v (plist-get params key)))
    v))

(define (display-param name key)
  (or (display-rule-param name key)
      (plist-get *display-buffer-defaults* key)))

;; frame-local policy state: values keyed by the selected frame — each
;; browser gets its own popup, its own ibuffer home window. Pruned when a
;; frame is deleted.
(define *frame-locals* '())   ; ((frame ((key val) ...)) ...)

(define (frame-local-in frame key)
  (let ((fr (assoc frame *frame-locals*)))
    (if fr
        (let ((kv (assoc key (cadr fr))))
          (if kv (cadr kv) #f))
        #f)))

(define (frame-local key)
  (frame-local-in (selected-frame) key))

(define (set-frame-local! key val)
  (let* ((frame (selected-frame))
         (fr (assoc frame *frame-locals*))
         (locals (if fr (cadr fr) '()))
         (rest (filter (lambda (e) (not (equal? (car e) frame))) *frame-locals*))
         (others (filter (lambda (e) (not (equal? (car e) key))) locals)))
    (set! *frame-locals* (cons (list frame (cons (list key val) others)) rest))))

(define (prune-frame-locals!)
  (let ((live (frame-list)))
    (set! *frame-locals*
      (filter (lambda (e) (member (car e) live)) *frame-locals*))))

;; The window that floats. The frame local lives in memory and dies with
;; the daemon, but the floating class is a buffer-local and comes back
;; with the desktop — so a restored popup is still a popup, and `C-\`` and
;; `C-M-\`` still reach it. Read the class when the local has nothing
;; live to say.
;; the class carries the side too — "popup popup-right" — so read it as
;; the prefix it is. Read for equality, this never matched, the frame
;; local was the only answer, and a restored popup split the frame a
;; second time every time you opened it.
(define (popup--class? buf)
  (let ((c (buffer-local buf 'window-class)))
    (and c (string-prefix? "popup" c))))

(define (popup--by-class)
  (let loop ((ws (window-list)))
    (cond ((null? ws) #f)
          ((popup--class? (cadr (car ws))) (car (car ws)))
          (else (loop (cdr ws))))))

(define (popup-window)
  (let ((w (frame-local 'popup-window)))
    (if (and w (window-exists? w) (popup--class? (window-buffer w)))
        w
        (popup--by-class))))

(define (popup-buffer)
  (or (frame-local 'popup-buffer)
      (let ((w (popup--by-class)))
        (and w (cadr (assoc w (window-list)))))))

(define (window-exists? id)
  (assoc id (window-list)))

;; a leftover popup that became the sole window (C-x 1 from inside it)
;; is not a popup anymore — treat it as closed so display-buffer splits
(define (popup-open?)
  (and (popup-window)
       (window-exists? (popup-window))
       (not (null? (cdr (window-list))))))

;; Where the popup came from. A popup is a visit, not a move. Closing it
;; restores work windows changed by a preview. The return record is
;; (WINDOW BUFFER POINT). The work record is ((WINDOW BUFFER) ...).
;;
;; Read the buffer from the window, never from (current-buffer): a popup
;; can open from inside a prompt, and (current-buffer) answers with the
;; minibuffer while one is open.
;;
;; The record lives in memory and dies with the daemon. A popup restored
;; from the desktop has nothing to go back to, so its close only closes.
(define (popup-remember!)
  (let ((w (active-window)))
    (unless (popup-open?)
      (set-frame-local! 'popup-work (window-list))
      (set-frame-local! 'popup-layout (window-tree)))
    ;; a popup that shows the next popup does not move you: the window
    ;; you came from is still the one the first popup remembered
    (when (not (equal? w (popup-window)))
      (set-frame-local! 'popup-return
        (list w (window-buffer w) (buffer-point (window-buffer w)))))))

(define (popup-saved-layout)
  (or (frame-local 'popup-layout)
      (let ((buf (popup-buffer)))
        (and buf (buffer-local buf 'popup-return-layout)))))

(define (popup-forget!)
  (let ((buf (popup-buffer)))
    (when (and buf (buffer-known? buf))
      (buffer-set-local! buf 'popup-return-layout #f)))
  (set-frame-local! 'popup-return #f)
  (set-frame-local! 'popup-work #f)
  (set-frame-local! 'popup-layout #f))

;; Restore only live buffers into surviving work windows. This preserves window
;; ids and ratios. It also does not recreate a buffer that ibuffer killed.
(define (popup-work-restore!)
  (for-each
    (lambda (row)
      (let ((w (car row)) (buf (cadr row)))
        (when (and (window-exists? w) (buffer-exists? buf)
                   (not (equal? (window-buffer w) buf)))
          (select-window! w)
          (switch-to-buffer-here! buf))))
    (or (frame-local 'popup-work) '())))

(define (popup-layout-live? layout)
  (and layout
       (null? (filter (lambda (buf) (not (buffer-exists? buf)))
                      (window-tree-buffers layout)))))

;; Go back. The window can be gone (you split or closed it from inside
;; the popup) and the buffer can be dead (ibuffer killed it) — each step
;; asks before it acts, and a step that cannot run leaves the rest alone.
(define (popup-return!)
  (let ((r (frame-local 'popup-return)))
    (popup-forget!)
    (when (and r (window-exists? (car r)))
      (select-window! (car r))
      (let ((buf (cadr r)))
        (when (and buf (buffer-exists? buf))
          (when (not (equal? (window-buffer (car r)) buf))
            (switch-to-buffer-here! buf))
          (goto-char! (caddr r)))))))

;; Closing the popup is three things, every time and in this order: the
;; buffer stops floating, the window goes, and you come back. You come
;; back only if you were IN the popup — `C-\`` from another window
;; dismisses it and leaves your focus alone.
;; The window is read ONCE. popup-window can answer from the class, and
;; the first step clears the class — read again after it, the answer is
;; #f and the window never goes.
;; Dismiss the popup's buffer: the one under it comes back, or the popup
;; closes when nothing waits. `q` in a listing and the toggles use this;
;; the popup toggle closes the whole popup.
(define (popup-dismiss!)
  (let loop ((stack (popup-stack)))
    (cond ((null? stack)
           (set-frame-local! 'popup-stack '())
           (popup-close!))
          ((buffer-known? (car stack))
           (set-frame-local! 'popup-stack (cdr stack))
           (set! *popup-dismissing* #t)
           (popup-show (car stack))
           (set! *popup-dismissing* #f))
          (else (loop (cdr stack))))))

(define (popup-close!)
  (set-frame-local! 'popup-stack '())
  (let* ((w (popup-window))
         (mine? (equal? (active-window) w))
         (buf (and w (window-buffer w)))
         (focus (active-window))
         (work (frame-local 'popup-work))
         (layout (popup-saved-layout)))
    ;; the buffer stops floating the moment it stops being the popup, or
    ;; it would float again in an ordinary window
    (when buf (popup-float! buf #f))
    (set-frame-local! 'popup-window #f)
    (cond
      ((pair? work)
       (when w (delete-window-id! w))
       (popup-work-restore!)
       (if mine?
           (popup-return!)
           (begin
             (when (window-exists? focus) (select-window! focus))
             (popup-forget!))))
      ((popup-layout-live? layout)
       (popup-forget!)
       (window-tree-set! layout))
      (else
       (when w (delete-window-id! w))
       (if mine? (popup-return!) (popup-forget!))))))

;; A popup FLOATS, and only visibly: it stays an ordinary window in the
;; tree, so every window command still reaches it. The class takes its
;; split out of the flow, so the window it covers keeps the whole frame
;; underneath. SIDE is the edge it floats against, or #f to stop
;; floating — `C-M-\`` passes #f and the popup becomes an ordinary split,
;; which is popper's toggle-type under popper's key.
;; In the popup, M-<left>, M-<right>, M-<up>, and M-<down> move it to
;; that edge. The keys are the popup's, not the buffer's: they go in
;; when the buffer floats and out when it stops, and the mode setup then
;; gives the buffer its own keys back.
(define *popup-keys*
  '(("M-<left>" "popup-move-left") ("M-<right>" "popup-move-right")
    ("M-<up>" "popup-move-up") ("M-<down>" "popup-move-down")
    ;; Cmd-RET keeps what floats: the popup becomes an ordinary window.
    ("s-RET" "popup-bufferize")))

(register-minor-mode! "popup-mode" (lambda (buf) #t) (lambda (buf) #t))
(minor-mode-keys! "popup-mode" *popup-keys*)

(define (popup-keys! name floating?)
  (if floating?
      (enable-minor-mode! name "popup-mode")
      (disable-minor-mode! name "popup-mode"))
  (buffer-set-local! name 'popup-keys (and floating? #t)))

;; A buffer can ask for more window classes than the popup gives it. The
;; extra words come after the side, so popup-side-of still reads the side.
(define (popup--extra-classes name)
  (let ((extra (buffer-local name 'window-classes)))
    (if (and (string? extra) (not (equal? extra "")))
        (string-append " " extra)
        "")))

;; A window floats because of its class, and for no other reason: the
;; pane is in the tree either way. So a change of shape is a change of
;; two locals. It runs no mode setup, which is what lets a prompt change
;; shape with its table still standing, filter and row intact.
(define (window-float-class! name side &optional size)
  (buffer-set-locals! name
    (list 'window-class
            (and side (string-append "popup popup-" (symbol->string side)
                                     (popup--extra-classes name)))
          ;; the share is a number, and CSS cannot read a Scheme list —
          ;; hand it over as a custom property the stylesheet already reads
          'window-style
            (and side size
                 (string-append "--popup-size:" (number->string (* 100 size)) "%")))))

(define (popup-float! name side &optional size)
  (let ((had-keys (buffer-local name 'popup-keys)))
    (window-float-class! name side size)
    (cond (side (popup-keys! name #t))
          (had-keys
           (popup-keys! name #f)
           ;; the buffer's own M-arrows come back with its mode. Not for a
           ;; peek: it is read-only, it dies when replaced, and a mode
           ;; setup is the one thing here that could move anything.
           (when (and (buffer-exists? name)
                      (not (and (boundp 'peek-buffer?) (peek-buffer? name))))
             (restore-buffer-runtime! name))))))

(define (popup-move! side)
  (let ((buf (current-buffer)))
    (if (not (and (popup-open?) (equal? (active-window) (popup-window))))
        (message "Not in the popup")
        (begin
          ;; the side a buffer was moved to is the side it opens on next
          (buffer-set-local! buf 'popup-side side)
          (popup-float! buf side (display-param buf 'size))
          (message (string-append "Popup on the " (symbol->string side)))))))

(define-command "popup-move-left" "Float the popup against the left edge"
  (lambda () (popup-move! 'left)))
(define-command "popup-move-right" "Float the popup against the right edge"
  (lambda () (popup-move! 'right)))
(define-command "popup-move-up" "Float the popup against the top edge"
  (lambda () (popup-move! 'top)))
(define-command "popup-move-down" "Float the popup against the bottom edge"
  (lambda () (popup-move! 'bottom)))

;; The popup FLOATS: its class says which edge, and its place in the
;; tree does not show. So the new window is always SECOND, whatever the
;; side, and the window it covers keeps its id and its place. A swap
;; into first place for the left and the top moved the covered window
;; to the other side of its half and carried the ids with the buffers.
;; popup-bufferize swaps when the popup becomes a real window.
(define (popup--split-for side size)
  (split-window! (if (or (equal? side 'top) (equal? side 'bottom)) 'v 'h)
                 (- 1 size))
  (other-window!))

;; the side a floating buffer wears, from its class, or #f. The class can
;; carry more words after the side, so the side is the first word.
(define (popup-side-of buf)
  (let ((c (and buf (buffer-local buf 'window-class))))
    (and c (string-prefix? "popup popup-" c)
         (let* ((rest (substring c (string-length "popup popup-") (string-length c)))
                (space (string-index rest " ")))
           (string->symbol (if space (substring rest 0 space) rest))))))

;; The popup shows one buffer at a time. A buffer shown over another
;; keeps it underneath (popper's stack): dismiss the top one and the one
;; under it comes back; close the popup and the stack empties.
(define *popup-dismissing* #f)

(define (popup-stack) (or (frame-local 'popup-stack) '()))

;; a peek is a look: replaced, it is killed, so it never waits on the
;; stack. Dead names are pruned as the stack is written, so it holds
;; live buffers only and cannot grow past them.
(define (popup-stack-push! name)
  (unless (and (boundp 'peek-buffer?) (peek-buffer? name))
    (set-frame-local! 'popup-stack
      (cons name (filter (lambda (b) (and (not (equal? b name)) (buffer-known? b)))
                         (popup-stack))))))

(define (popup-stack-drop! name)
  (set-frame-local! 'popup-stack
    (remove (lambda (b) (equal? b name)) (popup-stack))))

(define (popup-show-on name side size)
    ;; before the focus moves: this is the place you come back to
    (popup-remember!)
    (let ((old (popup-buffer))
          (layout (popup-saved-layout)))
      (when (and old (not (equal? old name)) (buffer-known? old))
        (buffer-set-local! old 'popup-return-layout #f)
        ;; the buffer this one covers waits underneath
        (when (and (popup-open?) (not *popup-dismissing*))
          (popup-stack-push! old)))
      (popup-stack-drop! name)
      (set-frame-local! 'popup-buffer name)
      (when layout (buffer-set-local! name 'popup-return-layout layout)))
    (popup-float! name side size)
    (if (popup-open?)
        (let ((was (window-buffer (popup-window))))
          (select-window! (popup-window))
          (switch-to-buffer! name)
          ;; the buffer this one replaces stops floating: the class is a
          ;; buffer-local, and a buffer that kept it floated in every
          ;; window it was shown in after
          (when (and was (not (equal? was name)) (buffer-exists? was))
            (popup-float! was #f)))
        (begin
          (popup--split-for side size)
          (set-frame-local! 'popup-window (active-window))
          (switch-to-buffer! name))))
(domain! 'files)
(effects! '(read))

;;; --- a look is not a use ------------------------------------------------------
;;; The MRU ring records the buffers the reader USED. A preview is not a
;;; use: the reader moves down a listing and every row shows for as long
;;; as the point rests on it. The buffer table sorts its rows by the ring,
;;; so a preview that bumped the ring rewrote the list under the point.
;;;
;;; While this flag stands, a display sets the window's buffer through
;;; window-preview-buffer!, which changes the window and leaves the ring
;;; alone. peek-show! binds it, so every look goes this way: the buffer
;;; table, dired, occur, and every list mode that peeks a row.

(define *display-preview* #f)

;; show NAME in WIN: the ring records it, unless this is a look
(define (window-show-buffer! win name)
  (if *display-preview*
      (window-preview-buffer! name win)
      (window-set-buffer! win name)))

(define (with-display-preview thunk)
  (let ((was *display-preview*))
    (set! *display-preview* #t)
    (let ((r (thunk)))
      (set! *display-preview* was)
      r)))

;; where the popup floats: the rule's side, else the side the buffer was
;; last moved to, else the default, which is the right edge
;; Show NAME in the popup without moving the selection: a preview takes
;; no focus. The popup window's buffer is set in place; a new popup is
;; split, filled, and the selection goes back where it was, in one
;; step. A quiet popup records no return place, no work windows, and no
;; layout: nothing is restored when it closes, because nothing moved.
;; The restores are for a popup you entered, and they carried every
;; window's point back to the moment the popup opened.
(define (popup-show-quietly name side size)
  (let ((me (active-window)))
    (let ((old (popup-buffer)))
      (when (and old (not (equal? old name)) (buffer-known? old))
        (when (and (popup-open?) (not *popup-dismissing*))
          (popup-stack-push! old)))
      (popup-stack-drop! name)
      (set-frame-local! 'popup-buffer name))
    (popup-float! name side size)
    (if (popup-open?)
        (let* ((w (popup-window))
               (was (window-buffer w)))
          (window-show-buffer! w name)
          (when (and was (not (equal? was name)) (buffer-exists? was))
            (popup-float! was #f)))
        (begin
          (popup--split-for side size)
          (let ((w (active-window)))
            (set-frame-local! 'popup-window w)
            (window-show-buffer! w name)
            (select-window! me))))
    (window-state-changed!)
    (popup-window)))

(define (popup-show name)
  (popup-show-on name
    (or (display-rule-param name 'side)
        (buffer-local name 'popup-side)
        (popup-default-side))
    (display-param name 'size)))

;; Nothing floats any more. The old popup door is kept so an older
;; caller still works, and it shows the buffer in an ordinary window.
;; SIDE and SIZE say nothing.
(define (display-buffer-popup! name &optional side size)
  (display-buffer name))
(domain! 'files)
(effects! '(read))

;;; --- display-buffer actions (Emacs window.el) ---------------------------------
;;; display-buffer shows NAME somewhere and returns the window. It selects
;;; nothing. pop-to-buffer shows and selects. switch-to-buffer! shows in
;;; the selected window. Where "somewhere" is comes from a chain of
;;; actions, tried in order until one answers with a window:
;;;
;;;   the rule for NAME in *display-buffer-alist*
;;;   *display-buffer-base-action*       the user's, empty by default
;;;   *display-buffer-fallback-action*   reuse-window mode-window
;;;                                      pop-up-window use-some-window
;;;                                      same-window
;;;
;;; The actions, each a function of NAME and ALIST on the display-action hook:
;;;
;;;   reuse-window     a window that shows NAME already
;;;   mode-window      a work window whose buffer has NAME's major mode: a
;;;                    group keeps one window per mode, so every chat lands
;;;                    in the chat pane
;;;   pop-up-window    split the largest work window when it is big
;;;                    enough (split-window-sensibly), else the selected one
;;;   use-some-window  another work window; the popup and a peek are not one
;;;   same-window      the selected window (also 'same)
;;;   popup            the side window (popup-show)
;;;
;;; ALIST is a plist the caller passes. 'category names the kind of display,
;;; and a rule (category KIND) matches it. 'inhibit-same-window #t keeps
;;; the selected window out of the chain. A window the chain made or took
;;; is noted for quit-window: q deletes the window the display made, or
;;; puts back the buffer the display replaced.
;;;
;;; The thresholds are Emacs' own: a window splits below when it has
;;; split-height-threshold rows, beside when it has split-width-threshold
;;; columns, and the sole work window splits below whatever its size.
;;; layouts.scm makes the four variables customizable.

(define split-height-threshold 80)
(define split-width-threshold 160)
(define window-min-height 4)
(define window-min-width 10)
(define *display-buffer-base-action* '())
(define *display-buffer-fallback-action*
  '(reuse-window mode-window pop-up-window use-some-window same-window))
;; an action is the keyed hook (display-action NAME)
(define (define-display-action! name fn) (add-hook! (list 'display-action name) fn))

(define (display-action-fn name)
  (let ((fs (hook-functions (list 'display-action name))))
    (and (pair? fs) (car fs))))

;; Explicit layouts remain targets as their occupied pane count changes.
(define (layout-target) (frame-local 'layout-target))
(define (layout-target-set! name)
  (set-frame-local! 'layout-target name)
  (unless name (set-frame-local! 'layout-slots #f))
  (when (and name (not (frame-local 'layout-slots)))
    (let ((visible (layout-visible-buffers)))
      (layout-target-note-slots!
        (if (and (member name '(main-left main-top)) (pair? visible))
            (cons (car (reverse visible)) (take visible (- (length visible) 1)))
            visible))))
  (set-frame-local! 'layout-target-count (length (layout-visible-buffers)))
  (layout-target-modeline!)
  name)

;;; The modeline names the chosen layout as Markdown: `*layout*:NAME`. The label
;;; is bold and the target reads plainly beside it, with no segment gap between
;;; the two spans. The text is compared before it is set, so the change hook
;;; that calls this on every window move does no work on an unchanged frame.
(define (layout-target-modeline-text)
  (let ((target (layout-target)))
    (string-append ":" (cond ((not target) "free")
                             ((symbol? target) (symbol->string target))
                             (else target)))))

(define (layout-target-modeline-shown)
  (let ((entry (assq 'layout-value *global-mode-string*)))
    (and entry (pair? (cadr entry)) (cadr (cadr entry)))))

(define (layout-target-modeline!)
  (let ((text (layout-target-modeline-text)))
    (unless (equal? text (layout-target-modeline-shown))
      (global-mode-string-set! 'layout-label '("ml-segment ml-strong" "layout"))
      (global-mode-string-set! 'layout-value (list "ml-segment ml-tight" text)))))

;; A target is an algorithm and a capacity, not a frozen accidental tree.
(define (layout-target-capacity target)
  (cond ((equal? target 'two-pane) 2)
        ((equal? target 'columns) 3)
        (else #f)))

;; Logical slot order is independent of focus and of the side holding main.
;; Match each occurrence once so deliberate duplicate views remain distinct.
(define (layout-target-note-slots! panes)
  (let loop ((names panes) (rows (window-list)) (out '()))
    (if (null? names)
        (begin
          (set-frame-local! 'layout-slots (reverse out))
          (set-frame-local! 'layout-target-count (length out)))
        (let ((matches (filter (lambda (row) (equal? (cadr row) (car names))) rows)))
          (if (null? matches)
              (loop (cdr names) rows out)
              (loop (cdr names)
                    (filter (lambda (row) (not (equal? (car row) (car (car matches))))) rows)
                    (cons (car matches) out)))))))

(define (layout-visible-window? row)
  (and (not (equal? (car row) (popup-window)))
       (not (popup--class? (cadr row)))
       (not (window-dock? (car row) (cadr row)))))

(define (layout-target-visible-buffers)
  (let ((visible (map cadr (filter layout-visible-window? (window-list)))))
    ;; The current tree is authoritative: a manual swap or restored tree can
    ;; keep window IDs while changing their order. Cached IDs must not undo it.
    ;; Main-left/top place the logical main last in physical tree order.
    (if (and (pair? visible) (member (layout-target) '(main-left main-top)))
        (cons (car (reverse visible)) (take visible (- (length visible) 1)))
        visible)))

(define (layout-target-arrange! panes focus)
  (let ((target (layout-target))
        (token (if (equal? focus (window-buffer (active-window)))
                   (layout-focus-token) (list focus 0))))
    (when (pair? panes)
      (if (equal? target 'adaptive)
          (tile-adaptive-windows! panes)
          (tile-windows! target panes))
      (layout-focus-restore! token)
      panes)))

(define (layout-focus-token)
  (let ((name (window-buffer (active-window))))
    (let loop ((rows (window-list)) (occurrence 0))
      (cond ((null? rows) (list name 0))
            ((equal? (car (car rows)) (active-window)) (list name occurrence))
            (else (loop (cdr rows)
                    (+ occurrence (if (equal? (cadr (car rows)) name) 1 0))))))))

(define (layout-focus-restore! token)
  (let ((matches (filter (lambda (row) (equal? (cadr row) (car token))) (window-list))))
    (when (pair? matches)
      (select-window! (car (nth (min (cadr token) (- (length matches) 1)) matches))))))

;; A user open selects its result. A display records how to quit and keeps focus.
(define (layout-target-open! name select? inhibit-same?)
  (and (fill-candidate? name) (window-fill-member? name)
       (not (buffer-context?))
       (let* ((selected (active-window))
              (focus (window-buffer selected))
              (shown (if inhibit-same?
                         (window-showing-other name selected)
                         (window-showing name)))
              ;; One window per mode outranks the target's spare capacity. A
              ;; three-column target is no licence to show two chats: the
              ;; second one takes the pane the first one already holds.
              (kin (and (not shown)
                        (window-showing-mode (buffer-local name 'mode-name)
                                             (and inhibit-same? selected))))
              (panes (layout-target-visible-buffers))
              (capacity (layout-target-capacity (layout-target))))
         (cond (shown
                (when select? (select-window! shown))
                shown)
               (kin
                (display-buffer-in-window! kin name)
                (when select? (select-window! kin))
                kin)
               ((and (not (member name panes))
                     (or (not capacity) (< (length panes) capacity)))
                (layout-target-arrange! (append panes (list name)) (if select? name focus))
                (window-showing name))
               (else
                 (let ((win (if select? selected (layout-replacement-window selected))))
                   (when win
                     (display-buffer-in-window! win name)
                     (when select? (select-window! win))
                     win)))))))

;; Results replace the least recently used other work pane. Ties keep order.
(define (layout-replacement-window selected)
  (let ((mru (buffer-list-mru)))
    (define (rank buf)
      (let loop ((rest mru) (n 0))
        (cond ((null? rest) n)
              ((equal? (car rest) buf) n)
              (else (loop (cdr rest) (+ n 1))))))
    (let loop ((windows (display--work-windows)) (best #f) (age -1))
      (if (null? windows)
          best
          (let* ((win (car windows))
                 (score (rank (window-buffer win))))
            (if (and (not (equal? win selected)) (> score age))
                (loop (cdr windows) win score)
                (loop (cdr windows) best age)))))))

;; Window changes reflow occupied slots. Closing a pane does not reopen hidden work.
(define (layout-target-on-change!)
  (layout-target-modeline!)
  (when (and (layout-target) (not *layout-busy*)
             (not (minibuffer-state)) (not (popup-open?)))
    (let ((panes (layout-target-visible-buffers))
          (focus (window-buffer (active-window))))
      (when (and (pair? panes)
                 (not (equal? (length panes) (frame-local 'layout-target-count))))
        (layout-target-arrange! panes focus)))))

(add-hook! 'window-configuration-change-hook 'layout-target-on-change!)

(define (display--keep-shape actions)
  (if (layout-target)
      (map (lambda (a) (if (equal? a 'pop-up-window) 'use-some-window a)) actions)
      actions))

;; the chain for NAME: the rule's actions, then the base, then the fallback
(define (display-buffer-actions-for name &optional alist)
  (let* ((a (display--alist-with-category name (or alist '())))
         (rule (cadr (display-rule-for name a)))
         (own (cond ((null? rule) '())
                    ((pair? rule) rule)
                    (else (list rule)))))
    (display--keep-shape
      (append own *display-buffer-base-action* *display-buffer-fallback-action*))))

;;; what a display did to a window, for quit-window: (WIN KIND PREV).
;;; KIND 'window: the display made the window, and quit deletes it.
;;; KIND 'other: the display took a window that showed PREV, and quit
;;; puts PREV back.
(define *window-quit-restore* '())

(define (window-quit-restore-note! win kind prev)
  (set! *window-quit-restore*
    (cons (list win kind prev)
          (filter (lambda (e) (and (not (equal? (car e) win))
                                   (window-exists? (car e))))
                  *window-quit-restore*))))

(define (window-display! thunk)
  (let* ((before (map (lambda (row) (list (car row) (cadr row))) (window-list)))
         (win (thunk))
         (previous (and win (assoc win before))))
    (when (and win (window-exists? win))
      (cond ((not previous)
             (window-quit-restore-note! win 'window #f))
            ((not (equal? (cadr previous) (window-buffer win)))
             (window-quit-restore-note! win 'other (cadr previous)))))
    win))

(define (window-quit-restore win) (assoc win *window-quit-restore*))

(define (window-quit-restore-forget! win)
  (set! *window-quit-restore*
    (filter (lambda (e) (not (equal? (car e) win))) *window-quit-restore*)))

;; undo what a display did to WIN: delete it, or put back what it
;; showed. #t when something was undone. The last window is never deleted.
(define (window-quit-restore! win)
  (let ((rec (window-quit-restore win)))
    (window-quit-restore-forget! win)
    (cond ((not rec) #f)
          ((not (window-exists? win)) #f)
          ((and (equal? (cadr rec) 'window) (pair? (cdr (window-list))))
           (if (equal? win (active-window))
               (delete-window!)
               (delete-window-id! win))
           #t)
          ((and (equal? (cadr rec) 'other) (caddr rec)
                (fill-candidate? (caddr rec)) (window-fill-member? (caddr rec)))
           (window-set-buffer! win (caddr rec))
           (window-state-changed!)
           #t)
          (else #f))))

;;; geometry, from the selected window's measure and the fractional rects

;; the work windows: not the popup, not a peek
(define (display--work-windows)
  (let ((popup (and (popup-open?) (popup-window))))
    (filter (lambda (w) (and (not (equal? w popup))
                             (not (window-dock? w (window-buffer w)))
                             (not (and (boundp 'peek-buffer?) (peek-buffer? (window-buffer w))))))
            (map car (window-list)))))

;; (ROWS COLS) of WIN, as the frame measures them
(define (window-size-of win)
  (let* ((rs (window-rects))
         (me (assoc (active-window) rs))
         (r (assoc win rs)))
    (if (and me r (> (nth 5 me) 0))
        (list (* (nth 5 r) (/ (window-rows) (nth 5 me)))
              (* (nth 4 r) (frame-cols)))
        (list (window-rows) (window-cols)))))

;; the largest work window by area, else the selected one
(define (display--largest-work-window)
  (let ((rs (window-rects)))
    (let loop ((ws (display--work-windows)) (best #f) (area 0))
      (cond ((null? ws) (or best (active-window)))
            (else
              (let* ((r (assoc (car ws) rs))
                     (a (if r (* (nth 4 r) (nth 5 r)) 0)))
                (if (> a area)
                    (loop (cdr ws) (car ws) a)
                    (loop (cdr ws) best area))))))))

;; Emacs window-splittable-p: 'v is one above the other, 'h side by side
(define (window-splittable? win dir)
  (let* ((size (window-size-of win))
         (rows (car size))
         (cols (cadr size)))
    (if (equal? dir 'v)
        (and (>= rows split-height-threshold) (>= rows (* 2 window-min-height)))
        (and (>= cols split-width-threshold) (>= cols (* 2 window-min-width))))))

;; split WIN, which need not be the selected window, and answer the new
;; window. The selection is where it was.
(define (split-window-in! win dir)
  (let ((me (active-window))
        (before (map car (window-list))))
    (unless (equal? win me) (select-window! win))
    (split-window! dir 0.5)
    (let ((new (let loop ((ws (window-list)))
                 (cond ((null? ws) #f)
                       ((member (car (car ws)) before) (loop (cdr ws)))
                       (else (car (car ws)))))))
      (unless (equal? (active-window) me) (select-window! me))
      new)))

;; Emacs split-window-sensibly: below when WIN is tall enough, else
;; beside when it is wide enough, else below anyway when WIN is the only
;; work window and can hold two. The new window, or #f.
(define (split-window-sensibly win)
  (let ((dir (cond ((window-splittable? win 'v) 'v)
                   ((window-splittable? win 'h) 'h)
                   ((and (null? (cdr (display--work-windows)))
                         (>= (car (window-size-of win)) (* 2 window-min-height)))
                    'v)
                   (else #f))))
    (and dir (split-window-in! win dir))))

;; show NAME in window WIN, selecting nothing. A buffer the user can see
;; is a buffer the user can switch to; a floating buffer shown anywhere
;; but the popup stops floating.
(define (display-buffer-in-window! win name)
  (when (and (not *display-preview*) (boundp 'buffer-promote!)) (buffer-promote! name))
  (window-show-buffer! win name)
  (when (and (popup--class? name) (not (equal? win (frame-local 'popup-window))))
    (popup-float! name #f))
  (window-state-changed!)
  win)

;; the popup action is kept for a rule written before popups went away,
;; and it takes the ordinary window chain
(define-display-action! 'popup
  (lambda (name alist)
    (display-buffer-run-actions name alist *display-buffer-fallback-action*)))

;; Where a shaped surface goes: the dock when it is a minibuffer, the
;; popup window when it is a panel or a modal. A buffer says which with
;; its own 'window-shape, so the rule needs no argument.
(define-display-action! 'shaped
  (lambda (name alist)
    (let ((shape (or (buffer-local name 'window-shape) minibuffer-default-shape))
          (docked (window-docked name)))
      (cond ((not (equal? shape "minibuffer")) (popup-show name))
            ((and docked (window-exists? docked)) (select-window! docked) docked)
            (else (window-dock! name (display-param name 'size)))))))

(define-display-action! 'same-window
  (lambda (name alist)
    (if (plist-get alist 'inhibit-same-window)
        #f
        (begin (switch-to-buffer-here! name) (active-window)))))

(define-display-action! 'same (display-action-fn 'same-window))

(define-display-action! 'reuse-window
  (lambda (name alist)
    (if (plist-get alist 'inhibit-same-window)
        (window-showing-other name (active-window))
        (window-showing name))))

;; A window prefers the mode of its work buffer. Temporary covers keep the
;; preference of the nearest work buffer in its own history. This uses the
;; history already carried through tiling and desktop restore.
(define (window-mode win)
  (let ((buf (window-buffer win)))
    (and (string? buf) (buffer-local buf 'mode-name))))

;; special-mode also includes persistent listings, so it does not mean cover.
;; Help is a cover by default; other surfaces may opt in with a buffer local.
(define (window-preference-cover? buf)
  (or (buffer-local buf 'window-preference-cover)
      (buffer-derived-mode? buf "help-mode")))

(define (window-preferred-mode win)
  (or (and (boundp 'window-cycle-mode) (window-cycle-mode win))
      (let loop ((buffers (cons (window-buffer win) (window-prev-buffers win))))
        (cond ((null? buffers) (window-mode win))
              ((and (buffer-known? (car buffers))
                    (not (window-preference-cover? (car buffers))))
               (buffer-local (car buffers) 'mode-name))
              (else (loop (cdr buffers)))))))

(define (window-prefers-buffer? win buf)
  (let ((mode (window-preferred-mode win)))
    (and (string? mode) (buffer-derived-mode? buf mode))))

;; The selected window comes first, so a command that opens one thing still
;; opens it where you are: you are already in the window of its mode.
(define (window-showing-mode mode &optional except)
  (and (string? mode)
       (let ((me (active-window))
             (work (display--work-windows)))
         (define (fits? w)
           (and (not (equal? w except))
                (or (equal? (window-preferred-mode w) mode)
                    (equal? (window-mode w) mode))))
         (if (and (member me work) (fits? me))
             me
             (let loop ((ws work))
               (cond ((null? ws) #f)
                     ((fits? (car ws)) (car ws))
                     (else (loop (cdr ws)))))))))

(define-display-action! 'mode-window
  (lambda (name alist)
    (let ((win (window-showing-mode
                 (buffer-local name 'mode-name)
                 (and (plist-get alist 'inhibit-same-window) (active-window)))))
      (and win (display-buffer-in-window! win name)))))

(define-display-action! 'pop-up-window
  (lambda (name alist)
    (let* ((me (active-window))
           (largest (display--largest-work-window))
           (win (or (split-window-sensibly largest)
                    (and (not (equal? largest me)) (split-window-sensibly me)))))
      (and win (display-buffer-in-window! win name)))))

(define-display-action! 'use-some-window
  (lambda (name alist)
    (let ((win (layout-replacement-window (active-window))))
      (and win (display-buffer-in-window! win name)))))

;; show NAME where the chain says, selecting nothing; the window, or #f
(define (display-buffer-run-actions name alist actions)
  (if (null? actions)
      #f
      (let* ((fn (display-action-fn (car actions)))
             (win (and fn (fn name alist))))
        (or win (display-buffer-run-actions name alist (cdr actions))))))

(define (display-buffer name &optional alist)
  (let ((a (or alist '())))
    ;; a board, a listing, any surface from outside the group takes its
    ;; pane through here. Record the group's arrangement BEFORE the
    ;; cover, or a switch made FROM the board has no way back — the
    ;; capture rule below only fires from a member buffer, and the board
    ;; is not one.
    (group-layout-save-before-cover! name)
    (let ((actions (display-buffer-actions-for name a)))
      (window-display!
        (lambda ()
          (or (and (layout-target) (not *layout-busy*) (pair? actions)
                   (not (member (car actions) '(popup same same-window)))
                   (layout-target-open! name #f (plist-get a 'inhibit-same-window)))
              (display-buffer-run-actions name a actions)))))))

;; show NAME and select its window (Emacs pop-to-buffer)
(define (pop-to-buffer name &optional alist)
  (let ((win (display-buffer name alist)))
    (when (and win (window-exists? win) (not (equal? win (active-window))))
      (select-window! win))
    win))

;; show NAME in a window other than the selected one, point staying put —
;; the display-buffer contract behind Emacs previews (occur/grep/consult):
;; windows are never remembered, they are chosen HERE, at display time.
;; window-set-buffer! takes a window id. switch-to-buffer! cannot do this
;; job: it answers a frame buffer-context before it looks at a window, so
;; an agent asked to show a file moved only its own context and the window
;; never changed. Nothing here selects a window, so point stays put.
;; The one exception is a list's detail window, which is remembered on
;; purpose so every row lands in the same place (packages/detail.scm).
(define (display-buffer-other-window! name)
  (display-buffer name '(inhibit-same-window #t)))
(domain! 'files)
(effects! '(read))

;;; --- peek -----------------------------------------------------------------------
;;; A peek shows a buffer to look at it, without adopting it into the
;;; workspace. RET on a row peeks; RET again keeps. The rules:
;;;
;;;   ONE peek at a time. The next peek replaces the last one. A buffer
;;;     that a peek MADE is killed when it is replaced. A buffer that
;;;     existed before the peek is only shown, never killed.
;;;   THE PEEK WINDOW is another window, never the popup. A look goes
;;;     beside the listing: the peek takes a window that is not the
;;;     reader's, and the next peek takes that same window again. The
;;;     buffer it replaced comes back when the peek goes.
;;;   A PEEK IS READ-ONLY (peek-mode, a minor mode): a stray key changes
;;;     nothing, and q dismisses it.
;;;   OPEN is M-RET on the row (peek-open!): the mark goes, the peek
;;;     window gives the buffer up, and the selected window shows it as
;;;     a visit would. KEEP alone is M-x keep-buffer, or a change from
;;;     outside the keyboard.
;;;   A replaced peek leaves a row in RECENT. The switcher lists recent
;;;     below the live buffers, and RET there peeks it again.
;;;
;;; The mark is the minor mode, and it is saved with the buffer: a peek
;;; on screen at a restart comes back as a peek, read-only.

;; The mode. A peek is read-only: a look changes nothing, and the
;; read-only keymap gives it q. The setup runs on enable and again on a
;; restore, so it records the buffer's own state once; keep puts that
;; state back.
(register-minor-mode! "peek-mode"
  (lambda (buf)
    (unless (buffer-local buf 'peek-own-read-only)
      (buffer-set-local! buf 'peek-own-read-only
        (if (buffer-read-only? buf) 'yes 'no)))
    (buffer-set-read-only! buf #t))
  (lambda (buf)
    (buffer-set-read-only! buf (equal? (buffer-local buf 'peek-own-read-only) 'yes))
    (buffer-set-local! buf 'peek-own-read-only #f)))

(mode-doc! "peek-mode"
  "A look at a buffer without keeping it: read-only, in another window. q dismisses it; M-RET on the row opens it as your own.")

(define (peek-buffer? name)
  (and (string? name) (buffer-exists? name) (minor-mode-on? name "peek-mode")))

(define (peek-buffers) (filter peek-buffer? (buffer-list)))

;;; recent: what a peek showed and let go. An entry is
;;; (LABEL KIND KEY TIME): KIND names the reviver, KEY is what it needs.

(defvar '*peek-recent* '() 'persist #t)
(define *peek-recent-max* 50)

(define (peek-recent-find key)
  (let ((hits (filter (lambda (x) (equal? (nth 2 x) key)) *peek-recent*)))
    (and (pair? hits) (car hits))))

;; how NAME comes back: a file by its path, a page by its URL, a
;; directory by its dir. #f for a buffer nothing can rebuild.
(define (peek-recent-entry name)
  (let ((path (buffer-path name))
        (url (buffer-local name 'browse-url))
        (dir (buffer-local name 'dired-dir)))
    (cond ((and (string? url) (not (equal? url "")))
           (list name 'browse url (current-time)))
          ((and (string? dir) (not (equal? dir "")))
           (list name 'dired dir (current-time)))
          ((and (string? path) (not (equal? path "")))
           (list name 'file path (current-time)))
          (else #f))))

(define (peek-remember! name)
  (let ((e (peek-recent-entry name)))
    (when e
      (set! *peek-recent*
        (take (cons e (filter (lambda (x) (not (equal? (nth 2 x) (nth 2 e))))
                                *peek-recent*))
                *peek-recent-max*)))))

(define (peek-forget-recent! key)
  (set! *peek-recent*
    (filter (lambda (x) (not (equal? (nth 2 x) key))) *peek-recent*)))

;; a recent row comes back as a peek: the same look, the same choice
(define (peek-revive! entry)
  (let ((kind (nth 1 entry))
        (key (nth 2 entry)))
    (cond ((and (equal? kind 'browse) (boundp 'web--tab-for!))
           (peek! (web--buffer-for key) (lambda () (web--tab-for! key))))
          ((equal? kind 'dired)
           (peek! key (lambda () (dired-open key))))
          ((equal? kind 'file)
           (peek-file! key))
          (else #f))))

;; let NAME go: remember it, kill it. A buffer with a live process is
;; never a peek, so nothing here stops one.
(define (peek-drop! name)
  (when (peek-buffer? name)
    (peek-remember! name)
    (buffer-kill! name)))

;; every peek but KEEP-ONE and the buffer the reader is in goes
(define (peek-drop-others! keep-one)
  (let ((here (current-buffer)))
    (for-each (lambda (b)
                (unless (or (equal? b keep-one) (equal? b here)
                            ;; a peek the reader put in a second window
                            ;; is theirs to look at
                            (window-showing b))
                  (peek-drop! b)))
              (peek-buffers))))

;; The peek slot is the window the last peek used, per frame. It is
;; remembered, not derived: a peek of a buffer that already existed
;; leaves no mark behind, and the next peek must still land in the
;; same window instead of splitting again. Keeping the buffer in the
;; slot releases the window (peek-keep!).
;; show NAME as the peek: in another window, always. The selected
;; window and its point stay. Returns the window the peek took.
;; the side away from the window the peek was asked from. The stock
;; rule sends no peek to the popup any more, so this answers only a
;; rule of your own that does. A window on the right half of the frame
;; gets the popup on the left; any other, the right.
(define (peek-side-away-from win)
  (let ((r (assoc win (window-rects))))
    (if (and r (> (+ (nth 2 r) (* 0.5 (nth 4 r))) 0.5)) 'left 'right)))

;; A peek is a preview: it takes no focus. The window shows it without
;; a selection change, and the focus commands pass it by.
;; A peek is a display of category preview. The stock rule sends it
;; through the window chain, and the next peek takes the window the last
;; one had. A rule of your own ((add-display-rule! '(category preview)
;; 'popup)) puts it back in the popup, and the popup path below answers.
(define (peek-show! name)
  (let* ((me (active-window))
         ;; a look leaves the MRU ring where it was: the reader looked,
         ;; the reader did not switch. A peek is always a window beside
         ;; the reader: nothing floats.
         (win (with-display-preview
                (lambda () (peek-show-in-window! name me)))))
    (set-frame-local! 'peek-window win)
    ;; what the look put on screen, by name: a buffer that existed
    ;; before wears no mode, and q must still take it away
    (set-frame-local! 'peek-shown name)
    (peek-drop-others! name)
    win))

(define (peek-show-in-popup! name me)
  (let* ((old (and (popup-open?) (popup-buffer)))
         (side (or (and old (popup-side-of old)) (peek-side-away-from me))))
    (popup-show-quietly name side (plist-get *display-buffer-defaults* 'size))))

;; the window the last peek used, while it still shows that peek
(define (peek--window-to-reuse me)
  (let ((pw (frame-local 'peek-window))
        (shown (frame-local 'peek-shown)))
    (and pw shown (window-exists? pw) (not (equal? pw me))
         (not (and (popup-open?) (equal? pw (popup-window))))
         (equal? (window-buffer pw) shown)
         pw)))

(define (peek-show-in-window! name me)
  (let* ((reuse (peek--window-to-reuse me))
         (win (if reuse
                  (display-buffer-in-window! reuse name)
                  (display-buffer name '(category preview inhibit-same-window #t)))))
    (unless (equal? (active-window) me) (select-window! me))
    win))

;; a window the focus commands may land on: not a peek's
(define (window-focusable? w)
  (let ((b (window-buffer w)))
    (not (and b (peek-buffer? b)))))

;; the peek verb. OPEN makes or finds the buffer and returns its name.
;; KNOWN is the name it will have, so "did the peek make it" is answered
;; before OPEN runs: a buffer that was known stays a real buffer. OPEN
;; may move the selected window (visit does); the window is put back.
;; A quiet popup is transparent to the point: nothing in this path
;; selects a window. OPEN opens the buffer, best without a window
;; (visit-quietly); an opener that showed it in the selected window has
;; the listing put back there, in place, with no selection change.
(define (peek! known open)
  (let* ((existed? (and (string? known) (buffer-known? known) #t))
         (me (active-window))
         (here (current-buffer))
         (buf (open)))
    (when (and (string? buf) (not (equal? buf here)))
      (unless (equal? (window-buffer me) here)
        (window-preview-buffer! here me))
      (unless existed? (enable-minor-mode! buf "peek-mode"))
      (peek-show! buf))
    buf))
(domain! 'files)
(effects! '(read))

;;; --- how big a file a look opens --------------------------------------------
;;; A look is not an open. Reading the file costs its bytes, the mode costs
;;; a parse of them, and the window costs one line structure per line. A
;;; listing of machine-generated files can put an 18 MB blob under the
;;; point, and a look there is seconds of work for a row the reader passes
;;; over. Above the cap a look shows nothing and says the size.
;;;
;;; The cap holds a LOOK only. RET opens the file, whatever its size: the
;;; reader asked for that one. A buffer that is open already is shown as
;;; before, because the work is paid.
;;;
;;; layouts.scm makes the variable customizable.

(define peek-max-file-size 1048576)

;; #t when a look at PATH would open a file too big to look at. A path
;; with a buffer already, a directory, and a remote path all answer #f:
;; file-size reads local files, and a remote stat answers 0. So does a
;; file shown from disk: a look at a video reads none of it.
(define (peek-too-big? path)
  (and (> peek-max-file-size 0)
       (string? path)
       (not (file-shown-from-disk? path))
       (let ((p (normalize-file-input path)))
         (and (not (buffer-known? p))
              (not (file-directory? p))
              (> (file-size p) peek-max-file-size)))))

;; Say why the window did not change. The size is the whole reason, so the
;; message carries it and the name of the variable that sets the cap.
(define (peek-say-too-big! path)
  (let ((p (normalize-file-input path)))
    (message (string-append (cadr (path-split p)) " is " (cadr (file-stat p))
                            ", too big to look at. RET opens it."))
    #f))

;; a file, peeked: the one opener every listing of files shares
(define (peek-file! path)
  (if (peek-too-big? path)
      (peek-say-too-big! path)
      (peek! path (lambda () (visit-quietly path)))))

;; RET twice: the first press peeks KNOWN, the second keeps it and goes
;; there. Returns 'peek or 'keep.
(define (peek-or-keep! known open)
  (if (and (string? known) (peek-buffer? known) (window-showing known))
      (begin
        (peek-keep! known)
        (select-window! (window-showing known))
        'keep)
      (begin (peek! known open) 'peek)))

;; RET on a row: peek KNOWN, or open it when it is the peek on screen
(define (peek-or-open! known open)
  (if (and (string? known) (peek-buffer? known) (window-showing known))
      (peek-open! known open)
      (begin (peek! known open) 'peek)))

;; the buffer the last look put in the popup, while the popup still
;; shows it: a peek, or a buffer that existed before and only shows
(define (peek-shown)
  (let ((b (frame-local 'peek-shown))
        (w (frame-local 'peek-window)))
    (and b
         (or (and (popup-open?) (equal? (popup-buffer) b))
             (and w (window-exists? w) (equal? (window-buffer w) b)))
         b)))

;; dismiss the look on screen: the popup gives the buffer up, and a
;; buffer the peek made goes to recent. #t when there was one.
(define (peek-dismiss!)
  (let ((shown (dedupe-names
                 (append (let ((b (peek-shown))) (if b (list b) '()))
                         (filter window-showing (peek-buffers))))))
    (for-each (lambda (p)
                (if (and (popup-open?) (equal? (popup-buffer) p))
                    (popup-dismiss!)
                    ;; a peek the window chain placed: the window it made
                    ;; goes, or the buffer it replaced comes back
                    (let ((w (window-showing p)))
                      (when w (window-quit-restore! w))))
                (when (peek-buffer? p) (peek-drop! p)))
              shown)
    (set-frame-local! 'peek-shown #f)
    (pair? shown)))

;; any work window that is not ME: the popup is not one
(define (other-work-window-id me)
  (let ((popup (and (popup-open?) (popup-window))))
    (let loop ((ws (window-list)))
      (cond ((null? ws) #f)
            ((and (not (equal? (car (car ws)) me))
                  (not (equal? (car (car ws)) popup)))
             (car (car ws)))
            (else (loop (cdr ws)))))))

;; show NAME as your own beside the listing, never on top of it: the
;; other work window when there is one, else a split beside this one
;; (Emacs find-file-other-window). Selects the window it used.
(define (show-in-other-work-window! name)
  (let* ((me (active-window))
         (w (other-work-window-id me)))
    (cond ((display-foreign? name) (pop-to-buffer name))
          (w (select-window! w) (switch-to-buffer-here! name))
          (else (split-window! 'h 0.5) (other-window!) (switch-to-buffer-here! name)))
    (active-window)))

;; open KNOWN as a buffer of your own, beside the listing: the popup
;; gives it up, the mark goes, and the other work window shows it. Not a
;; peek yet, it opens the same way.
(define (peek-open! known open)
  (let ((me (active-window)))
    (when (and (string? known) (peek-buffer? known))
      (peek-keep! known)
      (when (and (popup-open?) (equal? (popup-buffer) known))
        (popup-dismiss!))
      (when (window-exists? me) (select-window! me)))
    (let ((buf (if (and (string? known) (buffer-known? known)) known (open))))
      (when (string? buf)
        ;; an opener may have shown it here; the listing takes its window back
        (when (and (window-exists? me) (not (equal? (window-buffer me) (current-buffer))))
          #t)
        (show-in-other-work-window! buf)))
    'open))

(define (peek-keep! name)
  (when (peek-buffer? name)
    (disable-minor-mode! name "peek-mode")
    ;; a kept buffer keeps its window: the slot moves on
    (let ((w (frame-local 'peek-window)))
      (when (and w (equal? (window-buffer w) name))
        (set-frame-local! 'peek-window #f)))
    (peek-forget-recent! (or (buffer-path name)
                             (buffer-local name 'browse-url)
                             (buffer-local name 'dired-dir)
                             name))
    (message (string-append "kept " name))))

;; an edit keeps: a file you typed in is yours. A listing reports itself
;; as modified and has no path, so only a file answers here.
(define (peek-keep-if-edited! b)
  (when (and (peek-buffer? b) (buffer-path b) (buffer-modified? b))
    (peek-keep! b)))

(define (peek--keep-if-edited-hook!)
    (peek-keep-if-edited! (current-buffer)))

(add-hook! 'post-command-hook 'peek--keep-if-edited-hook!)

(define-command "keep-buffer" "Keep this peek: it becomes an ordinary buffer"
  (lambda ()
    (let ((b (current-buffer)))
      (if (peek-buffer? b)
          (peek-keep! b)
          (message "not a peek")))))

(define-command "peek-recent" "Peek a buffer you looked at and let go"
  (lambda ()
    (if (null? *peek-recent*)
        (message "nothing recent")
        (minibuffer-read* "Recent: "
          (map (lambda (e) (list (nth 2 e) (car e))) *peek-recent*)
          (list (list 'match-hint 1)
                (list 'confirm
                      (lambda (key)
                        (let ((e (peek-recent-find key)))
                          (when e (peek-revive! e))))))))))

(public! 'window-fill-buffers
  "(window-fill-buffers) — the buffers a window in this frame may be filled with, most recent first: the frame's context, never the raw MRU ring")
(public! 'window-fill-blank
  "(window-fill-blank) — context scratch fallback, or #f; fixed target layouts leave spare capacity empty")
(public! 'buffer-special?
  "(buffer-special? NAME) — a view of something else (a listing, a diff, a mail thread), not a place you work: Emacs special-mode")
(public! 'fill-candidate?
  "(fill-candidate? NAME) — eligible ordinary buffer: known, not hidden, special, context-only, popup or peek")
(public! 'peek!
  "(peek! KNOWN OPEN) — show the buffer OPEN returns beside the selected window as a peek; KNOWN is its name, so a buffer that already existed is only shown and never killed; the next peek replaces it")
(public! 'peek-or-keep!
  "(peek-or-keep! KNOWN OPEN) — peek KNOWN, or keep it and go there when it is the peek on screen (browse's M-RET twice)")
(public! 'peek-or-open!
  "(peek-or-open! KNOWN OPEN) — RET on a row: peek KNOWN, or open it as your own when it is the peek on screen")
(public! 'peek-dismiss!
  "(peek-dismiss!) — dismiss every peek on screen; #t when there was one")
(public! 'peek-open!
  "(peek-open! KNOWN OPEN) — open KNOWN as your own in the selected window: a peek is kept and the popup gives it up; not a peek yet, OPEN runs")
(public! 'peek-file!
  "(peek-file! PATH) — peek the file at PATH")
(public! 'peek-keep!
  "(peek-keep! NAME) — keep a peek: clear the mark; the buffer and its window stay")
(public! 'peek-buffer?
  "(peek-buffer? NAME) — #t when NAME is a peek: shown to look at, killed when the next peek replaces it")
(public! 'peek-too-big?
  "(peek-too-big? PATH) — #t when a look at PATH would open a file over peek-max-file-size; a path with a buffer already, a directory, and a remote path answer #f")
(public! 'peek-say-too-big!
  "(peek-say-too-big! PATH) — say that PATH is too big to look at, and answer #f; the message names the size")
(public! 'file-shown-from-disk?
  "(file-shown-from-disk? PATH) — #t when PATH opens in a viewer that reads the file from disk: the buffer holds no bytes, and no size cap applies")
(public! 'buffer-unread-file?
  "(buffer-unread-file? BUF) — #t when BUF is bound to a file it never read; nothing in it stands for the file, so it is never saved over it")
(domain! 'files)
(effects! '(read))

;;; --- mode layouts -------------------------------------------------------------
;;; A display rule says where ONE buffer goes. A mode that owns the frame needs
;;; more: writing mode is a document and its scratch, side by side, and nothing
;;; else. The mode declares that arrangement as data, and this engine puts the
;;; windows there:
;;;
;;;   (define-mode-layout! "writing-mode" '(h 0.62 self scratch-buffer))
;;;
;;; The spec is (DIR RATIO PANE PANE ...), or one PANE alone for a full frame.
;;; DIR is 'h (side by side) or 'v (one above the other). RATIO is the share the
;;; first pane takes. A PANE names a buffer in one of three ways:
;;;
;;;   self       the buffer the mode is on
;;;   SYMBOL     the buffer named by that buffer-local of the anchor
;;;   "NAME"     that buffer, by name
;;;
;;; The engine drops a pane whose buffer does not exist, so a document with no
;;; scratch yet fills the frame alone. It arranges the frame when a mode turns
;;; on in the selected window, and stays out of the way everywhere else: the
;;; desktop rebuilds its own saved windows, a background buffer never replaces
;;; the windows in front of somebody, and the ordinary split and delete commands
;;; still work while the mode is on.

(define (define-mode-layout! mode spec) (mode-put! mode 'layout spec))
(define (mode-layout mode) (mode-get mode 'layout))

;; the layout BUF declares. A minor mode answers before the major mode: it is
;; the more specific statement about the same buffer.
(define (buffer-layout buf)
  (let loop ((names (append (or (buffer-local buf 'minor-modes) '())
                            (let ((m (buffer-local buf 'mode-name)))
                              (if m (list m) '())))))
    (if (null? names)
        #f
        (let ((spec (mode-layout (car names))))
          (if spec spec (loop (cdr names)))))))

;; A pane that may not exist yet: (ensure "NAME" "COMMAND") runs COMMAND
;; when NAME is absent, then uses NAME. This is what lets a declared
;; layout be the whole truth — kill a pane's buffer, ask for the layout
;; again, and the command builds it back. A plain "NAME" pane still
;; drops when it is missing, because a document with no scratch yet must
;; fill the frame alone.
(define (layout--ensure name maker)
  (unless (buffer-known? name)
    (when (string? maker) (run-command maker)))
  (and (buffer-known? name) name))

(define (layout--pane anchor pane)
  (cond ((equal? pane 'self) anchor)
        ((string? pane) (and (buffer-known? pane) pane))
        ((and (pair? pane) (equal? (car pane) 'ensure))
         (layout--ensure (car (cdr pane))
                         (and (pair? (cdr (cdr pane))) (car (cdr (cdr pane))))))
        ((symbol? pane)
         (let ((v (buffer-local anchor pane)))
           (and (string? v) (buffer-known? v) v)))
        (else #f)))

;; the buffers the spec names, in order, without repeats
(define (layout--panes anchor spec)
  (let loop ((rest (if (pair? spec) (cdr (cdr spec)) (list spec))) (acc '()))
    (if (null? rest)
        (reverse acc)
        (let ((b (layout--pane anchor (car rest))))
          (loop (cdr rest) (if (and b (not (member b acc))) (cons b acc) acc))))))

(define (layout--dir spec) (if (pair? spec) (car spec) 'h))
(define (layout--ratio spec) (if (pair? spec) (cadr spec) 0.5))

;; Return the window made by one split. Window ids are stable, so the new id
;; is the only id that was not present before the split.
(define (layout--new-window before)
  (let loop ((windows (window-list)))
    (cond ((null? windows) #f)
          ((not (member (car (car windows)) before)) (car (car windows)))
          (else (loop (cdr windows))))))

(define (layout--valid-ratio ratio fallback)
  (if (and (number? ratio) (> ratio 0) (< ratio 1)) ratio fallback))

;; Fill the selected leaf with BUFFERS along DIR. FIRST-RATIO controls the
;; first pane. Each later split divides the remaining space evenly. Three
;; panes therefore use 1/3, then 1/2, and finish as equal thirds.
(define (layout--fill-line! buffers dir first-ratio)
  (when (pair? buffers)
    (switch-to-buffer-here! (car buffers))
    (let loop ((rest (cdr buffers)) (first? #t))
      (when (pair? rest)
        (let* ((count (+ 1 (length rest)))
               (ratio (if first?
                          (layout--valid-ratio first-ratio (/ 1 count))
                          (/ 1 count)))
               (before (map car (window-list))))
          (split-window! dir ratio)
          (let ((new (layout--new-window before)))
            (when new
              (select-window! new)
              (switch-to-buffer-here! (car rest))
              (loop (cdr rest) #f)))))))
  buffers)

;;; A build makes its windows from one survivor: delete-other-windows!
;;; keeps one, and each split copies that one's history into the new
;;; window. Without a repair every pane remembers the survivor's past,
;;; a kill in a pane then shows the survivor's previous buffer, and the
;;; panes that went away take their pasts with them. So a build captures
;;; every window's (BUFFER . HISTORY) first and hands each new pane the
;;; history of the pane that showed its buffer. A pane on a buffer no
;;; window showed takes a pane that went away, that buffer first, so a
;;; kill there falls back to what the frame lost (Emacs prev-buffers).
(define (layout--capture-histories)
  (map (lambda (row)
         (list (cadr row) (window-prev-buffers (car row))
               (window-point (car row)) (window-quit-restore (car row))))
       (window-list)))

(define (layout--drop-record record records)
  (cond ((null? records) '())
        ((equal? record (car records)) (cdr records))
        (else (cons (car records) (layout--drop-record record (cdr records))))))

(define (layout--restore-histories! captured)
  (let ((shown (map cadr (window-list))))
    (let loop ((rows (window-list)) (remaining captured))
      (when (pair? rows)
        (let* ((win (car (car rows)))
               (buf (cadr (car rows)))
               (own (assoc buf remaining))
               (gone (filter (lambda (e) (not (member (car e) shown))) remaining))
               (record (or own (and (pair? gone) (car gone)))))
          (window-quit-restore-forget! win)
          (cond (own
                 (set-window-prev-buffers! win (cadr own))
                 (when (number? (caddr own)) (window-set-point! win (caddr own)))
                 (let ((quit (nth 3 own)))
                   (when quit (window-quit-restore-note! win (cadr quit) (caddr quit)))))
                (record (set-window-prev-buffers! win (cons (car record) (cadr record))))
                (else (set-window-prev-buffers! win '())))
          ;; Rebuilt panes cannot inherit a foreign group's stack or return.
          (set-window-prev-buffers! win (window-eligible-history win))
          (let ((quit (window-quit-restore win)))
            (when (and quit (equal? (cadr quit) 'other)
                       (not (window-history-member? win (caddr quit))))
              (window-quit-restore-forget! win)))
          (loop (cdr rows) (if record (layout--drop-record record remaining) remaining)))))))

;; The engine runs one arrangement at a time. switch-to-buffer! wakes a dormant
;; buffer, which re-runs its mode setups; without this flag that wake would ask
;; for another layout in the middle of this one.
(define *layout-busy* #f)

;; Winner records one entry for a complete layout change. The wrapped split
;; functions consult this flag, including during mode layouts and tiling.
(define *winner-inhibit* #f)

;; Run THUNK with the engine standing down. Desktop restore uses this: it
;; rebuilds the exact windows it saved, and a mode setup that runs inside it
;; must not arrange the frame a second way.
;; Is the engine arranging the frame right now? A package that moves
;; windows of its own — a preview that opens beside its index, say — must
;; ask this and stand down: the engine is mid-build, it will place every
;; declared pane itself, and a split landing inside that build leaves the
;; frame neither arrangement.
(define (layout-arranging?) *layout-busy*)

;; This Scheme has no unwind form, so a throw inside a build leaves the
;; flag raised and every later arrangement returns early — the frame
;; quietly stops obeying its layouts. A top-level, user-initiated build
;; clears it first: nothing can legitimately be arranging the frame at
;; the moment somebody asks for an arrangement.
(define (layout-abort!) (set! *layout-busy* #f))

(define (with-layout-suppressed thunk)
  (let ((was *layout-busy*))
    (set! *layout-busy* #t)
    (let ((r (thunk)))
      (set! *layout-busy* was)
      r)))

;; Put the frame where SPEC says. The anchor keeps focus: a mode that arranges
;; the frame must not move the user out of the buffer they are in.
(define (apply-layout! anchor spec)
  (if *layout-busy*
      (layout--panes anchor spec)
      (begin
        ;; the flag goes up BEFORE the panes resolve: an ensure pane runs a
        ;; command, that command switches buffers and sets a mode, and a
        ;; mode setup asks the engine for a layout of its own. One
        ;; arrangement at a time, materialising included.
        (set! *layout-busy* #t)
        (winner-save!)
        (set! *winner-inhibit* #t)
        (let ((panes (layout--panes anchor spec))
              (histories (layout--capture-histories)))
          (when (pair? panes)
            (delete-other-windows!)
            (layout--fill-line! panes (layout--dir spec) (layout--ratio spec))
            (layout--restore-histories! histories)
            (let ((w (window-showing anchor)))
              (when w (select-window! w))))
          (set! *winner-inhibit* #f)
          (set! *layout-busy* #f)
          panes))))

 ;; Visible panes keep tree order. Selecting a pane does not promote it.
(define (layout-visible-buffers)
  (map cadr
    (filter layout-visible-window? (window-list))))
(domain! 'files)
(effects! '(read))

;;; --- the pool: which buffers belong in this frame's windows -------------
;;; One source, the way a completion source answers a prompt. The buffers
;;; a window in this frame may be filled with, most recent first, are the
;;; frame's context: editor.scm knows no groups, so the base answer is the
;;; MRU ring, and groups.scm sets the source to the group's members when
;;; the frame stands in one. Every site that fills a window reads this
;;; and never the ring itself: the columns of a layout, the window a kill
;;; empties, the buffer q falls to. A layout that read the ring pulled
;;; buffers in from other groups.

;; a buffer a window may be filled with: known, not hidden, not floating
;; as the popup, not a peek (a look, not a place)
(domain! 'files)
(effects! '(read))

;;; --- special-mode (after Emacs) -------------------------------------------
;;; The parent of every view: a listing, a diff, a mail thread. Deriving
;;; from it is how a MODE says "this is not a place you work", which fill,
;;; group seeding and group context all ask through buffer-special?. A
;;; mode answers once; a buffer-local had to be written onto every buffer
;;; and could be stripped again, which is exactly what happened.
;;; It carries NO keys. Emacs' special-mode also forces read-only and binds
;;; q and g; here that is the child's business, and giving the parent a q
;;; broke a writable buffer that owns a child (dismiss-test: "writable
;;; buffers keep typing q"). Classification is what this mode is for.
(define-mode "special-mode" (lambda () #t))
;; Emacs' special-mode: a buffer that is a VIEW of something else -- a
;; listing, a diff, the telemetry, a mail thread -- and not a place you
;; work. Read-only, g re-renders it, q buries it. Nothing fills a window
;; with one, no group is seeded from one, and one never tells the frame
;; which group it stands in. It says NOTHING about persistence: what a
;; view rebuilds from is its mode's business (desktop-skip!), and it was
;; called 'transient until the day that name made four other things true.
;;
;; The MODE answers: a mode that derives from special-mode is a view. The
;; buffer-local stays as an explicit override for a buffer whose mode does
;; not say -- a hand-written view mode, or a test standing one up.
(define (buffer-special? b)
  (and (string? b)
       (or (derived-mode? (buffer-local b 'mode-name) "special-mode")
           (and (buffer-local b 'special) #t))))

;; a buffer a window may be filled with: known, not hidden, not floating
;; as the popup, not a peek (a look, not a place)
(define (fill-candidate? b)
  (and (string? b) (buffer-known? b)
       (not (string-prefix? " " b))
       (not (buffer-local b 'context-only))
       (not (buffer-special? b))
       (not (popup--class? b))
       (not (and (boundp 'peek-buffer?) (peek-buffer? b)))))

(define window-fill-source (lambda () (buffer-list-mru)))
(define window-fill-primary? (lambda (buffer) #t))
(define window-fill-member? (lambda (buffer) #t))

;; History permits utility covers, but never another group's content.
;; groups.scm supplies ownership policy separately from layout fill policy.
(define window-history-member? (lambda (win buffer) #t))
(define (window-eligible-history win)
  (filter (lambda (b)
            (and (buffer-known? b) (not (equal? b (window-buffer win)))
                 (window-history-member? win b)))
          (window-prev-buffers win)))

(define (window-fill-buffers)
  (filter fill-candidate? (window-fill-source)))

;; The blank pane: the buffer a layout shows in a pane the pool cannot
;; fill. editor.scm knows no groups, so the base answer is none, and a
;; layout stays short; scratch.scm sets the source to the group's scratch
;; when the frame stands in a group, so a sealed group's layout keeps its
;; shape without a buffer from outside.
(define window-fill-blank (lambda () #f))

;; Explicit fixed layouts fill with hidden work from the same context.
;; Keep the focused buffer when a smaller target hides surplus panes.
(define (layout--fit buffers capacity)
  (let* ((kept (take buffers capacity))
         (focus (window-buffer (active-window))))
    (if (and (member focus buffers) (not (member focus kept)))
        (append (take kept (- capacity 1)) (list focus))
        kept)))

(define (layout--fill-to buffers capacity)
  ;; The fill list costs a walk of every live buffer, so only pay for it when
  ;; the fit actually came up short. The common case -- more buffers than
  ;; panes -- now costs nothing.
  (let ((fitted (layout--fit buffers capacity)))
    (if (>= (length fitted) capacity)
        fitted
        (let loop ((rest (filter window-fill-primary? (window-fill-buffers)))
                   (result fitted))
          (cond ((>= (length result) capacity) result)
                ((null? rest) result)
                ((member (car rest) result) (loop (cdr rest) result))
                (else (loop (cdr rest) (append result (list (car rest))))))))))

(define (layout--three-columns buffers) (layout--fill-to buffers 3))
(define (layout--two-panes buffers) (layout--fill-to buffers 2))

;; Validate each requested pane without removing duplicate buffer names.
(define (layout--known-buffers buffers)
  (let loop ((rest buffers) (acc '()))
    (if (null? rest)
        (reverse acc)
        (let ((buf (car rest)))
          (loop (cdr rest)
            (if (and (string? buf) (buffer-known? buf))
                (cons buf acc)
                acc))))))

(define (layout--drop-n values n)
  (if (or (= n 0) (null? values)) values (layout--drop-n (cdr values) (- n 1))))

;; A balanced binary tiler. Alternating split directions produces a grid.
;; Ratios follow the leaf counts, so odd grids give the larger half more room.
(define (layout--grid! buffers dir)
  (if (null? (cdr buffers))
      (switch-to-buffer-here! (car buffers))
      (let* ((count (length buffers))
             (left-count (quotient (+ count 1) 2))
             (left (take buffers left-count))
             (right (layout--drop-n buffers left-count))
             (before (map car (window-list)))
             (left-window (active-window)))
        (split-window! dir (/ left-count count))
        (let ((right-window (layout--new-window before))
              (next-dir (if (equal? dir 'h) 'v 'h)))
          (select-window! left-window)
          (layout--grid! left next-dir)
          (select-window! right-window)
          (layout--grid! right next-dir)))))

;; Build a two-zone layout. The main pane takes window-layout-main-ratio
;; of the frame. The other buffers share the rest on SIDE: a column when
;; window-layout-stack is 'column, a grid of tiles when it is 'grid.
(define (layout--stack-zone! stack stack-dir)
  (if (and (equal? window-layout-stack 'grid) (pair? (cdr stack)))
      (layout--grid! stack (if (equal? stack-dir 'v) 'h 'v))
      (layout--fill-line! stack stack-dir (/ 1 (length stack)))))

(define (layout--main-stack! buffers side)
  (let* ((main (car buffers))
         (stack (cdr buffers))
         (horizontal? (or (equal? side 'left) (equal? side 'right)))
         (split-dir (if horizontal? 'h 'v))
         (stack-dir (if horizontal? 'v 'h))
         (stack-first? (or (equal? side 'left) (equal? side 'top)))
         (ratio (layout--valid-ratio window-layout-main-ratio (- 1 *window-third*)))
         (before (map car (window-list)))
         (first-window (active-window)))
    (switch-to-buffer-here! (if stack-first? (car stack) main))
    (split-window! split-dir (if stack-first? (- 1 ratio) ratio))
    (let ((second-window (layout--new-window before)))
      (if stack-first?
          (begin
            (select-window! first-window)
            (layout--stack-zone! stack stack-dir)
            (select-window! second-window)
            (switch-to-buffer-here! main))
          (begin
            (select-window! second-window)
            (layout--stack-zone! stack stack-dir))))))

(define *window-layout-algorithms*
  '(two-pane columns rows grid main-right main-left main-bottom main-top))

;; Arrange explicit buffers with a named tiling algorithm. The first buffer is
;; the main buffer and keeps focus. This is the stable agent-facing entry point.
(define (tile-windows! algorithm buffers)
  (let* ((known (layout--known-buffers buffers))
         (panes (if (equal? algorithm 'two-pane) (take known 2) known)))
    (cond
      ((not (member algorithm *window-layout-algorithms*))
       (message "Unknown window layout") #f)
      ((null? panes) (message "No live buffers to arrange") #f)
      (*layout-busy* panes)
      (else
        (when (popup-open?) (popup-close!))
        (set! *layout-busy* #t)
        (winner-save!)
        (set! *winner-inhibit* #t)
        (set! *layout-histories* (layout--capture-histories))
        (delete-other-windows!)
        (cond
          ((equal? algorithm 'two-pane)
           (layout--fill-line! panes 'h (/ 2 3)))
          ((equal? algorithm 'columns)
           (layout--fill-line! panes 'h (/ 1 (length panes))))
          ((equal? algorithm 'rows)
           (layout--fill-line! panes 'v (/ 1 (length panes))))
          ((equal? algorithm 'grid)
           (layout--grid! panes 'h))
          ((equal? algorithm 'main-right)
           (if (null? (cdr panes)) (switch-to-buffer-here! (car panes))
               (layout--main-stack! panes 'right)))
          ((equal? algorithm 'main-left)
           (if (null? (cdr panes)) (switch-to-buffer-here! (car panes))
               (layout--main-stack! panes 'left)))
          ((equal? algorithm 'main-bottom)
           (if (null? (cdr panes)) (switch-to-buffer-here! (car panes))
               (layout--main-stack! panes 'bottom)))
          (else
           (if (null? (cdr panes)) (switch-to-buffer-here! (car panes))
               (layout--main-stack! panes 'top))))
        (layout--restore-histories! *layout-histories*)
        (set! *layout-histories* '())
        (let ((home (window-showing (car panes))))
          (when home (select-window! home)))
        (set! *winner-inhibit* #f)
        (set! *layout-busy* #f)
        (layout-target-note-slots! panes)
        panes))))

;; the histories a tile is carrying across its build
(define *layout-histories* '())

(define (layout-request-buffers)
  (let* ((visible (layout-target-visible-buffers))
         (hidden (if (and (boundp 'frame-group) (frame-group))
                     (filter (lambda (b) (not (member b visible))) (window-fill-buffers))
                     '())))
    ;; Existing panes keep their buffers, including deliberate duplicates,
    ;; transient lists and visible non-members. Only hidden fillers are filtered.
    (append visible hidden)))

(define (tile-visible-windows! algorithm &optional requested)
  (let* ((focus (layout-focus-token))
         (visible (or requested (layout-request-buffers)))
         (panes (cond ((equal? algorithm 'two-pane) (layout--two-panes visible))
                      ((equal? algorithm 'columns) (layout--three-columns visible))
                      (else visible)))
         (result (and (pair? panes) (tile-windows! algorithm panes))))
    (when result (layout-focus-restore! focus))
    result))

(define (window-layout-command algorithm)
  (lambda ()
    (when (tile-visible-windows! algorithm)
      (layout-target-set! algorithm))))

;; Layout selection is a live preview. Keep the complete frame arrangement so
;; cancelling the prompt returns both the windows and the selected window.
(define (window-layout-preview! name &optional requested)
  ;; A failed earlier arrangement must not disable a later interactive
  ;; preview. This command is a new top-level layout request.
  (layout-abort!)
  (if (equal? name "adaptive")
      (tile-visible-adaptive! requested)
      (tile-visible-windows! (string->symbol name) requested)))

(define (window-layout-preview-without-history! name &optional requested)
  (let ((was *winner-inhibit*))
    (set! *winner-inhibit* #t)
    (let ((result (window-layout-preview! name requested)))
      (set! *winner-inhibit* was)
      result)))

(define-command "window-layout-columns" "Tile visible buffers in equal columns"
  (window-layout-command 'columns))
(define-command "window-layout-two-pane"
  "Show up to two side-by-side panes; the first pane takes two thirds"
  (window-layout-command 'two-pane))
(define-command "window-layout-rows" "Tile visible buffers in equal rows"
  (window-layout-command 'rows))
(define-command "window-layout-grid" "Tile visible buffers in a balanced grid"
  (window-layout-command 'grid))
(define-command "window-layout-main-right" "Show a main pane and the other buffers on the right"
  (window-layout-command 'main-right))
(define-command "window-layout-main-left" "Show a main pane and the other buffers on the left"
  (window-layout-command 'main-left))
(define-command "window-layout-main-top" "Show a main pane and the other buffers above"
  (window-layout-command 'main-top))
(define-command "window-layout-main-bottom" "Show a main pane and the other buffers below"
  (window-layout-command 'main-bottom))

;; the commit: the chosen layout is the frame's target from here on
(define (window-layout-choose! saved name &optional requested)
  ;; Commit from the original arrangement so winner records one real
  ;; layout change, not an intermediate preview arrangement.
  (window-tree-set! saved)
  (cond ((equal? name "free")
         (layout-target-set! #f)
         (message "Layout free: a display may split a window again"))
        ((window-layout-preview! name requested)
         (layout-target-set! (string->symbol name))
         (message (string-append "Layout " name " is the target")))
        (else #f)))

(define-command "window-layout" "Choose a tiling layout for visible buffers; the choice is the frame's target layout"
  (lambda ()
    (let ((saved (window-tree))
          (saved-panes (layout-target-visible-buffers))
          (saved-order (layout-request-buffers)))
      (define (restore-preview!)
        (window-tree-set! saved)
        (layout-target-note-slots! saved-panes))
      (minibuffer-read-preview "Window layout: "
        '(("adaptive" "choose from usable monitor width")
          ("two-pane" "2/3 + 1/3 side by side")
          ("columns" "3 columns")
          ("rows" "equal rows")
          ("grid" "balanced grid")
          ("main-right" "companion view (companion on the right)")
          ("main-left" "2/3 + 1/3 (companion on the left)")
          ("main-bottom" "2/3 + 1/3 (companion below)")
          ("main-top" "2/3 + 1/3 (companion above)")
          ("free" "no target: a display may split a window"))
        (lambda (name)
          (restore-preview!)
          (unless (equal? name "free")
            (window-layout-preview-without-history! name saved-order)))
        (lambda (name) (restore-preview!) (window-layout-choose! saved name saved-order))
        (lambda () (restore-preview!))
        #f #f #f #f
        '(("a" "adaptive") ("2" "two-pane")
          ("c" "columns") ("r" "rows") ("g" "grid")
          ("l" "main-left") ("i" "main-right")
          ("t" "main-top") ("b" "main-bottom")
          ("f" "free"))))))

(define-command "window-layout-free"
  "Drop the frame's target layout: a display may split a window again"
  (lambda ()
    (layout-target-set! #f)
    (message "Layout free: a display may split a window again")))

(for-each
  (lambda (name) (catalog-meta! 'command name 'domain 'windows 'effects '(write display)))
  '("window-layout" "window-layout-free" "window-layout-two-pane"
    "window-layout-columns" "window-layout-rows"
    "window-layout-grid" "window-layout-main-right" "window-layout-main-bottom"
    "window-layout-main-left" "window-layout-main-top"))

;; The engine's entry point: a mode turned on in BUF. Arrange the frame only
;; when BUF is the buffer the user is looking at.
(define (layout-enter! buf)
  (let ((spec (buffer-layout buf)))
    (if (and spec
             (not (layout-target))
             (not *layout-busy*)
             (equal? (window-buffer (active-window)) buf))
        (apply-layout! buf spec)
        #f)))

(define-command "reset-layout" "Arrange the frame the way this buffer's mode asks"
  (lambda ()
    (layout-abort!)
    (let ((spec (buffer-layout (current-buffer))))
      (if spec
          ;; also the way back from an arrangement that failed part way: the
          ;; flag never outlives the command the user runs to fix the frame
          (begin (set! *layout-busy* #f)
                 (apply-layout! (current-buffer) spec))
          (message "This buffer's modes declare no layout")))))

(define-command "popup-toggle" "Toggle the floating popup window"
  (lambda ()
    (if (popup-open?)
        (popup-close!)
        (if (popup-buffer)
            (popup-show (popup-buffer))
            (message "No popup buffer yet")))))

(define-command "popup-buffer" "Show any buffer in another window"
  (lambda ()
    (minibuffer-read "Show buffer: " (buffer-candidates)
      (lambda (name) (display-buffer name)))))
(catalog-meta! 'command "popup-buffer" 'domain 'windows 'effects '(write display))

;; popper-toggle-type: the popup you want to keep stops floating and
;; becomes an ordinary window, in the place it already occupies.
(define-command "popup-bufferize"
  "Turn the floating popup into an ordinary window"
  (lambda ()
    (if (not (popup-open?))
        (message "No popup window")
        (let* ((buf (current-buffer))
               (side (popup-side-of buf)))
          ;; the buffer is about to take a pane. groups.scm adds a foreign
          ;; buffer to the frame's group here, before any window change
          ;; derives the group again from the panes
          (run-hooks 'popup-bufferize-hook)
          (popup-float! buf #f)
          ;; a window on the left or the top takes that place in the tree
          ;; now: floating, it sat second and the class placed it
          (cond ((equal? side 'left) (window-swap! 'left))
                ((equal? side 'top) (window-swap! 'up)))
          (set-frame-local! 'popup-window #f)
          ;; it is a window now, not a visit — there is nothing to go back from
          (popup-forget!)
          (message (string-append buf " is an ordinary window now"))))))

(define (window-unwind-or-close! win)
  (let* ((cur (window-buffer win))
         (history (window-eligible-history win))
         (record (window-quit-restore win)))
    (cond ((and record (equal? (cadr record) 'window) (other-window-id win))
           (window-quit-restore-forget! win)
           (delete-window-id! win) #t)
          ((pair? history)
           (window-quit-restore-forget! win)
           (display-buffer-in-window! win (car history))
           (set-window-prev-buffers! win (cdr history)) #t)
          ((other-window-id win)
           (window-quit-restore-forget! win)
           (delete-window-id! win) #t)
          (else
            (message "No previous buffer; this is the last window") #f))))

;; Quit consumes this window's own stack. An exhausted window closes before
;; the buffer dies, so kill repair cannot refill it from group recency.
(define-command "quit-window" "Close the popup, or kill this buffer and go back"
  (lambda ()
    (cond
      ;; a peek goes with its window: the look is over, and the layout
      ;; is what it was. In the popup the popup is dismissed; in a split
      ;; the split closes; alone, the window falls to the next buffer.
      ((peek-buffer? (current-buffer))
        (let ((cur (current-buffer)))
          (cond ((and (popup-open?) (equal? (active-window) (popup-window)))
                 (popup-dismiss!))
                ((window-quit-restore! (active-window)) #t)
                ((other-window-id (active-window))
                 (delete-window!))
                (else
                 (let loop ((bs (window-fill-buffers)))
                   (cond ((null? bs) #t)
                         ((and (not (equal? (car bs) cur)) (buffer-exists? (car bs)))
                          (switch-to-buffer! (car bs)))
                         (else (loop (cdr bs)))))))
          (peek-drop! cur)))
      ;; from any other buffer, a peek on screen goes first: q in the
      ;; listing that peeked takes the look, then the listing
      ((peek-dismiss!) #t)
      ((and (popup-open?) (equal? (active-window) (popup-window)))
        (popup-dismiss!))
      (else
        (let ((cur (current-buffer)))
          ;; a file with edits you did not save is not a listing: say so and
          ;; stay. A listing reports itself as modified — it has no path.
          (if (and (buffer-path cur) (buffer-modified? cur))
              (message "Buffer is modified — save it, or C-x k to kill it")
              (when (window-unwind-or-close! (active-window))
                ;; A live process dies only when its buffer can be dismissed.
                (if (process-running? cur) (process-kill! cur))
                (buffer-kill! cur))))))))

;; q quits every buffer you cannot type in. The read-only keymap sits
;; between the buffer's own map and the global one, so a mode that wants q
;; for something else — code-mode's exit, notmuch's search — still wins.
(local-set-key* " *read-only*" "q" "quit-window")

(domain! 'processes)
(effects! '(write execute))
(domain! 'processes)
(effects! '(write execute))

;;; --- winner: layout undo ------------------------------------------------------
;;; Every arrangement about to be destroyed goes onto a per-frame ring;
;;; C-c <left> walks back through them, C-c <right> walks forward. The
;;; wrapped window mutators and the group switch push; the walk itself
;;; does not, so undo cannot pollute its own history.

(define *winner-depth* 12)

;; a compound operation (a group switch builds its layout in steps)
;; saves ONCE and inhibits the wrapped mutators' pushes underneath

(define (winner-save!)
  (unless *winner-inhibit*
    (let ((ring (or (frame-local 'winner-ring) '()))
          (now (window-tree)))
      (unless (and (pair? ring) (equal? (car ring) now))
        (set-frame-local! 'winner-ring (take (cons now ring) *winner-depth*)))
      (set-frame-local! 'winner-pos #f))))

(define (winner--restore idx)
  (let ((ring (or (frame-local 'winner-ring) '())))
    (if (or (< idx 0) (>= idx (length ring)))
        (message (if (< idx 0) "at the latest layout" "no earlier layout"))
        (begin
          (set-frame-local! 'winner-pos idx)
          (window-tree-set! (nth idx ring))
          (message (string-append "layout "
                     (number->string (+ idx 1)) "/"
                     (number->string (length ring))))))))

(define (winner-previous!)
  (set! *winner-inhibit* #f)
  (let ((pos (frame-local 'winner-pos)))
    (if pos
        (winner--restore (+ pos 1))
        ;; entering the walk: the CURRENT arrangement joins the ring
        ;; first, so next can return to it.
        (begin
          (winner-save!)
          (winner--restore 1)))))

(define (winner-next!)
  (let ((pos (frame-local 'winner-pos)))
    (if (and pos (> pos 0))
        (winner--restore (- pos 1))
        (message "at the latest layout"))))

;; The ring holds layouts, and a layout names its buffers. A rename that
;; does not reach the ring makes winner-undo restore a window on a dead
;; name. Every frame keeps its own ring, so the sweep walks them all.
(add-hook! 'buffer-renamed-hook
  (lambda (old new)
    (set! *frame-locals*
      (map (lambda (frame-entry)
             (list (car frame-entry)
                   (map (lambda (item)
                          (if (equal? (car item) 'winner-ring)
                              (list 'winner-ring
                                    (map (lambda (tree)
                                           (window-tree-rename tree old new))
                                         (car (cdr item))))
                              item))
                        (car (cdr frame-entry)))))
           *frame-locals*))))

;; These names describe the operation as a desktop switch: the saved tree
;; contains both the window arrangement and the buffer shown in each window.
(define-command "winner-previous" "Switch to the previous window and buffer arrangement"
  (lambda () (winner-previous!)))
(define-command "winner-next" "Switch to the next window and buffer arrangement"
  (lambda () (winner-next!)))
(define-command "winner-undo" "Restore the previous window and buffer arrangement"
  (lambda () (winner-previous!)))
(define-command "winner-redo" "Walk forward to a later window and buffer arrangement"
  (lambda () (winner-next!)))

(for-each
  (lambda (name) (catalog-meta! 'command name 'domain 'windows 'effects '(write display)))
  '("winner-previous" "winner-next" "winner-undo" "winner-redo"))

;; the window mutators the keyboard reaches (C-x 1/2/3/0, popups) push
;; the arrangement they are about to destroy
(define (window-tree-set! tree)
  (builtin-window-tree-set! tree)
  (window-state-changed!))

;; a look at an arrangement, the way window-preview-buffer! is a look at
;; a buffer: the windows change, the MRU ring does not
(define (window-tree-preview! tree)
  (builtin-window-tree-preview! tree)
  (window-state-changed!))

(define (delete-other-windows!)
  (winner-save!)
  (builtin-delete-other-windows!)
  (window-state-changed!))

(define (split-window! dir &optional ratio)
  (winner-save!)
  (let ((result (if ratio
                    (builtin-split-window! dir ratio)
                    (builtin-split-window! dir))))
    (window-state-changed!)
    result))

(define (delete-window!)
  (winner-save!)
  (let ((result (builtin-delete-window!)))
    (window-state-changed!)
    result))

(define (delete-window-id! id)
  (let ((result (builtin-delete-window-id! id)))
    (window-state-changed!)
    result))
(domain! 'processes)
(effects! '(write execute))

;;; --- asking about windows -------------------------------------------------------
;;; (window-list) is ((id buffer) ...) and five places walked it by hand,
;;; each with its own loop and its own idea of what to return when nothing
;;; matched. These are the four questions that were being asked.

;; the window showing NAME, or #f
(define (window-showing name)
  (let ((ws (filter (lambda (w) (equal? (cadr w) name)) (window-list))))
    (if (null? ws) #f (car (car ws)))))

;; ...that is not EXCEPT — for "put it somewhere other than here"
(define (window-showing-other name except)
  (let ((ws (filter (lambda (w) (and (equal? (cadr w) name)
                                     (not (equal? (car w) except))))
                    (window-list))))
    (if (null? ws) #f (car (car ws)))))

;; the buffer a window is showing, or #f
(define (window-buffer id)
  (let ((w (assoc id (window-list))))
    (and w (cadr w))))

;; any window that is not ME, or #f when ME is the only one
(define (other-window-id me)
  (let loop ((ws (window-list)))
    (cond ((null? ws) #f)
          ((not (equal? (car (car ws)) me)) (car (car ws)))
          (else (loop (cdr ws))))))

;; C-c q : ask from anywhere. In a grouped buffer (its chat included) the
;; prompt becomes a turn in the group's one chat; ungrouped, it goes to
;; the global *chat* buffer -- follow-ups with C-c RET.
(domain! 'unknown)
(effects! '(unknown))

;;; --- tiling windows --------------------------------------------------------

(define (split-window-with-other-buffer! direction)
  (let* ((before (map car (window-list)))
         (shown (map cadr (window-list)))
         (candidates (filter (lambda (b) (not (member b shown))) (window-fill-buffers))))
    (split-window! direction)
    (let ((created (layout--new-window before)))
      (when (and created (pair? candidates))
        (display-buffer-in-window! created (car candidates)))
      created)))

(define-command "split-window-below" "Split the window in two, one above the other"
  (lambda () (split-window-with-other-buffer! 'v)))
(define-command "split-window-right" "Split the window in two, side by side"
  (lambda () (split-window-with-other-buffer! 'h)))
;; `C-x 0` in the popup closes the popup: same window, same close, so the
;; same return. Winner still records the arrangement — popup-close! calls
;; delete-window-id!, which winner does not save, so save it here.
(define-command "delete-window" "Delete the selected window"
  (lambda ()
    (if (and (popup-open?) (equal? (active-window) (popup-window)))
        (begin (winner-save!) (popup-close!))
        (if (not (delete-window!)) (message "Attempt to delete sole window")))))
;; `C-x 1` from anywhere makes one window, and the popup is not one of
;; them: it stops being a popup rather than leaving a return nobody can use
(define-command "delete-other-windows" "Make the selected window the only one"
  (lambda ()
    (when (popup-open?)
      (let ((buf (window-buffer (popup-window))))
        (when buf (popup-float! buf #f)))
      (set-frame-local! 'popup-window #f)
      (popup-forget!))
    (delete-other-windows!)))

;; frames: one per attached browser. Deleting the selected frame while its
;; browser is still connected resets it to a fresh single window (the client
;; immediately re-attaches under the same id); deleting a disconnected
;; frame removes it for good.
(define-command "delete-frame" "Delete the selected frame"
  (lambda ()
    (delete-frame!)
    (prune-frame-locals!)))

;; landing in a rich chat/agent window puts point in its input region —
;; the transcript is for reading, the prompt is where typing goes
(define (chat-snap-to-input!)
  (let ((buf (current-buffer)))
    (when (equal? (buffer-local buf 'render-mode) "agent")
      (when (< (point) (chat-input-start buf))
        (end-of-buffer!)))))

(define-command "other-window" "Select another window in cyclic order"
  (lambda ()
    ;; a peek's window is passed by: a preview takes no focus
    (let ((start (active-window)))
      (other-window!)
      (let loop ((n (length (window-list))))
        (when (and (> n 0) (not (window-focusable? (active-window)))
                   (not (equal? (active-window) start)))
          (other-window!)
          (loop (- n 1)))))
    (chat-snap-to-input!)))
(for-each
  (lambda (name) (catalog-meta! 'command name 'domain 'windows 'effects '(write display)))
  '("split-window-below" "split-window-right" "delete-window"
    "delete-other-windows" "other-window"))

;; Cmd-arrows (s- = super) move the focus geometrically: window-rects gives each
;; leaf's normalized frame rectangle, and the neighbor in DIR is the nearest
;; window past the active edge whose span contains the active center — so
;; motion follows what's on screen, not the split tree's shape.
(define (window-in-direction dir)
  (let* ((rs (window-rects))
         (me (let find ((l rs))
               (cond ((null? l) #f)
                     ((equal? (car (car l)) (active-window)) (car l))
                     (else (find (cdr l)))))))
    (and me
         (let* ((mx (list-ref me 2)) (my (list-ref me 3))
                (cx (+ mx (/ (list-ref me 4) 2)))
                (cy (+ my (/ (list-ref me 5) 2)))
                (eps 0.000001))
           (let loop ((l rs) (best #f) (bestd 999))
             (if (null? l)
                 best
                 (let* ((r (car l))
                        (x (list-ref r 2)) (y (list-ref r 3))
                        (w (list-ref r 4)) (h (list-ref r 5))
                        (d (cond ((equal? dir 'left)
                                  (and (<= (+ x w) (+ mx eps)) (<= y cy) (< cy (+ y h))
                                       (- mx (+ x w))))
                                 ((equal? dir 'right)
                                  (and (>= (+ x eps) (+ mx (list-ref me 4))) (<= y cy) (< cy (+ y h))
                                       (- x (+ mx (list-ref me 4)))))
                                 ((equal? dir 'up)
                                  (and (<= (+ y h) (+ my eps)) (<= x cx) (< cx (+ x w))
                                       (- my (+ y h))))
                                 (else
                                  (and (>= (+ y eps) (+ my (list-ref me 5))) (<= x cx) (< cx (+ x w))
                                       (- y (+ my (list-ref me 5))))))))
                   (if (and d (< d bestd))
                       (loop (cdr l) r d)
                       (loop (cdr l) best bestd)))))))))

(define (focus-move! dir)
  (let ((w (window-in-direction dir)))
    (if w
        (begin (select-window! (car w))
               (chat-snap-to-input!))
        (message (string-append "No window " (symbol->string dir))))))

;; a move that lands on a peek's window goes back: a preview takes no
;; focus. M-<down> scrolls it; RET on its row opens it.
(define (focus-move-safe! dir)
  (let ((from (active-window)))
    (focus-move! dir)
    (unless (window-focusable? (active-window))
      (select-window! from)
      (message "A peek: RET on its row opens it, M-<down> scrolls it"))))

(define-command "focus-left" "Select the window to the left"
  (lambda () (focus-move-safe! 'left)))
(define-command "focus-right" "Select the window to the right"
  (lambda () (focus-move-safe! 'right)))
(define-command "focus-up" "Select the window above"
  (lambda () (focus-move-safe! 'up)))
(define-command "focus-down" "Select the window below"
  (lambda () (focus-move-safe! 'down)))

;; Move the buffer onto the neighboring stack; consume the source's previous
;; entry instead of exchanging the two visible buffers. Splits stay intact.
(define (buffer-move! dir)
  (let* ((source (active-window))
         (neighbor (window-in-direction dir))
         (buf (window-buffer source))
         (point (window-point source))
         (past (window-prev-buffers source))
         (eligible (filter (lambda (b)
                            (and (not (equal? b buf))
                                 (buffer-known? b) (not (buffer-context-only? b))
                                 (not (popup--class? b)) (not (peek-buffer? b))
                                 (window-fill-member? b))) past)))
    (cond ((not neighbor) (message "No neighboring pane"))
          ((or (not (window-focusable? (car neighbor)))
               (not (layout-visible-window? neighbor))
               (not (layout-visible-window? (list source buf)))
               (not (window-fill-member? buf)))
           (message "Cannot move this buffer into that pane"))
          ((null? eligible) (message "No previous buffer to reveal"))
          (else
            (switch-to-buffer-here! (car eligible))
            (set-window-prev-buffers! source
              (filter (lambda (b) (not (equal? b buf))) past))
            (window-quit-restore-forget! source)
            (select-window! (car neighbor))
            (switch-to-buffer-here! buf)
            (window-set-point! (car neighbor) point)
            (window-quit-restore-forget! (car neighbor))))))

(for-each
  (lambda (dir)
    (let ((name (string-append "buffer-" (symbol->string dir))))
      (define-command name "Move this buffer to the neighboring pane and reveal its previous buffer"
        (lambda () (buffer-move! dir)))
      (catalog-meta! 'command name 'domain 'windows 'effects '(write display))))
  '(left right up down))

;; Move this logical window into the directional neighbor's pane and follow it.
;; The neighboring logical window moves into this pane; both complete stacks stay whole.
;; (window-left/right/up/down — the window family)
(define (window-swap! dir)
  "Move this logical window to the neighboring pane, carrying its complete stack and state."
  (let ((nb (window-in-direction dir)))
    (if nb
        (if (window-swap-id! (active-window) (car nb))
            (chat-snap-to-input!)
            (message "Could not move window"))
        (message (string-append "No window " (symbol->string dir))))))

(define-command "window-left" "Move this window leftward with its complete buffer stack"
  (lambda () (window-swap! 'left)))
(define-command "window-right" "Move this window rightward with its complete buffer stack"
  (lambda () (window-swap! 'right)))
(define-command "window-up" "Move this window upward with its complete buffer stack"
  (lambda () (window-swap! 'up)))
(define-command "window-down" "Move this window downward with its complete buffer stack"
  (lambda () (window-swap! 'down)))
(for-each
  (lambda (name) (catalog-meta! 'command name 'domain 'windows 'effects '(write display)))
  '("focus-left" "focus-right" "focus-up" "focus-down"
    "window-left" "window-right"
    "window-up" "window-down"))

;; Eat the pane next door: it goes away and this window takes exactly its
;; rectangle. Only a neighbor that shares a whole edge is a meal, so the
;; panes that are not eaten keep the space they had — the space does not
;; fall to whichever sibling the split tree favours, the way a delete
;; leaves it. Without a direction the first neighbor that merges is
;; eaten, right and down first.
(define *window-eat-order* '(right down left up))

(define (window--rect id)
  (let loop ((l (window-rects)))
    (cond ((null? l) #f)
          ((equal? (car (car l)) id) (car l))
          (else (loop (cdr l))))))

;; two panes make one rectangle when they meet along a whole shared edge
(define (window-rects-merge? a b)
  (let* ((eps 1.0e-6)
         (near? (lambda (p q) (< (abs (- p q)) eps)))
         (ax (list-ref a 2)) (ay (list-ref a 3))
         (aw (list-ref a 4)) (ah (list-ref a 5))
         (bx (list-ref b 2)) (by (list-ref b 3))
         (bw (list-ref b 4)) (bh (list-ref b 5)))
    (or (and (near? ay by) (near? ah bh)
             (or (near? (+ ax aw) bx) (near? (+ bx bw) ax)))
        (and (near? ax bx) (near? aw bw)
             (or (near? (+ ay ah) by) (near? (+ by bh) ay))))))

(define (window-eat! &optional dir)
  (let ((me (active-window))
        (mine (window--rect (active-window)))
        (dirs (if dir (list dir) *window-eat-order*)))
    (let loop ((l dirs) (refused #f))
      (if (null? l)
          (message (if refused
                       "That pane and this one make no rectangle"
                       "No neighboring pane"))
          (let ((n (window-in-direction (car l))))
            (cond ((not n) (loop (cdr l) refused))
                  ((or (not (window-focusable? (car n)))
                       (not (layout-visible-window? n))
                       (not (window-rects-merge? mine n)))
                   (loop (cdr l) #t))
                  (else
                    ;; winner records what a delete leaves behind, and an
                    ;; eat is a delete: C-c <left> brings the pane back
                    (winner-save!)
                    (window-eat-id! me (car n))
                    (message (string-append "Ate " (cadr n))))))))))

(define-command "window-eat" "Eat the neighboring pane and take its space"
  (lambda () (window-eat!)))
(catalog-meta! 'command "window-eat" 'domain 'windows 'effects '(write display))

;; No arrow family has default keys; an installer binds them:
;; (focus-default-keybindings MODIFIERS) binds the arrows to focus-*,
;; (window-default-keybindings MODIFIERS) to window-*, and
;; (buffer-default-keybindings MODIFIERS) to buffer-*. MODIFIERS is one
;; symbol or a list from shift, control, meta, super. The client sends
;; the Cmd-arrows from an editable buffer only in its movement state
;; (before the first key, or after ESC); in the editing state the
;; browser keeps them as line and document start and end.
(define *direction-names* '("left" "right" "up" "down"))

(define (arrow-chord modifiers key)
  (let* ((mods (cond ((or (not modifiers) (null? modifiers)) '(shift))
                     ((symbol? modifiers) (list modifiers))
                     (else modifiers)))
         (has? (lambda (m) (member m mods))))
    (string-append (if (has? 'super) "s-" "")
                   (if (has? 'control) "C-" "")
                   (if (has? 'meta) "M-" "")
                   (if (has? 'shift) "S-" "")
                   key)))

(define (install-arrow-keys! modifiers prefix)
  (for-each
    (lambda (dir)
      (global-set-key (arrow-chord modifiers (string-append "<" dir ">"))
                      (string-append prefix dir)))
    *direction-names*))

(define (focus-default-keybindings &optional modifiers)
  (install-arrow-keys! modifiers "focus-"))

;; default chords: Cmd-Shift for the window and buffer families
(define (window-default-keybindings &optional modifiers)
  (install-arrow-keys! (or modifiers '(shift super)) "window-"))

(define (buffer-default-keybindings &optional modifiers)
  (install-arrow-keys! (or modifiers '(shift super)) "buffer-"))

(domain! 'unknown)
(effects! '(unknown))

;; Cmd-arrows move the focus; Cmd-Shift-arrows swap the two panes
(focus-default-keybindings 'super)
(window-default-keybindings '(shift super))

;;; --- the public API of this file ----------------------------------------------
;;; The catalog scope of each entry is the one it had in editor.scm.

(domain! 'buffers)
(effects! '(write display))
(category! 'buffers)
(public! 'display-foreign? "(display-foreign? NAME) — #t when a pane on NAME would take the frame out of its group; groups.scm answers")
(domain! 'windows)
(effects! '(read))
(category! 'windows)
(public! 'window-showing "(window-showing NAME) — the window showing NAME, or #f")
(public! 'window-buffer "(window-buffer ID) — the buffer that window shows, or #f")
(public! 'other-window-id "(other-window-id ME) — any window that is not ME, or #f")
(effects! '(write display))
(public! 'split-window! "(split-window! 'h|'v [RATIO]) — ratio = first pane's share")
(public! 'delete-window-id! "(delete-window-id! ID)")
(public! 'delete-other-windows! "Make the active window the only one")
(public! 'display-buffer
  "(display-buffer NAME [ALIST]) — show NAME where the display rules and the action chain say, selecting nothing; returns the window. ALIST is a plist: 'category KIND, 'inhibit-same-window #t")
(public! 'pop-to-buffer
  "(pop-to-buffer NAME [ALIST]) — display-buffer, then select the window it used")
(public! 'display-buffer-actions-for
  "(display-buffer-actions-for NAME [ALIST]) — the action chain a display of NAME would try, in order")
(public! 'layout-target
  "(layout-target) — the frame's target layout, the name chosen at window-layout, or #f")
(public! 'layout-target-set!
  "(layout-target-set! NAME) — keep NAME as the target algorithm as panes open or close; #f frees the frame")
(public! 'define-display-action!
  "(define-display-action! NAME FN) — register a display action; FN takes NAME and ALIST and returns a window or #f")
(public! 'window-mode
  "(window-mode WIN) — the major mode of the buffer WIN shows, or #f")
(public! 'window-preferred-mode
  "(window-preferred-mode WIN) — explicit cycle mode, else the nearest work buffer's mode beneath temporary covers")
(public! 'window-prefers-buffer?
  "(window-prefers-buffer? WIN BUF) — whether BUF matches WIN's preferred mode, including derived modes")
(public! 'window-showing-mode
  "(window-showing-mode MODE [EXCEPT]) — the work window preferring or showing MODE, or #f")
(public! 'split-window-sensibly
  "(split-window-sensibly WIN) — split WIN below when it is tall enough, beside when wide enough; the new window or #f")
(public! 'window-quit-restore!
  "(window-quit-restore! WIN) — undo what a display did to WIN: delete the window it made, or put back the buffer it replaced")
(public! 'display-buffer-popup!
  "(display-buffer-popup! NAME [SIDE SIZE]) — kept for an older caller: shows NAME in an ordinary window, because nothing floats. SIDE and SIZE say nothing")
(public! 'display-buffer-other-window! "(display-buffer-other-window! NAME) — show NAME without leaving this window: the display chain with the selected window kept out of it")
(public! 'apply-layout! "(apply-layout! ANCHOR SPEC) — arrange the frame by SPEC, ANCHOR keeping focus")
(public! 'tile-windows!
  "(tile-windows! ALGORITHM BUFFERS) — arrange names with two-pane, columns, rows, grid, main-right, main-left, main-bottom, or main-top")
(public! 'tile-visible-windows!
  "(tile-visible-windows! ALGORITHM) — rearrange visible work windows with a named tiler")
(public! 'window-eat!
  "(window-eat! [DIR]) — the neighboring pane goes away and this window takes its rectangle; DIR is left, right, up or down")
(effects! '(write))
(public! 'add-display-rule!
  "(add-display-rule! PATTERN ACTION [PARAMS]) — set display policy without showing a buffer. PATTERN is a name substring or (category KIND); ACTION is one action name or a list: pop-up-window, reuse-window, use-some-window, same-window")
(public! 'define-mode-layout!
  "(define-mode-layout! MODE '(h|v RATIO PANE ...)) — set a mode layout without applying it")
(effects! '(read))
(public! 'buffer-layout "(buffer-layout NAME) — the layout NAME's modes declare, or #f")
(effects! '(write))
(public! 'with-layout-suppressed "(with-layout-suppressed THUNK) — run THUNK without the layout engine arranging the frame")
(domain! 'unknown)
(effects! '(unknown))
(category! 'interaction)
(catalog-meta! 'command "reset-layout" 'domain 'windows 'effects '(write display))
(catalog-meta! 'function "define-mode-layout!" 'domain 'windows 'effects '(write))
(category! 'commands)
(public! 'focus-default-keybindings "(focus-default-keybindings &optional MODIFIERS) — bind the arrows with MODIFIERS (shift control meta super; default shift) to focus-left/right/up/down")
(public! 'window-default-keybindings "(window-default-keybindings &optional MODIFIERS) — bind the arrows with MODIFIERS (default shift super) to window-left/right/up/down; the logical windows exchange panes with their complete stacks and focus follows")
(public! 'buffer-default-keybindings "(buffer-default-keybindings &optional MODIFIERS) — bind the arrows with MODIFIERS (default shift super) to buffer-left/right/up/down; the buffer moves to the neighbor and its previous buffer shows here")
(public! 'arrow-chord "(arrow-chord MODIFIERS KEY) — the key spec for KEY under MODIFIERS, e.g. (arrow-chord '(meta shift) \"<left>\") is \"M-S-<left>\"")
(public! 'layout-arranging? "(layout-arranging?) — #t while the layout engine is building the frame; a package that moves windows must stand down")
(public! 'layout-abort! "(layout-abort!) — clear a layout build left in progress by a failure; a top-level build calls this first")

(domain! 'unknown)
(effects! '(unknown))
