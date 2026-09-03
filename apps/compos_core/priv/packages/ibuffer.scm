;;; ibuffer.scm --- the buffer list as a dired: filter, mark, act.
;;;
;;; C-x C-b and M-x ibuffer open *ibuffer*. The table shows one row per
;;; buffer under a heading per section. A section is a group, a mode, or
;;; a directory; `;` cycles the grouping. Inside a section the rows sort
;;; by name, by recency, or by size; `,` cycles the sort. TAB folds the
;;; section at point, and a folded heading stays as a row that carries
;;; its counts. A row shows the modified dot, the icon, the directory in
;;; dim and the name in the colour of its mode family, and on the right
;;; the size, the mode, and the time since the buffer was last shown.
;;; The keys follow traditional Emacs ibuffer: m marks, * marks all rows,
;;; d flags for killing, x executes, u and U unmark, RET visits, g
;;; refreshes, and q quits. / narrows the table by name, mode, or path.

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

(define *ibuffer-sorts* '(name recent size))

;; a heading wears a band across its row, and a marked or flagged row a
;; tint; both are translucent, so they sit on any theme
(defface! 'ibuffer-heading 'bg "rgba(128, 128, 128, 0.10)")
(defface! 'ibuffer-marked 'bg "rgba(213, 172, 102, 0.13)")
(define *ibuffer-groupings* '(group mode directory))

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
       (not (equal? b *ibuffer-buffer*))
       (not (string-prefix? " " b))
       (not (buffer-context-only? b))
       (ibuffer-workspace-buffer? b)))

