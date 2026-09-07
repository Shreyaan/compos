;;; ibuffer.scm --- ONE table for lists of buffers: filter, mark, act.
;;;
;;; C-x C-b and M-x ibuffer open *ibuffer*; C-x C-c and M-x ichat open
;;; *chats*, the same table over the chat buffers. The table shows one
;;; row per buffer under a heading per section. A section is a group, a
;;; mode, or a directory; `;` cycles the grouping. Inside a section the
;;; rows sort by name, by recency, or by size; `,` cycles the sort. TAB
;;; folds the section at point, and a folded heading stays as a row that
;;; carries its counts. A row shows a dot, the icon, the directory in dim
;;; and the name in the colour of its kind, and on the right the size,
;;; the mode, and the time since the buffer was last seen. The keys
;;; follow traditional Emacs ibuffer: m marks, * marks all rows, d flags
;;; for killing, x executes, u and U unmark, RET visits, g refreshes, and
;;; q quits. / narrows the table by name, mode, or path.
;;;
;;; A VIEW is one table buffer with its own scope: *ibuffer* lists every
;;; workspace buffer, *chats* lists the chats. A view's mode takes the
;;; template's options and overrides the few that differ (ibuffer-mode-opts).
;;;
;;; A ROW KIND says what a row shows: a buffer, a chat, a file no buffer
;;; holds. The template asks the kind for the dot, the name, the size,
;;; the label under "mode", the age, the match text, and the face. A
;;; package registers its kind with ibuffer-kind!.
;;;
;;; The group buckets (ibuffer-group-buckets) serve the C-x b prompt too:
;;; the prompt is the same rows in the minibuffer, the table is the same
;;; rows in a window.

