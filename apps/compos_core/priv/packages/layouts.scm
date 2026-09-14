;;; layouts.scm — monitor-width-aware window policy.
;;;
;;; Width is measured in usable text columns, not pixels. That makes the same
;;; breakpoints respond naturally to monitor size, browser width, sidebars,
;;; font size, and display scaling. The tiling mechanics remain in editor.scm;
;;; this package owns only the policy that chooses among them.

(category! 'windows)
(domain! 'windows)
(effects! '(write))

(defgroup 'windows "Window layout and responsive popup policy.")

(defcustom 'window-layout-compact-cols 100
  "Below this usable frame width, layouts stack and popups use the bottom."
  'group 'windows 'type 'number)

(defcustom 'window-layout-wide-cols 200
  "At this usable frame width, three panes become columns and four become a grid."
  'group 'windows 'type 'number)

;; peek! and the ripgrep preview (editor.scm) read this one.
(defcustom 'peek-max-file-size 1048576
  "The largest file a look opens. A peek or a ripgrep preview of a bigger file shows nothing and says the size; RET still opens it. 0 removes the cap."
  'group 'windows 'type 'number)

;; visit and visit-quietly (editor.scm) read this one.
(defcustom 'large-file-warning-threshold 10485760
  "The largest file a visit opens without asking (Emacs large-file-warning-threshold). A visit of a bigger file refuses and says the size; M-x find-file asks, and a yes opens it for this session only. 0 removes the cap."
  'group 'files 'type 'number)

;; The display-buffer chain (editor.scm) reads these. They are plain
;; defines there, because editor.scm loads before custom.scm.
(defcustom 'split-height-threshold 80
  "A window with this many rows splits below for a pop-up window (Emacs split-height-threshold)."
  'group 'windows 'type 'number)

(defcustom 'split-width-threshold 160
  "A window with this many columns splits beside for a pop-up window (Emacs split-width-threshold)."
  'group 'windows 'type 'number)

(defcustom 'next-screen-context-lines 2
  "Rows a page scroll keeps from the screen before it. A page overlaps by this much and never leaves a gap (Emacs next-screen-context-lines)."
  'group 'windows 'type 'number)

;; The main layouts (editor.scm layout--main-stack!) read these two.
(defcustom 'window-layout-main-ratio 0.62
  "The main pane's share of the frame in the main layouts: a fraction between 0.3 and 0.9."
  'group 'windows 'type 'number)

(defcustom 'window-layout-stack 'column
  "How the other panes arrange beside the main pane: 'column stacks them, 'grid tiles them."
  'group 'windows 'type 'choice)

(defcustom 'window-layout-main-side 'left
  "Where the auto layout puts the main pane: 'left or 'right."
  'group 'windows 'type 'choice)

(defcustom '*display-buffer-base-action* '()
  "Display actions tried after the rule for a buffer and before the fallback: a list of pop-up-window, reuse-window, use-some-window, same-window."
  'group 'windows 'type 'list)

(defcustom '*display-buffer-fallback-action*
  '(reuse-window mode-window pop-up-window use-some-window same-window)
  "Display actions tried last for a buffer with no rule."
  'group 'windows 'type 'list)

;; Deliberately pure: agents can inspect the choice before they change a frame.
(define (window-layout-for-width width pane-count)
  (cond
    ((< width window-layout-compact-cols) 'main-bottom)
    ((< width window-layout-wide-cols) 'main-right)
    ((<= pane-count 2) 'main-right)
    ((equal? pane-count 3) 'columns)
    (else 'grid)))

(define (tile-adaptive-windows! buffers)
  (let ((panes (layout--known-buffers buffers)))
    (tile-windows!
      (window-layout-for-width (frame-cols) (length panes))
      panes)))

(define (tile-visible-adaptive! &optional requested)
  (let ((panes (or requested (layout-request-buffers)))
        (focus (layout-focus-token)))
    (when (pair? panes)
      (tile-adaptive-windows! panes)
      (layout-focus-restore! focus)
      panes)))

;;; --- tile-all: the overview -------------------------------------------------
;;; tile-all is the context overview. It tiles each buffer in the current
;;; group or project and locks the frame. Keys select a tile and do not edit.
;;; SPC pops the selection out into a new group. The new group
;;; records the group the frame was in as its parent, and group-dissolve
;;; merges the members back into that parent. q restores the layout and
;;; the group unchanged.

(define (overview--project-buffers root)
  (let ((members (project-buffers root))
        (mru (buffer-list-mru)))
    (append
      (filter (lambda (buf) (member buf members)) mru)
      (filter (lambda (buf) (not (member buf mru))) members))))

(define (overview-buffers)
  (let ((group (frame-group)))
    (cond
      (group
        (let ((members (group-buffers-mru group)))
          (if (pair? members) members (list (group-chat group)))))
      ((and (boundp (quote project-current)) (project-current))
        (overview--project-buffers (project-current)))
      (else '()))))

(define (overview-active?) (equal? (frame-local 'overview-active) #t))

(define (overview--short-name buf)
  (let loop ((parts (reverse (string-split buf "/"))))
    (cond ((null? parts) buf)
          ((equal? (car parts) "") (loop (cdr parts)))
          (else (car parts)))))

;; A pop-out never prompts. The group takes the buffer's short name, made
;; unique with a counter, and group-rename can improve it later.
(define (overview--fresh-group-name base)
  (let loop ((n 1))
    (let ((name (if (= n 1) base
                    (string-append base " " (number->string n)))))
      (if (group-record-by-name name) (loop (+ n 1)) name))))

(define (overview--bindings)
  (list (list "<left>" "overview-left")
        (list "<right>" "overview-right")
        (list "<up>" "overview-up")
        (list "<down>" "overview-down")
        (list "m" "overview-mark")
        (list "SPC" "overview-pop-out")
        (list "RET" "overview-pop-out")
        (list "q" "overview-quit")
        (list "C-g" "overview-quit")
        (list "ESC" "overview-quit")))

(define (overview--hint!)
  (message "Overview: arrows select · m marks · SPC pops out into a new group · q quits"))

(define (overview-enter!)
  (if (overview-active?)
      (begin (overview--hint!) #f)
      (let ((buffers (overview-buffers))
            (base (window-tree))
            (group (frame-group)))
        (cond
          ((null? buffers)
           (message "Tile all is available only in a group or project") #f)
          ((not (tile-windows! 'grid buffers)) #f)
          (else
            (set-frame-local! 'overview-return (list base group))
            (set-frame-local! 'overview-marked '())
            (set-frame-local! 'overview-active #t)
            (transient-keymap-install! (overview--bindings))
            (transient-show! #t)
            (overview--hint!)
            #t)))))

(define (overview--unlock!)
  (transient-show! #f)
  (transient-keymap-clear!)
  (set-frame-local! 'overview-active #f)
  (set-frame-local! 'overview-marked '()))

;; The restore puts back the saved window tree and the saved group. The
;; window walk during the overview can recalculate the frame's group, so
;; standing where you stood is part of the restore. Returns the saved
;; group, the parent of a pop-out.
(define (overview--restore!)
  (let ((return (frame-local 'overview-return)))
    (set-frame-local! 'overview-return #f)
    (if (not (pair? return))
        #f
        (let ((group (car (cdr return))))
          (window-tree-set! (car return))
          (unless (equal? (frame-group) group)
            (set-frame-local! 'current-group group)
            (frame-group-label-refresh!))
          group))))

(define (overview-quit!)
  (when (overview-active?)
    (overview--unlock!)
    (overview--restore!)
    (message "")))

(define (overview--move! dir)
  (when (overview-active?) (focus-move! dir)))

(define (overview-mark!)
  (when (overview-active?)
    (let* ((buf (current-buffer))
           (marked (or (frame-local 'overview-marked) '()))
           (next (if (member buf marked)
                     (remove (lambda (b) (equal? b buf)) marked)
                     (append marked (list buf)))))
      (set-frame-local! 'overview-marked next)
      (message (if (null? next)
                   "No marks"
                   (string-append "Marked: "
                     (string-join (map overview--short-name next) " ")))))))

;; The pop-out takes the marked buffers, else the selected one. Each
;; buffer moves out of the parent group and into the new group; a
;; membership in any other group stays.
(define (overview-pop-out!)
  (when (overview-active?)
    (let* ((selected (current-buffer))
           (marked (or (frame-local 'overview-marked) '()))
           (buffers (filter buffer-known?
                            (if (pair? marked) marked (list selected)))))
      (if (null? buffers)
          (message "Nothing to pop out")
          (begin
            (overview--unlock!)
            (let* ((parent (overview--restore!))
                   (name (overview--fresh-group-name
                           (overview--short-name (car buffers))))
                   (id (group-record-create! name)))
              (if (not id)
                  (message (string-append "Could not create group " name))
                  (begin
                    (for-each
                      (lambda (buf)
                        (buffer-add-group! buf id)
                        (when (and parent (buffer-in-group? buf parent))
                          (buffer-remove-group! buf parent)))
                      buffers)
                    (when parent (group-parent-set! id parent))
                    (switch-to-group! id)))))))))

(define-command "tile-all"
  "Open the current group or project in one locked grid"
  overview-enter!)
(define-command "overview-left" "Select the overview tile to the left"
  (lambda () (overview--move! 'left)))
(define-command "overview-right" "Select the overview tile to the right"
  (lambda () (overview--move! 'right)))
(define-command "overview-up" "Select the overview tile above"
  (lambda () (overview--move! 'up)))
(define-command "overview-down" "Select the overview tile below"
  (lambda () (overview--move! 'down)))
(define-command "overview-mark" "Mark or unmark the selected overview tile"
  overview-mark!)
(define-command "overview-pop-out"
  "Pop the marked buffers, else the selected one, out into a new group"
  overview-pop-out!)
(define-command "overview-quit" "Leave the overview and restore the layout"
  overview-quit!)

(define-command "window-layout-adaptive"
  "Tile visible buffers for the selected frame's usable width; the choice is the frame's target layout"
  (lambda ()
    (when (tile-visible-adaptive!)
      (layout-target-set! 'adaptive))))

(define-key "layout-map" "a" "window-layout-adaptive")

;;; --- autolayout: one main pane, the rest beside it ---------------------------
;;; The StumpWM shape. The selected window's buffer is the main pane on
;;; window-layout-main-side, with window-layout-main-ratio of the frame.
;;; The other visible buffers share the rest, as a column or as tiles
;;; (window-layout-stack). autolayout-mode keeps the frame in this shape:
;;; when a window comes or goes, the frame re-arranges, the main pane
;;; stays main while its buffer is visible, and a new buffer joins the
;;; stack. A popup and the minibuffer are not panes.
;;; Cmd-RET (s-RET) runs autolayout: the window you are in becomes the main pane.
;;; autolayout-mode is a custom, so the mode survives a restart.

(defcustom 'autolayout-mode #f
  "Keep the frame in the main-and-stack layout as windows come and go."
  'group 'windows 'type 'boolean)

;; main pane on the left = the stack on the right, in the tiler's names
(define (autolayout--algorithm)
  (if (equal? window-layout-main-side 'right) 'main-left 'main-right))

;; the panes, main first: MAIN while it is visible, else the selected
;; window's buffer. Duplicates stay: two windows on one buffer are two panes.
(define (autolayout--panes main)
  (let ((visible (layout-visible-buffers)))
    (cond ((null? visible) '())
          ((and main (member main visible))
           (cons main (let loop ((rest visible) (dropped #f))
                        (cond ((null? rest) '())
                              ((and (not dropped) (equal? (car rest) main)) (loop (cdr rest) #t))
                              (else (cons (car rest) (loop (cdr rest) dropped)))))))
          (else visible))))

(define (autolayout--same-panes? a b)
  (and (= (length a) (length b))
       (let loop ((xs a) (ys b))
         (or (null? xs)
             (and (member (car xs) ys)
                  (loop (cdr xs) (let drop ((rest ys))
                                   (cond ((null? rest) '())
                                         ((equal? (car rest) (car xs)) (cdr rest))
                                         (else (cons (car rest) (drop (cdr rest))))))))))))

;; arrange the frame with MAIN as the main pane. One pane: one window.
(define (autolayout-apply! main &optional algorithm)
  (let ((panes (autolayout--panes main)))
    (cond ((null? panes) #f)
          (else
            (set-frame-local! 'autolayout-main (car panes))
            (set-frame-local! 'autolayout-panes panes)
            (if (null? (cdr panes))
                (begin (delete-other-windows!) panes)
                (tile-windows! (or algorithm (autolayout--algorithm)) panes))))))

;; the hook: the frame's panes changed, so the shape is re-made. Nothing
;; runs while a tiler runs, or while a prompt is open.
(define (autolayout--on-change!)
  (when (and autolayout-mode (not (layout-target))
             (not *layout-busy*) (not (minibuffer-state)))
    (let ((panes (autolayout--panes (frame-local 'autolayout-main))))
      (when (and (pair? panes)
                 (not (autolayout--same-panes? panes (or (frame-local 'autolayout-panes) '()))))
        (autolayout-apply! (car panes))))))

(add-hook! 'window-configuration-change-hook 'autolayout--on-change!)

;; "62", not "62.0": the dialect has no round
(define (autolayout--percent ratio)
  (car (string-split (number->string (* 100 ratio)) ".")))

(define (autolayout--ratio-from-input text)
  (let ((n (string->number text)))
    (cond ((not (number? n)) #f)
          ((> n 1) (/ n 100))
          (else n))))

(define (autolayout-select! main &optional algorithm)
  (let* ((target (or algorithm (autolayout--algorithm)))
         (panes (autolayout-apply! main target)))
    (when panes (layout-target-set! target))
    panes))

(define-command "autolayout"
  "Make the selected window's buffer the main pane; the other buffers stack beside it"
  (lambda ()
    (let ((target (layout-target)))
      (autolayout-select! (window-buffer (active-window))
        (and (member target '(main-left main-right main-top main-bottom)) target)))))

(define-command "autolayout-main-left"
  "Put the main pane on the left and arrange the frame"
  (lambda ()
    (customize-set! 'window-layout-main-side 'left)
    (autolayout-select! (window-buffer (active-window)))))

(define-command "autolayout-main-right"
  "Put the main pane on the right and arrange the frame"
  (lambda ()
    (customize-set! 'window-layout-main-side 'right)
    (autolayout-select! (window-buffer (active-window)))))

(define-command "autolayout-set-main-width"
  "Set the main pane's share of the frame, as a fraction or a percent, and arrange the frame"
  (lambda ()
    (minibuffer-read
      (string-append "Main pane width (now "
                     (autolayout--percent window-layout-main-ratio) "%): ")
      '()
      (lambda (text)
        (let ((ratio (autolayout--ratio-from-input text)))
          (if (and ratio (>= ratio 0.3) (<= ratio 0.9))
              (begin
                (customize-set! 'window-layout-main-ratio ratio)
                (autolayout-select! (or (frame-local 'autolayout-main)
                                       (window-buffer (active-window)))))
              (message "The main pane takes between 30% and 90% of the frame")))))))

(define-command "autolayout-toggle-stack"
  "Arrange the other panes as a column, or as tiles; again goes back"
  (lambda ()
    (customize-set! 'window-layout-stack
                    (if (equal? window-layout-stack 'grid) 'column 'grid))
    (message (if (equal? window-layout-stack 'grid) "Tiles beside the main pane" "A column beside the main pane"))
    (autolayout-select! (or (frame-local 'autolayout-main) (window-buffer (active-window))))))

(define-command "autolayout-mode"
  "Keep the frame in the main-and-stack layout as windows come and go; again turns it off"
  (lambda ()
    ;; customize-save! writes custom.scm, so the mode survives a restart
    (customize-save! 'autolayout-mode (not autolayout-mode))
    (if autolayout-mode
        (begin
          (layout-target-set! #f)
          (autolayout-apply! (window-buffer (active-window)))
          (message "Autolayout on: the selected buffer is the main pane"))
        (message "Autolayout off"))))

;; Cmd-RET makes the window you are in the main pane. The client claims
;; the chord from the browser (CMD_KEYS in layouts.ex) and sends it as
;; s-RET. The browse reader binds its own s-RET, and a local map wins.
(global-set-key "s-RET" "autolayout")

(for-each
  (lambda (name) (catalog-meta! 'command name 'domain 'windows 'effects '(write display)))
  '("autolayout" "autolayout-main-left" "autolayout-main-right"
    "autolayout-set-main-width" "autolayout-toggle-stack" "autolayout-mode"))

;; The popup's default side is the right edge, on every frame: a compact
;; frame once got the bottom edge, and the estimate of the frame's width
;; read narrow after a stale window measurement, so the popup wandered.
;; A rule names a side, and M-<arrows> in the popup move it.
(set! popup-default-side (lambda () 'right))

(catalog-meta! 'command "window-layout-adaptive"
  'domain 'windows 'effects '(write display))
(for-each
  (lambda (name)
    (catalog-meta! 'command name 'domain 'windows 'effects '(write display)))
  '("tile-all" "overview-left" "overview-right" "overview-up" "overview-down"
    "overview-mark" "overview-pop-out" "overview-quit"))

(effects! '(read))
(public! 'window-layout-for-width
  "(window-layout-for-width COLS COUNT) — responsive tiler chosen for a frame width and pane count")
(effects! '(write))
(public! 'tile-adaptive-windows!
  "(tile-adaptive-windows! BUFFERS) — tile named buffers for the selected frame width")
(public! 'tile-visible-adaptive!
  "(tile-visible-adaptive!) — tile visible work windows for the selected frame width")
(public! 'autolayout-apply!
  "(autolayout-apply! MAIN [ALGORITHM]) — arrange MAIN and the other visible buffers using ALGORITHM or the default main side")
(effects! '(read))
(public! 'overview-buffers
  "(overview-buffers) — current group members, else current project buffers")
(public! 'overview-active?
  "(overview-active?) — #t while this frame shows the locked overview")
(effects! '(write))
(public! 'overview-enter!
  "(overview-enter!) — tile the current group or project and lock the frame keys")

(domain! 'unknown)
(effects! '(unknown))

;; The active target is desktop state too: switching groups is not required
;; before saving. Window IDs and derived slot/count caches are runtime state.
(define (layout-targets-state)
  (map (lambda (frame) (list frame (frame-local-in frame 'layout-target))) (frame-list)))

(define (layout-targets-restore! saved)
  (for-each
    (lambda (frame)
      (let* ((entry (assoc frame saved))
             (target (and entry (cadr entry)))
             (old (assoc frame *frame-locals*))
             (locals (if old (cadr old) '()))
             (kept (filter (lambda (row)
                              (not (member (car row) '(layout-target layout-slots layout-target-count))))
                            locals)))
        (set! *frame-locals*
          (cons (list frame (cons (list 'layout-target target) kept))
                (filter (lambda (row) (not (equal? (car row) frame))) *frame-locals*)))))
    (frame-list)))

(persist-global! 'layout-targets layout-targets-state layout-targets-restore!)

;;; Hidden windows hold ordered buffer stacks without occupying a pane.
(domain! 'windows)
(effects! '(write))
(define *hidden-windows* '())
(define *hidden-window-next-id* 0)

(define (hidden-window-create! buffers &optional saved-point)
  (let ((live (filter buffer-known? buffers)))
    (and (pair? live)
         (begin
           (set! *hidden-window-next-id* (+ *hidden-window-next-id* 1))
           (let ((id (string-append "hidden:" (number->string *hidden-window-next-id*))))
             (set! *hidden-windows*
               (cons (list id (selected-frame) (frame-group) live saved-point) *hidden-windows*))
             id)))))

(define (hidden-window-buffers id)
  (let ((record (assoc id *hidden-windows*)))
    (if record (filter buffer-known? (nth 3 record)) '())))

(define (hidden-window-list)
  (map car
    (filter (lambda (record)
              (and (equal? (cadr record) (selected-frame))
                   (equal? (caddr record) (frame-group))
                   (pair? (hidden-window-buffers (car record)))))
            *hidden-windows*)))

;; Explicitly exchange a hidden stack with the selected pane's stack.
;; No split, deletion, or layout change is involved.
(define (hidden-window-show! id)
  (let ((record (assoc id *hidden-windows*))
        (buffers (hidden-window-buffers id)))
    (and (member id (hidden-window-list)) (pair? buffers)
         (with-layout-suppressed
           (lambda ()
             (let ((win (active-window))
                   (old (cons (current-buffer) (window-prev-buffers (active-window))))
                   (old-point (window-point (active-window))))
               (display-buffer-in-window! win (car buffers))
               (set-window-prev-buffers! win (cdr buffers))
               (window-quit-restore-forget! win)
               (window-cycle-mode! win #f)
               (when (number? (nth 4 record)) (window-set-point! win (nth 4 record)))
               (set! *hidden-windows*
                 (cons (list id (cadr record) (caddr record) old old-point)
                       (filter (lambda (r) (not (equal? (car r) id))) *hidden-windows*)))
               win))))))

(persist-global! 'hidden-windows
  (lambda () (list *hidden-window-next-id* *hidden-windows*))
  (lambda (saved)
    (when (and (list? saved) (= (length saved) 2))
      (set! *hidden-window-next-id* (car saved))
      (set! *hidden-windows* (cadr saved)))))

(on-buffer-renamed!
  (lambda (old new)
    (set! *hidden-windows*
      (map (lambda (r)
             (list (car r) (cadr r) (caddr r)
                   (map (lambda (b) (if (equal? b old) new b)) (nth 3 r)) (nth 4 r)))
           *hidden-windows*))))

(public! 'hidden-window-create!
  "(hidden-window-create! BUFFERS [POINT]) — store an ordered buffer stack without assigning it a pane")
(public! 'hidden-window-show!
  "(hidden-window-show! ID) — exchange a hidden stack with the selected window's stack, preserving pane geometry")
(effects! '(read))
(public! 'hidden-window-list
  "(hidden-window-list) — hidden window IDs for this frame and group")
(public! 'hidden-window-buffers
  "(hidden-window-buffers ID) — the hidden window's live buffer stack, current buffer first")