;; #f means the ordinary complete table. A list, including an empty list,
;; is the exact result set that a buffer prompt handed to ibuffer. The
;; source keeps MRU order; a section sorts its own rows.
(define (ibuffer-source)
  (let ((scope (buffer-local *ibuffer-buffer* 'ibuffer-scope)))
    (filter ibuffer-row? (if (equal? scope #f) (buffer-list-mru) scope))))

(define (ibuffer-total) (length (ibuffer-source)))

;;; --- the view state: sort, grouping, folds -----------------------------------
;;; The three live on the list buffer, so they survive a quit and a
;;; reopen the way the filters do.

(define (ibuffer-sort)
  (or (buffer-local *ibuffer-buffer* 'ibuffer-sort) ibuffer-default-sorting-mode))

(define (ibuffer-grouping)
  (or (buffer-local *ibuffer-buffer* 'ibuffer-grouping) ibuffer-default-grouping))

(define (ibuffer-collapsed)
  (or (buffer-local *ibuffer-buffer* 'ibuffer-collapsed) '()))

(define (ibuffer-cycle-after item items)
  (let ((rest (member item items)))
    (if (and rest (pair? (cdr rest))) (cadr rest) (car items))))

(define (ibuffer-set-sort! mode)
  (buffer-set-local! *ibuffer-buffer* 'ibuffer-sort mode)
  (when (buffer-known? *ibuffer-buffer*) (ibuffer-refresh!)))

(define (ibuffer-set-grouping! mode)
  (buffer-set-locals! *ibuffer-buffer*
    (list 'ibuffer-grouping mode 'ibuffer-collapsed '()))
  (when (buffer-known? *ibuffer-buffer*) (ibuffer-refresh!)))

(define (ibuffer-folded? key) (if (member key (ibuffer-collapsed)) #t #f))

(define (ibuffer-toggle-fold! key)
  (let ((now (ibuffer-collapsed)))
    (buffer-set-local! *ibuffer-buffer* 'ibuffer-collapsed
      (if (member key now)
          (filter (lambda (k) (not (equal? k key))) now)
          (cons key now)))
    (ibuffer-refresh!)))

;;; --- sorting ------------------------------------------------------------------

(define (ibuffer-sort-names rows)
  (map cadr (sort (map (lambda (row) (list (string-downcase row) row)) rows))))

(define (ibuffer-sort-sizes rows)
  (map cadr (sort (map (lambda (row) (list (- 0 (buffer-size row)) row)) rows))))

(define (ibuffer-sort-rows rows)
  (let ((mode (ibuffer-sort)))
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
        (length (filter buffer-modified? members))
        (fold (lambda (n b) (+ n (buffer-size b))) 0 members)
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

(define (ibuffer-section label key members face)
  (if (null? members)
      '()
      (if (ibuffer-folded? key)
          (list (ibuffer-heading label key "folded" members face))
          (cons (ibuffer-heading label key "separator" members face)
                (ibuffer-sort-rows members)))))

;; A buffer can belong to many groups, but an ibuffer row appears once. The
;; current group wins. Otherwise, the first group by name owns the row.
(define (ibuffer-row-group row ordered-groups)
  (let ((memberships (group-buffer-memberships row)))
    (let loop ((groups ordered-groups))
      (cond ((null? groups) #f)
            ((member (car groups) memberships) (car groups))
            (else (loop (cdr groups)))))))

;; Match C-x b for the current section, then continue group by group. Other
;; groups sort by name. Buffers with no matching membership come last.
(define (ibuffer-group-sections rows current)
  (let* ((named (sort (map (lambda (id)
                             (list (string-downcase (group-name id)) id))
                           (filter (lambda (id) (not (equal? id current)))
                                   (group-ids)))))
         (ordered (append (if current (list current) '()) (map cadr named)))
         (grouped
           (fold (lambda (out id)
                   (append out
                     (ibuffer-section
                       (if (equal? id current) "in this group" (group-name id))
                       (string-append "group:" id)
                       (filter (lambda (row)
                                 (equal? (ibuffer-row-group row ordered) id))
                               rows)
                       (group-color-face id))))
                 '() ordered))
         (ungrouped
           (filter (lambda (row) (not (ibuffer-row-group row ordered))) rows)))
    (append grouped (ibuffer-section "ungrouped" "group:" ungrouped "faint"))))

;; the rows bucketed by a key fn, one section per key, keys by name;
;; LAST names the key that goes at the end whatever its name
(define (ibuffer-keyed-sections rows key-of face-of last)
  (let* ((keys (dedupe-names (map key-of rows)))
         (named (map cadr
                     (sort (map (lambda (k) (list (string-downcase k) k))
                                (filter (lambda (k) (not (equal? k last))) keys)))))
         (ordered (append named (if (member last keys) (list last) '()))))
    (fold (lambda (out k)
            (append out
              (ibuffer-section k k
                (filter (lambda (row) (equal? (key-of row) k)) rows)
                (face-of k))))
          '() ordered)))

(define (ibuffer-mode-sections rows)
  (ibuffer-keyed-sections rows ibuffer-short-mode ibuffer-mode-family-face #f))

(define (ibuffer-directory-sections rows)
  (ibuffer-keyed-sections rows ibuffer-row-directory (lambda (k) "accent")
                          "no file"))

;; The list fetches its rows on open and on g. A mark or a narrowing
;; redraws the rows it already has, so the cursor stays stable.
(define (ibuffer-rows)
  (let ((rows (ibuffer-source))
        (grouping (ibuffer-grouping)))
    (cond ((equal? grouping 'mode) (ibuffer-mode-sections rows))
          ((equal? grouping 'directory) (ibuffer-directory-sections rows))
          (else (ibuffer-group-sections
                  rows (and (boundp 'frame-group) (frame-group)))))))

(define (ibuffer-visible)
  (list-keep *ibuffer-buffer* (ibuffer-rows)))

;;; --- one row's words ----------------------------------------------------------

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

;; the abbreviated directory and the base name of a file buffer; a buffer
;; with no file is all base
(define (ibuffer-split-path p)
  (let* ((parts (string-split p "/"))
         (base (car (reverse parts))))
    (list (substring p 0 (- (string-length p) (string-length base))) base)))

(define (ibuffer-row-directory b)
  (let ((p (buffer-path b)))
    (if p (car (ibuffer-split-path (abbreviate-file-name p))) "no file")))

(define (ibuffer-row-name-parts b)
  (let ((p (buffer-path b)))
    (if p
        (let ((parts (ibuffer-split-path (abbreviate-file-name p))))
          ;; a directory's path ends in a slash and has no base: it is
          ;; all name
          (if (equal? (cadr parts) "")
              (list "" (abbreviate-file-name p))
              ;; the column trims the middle of a long path itself, so
              ;; the head of the directory and the whole name stay
              parts))
        (list "" b))))

(define (ibuffer-details b)
  (string-join
    (filter (lambda (part) (not (equal? part "")))
      (list (ibuffer-human (buffer-size b))
            (ibuffer-short-mode b)
            (ibuffer-last-label b)))
    " · "))

(define (ibuffer-heading-details row width)
  (let ((m (ibuffer-heading-modified row))
        (n (ibuffer-heading-count row)))
    (string-append
      (if (and (> m 0) (>= width 28))
          (string-append (number->string m) " modified · ")
          "")
      (number->string n) (if (= n 1) " buffer · " " buffers · ")
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
  (let ((parts (ibuffer-row-name-parts b)))
    (list (if (buffer-modified? b) (list "●" "warn") "")
          (list (buffer-icon b) "faint")
          (list (string-append (car parts) (cadr parts)) (ibuffer-row-face b)))))

(define (ibuffer-heading-head row)
  (list ""
        (list (ibuffer-chevron row) "dim")
        (list (ibuffer-heading-label row) (or (ibuffer-heading-face row) "accent"))))

(define (ibuffer-compact-cells buf b)
  (if (ibuffer-heading? b)
      (append (ibuffer-heading-head b)
              (list (list (ibuffer-heading-details b (ibuffer-details-column-width buf))
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
              (let ((n (ibuffer-heading-count b)))
                (list (string-append (number->string n)
                                     (if (= n 1) " buffer" " buffers"))
                      "dim"))
              "" ""))
      (append (ibuffer-cell-head b)
        (list (list (ibuffer-human (buffer-size b)) "dim")
              (list (or (buffer-local b 'mode-name) "Fundamental") "faint")
              (list (group-label (buffer-group b))
                    (and (buffer-group b) (group-color-face (buffer-group b))))
              (list (ibuffer-last-label b) "dim")
              (list (if (buffer-path b) "✓" "") "ok")))))

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

(define (ibuffer-dir-overlay buf b off)
  (if (not (buffer-path b))
      '()
      (let* ((parts (ibuffer-row-name-parts b))
             (dir (car parts))
             (cols (list-columns buf))
             (width (and (> (length cols) 2) (list-col-width (nth 2 cols))))
             (fitted (list-fit (string-append dir (cadr parts)) width 'middle))
             (dim (substring fitted 0 (ibuffer-prefix-chars fitted dir)))
             (dot (if (buffer-modified? b) "●" " "))
             (icon (let ((i (buffer-icon b))) (if (equal? i "") " " i)))
             (start (+ off 2
                       (string-byte-length dot) 2
                       (string-byte-length icon) 2)))
        (if (equal? dim "")
            '()
            (list (list start (+ start (string-byte-length dim)) "dim"))))))

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

(define (ibuffer-counts-parts n dirty bytes)
  (list (list (string-append
                (number->string n) (if (= n 1) " buffer" " buffers")
                " · " (number->string dirty) " modified"
                " · " (ibuffer-human bytes))
              "dim")))

;; the wide head says the choices as chips; the compact one says the
;; current ones in four words
(define (ibuffer-wide-meta-line n dirty bytes)
  (ibuffer-join-parts
    (append (ibuffer-counts-parts n dirty bytes)
            (list (list "   " #f))
            (ibuffer-chips "GROUP" '("group" "mode" "directory")
                           (symbol->string (ibuffer-grouping)))
            (list (list "   " #f))
            (ibuffer-chips "SORT" '("name" "recent" "size")
                           (symbol->string (ibuffer-sort))))))

(define (ibuffer-compact-meta-line n dirty bytes)
  (ibuffer-join-parts
    (append (ibuffer-counts-parts n dirty bytes)
            (list (list (string-append " · by " (symbol->string (ibuffer-grouping))
                                       " · " (symbol->string (ibuffer-sort)))
                        "dim")))))

(define (ibuffer-meta-with buf line)
  (let loop ((rows (list-entries buf)) (n 0) (dirty 0) (bytes 0))
    (cond ((null? rows) (line n dirty bytes))
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
                   (+ dirty (if (buffer-modified? b) 1 0))
                   (+ bytes (buffer-size b))))))))

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

;; what `/` reads: the name, the mode, and the path
(define (ibuffer-match? buf row input)
  (if (ibuffer-heading? row)
      (let loop ((ms (ibuffer-heading-members row)))
        (and (pair? ms)
             (or (ibuffer-match? buf (car ms) input) (loop (cdr ms)))))
      (completion-match?
        (string-append row " "
                       (or (buffer-local row 'mode-name) "Fundamental") " "
                       (or (buffer-path row) ""))
        input 'substring)))

(define (ibuffer-refresh!) (list-refresh! *ibuffer-buffer*))
(define (ibuffer-current) (list-current *ibuffer-buffer*))
(define (ibuffer-filter-push! f) (list-filter-push! *ibuffer-buffer* f))

;; the heading of the section the highlight is in: the row itself when it
;; is a heading, else the nearest heading above it
(define (ibuffer-section-at)
  (let ((i (list-clamped-index *ibuffer-buffer*))
        (es (list-entries *ibuffer-buffer*)))
    (and i
         (let loop ((k (min i (- (length es) 1))))
           (cond ((< k 0) #f)
                 ((ibuffer-heading? (nth k es)) (nth k es))
                 (else (loop (- k 1))))))))

(domain! 'buffers)
(effects! '(read))

(define (ibuffer-open! scope)
  (let ((from (active-window)))
    (buffer-create *ibuffer-buffer*)
    (buffer-set-local! *ibuffer-buffer* 'ibuffer-scope scope)
    ;; Typed narrowing is temporary. Keep any mode-specific filters.
    (list-clear-query! *ibuffer-buffer*)
    (display-buffer *ibuffer-buffer*)
    (let ((w (window-showing-other *ibuffer-buffer* from)))
      (if w (select-window! w) (switch-to-buffer! *ibuffer-buffer*)))
    (set-mode! "ibuffer-mode")
    (ibuffer-refresh!)
    (list-goto-first-entry *ibuffer-buffer*)))

(define (ibuffer-open-buffers! buffers)
  (ibuffer-open! (dedupe-names (filter buffer-known? buffers)))
  (list-preview! *ibuffer-buffer*))

(define-command "ibuffer" "List buffers in a traditional management table"
  (lambda () (ibuffer-open! #f)))

(define-command "ibuffer-visit"
  "Visit the selected buffer in another window; on a folded heading, open the section"
  (lambda ()
    (let ((b (ibuffer-current)))
      (cond ((ibuffer-heading? b) (ibuffer-toggle-fold! (ibuffer-heading-key b)))
            ((and (string? b) (buffer-known? b))
             (let ((w (display-buffer-other-window! b)))
               (run-command "quit-window")
               (when (and w (window-exists? w)) (select-window! w))
               (switch-to-buffer! b)))
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

;; Keep the former public helper for callers and historical tests.
(define (ibuffer-preview!)
  (let ((b (ibuffer-current)))
    (when (and (string? b) (buffer-known? b))
      (display-buffer-other-window! b))))

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
(define (ibuffer-group-at)
  (let ((row (ibuffer-current))
        (heading (ibuffer-section-at)))
    (cond ((and (equal? (ibuffer-grouping) 'group) heading)
           (let ((key (ibuffer-heading-key heading)))
             (and (string-prefix? "group:" key)
                  (> (string-length key) 6)
                  (substring key 6 (string-length key)))))
          ((string? row) (buffer-group row))
          (else #f))))

(define-command "ibuffer-group-kill"
  "Kill the group at point: every member, then the group itself"
  (lambda ()
    (let ((g (ibuffer-group-at)))
      (if g
          (begin (group-kill! g)
                 (when (buffer-known? *ibuffer-buffer*) (ibuffer-refresh!)))
          (message "no group here")))))


(effects! '(read))

(mode-icon! "ibuffer-mode" "")

(define-list-mode! "ibuffer-mode"
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
    'rows (lambda (buf) (ibuffer-rows))
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
    'total (lambda (buf) (ibuffer-total))
    'compact #t
    'flags (list (list "d" "D" "kill"
                       (lambda (buf b)
                         (and (string? b)
                              (buffer-known? b)
                              (begin (buffer-kill! b) #t)))))
    'noun "buffer"
    ;; the row under the highlight shows in the window this listing
    ;; covers, and leaves no trace: not a peek, which goes to the popup
    ;; this listing is in
    'preview (lambda (buf b)
               (let ((w (other-window-id (active-window))))
                 (when (and w (string? b) (buffer-known? b))
                   (window-preview-buffer! b w))))
    'keys '(("RET" "ibuffer-visit") ("SPC" "list-toggle-mark")
            ("k" "ibuffer-kill") ("K" "ibuffer-group-kill")
            ("TAB" "ibuffer-toggle-filter-group")
            ("," "ibuffer-toggle-sorting-mode")
            (";" "ibuffer-toggle-grouping")
            ("G" "group-add") ("g" "ibuffer-refresh")
            ("q" "quit-window"))))

(define-key "ctl-x-map" "C-b" "ibuffer")

(category! 'buffers)
(catalog-meta! 'command "ibuffer-kill" 'domain 'buffers 'effects '(destroy))
(catalog-meta! 'command "ibuffer-group-kill" 'domain 'buffers 'effects '(destroy))
(public! 'ibuffer-refresh! "(ibuffer-refresh!) — rebuild the *ibuffer* table")
(public! 'ibuffer-open-buffers! "(ibuffer-open-buffers! BUFFERS) — open ibuffer on exactly these known buffers")
(public! 'ibuffer-set-sort! "(ibuffer-set-sort! MODE) — order the rows of a section by 'name, 'recent, or 'size")
(public! 'ibuffer-set-grouping! "(ibuffer-set-grouping! MODE) — section the table by 'group, 'mode, or 'directory")
(public! 'ibuffer-toggle-fold! "(ibuffer-toggle-fold! KEY) — fold or unfold the section KEY names")
(public! 'ibuffer-age-label "(ibuffer-age-label SECONDS) — \"now\", \"40s\", \"5m\", \"2h\", \"3d\", or \"\" for #f")