(domain! 'buffers)
(effects! '(read))

(defgroup 'buffers "Buffer lists and buffer management.")

(defcustom 'ibuffer-compact-cols 100
  "Below this width, ibuffer combines size, mode, and last-seen details."
  'group 'buffers 'type 'number)

(defcustom 'ibuffer-default-sorting-mode 'name
  "The order of the rows inside a section: 'name, 'recent, or 'size."
  'group 'buffers 'type 'choice)

(defcustom 'ibuffer-default-grouping 'group
  "What a section is: 'group, 'mode, or 'directory."
  'group 'buffers 'type 'choice)

(define *ibuffer-buffer* "*ibuffer*")

(add-display-rule! *ibuffer-buffer* 'popup)

;; the sort modes and the groupings, in the order the toggles cycle
(define *ibuffer-sorts* '(name recent size))
(define *ibuffer-groupings* '(group mode directory))

;; the tint under a heading and under a marked row: a background alone, so
;; the row's own faces show through
(defface! 'ibuffer-heading 'bg "rgba(128, 128, 128, 0.10)")
(defface! 'ibuffer-marked 'bg "rgba(213, 172, 102, 0.13)")

;;; --- views --------------------------------------------------------------------
;;; A view is a table buffer. The registry names them, with the defaults
;;; the view wants when its buffer holds none. The tables survive a
;;; reload of this file: the registries keep what other packages put in.

(define *ibuffer-views*
  (if (boundp '*ibuffer-views*) *ibuffer-views* (list (list *ibuffer-buffer*))))

(define (ibuffer-view! buf &rest defaults)
  (set! *ibuffer-views*
    (cons (cons buf defaults)
          (filter (lambda (v) (not (equal? (car v) buf))) *ibuffer-views*))))

(define (ibuffer-view? b)
  (and (string? b) (assoc b *ibuffer-views*) #t))

(define (ibuffer-view-default buf key)
  (let ((v (assoc buf *ibuffer-views*)))
    (and v (pair? (cdr v)) (plist-get (cdr v) key))))

;; the view a command means: the table it runs in, else *ibuffer*
(define (ibuffer-view)
  (let ((b (current-buffer)))
    (if (ibuffer-view? b) b *ibuffer-buffer*)))

;;; --- row kinds ----------------------------------------------------------------
;;; A kind is (NAME PLIST). The plist holds fns of one row:
;;;   'when?     (b) -> #t            this kind owns the row
;;;   'dot       (b) -> CELL          the one-character state column
;;;   'name      (b) -> (DIR BASE)    the name, its dim head and its base
;;;   'size      (b) -> number or #f  what the size column and the sort read
;;;   'label     (b) -> string        the mode column, and the mode grouping key
;;;   'last      (b) -> string        the age label
;;;   'match     (b) -> string        what / reads beside the name
;;;   'face      (b) -> face          the colour of the name
;;;   'modified? (b) -> #t            counts under "modified"
;;; A kind answers the keys it cares about; the buffer kind answers the rest.

(define *ibuffer-kinds* (if (boundp '*ibuffer-kinds*) *ibuffer-kinds* '()))

(define (ibuffer-kind! name plist)
  (set! *ibuffer-kinds*
    (cons (list name plist)
          (filter (lambda (k) (not (equal? (car k) name))) *ibuffer-kinds*))))

;; a row with no buffer is a file
(define (ibuffer-row-kind b)
  (let loop ((ks *ibuffer-kinds*))
    (cond ((null? ks) (if (buffer-known? b) 'buffer 'file))
          (((plist-get (cadr (car ks)) 'when?) b) (car (car ks)))
          (else (loop (cdr ks))))))

(define (ibuffer-kind-fn kind key)
  (let ((k (assoc kind *ibuffer-kinds*)))
    (and k (plist-get (cadr k) key))))

(define (ibuffer-ask b key default)
  (let ((f (ibuffer-kind-fn (ibuffer-row-kind b) key)))
    (if f (f b) (default b))))

;;; --- last seen ----------------------------------------------------------------
;;; The editor keeps an MRU order but no clock. This table notes the time
;;; a buffer was last shown in the active window. It starts empty at boot,
;;; so a buffer nobody showed since the restart has no time.

(define *ibuffer-seen* '())

(define (ibuffer-note-seen! b)
  (when (string? b)
    (set! *ibuffer-seen*
      (cons (list b (current-time))
            (filter (lambda (e) (not (equal? (car e) b))) *ibuffer-seen*)))))

(define (ibuffer--seen-hook!)
  (when (and (boundp 'active-window) (boundp 'window-buffer))
    (ibuffer-note-seen! (window-buffer (active-window)))))

(add-hook! 'window-configuration-change-hook 'ibuffer--seen-hook!)

(define (ibuffer-seen-at b)
  (let ((e (assoc b *ibuffer-seen*)))
    (and e (cadr e))))

(define (ibuffer-age-label age)
  (cond ((not age) "")
        ((< age 10) "now")
        ((< age 60) (string-append (number->string age) "s"))
        ((< age 3600) (string-append (number->string (quotient age 60)) "m"))
        ((< age 86400) (string-append (number->string (quotient age 3600)) "h"))
        (else (string-append (number->string (quotient age 86400)) "d"))))

(define (ibuffer-last-label b)
  (let ((t (ibuffer-seen-at b)))
    (ibuffer-age-label (and t (- (current-time) t)))))

;;; --- the buffer kind and the file kind ----------------------------------------

(define (ibuffer-human n)
  (cond ((>= n 1048576)
         (string-append (number->string (quotient n 1048576)) "M"))
        ((>= n 1024)
         (string-append (number->string (quotient n 1024)) "k"))
        (else (number->string n))))

(define (ibuffer-short-mode b)
  (let* ((mode (or (buffer-local b 'mode-name) "Fundamental"))
         (n (string-length mode)))
    (if (and (> n 5) (string-suffix? "-mode" mode))
        (substring mode 0 (- n 5))
        mode)))

;; a mode family wears one colour: conversations and pages in accent,
;; text and code in ok, mail and terminals in warn
(define *ibuffer-mode-faces*
  '(("chat" "accent") ("browse" "accent") ("mcp-hub" "accent")
    ("doppler" "accent") ("agent" "accent")
    ("scheme" "ok") ("elixir" "ok") ("org" "ok") ("morg" "ok")
    ("markdown" "ok") ("dired" "ok") ("text" "ok")
    ("notmuch" "warn") ("notmuch-show" "warn") ("irc" "warn")
    ("erc" "warn") ("shell" "warn") ("term" "warn")))

(define (ibuffer-mode-family-face mode)
  (let ((e (assoc mode *ibuffer-mode-faces*)))
    (and e (cadr e))))

(define (ibuffer-row-face b)
  (or (ibuffer-mode-family-face (ibuffer-short-mode b))
      (buffer-filename-face b)
      (and (string-prefix? "*" b) "accent")))

;; the abbreviated directory and the base name of a path; a directory's
;; path ends in a slash and has no base: it is all name
(define (ibuffer-split-path p)
  (let* ((parts (string-split p "/"))
         (base (car (reverse parts))))
    (if (equal? base "")
        (list "" p)
        (list (substring p 0 (- (string-length p) (string-length base))) base))))

;; the directory in front of a file buffer's name; a buffer with no file
;; is all base. The column trims the middle of a long path itself, so
;; the head of the directory and the whole name stay.
(define (ibuffer-row-name-parts b)
  (let ((p (buffer-path b)))
    (if p (ibuffer-split-path (abbreviate-file-name p)) (list "" b))))

(define (ibuffer-file-age b)
  (let ((t (ignore-errors (lambda () (file-mtime b)))))
    (ibuffer-age-label (and (number? t) (- (current-time) t)))))

(define (ibuffer-buffer-dot b)
  (if (and (buffer-known? b) (buffer-modified? b)) (list "●" "warn") ""))

(define (ibuffer-buffer-name b)
  (if (buffer-known? b)
      (ibuffer-row-name-parts b)
      (ibuffer-split-path (abbreviate-file-name b))))

(define (ibuffer-buffer-size b) (and (buffer-known? b) (buffer-size b)))

(define (ibuffer-buffer-label b) (if (buffer-known? b) (ibuffer-short-mode b) "file"))

(define (ibuffer-buffer-last b)
  (if (buffer-known? b) (ibuffer-last-label b) (ibuffer-file-age b)))

(define (ibuffer-buffer-match b)
  (if (buffer-known? b)
      (string-append (or (buffer-local b 'mode-name) "Fundamental") " "
                     (or (buffer-path b) ""))
      "file"))

(define (ibuffer-buffer-face b) (if (buffer-known? b) (ibuffer-row-face b) "dim"))

(define (ibuffer-buffer-modified? b) (and (buffer-known? b) (buffer-modified? b)))

;;; --- what a row shows: the kind's answer, else the buffer's ------------------

(define (ibuffer-row-dot b) (ibuffer-ask b 'dot ibuffer-buffer-dot))
(define (ibuffer-row-name b) (ibuffer-ask b 'name ibuffer-buffer-name))
(define (ibuffer-row-size b) (ibuffer-ask b 'size ibuffer-buffer-size))
(define (ibuffer-row-label b) (ibuffer-ask b 'label ibuffer-buffer-label))
(define (ibuffer-row-last b) (ibuffer-ask b 'last ibuffer-buffer-last))
(define (ibuffer-row-match b) (ibuffer-ask b 'match ibuffer-buffer-match))
(define (ibuffer-row-color b) (ibuffer-ask b 'face ibuffer-buffer-face))
(define (ibuffer-row-modified? b) (ibuffer-ask b 'modified? ibuffer-buffer-modified?))

(define (ibuffer-row-title b)
  (let ((parts (ibuffer-row-name b)))
    (string-append (car parts) (cadr parts))))

(define (ibuffer-row-icon b) (if (buffer-known? b) (buffer-icon b) ""))

(define (ibuffer-row-directory b)
  (let ((p (if (buffer-known? b) (buffer-path b) b)))
    (if p (car (ibuffer-split-path (abbreviate-file-name p))) "no file")))

(define (ibuffer-row-group-label b)
  (if (buffer-known? b) (group-label (buffer-group b)) ""))

(define (ibuffer-memberships b)
  (if (buffer-known? b) (group-buffer-memberships b) '()))

;;; --- the source ---------------------------------------------------------------

(define (ibuffer-workspace-buffer? b)
  (let* ((root (and (boundp (quote daemon-workspace-root))
                    (daemon-workspace-root)))
         (path (or (buffer-path b)
                   (and (string-prefix? "/" b) b))))
    (or (not (string? root))
        (not path)
        (equal? path root)
        (string-prefix? (string-append root "/") path))))

(define (ibuffer-row? b)
  (and (buffer-known? b)
       (not (ibuffer-view? b))
       (not (string-prefix? " " b))
       (not (buffer-context-only? b))
       (ibuffer-workspace-buffer? b)))

;; a named scope is a fn of no arguments that answers the buffers; a view
;; keeps the name on its buffer, so the scope survives a restart
(define *ibuffer-scopes* (if (boundp '*ibuffer-scopes*) *ibuffer-scopes* '()))

(define (ibuffer-scope! name thunk)
  (set! *ibuffer-scopes*
    (cons (list name thunk)
          (filter (lambda (s) (not (equal? (car s) name))) *ibuffer-scopes*))))

;; #f means the ordinary complete table. A list, including an empty list,
;; is the exact result set that a buffer prompt handed to ibuffer. A
;; symbol names a registered scope. The source keeps MRU order; a
;; section sorts its own rows.
(define (ibuffer-source buf)
  (let ((scope (buffer-local buf 'ibuffer-scope)))
    (filter ibuffer-row?
            (cond ((equal? scope #f) (buffer-list-mru))
                  ((symbol? scope)
                   (let ((s (assoc scope *ibuffer-scopes*)))
                     (if s ((cadr s)) '())))
                  (else scope)))))

(define (ibuffer-total buf) (length (ibuffer-source buf)))

;;; --- the view state: sort, grouping, folds -----------------------------------
;;; The three live on the view's buffer, so they survive a quit and a
;;; reopen the way the filters do. BUF defaults to the view a command
;;; runs in.

(define (ibuffer-sort &optional buf)
  (let ((buf (or buf (ibuffer-view))))
    (or (buffer-local buf 'ibuffer-sort)
        (ibuffer-view-default buf 'sort)
        ibuffer-default-sorting-mode)))

(define (ibuffer-grouping &optional buf)
  (let ((buf (or buf (ibuffer-view))))
    (or (buffer-local buf 'ibuffer-grouping)
        (ibuffer-view-default buf 'grouping)
        ibuffer-default-grouping)))

(define (ibuffer-collapsed &optional buf)
  (or (buffer-local (or buf (ibuffer-view)) 'ibuffer-collapsed) '()))

(define (ibuffer-cycle-after item items)
  (let ((rest (member item items)))
    (if (and rest (pair? (cdr rest))) (cadr rest) (car items))))

(define (ibuffer-refresh! &optional buf)
  (list-refresh! (or buf (ibuffer-view))))

(define (ibuffer-set-sort! mode &optional buf)
  (let ((buf (or buf (ibuffer-view))))
    (buffer-set-local! buf 'ibuffer-sort mode)
    (when (buffer-known? buf) (ibuffer-refresh! buf))))

(define (ibuffer-set-grouping! mode &optional buf)
  (let ((buf (or buf (ibuffer-view))))
    (buffer-set-locals! buf (list 'ibuffer-grouping mode 'ibuffer-collapsed '()))
    (when (buffer-known? buf) (ibuffer-refresh! buf))))

(define (ibuffer-folded? key &optional buf)
  (if (member key (ibuffer-collapsed buf)) #t #f))

(define (ibuffer-toggle-fold! key &optional buf)
  (let* ((buf (or buf (ibuffer-view)))
         (now (ibuffer-collapsed buf)))
    (buffer-set-local! buf 'ibuffer-collapsed
      (if (member key now)
          (filter (lambda (k) (not (equal? k key))) now)
          (cons key now)))
    (ibuffer-refresh! buf)))

;;; --- sorting ------------------------------------------------------------------

(define (ibuffer-sort-names rows)
  (map cadr (sort (map (lambda (row) (list (string-downcase (ibuffer-row-title row)) row))
                       rows))))

(define (ibuffer-sort-sizes rows)
  (map cadr (sort (map (lambda (row) (list (- 0 (or (ibuffer-row-size row) 0)) row))
                       rows))))

(define (ibuffer-sort-rows buf rows)
  (let ((mode (ibuffer-sort buf)))
    (cond ((equal? mode 'size) (ibuffer-sort-sizes rows))
          ((equal? mode 'recent) rows)
          (else (ibuffer-sort-names rows)))))

;;; --- headings -----------------------------------------------------------------
;;; A heading row is a list: (LABEL "" KIND KEY COUNT MODIFIED BYTES FACE
;;; MEMBERS). KIND is "separator" for an open section, whose rows follow
;;; it, or "folded" for a closed one, whose rows it stands for. A folded
;;; heading is a row of its own: the narrowing keeps it when a member
;;; matches, the highlight can rest on it, and RET or TAB opens it.

(define (ibuffer-heading label key kind members face)
  (list label "" kind key
        (length members)
        (length (filter ibuffer-row-modified? members))
        (fold (lambda (n b) (+ n (or (ibuffer-row-size b) 0))) 0 members)
        face
        members))

(define (ibuffer-heading? row) (and (pair? row) (> (length row) 2)))
(define (ibuffer-heading-label row) (car row))
(define (ibuffer-heading-key row) (nth 3 row))
(define (ibuffer-heading-count row) (nth 4 row))
(define (ibuffer-heading-modified row) (nth 5 row))
(define (ibuffer-heading-bytes row) (nth 6 row))
(define (ibuffer-heading-face row) (nth 7 row))
(define (ibuffer-heading-members row) (nth 8 row))
(define (ibuffer-heading-folded? row) (equal? (nth 2 row) "folded"))

(define (ibuffer-separator? buf row)
  (and (ibuffer-heading? row) (equal? (nth 2 row) "separator")))

;; a section: its heading, then its members in the view's order. AS-IS?
;; keeps the order the members came in: the saved chats come newest first
;; and have no name to sort by.
(define (ibuffer-section buf label key members face &optional as-is?)
  (if (null? members)
      '()
      (let ((ordered (if as-is? members (ibuffer-sort-rows buf members))))
        (if (ibuffer-folded? key buf)
            (list (ibuffer-heading label key "folded" ordered face))
            (cons (ibuffer-heading label key "separator" ordered face) ordered)))))

;;; --- buckets by group ---------------------------------------------------------
;;; The rows in buckets by group: the current group first, then the
;;; other groups by name, then the rows no group claims. A row belongs to
;;; one bucket. The current group wins; otherwise the first group by name
;;; owns the row. A bucket is (LABEL KEY MEMBERS FACE); an empty one is
;;; left out. MEMBERSHIPS-OF answers a row's group ids. The C-x b prompt
;;; reads the same buckets, so the two surfaces section alike.

(define (ibuffer-group-buckets rows current memberships-of)
  (let* ((named (sort (map (lambda (id)
                             (list (string-downcase (or (group-name id) "")) id))
                           (filter (lambda (id) (not (equal? id current)))
                                   (group-ids)))))
         (ordered (append (if current (list current) '()) (map cadr named)))
         (owner-of (lambda (row)
                     (let ((ms (memberships-of row)))
                       (let loop ((gs ordered))
                         (cond ((null? gs) #f)
                               ((member (car gs) ms) (car gs))
                               (else (loop (cdr gs))))))))
         (owned (map (lambda (row) (list (owner-of row) row)) rows))
         (of (lambda (id)
               (map cadr (filter (lambda (o) (equal? (car o) id)) owned))))
         (buckets (map (lambda (id)
                         (let ((ms (of id)))
                           (and (pair? ms)
                                (list (if (equal? id current)
                                          "in this group"
                                          (or (group-name id) id))
                                      (string-append "group:" id)
                                      ms
                                      (group-color-face id)))))
                       ordered))
         (rest (of #f)))
    (append (filter pair? buckets)
            (if (null? rest) '() (list (list "ungrouped" "group:" rest "faint"))))))

(define (ibuffer-group-sections buf rows current)
  (fold (lambda (out bucket)
          (append out
            (ibuffer-section buf (car bucket) (nth 1 bucket) (nth 2 bucket) (nth 3 bucket))))
        '()
        (ibuffer-group-buckets rows current ibuffer-memberships)))

;; the rows bucketed by a key fn, one section per key, keys by name;
;; LAST names the key that goes at the end whatever its name
(define (ibuffer-keyed-sections buf rows key-of face-of last)
  (let* ((keys (dedupe-names (map key-of rows)))
         (named (map cadr
                     (sort (map (lambda (k) (list (string-downcase k) k))
                                (filter (lambda (k) (not (equal? k last))) keys)))))
         (ordered (append named (if (member last keys) (list last) '()))))
    (fold (lambda (out k)
            (append out
              (ibuffer-section buf k k
                (filter (lambda (row) (equal? (key-of row) k)) rows)
                (face-of k))))
          '() ordered)))

;; the mode grouping keys on the row's label: the mode of a buffer, the
;; state of a chat
(define (ibuffer-mode-sections buf rows)
  (ibuffer-keyed-sections buf rows ibuffer-row-label ibuffer-mode-family-face #f))

(define (ibuffer-directory-sections buf rows)
  (ibuffer-keyed-sections buf rows ibuffer-row-directory (lambda (k) "accent")
                          "no file"))

;; The list fetches its rows on open and on g. A mark or a narrowing
;; redraws the rows it already has, so the cursor stays stable.
(define (ibuffer-rows buf)
  (let ((rows (ibuffer-source buf))
        (grouping (ibuffer-grouping buf)))
    (cond ((equal? grouping 'mode) (ibuffer-mode-sections buf rows))
          ((equal? grouping 'directory) (ibuffer-directory-sections buf rows))
          (else (ibuffer-group-sections
                  buf rows (and (boundp 'frame-group) (frame-group)))))))

(define (ibuffer-visible &optional buf)
  (let ((buf (or buf (ibuffer-view))))
    (list-keep buf (ibuffer-rows buf))))

;;; --- one row's words ----------------------------------------------------------

(define (ibuffer-size-label b)
  (let ((n (ibuffer-row-size b)))
    (if (number? n) (ibuffer-human n) "")))

(define (ibuffer-details b)
  (string-join
    (filter (lambda (part) (not (equal? part "")))
      (list (ibuffer-size-label b)
            (ibuffer-row-label b)
            (ibuffer-row-last b)))
    " · "))

(define (ibuffer-noun buf n)
  (let ((noun (or (list-opt buf 'noun) "buffer")))
    (string-append (number->string n) " " noun (if (= n 1) "" "s"))))

(define (ibuffer-heading-details buf row width)
  (let ((m (ibuffer-heading-modified row)))
    (string-append
      (if (and (> m 0) (>= width 28))
          (string-append (number->string m) " modified · ")
          "")
      (ibuffer-noun buf (ibuffer-heading-count row)) " · "
      (ibuffer-human (ibuffer-heading-bytes row)))))

(define (ibuffer-chevron row) (if (ibuffer-heading-folded? row) "▸" "▾"))

;;; --- columns and cells --------------------------------------------------------

;; the details take a third of a narrow window and no more than 30
;; columns of a wide one; the name keeps the rest
(define (ibuffer-details-width w) (max 16 (min 30 (quotient w 3))))

(define (ibuffer-compact-columns buf)
  (list (list "" 1)
        (list "" 1)
        (list "buffer" #f)
        (list "details" (ibuffer-details-width (list-view-width buf)) 'right)))

(define (ibuffer-details-column-width buf)
  (let ((cols (list-columns buf)))
    (if (> (length cols) 3) (or (list-col-width (nth 3 cols)) 30) 30)))

(define (ibuffer-wide-columns buf)
  (list (list "" 1)
        (list "" 1)
        (list "buffer" #f)
        (list "size" 7 'right)
        (list "mode" 16)
        (list "group" 18)
        (list "last" 4 'right)
        (list "file" 4)))

(define (ibuffer-cell-head b)
  (list (ibuffer-row-dot b)
        (list (ibuffer-row-icon b) "faint")
        (list (ibuffer-row-title b) (ibuffer-row-color b))))

(define (ibuffer-heading-head row)
  (list ""
        (list (ibuffer-chevron row) "dim")
        (list (ibuffer-heading-label row) (or (ibuffer-heading-face row) "accent"))))

(define (ibuffer-compact-cells buf b)
  (if (ibuffer-heading? b)
      (append (ibuffer-heading-head b)
              (list (list (ibuffer-heading-details buf b (ibuffer-details-column-width buf))
                          "dim")))
      (append (ibuffer-cell-head b)
              (list (list (ibuffer-details b) "faint")))))

(define (ibuffer-wide-cells buf b)
  (if (ibuffer-heading? b)
      (append (ibuffer-heading-head b)
        (list (list (ibuffer-human (ibuffer-heading-bytes b)) "dim")
              (let ((m (ibuffer-heading-modified b)))
                (if (> m 0)
                    (list (string-append (number->string m) " modified") "warn")
                    ""))
              (list (ibuffer-noun buf (ibuffer-heading-count b)) "dim")
              "" ""))
      (append (ibuffer-cell-head b)
        (list (list (ibuffer-size-label b) "dim")
              (list (ibuffer-row-label b) "faint")
              (list (ibuffer-row-group-label b)
                    (and (buffer-known? b) (buffer-group b)
                         (group-color-face (buffer-group b))))
              (list (ibuffer-row-last b) "dim")
              (list (if (or (not (buffer-known? b)) (buffer-path b)) "✓" "") "ok")))))

;; the directory in front of a file name is dim: a span over the head of
;; the buffer cell. The cell sits after the mark and the two one-character
;; columns; the dot and the icon can be multibyte, so the span counts
;; their bytes and not their columns.
(define (ibuffer-prefix-chars a b)
  (let ((n (min (string-length a) (string-length b))))
    (let loop ((i 0))
      (if (and (< i n) (equal? (substring a i (+ i 1)) (substring b i (+ i 1))))
          (loop (+ i 1))
          i))))

(define (ibuffer-row-bytes buf b)
  (fold (lambda (n line) (+ n (string-byte-length (car line)) 1))
        0 (list-row-lines buf b)))

(define (ibuffer-band buf b off face)
  (list (list off (+ off (ibuffer-row-bytes buf b) -1) face)))

(define (ibuffer-row-overlays buf b off)
  (cond ((ibuffer-heading? b) (ibuffer-band buf b off "ibuffer-heading"))
        ((not (equal? (list-mark-of buf b) " "))
         (append (ibuffer-band buf b off "ibuffer-marked")
                 (ibuffer-dir-overlay buf b off)))
        (else (ibuffer-dir-overlay buf b off))))

(define (ibuffer-cell-text cell) (if (pair? cell) (car cell) cell))

(define (ibuffer-dir-overlay buf b off)
  (let* ((parts (ibuffer-row-name b))
         (dir (car parts)))
    (if (equal? dir "")
        '()
        (let* ((cols (list-columns buf))
               (width (and (> (length cols) 2) (list-col-width (nth 2 cols))))
               (fitted (list-fit (string-append dir (cadr parts)) width 'middle))
               (dim (substring fitted 0 (ibuffer-prefix-chars fitted dir)))
               (dot (let ((d (ibuffer-cell-text (ibuffer-row-dot b))))
                      (if (equal? d "") " " d)))
               (icon (let ((i (ibuffer-row-icon b))) (if (equal? i "") " " i)))
               (start (+ off 2
                         (string-byte-length dot) 2
                         (string-byte-length icon) 2)))
          (if (equal? dim "")
              '()
              (list (list start (+ start (string-byte-length dim)) "dim")))))))

;;; --- the head and the key bar -------------------------------------------------

;; the pieces of a line with their faces, as the text and its spans
(define (ibuffer-join-parts parts)
  (let loop ((ps parts) (text "") (spans '()))
    (if (null? ps)
        (list text (reverse spans))
        (let* ((t (car (car ps)))
               (f (cadr (car ps)))
               (at (string-byte-length text)))
          (loop (cdr ps)
                (string-append text t)
                (if f (cons (list at (string-byte-length t) f) spans) spans))))))

;; a row of choices: the label, then every choice, the current one lit
(define (ibuffer-chips label items current)
  (cons (list label "faint")
        (let loop ((is items) (out '()))
          (if (null? is)
              (reverse out)
              (loop (cdr is)
                    (cons (list (car is) (if (equal? (car is) current) "accent" "dim"))
                          (cons (list (if (null? out) " " " · ") "dim") out)))))))

(define (ibuffer-counts-parts buf n dirty bytes)
  (list (list (string-append
                (ibuffer-noun buf n)
                " · " (number->string dirty) " modified"
                " · " (ibuffer-human bytes))
              "dim")))

;; the wide head says the choices as chips; the compact one says the
;; current ones in four words
(define (ibuffer-wide-meta-line buf n dirty bytes)
  (ibuffer-join-parts
    (append (ibuffer-counts-parts buf n dirty bytes)
            (list (list "   " #f))
            (ibuffer-chips "GROUP" (map symbol->string *ibuffer-groupings*)
                           (symbol->string (ibuffer-grouping buf)))
            (list (list "   " #f))
            (ibuffer-chips "SORT" (map symbol->string *ibuffer-sorts*)
                           (symbol->string (ibuffer-sort buf))))))

(define (ibuffer-compact-meta-line buf n dirty bytes)
  (ibuffer-join-parts
    (append (ibuffer-counts-parts buf n dirty bytes)
            (list (list (string-append " · by " (symbol->string (ibuffer-grouping buf))
                                       " · " (symbol->string (ibuffer-sort buf)))
                        "dim")))))

(define (ibuffer-meta-with buf line)
  (let loop ((rows (list-entries buf)) (n 0) (dirty 0) (bytes 0))
    (cond ((null? rows) (line buf n dirty bytes))
          ((ibuffer-heading? (car rows))
           (let ((row (car rows)))
             (if (ibuffer-heading-folded? row)
                 (loop (cdr rows)
                       (+ n (ibuffer-heading-count row))
                       (+ dirty (ibuffer-heading-modified row))
                       (+ bytes (ibuffer-heading-bytes row)))
                 (loop (cdr rows) n dirty bytes))))
          (else
           (let ((b (car rows)))
             (loop (cdr rows) (+ n 1)
                   (+ dirty (if (ibuffer-row-modified? b) 1 0))
                   (+ bytes (or (ibuffer-row-size b) 0))))))))

(define (ibuffer-compact-meta buf) (ibuffer-meta-with buf ibuffer-compact-meta-line))
(define (ibuffer-wide-meta buf) (ibuffer-meta-with buf ibuffer-wide-meta-line))
(define (ibuffer-meta buf) (ibuffer-compact-meta buf))

(define (ibuffer-compact-footer buf)
  '(("RET" "visit") ("SPC" "mark") ("k" "kill") ("TAB" "fold")
    ("," "sort") (";" "group by") ("/" "filter") ("q" "quit")))

(define (ibuffer-wide-footer buf)
  '(("RET" "visit") ("SPC" "mark") ("*" "all") ("k" "kill") ("TAB" "fold")
    ("," "sort") (";" "group by") ("G" "add to group") ("K" "kill group")
    ("d" "flag") ("x" "execute") ("/" "filter")
    ("\\" "widen") ("g" "refresh") ("q" "quit")))

;; what `/` reads: the name and what the row's kind adds — the mode and
;; the path of a buffer, the summary and the state of a chat
(define (ibuffer-match? buf row input)
  (if (ibuffer-heading? row)
      (let loop ((ms (ibuffer-heading-members row)))
        (and (pair? ms)
             (or (ibuffer-match? buf (car ms) input) (loop (cdr ms)))))
      (completion-match?
        (string-append row " " (ibuffer-row-title row) " " (ibuffer-row-match row))
        input 'substring)))

(define (ibuffer-current &optional buf) (list-current (or buf (ibuffer-view))))
(define (ibuffer-filter-push! f &optional buf) (list-filter-push! (or buf (ibuffer-view)) f))

;; the heading of the section the highlight is in: the row itself when it
;; is a heading, else the nearest heading above it
(define (ibuffer-section-at &optional buf)
  (let* ((buf (or buf (ibuffer-view)))
         (i (list-clamped-index buf))
         (es (list-entries buf)))
    (and i
         (let loop ((k (min i (- (length es) 1))))
           (cond ((< k 0) #f)
                 ((ibuffer-heading? (nth k es)) (nth k es))
                 (else (loop (- k 1))))))))

(domain! 'buffers)
(effects! '(read))

;; open (or re-open) a view on SCOPE: *ibuffer* in ibuffer-mode unless a
;; view and its mode are named
(define (ibuffer-open! scope &optional view mode)
  (let ((from (active-window))
        (buf (or view *ibuffer-buffer*)))
    (buffer-create buf)
    (buffer-set-local! buf 'ibuffer-scope scope)
    ;; Typed narrowing is temporary. Keep any mode-specific filters.
    (list-clear-query! buf)
    (display-buffer buf)
    (let ((w (window-showing-other buf from)))
      (if w (select-window! w) (switch-to-buffer! buf)))
    (set-mode! (or mode "ibuffer-mode"))
    (ibuffer-refresh! buf)
    (list-goto-first-entry buf)))

(define (ibuffer-open-buffers! buffers)
  (ibuffer-open! (dedupe-names (filter buffer-known? buffers)))
  (list-preview! *ibuffer-buffer*))

(define-command "ibuffer" "List buffers in a traditional management table"
  (lambda () (ibuffer-open! #f)))

(define-command "ibuffer-visit"
  "Visit the selected row in another window; on a folded heading, open the section"
  (lambda ()
    (let ((b (ibuffer-current)))
      (cond ((ibuffer-heading? b) (ibuffer-toggle-fold! (ibuffer-heading-key b)))
            ((and (string? b) (buffer-known? b))
             (let ((w (display-buffer-other-window! b)))
               (run-command "quit-window")
               (when (and w (window-exists? w)) (select-window! w))
               (switch-to-buffer! b)))
            ;; a file no buffer holds: visit it where the table came from
            ((and (string? b) (file-exists? b))
             (run-command "quit-window")
             (visit-in-group b (and (boundp 'frame-group) (frame-group))))
            (else (message "no buffer here"))))))

(define-command "ibuffer-refresh" "Refresh the buffer table"
  (lambda () (ibuffer-refresh!)))

(define-command "ibuffer-toggle-filter-group"
  "Fold or unfold the section at point"
  (lambda ()
    (let ((row (ibuffer-section-at)))
      (if row
          (ibuffer-toggle-fold! (ibuffer-heading-key row))
          (message "no section here")))))

(define-command "ibuffer-toggle-sorting-mode"
  "Cycle the order inside a section: name, recent, size"
  (lambda ()
    (let ((next (ibuffer-cycle-after (ibuffer-sort) *ibuffer-sorts*)))
      (ibuffer-set-sort! next)
      (message (string-append "sorted by " (symbol->string next))))))

(define-command "ibuffer-do-sort-by-alphabetic" "Order the rows of a section by name"
  (lambda () (ibuffer-set-sort! 'name)))

(define-command "ibuffer-do-sort-by-recency" "Order the rows of a section by last use"
  (lambda () (ibuffer-set-sort! 'recent)))

(define-command "ibuffer-do-sort-by-size" "Order the rows of a section by size, largest first"
  (lambda () (ibuffer-set-sort! 'size)))

(define-command "ibuffer-toggle-grouping"
  "Cycle what a section is: group, mode, directory"
  (lambda ()
    (let ((next (ibuffer-cycle-after (ibuffer-grouping) *ibuffer-groupings*)))
      (ibuffer-set-grouping! next)
      (message (string-append "grouped by " (symbol->string next))))))

;; the row under the highlight shows in the window this listing covers,
;; and leaves no trace: not a peek, which goes to the popup this listing
;; is in
(define (ibuffer-preview! &optional buf b)
  (let ((b (or b (ibuffer-current buf)))
        (w (other-window-id (active-window))))
    (when (and w (string? b) (buffer-known? b))
      (window-preview-buffer! b w))))

(define-command "ibuffer-next" "Move down and preview the selected buffer"
  (lambda () (list-move! 1)))

(define-command "ibuffer-prev" "Move up and preview the selected buffer"
  (lambda () (list-move! -1)))

(effects! '(destroy))

(define (ibuffer-kill-targets! view targets killed kept)
  ;; Confirm serially: one minibuffer question at a time, and every target
  ;; goes through the same high-level policy as C-x k.
  (if (null? targets)
      (begin
        (when (buffer-known? view) (list-refresh! view))
        (message
          (string-append "killed " (number->string killed) " buffers"
                         (if (> kept 0)
                             (string-append "; kept " (number->string kept))
                             ""))))
      (let ((target (car targets)))
        (if (not (and (string? target) (buffer-known? target)))
            (ibuffer-kill-targets! view (cdr targets) killed kept)
            (kill-buffer-confirm! target
              (lambda (killed?)
                (when (and killed? (buffer-known? view))
                  (list-unmark-key! view target))
                (ibuffer-kill-targets! view
                                      (cdr targets)
                                      (+ killed (if killed? 1 0))
                                      (+ kept (if killed? 0 1)))))))))

(define-command "ibuffer-kill" "Kill the marked buffers, or the row at point"
  (lambda ()
    (let ((view (current-buffer))
          (targets (list-targets (current-buffer))))
      (ibuffer-kill-targets! view targets 0 0))))

;; the group at point: under group sectioning, the section's group;
;; otherwise the group of the buffer on the row
(define (ibuffer-group-at &optional buf)
  (let* ((buf (or buf (ibuffer-view)))
         (row (ibuffer-current buf))
         (heading (ibuffer-section-at buf)))
    (cond ((and (equal? (ibuffer-grouping buf) 'group) heading)
           (let ((key (ibuffer-heading-key heading)))
             (and (string-prefix? "group:" key)
                  (> (string-length key) 6)
                  (substring key 6 (string-length key)))))
          ((and (string? row) (buffer-known? row)) (buffer-group row))
          (else #f))))

(define-command "ibuffer-group-kill"
  "Kill the group at point: every member, then the group itself"
  (lambda ()
    (let ((g (ibuffer-group-at))
          (view (ibuffer-view)))
      (if g
          (begin (group-kill! g)
                 (when (buffer-known? view) (ibuffer-refresh! view)))
          (message "no group here")))))

(effects! '(read))

;;; --- the template -------------------------------------------------------------
;;; Every view is one list mode built from these options. A view's own
;;; mode overrides a few: its buffer, its title, its noun, its rows, its
;;; flags. Its keys ADD to the template's, and a flag key binds last, so
;;; a view's flag wins over the template's command on the same key.

(define *ibuffer-opts*
  (list
    'doc (string-append
           "A traditional buffer management table. A section is a group, "
           "a mode, or a directory; ; cycles the grouping. Rows inside a "
           "section sort by name, recency, or size; , cycles the sort. "
           "TAB folds the section at point. Compact rows combine size, "
           "mode, and last-seen details. Wide rows also show the group and "
           "the file status. / narrows the table by name, mode, or path, "
           "and \\ widens it. m marks one row, SPC toggles the mark, * marks all shown rows, u "
           "unmarks one row, and U clears all marks. k kills now. d flags "
           "rows for killing, and x executes the flags. G puts the targets "
           "in a group, and K kills the group at point. RET visits, g "
           "refreshes, and q quits.")
    'buffer *ibuffer-buffer*
    'category 'buffer
    'rows ibuffer-rows
    'separator? ibuffer-separator?
    'section? (lambda (buf b) (ibuffer-heading? b))
    'markable? (lambda (buf b) (string? b))
    'key (lambda (buf b)
           (if (ibuffer-heading? b)
               (string-append "section:" (ibuffer-heading-key b))
               b))
    'match ibuffer-match?
    'overlays ibuffer-row-overlays
    'local-filter #t
    'stamp (lambda (buf) (length (buffer-list-mru)))
    'layouts
      (list
        (list 'name 'compact
              'max-cols (lambda (buf) (- ibuffer-compact-cols 1))
              'columns ibuffer-compact-columns
              'cells ibuffer-compact-cells
              'meta ibuffer-compact-meta
              'footer ibuffer-compact-footer)
        (list 'name 'wide
              'default #t
              'columns ibuffer-wide-columns
              'cells ibuffer-wide-cells
              'meta ibuffer-wide-meta
              'footer ibuffer-wide-footer))
    'title (lambda (buf) "Buffers")
    'meta ibuffer-meta
    'total ibuffer-total
    'compact #t
    'flags (list (list "d" "D" "kill"
                       (lambda (buf b)
                         (and (string? b)
                              (buffer-known? b)
                              (begin (buffer-kill! b) #t)))))
    'noun "buffer"
    'preview (lambda (buf b) (ibuffer-preview! buf b))
    'keys '(("RET" "ibuffer-visit") ("SPC" "list-toggle-mark")
            ("k" "ibuffer-kill") ("K" "ibuffer-group-kill")
            ("TAB" "ibuffer-toggle-filter-group")
            ("," "ibuffer-toggle-sorting-mode")
            (";" "ibuffer-toggle-grouping")
            ("G" "group-add") ("g" "ibuffer-refresh")
            ("q" "quit-window"))
    ;; line movement steps over the headings and previews the row
    'remap '(("next-line" "list-next") ("previous-line" "list-prev"))))

(define (ibuffer-plist-put plist key value)
  (let loop ((ps plist) (out '()) (found #f))
    (cond ((null? ps)
           (append (reverse out) (if found '() (list key value))))
          ((equal? (car ps) key)
           (loop (cddr ps) (cons value (cons key out)) #t))
          (else (loop (cddr ps) (cons (cadr ps) (cons (car ps) out)) found)))))

(define (ibuffer-mode-opts overrides)
  (let loop ((os overrides) (opts *ibuffer-opts*))
    (if (null? os)
        opts
        (let ((key (car os)) (value (cadr os)))
          (loop (cddr os)
                (ibuffer-plist-put opts key
                  (if (equal? key 'keys)
                      (append (plist-get opts 'keys) value)
                      value)))))))

(mode-icon! "ibuffer-mode" "")

(define-list-mode! "ibuffer-mode" *ibuffer-opts*)

(define-key "ctl-x-map" "C-b" "ibuffer")

(category! 'buffers)
(catalog-meta! 'command "ibuffer-kill" 'domain 'buffers 'effects '(destroy))
(catalog-meta! 'command "ibuffer-group-kill" 'domain 'buffers 'effects '(destroy))
(public! 'ibuffer-refresh! "(ibuffer-refresh! [BUF]) — rebuild the table BUF, else the view at hand")
(public! 'ibuffer-open! "(ibuffer-open! SCOPE [VIEW MODE]) — open a table on SCOPE: #f for every buffer, a list, or a scope name")
(public! 'ibuffer-open-buffers! "(ibuffer-open-buffers! BUFFERS) — open ibuffer on exactly these known buffers")
(public! 'ibuffer-set-sort! "(ibuffer-set-sort! MODE [BUF]) — order the rows of a section by 'name, 'recent, or 'size")
(public! 'ibuffer-set-grouping! "(ibuffer-set-grouping! MODE [BUF]) — section the table by 'group, 'mode, or 'directory")
(public! 'ibuffer-toggle-fold! "(ibuffer-toggle-fold! KEY [BUF]) — fold or unfold the section KEY names")
(public! 'ibuffer-age-label "(ibuffer-age-label SECONDS) — \"now\", \"40s\", \"5m\", \"2h\", \"3d\", or \"\" for #f")
(public! 'ibuffer-kind! "(ibuffer-kind! NAME PLIST) — register a row kind: 'when? 'dot 'name 'size 'label 'last 'match 'face 'modified? fns of a row")
(public! 'ibuffer-scope! "(ibuffer-scope! NAME THUNK) — register a named scope; a view's 'ibuffer-scope local names it")
(public! 'ibuffer-view! "(ibuffer-view! BUF . DEFAULTS) — register a table buffer with its default 'sort and 'grouping")
(public! 'ibuffer-mode-opts "(ibuffer-mode-opts OVERRIDES) — the template's list-mode options with OVERRIDES; 'keys add to the template's")
(public! 'ibuffer-group-buckets "(ibuffer-group-buckets ROWS CURRENT MEMBERSHIPS-OF) — rows in (LABEL KEY MEMBERS FACE) buckets: this group, the others by name, ungrouped")
