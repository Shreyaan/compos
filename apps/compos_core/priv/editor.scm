;;; editor.scm --- the editor, in Scheme.
;;;
;;; The Elixir core knows nothing about what keys mean or what commands do.
;;; Everything here is userland: redefine any of it from init.scm or M-:.

;;; --- wrapping a function once -----------------------------------------------
;;; The editor wraps a function by defining a wrapper under the wrapped
;;; name, and calling the original under a second name. Scheme must capture
;;; the original ONE time. A whole-file reload evaluates the capturing form
;;; again, and the wrapped name then holds the wrapper: a second capture
;;; points the wrapper at itself, and the next call recurses until the heap
;;; bound stops it. On 2026-09-10 define-command--raw took that path, and
;;; the daemon could define no command again.
;;;
;;; So a capture keeps its first value, the way defvar keeps a variable.
;;;
;;; A wrapped PRIMITIVE needs no capture at all: `Compos.Core.SchemeRawNames`
;;; registers the raw name in Elixir, which also keeps it repairable with
;;; `M-x reload-scheme`. Use alias-once! to wrap a Scheme function, the way
;;; custom.scm wraps load-theme.

(define (alias-once! name target)
  (unless (boundp name) (set-symbol-value! name (symbol-value target)))
  name)

;;; --- package context and the shared catalog ---------------------------------
;;; Scheme's callable globals deliberately stay flat.  These two stamps are
;;; metadata: the loader changes them while evaluating a file so every public
;;; thing can say who owns it and which vocabulary it belongs to.

(define *loading-package* 'editor)
(define *loading-namespace* 'core)
(define *loading-origin* 'bundled)
(define *catalog-domain* 'unknown)
(define *catalog-effects* '(unknown))

(define (package! name &optional namespace)
  (set! *loading-package* name)
  (set! *loading-namespace* (or namespace name))
  (set! *catalog-domain* 'unknown)
  (set! *catalog-effects* '(unknown))
  name)

(define (namespace! name) (set! *loading-namespace* name))
(define (origin! name) (set! *loading-origin* name))
(define (domain! name) (set! *catalog-domain* name))
(define (effects! effects) (set! *catalog-effects* effects))

;; Catalog entries are plists.  KIND says how to use an entry; PACKAGE says
;; who may replace it on reload; NAMESPACE is its stable display vocabulary;
;; DOMAIN is the subject area; EFFECTS say what invoking it may do.
(define *catalog* '())

;; Deriving an index from the catalog costs more than reading it, so a
;; reader caches what it built and checks this counter to know the cache
;; still answers. Every write to *catalog* moves it.
(define *catalog-gen* 0)

(define (catalog-generation) *catalog-gen*)

(define (catalog--touch!) (set! *catalog-gen* (+ *catalog-gen* 1)))

;; One key string per live entry, for the registration fast path. The
;; `member` builtin runs in Elixir, so a fresh load asks "seen before?"
;; without an interpreted scan; only a re-registration pays the rebuild.
;; Load-time registration was O(n^2) in interpreted frames without this —
;; the whole 15s boot.
(define *catalog-keys* '())

(define (catalog--key k n qualified)
  (string-append k ":" (if (equal? k "component") qualified n)))

(define catalog--get plist-get)

(define (catalog--put pl key value)
  (append (list key value)
          (let loop ((xs pl))
            (cond ((null? xs) '())
                  ((null? (cdr xs)) '())
                  ((equal? (car xs) key) (loop (cdr (cdr xs))))
                  (else (cons (car xs) (cons (cadr xs) (loop (cdr (cdr xs))))))))))

(define (catalog--string x)
  (cond ((string? x) x)
        ((symbol? x) (symbol->string x))
        (else (value->string x))))

;; The entry computes these keys, so a copy in meta made the same key
;; appear twice. plist-get reads the first, so the duplicate was invisible
;; to a reader and visible to anything that walks the entry.
(define catalog--computed-keys
  '(kind name qualified-name package namespace origin domain effects
    metadata-source doc))

(define (catalog--strip-computed pl)
  (cond ((or (null? pl) (null? (cdr pl))) '())
        ((member (car pl) catalog--computed-keys)
         (catalog--strip-computed (cdr (cdr pl))))
        (else (cons (car pl)
                    (cons (cadr pl) (catalog--strip-computed (cdr (cdr pl))))))))

(define (catalog-register! kind name doc &rest meta)
  (let* ((n (catalog--string name))
         (k (catalog--string kind))
         (ns (or (catalog--get meta 'namespace) *loading-namespace*))
         (pkg (or (catalog--get meta 'package) *loading-package*))
         (qualified (or (catalog--get meta 'qualified-name)
                        (string-append (catalog--string ns) "/" n)))
         (domain (or (catalog--get meta 'domain) *catalog-domain*))
         (effects (or (catalog--get meta 'effects) *catalog-effects*))
         ;; The source declares the metadata, or the entry says it does not
         ;; know. A guess here becomes a permission input, so there is none.
         (declared? (and (not (equal? domain 'unknown))
                         (not (member 'unknown effects))))
         (entry (append
                  (list 'kind k 'name n
                        'qualified-name qualified 'package (catalog--string pkg)
                        'namespace (catalog--string ns)
                        'origin (catalog--string *loading-origin*)
                        'domain (catalog--string domain)
                        'effects (map catalog--string effects)
                        'metadata-source (if declared? "declared" "unknown")
                        'doc doc)
                  (catalog--strip-computed meta))))
    (let ((key (catalog--key k n qualified)))
      (if (member key *catalog-keys*)
          (set! *catalog*
            (cons entry
                  (remove (lambda (e)
                            (and (equal? (catalog--get e 'kind) k)
                                 (if (equal? k "component")
                                     (equal? (catalog--get e 'qualified-name) qualified)
                                     (equal? (catalog--get e 'name) n))))
                          *catalog*)))
          (begin
            (set! *catalog* (cons entry *catalog*))
            (set! *catalog-keys* (cons key *catalog-keys*)))))
    (catalog--touch!)
    (when (boundp (quote apropos-catalog-changed!))
      (apropos-catalog-changed! entry))
    entry))

(define (catalog) (reverse *catalog*))

(define (catalog-entry kind name)
  (let ((k (catalog--string kind)) (n (catalog--string name)))
    (let loop ((es *catalog*))
    (cond ((null? es) #f)
          ((and (equal? (catalog--get (car es) 'kind) k)
                (if (and (equal? k "component") (string-contains? n "/"))
                    (equal? (catalog--get (car es) 'qualified-name) n)
                    (equal? (catalog--get (car es) 'name) n)))
           (car es))
          (else (loop (cdr es)))))))

(define (catalog--merge entry meta)
  (if (or (null? meta) (null? (cdr meta)))
      entry
      (catalog--merge (catalog--put entry (car meta) (cadr meta))
                      (cdr (cdr meta)))))

;; domain and effects reach an entry as strings, whichever door they come
;; through. A symbol here made the same domain appear twice in a facet list.
(define (catalog--normalise-meta meta)
  (cond ((or (null? meta) (null? (cdr meta))) meta)
        ((equal? (car meta) 'domain)
         (cons 'domain (cons (catalog--string (cadr meta))
                             (catalog--normalise-meta (cdr (cdr meta))))))
        ((equal? (car meta) 'effects)
         (cons 'effects (cons (map catalog--string (cadr meta))
                              (catalog--normalise-meta (cdr (cdr meta))))))
        (else (cons (car meta) (cons (cadr meta)
                                     (catalog--normalise-meta (cdr (cdr meta))))))))

;; An explicit declaration wins over the scope in force. Packages use this for
;; one entry in a mixed section, and the entry then counts as declared.
(define (catalog-meta! kind name &rest meta)
  (let ((old (catalog-entry kind name)))
    (if (not old)
        #f
        (let* ((merged (catalog--merge old (catalog--normalise-meta meta)))
               (updated (catalog--put merged 'metadata-source
                          (if (and (not (equal? (catalog--get merged 'domain) "unknown"))
                                   (not (member "unknown" (catalog--get merged 'effects))))
                              "declared" "unknown"))))
          (set! *catalog*
            (cons updated
                  (remove (lambda (e)
                            (and (equal? (catalog--get e 'kind) (catalog--get old 'kind))
                                 (equal? (catalog--get e 'qualified-name)
                                         (catalog--get old 'qualified-name))))
                          *catalog*)))
          (catalog--touch!)
          (when (boundp (quote apropos-catalog-changed!))
            (apropos-catalog-changed! updated))
          updated))))

;; Commands are an Elixir registry underneath, but this wrapper gives every
;; declaration the same package/domain/effect metadata as Scheme APIs.

;;; --- interactive: how a command gets its arguments ----------------------------
;;; Emacs's (interactive "p"). A command may take arguments; the spec says
;;; where they come from when a key runs it, and command-call passes them
;;; when Scheme does. Codes: 'p the numeric prefix argument; 'P the raw one;
;;; 'r the region start and end, two arguments; 'b the current buffer; 'd
;;; point; 'm the mark or point; a string "sPrompt: " reads a string from
;;; the minibuffer ("n" a number, "f" a file, "b" a buffer name).
;;;
;;;   (define-command "next-line" "Move point down" (interactive 'p)
;;;     (lambda (n) ...))

(define (interactive &rest codes) (cons 'interactive codes))

(define (interactive-spec? x) (and (pair? x) (equal? (car x) 'interactive)))

(define *command-fns* '())              ; ((name spec fn) ...)

(define (interactive--arg code k)
  (cond ((equal? code 'p) (k (prefix-numeric-value (current-prefix-arg))))
        ((equal? code 'P) (k (current-prefix-arg)))
        ((equal? code 'r) (k (list (region-beginning) (region-end))))
        ((equal? code 'b) (k (current-buffer)))
        ((equal? code 'd) (k (point)))
        ((equal? code 'm) (k (or (mark) (point))))
        ((string? code)
         (let ((kind (substring code 0 1))
               (prompt (substring code 1 (string-length code))))
           (cond ((equal? kind "n")
                  (minibuffer-read prompt '()
                    (lambda (v) (k (let ((n (string->number v))) (if (number? n) n 0))))))
                 ((equal? kind "f") (read-file-name prompt k))
                 ((equal? kind "b") (minibuffer-read prompt (buffer-list) k))
                 (else (minibuffer-read prompt '() k)))))
        (else (k #f))))

;; the arguments collect left to right; a prompt is asynchronous, so the
;; rest of the collection is its continuation
(define (interactive--collect codes acc fn)
  (if (null? codes)
      (apply fn (reverse acc))
      (interactive--arg (car codes)
        (lambda (v)
          (interactive--collect (cdr codes)
                                (if (equal? (car codes) 'r)
                                    (append (reverse v) acc)
                                    (cons v acc))
                                fn)))))

(define (call-interactively--spec spec fn)
  (interactive--collect (cdr spec) '() fn))

;; One name per live command, for the registration fast path: a fresh
;; definition asks the `member` builtin and conses; only a redefinition
;; pays the walk that drops the old entry.
(define *command-names* '())

;; (define-command NAME [DOC] [SPEC] FN)
(define (define-command name &rest args)
  (let* ((doc (if (and (pair? args) (string? (car args))) (car args) ""))
         (rest (if (and (pair? args) (string? (car args))) (cdr args) args))
         (spec (and (pair? rest) (interactive-spec? (car rest)) (car rest)))
         (fn (if spec (cadr rest) (car rest)))
         (thunk (if spec (lambda () (call-interactively--spec spec fn)) fn)))
    (set! *command-fns*
      (if (member name *command-names*)
          (cons (list name spec fn)
                (remove (lambda (e) (equal? (car e) name)) *command-fns*))
          (begin
            (set! *command-names* (cons name *command-names*))
            (cons (list name spec fn) *command-fns*))))
    (if (> (string-length doc) 0)
        (define-command--raw name doc thunk)
        (define-command--raw name thunk))
    (catalog-register! 'command name doc
      'use (string-append "(run-command \"" name "\")"))
    name))

;; the function behind a command, and its spec
(define (command-function name)
  (let ((e (assoc name *command-fns*))) (and e (nth 2 e))))

(define (command-interactive-spec name)
  (let ((e (assoc name *command-fns*))) (and e (nth 1 e))))

;; (command-call NAME ARG ...): run the command's function with ARGS. A
;; command with no spec takes none.
(define (command-call name &rest args)
  (let ((fn (command-function name)))
    (cond ((not fn) (run-command name))
          ((command-interactive-spec name) (apply fn args))
          (else (fn)))))

;; Emacs call-interactively: run NAME as a key would
(define (call-interactively name) (run-command name))

(define (undefine-command name)
  (undefine-command--raw name)
  (when (member name *command-names*)
    (set! *command-names* (remove (lambda (n) (equal? n name)) *command-names*))
    (set! *command-fns* (remove (lambda (e) (equal? (car e) name)) *command-fns*)))
  ;; a name the catalog does not hold needs no walk over it
  (let ((key (catalog--key "command" name name)))
    (when (member key *catalog-keys*)
      (set! *catalog-keys* (remove (lambda (k) (equal? k key)) *catalog-keys*))
      (set! *catalog*
        (remove (lambda (entry)
                  (and (equal? (catalog--get entry 'kind) "command")
                       (equal? (catalog--get entry 'name) name)))
                *catalog*))
      (catalog--touch!)
      (when (boundp (quote apropos-catalog-changed!))
        (apropos-catalog-changed! #f))))
  name)

;;; --- public API registry -----------------------------------------------------
;;; The supported surface, curated: name + one-line doc. Everything else in
;;; the global namespace is implementation detail — callable, but private by
;;; convention. The LLM's apropos searches this registry by default, so
;;; the model discovers a documented API instead of hundreds of internals.
;;; Declare yours next to its definition: (public! 'my-fn "what it does").

(define *public-api* '())
(define *public-keys* '())   ; the fast path, as for *catalog-keys*

;;; Every entry is (NAME DOC SIG CATEGORY).
;;;
;;; The signature comes out of the doc, because the house convention
;;; already writes one: "(fn ARGS) — what it does". Ninety-five of these
;;; were written that way before anything parsed them, so public! splits
;;; the string rather than making every caller say it twice. A doc with no
;;; leading form gets "(name)".
;;;
;;; The category comes from (category! 'name), which holds until the next
;;; one — declared once per section instead of once per entry. An agent
;;; asking "what can I do with windows" wants the category, not a regex.

(define *public-category* 'unknown)

(define (category! name)
  (set! *public-category* name)
  (domain! name))

;; the balanced leading form of DOC, and the rest with its dash removed
(define (public--split doc)
  (if (not (string-prefix? "(" doc))
      (list #f doc)
      (let loop ((i 0) (depth 0))
        (cond
          ((>= i (string-byte-length doc)) (list #f doc))
          ((equal? (substring-bytes doc i (+ i 1)) "(") (loop (+ i 1) (+ depth 1)))
          ((equal? (substring-bytes doc i (+ i 1)) ")")
           (if (= depth 1)
               (list (substring-bytes doc 0 (+ i 1))
                     (public--undash
                       (substring-bytes doc (+ i 1) (string-byte-length doc))))
               (loop (+ i 1) (- depth 1))))
          (else (loop (+ i 1) depth))))))

(define (public--undash rest)
  (let ((s (string-trim rest)))
    (cond ((string-prefix? "— " s) (string-trim (substring-bytes s 4 (string-byte-length s))))
          ((string-prefix? "-> " s) (string-trim (substring-bytes s 3 (string-byte-length s))))
          ((string-prefix? "-- " s) (string-trim (substring-bytes s 3 (string-byte-length s))))
          (else s))))

(define (public! name doc &optional category)
  (let* ((n (symbol->string name))
         (parts (public--split doc))
         (sig (or (car parts) (string-append "(" n ")")))
         (text (car (cdr parts))))
    (set! *public-api*
      (if (member n *public-keys*)
          (cons (list n text sig (or category *public-category*))
                (remove (lambda (e) (equal? (car e) n)) *public-api*))
          (begin
            (set! *public-keys* (cons n *public-keys*))
            (cons (list n text sig (or category *public-category*))
                  *public-api*))))
    (catalog-register! 'function n text
      'domain (or category *public-category*) 'signature sig 'use sig)))

(define (public-api) (reverse *public-api*))

(define (public-entry name)
  (let loop ((es *public-api*))
    (cond ((null? es) #f)
          ((equal? (car (car es)) name) (car es))
          (else (loop (cdr es))))))

(define (public-categories)
  (let loop ((es (public-api)) (acc '()))
    (cond ((null? es) (reverse acc))
          ((member (nth 3 (car es)) acc) (loop (cdr es) acc))
          (else (loop (cdr es) (cons (nth 3 (car es)) acc))))))

;;; --- tabulated lists -----------------------------------------------------------
;;; Five buffers are the same buffer: dired, ibuffer, *chats*, mcp-hub and
;;; notmuch. Each had its own marks, its own filter stack, its own
;;; point-preserving refresh, its own n/p remap, and its own copy of
;;; "which entry is on the current line" — six copies of that one, with
;;; three different header-offset conventions between them.
;;;
;;; define-list-mode! owns all of it. A caller says where the rows come
;;; from and how one renders; everything else is the same list behaviour it
;;; was always going to need. It registers a real mode, so a restored list
;;; buffer comes back with its keys and its read-only flag instead of inert
;;; (S8), and the setup fn rebuilds from the buffer-locals like every other
;;; mode.
;;;
;;; A mode can have MANY buffers (dired: one per directory): every
;;; callback gets the buffer first, so rows and header can read the
;;; buffer's own locals. State — entries, marks, filters — is
;;; buffer-local already.
;;;
;;; OPTS is a plist:
;;;   buffer  the fixed buffer name, for one-buffer modes (list-mode-show!)
;;;   rows    (buf) -> entries. Any value; render turns one into a line.
;;;   render  (buf entry) -> one line, no trailing newline
;;;   key     (buf entry) -> a string identity, for marks. Default: the entry.
;;;   header  (buf) -> the header line, no trailing newline
;;;   keys    ((KEY COMMAND) ...)
;;;   remap   ((FROM-COMMAND TO-COMMAND) ...)
;;;   doc     what the list is for — "?" shows it above the key table
;;;   category  the marginalia category the entries belong to, so `/`
;;;             matches the annotation too — see list-match?
;;;   match   (buf entry input) -> #t to keep. What `/` means here.
;;;   filter  (buf entry filter) -> #t to keep. The mode's own filter kinds.
;;;   separator? (buf entry) -> #t for a section heading. Headings are not
;;;              choices. Filtering drops a heading when its section is empty.
;;;   section? (buf entry) -> #t for a row that starts a section. Default:
;;;            separator?. A selectable start (a folded section) stays
;;;            when its section is empty and it matches by itself.
;;;   selection-face  face name for the row at point. Omit it for no highlight.
;;;   fold    (buf) -> fold or unfold the section at point. TAB in a
;;;           prompt standing in front of this list calls it.
;;;   regroup (buf) -> cycle what a section is. M-g in that prompt calls it.

(define *list-modes* '())

(define (list-mode-opts name)
  (let ((e (assoc name *list-modes*)))
    (if e (car (cdr e)) '())))

(define (list-mode-of buf) (buffer-local buf 'list-mode))

(define (list-plist-key? pl key)
  (let loop ((rest pl))
    (cond ((or (null? rest) (null? (cdr rest))) #f)
          ((equal? (car rest) key) #t)
          (else (loop (cdr (cdr rest)))))))

(define (list-layout-bound buf profile key)
  (let ((value (plist-get profile key)))
    (if (procedure? value) (value buf) value)))

;; Where narrow starts is the system's answer, not each view's: every
;; list turns at the same width, so a profile that calls itself narrow or
;; compact declares only WHICH columns survive. An explicit min-cols or
;; max-cols still wins. The headline at the top of a window turns at the
;; same two widths, and a mode there declares only WHICH segments survive.
(define narrow-cols 64)
(define compact-cols 100)

(define (list-layout-named-max profile)
  (let ((name (plist-get profile 'name)))
    (cond ((equal? name 'narrow) (- narrow-cols 1))
          ((equal? name 'compact) (- compact-cols 1))
          (else #f))))

(define (list-layout-match? buf profile width)
  (let ((minimum (list-layout-bound buf profile 'min-cols))
        (maximum (or (list-layout-bound buf profile 'max-cols)
                     (list-layout-named-max profile))))
    (or (plist-get profile 'default)
        (and (or minimum maximum)
             (or (not minimum) (>= width minimum))
             (or (not maximum) (<= width maximum))))))

(define (list-select-layout buf layouts width)
  (let loop ((rest layouts))
    (cond ((null? rest) '())
          ((list-layout-match? buf (car rest) width) (car rest))
          (else (loop (cdr rest))))))

;; Select one responsive profile per draw. Every option read then uses it.
(define (list-active-layout buf)
  (let* ((opts (list-mode-opts (list-mode-of buf)))
         (layouts (or (plist-get opts 'layouts) '()))
         (width (list-view-width buf))
         (cache (buffer-local buf 'list-layout-cache)))
    (if (and (pair? cache) (equal? (car cache) width))
        (cadr cache)
        (let ((profile (list-select-layout buf layouts width)))
          (buffer-set-local! buf 'list-layout-cache (list width profile))
          profile))))

(define (list-opt buf key)
  (let* ((opts (list-mode-opts (list-mode-of buf)))
         (profile (list-active-layout buf)))
    (if (list-plist-key? profile key)
        (plist-get profile key)
        (plist-get opts key))))

;; how many lines of header sit above the first entry — a header may be
;; several lines, and every one of the five had hardcoded its own count
(define (list-header-lines buf)
  (length (list-head-lines buf)))

(define (list-header-text buf)
  (string-join (map car (list-head-lines buf)) "\n"))

;; the 0-based index of the entry line BUF's point is on, or #f above the
;; entries. BUF's own point, not (point): a context provider asks about a
;; list buffer while another buffer is current.
(define (line-index-at buf header-lines)
  (let* ((before (substring-bytes (buffer-text buf) 0 (buffer-point buf)))
         (ln (- (length (string-split before "\n")) 1 header-lines)))
    (and (>= ln 0) ln)))

(define (list-entries buf) (or (buffer-local buf 'list-entries) '()))

(define (list-key buf e)
  (let ((f (list-opt buf 'key)))
    (if f (f buf e) e)))

;; The entry on the current line, or #f when the list has no rows. Point
;; can sit off the rows — a click lands on the header or the key bar, and
;; a mouse click runs no command — so the row at point is the NEAREST
;; row. Every verb reads this one answer, so RET, `k` and a mark all act
;; on the row the highlight then rests on (post-command! moves it there).
(define (list-separator? buf e)
  (let ((f (list-opt buf 'separator?)))
    (and f (f buf e))))

(define (list-selectable? buf e) (not (list-separator? buf e)))

(define (list-current buf)
  (let ((i (list-clamped-index buf))
        (es (list-entries buf)))
    (and i (< i (length es))
         (let ((e (nth i es))) (and (list-selectable? buf e) e)))))

;;; marks — a list of (KEY CHAR), on the list buffer

(define (list-marks buf) (or (buffer-local buf 'list-marks) '()))

(define (list-mark-of buf e &optional ctx)
  (let* ((key (if ctx
                  (let ((f (list-ctx-key ctx))) (if f (f buf e) e))
                  (list-key buf e)))
         (m (assoc key (if ctx (list-ctx-marks ctx) (list-marks buf)))))
    (if m (car (cdr m)) " ")))

(define (list-mark! buf e ch)
  (let* ((k (list-key buf e))
         (rest (filter (lambda (m) (not (equal? (car m) k))) (list-marks buf))))
    (buffer-set-local! buf 'list-marks (if ch (cons (list k ch) rest) rest))))

(define (list-marked buf ch)
  (map car (filter (lambda (m) (equal? (car (cdr m)) ch)) (list-marks buf))))

(define (list-clear-marks! buf) (buffer-set-local! buf 'list-marks '()))

;; unmark by the stored KEY — the execute loop holds keys, not entries,
;; and list-mark! would run the mode's 'key fn on one
(define (list-unmark-key! buf k)
  (buffer-set-local! buf 'list-marks
    (filter (lambda (m) (not (equal? (car m) k))) (list-marks buf))))

;;; --- flag, then execute ------------------------------------------------------
;;; The dired paradigm, in the mechanism. A list declares what its flags DO:
;;;
;;;   'flags ((KEY CHAR VERB ACTION CONFIRM?) ...)
;;;
;;; KEY flags the entry at point with CHAR. `x` runs every flagged entry
;;; through (ACTION LIST-BUFFER KEY) — the entry's 'key identity, which IS
;;; the entry for a list without a 'key fn. The action answers #t when it
;;; acted and #f when it found nothing to do; `x` reports "VERB N NOUN". CONFIRM?
;;; asks first. The mechanism supplies the rest: SPC marks, `u` unmarks,
;;; `U` drops every mark, and the mark column goes in front of every row.
;;;
;;; Three lists had written their own copy of this and the copies had
;;; drifted: one asked before it acted, one moved point after marking, one
;;; killed a runtime the moment you pressed the key. A list now says only
;;; what its flags mean.

(define *list-mark-char* "*")

(define (list-flags buf) (or (list-opt buf 'flags) '()))

;; a list may refuse to mark some rows (dired: "..")
(define (list-markable? buf e)
  (let ((f (list-opt buf 'markable?)))
    (and (list-selectable? buf e) (if f (f buf e) #t))))

;; a mark needs a column to show in. A list with flags has always had
;; one; a list with columns gets one too, because marking is what every
;; one of them does.
(define (list-marks-column? buf)
  (or (pair? (list-flags buf)) (list-table? buf)))

(define (list-mark-at-point! ch)
  (let* ((buf (current-buffer))
         (e (list-current buf))
         (i (list-index buf)))
    (if (not (and e (list-markable? buf e)))
        (message "no entry on this line")
        ;; a mark changes no row — redraw what the list has; a refresh
        ;; would call the source (the network, for sentry) per keypress
        (begin (list-mark! buf e ch)
               (list-redraw! buf)
               (list-goto-index! buf (+ (or i 0) 1))))))

;; a mark is only as real as the row it sits on. Marks persist with the
;; buffer (durable lifecycle), so after a restart they can name rows the
;; list no longer shows — a verb must act on what the reader SEES.
(define (list-live-marked buf ch)
  ;; A local filter hides source rows; it does not delete them. Keep marks
  ;; valid against the full source so narrowing can build one transaction.
  (let* ((entries (if (list-opt buf 'local-filter)
                      (list-source-entries buf)
                      (list-entries buf)))
         (keys (map (lambda (e) (list-key buf e)) entries)))
    (filter (lambda (k) (member k keys)) (list-marked buf ch))))

(define (list-targets buf)
  ;; Marked actions in a local-filter list use the full source. This lets
  ;; the user mark one row, narrow to another, and act on both together.
  (let* ((m (list-live-marked buf *list-mark-char*))
         (entries (if (list-opt buf 'local-filter)
                      (list-source-entries buf)
                      (list-entries buf))))
    (if (pair? m)
        (filter (lambda (e) (member (list-key buf e) m)) entries)
        (let ((e (list-current buf))) (if e (list e) '())))))
;; This is what makes one key work on one chat and on twelve. ENTRIES,
;; not keys, in both cases: a list whose rows are plists (sentry) marks
;; by key but acts on the row itself.

(define-command "list-mark" "Mark the entry at point"
  (lambda () (list-mark-at-point! *list-mark-char*)))

(define-command "list-unmark" "Unmark the entry at point"
  (lambda () (list-mark-at-point! #f)))

;; one key that marks and unmarks: a marked or flagged row loses its
;; mark, any other row gets one
(define-command "list-toggle-mark" "Mark the entry at point, or unmark a marked one"
  (lambda ()
    (let* ((buf (current-buffer))
           (e (list-current buf)))
      (list-mark-at-point!
        (if (and e (not (equal? (list-mark-of buf e) " "))) #f *list-mark-char*)))))

(define-command "list-unmark-all" "Drop every mark and flag in this list"
  (lambda ()
    (let ((buf (current-buffer)))
      (list-clear-marks! buf)
      (list-redraw! buf))))

;; `*` marks the whole list — the rows you narrowed to, because a filter
;; and a mark say the same thing: these ones
(domain! 'interaction)
(effects! '(write))

(define-command "list-mark-all" "Mark every row this list shows; again unmarks them"
  (lambda ()
    (let* ((buf (current-buffer))
           (i (list-index buf))
           (markable (filter (lambda (e) (list-markable? buf e))
                             (list-entries buf)))
           ;; a second `*` reads as "never mind": every shown row already
           ;; marked means unmark them all
           (all-marked?
             (and (pair? markable)
                  (let loop ((es markable))
                    (cond ((null? es) #t)
                          ((equal? (list-mark-of buf (car es)) *list-mark-char*)
                           (loop (cdr es)))
                          (else #f))))))
      (for-each (lambda (e)
                  (list-mark! buf e (if all-marked? #f *list-mark-char*)))
                markable)
      (list-redraw! buf)
      (when i (list-goto-index! buf i)))))

(domain! 'unknown)
(effects! '(unknown))

;; a keymap binds a command NAME, so each flag char needs a command of its
;; own. The body is the same in every list, so one command per char serves
;; all of them.
(define (list-flag-command ch)
  (let ((name (string-append "list-flag-" ch)))
    (define-command name (string-append "Flag the entry at point with " ch)
      (lambda () (list-mark-at-point! ch)))
    name))

;; Every flag that has something flagged, in the order the list declared
;; — and the marked rows go with the FIRST flag. `*` and `m` say WHICH
;; rows; the flag says WHAT to do. A list with one flag needs no second
;; key for it: mark the rows and press `x`. A flagged row keeps its own
;; flag, because a row carries one mark and the two sets cannot overlap.
(define (list-execute-plan buf)
  (let loop ((fs (list-flags buf))
             (marked (list-live-marked buf *list-mark-char*))
             (out '()))
    (if (null? fs)
        (reverse out)
        (let ((rows (append (list-live-marked buf (car (cdr (car fs)))) marked)))
          (loop (cdr fs) '()
                (if (null? rows) out (cons (list (car fs) rows) out)))))))

;; what one row IS, for the prompts: "delete 2 files" reads like a question
;; a person asks. A list that declares no noun gets "row".
(define (list-noun buf n)
  (let ((w (or (list-opt buf 'noun) "row")))
    (if (= n 1) w (string-append w "s"))))

(define (list-plan-label buf plan)
  (string-join (map (lambda (p)
                      (let ((n (length (car (cdr p)))))
                        (string-append (nth 2 (car p)) " "
                                       (number->string n) " "
                                       (list-noun buf n))))
                    plan)
               " · "))

(define (list-plan-asks? plan)
  (let loop ((ps plan))
    (cond ((null? ps) #f)
          ((and (> (length (car (car ps))) 4) (nth 4 (car (car ps)))) #t)
          (else (loop (cdr ps))))))

;; Clear the flag BEFORE the action runs: an action may kill the entry, and
;; a mark on a row that no longer exists outlives every refresh. The report
;; counts what the actions DID — an action answers #f when it found nothing
;; to do, so "kill runtime 0 chats" is a sentence this can say.
(define (list-plan-run! buf plan)
  (let loop ((ps plan) (parts '()))
    (if (null? ps)
        (begin (list-refresh! buf)
               (message (string-join (reverse parts) " · ")))
        (let* ((spec (car (car ps)))
               (action (nth 3 spec))
               (n (let inner ((es (car (cdr (car ps)))) (k 0))
                    (cond ((null? es) k)
                          (else (list-unmark-key! buf (car es))
                                (inner (cdr es)
                                       (if (action buf (car es)) (+ k 1) k)))))))
          (loop (cdr ps)
                (cons (string-append (nth 2 spec) " " (number->string n) " "
                                     (list-noun buf n))
                      parts))))))

(define-command "list-execute" "Run the flags in this list"
  (lambda ()
    (let* ((buf (current-buffer))
           (plan (list-execute-plan buf)))
      (cond ((null? plan) (message "nothing marked"))
            ((list-plan-asks? plan)
             (minibuffer-read (string-append (list-plan-label buf plan) "? ")
                              (list "yes" "no")
                              (lambda (ans)
                                (if (equal? ans "yes")
                                    (list-plan-run! buf plan)
                                    (message "Cancelled")))))
            (else (list-plan-run! buf plan))))))

;; the marking keys. Every list that shows a mark column marks the same
;; way — SPC marks (m as well), `u`, `U` and `*` — and a list that declares flags also gets
;; the flag chars and `x`. They go in before the list's own keys, so a
;; list can still claim any of them for something else.
;; Every list answers the same keys, from one map every list mode's map
;; falls back to: help, the filter, the row motion, the marks, and
;; execute. A list mode's own keys shadow them, because its map is the
;; child. The flag keys a list declares go on its own map when it is
;; defined (define-list-mode!); a layout profile that brings flags of
;; its own binds them on the buffer, since the profile is buffer state.
(define-keymap! "list-mode-map")
(for-each (lambda (p) (define-key "list-mode-map" (car p) (cadr p)))
  '(("?" "describe-mode")
    ("/" "list-filter") ("\\" "list-filter-pop")
    ("n" "list-next") ("p" "list-prev")
    ("SPC" "list-mark") ("m" "list-mark")
    ("u" "list-unmark") ("U" "list-unmark-all") ("*" "list-mark-all")
    ("x" "list-execute") ("g" "list-revert")))

;; the flag keys of one list: (KEY FLAG-CHAR ...) rows become bindings
;; on MAP, buffer or mode
(define (list-flag-keys! bind fs)
  (for-each (lambda (f) (bind (car f) (list-flag-command (car (cdr f))))) fs))

;; a profile's own flags, beyond the mode's, go on the buffer
(define (list-install-mark-keys! buf)
  (let ((fs (or (list-opt buf 'flags) '()))
        (declared (or (plist-get (list-mode-opts (list-mode-of buf)) 'flags) '())))
    (unless (equal? fs declared)
      (list-flag-keys! (lambda (k c) (local-set-key* buf k c)) fs))))

;;; filters — a stack of (LABEL ARG), newest first

(define (list-filters buf) (or (buffer-local buf 'list-filters) '()))

(define (list-filter-push! buf f)
  (buffer-set-local! buf 'list-filters (cons f (list-filters buf)))
  (list-redraw! buf))

;; The query is ONE filter, not a stack of them: the text you type IS
;; the narrowing, so deleting it widens and emptying it removes it.
;; A mode's own filter (dired's dotfiles) is a different kind and keeps
;; its place in the stack.
(define (list-query buf)
  (let ((f (assoc "match" (list-filters buf))))
    (if f (car (cdr f)) "")))

(define (list-set-query! buf q)
  (let ((rest (filter (lambda (f) (not (equal? (car f) "match")))
                      (list-filters buf))))
    (buffer-set-local! buf 'list-filters
      (if (equal? q "") rest (cons (list "match" q) rest)))
    (list-redraw! buf)))

;; drop the typed query and keep the mode's own kinds (dired's dotfiles).
;; No refresh: the caller is opening the list and draws it next.
(define (list-clear-query! buf)
  (let* ((before (list-filters buf))
         (rest (filter (lambda (f) (not (equal? (car f) "match"))) before)))
    (buffer-set-local! buf 'list-filters rest)
    ;; #t when it dropped a query, so the caller knows the rows in the
    ;; buffer are narrower than the list now holds
    (not (= (length before) (length rest)))))

(define (list-filter-pop! buf)
  (let ((fs (list-filters buf)))
    (unless (null? fs) (buffer-set-local! buf 'list-filters (cdr fs)))
    (list-redraw! buf)))

(define (list-filter-clear! buf)
  (buffer-set-local! buf 'list-filters '())
  (list-redraw! buf))

;; what you typed reads back as you typed it; a kind the mode invented
;; says its name
(define (list-filters-label buf)
  (if (null? (list-filters buf))
      ""
      (string-append "   ·  " (list-filters-text buf))))

;;; --- `/` narrows --------------------------------------------------------------
;;; One filter, for every list. You press `/` and type; the list narrows
;;; on every keystroke to the rows that match. The arrows move the rows
;;; while you type, so you type and then you select. RET keeps the
;;; narrowing and the row you chose, C-g drops the narrowing, `/` again
;;; narrows the narrowing — the filters stack, and the stack persists with
;;; the buffer. `\` widens by one.
;;;
;;; A row matches on everything you can SEE: its line, and the marginalia
;;; the prompts show beside the same thing (the mode names the category).
;;; So dired finds `elixir-mode` and ibuffer finds a group, and neither
;;; needs a filter of its own. The zoo this replaces — one command and one
;;; chord per field, name, extension, type, mode — asked you to say which
;;; field before you said what you wanted.
;;;
;;; A mode that knows better declares 'match (buf entry input) -> #t.

(define (list-annotation-fields buf e)
  (let* ((cat (list-opt buf 'category))
         (f (and cat (marginalia-for cat))))
    (if f (map string-trim (marginalia-row f e)) '())))

(define (list-annotation buf e)
  (string-join (list-annotation-fields buf e) " "))

;; the whole row as text: the lines you see, and what they mean. A table
;; row matches on its columns, because its columns are what it shows, and
;; a row of two lines matches on both of them.
(define (list-row-text buf e &optional ctx)
  (string-append (string-join (map car (list-row-lines buf e ctx)) " ")
                 " " (list-annotation buf e)))

;; a list narrows the way a prompt does: one matcher, case-insensitive,
;; every term a substring of the row, and a "(" in the input is a
;; character, not half of a regexp
(define (list-match? buf e input &optional ctx)
  (let ((m (list-opt buf 'match)))
    (if m (m buf e input) (completion-match? (list-row-text buf e ctx) input 'substring))))

;; every list gets the "match" kind; the mode's own 'filter fn reads the
;; kinds it invented. A list with neither keeps every row.
(define (list-filter-match? buf e f &optional ctx)
  (if (equal? (car f) "match")
      (list-match? buf e (car (cdr f)) ctx)
      (let ((m (list-opt buf 'filter)))
        (if m (m buf e f) #t))))

;; the rows that survive the stack — the loop each list wrote by hand.
;; The filters and the row context are read once, not once per row.
(define (list-entry-kept? buf e filters ctx)
  (let loop ((fs filters))
    (cond ((null? fs) #t)
          ((list-filter-match? buf e (car fs) ctx) (loop (cdr fs)))
          (else #f))))

;; Split at heading rows before filtering. A heading owns every row up to the
;; next heading. It stays only when at least one row in its section stays.
(define (list-keep-section-emit buf heading rows filters ctx out)
  (let ((kept (filter (lambda (e) (list-entry-kept? buf e filters ctx))
                      (reverse rows))))
    (cond ((pair? kept)
           (append out (if heading (cons heading kept) kept)))
          ;; a heading that is a row of its own (a folded section) stays
          ;; when it matches by itself
          ((and heading
                (list-selectable? buf heading)
                (list-entry-kept? buf heading filters ctx))
           (append out (list heading)))
          (else out))))

;; a row that starts a section: a heading, or a folded section standing
;; as one selectable row. The mode's 'section? says which; without it,
;; the separators are the only starts.
(define (list-section-start? buf e)
  (let ((f (list-opt buf 'section?)))
    (if f (f buf e) (list-separator? buf e))))

(define (list-keep-sections buf entries filters ctx)
  (let walk ((rest entries) (heading #f) (rows '()) (out '()))
    (cond ((null? rest)
           (list-keep-section-emit buf heading rows filters ctx out))
          ((list-section-start? buf (car rest))
           (walk (cdr rest) (car rest) '()
                 (list-keep-section-emit buf heading rows filters ctx out)))
          (else (walk (cdr rest) heading (cons (car rest) rows) out)))))

(define (list-keep buf entries)
  (let ((filters (list-filters buf)))
    (let ((ctx (list-row-ctx buf)))
      (if (list-opt buf 'separator?)
          (list-keep-sections buf entries filters ctx)
          (if (null? filters)
              entries
              (filter (lambda (e) (list-entry-kept? buf e filters ctx))
                      entries))))))

;; A list that declares 'local-filter fetches its source once and runs
;; the filters on the cache: a keystroke in `/` must not call the source
;; again. A plain list computes its rows on every draw.
(define (list-source-entries buf)
  (or (buffer-local buf 'list-source-entries) '()))

(define (list-render-rows! buf fetch)
  (if (list-opt buf 'local-filter)
      (begin
        (when (or (equal? fetch #t)
                  (not (buffer-local buf 'list-source-entries)))
          (buffer-set-local! buf 'list-source-entries
                             ((list-opt buf 'rows) buf)))
        (list-keep buf (list-source-entries buf)))
      ;; 'cached is the wake path: the rows already in 'list-entries ARE
      ;; the view, and calling the source again would pay its cost (the
      ;; network, for sentry) inside a switcher preview. A filter redraw
      ;; still passes #f and reaches the source, which reads the query.
      (if (and (equal? fetch 'cached)
               (pair? (buffer-local buf 'list-entries)))
          (list-entries buf)
          ((list-opt buf 'rows) buf))))

;;; --- the view: a title, columns, rows, a key bar ------------------------------
;;; Every list draws the same shape. A mode says what its columns are and
;;; what one row puts in them; the mechanism pads the cells, colours them,
;;; writes the column labels, shows the narrowing you typed and prints the
;;; key bar. Three lists had each written their own padding and their own
;;; header string, and the three had drifted apart.
;;;
;;;   'title    (buf) -> string             what this list shows
;;;   'meta     (buf) -> string             the counts under the title,
;;;                      or (TEXT SPANS) with its own (OFFSET LENGTH FACE) spans
;;;   'total    (buf) -> number             rows before the filters, for the chip
;;;   'columns  (buf) -> ((LABEL WIDTH ALIGN TRIM) ...)
;;;                      WIDTH #f means the rest of the line.
;;;                      ALIGN is 'left or 'right.
;;;                      TRIM is 'middle (the default), 'end, or a
;;;                      (TEXT WIDTH) -> TEXT fn of the mode's own.
;;;   'cells    (buf entry) -> (CELL ...)   CELL is a string, or (TEXT FACE)
;;;
;;; A row may take more than one line. Such a mode declares the two in
;;; the plural — one column list and one cell list per line of a row:
;;;
;;;   'row-columns (buf) -> (COLUMNS ...)
;;;   'row-cells   (buf entry) -> (CELLS ...)
;;;   'collection semantic collection tag; 'composml (buf entry) -> block
;;;              Optional semantic row projection; keys must be strings.
;;;   'composml-head (buf head) -> (BLOCK ...)
;;;              Optional head of that projection. The default draws the
;;;              head's own lines as text; a mode answering this draws it
;;;              as blocks, so a tab bar can be tabs.
;;;
;;; The mark goes on the first line and the lines under it start where it
;;; does. A two-line row has no single label row, so the head shows none.
;;;   'footer   (buf) -> ((KEY WORD) ...)   the key bar under the rows
;;;   'preview  (buf entry)                 what moving the highlight shows
;;;   'compact  #t                          merge title and meta; omit rules
;;;   'layouts  ordered profile plists. A profile can override view options.
;;;             min-cols and max-cols select by measured text width.
;;;             A final (default #t ...) profile supplies the fallback.
;;;
;;; A list whose rows come from a slow source (the network) declares the
;;; source through the buffer cache instead of 'rows doing the fetch:
;;;   'cache-fetch (buf k)                  fetch off the UI lane, call (k ROWS);
;;;                                         (k #f) on failure keeps the old rows
;;;   'cache-ttl   SECONDS                  wake refreshes only past this age;
;;;                                         #f fetches only on explicit refresh
;;; 'rows then serves (list-entries buf) — the cache IS the source of the
;;; view — and the mode's `g` calls cache-refresh! instead of list-refresh!.
;;;
;;; A mode that declares 'columns gets the mark column, the m/u/U/* keys
;;; and the clamped n/p for free. A mode that declares 'header and 'render
;;; keeps the plain lines it always had.

(define *list-gap* "  ")

;; the window the list is in, in characters. The client measures its own
;; font and reports it; a list nobody is showing lays out for the active
;; window, and one nobody has measured gets the default. The last column
;; keeps one character clear of the edge, so nothing wraps.
(define (list-view-width buf)
  (max 40 (- (buffer-cols buf) 1)))

;; the column that declares no width takes whatever the others leave, so
;; the table fills the window instead of stopping short of it
(define (list-fit-columns cols w)
  (let* ((fixed (fold (lambda (acc c) (+ acc 2 (or (list-col-width c) 0))) 2 cols))
         (rest (max 8 (- w fixed))))
    (map (lambda (c)
           (if (list-col-width c)
               c
               (list (car c) rest (list-col-align c) (list-col-trim c))))
         cols)))

;; a mode says its columns once per line of a row. A one-line list says
;; 'columns and means one line; a two-line list says 'row-columns.
(define (list-declared-columns buf)
  (let ((g (list-opt buf 'row-columns))
        (f (list-opt buf 'columns)))
    (cond (g (g buf))
          (f (list (f buf)))
          (else '()))))

;; The mode's columns fn runs once per draw: every later call in the
;; same draw reads the cache. The cache keys on the width, so a resize
;; recomputes. A draw clears the cache first.
;;; The column layout is a cache, not state the frame shows. A buffer
;;; local is a change, and a change is a frame refresh and a render, so
;;; a draw that laid its columns out again refreshed every frame twice
;;; for a table nobody could see change. The cache lives here instead,
;;; one entry per list buffer, keyed by the width it was laid out for.
(define *list-columns-cache* '())

(define (list-columns-forget! buf)
  (set! *list-columns-cache*
        (filter (lambda (e) (not (equal? (car e) buf))) *list-columns-cache*)))

(define (list-column-lines buf)
  (let* ((w (list-view-width buf))
         (cache (assoc buf *list-columns-cache*)))
    (if (and cache (equal? (cadr cache) w))
        (nth 2 cache)
        (let ((cols (map (lambda (cs) (list-fit-columns cs w))
                         (list-declared-columns buf))))
          (list-columns-forget! buf)
          (set! *list-columns-cache*
                (cons (list buf w cols) *list-columns-cache*))
          cols))))

;; the first line's columns — the label row and every caller that means
;; "the columns" reads these
(define (list-columns buf)
  (let ((ls (list-column-lines buf)))
    (if (pair? ls) (car ls) '())))

;; how many lines one row takes. A render reads the mode; motion reads
;; what the last render wrote, so a mode that changed under a stale
;; buffer never moves point to a line that is not there.
(define (list-row-height buf) (max 1 (length (list-column-lines buf))))

(define (list-drawn-row-height buf)
  (or (buffer-local buf 'list-row-height) 1))

(define (list-table? buf) (pair? (list-columns buf)))

;; a mode answers with a string, or does not answer at all
(define (list-say buf key)
  (let ((f (list-opt buf key)))
    (if f (or (f buf) "") "")))

(define (list-cell-text c) (if (pair? c) (car c) c))
(define (list-cell-face c) (if (pair? c) (car (cdr c)) #f))

;; a name too long for its column loses its MIDDLE: the head says what
;; the thing is and the tail says which one, and a path or a suffix lives
;; in the tail. The columns after it stay where the labels say they are.
;;
;; A column whose tail says nothing declares 'end instead, and loses the
;; end: a subject and a tag list both read from the left, and a middle
;; cut through a list of words invents a word that is not there.
(define (list-fit s w trim)
  (cond ((not w) s)
        ((<= (string-length s) w) s)
        ((<= w 3) (substring s 0 w))
        ;; a column that knows what its text IS shortens it itself: the
        ;; tags of a mail thread are words, and every word can lose its
        ;; end and still say which tag it is. The mechanism holds the
        ;; column to its width after the mode had its say.
        ((procedure? trim)
         (let ((out (trim s w)))
           (if (> (string-length out) w) (substring out 0 w) out)))
        ((equal? trim 'end) (string-append (substring s 0 (- w 1)) "…"))
        (else
          (let* ((keep (- w 1))
                 (head (quotient (+ keep 1) 2))
                 (tail (- keep head))
                 (n (string-length s)))
            (string-append (substring s 0 head) "…" (substring s (- n tail) n))))))

;; the padding of the last column is only blank space at the end of a line
(define (string-trim-right s)
  (let loop ((n (string-length s)))
    (if (and (> n 0) (equal? (substring s (- n 1) n) " "))
        (loop (- n 1))
        (substring s 0 n))))

(define (list-pad s w align)
  (cond ((not w) s)
        ((equal? align 'right) (string-pad-left s w))
        (else (string-pad-right s w))))

(define (list-col-width c) (car (cdr c)))
(define (list-col-align c) (if (> (length c) 2) (nth 2 c) 'left))

;; how the column gives up space: 'middle (the default), 'end, or a fn
;; the mode wrote
(define (list-col-trim c) (if (> (length c) 3) (nth 3 c) 'middle))

;; how wide the table is: the rule and the right-hand chip measure
;; themselves against it, so nothing has to ask the window
;; one row of cells as text plus the faces on it. A span is (OFFSET
;; LENGTH FACE) inside the line, in bytes, so the writer below is the
;; only place that counts absolute offsets.
(define (list-lay-out cells cols &optional fields?)
  (let loop ((cs cells) (ks cols) (text "") (spans '()) (fields '()))
    (if (or (null? cs) (null? ks))
        (if fields? (list text (reverse spans) (reverse fields))
                    (list text (reverse spans)))
        (let* ((k (car ks))
               (fitted (list-fit (list-cell-text (car cs)) (list-col-width k)
                                 (list-col-trim k)))
               ;; the last column is not padded, so the line ends where
               ;; its text ends; a right-aligned last column pads on the
               ;; left, so its text ends at the column's edge
               (align (list-col-align k))
               (padded (if (and (null? (cdr ks)) (not (equal? align 'right)))
                           fitted
                           (list-pad fitted (list-col-width k) align)))
               (face (list-cell-face (car cs)))
               ;; a right-aligned cell's text sits after its padding
               (start (+ (string-byte-length text)
                         (if (equal? align 'right)
                             (- (string-byte-length padded) (string-byte-length fitted))
                             0))))
          (loop (cdr cs) (cdr ks)
                (string-append text padded
                               (if (null? (cdr ks)) "" *list-gap*))
                (if face
                    (cons (list start (string-byte-length fitted) face) spans)
                    spans)
                (if fields? (cons (list start (string-byte-length fitted)) fields) fields))))))

(define (list-shift-spans spans n)
  (map (lambda (s) (list (+ (car s) n) (car (cdr s)) (nth 2 s))) spans))

(define (list-rule-line w) (list (string-repeat "─" w) (list (list 0 (* 3 w) "faint"))))

;; the narrowing, on the right of the title: what you typed and how many
;; rows it left. It shows only while the list is narrowed.
;; how many things this list is showing. A row you cannot mark is not a
;; thing the list holds — dired's ".." is a way out of the directory.
(define (list-count buf)
  (let ((f (list-opt buf 'markable?))
        (separator? (list-opt buf 'separator?))
        (es (list-entries buf)))
    (if (or f separator?)
        (length (filter (lambda (e) (list-markable? buf e)) es))
        (length es))))

;; the chip counts only while the list is narrowed: the count asks the
;; mode about every row, and a wide list of 400 rows paid 200ms per draw
;; to show nothing
(define (list-chip buf)
  (let ((fs (list-filters buf)))
    (if (null? fs)
        ""
        (let* ((n (list-count buf))
               (tf (list-opt buf 'total))
               (total (if tf (tf buf) n)))
          (string-append (list-filters-text buf) "   "
                         (number->string n) " of " (number->string total))))))

;; what you typed reads back as you typed it; a kind the mode invented
;; says its name
(define (list-filters-text buf)
  (string-join (map (lambda (f)
                      (if (equal? (car f) "match")
                          (string-append "/" (car (cdr f)))
                          (string-append (car f) ":" (car (cdr f)))))
                    (reverse (list-filters buf)))
               " "))

(define (list-title-line buf w)
  (let* ((title (list-say buf 'title))
         (chip (list-chip buf)))
    (if (equal? chip "")
        (list title '())
        (let* ((gap (max 1 (- w (string-length title) (string-length chip))))
               (text (string-append title (string-repeat " " gap) chip)))
          ;; the chip shows only while the list is narrowed, and it wears
          ;; the same colour as the note under it: one colour says "you
          ;; are not seeing everything"
          (list text
                (list (list (- (string-byte-length text) (string-byte-length chip))
                            (string-byte-length chip) "warn")))))))

(define (list-label-line buf cols)
  (let* ((labels (map (lambda (c) (list (string-upcase (car c)) "faint")) cols))
         (laid (list-lay-out labels cols)))
    (list (string-trim-right (string-append "  " (car laid)))
          (list-shift-spans (car (cdr laid)) 2))))

;; A narrowed list looks exactly like a short list, and the mode's own
;; meta counts the rows it can see — "2 buffers" when the editor holds
;; fourteen. So the narrowing says itself here, in the sentence under the
;; title, and it says how to leave.
(define (list-meta-line buf)
  (let* ((said (list-say buf 'meta))
         ;; a mode's meta is a string, or the text and its own spans
         (meta (if (pair? said) (car said) said))
         (own-spans (if (pair? said) (cadr said) #f))
         (meta (if (list-more? buf)
                   (string-append meta (if (equal? meta "") "" " · ")
                                  (number->string (list-shown-count buf)) " of "
                                  (number->string (length (list-entries buf)))
                                  " shown, PgDn draws more")
                   meta))
         (note (if (null? (list-filters buf))
                   ""
                   (string-append "narrowed to " (list-filters-text buf)
                                  " — \\ widens")))
         (text (cond ((equal? note "") meta)
                     ((equal? meta "") note)
                     (else (string-append meta "   ·   " note)))))
    (list text
          (append (cond ((equal? meta "") '())
                        (own-spans own-spans)
                        (else (list (list 0 (string-byte-length meta) "dim"))))
                  (if (equal? note "")
                      '()
                      (list (list (- (string-byte-length text)
                                     (string-byte-length note))
                                  (string-byte-length note) "warn")))))))

;; one label per column says nothing about a row of two lines: the row
;; itself is the only place the two meet, so a two-line list shows none
;; A list that names none of its columns shows no label row: the row
;; itself says what it is, and a bar of blanks is one more line of chrome
;; over the rows.
(define (list-labelled? cols)
  (pair? (filter (lambda (c) (not (equal? (car c) ""))) cols)))

(define (list-label-lines buf cols)
  (if (or (> (list-row-height buf) 1) (not (list-labelled? cols)))
      '()
      (list (list-label-line buf cols))))

;; the key bar, as header lines: the mode's 'footer keys, under the counts
(define (list-key-lines buf)
  (let* ((f (list-opt buf 'footer))
         (keys (if f (f buf) '())))
    (if (null? keys) '() (list (list-key-bar buf keys)))))

(define (list-table-head buf)
  (let* ((cols (list-columns buf))
         (w (list-view-width buf))
         (meta (list-meta-line buf)))
    (if (list-opt buf 'compact)
        (if (and (null? (list-filters buf))
                 (not (equal? (car meta) "")))
            ;; the meta's spans ride along, shifted past the title;
            ;; a line the width trimmed loses them, as the offsets moved
            (append (let* ((title (list-say buf 'title))
                           (text (string-append title "  " (car meta)))
                           (fitted (list-fit text w 'middle)))
                      (list (list fitted
                                  (if (equal? fitted text)
                                      (list-shift-spans (cadr meta)
                                                        (+ (string-byte-length title) 2))
                                      '()))))
                    (list-key-lines buf)
                    (list-label-lines buf cols))
            (append (list (list-title-line buf w))
                    (if (equal? (car meta) "") '() (list meta))
                    (list-key-lines buf)
                    (list-label-lines buf cols)))
        (append (list (list-title-line buf w))
                (if (equal? (car meta) "") '() (list meta))
                (list-key-lines buf)
                (list (list-rule-line w))
                (list-label-lines buf cols)))))

;; the header as lines. A mode's own 'header is text it wrote itself, so
;; its lines carry no faces.
(define (list-head-lines buf)
  (let ((f (list-opt buf 'header)))
    (cond (f (map (lambda (l) (list l '())) (string-split (f buf) "\n")))
          ((list-table? buf) (list-table-head buf))
          (else (list (list "" '()))))))

;; the key bar: what this list does, in the words the mode chose
(define (list-key-bar-text keys)
  (let loop ((ks keys) (text " ") (spans '()))
    (if (null? ks)
        (list text (reverse spans))
        (let* ((key (car (car ks)))
               (word (car (cdr (car ks))))
               (at (string-byte-length text))
               (piece (string-append key " " word)))
          (loop (cdr ks)
                (string-append text piece (if (null? (cdr ks)) "" " · "))
                (cons (list (+ at (string-byte-length key) 1)
                            (string-byte-length word) "dim")
                      (cons (list at (string-byte-length key) "accent") spans)))))))

;; the bar fits the window: a key that does not fit is dropped from the
;; end, and a bar that dropped any ends in "? keys", where ? shows them
;; all. A bar that wrapped took two lines and pushed the rows down.
(define (list-key-bar buf keys)
  (let ((w (list-view-width buf))
        (full (list-key-bar-text keys)))
    (if (<= (string-length (car full)) w)
        full
        (let loop ((ks keys))
          (let ((bar (list-key-bar-text (append ks '(("?" "keys"))))))
            (if (or (null? ks) (<= (string-length (car bar)) w))
                bar
                (loop (reverse (cdr (reverse ks))))))))))

;; one entry's cells, one list per line of the row
(define (list-row-cells buf e &optional ctx)
  (let ((g (if ctx (list-ctx-row-cells ctx) (list-opt buf 'row-cells)))
        (f (if ctx (list-ctx-cells ctx) (list-opt buf 'cells))))
    (cond (g (g buf e))
          (f (list (f buf e)))
          (else '()))))

;; CTX is the answers every row of one draw shares: the mark column,
;; the column lines, the mode's cells, row-cells, render, and key fns,
;; and the marks. One draw computes it once. Each answer reads the
;; buffer or resolves the layout profile, and a buffer read is a call
;; into the buffer's process: a row that asked ten times cost 6ms, and
;; a draw of 400 rows took seconds.
(define (list-row-ctx buf)
  (list (list-marks-column? buf) (list-column-lines buf)
        (list-opt buf 'cells) (list-opt buf 'row-cells) (list-opt buf 'render)
        (list-marks buf) (list-opt buf 'key)))

(define (list-ctx-marks? ctx) (car ctx))
(define (list-ctx-column-lines ctx) (nth 1 ctx))
(define (list-ctx-cells ctx) (nth 2 ctx))
(define (list-ctx-row-cells ctx) (nth 3 ctx))
(define (list-ctx-render ctx) (nth 4 ctx))
(define (list-ctx-marks ctx) (nth 5 ctx))
(define (list-ctx-key ctx) (nth 6 ctx))

;; one entry as its lines. The mark column belongs to the mechanism:
;; three renders were each prepending their own. The mark goes on the
;; first line, and the lines under it start where it does.

(define (list-row-lines buf e &optional ctx)
  (let* ((ctx (or ctx (list-row-ctx buf)))
         (marks? (list-ctx-marks? ctx))
         (column-lines (list-ctx-column-lines ctx))
         (mark (if marks? (list-mark-of buf e ctx) "")))
    (if (pair? column-lines)
        (let* ((head (string-append mark " "))
               (blank (string-repeat " " (string-length head))))
          (let loop ((cs (list-row-cells buf e ctx))
                     (ks column-lines)
                     (first? #t)
                     (out '()))
            (if (or (null? cs) (null? ks))
                (reverse out)
                (let* ((laid (list-lay-out (car cs) (car ks)))
                       (pre (if first? head blank))
                       (n (string-byte-length pre)))
                  (loop (cdr cs) (cdr ks) #f
                        (cons (list (string-trim-right
                                      (string-append pre (car laid)))
                                    (append (if (or (not first?)
                                                    (equal? mark " ")
                                                    (equal? mark ""))
                                                '()
                                                (list (list 0 (string-byte-length mark)
                                                            "alert")))
                                            (list-shift-spans (car (cdr laid)) n)))
                              out))))))
        (list (list (string-append mark ((list-ctx-render ctx) buf e)) '())))))

;; the whole view, top to bottom
;; the view: the header, then the rows. The key bar is in the header,
;; under the counts, where the eye lands on an open: at the foot of the
;; text it scrolled away with the rows.
(define (list-view-lines buf rows &optional head)
  (let ((ctx (list-row-ctx buf)))
    (append (or head (list-head-lines buf))
            (fold (lambda (acc e) (append acc (list-row-lines buf e ctx))) '() rows))))

;; write the lines, answer their overlays, and leave every row's byte
;; offset on the buffer — motion and the mode's own overlays then read
;; the same numbers the text has. The text goes in as ONE replace of the
;; whole buffer: a delete and then an append let a render in between
;; see an empty buffer, reset the window's top, and write it back, and
;; the view jumped. The offsets, the head count, and the row height go
;; in as one change too, with the locals the caller adds: every change
;; is a frame refresh and a render, and a draw of twelve changes was
;; twelve of each.
;;; A draw writes only what changed. Every buffer change is a frame
;;; refresh and a render, and a whole-text rewrite is a delete and an
;;; insert: the render between the two sees an empty table. A live list
;;; redraws while its rows hold still -- an age column ticks over, a
;;; token count grows -- so the lines that differ are two of thirty.
;;; Write that run. When the line count itself moves, one whole write
;;; still answers.
(define (list-lines-shared a b)
  (let loop ((x a) (y b) (n 0))
    (if (and (pair? x) (pair? y) (equal? (car x) (car y)))
        (loop (cdr x) (cdr y) (+ n 1))
        n)))

;; the bytes the lines [FROM, TO) hold, each with its newline
(define (list-lines-bytes lines from to)
  (let loop ((ls lines) (i 0) (n 0))
    (cond ((null? ls) n)
          ((and (>= i from) (< i to))
           (loop (cdr ls) (+ i 1) (+ n (string-byte-length (car ls)) 1)))
          (else (loop (cdr ls) (+ i 1) n)))))

(define (list-lines-join lines from to)
  (let loop ((ls lines) (i 0) (acc '()))
    (cond ((null? ls) (string-join (reverse acc) "\n"))
          ((and (>= i from) (< i to))
           (loop (cdr ls) (+ i 1) (cons (car ls) acc)))
          (else (loop (cdr ls) (+ i 1) acc)))))

(define (list-write-text! buf text)
  (let ((old (buffer-text buf)))
    (unless (equal? old text)
      (let* ((a (string-split old "\n"))
             (b (string-split text "\n"))
             (n (length a)))
        (if (= n (length b))
            (let* ((p (list-lines-shared a b))
                   (s (min (- n p) (list-lines-shared (reverse a) (reverse b))))
                   (start (list-lines-bytes a 0 p))
                   (stop (- (buffer-size buf) (list-lines-bytes a (- n s) n))))
              (buffer-replace-range! buf start (- stop start)
                                     (list-lines-join b p (- n s))))
            (buffer-replace-range! buf 0 (buffer-size buf) text))))))

;;; A local that holds its value is not a change: writing it again is a
;;; refresh and a render for nothing.
(define (list-set-locals! buf plist)
  (let loop ((p plist) (fresh '()))
    (cond ((or (null? p) (null? (cdr p)))
           (unless (null? fresh) (buffer-set-locals! buf fresh)))
          ((equal? (buffer-local buf (car p)) (cadr p)) (loop (cddr p) fresh))
          (else (loop (cddr p) (cons (car p) (cons (cadr p) fresh)))))))

(define (list-write! buf lines first-row n-rows per &optional extra-locals)
  (let loop ((ls lines) (i 0) (off 0) (ovs '()) (offsets '()) (texts '()))
    (if (null? ls)
        (begin (list-write-text! buf (string-join (reverse texts) ""))
               (list-set-locals! buf
                 (append (list 'list-offsets (reverse offsets)
                               'list-head-count first-row
                               'list-row-height per)
                         (or extra-locals '())))
               (reverse ovs))
        (let ((text (car (car ls)))
              (spans (car (cdr (car ls)))))
          (loop (cdr ls) (+ i 1)
                (+ off (string-byte-length text) 1)
                (fold (lambda (acc s)
                        (cons (list (+ off (car s))
                                    (+ off (car s) (car (cdr s)))
                                    (nth 2 s))
                              acc))
                      ovs spans)
                ;; one offset per row: a row of two lines answers with
                ;; the line the reader lands on
                (if (and (>= i first-row) (< i (+ first-row (* n-rows per)))
                         (= 0 (modulo (- i first-row) per)))
                    (cons off offsets)
                    offsets)
                (cons (string-append text "\n") texts))))))

;;; --- where point is, in rows ---------------------------------------------------

(define (list-offsets buf) (or (buffer-local buf 'list-offsets) '()))

;; the header count comes off the buffer, not out of a fresh header: the
;; header names the row count, and asking it to count rows that a refresh
;; is halfway through replacing reads the rows that went
(define (list-index buf)
  (let ((ln (line-index-at buf (or (buffer-local buf 'list-head-count)
                                   (list-header-lines buf)))))
    (and ln (quotient ln (list-drawn-row-height buf)))))

(define (list-goto-index! buf i)
  (let ((offs (list-offsets buf)))
    (when (and (>= i 0) (< i (length offs)))
      (let ((p (nth i offs))
            (shown (filter (lambda (w) (equal? (cadr w) buf)) (window-list-all))))
        (if (equal? (current-buffer) buf)
            (goto-char! p)
            (begin
              (buffer-goto! buf p)
              ;; a prompt can move the list from outside: the windows
              ;; showing it keep their own point, and the client keeps each
              ;; window's point line in view, so the row follows on screen
              (for-each (lambda (w) (window-set-point! (car w) p)) shown)))
        ;; the client's own follow scroll reports back and pins the window,
        ;; and only a key IN that window unpins it. Under a prompt the keys
        ;; go to the minibuffer, so a move unpins the windows here.
        (when (pair? shown) (buffer-windows-follow-point! buf))
        (list-update-selection! buf)))))

(define (list-first-selectable-index buf)
  (let loop ((es (list-entries buf)) (i 0))
    (cond ((null? es) #f)
          ((list-selectable? buf (car es)) i)
          (else (loop (cdr es) (+ i 1))))))

(define (list-nearest-selectable-index buf from)
  (let* ((es (list-entries buf))
         (n (length es)))
    (if (= n 0)
        #f
        (let ((start (max 0 (min (- n 1) from))))
          (let forward ((i start))
            (cond ((>= i n)
                   (let backward ((j (- start 1)))
                     (cond ((< j 0) #f)
                           ((list-selectable? buf (nth j es)) j)
                           (else (backward (- j 1))))))
                  ((list-selectable? buf (nth i es)) i)
                  (else (forward (+ i 1)))))))))

(define (list-step-selectable-index buf from step)
  (let* ((es (list-entries buf))
         (n (length es)))
    (let loop ((i (+ from step)))
      (cond ((or (< i 0) (>= i n)) from)
            ((list-selectable? buf (nth i es)) i)
            (else (loop (+ i step)))))))

;; Point is the live selection. Keep its row key as durable state, and paint
;; the complete row when the mode asks for a selection face. A row can use
;; more than one line, so the overlay follows the rendered row height.
(define (list-update-selection! buf)
  (let* ((i (list-clamped-index buf))
         (entries (list-entries buf))
         (offsets (list-offsets buf))
         (face (list-opt buf 'selection-face)))
    (if (and i (< i (length entries)) (< i (length offsets)))
        (let* ((entry (nth i entries))
               (start (nth i offsets))
               (size (fold (lambda (n line)
                             (+ n (string-byte-length (car line)) 1))
                           0 (list-row-lines buf entry))))
          ;; the key is a change, and a change is a refresh: write it
          ;; only when the selection moved
          (let ((key (list-key buf entry)))
            (unless (equal? key (buffer-local buf 'list-selection-key))
              (buffer-set-local! buf 'list-selection-key key)))
          (if face
              (overlay-set! buf 'list-selection
                (list (list start (+ start size) face)))
              (overlay-clear! buf 'list-selection)))
        ;; Keep the saved key when rows are temporarily empty. An async reload
        ;; can use it when the rows arrive again.
        (overlay-clear! buf 'list-selection))))

;; the row point sits on, clamped into the rows: below the last one is
;; the key bar, and a list where point can leave the rows has no row at
;; point to act on
(define (list-clamped-index buf)
  (let ((n (length (list-entries buf)))
        (i (list-index buf)))
    (cond ((= n 0) #f)
          ((not i) 0)
          ((>= i n) (- n 1))
          (else i))))

;; the client re-measures its windows after every patch. When one of them
;; changes width, the tables ON SCREEN lay themselves out again — this is
;; the window-configuration change hook, and a visible list is what
;; listens. A hidden list has no width of its own (it would lay out for
;; the active window), and the width check in list-post-command! re-lays
;; it the moment a window shows it.
(define (window-config-changed!)
  (for-each (lambda (w) (list-post-command! (cadr w))) (window-list)))

;; Point never rests in the chrome. A header line and a key bar are not
;; rows, and a verb acts on the row at point — so a click on the key bar
;; made `k` say "killed 0 buffers" and RET say "no buffer here", again
;; and again, because nothing moved point back. The nearest row takes
;; point, and the reader SEES what the next key acts on.
(define (list-snap-point! buf)
  (let ((n (length (list-entries buf))))
    (when (> n 0)
      (let ((i (list-index buf)))
        (let ((target (list-nearest-selectable-index
                        buf (cond ((not i) 0)
                                  ((>= i n) (- n 1))
                                  (else i)))))
          (when target (list-goto-index! buf target)))))))

;; Some lists show state that other commands change: ibuffer shows the
;; buffers, and C-x k kills one from anywhere. Such a mode gives a
;; 'stamp fn — a cheap value that moves when the rows move. The list
;; compares the stamp after every command and re-renders when it
;; differs, so a verb never acts on a row that is gone.
(define (list-stamp! buf)
  (let ((f (list-opt buf 'stamp)))
    (when f (buffer-set-local! buf 'list-stamp (f buf)))))

(define (list-restamp! buf)
  (let ((f (list-opt buf 'stamp)))
    (when f
      (unless (equal? (f buf) (buffer-local buf 'list-stamp))
        (list-refresh! buf)))))

;; a table lays out in characters, so a window that changed width means a
;; re-render — of the rows the list already has. A resize never needs new
;; data, so it must not call the source (the network, for sentry); only
;; `g` and the mode's own verbs fetch. After a command is the other
;; moment the width can have moved.
(define (list-post-command! buf)
  (when (list-mode-of buf)
    (when (list-table? buf)
      (let ((w (list-view-width buf)))
        (unless (equal? w (buffer-local buf 'list-width))
          (buffer-set-local! buf 'list-width w)
          (list-render! buf 'cached))))
    (list-restamp! buf)
    (list-snap-point! buf)
    (list-update-selection! buf)))

(define (list-preview! buf)
  (let ((f (list-opt buf 'preview))
        (e (list-current buf)))
    (when (and f e) (f buf e))))

;; the mover may not be in the list: the filter prompt is the current
;; buffer while its arrows move the rows of the list behind it
(define (list-move-in! buf step)
  (let ((i (list-clamped-index buf)))
    (when i
      (let ((target (list-step-selectable-index buf i step)))
        ;; A skipped heading can put the target on the next page.
        (when (> step 0) (list-ensure-shown! buf target))
        (list-goto-index! buf target)
        (list-preview! buf)))))

(define (list-move! step) (list-move-in! (current-buffer) step))

(domain! 'interaction)
(effects! '(read))

(define-command "list-next" "Move to the next row of this list"
  (lambda () (list-move! 1)))

(define-command "list-prev" "Move to the previous row of this list"
  (lambda () (list-move! -1)))

;; a screen down in a paged list: the rows the screen lands on are drawn
;; first, so the page never ends in the key bar with more rows to come
(define-command "list-page-down" "Move a screen down this list; a paged list draws its next page"
  (lambda ()
    (let* ((buf (current-buffer))
           (i (or (list-clamped-index buf) 0)))
      (list-ensure-shown! buf (+ i (window-rows)))
      (move-lines (- (window-rows) 2) next-line!)
      (list-snap-point! buf))))

(define-command "list-more" "Draw the next page of this list"
  (lambda ()
    (if (list-more? (current-buffer))
        (list-more! (current-buffer))
        (message "Every row is shown"))))

(domain! 'unknown)
(effects! '(unknown))

;; the first entry's byte offset — the header may be several lines
(define (list-first-entry-pos buf)
  (+ (string-byte-length (list-header-text buf)) 1))

;; a narrow makes the old line meaningless: land on the first row. The
;; filter prompt calls this while the minibuffer is current, so it moves
;; the list's own point rather than the current buffer's.
(define (list-goto-first-entry buf)
  (if (pair? (list-offsets buf))
      (let ((i (list-first-selectable-index buf)))
        (when i (list-goto-index! buf i)))
      (let ((p (min (list-first-entry-pos buf) (buffer-size buf))))
        (if (equal? (current-buffer) buf)
            (goto-char! p)
            (buffer-goto! buf p)))))

(define (list-set-filters! buf fs)
  (buffer-set-local! buf 'list-filters fs)
  (list-refresh! buf)
  (list-goto-first-entry buf))

(domain! 'interaction)
(effects! '(write))

;;; The filter prompt has no candidates of its own: the ROWS are the
;;; candidates, and they live in the list behind the prompt. So the
;;; arrows move the highlight in that list while you type, and RET closes
;;; the prompt on the row you chose. You type, and then you select.
(define *mb-list-buffer* #f)
(define *list-filter-prompt* "Filter: ")
;; the label of the prompt that stands in front of *mb-list-buffer*: the
;; filter's own, or the one a table's prompt form chose
(define *mb-list-prompt* #f)

;; #t means the arrows moved a list. #f means no list stands behind this
;; prompt, so the minibuffer keeps its own arrows. The prompt line is the
;; proof: a prompt can also close behind Scheme's back, and a stale list
;; must never steal the arrows from the next palette.
(define (mb-list-target)
  (let ((buf *mb-list-buffer*)
        (mb (minibuffer-state)))
    (and buf mb (buffer-exists? buf)
         (equal? (plist-get mb 'prompt) (or *mb-list-prompt* *list-filter-prompt*))
         buf)))

(define (mb-list-move! step)
  (let ((buf (mb-list-target)))
    (if buf
        (begin (with-invoking-buffer (lambda () (list-move-in! buf step))) #t)
        #f)))

;; The prompt in front of a list drives that list. Each of these answers
;; #t when a list stood behind the prompt and took the key, so the
;; minibuffer's own meaning for the key stays the fallback. What the key
;; MEANS is the list mode's: 'fold and 'regroup are fns of the buffer.
(define (mb-list-call! key)
  (let ((buf (mb-list-target)))
    (and buf
         (let ((f (list-opt buf key)))
           (and f (begin (with-invoking-buffer (lambda () (f buf))) #t))))))

;; the index of the next row that starts a section, walking STEP from
;; the row at point; #f when there is none that way
(define (list-section-index buf from step)
  (let* ((es (list-entries buf))
         (n (length es)))
    (let loop ((i (+ from step)))
      (cond ((or (< i 0) (>= i n)) #f)
            ((list-section-start? buf (nth i es)) i)
            (else (loop (+ i step)))))))

;; the index of the section the row at FROM belongs to: the nearest
;; section start at or above it, or #f above the first one
(define (list-section-here buf from)
  (let ((es (list-entries buf)))
    (let loop ((i from))
      (cond ((< i 0) #f)
            ((list-section-start? buf (nth i es)) i)
            (else (loop (- i 1)))))))

;; A section jump lands on the section's first ROW, not on its heading:
;; the jump is how you reach the rows over there, and RET must visit one.
;; A folded heading stands for its rows, so the jump rests on it.
;; Backwards means the section BEFORE this one, so the walk starts at
;; this section's own heading and not at the row you are on.
;;
;; The key belongs to the list whenever a list stands behind the prompt.
;; At the first section, backwards does nothing — it must not fall
;; through to the history and type a past answer into the filter.
(define (mb-list-section! step)
  (let ((buf (mb-list-target)))
    (and buf
         (let* ((i (list-clamped-index buf))
                (from (if (and i (< step 0)) (or (list-section-here buf i) i) i))
                (head (and from (list-section-index buf from step))))
           (when head
             (let* ((entries (list-entries buf))
                    (target (if (list-selectable? buf (nth head entries))
                                head
                                (list-step-selectable-index buf head 1))))
               (with-invoking-buffer
                 (lambda ()
                   (list-ensure-shown! buf target)
                   (list-goto-index! buf target)
                   (list-preview! buf)))))
           #t))))

;; The narrowing is live, and the input IS it. The prompt opens holding
;; the query the list already has, so `/` edits the narrowing instead of
;; stacking a second one on top of it. Every keystroke narrows, every
;; DEL widens, and an empty input means no query at all — that is how
;; you remove one. C-g puts back the query you came in with.
(define-command "list-filter"
  "Narrow this list to the rows that match what you type"
  (lambda ()
    (let* ((buf (current-buffer))
           (before (list-query buf))
           (narrow (lambda (q)
                     (list-set-query! buf q)
                     (list-goto-first-entry buf)))
           (done (lambda () (set! *mb-list-buffer* #f) (set! *mb-list-prompt* #f))))
      (set! *mb-list-buffer* buf)
      (set! *mb-list-prompt* *list-filter-prompt*)
      (minibuffer-read* *list-filter-prompt* '()
        (list (list 'change narrow)
              ;; RET keeps the narrowing AND the row: the arrows moved the
              ;; highlight to the row you want, so confirm must not send it
              ;; back to the first one. A query the change handler did not
              ;; apply yet still narrows here.
              (list 'confirm (lambda (q)
                               (done)
                               (if (equal? q (list-query buf)) #t (narrow q))))
              (list 'cancel (lambda () (done) (narrow before)))
              (list 'style "filter")))
      ;; the prompt starts where the list is: editing beats retyping
      (unless (equal? before "") (minibuffer-input! before)))))

(define-command "list-filter-pop" "Drop the most recent filter on this list"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (null? (list-filters buf))
          (message "no filter")
          (begin (list-filter-pop! buf)
                 (list-goto-first-entry buf))))))

(define-command "list-filter-clear" "Drop every filter on this list"
  (lambda ()
    (let ((buf (current-buffer)))
      (list-filter-clear! buf)
      (list-goto-first-entry buf))))

(domain! 'unknown)
(effects! '(unknown))

;;; the refresh every one of them wrote by hand

;; a row may want colour, and colour is byte ranges — so the list tells
;; the row where its line landed rather than making the caller keep its
;; own running offset
(define (list-row-overlays buf rows)
  (let ((ovf (list-opt buf 'overlays)))
    (if (not ovf)
        '()
        (let loop ((es rows) (offs (list-offsets buf)) (out '()))
          (if (or (null? es) (null? offs))
              (reverse out)
              (loop (cdr es) (cdr offs)
                    (append (reverse (ovf buf (car es) (car offs))) out)))))))

;; where a row went: a refresh may reorder the rows, and the reader stays
;; on the row rather than on its number
(define (list-index-of buf rows key)
  (let loop ((es rows) (i 0))
    (cond ((null? es) #f)
          ((equal? (list-key buf (car es)) key) i)
          (else (loop (cdr es) (+ i 1))))))

;;; --- pages -------------------------------------------------------------------
;;; A mode with many rows declares 'page-size N. The draw writes the first
;;; page; the reader who moves past its end gets the next page, and the
;;; header says how many rows the page holds of the whole. The entries
;;; keep every row, so the counts, the filters, and the marks see them
;;; all, and the drawn rows are a prefix of the entries, so an index means
;;; the same row in both.

(define (list-page-size buf) (list-opt buf 'page-size))

;; how many rows the next draw writes: the pages opened so far, or one
(define (list-page-limit buf)
  (let ((size (list-page-size buf)))
    (and size (max size (or (buffer-local buf 'list-page-limit) 0)))))

(define (list-page-rows buf rows)
  (let ((limit (list-page-limit buf)))
    (if (and limit (> (length rows) limit))
        (let loop ((rs rows) (k limit) (acc '()))
          (if (or (null? rs) (= k 0))
              (reverse acc)
              (loop (cdr rs) (- k 1) (cons (car rs) acc))))
        rows)))

(define (list-shown-count buf)
  (or (buffer-local buf 'list-shown-count) (length (list-entries buf))))

;; only a paged list has more: a mode without pages may set its own
;; entries after a draw, and the count of the last draw is not a page
(define (list-more? buf)
  (and (list-page-size buf)
       (< (list-shown-count buf) (length (list-entries buf)))))

;; draw enough pages to show row WANT (an index); nothing when it shows
(define (list-ensure-shown! buf want)
  (let ((size (list-page-size buf)))
    (when (and size (list-more? buf) (>= want (list-shown-count buf)))
      (let* ((total (length (list-entries buf)))
             (pages (+ 1 (quotient want size)))
             (limit (min total (* pages size))))
        (buffer-set-local! buf 'list-page-limit limit)
        (list-redraw! buf)))))

(define (list-more! buf)
  (list-ensure-shown! buf (list-shown-count buf)))

;; the row index at byte POS: the last row whose start is at or before it
(define (list-index-at-pos buf pos)
  (let loop ((offs (list-offsets buf)) (i 0) (best #f))
    (cond ((null? offs) best)
          ((<= (car offs) pos) (loop (cdr offs) (+ i 1) i))
          (else best))))

;; the row key at byte POS, or #f in the header
(define (list-key-at-pos buf pos)
  (let ((i (list-index-at-pos buf pos))
        (es (list-entries buf)))
    (and i (< i (length es)) (list-key buf (nth i es)))))

;; Every window showing BUF and the row its own point is on (Emacs
;; dired-save-positions). A window keeps its own point; the buffer's
;; point is only the selected window's. -> ((WIN KEY) ...)
(define (list-window-places buf)
  (fold (lambda (acc w)
          (if (equal? (cadr w) buf)
              (let ((p (window-point (car w))))
                (cons (list (car w) (and (number? p) (list-key-at-pos buf p))) acc))
              acc))
        '()
        (window-list-all)))

;; put each window back on its row after a rewrite (Emacs
;; dired-restore-positions). The rewrite clamped every stored window
;; point to 0; the buffer point alone reaches only the selected window.
(define (list-restore-window-places! buf places rows)
  (let ((offs (list-offsets buf))
        (last (- (list-shown-count buf) 1)))
    (for-each
      (lambda (place)
        (let ((i (and (cadr place) (list-index-of buf rows (cadr place)))))
          (when (and i (>= last 0))
            (let ((at (min i last)))
              (when (< at (length offs))
                (let ((p (nth at offs)))
                  ;; A refresh that left this row at the same byte left the
                  ;; window alone too. Re-setting it still makes the client
                  ;; follow point and repaint the window.
                  (unless (equal? (window-point (car place)) p)
                    (window-set-point! (car place) p))))))))
      places)))

;; Optional semantic projection of the same selectable rows. Text offsets stay
;; authoritative for commands, search, marks, and per-window selection.
;; Field boundaries come from the same layout operation that wrote the text.
(define (list-composml-fields buf row start &optional ctx fields)
  (let ((fields (or fields (list-opt buf 'composml-fields))))
    (if (not fields) '()
      (let* ((ctx (or ctx (list-row-ctx buf)))
             (prefix (+ (string-byte-length (if (list-ctx-marks? ctx) (list-mark-of buf row ctx) "")) 1))
             (laid (list-lay-out (car (list-row-cells buf row ctx))
                                (car (list-ctx-column-lines ctx)) #t)))
        (let loop ((ranges (nth 2 laid)) (descs (fields buf row)) (out '()))
          (if (or (null? ranges) (null? descs)) (reverse out)
            (let* ((r (car ranges)) (a (+ start prefix (car r))))
              (loop (cdr ranges) (cdr descs)
                (if (> (cadr r) 0) (cons (list a (+ a (cadr r)) (car descs)) out) out)))))))))

;; Semantic text records keep the existing text, faces and line geometry.
(define (list-composml-text! buf rows)
  (let ((record (or (list-opt buf 'composml-record)
                    (lambda (b row) (list 'tag "c-item"))))
        (root (or (list-opt buf 'composml-root)
                  (lambda (b) (list 'tag "c-list" 'attrs
                    (list (list "mode" (list-mode-of b))))))))
    (unless (list-opt buf 'composml)
      (desktop-skip! buf 'render-text-root)
      (desktop-skip! buf 'render-records)
      ;; the draw's own context and field fn, read once: a row that asked
      ;; for them itself cost this pass twice its time (docs/LISTS.md).
      (let* ((ctx (list-row-ctx buf))
             (fields (list-opt buf 'composml-fields))
             (key-of (list-ctx-key ctx)))
        (list-set-locals! buf
          (list 'render-text-root (root buf)
                'render-records
                (let loop ((rs rows) (offsets (list-offsets buf)) (out '()))
                  (if (or (null? rs) (null? offsets)) (reverse out)
                    (let* ((row (car rs)) (start (car offsets))
                           (size (fold (lambda (n ln) (+ n (string-byte-length (car ln)) 1))
                                       0 (list-row-lines buf row ctx)))
                           (block (record buf row)))
                      (loop (cdr rs) (cdr offsets)
                        (cons (list start (+ start size)
                                (append (list 'fields (if fields (list-composml-fields buf row start ctx fields) '())
                                              'attrs (append
                                (list (list "record-id" (let ((key (if key-of (key-of buf row) row)))
                                  (if (string? key) key (value->string key)))))
                                (or (plist-get block 'attrs) '()))) block)) out)))))))))))

(define (list-composml! buf rows head)
  (let ((render (list-opt buf 'composml))
        (collection (list-opt buf 'collection)))
    (when (and render collection)
      (desktop-skip! buf 'render-blocks)
      (desktop-skip! buf 'render-root)
      (let ((per (list-row-height buf)) (first (length head)))
        (list-set-locals! buf
          (list 'render-mode "blocks"
                'render-root (let ((root (list-opt buf 'composml-root)))
                               (if root (root buf) (list 'tag "c-buffer")))
                'render-blocks
                (list
                  (list 'tag "c-headerline" 'class "semantic-list-header"
                        ;; the head is text and its faces. A mode that wants
                        ;; its own head -- tabs as tabs, a title as a title --
                        ;; answers 'composml-head with blocks instead.
                        'children (let ((f (list-opt buf 'composml-head)))
                                    (if f
                                        (f buf head)
                                        (map (lambda (ln) (list 'tag "pre" 'text (car ln))) head))))
                  (list 'tag collection 'class "semantic-list"
                        'attrs '(("role" "list"))
                        'children
                        (let loop ((rest rows) (i 0) (out '()))
                          (if (null? rest) (reverse out)
                            (let* ((row (car rest))
                                   (key (list-key buf row))
                                   (block (render buf row))
                                   (start (+ first (* i per) 1)))
                              (loop (cdr rest) (+ i 1)
                                (cons
                                  (append
                                    (list 'class (string-append "semantic-item " (or (plist-get block 'class) ""))
                                          'anchor (string-append "list:" (url-encode key))
                                          'click (string-append "list:" key)
                                          'lines (list start (+ start per -1))
                                          'mark "selected"
                                          'attrs (append (list (list "record-id" key) (list "role" "listitem"))
                                                         (or (plist-get block 'attrs) '())))
                                    block)
                                  out)))))))))))))

(define (list-render! buf fetch)
  (when (buffer-exists? buf)
    ;; the layout cache needs no reset here: it names the width it was
    ;; laid out for, and a new width misses it
    ;; a rewrite dumps point to 0 — keep the reader's place. The place is
    ;; the ROW the reader is on, not the byte and not the number: a
    ;; reflowed table moves every byte, and a most-recently-used list
    ;; reorders the rows under the cursor.
    (let* ((here (list-current buf))
           (selected-key (or (and here (list-key buf here))
                             (buffer-local buf 'list-selection-key)))
           (was (list-index buf))
           ;; each window's own row, before the rows move under it
           (places (list-window-places buf))
           (rows (list-render-rows! buf fetch))
           (cur? (equal? (current-buffer) buf))
           ;; the buffer's own point: a refresh runs while another buffer
           ;; is current (a hook, a prompt), and that list keeps its place
           (p (buffer-point buf)))
      ;; The rewrite is a programmatic write: buffer-replace-range! bypasses
      ;; read-only on its own. The flag stays where it is. A flip off and
      ;; on reached the browser as two patches when a hook redrew the list
      ;; outside a command, and for the patch between them the read-only
      ;; buffer was editable: the client took the caret, lost its text
      ;; node on the second patch, and reported end-of-buffer as point.
      ;; a paged list draws the first page of its rows; the entries keep
      ;; every row, so the counts and the filters see them all
      (let* ((shown (list-page-rows buf rows)))
        ;; entries first: the header states the row count. The columns
        ;; lay out against the rows this draw writes: the cache clears
        ;; HERE, not before the fetch. Reading point asks the header how
        ;; many lines it has, and that laid the columns out while the
        ;; rows they must fit were still the last draw's. Every later
        ;; call in this draw reads the cache, so the mode's columns fn
        ;; still runs once. One change for the two, and none when the
        ;; rows this draw found are the rows the last one drew.
        (list-columns-forget! buf)
        (list-set-locals! buf
          (list 'list-entries rows
                'list-shown-count (length shown)))
        (let* (;; the header once: its lines and their count are one answer
               (head (list-head-lines buf))
               (stamp-fn (list-opt buf 'stamp))
               ;; the width and the stamp ride the write's own change: the
               ;; rows are now the rows this render shows, and the stamp
               ;; says so
               (extra (append
                        (if (list-table? buf)
                            (list 'list-width (list-view-width buf))
                            '())
                        (if stamp-fn (list 'list-stamp (stamp-fn buf)) '())))
               (base (list-write! buf (list-view-lines buf shown head)
                                  (length head) (length shown)
                                  (list-row-height buf) extra)))
          ;; the tag's old ranges go with this set: one change, not a
          ;; clear and then a set
          (overlay-set! buf 'list (append base (list-row-overlays buf shown)))
          (list-composml! buf shown head)
          (list-composml-text! buf shown)))
      (let ((i (and selected-key (list-index-of buf rows selected-key)))
            (last (- (list-shown-count buf) 1)))
        ;; Restore the buffer's point without moving every window that
        ;; shows it. list-goto-index! deliberately propagates interactive
        ;; motion to those windows; a background refresh must preserve each
        ;; window's independent place instead.
        (let* ((at (cond ((and i (pair? rows)) (min i last))
                         ((and was (pair? rows)) (min was last))
                         (else #f)))
               (q (if at
                      (nth at (list-offsets buf))
                      (min p (buffer-size buf)))))
          (unless (equal? (buffer-point buf) q)
            (if cur? (goto-char! q) (buffer-goto! buf q)))))
      (list-snap-point! buf)
      (list-update-selection! buf)
      ;; the windows that show this list, each on its own row again
      (list-restore-window-places! buf places rows))))

;; `g` and every source change fetch again; a filter keystroke only
;; redraws, and a 'local-filter list then reuses its cached source.
(define (list-refresh! buf) (list-render! buf #t))
(define (list-redraw! buf) (list-render! buf #f))

;; the `g` every list answers: a cached list fetches its source again,
;; a plain one re-reads its rows; a mode's own `g` shadows this one
(define-command "list-revert" "Fetch this list's rows again and redraw"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (buffer-local buf 'cache-spec)
          (cache-refresh! buf)
          (list-refresh! buf)))))

;;; --- the buffer cache: content fetched from a slow source ---------------------
;;; A buffer that shows external data (an HTTP API, a slow command) keeps
;;; what it fetched — rendered text, list entries — and these helpers keep
;;; the bookkeeping: when the data arrived, whether it is stale, and one
;;; refresh in flight at a time. The fetch must leave the UI lane: FETCH
;;; receives a continuation and calls it with the data when it has it, so
;;; a shell fetch uses the callback form of shell-command->string and the
;;; lane moves on. A wake draws the cache it has and refreshes only when
;;; the declared TTL has passed.
;;;
;;;   'cache-time      seconds at the last successful render — persists,
;;;                    so a restart knows the age of what it restored
;;;   'cache-spec      (fetch FN render FN ttl SECONDS) — holds closures,
;;;                    so the mode setup re-declares it on every wake
;;;   'cache-inflight  one refresh at a time — runtime state

(define (cache-declare! buf fetch render ttl)
  (desktop-skip! buf 'cache-spec)
  (desktop-skip! buf 'cache-inflight)
  (buffer-set-local! buf 'cache-inflight #f)
  (buffer-set-local! buf 'cache-spec
    (list 'fetch fetch 'render render 'ttl ttl)))

(define (cache-stamp! buf)
  (buffer-set-local! buf 'cache-time (current-time)))

;; seconds since the last successful render, or #f before the first
(define (cache-age buf)
  (let ((t (buffer-local buf 'cache-time)))
    (and t (- (current-time) t))))

;; #t when the buffer never rendered, or its TTL has passed. A declared
;; TTL of #f means the data never goes stale by age: only an explicit
;; cache-refresh! fetches again.
(define (cache-stale? buf)
  (let ((spec (buffer-local buf 'cache-spec)))
    (and spec
         (let ((age (cache-age buf))
               (ttl (plist-get spec 'ttl)))
           (cond ((not age) #t)
                 ((not ttl) #f)
                 (else (> age ttl)))))))

;; "just now", "40s ago", "5m ago", "2h ago" — for a header or modeline
(define (cache-age-label buf)
  (let ((age (cache-age buf)))
    (cond ((not age) #f)
          ((< age 10) "just now")
          ((< age 60) (string-append (number->string age) "s ago"))
          ((< age 3600) (string-append (number->string (quotient age 60)) "m ago"))
          (else (string-append (number->string (quotient age 3600)) "h ago")))))

;; Fetch and re-render. The buffer shows what it has until the data
;; lands; a fetch already in flight is not doubled. A #f from the fetch
;; leaves the cache as it was — the stale rows beat an empty view.
(define (cache-refresh! buf)
  (let ((spec (buffer-local buf 'cache-spec)))
    (when (and spec (not (buffer-local buf 'cache-inflight)))
      (buffer-set-local! buf 'cache-inflight #t)
      ((plist-get spec 'fetch) buf
       (lambda (data)
         (when (buffer-known? buf)
           (buffer-set-local! buf 'cache-inflight #f)
           (when data
             ((plist-get spec 'render) buf data)
             ;; a render may retire its own buffer — browse hands a PDF to
             ;; the file's own mode and kills the tab — so the stamp asks
             ;; again whether there is still a buffer to stamp
             (when (buffer-known? buf) (cache-stamp! buf)))))))))

;; the wake rule: show the cache, and fetch only past the TTL
(define (cache-wake! buf)
  (when (cache-stale? buf) (cache-refresh! buf)))

;; a caller that refreshes right after entering the mode (ibuffer-open!)
;; must not have list-mode-init! draw first: that draw is thrown away
;; unread, and on a table of hundreds of rows it is not cheap to throw away
(define *list-mode-skip-render* #f)

(define (with-list-mode-skip-render thunk)
  (let ((was *list-mode-skip-render*))
    (set! *list-mode-skip-render* #t)
    (let ((r (thunk)))
      (set! *list-mode-skip-render* was)
      r)))

;; Everything a list buffer needs to BE one, applied to an explicit
;; buffer. The mode setup calls it with (current-buffer); opening a list
;; calls it with the buffer it just made, so neither has to select first.
(define (list-mode-init! buf name)
  (let ((opts (list-mode-opts name))
        (widened #f))
    (buffer-set-local! buf 'list-mode name)
    (desktop-skip! buf 'list-layout-cache)
    (buffer-set-local! buf 'list-layout-cache #f)
    ;; whether this list is a view is the MODE's answer now (its parent is
    ;; special-mode unless the list declared 'special #f), so nothing is
    ;; written here. What the desktop keeps is a separate question,
    ;; answered by desktop-skip! above.
    ;; the stamp names the rows of one render — a restart draws new ones
    (desktop-skip! buf 'list-stamp)
    ;; A list opens WIDE. The typed narrowing answers a question you asked
    ;; THIS time; a local persists, so C-x C-b days later opened on a
    ;; three-row list narrowed by a word you no longer remember typing.
    ;; The mode's own kinds (dired's dotfiles) are a setting, and stay.
    ;; ...but a WAKE is not an open. Clearing the query there would leave
    ;; the buffer holding the rows a narrowing kept with no query to
    ;; explain them, and redrawing them from the source is the fetch a
    ;; preview must not pay.
    (unless *buffer-waking*
      (set! widened (list-clear-query! buf))
      ;; an open shows the first page; the pages you drew were for the
      ;; question you asked last time
      (buffer-set-local! buf 'list-page-limit #f))
    (desktop-skip! buf 'list-shown-count)
    ;; a list buffer's text IS its view. A buffer keeps the locals of the
    ;; mode before it, so dired on a directory that once held a diff kept
    ;; 'render-mode "blocks" and the window drew no rows at all.
    (buffer-set-local! buf 'render-mode #f)
    (buffer-set-local! buf 'render-text-root #f)
    (buffer-set-local! buf 'render-records #f)
    ;; the keys are the mode's map, under list-mode-map (define-list-mode!);
    ;; a layout profile's own flags are buffer state and bind here
    (list-install-mark-keys! buf)
    ;; a table moves the same way in every list: the line-motion keys
    ;; REMAP, so the arrows and C-n/C-p walk the rows and stop at the ends
    (when (list-table? buf)
      (local-remap*! buf "next-line" "list-next")
      (local-remap*! buf "previous-line" "list-prev")
      (local-remap*! buf "scroll-up-command" "list-page-down"))
    (for-each (lambda (r) (local-remap*! buf (car r) (car (cdr r))))
              (or (plist-get opts 'remap) '()))
    (buffer-set-read-only! buf #t)
    ;; A wake must not pay the source fetch: the buffer switcher previews
    ;; dormant buffers by re-running this setup, and a list whose rows come
    ;; from the network (sentry) froze the UI for the round trip — then
    ;; went back to sleep. 'cached renders the rows already in the buffer
    ;; and reaches the source only when there are none; `g` refetches.
    ;; ...unless the clear above just widened the list. The rows in the
    ;; buffer are the ones a narrowing kept, so drawing them back would
    ;; open the list on a query it no longer holds: the filters read
    ;; empty and the rows stay narrow, for good. A dired listing that
    ;; matched one file kept showing that file every time it re-opened.
    (unless *list-mode-skip-render*
      (list-render! buf (if widened #t 'cached)))
    ;; list-render! restores the selected row by key. It moves a new list to
    ;; its first row, but it does not reset an existing list during reload.
    ;; a list that declares an off-lane source refreshes through the
    ;; buffer cache: the wake above drew what it had, and new rows land
    ;; when the fetch answers. 'rows keeps serving the cached entries.
    (let ((cf (plist-get opts 'cache-fetch)))
      (when cf
        (cache-declare! buf cf
          (lambda (b rows)
            (buffer-set-local! b 'list-entries rows)
            (list-render! b 'cached))
          (plist-get opts 'cache-ttl))
        (cache-wake! buf)))))

(define (define-list-mode! name opts)
  (set! *list-modes*
    (cons (list name opts)
          (remove (lambda (e) (equal? (car e) name)) *list-modes*)))
  ;; the list says what it is once, here — describe-mode reads it back
  (let ((d (plist-get opts 'doc)))
    (when d (mode-doc! name d)))
  ;; a real mode: a restored list buffer gets its keys and its read-only
  ;; flag back from here, not from whatever command first opened it
  (define-mode name (lambda () (list-mode-init! (current-buffer) name)))
  ;; Emacs derives tabulated-list-mode from special-mode. A generated list
  ;; is a view unless it says otherwise, and it says so once, here, as its
  ;; parent -- not as a local on every buffer the mode makes.
  (mode-parent! name (if (if (member 'special opts) (plist-get opts 'special) #t)
                         "special-mode"
                         "list-mode"))
  ;; the list's keys: its own on its map, every list's under it
  (keymap-parent! (mode-keymap name) "list-mode-map")
  (mode-keys! name (or (plist-get opts 'keys) '()))
  (list-flag-keys! (lambda (k c) (define-key (mode-keymap name) k c))
                   (or (plist-get opts 'flags) '()))
  name)

;; open (or re-open) a list buffer in its mode
(define (list-mode-show! name)
  (let ((buf (plist-get (list-mode-opts name) 'buffer)))
    (buffer-create buf)
    ;; an explicit open asks for current rows; a wake does not. The init
    ;; below redraws cached entries when there are any, so fetch here in
    ;; that case — the one place the user chose to look.
    (let ((cached? (pair? (buffer-local buf 'list-entries))))
      ;; enter the mode through set-mode!: it attaches the mode's keymap
      ;; (use-local-map!) and runs the setup above. A bare mode-name
      ;; local leaves the list's keys unreachable (S8).
      (with-current-buffer buf (lambda () (set-mode! name)))
      ;; current rows; the row stays where the reader left it. The point
      ;; belongs to the reader, and the draw restores the row by its key.
      (when cached?
        (list-refresh! buf)))
    ;; a listing is opened to work in: the window it takes is selected
    (pop-to-buffer buf)
    buf))

;;; --- plists ------------------------------------------------------------------
;;; Flat plists — (key value key value ...) with symbol keys — are the house
;;; record shape: events, configs, conversation turns. This dialect has no
;;; dotted pairs, so there are no alists to confuse them with.

;; plist-get is a builtin: the flat plist read is the hottest list read.

;; list-ref by its Emacs name; list-ref is a builtin
(define (nth n l) (list-ref l n))

;;; --- editing commands ------------------------------------------------------

;; (repeat-count N THUNK): THUNK N times; a negative N runs OPPOSITE -N times
(define (repeat-count n thunk &optional opposite)
  (cond ((and (< n 0) opposite) (repeat-count (- n) opposite))
        (else (let loop ((i 0)) (when (< i n) (thunk) (loop (+ i 1)))))))

(define-command "forward-char" "Move point one character forward" (interactive 'p)
  (lambda (n) (repeat-count n forward-char! backward-char!)))
(define-command "backward-char" "Move point one character backward" (interactive 'p)
  (lambda (n) (repeat-count n backward-char! forward-char!)))
;; An app owns its input, and a read-only HTML page is a reader. Scroll those
;; pages instead of moving an invisible source point. A writable HTML preview
;; takes edits, so its motion keys must move through the source.
(define (preview-buffer? buf)
  (let ((rm (buffer-local buf 'render-mode)))
    (or (equal? rm "app")
        (and (equal? rm "html") (buffer-read-only? buf)))))

;; #t when it scrolled, so a command can fall through to the point motion
(define (preview-scroll! lines)
  (and (preview-buffer? (current-buffer))
       (begin (scroll-window! (active-window) lines) #t)))

(define (next-line-n! n)
  (repeat-count n
    (lambda () (or (preview-scroll! 3) (visual-next-line!)))
    (lambda () (or (preview-scroll! -3) (visual-previous-line!)))))

(define-command "next-line" "Move point down one line" (interactive 'p)
  (lambda (n) (next-line-n! n)))
(define-command "previous-line" "Move point up one line" (interactive 'p)
  (lambda (n) (next-line-n! (- n))))
(define-command "beginning-of-line" "Move point to the beginning of the line"
  (lambda () (visual-beginning-of-line!)))
(define-command "end-of-line" "Move point to the end of the line"
  (lambda () (visual-end-of-line!)))
(define-command "beginning-of-buffer" "Move point to the beginning of the buffer"
  (lambda () (or (preview-scroll! -1000000) (beginning-of-buffer!))))
(define-command "end-of-buffer" "Move point to the end of the buffer"
  (lambda () (or (preview-scroll! 1000000) (end-of-buffer!))))
(catalog-meta! 'command "beginning-of-buffer" 'domain 'editing 'effects '(write display))
(catalog-meta! 'command "end-of-buffer" 'domain 'editing 'effects '(write display))

(define (preview--positions text needle)
  (let loop ((from 0) (acc (list)))
    (let ((i (string-index text needle from)))
      (if i
          (loop (+ i 1) (cons i acc))
          (reverse acc)))))

;; The nearest position strictly on DIR's side of FROM. DIR is 1 for a key
;; that moves down, -1 for a key that moves up.
(define (preview--toward positions from dir)
  (let ((side (filter (lambda (p) (if (> dir 0) (> p from) (< p from)))
                      positions)))
    (cond ((null? side) #f)
          ((> dir 0) (car side))
          (else (car (reverse side))))))

;; The position nearest FROM, on either side.
(define (preview--nearest positions from)
  (let loop ((ps positions) (best #f))
    (cond ((null? ps) best)
          ((or (not best) (< (abs (- (car ps) from)) (abs (- best from))))
           (loop (cdr ps) (car ps)))
          (else (loop (cdr ps) best)))))

(define (preview--nth lst n)
  (cond ((null? lst) #f)
        ((<= n 0) (car lst))
        (else (preview--nth (cdr lst) (- n 1)))))

;; One rendered fragment names many source positions. A two-character code
;; span such as `-b` sits in the file ten times, so the first hit is almost
;; never the one the reader points at: the cursor jumps to the top of the
;; file, and the next key matches the same first hit again. The cursor then
;; stops moving.
;;
;; So the client also counts, on the page, how many times the fragment
;; comes before the one it means (NTH), and names the direction the key
;; moves (DIR: 1 down, -1 up, 0 for a click). Take the NTH source hit.
;; Rendered text and source text differ, so that count can miss; when it
;; misses, or when DIR says the cursor must move and the NTH hit does not
;; move it, take the nearest hit on DIR's side. A down key then always
;; moves down.
;;
;; string-index rejects an empty pattern, so an empty needle answers #f.
(define (preview--hit text before after nth dir from)
  (let ((needle (string-append before after)))
    (if (equal? needle "")
        #f
        (let* ((starts (preview--positions text needle))
               (b (string-byte-length before))
               (hits (map (lambda (i) (+ i b)) starts))
               (want (preview--nth hits nth))
               (ok (and want (or (= dir 0) (if (> dir 0) (> want from) (< want from))))))
          (cond (ok want)
                ((= dir 0) (preview--nearest hits from))
                (else (or (preview--toward hits from dir)
                          (preview--nearest hits from))))))))

;; A click or a visual-line key in a rendered markdown page. The client
;; sends the text node split at the caret, plus the word run around the
;; caret. Rendered text and source differ (markup is stripped, punctuation
;; is smartened), so try the exact node first and the plain word run
;; second; NTH counts the node, WN counts the word run.
(define (preview-goto! win before after wb wa nth wn dir)
  (mouse-select-window! win)
  (set-mark! #f)
  (let* ((text (buffer-text (current-buffer)))
         (from (point))
         (hit (or (preview--hit text before after nth dir from)
                  (preview--hit text wb wa wn dir from))))
    (when hit (goto-char! hit))))
(public! 'preview-goto!
  "(preview-goto! WIN BEFORE AFTER WB WA NTH WN DIR) — put point where a preview click or visual-line key landed"
  'interaction)

(define (preview-select! win before after wb wa nth wn dir)
  (let ((anchor (or (mark) (point))))
    (preview-goto! win before after wb wa nth wn dir)
    (set-mark! anchor)))
(public! 'preview-select!
  "(preview-select! WIN BEFORE AFTER WB WA NTH WN DIR) — extend the region to a rendered position"
  'interaction)

;; Render-only widgets know their exact source ranges. Unlike preview-goto!,
;; these do not need to reverse-map rendered prose into Markdown.
(define (preview-goto-pos! win pos extend)
  (mouse-select-window! win)
  (when extend (unless (mark) (set-mark! (point))))
  (unless extend (set-mark! #f))
  (goto-char! (max 0 (min pos (buffer-size (current-buffer))))))
(public! 'preview-goto-pos!
  "(preview-goto-pos! WIN POS EXTEND) — move to an exact preview source position"
  'interaction)

;; A click on a link in a rendered page. The client never follows the link
;; itself — it sends the href here, and Scheme says what the link means.
;; A link the editor owns reads "compos:VERB/ARGUMENT": a package claims a
;; verb with on-preview-link!, the way it claims a display rule. help.scm
;; claims "def", which opens the source of a name. An ordinary URL opens
;; in the reader.
(define *preview-link-verbs* '())

(define (on-preview-link! verb fn)
  (set! *preview-link-verbs*
    (cons (list verb fn)
          (filter (lambda (e) (not (equal? (car e) verb))) *preview-link-verbs*))))

;; "compos:def/find-file" -> ("def" "find-file"). The argument keeps its own
;; slashes, so a qualified name survives the split.
(define (preview--link-parts href)
  (let* ((body (string-join (cdr (string-split href ":")) ":"))
         (parts (string-split body "/")))
    (list (car parts) (string-join (cdr parts) "/"))))

(define (preview-follow-link! win href)
  (mouse-select-window! win)
  (cond
    ((string-prefix? "compos:" href)
     (let* ((parts (preview--link-parts href))
            (hit (assoc (car parts) *preview-link-verbs*)))
       (if hit
           ((cadr hit) (cadr parts))
           (message (string-append "No handler for " href)))))
    ((and (or (string-prefix? "http://" href) (string-prefix? "https://" href))
          (boundp 'browse))
     (browse href))
    (else (message href))))

(public! 'on-preview-link!
  "(on-preview-link! VERB FN) — claim the compos:VERB/ARG links in a rendered page; FN gets ARG"
  'interaction)
(public! 'preview-follow-link!
  "(preview-follow-link! WIN HREF) — follow a link a reader clicked in a rendered page"
  'interaction)
(catalog-meta! 'function "on-preview-link!" 'domain 'interaction 'effects '(write))
(catalog-meta! 'function "preview-follow-link!" 'domain 'interaction 'effects '(write))

(define-command "newline" "Insert a newline at point" (interactive 'p)
  (lambda (n) (repeat-count n (lambda () (insert! "\n")))))
(define (delete-active-region!)
  (if (and (mark) (< (region-beginning) (region-end)))
      (begin
        (delete-region!)
        (set-mark! #f)
        #t)
      #f))

(define-command "delete-backward-char" "Delete the character before point" (interactive 'p)
  (lambda (n)
    (unless (delete-active-region!) (delete-char! (- n)))))
(define-command "delete-char" "Delete the character after point" (interactive 'p)
  (lambda (n)
    (unless (delete-active-region!) (delete-char! n))))

;;; --- the kill ring: a kill after a kill appends -------------------------------
;;; Emacs: a kill command that follows a kill command grows the newest
;;; entry, so C-k C-k C-k yanks back as one piece. A kill that follows
;;; anything else starts an entry.

(define *kill-commands*
  '("kill-line" "kill-region" "kill-word" "backward-kill-word" "kill-whole-line"
    "kill-sexp" "backward-kill-sexp" "kill-paragraph"))

(define (kill-appends?)
  (and (member (last-command) *kill-commands*) #t))

;; put TEXT on the ring: onto the newest entry after a kill, else as a
;; new entry. BEFORE? puts it in front, for a backward kill.
(define (kill-text! text &optional before?)
  (if (kill-appends?)
      (kill-append! text (if before? #t #f))
      (kill-push! text))
  text)

;; the Emacs names
(define (kill-new text) (kill-push! text))
(define (current-kill n) (kill-nth n))

(define-command "kill-line" "Kill text from point to end of line" (interactive 'p)
  (lambda (n)
    (let loop ((i 0) (acc ""))
      (if (>= i n)
          (if (equal? acc "") #f (kill-text! acc))
          (let ((killed (kill-line!)))
            (if (equal? killed "")
                (if (equal? acc "") #f (kill-text! acc))
                (loop (+ i 1) (string-append acc killed))))))))

(define-command "undo" "Undo the last change" (interactive 'p)
  (lambda (n)
    (let loop ((i 0))
      (when (< i n)
        (if (undo!)
            (loop (+ i 1))
            (message "No further undo information"))))))

;;; --- minibuffer --------------------------------------------------------------
;;; The minibuffer is a real buffer (" *minibuf*"): point motion, kill/yank,
;;; undo and M-DEL all work in prompts for free via the global keymap. Only
;;; prompt-specific behavior is bound here, in its local keymap.

;;; --- the rail: the palette's second list -------------------------------------
;;; A modal prompt can carry a list on the right as well as the left. Only
;;; one of the two holds the keys: <right> steps into the rail, <left>
;;; steps back out, and up/down/RET always mean the list you are standing
;;; in. The prompt owns the rows and what RET does with one; this keeps
;;; the cursor and tells the frame, so the view infers nothing.

(define *mb-rail-rows* '())
(define *mb-rail-index* 0)
(define *mb-rail-focus* #f)
(define *mb-rail-pick* #f)

(define (mb-rail-reset!)
  (set! *mb-rail-rows* '())
  (set! *mb-rail-index* 0)
  (set! *mb-rail-focus* #f)
  (set! *mb-rail-pick* #f))

(define (mb-rail-push!)
  (minibuffer-rail! *mb-rail-rows* *mb-rail-index* *mb-rail-focus*))

;; ROWS is ((LABEL HINT . REST) ...) — the frame reads the first two and
;; carries the rest untouched, so PICK gets back the whole row and the
;; prompt can act on what it put there
(define (mb-rail! rows pick)
  (set! *mb-rail-rows* rows)
  (set! *mb-rail-pick* pick)
  (when (null? rows) (set! *mb-rail-focus* #f))
  (when (>= *mb-rail-index* (length rows)) (set! *mb-rail-index* 0))
  (mb-rail-push!))

(define (mb-rail-focused?) (and *mb-rail-focus* (pair? *mb-rail-rows*)))

(define (mb-rail-enter!)
  (cond ((mb-rail-focused?) #t)
        ((null? *mb-rail-rows*) #f)
        (else (set! *mb-rail-focus* #t) (set! *mb-rail-index* 0) (mb-rail-push!) #t)))

(define (mb-rail-exit!)
  (if (mb-rail-focused?)
      (begin (set! *mb-rail-focus* #f) (mb-rail-push!) #t)
      #f))

(define (mb-rail-move! delta)
  (if (mb-rail-focused?)
      (begin
        (set! *mb-rail-index*
              (max 0 (min (- (length *mb-rail-rows*) 1) (+ *mb-rail-index* delta))))
        (mb-rail-push!)
        #t)
      #f))

(define (mb-rail-confirm!)
  (if (and (mb-rail-focused?) *mb-rail-pick*)
      (begin (*mb-rail-pick* (list-ref *mb-rail-rows* *mb-rail-index*)) #t)
      #f))

(define-command "minibuffer-rail-enter"
  "Move the arrows into the list on the right of the palette"
  (lambda () (if (mb-rail-enter!) #t (run-command "forward-char"))))
(define-command "minibuffer-rail-exit"
  "Leave the list on the right and go back to the candidates"
  (lambda () (if (mb-rail-exit!) #t (run-command "backward-char"))))

(define-command "minibuffer-confirm" "Accept the selected minibuffer candidate"
  (lambda () (if (mb-rail-confirm!) #t (minibuffer-confirm!))))
;; RET takes the candidate. C-RET takes the same candidate with a
;; different verb, and the prompt that cares (the buffer switcher)
;; reads and resets the flag:
;;   RET    go there, move nothing else
;;   C-RET  enter the candidate's context, layout and all
(define *mb-confirm-context* #f)
(define-command "minibuffer-confirm-context"
  "Accept the selected candidate as a context (group) switch"
  (lambda () (set! *mb-confirm-context* #t) (minibuffer-confirm!)))
(define-command "minibuffer-confirm-input" "Accept the minibuffer input exactly as typed"
  (lambda () (minibuffer-confirm-input!)))
(define-command "minibuffer-cancel" "Cancel the minibuffer prompt"
  (lambda () (minibuffer-cancel!)))

;;; The shape is not a different prompt. What you opened as a modal can
;;; finish as the bottom bar and go back, carrying the same input, the same
;;; candidates and the same selection: only the geometry changes. A prompt
;;; that says what its row means (a question) keeps its shape.
;;;
;;; A prompt that stands in front of a LIST changes shape with it. The
;;; table is a window and the prompt is a line, and the two are one
;;; surface: the shape says where that surface is.
;;;
;;;   minibuffer  a DOCK: the bottom rows of the frame, in the flow. The
;;;               window tree shrinks by exactly that much, so the surface
;;;               covers no work and hides nothing. This is the default.
;;;   panel       the same rows, floating over the work. Nothing reflows
;;;               and the work underneath is hidden while you look.
;;;   modal       the centred palette.
;;;
;;; A panel is not a popup window. The popup (display-buffer's 'popup
;;; action, C-\) is a side window a buffer is sent to and lives in; a
;;; panel is a shape a prompt wears for as long as it is open.

(define minibuffer-default-shape "minibuffer")

(define *minibuffer-shapes* '("minibuffer" "panel" "modal"))

;;; --- the dock ------------------------------------------------------------
;;; A dock is a pane of the FRAME. split-root! splits the whole tree, so
;;; the pane spans the frame and every window above keeps its share of
;;; what is left: the surface takes rows rather than covering them. This
;;; is what makes the minibuffer shape a minibuffer and not a panel.
;;;
;;; Splitting the selected window instead gives a pane as wide as whatever
;;; window happened to be selected, which is a sub-pane, not a dock.

(define (window-docked buf)
  (and (buffer-known? buf) (buffer-local buf 'window-dock)))

;; A dock is not a work window. Every rule that keeps the popup out of
;; the layout keeps a dock out too: the tiler must not count it, fill it,
;; or renumber it away, and a display must never land in it.
(define (window-dock? win buf) (and buf (equal? (window-docked buf) win)))

(define (window-dock! buf size)
  (let ((win (split-root! 'v (- 1 size))))
    (when win
      (window-float-class! buf #f)
      (buffer-set-local! buf 'window-dock win)
      (display-buffer-in-window! win buf)
      (select-window! win))
    win))

(define (window-undock! buf)
  (let ((win (window-docked buf)))
    (when (buffer-known? buf) (buffer-set-local! buf 'window-dock #f))
    (and win (window-exists? win) (delete-window-id! win))))

;; BUF's window wears SHAPE. The buffer remembers it, so a display of
;; this buffer takes the shape too, and a shape change moves the surface
;; and nothing else: no mode setup runs, so a table keeps its rows, its
;; filter and the row the reader is on.
(define (window-shape! buf shape)
  (buffer-set-local! buf 'window-shape shape)
  (if (equal? shape "minibuffer")
      (begin
        (when (and (popup-open?) (equal? (window-buffer (popup-window)) buf))
          (popup-dismiss!))
        (window-float-class! buf #f)
        (unless (window-docked buf)
          (window-dock! buf (display-param buf 'size))))
      (begin
        (window-undock! buf)
        (window-float-class! buf
          (if (equal? shape "modal") 'center 'bottom)
          (display-param buf 'size))
        (unless (window-showing buf) (display-buffer buf)))))

;; the list standing behind the prompt takes the shape the prompt takes
(define (mb-list-shape! shape)
  (let ((buf *mb-list-buffer*))
    (when (and buf (buffer-known? buf)) (window-shape! buf shape))))

(define (minibuffer-shape)
  (let* ((st (minibuffer-state))
         (style (and st (plist-get st 'style))))
    (cond ((member style '("modal" "palette")) "modal")
          ((member style '("panel" "popup")) "panel")
          (else "minibuffer"))))

(define (minibuffer-shape-after here)
  (cond ((equal? here "minibuffer") "panel")
        ((equal? here "panel") "modal")
        (else "minibuffer")))

;; The shape of a prompt with a list behind it is the shape of the list:
;; the filter line is one row either way, and what moves is the table.
;; So a filter prompt cycles, and only a question keeps its shape.
(define (minibuffer-list-shape)
  (and *mb-list-buffer*
       (buffer-known? *mb-list-buffer*)
       (let ((side (popup-side-of *mb-list-buffer*)))
         (cond ((equal? side 'center) "modal")
               (side "panel")
               (else "minibuffer")))))

(define-command "minibuffer-cycle-shape"
  "Show this prompt as the bottom bar, the popup, or the modal"
  (lambda ()
    (if (not (minibuffer-active?))
        (message "No prompt")
        (let ((style (plist-get (minibuffer-state) 'style))
              (list-shape (minibuffer-list-shape)))
          (cond
            ((equal? style "question") (message "This prompt keeps its shape"))
            (list-shape
              (let ((next (minibuffer-shape-after list-shape)))
                (mb-list-shape! next)
                (message next)))
            ((equal? style "filter") (message "This prompt keeps its shape"))
            (else
              (let ((next (minibuffer-shape-after (minibuffer-shape))))
                (minibuffer-style! next)
                (message next))))))))
(define-command "minibuffer-next-candidate" "Select the next minibuffer candidate"
  (lambda ()
    (cond ((mb-rail-move! 1) #t)
          ((mb-list-move! 1) #t)
          (else (minibuffer-next!) (mb-select-notify!)))))
(define-command "minibuffer-previous-candidate" "Select the previous minibuffer candidate"
  (lambda ()
    (cond ((mb-rail-move! -1) #t)
          ((mb-list-move! -1) #t)
          (else (minibuffer-prev!) (mb-select-notify!)))))
(define-command "minibuffer-delete-backward" "Delete the character before point"
  (lambda () (minibuffer-del!)))
(define-command "minibuffer-complete"
  "Fold the section at hand in the list behind the prompt, else complete the input"
  (lambda () (if (mb-list-call! 'fold) #t (minibuffer-complete!))))
(define-command "minibuffer-regroup"
  "Cycle what a section is in the list behind the prompt"
  (lambda () (if (mb-list-call! 'regroup) #t (message "no list here"))))
(define-command "minibuffer-next-section"
  "Move to the next section in the list behind the prompt, else the next history entry"
  (lambda () (if (mb-list-section! 1) #t (run-command "next-history-element"))))
(define-command "minibuffer-previous-section"
  "Move to the previous section in the list behind the prompt, else the previous history entry"
  (lambda () (if (mb-list-section! -1) #t (run-command "previous-history-element"))))

;;; --- candidate preview (the consult mechanism) -------------------------------
;;; Emacs previews by hooking SELECTION, not windows: consult registers a
;;; state function that fires as the highlighted candidate changes, shows
;;; it in the window the prompt was invoked from (minibuffer-selected-
;;; window), and restores on quit. Same here: a prompt can register a
;;; select hook; it fires after C-n/C-p and after typing refilters. The
;;; preview itself uses window-preview-buffer!, which never touches the
;;; MRU ring — cancelling leaves history exactly as it was.

(define *mb-select-fn* #f)

(define (mb-select-notify!)
  (when *mb-select-fn*
    (let ((sel (minibuffer-selected)))
      (when sel (*mb-select-fn* sel)))))

;; current-buffer defaults to the minibuffer's OWN text while one is
;; active (the normal case: typing in the minibuffer should act on the
;; minibuffer). A preview callback is the opposite by definition — its
;; whole job is to act on what you're previewing, in the window you
;; invoked it from — so wrap it here, once, rather than trust every
;; future caller to remember set-mb-redirect! for themselves. Forgetting
;; it doesn't error; it just silently moves point in text nobody sees,
;; which is exactly the bug this replaced.
(define (with-invoking-buffer thunk)
  (set-mb-redirect! #f)
  (let ((result (thunk)))
    (set-mb-redirect! #t)
    result))

;; minibuffer-read with live candidate preview: ON-SELECT fires per
;; highlight move, ON-CONFIRM with the choice, ON-CANCEL on C-g (restore
;; whatever the preview displaced there). All three run against the
;; invoking buffer, not the minibuffer's — see with-invoking-buffer.
;; One prompt at a time, as in Emacs without enable-recursive-minibuffers.
;; A prompt that opens while another is up cancels the outer one first,
;; so its cancel handler restores what it displaced, instead of the
;; outer prompt vanishing with its closures.

(define (minibuffer-active?) (if (minibuffer-state) #t #f))

;; what the prompt holds now, "" without a prompt
(define (minibuffer-input)
  (let ((st (minibuffer-state)))
    (if st (plist-get st 'input) "")))

(define (minibuffer-read* prompt cands handlers)
  (when (minibuffer-active?)
    (minibuffer-cancel!)
    (message "Quit the outer prompt"))
  ;; a rail belongs to one prompt: the next one starts without it
  (mb-rail-reset!)
  (let ((r (minibuffer-read*--raw prompt cands handlers)))
    ;; the frame's prompt buffer exists once a prompt has opened in it
    (minibuffer-mode-ensure!)
    r))

;; one interaction model: a completion prompt is the BOTTOM bar, like
;; Emacs — the candidates sit above the input and the input sits on the
;; last row. Only a prompt that asks for "palette" by name floats: the
;; switcher, the command palette, and the LLM config menus.
;;
;; the builtin reads (prompt cands confirm) or (prompt cands complete
;; confirm); this wrapper keeps both shapes
(define (minibuffer-read prompt cands a &optional b)
  (minibuffer-read* prompt cands
    (append
      (list (list 'confirm (if b b a)))
      (if b (list (list 'complete a)) '())
      (list (list 'style #f)))))

;;; --- completing-read ----------------------------------------------------------
;;; Emacs's completing-read, asynchronous: K gets the choice. COLLECTION is
;;; a list of candidates (strings or (label hint) rows) or a procedure of
;;; the input that answers the rows. OPTS is a plist:
;;;   'predicate FN       keep the candidates FN accepts
;;;   'require-match #t   RET takes a candidate only; free text says [No match]
;;;   'initial TEXT       the input to start with
;;;   'default TEXT       the answer to an empty input, listed first
;;;   'history SYM        the history to read and to push the choice on
;;;   'category SYM       the marginalia annotator to use
;;;   'style SYM          how the input matches: flex, substring, prefix, regexp
;;;   'annotate? #f       the rows are annotated already

(define *mb-history-key* #f)          ; the history the active prompt walks
(define *mb-history-pos* -1)          ; -1 is the input, 0 the newest item
(define *mb-history-input* "")        ; what was typed before M-p

(define (completing-read--rows collection input)
  (if (procedure? collection) (collection input) collection))

(define (completing-read--label row) (if (pair? row) (car row) row))

(define (completing-read--prepare rows opts)
  (let* ((pred (plist-get opts 'predicate))
         (kept (if pred (filter (lambda (r) (pred (completing-read--label r))) rows) rows))
         (default (plist-get opts 'default))
         (led (if (and default (member default (map completing-read--label kept)))
                  (cons (let loop ((rs kept))
                          (if (equal? (completing-read--label (car rs)) default) (car rs) (loop (cdr rs))))
                        (filter (lambda (r) (not (equal? (completing-read--label r) default))) kept))
                  kept))
         (hist (plist-get opts 'history))
         (ordered (if (and hist (not (pair? (car (or (and (pair? led) led) '("")))))) (history-order hist led) led))
         (category (plist-get opts 'category)))
    (if (and category (not (equal? (plist-get opts 'annotate?) #f)))
        (annotate category ordered)
        ordered)))

(define (completing-read prompt collection k &rest opts)
  (let* ((hist (plist-get opts 'history))
         (default (plist-get opts 'default))
         (require? (plist-get opts 'require-match))
         (rows (completing-read--prepare (completing-read--rows collection "") opts))
         (labels (lambda () (map completing-read--label
                                (completing-read--prepare
                                  (completing-read--rows collection (minibuffer-input)) opts))))
         (confirm
           (lambda (v)
             (let ((v (if (and default (equal? v "")) default v)))
               (cond ((and require? (not (member v (labels))))
                      (message "[No match]")
                      (apply completing-read (append (list prompt collection k) opts)))
                     (else
                       (when hist (history-push! hist v))
                       (set! *mb-history-key* #f)
                       (k v)))))))
    (set! *mb-history-key* hist)
    (set! *mb-history-pos* -1)
    (minibuffer-read* prompt rows
      (append
        (list (list 'confirm confirm)
              (list 'cancel (lambda () (set! *mb-history-key* #f))))
        (if (procedure? collection)
            (list (list 'change
                        (lambda (input)
                          (minibuffer-set-candidates!
                            (completing-read--prepare (collection input) opts)))))
            '())
        (if (plist-get opts 'initial) (list (list 'initial (plist-get opts 'initial))) '())
        (if (plist-get opts 'style) (list (list 'completion-style (plist-get opts 'style))) '())
        (list (list 'style #f))))))

;; the Emacs readers, each a completing-read of one kind
(define (read-string prompt k &rest opts)
  (apply completing-read (append (list prompt '() k) opts)))

(define (read-number prompt k &rest opts)
  (apply completing-read
    (append (list prompt '()
                  (lambda (v) (let ((n (string->number v))) (k (if (number? n) n 0)))))
            opts)))

(define (read-buffer prompt k &rest opts)
  (apply completing-read (append (list prompt (buffer-list) k 'category 'buffer) opts)))

;; the history ring: M-p walks back through what this prompt was answered
;; with, M-n forward, and past the newest the input comes back
(define (minibuffer-history-step! delta)
  (let ((items (if *mb-history-key* (history-items *mb-history-key*) '())))
    (cond ((null? items) (message "End of history; no default available"))
          (else
            (when (= *mb-history-pos* -1) (set! *mb-history-input* (minibuffer-input)))
            (let ((next (+ *mb-history-pos* delta)))
              (cond ((< next -1) (message "End of history; no default available"))
                    ((>= next (length items)) (message "End of history; no default available"))
                    (else
                      (set! *mb-history-pos* next)
                      (minibuffer-input!
                        (if (= next -1) *mb-history-input* (nth next items))))))))))

(define-command "previous-history-element" "Put the previous history item in the minibuffer"
  (lambda () (minibuffer-history-step! 1)))
(define-command "next-history-element" "Put the next history item in the minibuffer"
  (lambda () (minibuffer-history-step! -1)))

;; y-or-n-p: a question that takes ONE key. "y" runs YES, "n" and C-g
;; run NO, and any other key clears the input, so the question stands
;; until it gets an answer. A question is not a completion prompt: it
;; offers no candidates, so it stays on the bottom bar and it never
;; grows a palette of two words.
;; (read-char-choice PROMPT CHARS K): one key from CHARS, a list of
;; one-character strings; K gets the character. Any other key asks again.
;; C-g cancels and K gets #f.
;; (read-char PROMPT K): the next key, whatever it is; K gets the
;; character, or #f on C-g. A register name is read this way.
(define (read-char prompt k)
  (let ((answer (lambda (ch) (minibuffer-detach!) (k ch))))
    (minibuffer-read* prompt '()
      (list (list 'change
              (lambda (input)
                (when (> (string-length input) 0)
                  (answer (substring input (- (string-length input) 1)
                                     (string-length input))))))
            (list 'confirm (lambda (v) (answer (if (equal? v "") "RET" v))))
            (list 'cancel (lambda () (k #f)))
            (list 'style "question")))))

(define (read-char-choice prompt chars k)
  (let ((answer (lambda (ch) (minibuffer-detach!) (k ch))))
    (minibuffer-read* prompt '()
      (list (list 'change
              (lambda (input)
                (let ((ch (if (> (string-length input) 0)
                              (substring input (- (string-length input) 1) (string-length input))
                              "")))
                  (if (member ch chars)
                      (answer ch)
                      (minibuffer-input! "")))))
            (list 'confirm (lambda (v) (read-char-choice prompt chars k)))
            (list 'cancel (lambda () (k #f)))
            (list 'style "question")))))

;; the Emacs names: K gets #t or #f
(define (y-or-n-p prompt k)
  (y-or-n prompt (lambda () (k #t)) (lambda () (k #f))))

;; a question that takes the word: "yes" or "no", RET after it
(define (yes-or-no-p prompt k)
  (minibuffer-read* (string-append prompt " (yes or no) ") '()
    (list (list 'confirm
            (lambda (v)
              (cond ((equal? v "yes") (k #t))
                    ((equal? v "no") (k #f))
                    (else (message "Please answer yes or no.")
                          (yes-or-no-p prompt k)))))
          (list 'cancel (lambda () (k #f)))
          (list 'style "question"))))

(define (y-or-n prompt yes &optional no)
  (let* ((no (if no no (lambda () #f)))
         ;; the prompt closes BEFORE the answer runs: an answer may ask
         ;; the next question, and two prompts cannot share the bar
         (answer (lambda (k) (lambda () (minibuffer-detach!) (k)))))
    (minibuffer-read* (string-append prompt " (y or n) ") '()
      (list (list 'change
              (lambda (input)
                (cond ((string-suffix? "y" input) ((answer yes)))
                      ((string-suffix? "n" input) ((answer no)))
                      (else (minibuffer-input! "")))))
            ;; RET is not an answer: a question takes y or n and nothing
            ;; else, so RET asks it again. C-g is the way out, and it
            ;; means no.
            (list 'confirm (lambda (v) (y-or-n prompt yes no)))
            (list 'cancel no)
            (list 'style "question")))))

;; MATCH-HINT also matches what you type against the marginalia beside
;; each candidate: #t means the first field, an integer N the first N.
;; STYLE picks the presentation; unset, the palette rule decides.
;; COMPLETE, when given, runs on TAB with (INPUT SELECTED) and can
;; answer (list NEW-INPUT CANDIDATES) to replace the pool.
;; COLLECT, when given, receives the candidate rows left after narrowing.
(define (minibuffer-read-preview prompt cands on-select on-confirm on-cancel
                                 &optional match-hint style complete collect)
  ;; the outer prompt's cancel handler clears *mb-select-fn*, so let it run
  ;; BEFORE this prompt installs its own. minibuffer-read* would quit the
  ;; outer prompt for us, but by then the new hook is already in place and
  ;; the old prompt's teardown takes it away: the new prompt opens with no
  ;; preview and no rail, which is the bug this line prevents.
  (when (minibuffer-active?)
    (minibuffer-cancel!)
    (message "Quit the outer prompt"))
  (set! *mb-select-fn* (lambda (sel) (with-invoking-buffer (lambda () (on-select sel)))))
  (minibuffer-read* prompt cands
    (append
      (list (list 'confirm (lambda (v)
                              (set! *mb-select-fn* #f)
                              (with-invoking-buffer (lambda () (on-confirm v)))))
            (list 'cancel  (lambda ()
                              (set! *mb-select-fn* #f)
                              (with-invoking-buffer on-cancel)))
            (list 'change  (lambda (input) (mb-select-notify!)))
            (list 'match-hint (if match-hint match-hint #f))
            (list 'style style))
      (if complete (list (list 'complete complete)) '())
      (if collect (list (list 'collect collect)) '()))))

;;; --- hooks (Emacs-style, all Scheme) ----------------------------------------
;;; A hook is a name and a list of functions. add-hook! puts a function on
;;; the list once. Give it the NAME of a function, quoted: the name is
;;; looked up when the hook runs, so a reload that redefines the function
;;; changes what runs, and adding the name again is a no-op. A closure is
;;; a fresh value after every reload, so a closure is added again each
;;; time the file loads; prefer the name.
;;;
;;; A hook with LOCAL set lives on the current buffer, and runs before
;;; the global list. run-hooks calls with no arguments; the
;;; run-hook-with-args family carries arguments and stops on the first
;;; success or the first failure, as in Emacs.

(define *hooks* '())                    ; ((HOOK FN ...) ...)
(define *local-hooks* '())              ; ((BUFFER (HOOK FN ...) ...) ...)

(define (hook--alist-get alist key)
  (let ((e (assoc key alist))) (if e (cdr e) '())))

(define (hook--alist-put alist key value)
  (cons (cons key value)
        (filter (lambda (e) (not (equal? (car e) key))) alist)))

(define (hook--global hook) (hook--alist-get *hooks* hook))

(define (hook--set-global! hook fns)
  (set! *hooks* (hook--alist-put *hooks* hook fns)))

(define (hook--local buf hook)
  (hook--alist-get (hook--alist-get *local-hooks* buf) hook))

(define (hook--set-local! buf hook fns)
  (set! *local-hooks*
    (hook--alist-put *local-hooks* buf
      (hook--alist-put (hook--alist-get *local-hooks* buf) hook fns))))

;; a name resolves when the hook runs; an unbound name runs nothing
(define (hook--fn f)
  (cond ((procedure? f) f)
        ((symbol? f) (and (boundp f) (symbol-value f)))
        ((string? f) (hook--fn (string->symbol f)))
        (else #f)))

(define (hook--add fns fn at-end)
  (cond ((member fn fns) fns)
        (at-end (append fns (list fn)))
        (else (cons fn fns))))

(define (hook--remove fns fn)
  (filter (lambda (f) (not (equal? f fn))) fns))

(define (add-hook! hook fn &optional at-end local)
  (if local
      (let ((buf (current-buffer)))
        (hook--set-local! buf hook (hook--add (hook--local buf hook) fn at-end)))
      (hook--set-global! hook (hook--add (hook--global hook) fn at-end)))
  fn)

(define (remove-hook! hook fn &optional local)
  (if local
      (let ((buf (current-buffer)))
        (hook--set-local! buf hook (hook--remove (hook--local buf hook) fn)))
      (hook--set-global! hook (hook--remove (hook--global hook) fn)))
  fn)

;; the functions HOOK runs, in order: the current buffer's, then the global
(define (hook-functions hook)
  (append (hook--local (current-buffer) hook) (hook--global hook)))

(define (run-hook-with-args hook &rest args)
  (for-each (lambda (f)
              (let ((p (hook--fn f)))
                (when p (apply p args))))
            (hook-functions hook))
  #f)

(define (run-hooks &rest hooks)
  (for-each (lambda (h) (run-hook-with-args h)) hooks))

;; the first function that answers a true value ends the run
(define (run-hook-with-args-until-success hook &rest args)
  (let loop ((fs (hook-functions hook)))
    (if (null? fs)
        #f
        (let* ((p (hook--fn (car fs)))
               (v (and p (apply p args))))
          (if v v (loop (cdr fs)))))))

;; the first function that answers #f ends the run
(define (run-hook-with-args-until-failure hook &rest args)
  (let loop ((fs (hook-functions hook)))
    (if (null? fs)
        #t
        (let* ((p (hook--fn (car fs)))
               (v (if p (apply p args) #t)))
          (if v (loop (cdr fs)) #f)))))

;; a client attached a frame: the Elixir side built it fresh, so anything
;; a frame CARRIES for display — the group it stands in, and whatever a
;; package adds later — has to be pushed out again. The client calls this
;; once per mount, inside that frame's input context.
(define (frame-attached!)
  (run-hooks 'frame-attach-hook))

;;; --- variables: a default and a buffer-local value --------------------------
;;; Emacs gives a variable one default and, in a buffer that set it, a
;;; local value. Here a global is a Scheme binding and a buffer-local is a
;;; key in the buffer; these forms tie the two together. variable-value
;;; reads the buffer's value when it has one, else the default, and
;;; variable-set! writes locally when the variable is automatically
;;; buffer-local (defvar-local) and globally otherwise.

(define *automatically-local* '())
(define *variable-docs* '())

(define (variable-doc! name doc)
  (set! *variable-docs* (hook--alist-put *variable-docs* name (list doc)))
  name)

(define (variable-doc name)
  (let ((e (assoc name *variable-docs*))) (and e (cadr e))))

;; (defvar NAME DEFAULT [DOC]): NAME takes DEFAULT unless it is bound
;; already, as in Emacs; a reload keeps the value a session set
(define (defvar name default &optional doc)
  (unless (boundp name) (set-symbol-value! name default))
  (when doc (variable-doc! name doc))
  name)

(define (make-variable-buffer-local! name)
  (unless (member name *automatically-local*)
    (set! *automatically-local* (cons name *automatically-local*)))
  name)

(define (automatically-local? name)
  (and (member name *automatically-local*) #t))

(define (defvar-local name default &optional doc)
  (defvar name default doc)
  (make-variable-buffer-local! name))

(define (default-value name)
  (and (boundp name) (symbol-value name)))

(define (set-default! name value)
  (set-symbol-value! name value)
  value)

;; #t when BUF holds its own value for NAME. A local set to #f reads as
;; absent, as buffer-local answers #f for both.
(define (local-variable-p name &optional buf)
  (let ((e (assoc name (buffer-locals (or buf (current-buffer))))))
    (and e (cadr e) #t)))

(define (buffer-local-value name &optional buf)
  (let* ((b (or buf (current-buffer)))
         (v (buffer-local b name)))
    (if v v (default-value name))))

(define (setq-local! name value)
  (buffer-set-local! (current-buffer) name value)
  value)

(define (kill-local-variable! name &optional buf)
  (buffer-set-local! (or buf (current-buffer)) name #f)
  name)

;; the Emacs variable reference and assignment
(define (variable-value name) (buffer-local-value name))

(define (variable-set! name value)
  (if (automatically-local? name)
      (setq-local! name value)
      (set-default! name value)))

;;; --- folds --------------------------------------------------------------------
;;; Folds are tagged, because a buffer has several fold owners: org folds
;;; headlines, the agent transcript folds tool output, diff-mode folds hunks.
;;; Each owner replaces only its own tag. The display hides the union.
;;;
;;; fold-toggle! is for an owner whose state IS the hidden-range list. An
;;; owner that derives its ranges from something else — org from headline
;;; offsets, agent from (start end open?) triples — toggles its own model
;;; and calls fold-set! with the result.

(define (fold-toggle! buf tag range)
  (let ((cur (fold-get buf tag)))
    (fold-set! buf tag
      (if (member range cur)
          (filter (lambda (r) (not (equal? r range))) cur)
          (cons range cur)))))

;;; --- overlay chrome ----------------------------------------------------------
;;; A chrome attachment draws text the buffer does not hold: a badge, a key
;;; hint, a chip. It stands at one byte, holds zero bytes, and the caret
;;; walks over it. Build one here and put it in an overlay-set! range list
;;; beside the face spans; the renderer draws it as a zero-length island
;;; with the class "chrome-seg CLASS". A before attachment draws ahead of
;;; its byte, an after attachment behind it.

(define (chrome--spec side pos text class click)
  (list pos pos
        (string-append "chrome-" side ":" class ":" (url-encode text)
                       (if click (string-append ":" click) ""))))

(define (chrome-before pos text class &optional click)
  (chrome--spec "b" pos text class click))

(define (chrome-after pos text class &optional click)
  (chrome--spec "a" pos text class click))

(public! 'chrome-before
  "(chrome-before POS TEXT CLASS [CLICK]) — an overlay range that draws TEXT ahead of byte POS as zero-length chrome with the class CLASS; a CLICK id routes through the block-click registry")
(public! 'chrome-after
  "(chrome-after POS TEXT CLASS [CLICK]) — an overlay range that draws TEXT behind byte POS as zero-length chrome with the class CLASS; a CLICK id routes through the block-click registry")

;;; --- the filesystem-change hook ----------------------------------------------
;;; Elixir holds ONE handler (fs-on-change!) and this dispatcher fans it
;;; out over fs-change-hook, whose functions take the root. Keep the handlers small: they schedule a
;;; refresh, they do not do the work. Watch debounces, but a slow handler
;;; still runs once per burst per root.

;; fs-change-hook: (FN ROOT). on-fs-change! is the older spelling.
(define (on-fs-change! fn) (add-hook! 'fs-change-hook fn))

(fs-on-change!
  (lambda (root) (run-hook-with-args 'fs-change-hook root)))

;;; --- marginalia ---------------------------------------------------------------
;;; What a candidate MEANS, beside the candidate. A prompt names the
;;; CATEGORY its candidates belong to; an annotator turns one candidate
;;; into the text next to it. The prompt does not know the annotation and
;;; the annotator does not know the prompt, so a package can annotate a
;;; category it did not write, and every prompt over that category gains
;;; the annotation at once.
;;;
;;;   (marginalia! 'file (lambda (name) (or (auto-mode-for name) "")))
;;;   (annotate 'file (list-dir dir))   ->   ((NAME HINT) ...)
;;;
;;; Three prompts each built their own (LABEL HINT) pairs inline, so a new
;;; prompt over the same things showed nothing. They all call `annotate`
;;; now. The core matches, ranks and confirms on the LABEL alone, so an
;;; annotation changes what you read and never what you get.
;;;
;;; An annotator answers with one string, or with a LIST of fields:
;;;
;;;   (marginalia! 'file (lambda (n) (list (mode n) (size n) (date n))))
;;;
;;; `annotate` measures each field over the whole candidate set and pads
;;; it, so field N lines up with field N on every other row and the
;;; annotation reads as a table. A field that wants its text on the right
;;; (a size) pads itself — the mechanism only makes the columns.

(define *marginalia* '())    ; ((CATEGORY FN) ...)

;; Packages can attach a face to a candidate label. The candidate renderer
;; carries the face without knowing why that name has that color.
(define candidate-face-for (lambda (category name) #f))

(define (marginalia! category fn)
  (set! *marginalia*
    (cons (list category fn)
          (remove (lambda (e) (equal? (car e) category)) *marginalia*))))

(define (marginalia-for category)
  (let ((e (assoc category *marginalia*)))
    (and e (car (cdr e)))))

;; one candidate's fields — a single string is a list of one
(define (marginalia-row f n)
  (let ((v (f n)))
    (cond ((string? v) (list v))
          ((pair? v) v)
          (else '()))))

;; the width of every column, over the whole set. A row with fewer fields
;; than the widest keeps the columns it does not reach.
(define (marginalia-widths rows)
  (fold (lambda (ws r)
          (let loop ((fs r) (old ws) (out '()))
            (if (null? fs)
                (append (reverse out) old)
                (loop (cdr fs)
                      (if (null? old) '() (cdr old))
                      (cons (max (string-length (car fs))
                                 (if (null? old) 0 (car old)))
                            out)))))
        '() rows))

;; a row whose last fields say nothing ends early — padding a column that
;; is empty to the end only makes an annotation out of blanks
(define (marginalia-trim fields)
  (let loop ((fs (reverse fields)))
    (cond ((null? fs) '())
          ((equal? (car fs) "") (loop (cdr fs)))
          (else (reverse fs)))))

;; the fields as the one string the core carries. The last field goes in
;; unpadded: trailing blanks would only pad the end of the line.
(define (marginalia-join fields widths)
  (let loop ((fs fields) (ws widths) (out ""))
    (if (null? fs)
        out
        (let ((txt (if (null? (cdr fs))
                       (car fs)
                       (string-pad-right (car fs) (if (null? ws) 0 (car ws))))))
          (loop (cdr fs)
                (if (null? ws) '() (cdr ws))
                (if (equal? out "") txt (string-append out "  " txt)))))))

;; a category with no annotator hands its candidates back as plain labels
(define (annotate category names)
  (let ((f (marginalia-for category)))
    (if (not f)
        names
        (let* ((rows (map (lambda (n) (marginalia-row f n)) names))
               (ws (marginalia-widths rows)))
          (let loop ((ns names) (rs rows) (out '()))
            (if (null? ns)
                (reverse out)
                (let* ((name (car ns))
                       (hint (marginalia-join (marginalia-trim (car rs)) ws))
                       (face (candidate-face-for category name)))
                  (loop (cdr ns) (cdr rs)
                        (cons (if face
                                  (list name hint "candidate" '() face)
                                  (list name hint))
                              out)))))))))

;;; --- hot reload -------------------------------------------------------------
;;; A save reloads that file's changed top-level forms into this session.
;;; A new definition alone does not reach a buffer that is already open:
;;; the mode setup fn installed the old keys, overlays and folds, and
;;; nothing re-runs it. That is the one reason a mode change used to need
;;; a restart.
;;;
;;; Session.reload_files/1 brackets every reload with these two fns.
;;; reload-begin! opens a record. define-mode and register-minor-mode!
;;; write their name into it. reload-finish! re-runs setup on every live
;;; buffer that wears one of those modes, and on nothing else — a save in
;;; markdown.scm must not rebuild a shell buffer.
;;;
;;; The work is the work desktop restore does, so the same rule holds: a
;;; setup fn rebuilds presentation from the buffer's locals, and stacks
;;; nothing twice.

(domain! 'system)
(effects! '(write))

(define *reloading?* #f)
(define *reload-touched* '())

;; Name a mode this reload defined. Outside a reload this records nothing,
;; so boot pays nothing for it.
(define (reload--touch! name)
  (when *reloading?*
    (set! *reload-touched* (cons name *reload-touched*))))

(define (reload-begin!)
  (set! *reloading?* #t)
  (set! *reload-touched* '())
  #t)

(define (reload-finish!)
  (set! *reloading?* #f)
  (when (boundp (quote apropos-reload-finished!))
    (apropos-reload-finished!))
  (let* ((modes *reload-touched*)
         (bufs (reload--buffers-to-rebuild modes)))
    (set! *reload-touched* '())
    (for-each restore-buffer-runtime! bufs)
    ;; A reload changes what a render would produce, but nothing asks for
    ;; one: a client repaints on an editor event, and evaluating a
    ;; definition is not an event. Without this a new modeline, face, or
    ;; fringe stays on screen exactly as it was until the next keystroke,
    ;; which reads as "the reload did nothing".
    (redraw!)
    (length bufs)))

;; Every buffer in a window, on every frame. A reload names only the modes
;; whose define-mode form changed, and a setup fn calls helpers that the
;; same save can change without touching that form. So rebuild what the
;; person is looking at as well: that is two to five buffers, never the
;; whole buffer list, and it is the difference between a save you can see
;; and a save you cannot. Set this to #f for a session where a mode setup
;; is expensive.
(define *reload-refresh-visible* #t)

(define (reload--visible-buffers)
  (if *reload-refresh-visible*
      (map (lambda (w) (car (cdr w))) (window-list-all))
      '()))

;; The buffers one reload must rebuild: every buffer wearing a mode the
;; reload redefined, plus every visible buffer. Once each, live only.
(define (reload--buffers-to-rebuild modes)
  (let loop ((bs (append (reload--mode-buffers modes) (reload--visible-buffers)))
             (acc '()))
    (cond ((null? bs) (reverse acc))
          ((or (member (car bs) acc) (not (buffer-exists? (car bs))))
           (loop (cdr bs) acc))
          (else (loop (cdr bs) (cons (car bs) acc))))))

;; Does B wear one of MODES, as its major mode or as a minor mode?
(define (buffer-wears-mode? b modes)
  (let loop ((names (cons (buffer-local b 'mode-name)
                          (or (buffer-local b 'minor-modes) '()))))
    (cond ((null? names) #f)
          ((and (car names) (member (car names) modes)) #t)
          (else (loop (cdr names))))))

(define (reload--mode-buffers modes)
  (if (null? modes)
      '()
      (filter (lambda (b)
                (and (buffer-exists? b) (buffer-wears-mode? b modes)))
              (buffer-list))))

;; Re-run mode setup wherever one of MODES is worn. Returns the number of
;; buffers rebuilt. restore-buffer-runtime! is desktop restore's entry: it
;; re-runs the major setup and every minor setup with the buffer current,
;; the layout engine suppressed, and the buffer neither displayed nor
;; selected. So the frame does not move and the point does not jump.
(define (reload-refresh-modes! modes)
  (let ((bs (reload--mode-buffers modes)))
    (for-each restore-buffer-runtime! bs)
    (length bs)))

(domain! 'unknown)
(effects! '(unknown))

;;; --- modes ------------------------------------------------------------------
;;; A major mode = mode-name buffer-local + a setup fn (local keys, vars).
;;; The registry, auto-mode-alist, everything: userland.

(define *mode-setups* '())

;; Replace the entry by name. assoc reads the newest first either way, but
;; a reloader that runs on every save must not grow this list without end.
;; the keymap a mode owns: MODE-map. set-mode! makes it the parent of
;; the buffer's own map, so a binding made once on the mode's map answers
;; in every buffer that wears the mode, and a buffer's own binding wins.
(define (mode-keymap name) (string-append name "-map"))

(define (define-mode name setup)
  (set! *mode-setups*
    (cons (list name setup)
          (remove (lambda (e) (equal? (car e) name)) *mode-setups*)))
  (define-keymap! (mode-keymap name))
  (reload--touch! name)
  ;; every mode is an M-x command, like Emacs, and like Emacs the command
  ;; puts the buffer in the mode; running it again keeps it there. The
  ;; modeline click is the toggle (modeline-toggle-mode!).
  (define-command name (lambda () (major-mode-set! name)))
  (catalog-register! 'mode name "Major mode"
    'use (string-append "(run-command \"" name "\")")))

;; A mode can say which mode it is built from. Emacs writes that into
;; define-derived-mode; here the parent is a fact about the name, so a test
;; asks derived-mode? instead of comparing one string and missing every child.
(define *mode-parents* '())

(define (mode-parent! name parent)
  (set! *mode-parents*
    (cons (list name parent)
          (remove (lambda (e) (equal? (car e) name)) *mode-parents*)))
  ;; the child's map falls back to the parent's
  (keymap-parent! (mode-keymap name) (mode-keymap parent)))

;; (define-derived-mode NAME PARENT SETUP): NAME is PARENT with SETUP on
;; top. Its keymap falls back to PARENT-map, its setup runs PARENT's
;; setup first, and set-mode! runs PARENT-hook before NAME-hook, as
;; Emacs's define-derived-mode does.
(define (define-derived-mode name parent setup)
  (mode-parent! name parent)
  (define-mode name (lambda () (mode-setup! parent) (setup))))

;; the hooks a mode runs, the root's first: fundamental has none
(define (mode-hook-chain name)
  (let loop ((m name) (acc '()) (seen '()))
    (if (or (not m) (member m seen))
        (map (lambda (n) (string->symbol (string-append n "-hook"))) acc)
        (loop (mode-parent m) (cons m acc) (cons m seen)))))

(define (mode-parent name)
  (let ((e (assoc name *mode-parents*))) (and e (cadr e))))

;; #t when MODE is NAME, or descends from it. The walk carries what it has
;; seen, so a parent loop ends instead of hanging the editor.
(define (derived-mode? mode name)
  (let loop ((m mode) (seen '()))
    (cond ((not m) #f)
          ((equal? m name) #t)
          ((member m seen) #f)
          (else (loop (mode-parent m) (cons m seen))))))

(define (buffer-derived-mode? buf name)
  (derived-mode? (buffer-local buf 'mode-name) name))

;; Run another mode's setup. A derived mode inherits the behavior instead
;; of copying it, so the two cannot drift apart.
(define (mode-setup! name)
  (let ((e (assoc name *mode-setups*)))
    (when e ((cadr e)))))

;; What a mode is for, in the mode's own words. describe-mode prints it
;; above the key table. A mode without one still gets its keys.
(define *mode-docs* '())

(define (mode-doc! name doc)
  (set! *mode-docs*
    (cons (list name doc)
          (remove (lambda (e) (equal? (car e) name)) *mode-docs*)))
  (let ((e (catalog-entry 'mode name)))
    (if e
        (catalog-register! 'mode name doc
          'package (string->symbol (catalog--get e 'package))
          'namespace (string->symbol (catalog--get e 'namespace))
          'domain (string->symbol (catalog--get e 'domain))
          'effects (map string->symbol (catalog--get e 'effects))
          'use (string-append "(run-command \"" name "\")"))
        (catalog-register! 'mode name doc))))

(define (mode-doc name)
  (let ((e (assoc name *mode-docs*)))
    (and e (car (cdr e)))))

;;; --- mode icons ---------------------------------------------------------------
;;; One glyph names a mode, and every list that shows a mode shows it:
;;; dired, ibuffer, the buffer prompt and the file prompt. A mode declares
;;; its own icon; a mode that declares none reads as a plain document. An
;;; icon is ONE character: a Nerd Font glyph, or a plain Unicode character
;;; where one says it better — λ names a Scheme file. Never an emoji, which
;;; draws two cells and colours a column that must stay quiet.

(define *mode-icons* '())
(define *default-mode-icon* "")

(define (mode-icon! name icon)
  (set! *mode-icons*
    (cons (list name icon)
          (remove (lambda (e) (equal? (car e) name)) *mode-icons*))))

(define (mode-icon name)
  (let ((e (and name (assoc name *mode-icons*))))
    (if e (car (cdr e)) *default-mode-icon*)))

;; the icon a buffer wears is its mode's
(define (buffer-icon b)
  (mode-icon (buffer-local b 'mode-name)))

;; the icon a file NAME wears is the icon of the mode it would open in. A
;; directory opens in Dired, and a listing marks one with a trailing "/".
(define (file-icon name)
  (if (string-suffix? "/" name)
      (mode-icon "Dired")
      (mode-icon (auto-mode-for name))))

;; a mode name with its icon in front, for a column that shows the mode
(define (mode-label name)
  (string-append (mode-icon name) " " (or name "Fundamental")))

;; the modes this file defines. A package stamps its own icons.
(mode-icon! "Dired" "")
(mode-icon! "text-mode" "")
(mode-icon! "scheme-mode" "λ")
(mode-icon! "elixir-mode" "")
(mode-icon! "json-mode" "")
(mode-icon! "rust-mode" "")
(mode-icon! "html-mode" "")
(mode-icon! "chat-mode" "")
(mode-icon! "shell-mode" "")
(mode-icon! "term-mode" "")
(mode-icon! "comint-shell-mode" "")
(mode-icon! "tail-mode" "")
(mode-icon! "collect-mode" "")


;;; --- mode link syntax ---------------------------------------------------------
;;; How a mode writes a link to a file: Markdown writes [LABEL](PATH), Org
;;; writes [[file:PATH][LABEL]]. A mode declares its own syntax, and a child
;;; mode inherits its parent's. A mode that declares none writes the path
;;; alone, which is a link in every buffer (goto-address.scm).

(define *mode-link-syntaxes* '())

(define (mode-link-syntax! name fn)
  (set! *mode-link-syntaxes*
    (cons (list name fn)
          (remove (lambda (e) (equal? (car e) name)) *mode-link-syntaxes*))))

;; the syntax of MODE or of its nearest ancestor: (lambda (PATH LABEL) TEXT),
;; or #f when the mode writes the path alone
(define (mode-link-syntax mode)
  (let loop ((m mode) (seen '()))
    (cond ((or (not m) (member m seen)) #f)
          ((assoc m *mode-link-syntaxes*) (cadr (assoc m *mode-link-syntaxes*)))
          (else (loop (mode-parent m) (cons m seen))))))

(define (set-mode! name)
  (let* ((buf (current-buffer))
         (old (buffer-local buf 'mode-name))
         (changed (and old (not (equal? old name)))))
    (when changed (run-hooks 'change-major-mode-hook))
    ;; a change of major mode starts the buffer's own map afresh, as
    ;; use-local-map does in Emacs. The mode's setup puts its keys back,
    ;; and the minor modes put theirs back after it.
    (when changed
      (clear-local-map! buf)
      ;; Semantic projections belong to the old mode; the new setup rebuilds them.
      (for-each (lambda (key) (buffer-set-local! buf key #f))
                '(render-root render-text-root render-records)))
    (define-keymap! (mode-keymap name))
    (use-local-map! buf (mode-keymap name))
    (buffer-set-local! buf 'mode-name name)
    (let ((m (assoc name *mode-setups*)))
      (if m ((cadr m))))
    (when changed (restore-minor-modes! buf))
    ;; a mode with font-lock keywords is painted from here on
    (when (pair? (font-lock-keywords name)) (font-lock-enable! buf))
    ;; the parent's hook runs before the child's, as in Emacs
    (apply run-hooks (mode-hook-chain name))
    (run-hooks 'after-change-major-mode-hook)
    ;; the mode is on: if it declares a layout, the engine arranges the frame
    (layout-enter! buf)))

;; the M-x form of a major mode: enter it, and say so. Running it in a
;; buffer that wears the mode already keeps the mode.
(define (major-mode-set! name)
  (set-mode! name)
  (message (string-append name " on")))

;;; --- kill-all-local-variables ---------------------------------------------------
;;; Emacs forgets a buffer's locals when the major mode changes, and keeps
;;; the ones marked permanent-local. Here a local can hold what a buffer
;;; IS (a chat's identity, its file), so set-mode! does not call this. It
;;; is the mechanism for a mode or a command that wants a clean buffer.

(define *permanent-locals* '(mode-name minor-modes))

(define (permanent-local! name)
  (unless (member name *permanent-locals*)
    (set! *permanent-locals* (cons name *permanent-locals*))))

(define (permanent-local? name)
  (or (member name *permanent-locals*)
      (and (boundp 'chat-identity-locals) (member name chat-identity-locals))))

;; forget every local that is not permanent, and the buffer's own keys
(define (kill-all-local-variables! buf)
  (for-each
    (lambda (entry)
      (unless (permanent-local? (car entry))
        (buffer-set-local! buf (car entry) #f)))
    (buffer-locals buf))
  (clear-local-map! buf)
  buf)

;; desktop restore's entry: set BUF's mode with BUF current, so the setup
;; fn rebuilds presentation from the locals restore already laid down.
;; The desktop restores its own saved windows, so the layout engine stands
;; down for the whole call.
(define (desktop-apply-mode! buf mode)
  (with-layout-suppressed
    (lambda ()
      (with-current-buffer buf (lambda () (set-mode! mode)))
      ;; The compact dashboard is derived state. Rebuild it during restore so
      ;; a saved desktop shows it before the first command runs.
      (when (boundp (quote dashboard--sync!))
        (dashboard--sync! buf)))))

;;; --- globals that outlive a restart (savehist) ---------------------------------
;;; The desktop saves buffers, windows and buffer-locals. A global was
;;; simply lost: the minibuffer history is a global, so every restart
;;; threw away which commands you use and M-x fell back to alphabetical.
;;;
;;; A variable joins by naming itself once. GET answers with the value to
;;; write; PUT receives it back after a restore. Only the VALUE travels,
;;; so the two closures stay here — a closure in the desktop file restores
;;; as a dangling frame and cannot be called.
;;;
;;;   (persist-global! 'my-thing (lambda () *my-thing*)
;;;                              (lambda (v) (set! *my-thing* v)))
;;;
;;; RULE: the variable behind a persisted global uses defvar, never define.
;;; A reload re-evaluates a top-level define and puts the literal back, so
;;; the live value becomes '() while the daemon runs. The next desktop save
;;; then writes that '() over the good file, and the state is gone for real.
;;; defvar binds only when the name is free, so a reload keeps the value.
;;; A state fn that derives its value from live frames or buffers, as
;;; layout-targets-state does, holds no such variable and needs nothing.

(define *desktop-globals* '())   ; ((KEY GET PUT CLEAR) ...)

(define (persist-global! key get put)
  (let* ((old (assoc key *desktop-globals*))
         (initial (get))
         ;; A package reload re-registers the variable after it changed.
         ;; Keep the first reset closure instead of adopting that live value.
         (reset (if old
                    (car (cdr (cdr (cdr old))))
                    (lambda () (put initial)))))
    (set! *desktop-globals*
      (cons (list key get put reset)
            (remove (lambda (e) (equal? (car e) key)) *desktop-globals*)))))

;; what the desktop writes
(define (desktop-globals)
  (map (lambda (e) (list (car e) ((cadr e)))) *desktop-globals*))

;; what the desktop hands back. A key nobody claims any more is dropped,
;; so a desktop file written by an older editor still boots.
(define (desktop-globals! saved)
  (for-each
    (lambda (e)
      (let ((hit (assoc (car e) saved)))
        (when hit ((car (cdr (cdr e))) (cadr hit)))))
    *desktop-globals*))

(define (desktop-globals-clear!)
  (for-each
    (lambda (e) ((car (cdr (cdr (cdr e))))))
    *desktop-globals*))

;; desktop-clear follows Emacs: remove every non-internal buffer and reset
;; the globals that ride in the desktop. Each modified file gets one question.
;; A saves all remaining files. N explicitly discards all remaining edits.
(define (desktop-clear--finish kept members)
  (let ((doomed (filter (lambda (b) (not (member b kept))) members)))
    (desktop-globals-clear!)
    (for-each
      (lambda (b)
        (when (process-running? b) (process-kill! b))
        (buffer-kill! b))
      doomed)
    (message
      (string-append "Cleared desktop: "
                     (number->string (length doomed)) " buffers"
                     (if (pair? kept)
                         (string-append "; kept "
                                        (number->string (length kept))
                                        " unsaved")
                         "")))))

(define (desktop-clear--save-all dirty members)
  (for-each save-buffer-named! dirty)
  (desktop-clear--finish '() members))

(define (desktop-clear--ask-save dirty kept members)
  (if (null? dirty)
      (desktop-clear--finish kept members)
      (let ((b (car dirty)))
        (read-char-choice
          (string-append "Save " b "? (y, n, A all, N none) ")
          '("y" "n" "A" "N")
          (lambda (ch)
            (cond ((equal? ch "y")
                   (save-buffer-named! b)
                   (desktop-clear--ask-save (cdr dirty) kept members))
                  ((equal? ch "n")
                   (desktop-clear--ask-save (cdr dirty) (cons b kept) members))
                  ((equal? ch "A") (desktop-clear--save-all dirty members))
                  ((equal? ch "N") (desktop-clear--finish '() members))
                  (else #f)))))))

(domain! 'desktop)
(effects! '(destroy))

(define-command "desktop-clear"
  "Empty the desktop, asking whether to save each modified file"
  (lambda ()
    (let* ((members (buffer-list-mru))
           (dirty (filter
                    (lambda (b)
                      (and (buffer-path b) (buffer-modified? b)))
                    members)))
      (desktop-clear--ask-save dirty '() members))))

;; The way back from a boot that brought the windows back and lost the
;; groups. It reads one desktop file and installs only the globals: the
;; group records, the graveyard, the histories. The windows do not move.
;; ~/.compos/desktop-backups holds a copy every ten minutes.
(define-command "desktop-read-globals"
  "Install the globals of a desktop file, leaving the windows alone"
  (lambda ()
    (read-file-name "Desktop file: "
      (lambda (file)
        (let ((globals (desktop-file-globals file)))
          (desktop-globals! globals)
          (desktop-dirty!)
          (message (string-append "Read " (number->string (length globals))
                                  " globals from " file)))))))

(catalog-meta! 'command "desktop-read-globals" 'domain 'desktop 'effects '(read write))

(domain! 'unknown)
(effects! '(unknown))

;;; --- minor modes --------------------------------------------------------------
;;; A minor mode = its name in the buffer-local 'minor-modes list + an
;;; idempotent setup fn taking the buffer. Desktop restore re-runs the
;;; setup (restore-minor-modes!) after locals come back, the same way
;;; set-mode! re-runs major-mode setup — so setup fns must rebuild
;;; presentation from the locals they find, never stack hooks twice.

(define *minor-mode-setups* '())   ; (name setup teardown keymap)

;; KEYMAP, when given, is the name of a keymap the mode owns. While the
;; mode is on in a buffer, that map answers ahead of the buffer's own map
;; and the major mode's, and turning the mode off takes it away, as
;; minor-mode-map-alist does in Emacs.
(define (register-minor-mode! name setup &optional teardown keymap)
  (when keymap (define-keymap! keymap))
  (set! *minor-mode-setups*
    (cons (list name setup teardown keymap)
          (remove (lambda (e) (equal? (car e) name)) *minor-mode-setups*)))
  (reload--touch! name))

(define (minor-mode-keymap name)
  (let ((m (assoc name *minor-mode-setups*)))
    (and m (> (length m) 3) (nth 3 m))))

;; give a registered minor mode its keymap after the fact
(define (minor-mode-keymap! name map)
  (define-keymap! map)
  (let ((m (assoc name *minor-mode-setups*)))
    (when m
      (set! *minor-mode-setups*
        (cons (list name (nth 1 m) (nth 2 m) map)
              (remove (lambda (e) (equal? (car e) name)) *minor-mode-setups*))))))

;; (mode-keys! MODE ((KEYS COMMAND) ...)): bind once on MODE's map, at
;; load; every buffer that wears the mode answers, and a buffer's own
;; binding still wins
(define (mode-keys! mode pairs)
  (define-keymap! (mode-keymap mode))
  (for-each (lambda (p) (define-key (mode-keymap mode) (car p) (cadr p))) pairs)
  mode)

;; (minor-mode-keys! NAME ((KEYS COMMAND) ...)): the minor mode's map,
;; NAME-map, in force while the mode is on and gone when it is off
(define (minor-mode-keys! name pairs)
  (let ((map (string-append name "-map")))
    (minor-mode-keymap! name map)
    (for-each (lambda (p) (define-key map (car p) (cadr p))) pairs)
    map))

;; the mode's map joins the buffer's minor maps, first
(define (minor-mode--attach-map! buf name)
  (let ((map (minor-mode-keymap name)))
    (when map
      (buffer-minor-maps! buf
        (cons map (remove (lambda (m) (equal? m map)) (buffer-minor-maps buf)))))))

(define (minor-mode--detach-map! buf name)
  (let ((map (minor-mode-keymap name)))
    (when map
      (buffer-minor-maps! buf
        (remove (lambda (m) (equal? m map)) (buffer-minor-maps buf))))))

(define (minor-mode-on? buf name)
  (let ((ms (buffer-local buf 'minor-modes)))
    (if (and ms (member name ms)) #t #f)))

(define (enable-minor-mode! buf name)
  (let ((cur (or (buffer-local buf 'minor-modes) '())))
    (unless (member name cur)
      (buffer-set-local! buf 'minor-modes (cons name cur))))
  (minor-mode--attach-map! buf name)
  (let ((m (assoc name *minor-mode-setups*)))
    (if m ((cadr m) buf)))
  ;; NAME-hook runs in the buffer, as a minor mode's hook does in Emacs
  (with-current-buffer buf
    (lambda () (run-hooks (string->symbol (string-append name "-hook")))))
  ;; the setup fn named the buffers its layout wants; now place them
  (layout-enter! buf))

(define (disable-minor-mode! buf name)
  (buffer-set-local! buf 'minor-modes
    (remove (lambda (n) (equal? n name))
            (or (buffer-local buf 'minor-modes) '())))
  (minor-mode--detach-map! buf name)
  (let ((m (assoc name *minor-mode-setups*)))
    (if (and m (caddr m)) ((caddr m) buf))))

(define (toggle-minor-mode! name)
  (let ((buf (current-buffer)))
    (if (minor-mode-on? buf name)
        (begin (disable-minor-mode! buf name) #f)
        (begin (enable-minor-mode! buf name) #t))))

;;; --- globalized minor modes ---------------------------------------------------
;;; (define-globalized-minor-mode! GLOBAL LOCAL ELIGIBLE?): the command
;;; GLOBAL turns LOCAL on in every buffer ELIGIBLE? accepts, now and as
;;; buffers appear, and off everywhere. Emacs's define-globalized-minor-mode.

(define *globalized-minor-modes* '())   ; ((global local eligible? on?) ...)

(define (globalized-minor-mode-on? global)
  (let ((e (assoc global *globalized-minor-modes*)))
    (and e (nth 3 e))))

(define (globalized-minor-mode--set! global on?)
  (let ((e (assoc global *globalized-minor-modes*)))
    (when e
      (set! *globalized-minor-modes*
        (cons (list global (nth 1 e) (nth 2 e) on?)
              (remove (lambda (x) (equal? (car x) global)) *globalized-minor-modes*))))))

(define (globalized-minor-mode--apply! e buf)
  (let ((local (nth 1 e)) (eligible? (nth 2 e)))
    (when (and (eligible? buf) (not (minor-mode-on? buf local)))
      (enable-minor-mode! buf local))))

(define (globalized-minor-mode-on! global)
  (globalized-minor-mode--set! global #t)
  (let ((e (assoc global *globalized-minor-modes*)))
    (when e (for-each (lambda (b) (globalized-minor-mode--apply! e b)) (buffer-list)))))

(define (globalized-minor-mode-off! global)
  (globalized-minor-mode--set! global #f)
  (let ((e (assoc global *globalized-minor-modes*)))
    (when e
      (for-each (lambda (b)
                  (when (minor-mode-on? b (nth 1 e))
                    (disable-minor-mode! b (nth 1 e))))
                (buffer-list)))))

;; a buffer that appears while a globalized mode is on gets the mode
(define (globalized-minor-mode--new-buffer! name)
  (for-each (lambda (e) (when (nth 3 e) (globalized-minor-mode--apply! e name)))
            *globalized-minor-modes*))

(define (globalized-minor-mode--find-file-hook!)
  (globalized-minor-mode--new-buffer! (current-buffer)))

(add-hook! 'buffer-created-hook 'globalized-minor-mode--new-buffer!)
(add-hook! 'find-file-hook 'globalized-minor-mode--find-file-hook!)

(define (define-globalized-minor-mode! global local eligible? &optional doc)
  (set! *globalized-minor-modes*
    (cons (list global local eligible? (globalized-minor-mode-on? global))
          (remove (lambda (x) (equal? (car x) global)) *globalized-minor-modes*)))
  (define-command global (or doc (string-append "Toggle " local " in every buffer"))
    (lambda ()
      (if (globalized-minor-mode-on? global)
          (begin (globalized-minor-mode-off! global)
                 (message (string-append global " disabled")))
          (begin (globalized-minor-mode-on! global)
                 (message (string-append global " enabled")))))))

;; Fundamental, the state a buffer has before any mode claims it. Nothing
;; remembers the mode you left, as in Emacs. normal-mode reads the file
;; name again and the mode comes back. The echo area states each result.

(define (major-mode-off! buf name)
  (buffer-set-local! buf 'render-mode #f)
  (buffer-set-local! buf 'preview-renderer #f)
  ;; the grammar is the mode's: no mode, no colours
  (buffer-set-local! buf 'ts-lang #f)
  (buffer-set-read-only! buf #f)
  (buffer-set-local! buf 'mode-name #f))

;; Emacs's normal-mode: the mode the file name asks for, applied again.
(define-command "normal-mode"
  "Set the major mode the buffer's file name asks for"
  (lambda ()
    (let* ((buf (current-buffer))
           (path (buffer-path buf))
           (m (and path (auto-mode-for path))))
      (if m
          (begin (set-mode! m) (message (string-append m " on")))
          (message "no mode for this buffer")))))

;;; --- global-mode-string ------------------------------------------------------
;;; The segments at the right edge of the frame modeline, as Emacs's
;;; global-mode-string. A package owns one segment by key. A segment is a
;;; string, a (FACE-CLASS TEXT) pair, or a thunk that returns one of those;
;;; #f or "" removes it. The registry composes every segment into the
;;; frame's extra text; the client draws one span per segment.

(define *global-mode-string* '()) ; ((key value) ...) in insertion order

(define (global-mode-string--segment value)
  (let ((v (if (procedure? value) (value) value)))
    (cond ((and (string? v) (not (equal? v ""))) (list "ml-segment" v))
          ((and (pair? v) (string? (cadr v)) (not (equal? (cadr v) ""))) (list (car v) (cadr v)))
          (else #f))))

(define (global-mode-string-segments)
  (filter (lambda (x) x)
          (map (lambda (e) (global-mode-string--segment (cadr e))) *global-mode-string*)))

(define (global-mode-string-refresh!)
  (set-modeline-extra! (global-mode-string-segments)))

(define (global-mode-string-set! key value)
  (let ((rest (remove (lambda (e) (equal? (car e) key)) *global-mode-string*)))
    (set! *global-mode-string*
      (if (or (not value) (equal? value ""))
          rest
          (append rest (list (list key value)))))
    (global-mode-string-refresh!)))

(define (global-mode-string-remove! key)
  (global-mode-string-set! key #f))

(define (modeline-toggle-mode! name)
  (let* ((buf (current-buffer))
         (major (or (buffer-local buf 'mode-name) "Fundamental")))
    (cond
      ;; a minor mode toggles in place. A name that is both is a major
      ;; mode here, because its own command would call this back forever.
      ((and (assoc name *minor-mode-setups*) (not (assoc name *mode-setups*)))
       (if (member name (command-names))
           (run-command name)
           (toggle-minor-mode! name))
       (message (string-append name
                               (if (minor-mode-on? buf name)
                                   " enabled"
                                   " disabled"))))
      ;; the buffer is in another mode: enter this one
      ((not (equal? name major))
       (set-mode! name)
       (message (string-append name " on")))
      ;; Fundamental is no mode: there is nothing to leave, so read the
      ;; file name again. This is the way back for a file buffer.
      ((equal? major "Fundamental")
       (run-command "normal-mode"))
      (else
        (major-mode-off! buf name)
        (message (string-append name " off"))))))

;; the minor maps live in the editor, not in the locals: put them back
;; with the setup
(define (restore-minor-modes! buf)
  (for-each
    (lambda (name)
      (minor-mode--attach-map! buf name)
      (let ((m (assoc name *minor-mode-setups*)))
        (if m ((cadr m) buf))))
    (reverse (or (buffer-local buf 'minor-modes) '()))))

;; #t while a wake rebuilds a buffer's runtime. A wake is not an open:
;; the switcher previews a dormant buffer by re-running its mode setup,
;; and a list whose rows come from the network must not pay that fetch
;; inside a preview. list-mode-init! reads this.
(define *buffer-waking* #f)

(define (with-buffer-waking thunk)
  (let ((was *buffer-waking*))
    (set! *buffer-waking* #t)
    (let ((r (thunk)))
      (set! *buffer-waking* was)
      r)))

;; A dormant buffer wakes with literal persisted locals but none of the
;; runtime machinery those locals describe. Re-run both setup layers with a
;; logical current buffer: restoration must not display or select BUF.
(define (restore-buffer-runtime! buf)
  (with-layout-suppressed
    (lambda ()
      (with-current-buffer buf
        (lambda ()
          (with-buffer-waking
            (lambda ()
              (let ((mode (buffer-local buf 'mode-name)))
                (when mode (set-mode! mode)))
              (restore-minor-modes! buf)
              ;; a restored popup floats still, so its move keys come back
              (when (popup--class? buf) (popup-keys! buf #t))))))))
  ;; The modeline is derived state. Rebuild it here so a restored desktop
  ;; shows its top line and its short name before the first command runs.
  (when (boundp (quote dashboard--sync!))
    (dashboard--sync! buf))
  ;; The buffer is whole again, so an owner can act on it. Outside
  ;; with-buffer-waking on purpose: that flag is restored by hand, and a
  ;; hook that throws inside it would leave every later wake believing it
  ;; was still waking.
  (buffer-woken! buf))

;;; Visual lines are a buffer capability, independent of the major mode.
;;; This minor mode owns the durable flag. The client measures where the
;;; rendered rows begin and reports the byte offsets per window, tagged
;;; with the buffer version it measured: the wrap map. The client cannot
;;; know what a key means on those rows; that is decided here.

(domain! 'interaction)
(effects! '(write))

(define (visual-line-mode--apply! buf)
  (buffer-set-local! buf 'visual-line-mode #t))

(define (visual-line-mode--teardown! buf)
  (buffer-set-local! buf 'visual-line-mode #f)
  (buffer-set-local! buf 'visual-goal #f))

(register-minor-mode!
  "visual-line-mode"
  visual-line-mode--apply!
  visual-line-mode--teardown!)

(define-command "visual-line-mode" "Toggle visual-row motion in the current buffer"
  (lambda ()
    (if (toggle-minor-mode! "visual-line-mode")
        (message "Visual line mode enabled")
        (message "Visual line mode disabled"))))

(mode-doc! "visual-line-mode"
  "Wrap long logical lines and make vertical motion follow rendered rows.")

;; The rows the client measured for the active window, when the mode is
;; on and the map is as new as the buffer. A map from an older version
;; names rows that moved, so the caller moves by source line instead, and
;; the measure after the next paint repairs it. A key never waits.
(define (visual-rows buf)
  (and (equal? (buffer-local buf 'visual-line-mode) #t)
       (let ((m (window-wrap-map (active-window))))
         (and m
              (equal? (car m) (buffer-version buf))
              (cadr m)))))

;; the end of the source line holding POS: the byte before its newline
(define (visual--line-end pos)
  (let* ((n (line-number-at-pos pos))
         (next (line-start-position (+ n 1))))
    (if (> next pos) (- next 1) (buffer-size (current-buffer)))))

;; The row holding POS: (START NEXT), NEXT being where the row below
;; begins, or #f for the last measured row. #f when POS is above every
;; measured row, or below the last one's source line.
(define (visual-row-bounds rows pos)
  (let loop ((rs rows) (start #f))
    (cond ((null? rs)
           (and start (<= pos (visual--line-end start)) (list start #f)))
          ((> (car rs) pos)
           (and start (list start (car rs))))
          (else (loop (cdr rs) (car rs))))))

;; the byte before POS, as a one-byte string; "" at the buffer start
(define (visual--byte-before pos)
  (if (> pos 0) (buffer-substring (- pos 1) pos) ""))

;; Where the row that begins at START ends. The row below begins at NEXT,
;; and the byte before NEXT is what the browser wrapped at. A space or a
;; newline there is not something the reader sees on this row, so the row
;; ends before it; a paragraph break is two newlines, and both stay off.
;; A row with nothing measured below it runs to the end of its source line.
(define (visual-row-end-from start next)
  (if (not next)
      (visual--line-end start)
      (let* ((b (visual--byte-before next))
             (q (if (and (> next start) (or (equal? b " ") (equal? b "\n")))
                    (- next 1)
                    next)))
        (let loop ((q q))
          (if (and (> q start) (equal? (visual--byte-before q) "\n"))
              (loop (- q 1))
              q)))))

(define (visual--row-before rows start)
  (let loop ((rs rows) (prev #f))
    (cond ((null? rs) #f)
          ((= (car rs) start) prev)
          (else (loop (cdr rs) (car rs))))))

(define (visual-row-start pos)
  (let ((rows (visual-rows (current-buffer))))
    (and rows
         (let ((b (visual-row-bounds rows pos)))
           (and b (car b))))))
(public! 'visual-row-start
  "(visual-row-start POS) — the byte offset the visual row holding POS begins at; #f when the wrap map cannot say")

(define (visual-row-end pos)
  (let ((rows (visual-rows (current-buffer))))
    (and rows
         (let ((b (visual-row-bounds rows pos)))
           (and b (visual-row-end-from (car b) (cadr b)))))))
(public! 'visual-row-end
  "(visual-row-end POS) — the byte offset the visual row holding POS ends at; #f when the wrap map cannot say")

;; The column a run of vertical moves holds, in characters from the row
;; start. It lives while point stands where the last move left it: any
;; other move, horizontal or a click, starts the column afresh.
(define (visual--goal buf start pos)
  (let ((g (buffer-local buf 'visual-goal)))
    (if (and g (equal? (car g) pos))
        (cadr g)
        (string-length (buffer-substring start pos)))))

(define (visual--land! buf start end goal)
  (let* ((text (buffer-substring start end))
         (n (min goal (string-length text)))
         (pos (+ start (string-byte-length (substring text 0 n)))))
    (goto-char! pos)
    (buffer-set-local! buf 'visual-goal (list pos goal))
    pos))

;; extending keeps the anchor, or starts a region at point; a plain move
;; clears the mark, as a click does
(define (visual--mark! extend)
  (if extend
      (unless (mark) (set-mark! (point)))
      (set-mark! #f)))

;; An editable surface asks the browser's own layout to move: it knows
;; where every row wraps, so no map is measured or kept for it. A
;; rendered page and a read-only buffer keep the wrap map.
(define (visual--client? buf)
  (and (equal? (buffer-local buf 'visual-line-mode) #t)
       (not (buffer-read-only? buf))
       ;; a client that has reported its caret is there to answer; a
       ;; headless buffer keeps the server's own motion
       (equal? (buffer-local buf 'client-caret) #t)
       ;; a window that measured a map, fresh or stale, draws a page that
       ;; measures; an editable surface never sends one
       (not (window-wrap-map (active-window)))
       ;; only the plain text view is an editable surface; a rendered page,
       ;; a block view, a transcript, and a terminal draw something else
       (not (member (buffer-local buf 'render-mode)
                    '("markdown" "html" "app" "blocks" "agent" "terminal")))))

(define (visual--client-move! alter dir granularity &optional count)
  (client-select! alter (if (< dir 0) "backward" "forward") granularity (or count 1))
  #t)

;; one measured row, from wherever point is now
(define (visual--row-step! buf rows dir extend)
  (let* ((pos (point))
         (here (visual-row-bounds rows pos)))
    (and here
         (let* ((start (car here))
                (goal (visual--goal buf start pos))
                (target (if (> dir 0) (cadr here) (visual--row-before rows start))))
           (and target
                (let ((there (visual-row-bounds rows target)))
                  (visual--mark! extend)
                  (visual--land! buf (car there)
                                 (visual-row-end-from (car there) (cadr there))
                                 goal)
                  #t))))))

;; COUNT rows up or down, holding the goal column; one row by default.
;; #f when the map cannot answer: the mode is off, the map is stale, or
;; no measured row lies that way. The caller then moves by source line.
;;
;; COUNT is one call, never a loop of calls. The browser answers a whole
;; page in one request; asking it COUNT times does not work, because a
;; frame keeps ONE pending request and each ask overwrites the last, so a
;; page moved one row.
(define (visual-row-move! dir extend &optional count)
  (let* ((buf (current-buffer))
         (n (max 1 (or count 1)))
         (rows (visual-rows buf)))
    ;; a fresh map answers first (a rendered page measures one; so does a
    ;; test); an editable surface measures none and asks the browser
    (if (and (not rows) (visual--client? buf))
        (visual--client-move! (if extend "extend" "move") dir "line" n)
        (and rows
             (let loop ((i 0) (moved #f))
               (if (>= i n)
                   moved
                   (if (visual--row-step! buf rows dir extend)
                       (loop (+ i 1) #t)
                       moved)))))))

;; the edge of the row point is on; #f when the map cannot answer
(define (visual-row-edge! dir extend)
  (let* ((buf (current-buffer))
         (rows (visual-rows buf)))
    (if (and (not rows) (visual--client? buf))
        (visual--client-move! (if extend "extend" "move") dir "lineboundary")
    (and rows
         (let ((here (visual-row-bounds rows (point))))
           (and here
                (begin
                  (visual--mark! extend)
                  (goto-char! (if (< dir 0)
                                  (car here)
                                  (visual-row-end-from (car here) (cadr here))))
                  #t)))))))

;; The motions the commands run. Each moves by visual row when the wrap
;; map can answer, and by source line otherwise, so a plain buffer moves
;; as it always did. EXTEND grows the region instead of clearing it.
(define (visual-next-line! &optional extend)
  (or (visual-row-move! 1 extend) (next-line!)))

;; The browser reached the edge of the rendered slice, not of the buffer.
;; Cross that source-line boundary in the buffer; redisplay supplies the
;; next slice, where native wrapped-line motion can continue.
(define (visual-edge-move! dir extend count)
  (visual--mark! extend)
  (repeat-count count (if (< dir 0) previous-line! next-line!))
  (recenter!))

(public! 'visual-edge-move!
  "(visual-edge-move! DIR EXTEND COUNT) — cross a rendered text slice boundary by source lines")
(define (visual-previous-line! &optional extend)
  (or (visual-row-move! -1 extend) (previous-line!)))
(define (visual-beginning-of-line! &optional extend)
  (or (visual-row-edge! -1 extend) (beginning-of-line!)))
(define (visual-end-of-line! &optional extend)
  (or (visual-row-edge! 1 extend) (end-of-line!)))
(public! 'visual-next-line!
  "(visual-next-line! [EXTEND]) — move point one visual row down when the wrap map can say, else one source line")
(public! 'visual-previous-line!
  "(visual-previous-line! [EXTEND]) — move point one visual row up when the wrap map can say, else one source line")
(public! 'visual-beginning-of-line!
  "(visual-beginning-of-line! [EXTEND]) — move point to the start of its visual row when the wrap map can say, else of its line")
(public! 'visual-end-of-line!
  "(visual-end-of-line! [EXTEND]) — move point to the end of its visual row when the wrap map can say, else of its line")

(domain! 'unknown)
(effects! '(unknown))

;;; --- renaming a buffer ---------------------------------------------------------
;;; buffer-rename! is the mechanism: the buffer keeps its process, so text,
;;; point, locals, overlays and undo all survive. What does NOT survive is
;;; state OTHER things key by the old name — a change hook, a pointer from
;;; another buffer. Each owner fixes its own, here.

;; buffer-renamed-hook: (FN OLD NEW). on-buffer-renamed! is the older spelling.
(define (on-buffer-renamed! fn)
  (add-hook! 'buffer-renamed-hook fn)
  #t)

;; the rename the editor uses: mechanism, then every owner of name-keyed
;; state. Returns the new name, or #f when the name is taken.
(define (rename-buffer! old new)
  (let ((done (buffer-rename! old new)))
    (when done
      (run-hook-with-args 'buffer-renamed-hook old new))
    done))

(define-command "buffer-rename" "Rename the current buffer without changing its file"
  (lambda ()
    (let ((old (current-buffer)))
      (minibuffer-read (string-append "Rename buffer " old " to: ") '()
        (lambda (input)
          (let ((new (string-trim input)))
            (cond
              ((equal? new "") (message "Buffer needs a name"))
              ((equal? new old) (message (string-append "Buffer is already named " old)))
              ((buffer-known? new)
               (message (string-append "Buffer " new " already exists")))
              ((rename-buffer! old new)
               (message (string-append "Renamed buffer " old " to " new)))
              (else
               (message (string-append "Could not rename buffer " old))))))))))

;;; --- detaching a buffer from its file ------------------------------------------
;;; buffer-detach! is the mechanism (Emacs: set-visited-file-name with no
;;; name): the buffer keeps its text, point, locals and undo, and forgets
;;; its path. A buffer that adopted a file through (buffer-save! PATH) by
;;; mistake writes nothing there after this; a save asks for a path again.

(domain! 'buffers)
(effects! '(write))

;; Returns #t, or #f when no buffer has that name.
(define (detach-buffer! name)
  (and (buffer-known? name)
       (buffer-detach! name)))

(public! 'detach-buffer!
  "(detach-buffer! NAME) — forget NAME's file and keep its text; #t, or #f when no buffer has that name")

(define-command "buffer-detach" "Forget the current buffer's file; keep its text"
  (lambda ()
    (let ((name (current-buffer)))
      (if (buffer-path name)
          (begin
            (detach-buffer! name)
            (message (string-append "Buffer " name " no longer visits a file")))
          (message (string-append "Buffer " name " visits no file"))))))

(domain! 'unknown)
(effects! '(unknown))

;; Packages derive policy from the accepted window state through this seam.
;; Preview uses a different primitive and does not call it.
(define window-state-changed! (lambda () #t))

;; Emacs window-configuration-change-hook. The editor calls this once for
;; each change of a frame's windows or their buffers, whoever made it: a
;; command, a kill that dropped a window onto its next buffer, an agent.
;; The window commands below call window-state-changed! themselves too,
;; so their own modeline is right before they return; this is the answer
;; for every other path.
(define (window-configuration-changed!)
  (window-state-changed!)
  (run-hooks 'window-configuration-change-hook))

;; The primitive changes the window and wakes the process; Scheme owns the
;; mode closures, so it also completes runtime restoration in this same
;; interpreter turn. A caller never sees the buffer between those two steps.
;; A switch to a buffer from outside the frame's group does not take the
;; selected window: the display chain shows the buffer as category
;; foreign, the popup by the stock rule, and selects it there. The
;; group's panes stay sealed, and the frame stays in its group. A switch
;; made inside the popup replaces the popup's buffer the same way. The
;; chain never comes back here: the popup floats the buffer before it
;; switches, and a floating buffer is not foreign; the same-window action
;; calls switch-to-buffer-here!; the window actions set a window's buffer
;; by id. Emacs: switch-to-buffer-obey-display-actions.
;; A mechanism that puts a buffer in a window it chose — a layout, a
;; swap, a restore, a borrowed window — calls switch-to-buffer-here!.
(define (switch-to-buffer! buf)
  ;; A user visit promotes quiet file loads before deciding target eligibility.
  ;; Logical and agent buffer switches remain headless.
  (when (and (not (buffer-context?)) (boundp 'buffer-promote!)
             (not (agent-edit-author? (current-edit-author))))
    (buffer-promote! buf))
  (cond ((buffer-context?) (switch-to-buffer-here! buf))
        ;; A chat never floats. It owns exactly one group, so a switch to it
        ;; enters that group and the chat opens as an ordinary buffer there.
        ;; The panes stay sealed: the frame follows the chat home, the chat
        ;; does not hang over another group's windows.
        ((and (display-foreign? buf) (chat-buffer? buf)
              (boundp 'switch-to-buffer-in-group!) (boundp 'group-home-of)
              (let ((home (group-home-of buf)))
                (and home (not (equal? home (frame-group))))))
         (switch-to-buffer-in-group! buf)
         buf)
        ((display-foreign? buf)
         (pop-to-buffer buf)
         (message (string-append buf " is not in this group."))
         buf)
        ((and (not *layout-busy*) (layout-target)
              (not (popup--class? (window-buffer (active-window))))
              (window-display! (lambda () (layout-target-open! buf #t #f)))) buf)
        (else
          (window-display!
            (lambda ()
              (switch-to-buffer-here! buf)
              (active-window)))
          buf)))

;; the switch itself: the selected window shows BUF, whatever its group
(define (switch-to-buffer-here! buf)
  (let ((restoring (not (buffer-exists? buf))))
    (window-switch-buffer! buf)
    (when restoring (restore-buffer-runtime! buf))
    ;; a buffer floats only in the popup window: shown anywhere else it
    ;; is an ordinary buffer again, whatever class it carried
    (when (and (popup--class? buf)
               (not (equal? (active-window) (frame-local 'popup-window))))
      (popup-float! buf #f))
    (window-state-changed!)
    buf))

(define *auto-mode-alist*
  '((".scm" "scheme-mode") (".el" "scheme-mode")
    (".ex" "elixir-mode") (".exs" "elixir-mode")
    (".json" "json-mode") (".rs" "rust-mode")
    (".html" "html-mode") (".htm" "html-mode")
    (".md" "morg-mode") (".markdown" "morg-mode")
    (".txt" "text-mode") (".org" "org-mode")
    (".chat" "chat-mode")))

;; the mode a file name would open in, without switching anything —
;; dired filters by it, and (auto-mode) applies it
;; an entry is a suffix (".scm") or a regexp ("\\.scm$", "^Makefile"), as
;; auto-mode-alist takes a regexp in Emacs. A pattern with a regexp
;; character is a regexp; a plain suffix compares case-insensitively.
(define (auto-mode--regexp? pattern)
  (or (string-contains? pattern "\\")
      (string-contains? pattern "^")
      (string-contains? pattern "$")
      (string-contains? pattern "[")
      (string-contains? pattern "(")
      (string-contains? pattern "*")
      (string-contains? pattern "?")))

(define (auto-mode--matches? pattern name)
  (if (auto-mode--regexp? pattern)
      (re-match? pattern name)
      (string-suffix? (string-downcase pattern) (string-downcase name))))

(define (auto-mode--lookup alist name)
  (let loop ((es alist))
    (cond ((null? es) #f)
          ((auto-mode--matches? (car (car es)) name) (car (cdr (car es))))
          (else (loop (cdr es))))))

(define (auto-mode-for name)
  (auto-mode--lookup *auto-mode-alist* name))

;; the mode for a script by the interpreter its first line names:
;; #!/usr/bin/env guile, #!/bin/sh. Emacs's interpreter-mode-alist.
(define *interpreter-mode-alist*
  '(("guile" "scheme-mode") ("scheme" "scheme-mode") ("chibi-scheme" "scheme-mode")
    ("elixir" "elixir-mode")))

;; the mode for a buffer by a regexp on its first line: Emacs's
;; magic-mode-alist. Empty by default; a package adds its own.
(define *magic-mode-alist* '())

(define (auto-mode--first-line buf)
  (let* ((size (buffer-size buf))
         (text (with-current-buffer buf
                 (lambda () (buffer-substring 0 (if (< size 256) size 256)))))
         (lines (string-split text "\n")))
    (if (pair? lines) (car lines) "")))

;; the program a shebang names: the last word of the line, after the
;; last slash. "#!/usr/bin/env guile" and "#!/usr/local/bin/guile" both
;; answer guile.
(define (auto-mode--interpreter line)
  (and (string-prefix? "#!" line)
       (let* ((words (filter (lambda (w) (> (string-length w) 0))
                             (string-split (substring line 2 (string-length line)) " ")))
              (last (if (pair? words) (car (reverse words)) ""))
              (prog (car (reverse (string-split last "/")))))
         (let loop ((es *interpreter-mode-alist*))
           (cond ((null? es) #f)
                 ((equal? (car (car es)) prog) (car (cdr (car es))))
                 (else (loop (cdr es))))))))

;; the mode a buffer would open in: its first line first (magic, then the
;; interpreter), then its name
(define (auto-mode-for-buffer buf &optional name)
  (let ((line (auto-mode--first-line buf)))
    (or (let loop ((es *magic-mode-alist*))
          (cond ((null? es) #f)
                ((re-match? (car (car es)) line) (car (cdr (car es))))
                (else (loop (cdr es)))))
        (auto-mode--interpreter line)
        (auto-mode-for (or name buf)))))

;; A buffer that already wears the mode its name implies is done: the
;; setup fn ran when the buffer opened. Re-running it re-parses the whole
;; buffer, and a preview calls auto-mode on every step. One 18 MB file
;; under the point cost 950 ms per keystroke before this guard.
;; A caller that WANTS the setup fn again (a reload, a desktop restore)
;; calls set-mode! by name; auto-mode only decides a new buffer's mode.
(define (auto-mode path)
  (let ((m (auto-mode-for-buffer (current-buffer) path)))
    (when (and m (not (equal? m (buffer-local (current-buffer) 'mode-name))))
      (set-mode! m))))

;; The directory the file candidates come from. A candidate is a bare
;; name, so the annotator cannot stat it on its own; the file prompt sets
;; this as it lists, through file-candidates below.
(define *marginalia-file-dir* "")

;; what a file name means in a prompt: the mode it would OPEN in, then its
;; size and its date, the same three dired shows. A directory opens in
;; Dired, and the stat says which entries are directories — a listing
;; marks them with a trailing "/", dired's ".." carries no mark, and both
;; read the same. A name no entry above claims opens in Fundamental, which
;; is a mode like any other — so the column stays full and says something
;; true. The size pads itself: a size reads right-aligned, and only the
;; field knows that.
;; This lambda is the file prompt's hot loop: it runs once for every entry
;; in the directory. Read the stat once, and scan auto-mode-alist once —
;; the icon column and the mode column both want the mode, and file-icon
;; would scan the alist a second time to find it.
(marginalia! 'file
  (lambda (name)
    (let* ((st (file-stat (string-append *marginalia-file-dir* name)))
           (dir? (string-prefix? "d" (car st)))
           (mode (and (not dir?) (auto-mode-for name))))
      (list (if dir? (mode-icon "Dired") (mode-icon mode))
            (if dir? "Dired" (or mode "Fundamental"))
            (string-pad-left (car (cdr st)) 6)
            (car (cdr (cdr st)))))))

;;; The prompt's input is a buffer, because typing, DEL, yank and undo are
;;; a buffer's own work. It is not a buffer of the buffer world: nothing
;;; reads it, dismisses it, or saves it. That difference is a major mode,
;;; so every rule about prompts asks the mode instead of matching the
;;; name — and the prompt's keys are the mode's map, so every frame's
;;; prompt has them, not only the frame that was up when this file loaded.
(define-mode "minibuffer-mode"
  (lambda ()
    ;; A prompt is input, never a reading surface. The read-only flag —
    ;; and the q dismissal and Reading bar that follow it — belongs to
    ;; the buffers you look at. A mode setup that runs while a prompt is
    ;; up sees the prompt as the current buffer, and that is how the flag
    ;; arrived there at all.
    (buffer-set-read-only! (current-buffer) #f)))

(mode-doc! "minibuffer-mode"
  "The buffer behind a prompt. It holds what you type and nothing else: no read-only flag, no dismissal, no reading surface.")

(mode-keys! "minibuffer-mode"
  '(("RET" "minibuffer-confirm")
    ("M-RET" "minibuffer-confirm-input")
    ("C-RET" "minibuffer-confirm-context")
    ("C-g" "minibuffer-cancel")
    ("TAB" "minibuffer-complete")
    ("C-n" "minibuffer-next-candidate")
    ("<down>" "minibuffer-next-candidate")
    ("C-p" "minibuffer-previous-candidate")
    ("<up>" "minibuffer-previous-candidate")
    ;; the palette's two lists: <right> steps into the one on the right,
    ;; <left> steps back. With no rail they are the point motion they have
    ;; always been, and C-f/C-b move point either way
    ("<right>" "minibuffer-rail-enter")
    ("<left>" "minibuffer-rail-exit")
    ;; a list behind the prompt takes these first; with no list they are
    ;; the history walk they have always been
    ("M-p" "minibuffer-previous-section")
    ("M-n" "minibuffer-next-section")
    ("M-<up>" "minibuffer-previous-section")
    ("M-<down>" "minibuffer-next-section")
    ("M-g" "minibuffer-regroup")
    ;; a search repeats from inside its own prompt
    ("C-s" "isearch-repeat-forward")
    ("C-r" "isearch-repeat-backward")
    ;; the prompt continues as a buffer — see minibuffer-collect
    ("C-c C-o" "minibuffer-collect")
    ;; the same prompt as the bar, the popup, or the modal, while it is up
    ("C-c C-t" "minibuffer-cycle-shape")
    ("DEL" "minibuffer-delete-backward")))

(define (minibuffer-buffer? buf)
  (if (and buf (buffer-known? buf) (buffer-derived-mode? buf "minibuffer-mode")) #t #f))

;; Every frame makes its own prompt buffer, on its first prompt. The mode
;; goes on there rather than at load: a frame opened later is a prompt too.
(define (minibuffer-mode-ensure! &optional buf)
  (let ((buf (or buf (minibuffer-buffer))))
    (when (and buf (buffer-exists? buf) (not (minibuffer-buffer? buf)))
      (with-current-buffer buf (lambda () (set-mode! "minibuffer-mode"))))
    buf))

(define-mode "text-mode" (lambda () #t))
(define-mode "scheme-mode" (lambda () #t))   ; scheme grammar pending

(mode-doc! "text-mode"
  "Plain prose: `.txt`. The mode adds no keys. `C-c C-v` renders the file, because the renderer reads the extension.")

;;; --- the name at point --------------------------------------------------------
;;; Two callers read the name under the cursor and they disagree about the
;;; alphabet, on purpose. `M-.` must not read `foo/2` or `a+b` as one
;;; name, so it stops at the code alphabet. Help also reads Scheme globals
;;; like `*mode-docs*`, so it adds `*`. One scanner, two alphabets.

(define *symbol-chars* "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_?!-")

;; Scan out from point over CHARS and return the name, or #f. Point sits
;; before the character it is on, so a point just after the last character
;; of a name still reads that name — the left scan finds it and the right
;; scan stops at once, the way Emacs answers.
;;
;; The scan reads one byte at a time, and substring-bytes floors both ends
;; to a character boundary. So a one-byte slice of a multi-byte character
;; comes back empty, and an empty slice is not a name character — the scan
;; stops there, which is the correct answer. The guard also matters
;; because string-index rejects an empty pattern.
(define (symbol-at-point-in chars)
  (let* ((text (buffer-text (current-buffer)))
         (size (string-byte-length text))
         (p (point))
         (word? (lambda (c) (and (not (equal? c "")) (string-index chars c)))))
    (let ((s (let loop ((i p))
               (if (and (> i 0) (word? (substring-bytes text (- i 1) i)))
                   (loop (- i 1))
                   i)))
          (e (let loop ((i p))
               (if (and (< i size) (word? (substring-bytes text i (+ i 1))))
                   (loop (+ i 1))
                   i))))
      (and (> e s) (substring-bytes text s e)))))

(define (symbol-at-point) (symbol-at-point-in *symbol-chars*))

;;; --- context providers --------------------------------------------------------
;;; A mode can explain what the user is looking at: (register-context-provider!
;;; "notmuch-mode" fn) where fn takes the buffer name and returns a short
;;; description or #f. agent-send prepends the visible windows'
;;; contexts, so "this" in a chat means the thing selected in the other window.

(define *context-providers* '())   ; ((mode-name fn) ...)

(define (register-context-provider! mode fn)
  (set! *context-providers*
    (cons (list mode fn)
          (filter (lambda (e) (not (equal? (car e) mode))) *context-providers*))))

(define (buffer-context buf)
  (let ((p (assoc (or (buffer-local buf 'mode-name) "") *context-providers*)))
    (and p ((cadr p) buf))))

;; contexts of every visible buffer except EXCLUDE (the chat itself),
;; deduped; "" when no provider speaks up
(define (editor-context exclude)
  (let loop ((ws (window-list)) (seen '()) (acc '()))
    (if (null? ws)
        (string-join (reverse acc) "\n")
        (let ((buf (cadr (car ws))))
          (if (or (equal? buf exclude) (member buf seen))
              (loop (cdr ws) seen acc)
              (let ((ctx (buffer-context buf)))
                (loop (cdr ws) (cons buf seen)
                      (if ctx (cons ctx acc) acc))))))))

;;; --- targets & actions (embark) -----------------------------------------------
;;; The thing at point is a typed TARGET: (type id label). Modes register
;;; a provider; types register ACTIONS ((name fn) ...). One table serves
;;; every consumer: C-. pops the action menu, and the act tool lets the
;;; model drive the same verbs the keyboard does.

(define *target-providers* '())   ; ((mode-name fn) ...), fn: buf -> target|#f

(define (register-target-provider! mode fn)
  (set! *target-providers*
    (cons (list mode fn)
          (filter (lambda (e) (not (equal? (car e) mode))) *target-providers*))))

(define (target-at buf)
  (let ((p (assoc (or (buffer-local buf 'mode-name) "") *target-providers*)))
    (and p ((cadr p) buf))))

(define *embark-actions* '())     ; ((type ((name fn) ...)) ...)

(define (register-actions! type actions)
  (set! *embark-actions*
    (cons (list type actions)
          (filter (lambda (e) (not (equal? (car e) type))) *embark-actions*))))

(define (actions-for type)
  (let ((e (assoc type *embark-actions*)))
    (if e (cadr e) '())))

(define-command "embark-act" "Act on the thing at point"
  (lambda ()
    (let ((t (target-at (current-buffer))))
      (if (not t)
          (message "nothing at point to act on")
          (let* ((type (car t)) (id (cadr t)) (label (caddr t))
                 (acts (actions-for type)))
            (if (null? acts)
                (message (string-append "no actions for "
                                        (symbol->string type)))
                (minibuffer-read
                  (string-append (symbol->string type) " · " label " → ")
                  (map (lambda (a) (list (car a) "")) acts)
                  (lambda (name)
                    (let ((a (assoc name acts)))
                      (when a ((cadr a) id)))))))))))

(global-set-key "C-." "embark-act")

(category! 'targets)
(public! 'register-target-provider! "(register-target-provider! MODE FN) — FN buf -> (type id label) target at point, or #f")
(public! 'register-actions! "(register-actions! 'type '((name fn)...)) — verbs for a target type; C-. and the act tool use them")
(public! 'target-at "(target-at BUF) — the typed target at BUF's point, or #f")

;; the paragraph chat/agent sends prepend when a context provider fires
(define (editor-context-preamble exclude)
  (let ((ctx (editor-context exclude)))
    (if (equal? ctx "")
        ""
        (string-append
          "[Editor context — what the user is looking at right now:\n" ctx
          "\nWhen the user says \"this\" they mean the item above.]\n\n"))))

(define (ts-mode lang)
  (lambda () (buffer-set-local! (current-buffer) 'ts-lang lang)))

(define-mode "html-mode" (ts-mode "html"))

(mode-doc! "html-mode"
  "HTML, parsed. You get the colours, and `C-M-f` and `C-M-b` step over whole elements. `C-c C-v` shows the rendered page, because the renderer reads the extension. `C-c C-a` runs the page as an app: its own scripts, its own storage, and the files beside it. A save reloads it, and `C-g` gives the keyboard back.")

;; revert-buffer: re-read the file from disk (discards buffer edits).
;; Kill + re-visit so modes, hooks and fontification re-apply cleanly.
(define-command "revert-buffer" "Re-read the current buffer's file from disk"
  (lambda ()
    (let* ((buf (current-buffer))
           (path (buffer-path buf))
           (p (point)))
      (if (not path)
          (message "Buffer is not visiting a file")
          (begin
            (buffer-kill! buf)
            (visit path)
            (goto-char! (min p (buffer-size (current-buffer))))
            (message "Reverted"))))))

;;; --- apps --------------------------------------------------------------
;;; preview-mode renders a page the way eww does: themed, and inert. An app
;;; needs the opposite. It keeps the colours the author wrote, it runs its
;;; own JavaScript, it keeps its own storage, and it loads the files beside
;;; it. So an app window draws a frame on the app origin — a different port,
;;; which the browser reads as a different origin — and that origin serves
;;; this buffer's live text plus the directory its file lives in.
;;;
;;; The two are separate commands on purpose. A downloaded .html that you
;;; open to read must not run anything; `C-c C-v` reads it, `C-c C-a` runs
;;; it, and the difference is a key you press.

;; The app itself lives in packages/preview.scm, which defines every one
;; of these and hooks the save. Both copies loaded and both hooks ran, so
;; one save reloaded every app twice. A package owns the app; this file
;; keeps the keys, and preview.scm binds the same three.

(define-mode "elixir-mode" (ts-mode "elixir"))
(define-mode "json-mode" (ts-mode "json"))
(define-mode "rust-mode" (ts-mode "rust"))

;; A language mode sets one buffer-local: `ts-lang`. That local starts the
;; incremental parser, and the parser supplies the colours, the sexp
;; motion and imenu. The mode adds no keys of its own — the global keys do
;; the work, and they need the parser to answer.
(mode-doc! "elixir-mode"
  "Elixir, parsed. You get the colours, `C-M-f` and `C-M-b` over forms, and `M-g i` for the definitions in the file.")
(mode-doc! "json-mode"
  "JSON, parsed. You get the colours, and `C-M-f` and `C-M-b` step over whole objects and arrays.")
(mode-doc! "rust-mode"
  "Rust, parsed. You get the colours, `C-M-f` and `C-M-b` over forms, and `M-g i` for the definitions in the file.")

;;; --- sexp / structural navigation (tree-sitter) ------------------------------

(define (ts-goto op)
  (let ((p (ts-nav op)))
    (if p (goto-char! p) (message "No structural navigation here"))))

(define-command "forward-sexp" "Move forward across one balanced expression"
  (lambda () (ts-goto 'forward)))
(define-command "backward-sexp" "Move backward across one balanced expression"
  (lambda () (ts-goto 'backward)))
(define-command "backward-up-list" "Move backward out of one level of parentheses"
  (lambda () (ts-goto 'up)))
(define-command "down-list" "Move forward down one level of parentheses"
  (lambda () (ts-goto 'down)))

;;; --- word motion & editing ---------------------------------------------------

(define (delete-between! s e)
  (set-mark! e)
  (goto-char! s)
  (delete-region!)
  (set-mark! #f))

;; ONE kill: push S..E to the kill ring, then delete it (dup #30).
;; Returns #t when the range was non-empty.
(define (kill-region-1 s e &optional before?)
  (if (> e s)
      (begin
        (kill-text! (buffer-substring s e) before?)
        (delete-between! s e)
        #t)
      #f))

;; A mode may let one visible region represent a larger source range. Keep
;; that policy here so keyboard copy, keyboard cut, and system copy agree.
(define *region-lifters* '())

(define (register-region-lifter! mode fn)
  (set! *region-lifters*
    (cons (list mode fn)
          (filter (lambda (entry) (not (equal? (car entry) mode)))
                  *region-lifters*))))

(define (region-action-bounds)
  (let* ((buf (current-buffer))
         (start (region-beginning))
         (end (region-end))
         (hit (assoc (buffer-local buf 'mode-name) *region-lifters*)))
    (if (and hit (procedure? (cadr hit)))
        ((cadr hit) buf start end)
        (list start end))))

(define-command "forward-word" "Move point forward one word" (interactive 'p)
  (lambda (n) (repeat-count n forward-word! backward-word!)))
(define-command "backward-word" "Move point backward one word" (interactive 'p)
  (lambda (n) (repeat-count n backward-word! forward-word!)))

;; N words forward from point, killed as one entry
(define (kill-words! n)
  (let ((s (point)))
    (repeat-count n forward-word!)
    (kill-region-1 s (point))))

(define (backward-kill-words! n)
  (let ((e (point)))
    (repeat-count n backward-word!)
    (kill-region-1 (point) e #t)))

(define-command "kill-word" "Kill characters forward to the end of a word" (interactive 'p)
  (lambda (n) (if (< n 0) (backward-kill-words! (- n)) (kill-words! n))))

(define-command "backward-kill-word" "Kill characters backward to the start of a word" (interactive 'p)
  (lambda (n) (if (< n 0) (kill-words! (- n)) (backward-kill-words! n))))

(define-command "transpose-chars" "Interchange characters around point"
  (lambda ()
    (if (= (point) (buffer-size (current-buffer))) (backward-char!))
    (if (> (point) 0)
        (let ((p (point)))
          (let ((s (backward-char!)))
            (goto-char! p)
            (let ((e (forward-char!)))
              (let ((a (buffer-substring s p))
                    (b (buffer-substring p e)))
                (delete-between! s e)
                (insert! (string-append b a)))))))))

;;; --- yank / yank-pop ----------------------------------------------------------

(define *yank-start* 0)
(define *yank-index* 0)

(define-command "yank" "Reinsert the last killed text at point"
  (lambda ()
    (set! *yank-index* 0)
    (set! *yank-start* (point))
    (insert! (kill-top))))

(define-command "yank-pop" "Replace just-yanked text with an earlier kill"
  (lambda ()
    (if (or (equal? (last-command) "yank") (equal? (last-command) "yank-pop"))
        (let ((n (kill-ring-size)))
          (if (> n 0)
              (begin
                (delete-between! *yank-start* (point))
                (set! *yank-index* (if (= (+ *yank-index* 1) n) 0 (+ *yank-index* 1)))
                (insert! (kill-nth *yank-index*)))))
        (message "Previous command was not a yank"))))

;;; --- completion framework (capf) ---------------------------------------------
;;; A completion source is a closure of no arguments returning either
;;;   #f                                — source has nothing here
;;;   (list start end candidates)      — region to replace + candidates,
;;;                                       each a string or (label hint) pair
;;;   (list start end candidates 'exclusive 'no)
;;;                                    — the same, and when CANDIDATES is
;;;                                       empty the next source is tried
;;; Sources are tried in order; the first that answers wins (Emacs capf).
;;; END may lie past point: accept replaces START..END, so a source that
;;; completes over a suffix names the whole word. An LSP client is just
;;; another source returning the same shape.
;;; Buffer-local sources: (buffer-set-local! buf 'capf-sources (list fn ...))

(define *capf-sources* '())

(define (add-capf! fn)
  (set! *capf-sources* (cons fn *capf-sources*)))

(define (capf-sources)
  (let ((local (buffer-local (current-buffer) 'capf-sources)))
    (if local (append local *capf-sources*) *capf-sources*)))

;; a source that says 'exclusive 'no yields to the next when it has nothing
(define (capf-result-yields? r)
  (let ((props (cdr (cdr (cdr r)))))
    (and (null? (caddr r))
         (pair? props)
         (equal? (plist-get props 'exclusive) 'no))))

;; the first answer among SOURCES, or #f
(define (capf-collect sources)
  (let loop ((sources sources))
    (if (null? sources)
        #f
        (let ((r ((car sources))))
          (if (and r (not (capf-result-yields? r)))
              r
              (loop (cdr sources)))))))

(define-command "completion-at-point" "Perform completion on the text around point"
  (lambda ()
    (let ((r (capf-collect (capf-sources))))
      (if r
          (completion-show! (car r) (cadr r) (caddr r))
          (begin
            (completion-dismiss!)
            (message "No completions here"))))))

;; The popup's keys are policy (dup #22): while it shows, KeyDispatch
;; consults this map first. Unbound printables narrow; anything else
;; unbound dismisses the popup and acts normally.
(define-command "completion-next" "Select the next completion candidate"
  (lambda () (completion-move! 1)))
(define-command "completion-prev" "Select the previous completion candidate"
  (lambda () (completion-move! -1)))
(define-command "completion-accept" "Insert the selected completion at point"
  (lambda ()
    (let ((a (completion-accept!)))
      (when a
        (let ((start (car a)) (end (cadr a)) (label (caddr a)))
          (when (> end start)
            (buffer-delete-range! (current-buffer) start (- end start)))
          (goto-char! start)
          (insert! label))))))
(define-command "completion-quit" "Dismiss the completion popup"
  (lambda () (completion-dismiss!) (message "")))

(local-set-key* " *completion*" "C-n" "completion-next")
(local-set-key* " *completion*" "<down>" "completion-next")
(local-set-key* " *completion*" "C-p" "completion-prev")
(local-set-key* " *completion*" "<up>" "completion-prev")
(local-set-key* " *completion*" "RET" "completion-accept")
(local-set-key* " *completion*" "TAB" "completion-accept")
(local-set-key* " *completion*" "C-g" "completion-quit")
(local-set-key* " *completion*" "ESC" "completion-quit")
;; a printable inserts and the popup narrows; DEL widens it. Both are
;; bindings, so a package can change what typing into the popup does.
(define-command "completion-delete-backward" "Delete the character before point and narrow the popup"
  (lambda ()
    (delete-char! -1)
    (completion-requery!)))
(local-set-key* " *completion*" "DEL" "completion-delete-backward")

;; The word before point, found by reading the text. A source must never
;; move point, not even to put it back: completion runs on a timer while
;; the user types, and backward-word! followed by goto-char! restores a
;; point the next keystroke has already moved on from. The caret jumps
;; back and the characters land out of order.
(define *capf-word-chars*
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")

(define (capf-word-start e)
  (let* ((lo (max 0 (- e 128)))
         (chunk (buffer-substring lo e)))
    (let loop ((i (- e lo)))
      (if (and (> i 0)
               (let ((c (substring-bytes chunk (- i 1) i)))
                 (and (not (equal? c "")) (string-index *capf-word-chars* c))))
          (loop (- i 1))
          (+ lo i)))))

;; dabbrev: complete the word before point from words in this buffer
(define (capf-dabbrev)
  (let* ((e (point))
         (s (capf-word-start e)))
    (if (>= s e)
        #f
        (let ((words (buffer-words (buffer-substring s e))))
          (if (null? words)
              #f
              (list s e (map (lambda (w) (list w "dabbrev")) words)))))))

;; by name, not by value: a reload must reach the source the popup uses
(add-capf! (lambda () (capf-dabbrev)))

;;; --- misc editing --------------------------------------------------------------

(define-command "indent-for-tab" "Indent by inserting two spaces"
  (lambda () (insert! "  ")))

;;; --- scrolling (viewport) ------------------------------------------------------

(define (move-lines n mover)
  (let loop ((i 0))
    (if (< i n)
        (begin (mover) (loop (+ i 1))))))

;; A page is a screenful of what the reader sees, so it steps by visual
;; rows: a rendered page and a wrapped paragraph draw many rows for one
;; source line, and paging by source lines there jumps several screens.
;; One counted move, not a loop of single moves — see visual-row-move!.
;; With no wrap map to read, the page is source lines again.
(define (visual-page! dir)
  (let ((n (- (window-rows) 2)))
    (or (visual-row-move! dir #f n)
        (move-lines n (if (> dir 0) next-line! previous-line!)))))

;; with an argument, scroll that many lines instead of a screen
(define-command "scroll-up-command" "Scroll text upward nearly a full screen" (interactive 'P)
  (lambda (arg)
    (if arg
        (scroll-window! (active-window) (prefix-numeric-value arg))
        (or (preview-scroll! (- (window-rows) 2))
            (visual-page! 1)))))

(define-command "scroll-down-command" "Scroll text downward nearly a full screen" (interactive 'P)
  (lambda (arg)
    (if arg
        (scroll-window! (active-window) (- (prefix-numeric-value arg)))
        (or (preview-scroll! (- 2 (window-rows)))
            (visual-page! -1)))))

(define-command "recenter-top-bottom" "Recenter point in the window"
  (lambda () (recenter!)))

(define-command "display-line-numbers-mode" "Toggle line numbers in the current buffer"
  (lambda ()
    (let ((cur (buffer-local (current-buffer) 'line-numbers)))
      (if (equal? cur "off")
          (begin
            (buffer-set-local! (current-buffer) 'line-numbers "on")
            (message "Line numbers enabled"))
          (begin
            (buffer-set-local! (current-buffer) 'line-numbers "off")
            (message "Line numbers disabled"))))))

;; window split/resize animations — CSS falls back to 140ms when the
;; chrome face doesn't say otherwise; this flips it to 0ms and back
(define *window-animations* #t)

(define-command "toggle-window-animations" "Toggle window split and resize animations"
  (lambda ()
    (set! *window-animations* (not *window-animations*))
    (set-face-attribute! 'chrome 'anim (if *window-animations* "140ms" "0ms"))
    (message (if *window-animations*
                 "Window animations on"
                 "Window animations off"))))

(define-command "back-to-indentation" "Move point to the first non-space on this line"
  (lambda ()
    (beginning-of-line!)
    (let loop ()
      (let ((p (point)))
        (if (and (< p (buffer-size (current-buffer)))
                 (equal? (buffer-substring p (+ p 1)) " "))
            (begin (forward-char!) (loop)))))))

(define-command "goto-line" "Go to a line number read from the minibuffer"
  (lambda ()
    (minibuffer-read "Goto line: " '()
      (lambda (s)
        (let ((n (string->number s)))
          (if (number? n)
              ;; direct rope lookup — O(log n), not a next-line! walk from
              ;; line 1 (which made jumping deep into a large file cost
              ;; proportional to how far you jumped)
              (goto-char! (line-start-position n))
              (message "Not a number")))))))

;;; imenu lives in packages/code.scm now, on the outline contract: the
;;; index is (code-outline BUF), so it needs no per-language query table.

;;; --- mark & region ---------------------------------------------------------

;;; --- the mark ring ---------------------------------------------------------
;;; Emacs keeps the marks a buffer had: C-SPC pushes the old mark onto the
;;; buffer's ring and sets a new one, and C-u C-SPC goes back to the mark
;;; and pops the ring. The global mark ring remembers the buffer too, so
;;; C-x C-SPC walks back across buffers. Here a set mark is an active
;;; region, so a pop lands point on the old mark and leaves no region.

(define mark-ring-max 16)
(define *global-mark-ring* '())    ; ((BUF POS) ...), newest first

(define (mark-ring &optional buf)
  (or (buffer-local (or buf (current-buffer)) 'mark-ring) '()))

(define (global-mark-ring) *global-mark-ring*)

;; the old mark joins the ring, and the global ring when the buffer is
;; not the newest entry's
(define (push-mark! &optional pos nomsg)
  (let* ((buf (current-buffer))
         (old (mark))
         (at (or pos (point))))
    (when old
      (buffer-set-local! buf 'mark-ring (take-n (cons old (mark-ring buf)) mark-ring-max)))
    (unless (and (pair? *global-mark-ring*) (equal? (car (car *global-mark-ring*)) buf))
      (set! *global-mark-ring* (take-n (cons (list buf (or old at)) *global-mark-ring*) mark-ring-max)))
    (set-mark! at)
    (unless nomsg (message "Mark set"))
    at))

;; back to the mark, and the ring turns: the next pop reaches the one
;; before. With no mark the newest ring entry is the target.
(define (pop-to-mark!)
  (let* ((buf (current-buffer))
         (m (mark))
         (ring (mark-ring buf))
         (target (or m (and (pair? ring) (car ring)))))
    (cond ((not target) (message "No mark set in this buffer") #f)
          (else
            (goto-char! target)
            (set-mark! #f)
            (buffer-set-local! buf 'mark-ring
              (if m
                  (append ring (list m))
                  (append (cdr ring) (list target))))
            target))))

(define-command "set-mark-command" "Set the mark where point is; with a prefix, go back to the previous mark"
  (interactive 'P)
  (lambda (arg)
    (if arg (pop-to-mark!) (push-mark!))))

(define-command "pop-global-mark" "Go back to the last mark set in any buffer"
  (lambda ()
    (if (null? *global-mark-ring*)
        (message "No global mark set")
        (let* ((e (car *global-mark-ring*))
               (buf (car e)) (pos (cadr e)))
          (set! *global-mark-ring* (append (cdr *global-mark-ring*) (list e)))
          (if (buffer-known? buf)
              (begin (switch-to-buffer! buf) (goto-char! pos))
              (run-command "pop-global-mark"))))))

(define-command "kill-region" "Kill the text between point and mark"
  (lambda ()
    (let ((bounds (region-action-bounds)))
      (unless (kill-region-1 (car bounds) (cadr bounds))
        (message "The region is empty")))))

(define-command "copy-region-as-kill" "Save the region as if killed, but don't kill it"
  (lambda ()
    (let* ((bounds (region-action-bounds))
           (text (buffer-substring (car bounds) (cadr bounds))))
      (if (equal? text "")
          (message "The region is empty")
          (begin
            (kill-push! text)
            (set-mark! #f)
            (message "Copied"))))))

(define-command "exchange-point-and-mark" "Exchange positions of point and mark"
  (lambda ()
    (if (not (exchange-point-and-mark!))
        (message "No mark set in this buffer"))))

;; Visual narrowing and model context are separate choices. These marker locals
;; make an explicit context restriction follow edits without making ordinary
;; C-x n n change what the model sees.
(define (llm-context-range buf)
  (let ((start (buffer-local buf 'llm-context-start))
        (end (buffer-local buf 'llm-context-end)))
    (and (number? start) (number? end) (<= start end) (list start end))))

(define (llm-context-text buf text)
  (let ((range (llm-context-range buf)))
    (if range
        (substring-bytes text (car range) (cadr range))
        text)))

(define (llm-context-clear! buf)
  (let ((had (llm-context-range buf)))
    (buffer-set-local! buf 'llm-context-start #f)
    (buffer-set-local! buf 'llm-context-end #f)
    (when (and had (minor-mode-on? buf "llm-mode")
               (boundp (quote llm-mode-reset-runtime!)))
      (llm-mode-reset-runtime! buf #f))
    had))

(define (llm-context-use-narrowing! buf)
  (let ((range (buffer-narrow-range buf)))
    (when range
      (buffer-marker-local! buf 'llm-context-start 'stay)
      (buffer-marker-local! buf 'llm-context-end 'advance)
      (buffer-set-local! buf 'llm-context-start (car range))
      (buffer-set-local! buf 'llm-context-end (cadr range))
      (when (and (minor-mode-on? buf "llm-mode")
                 (boundp (quote llm-mode-reset-runtime!)))
        (llm-mode-reset-runtime! buf #f)))
    range))

(define-command "narrow-to-region" "Show only the text between point and mark"
  (lambda ()
    (if (and (mark) (< (region-beginning) (region-end)))
        (begin
          (buffer-narrow! (current-buffer) (region-beginning) (region-end))
          (message "Narrowed to region"))
        (message "No region — set the mark first (C-SPC)"))))

(define-command "narrow-context-also"
  "Narrow the view and the LLM context to the same region or Morg section"
  (lambda ()
    (let ((buf (current-buffer)))
      (run-command
        (if (buffer-derived-mode? buf "morg-mode") "morg-narrow" "narrow-to-region"))
      (let ((range (llm-context-use-narrowing! buf)))
        (when range
          (message (string-append "Narrowed view and LLM context to "
                                  (number->string (- (cadr range) (car range)))
                                  " bytes")))))))

(define-command "widen" "Show the complete current buffer"
  (lambda ()
    (llm-context-clear! (current-buffer))
    (buffer-widen! (current-buffer))
    (message "Widened buffer")))

(catalog-meta! 'command "narrow-to-region"
  'domain 'buffers 'effects '(write display))
(catalog-meta! 'command "narrow-context-also"
  'domain 'llm 'effects '(write display))

(catalog-meta! 'command "widen"
  'domain 'buffers 'effects '(write display))

;;; --- isearch ---------------------------------------------------------------
;;; ONE search engine (dup #13), two surfaces: C-s/C-r here, evil's
;;; / ? n N in evil.scm. The engine owns the directional find, the wrap
;;; retry, and the incremental loop — capture the origin, re-search from
;;; it on every keystroke, restore it on cancel. The surface owns what a
;;; hit shows, what a miss says, and what RET keeps.
;;;
;;; One search runs at a time, so one variable holds it. The state says
;;; where the next find starts, which way it runs, and how to draw a hit.
;;; C-s and C-r in the minibuffer map move that start past the current
;;; match — the prompt stays open, the way Emacs repeats a search.

;; (search-find q backward from) -> (start end) or #f
(define (search-find q backward from)
  (if backward (buffer-search-backward q from) (buffer-search q from)))

;; miss -> one retry from the far end, and the echo area says so
(define (search-find-wrap q backward from)
  (or (search-find q backward from)
      (let ((m (search-find q backward
                            (if backward (buffer-size (current-buffer)) 0))))
        (when m (message "Search wrapped"))
        m)))

;; the live search, or #f between searches
(define *isearch* #f)
;; the last string searched for. An empty C-s repeats it, as Emacs does.
(define *isearch-last* "")

(define (isearch--set! origin start backward show query match)
  (set! *isearch*
    (list 'origin origin 'start start 'backward backward
          'show show 'query query 'match match)))

(define (isearch--field key) (and *isearch* (plist-get *isearch* key)))

;; one find, drawn by the surface. Call it inside with-window-buffer: the
;; search reads the window's buffer, not the prompt.
(define (isearch--step! q backward from wrap)
  (let ((m (and (not (equal? q ""))
                (if wrap
                    (search-find-wrap q backward from)
                    (search-find q backward from))))
        (origin (isearch--field 'origin))
        (show (isearch--field 'show)))
    (isearch--set! origin from backward show q m)
    (show m q origin)
    m))

;; The loop. SHOW gets (match q origin) on every keystroke — match is #f
;; on a miss and on an empty query. ACCEPT gets (q origin) on RET.
;; CANCEL gets (origin) on C-g, after the point returns to it.
(define (isearch-loop prompt backward show accept cancel)
  (let ((origin (point)))
    (isearch--set! origin origin backward show "" #f)
    (minibuffer-read* prompt '()
      (list (list 'change
              (lambda (q)
                (unless (equal? q "") (set! *isearch-last* q))
                (with-window-buffer
                  (lambda ()
                    (isearch--step! q backward (isearch--field 'start) #f)))))
            (list 'confirm (lambda (q)
                             (set! *isearch* #f)
                             (accept q origin)))
            (list 'cancel (lambda ()
                            (set! *isearch* #f)
                            (goto-char! origin)
                            (cancel origin)))))))

;; C-s again: find the match after this one. The repeat wraps at the end of
;; the buffer, and it can turn the search around — C-r inside a forward
;; search walks back through the same hits.
(define (isearch--repeat! backward)
  (when *isearch*
    (with-window-buffer
      (lambda ()
        (let* ((typed (isearch--field 'query))
               (q (if (equal? typed "") *isearch-last* typed))
               (m (isearch--field 'match))
               (turn (not (equal? backward (isearch--field 'backward))))
               (from (cond ((not m) (if backward (buffer-size (current-buffer)) 0))
                           ;; a turn reads THIS match again from the other side
                           (turn (if backward (cadr m) (car m)))
                           (backward (car m))
                           (else (+ (car m) 1)))))
          (if (equal? q "")
              (message "No previous search")
              (begin
                ;; the prompt shows the string it repeats
                (when (equal? typed "") (minibuffer-input! q))
                ;; the surface says what a hit and a miss look like
                (isearch--step! q backward from #t))))))))

(define-command "isearch-repeat-forward" "During a search, move to the next match"
  (lambda () (isearch--repeat! #f)))
(define-command "isearch-repeat-backward"
  "During a search, move to the previous match"
  (lambda () (isearch--repeat! #t)))

(catalog-meta! 'command "isearch-repeat-forward" 'domain 'targets 'effects '(write))
(catalog-meta! 'command "isearch-repeat-backward" 'domain 'targets 'effects '(write))

;;; --- lazy highlight -------------------------------------------------------
;;; Emacs paints every other match of the search in lazy-highlight and the
;;; current one in isearch, so the reader sees where C-s will go next.
;;; The paint is an overlay tag of its own, cleared when the search ends.

(define isearch-lazy-highlight-max 300)

;; every (START END) of Q in the buffer, at most the limit, in order
(define (isearch-matches q)
  (if (equal? q "")
      '()
      (let loop ((from 0) (acc '()) (n 0))
        (let ((m (and (< n isearch-lazy-highlight-max) (buffer-search q from))))
          (if (or (not m) (<= (cadr m) (car m)))
              (reverse acc)
              (loop (cadr m) (cons m acc) (+ n 1)))))))

(define (isearch--paint! q m)
  (overlay-set! (current-buffer) 'isearch
    (map (lambda (r)
           (list (car r) (cadr r)
                 (if (and m (equal? r m)) "isearch" "lazy-highlight")))
         (isearch-matches q))))

(define (isearch--unpaint!)
  (overlay-set! (current-buffer) 'isearch '()))

;; Emacs surface: the current match is the region (mark at one end, point
;; at the other), the other matches wear lazy-highlight, a miss says so,
;; RET keeps the point and drops the region.
(define (isearch backward)
  (isearch-loop (if backward "I-search backward: " "I-search: ") backward
    (lambda (m q origin)
      ;; the LIVE direction, not the one this search started with: C-r
      ;; inside a forward search turns it around, and the point must land
      ;; at the end the reader now moves toward
      (let ((back (isearch--field 'backward)))
        (isearch--paint! q m)
        (cond ((equal? q "") (set-mark! #f) (goto-char! origin))
              (m (if back
                     (begin (set-mark! (cadr m)) (goto-char! (car m)))
                     (begin (set-mark! (car m)) (goto-char! (cadr m)))))
              (else (message (string-append "Failing I-search: " q))))))
    (lambda (q origin) (with-window-buffer isearch--unpaint!) (set-mark! #f))
    (lambda (origin) (with-window-buffer isearch--unpaint!) (set-mark! #f))))

;;; --- hl-line-mode ------------------------------------------------------------
;;; The page highlights the line point is on. Emacs makes that a minor
;;; mode; here it is on by default, and the mode turns it off and on for
;;; one buffer. The local reads "off" when it is off: a local holding #f
;;; reads as absent.

(define (hl-line-on? buf)
  (not (equal? (buffer-local buf 'hl-line-mode) "off")))

(define-command "hl-line-mode" "Toggle the highlight of the current line in this buffer"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (hl-line-on? buf)
          (begin (buffer-set-local! buf 'hl-line-mode "off") (message "hl-line-mode off"))
          (begin (buffer-set-local! buf 'hl-line-mode "on") (message "hl-line-mode on"))))))

;;; --- font-lock keywords -------------------------------------------------------
;;; Emacs's font-lock-keywords for a mode without a grammar: a list of
;;; (REGEXP FACE). Every match in the buffer wears the face, under the
;;; font-lock overlay tag, and the paint follows every change. A derived
;;; mode inherits its parent's keywords. A mode with keywords is painted
;;; from set-mode! on; a package may call font-lock-refontify! itself.

(define *font-lock-keywords* '())     ; ((MODE (REGEXP FACE) ...) ...)
(define *font-lock-hooks* '())        ; ((BUF HANDLE) ...)

(define (font-lock-add-keywords! mode keywords)
  (set! *font-lock-keywords*
    (hook--alist-put *font-lock-keywords* mode
      (append (hook--alist-get *font-lock-keywords* mode)
              (filter (lambda (k) (not (member k (hook--alist-get *font-lock-keywords* mode))))
                      keywords))))
  mode)

(define (font-lock-set-keywords! mode keywords)
  (set! *font-lock-keywords* (hook--alist-put *font-lock-keywords* mode keywords))
  mode)

;; the keywords of MODE and its parents, the parent's first
(define (font-lock-keywords mode)
  (let loop ((m mode) (acc '()) (seen '()))
    (if (or (not m) (member m seen))
        acc
        (loop (mode-parent m) (append (hook--alist-get *font-lock-keywords* m) acc) (cons m seen)))))

(define (font-lock--spans text keywords)
  (apply append
    (map (lambda (k)
           (map (lambda (r) (list (car r) (cadr r) (cadr k)))
                (re-find* (car k) text)))
         keywords)))

(define (font-lock-refontify! buf)
  (when (buffer-exists? buf)
    (let ((kws (font-lock-keywords (buffer-local buf 'mode-name))))
      (overlay-set! buf 'font-lock
        (if (null? kws) '() (font-lock--spans (buffer-text buf) kws))))))

;; the reactor binds a rule to one buffer process, so setup replaces the
;; old rule, as markdown-mode does
(define (font-lock-enable! buf)
  (let ((old (assoc buf *font-lock-hooks*)))
    (when old (remove-on-change! (cadr old)))
    (set! *font-lock-hooks*
      (cons (list buf
                  (on-change! buf
                    (lambda (pos inserted deleted source)
                      (unless (equal? source "locals") (font-lock-refontify! buf)))
                    'eager))
            (remove (lambda (e) (equal? (car e) buf)) *font-lock-hooks*)))
    (font-lock-refontify! buf)))

(define (font-lock-disable! buf)
  (let ((old (assoc buf *font-lock-hooks*)))
    (when old
      (remove-on-change! (cadr old))
      (set! *font-lock-hooks* (remove (lambda (e) (equal? (car e) buf)) *font-lock-hooks*)))
    (overlay-set! buf 'font-lock '())))

(define-command "isearch-forward" "Do incremental search forward"
  (lambda () (isearch #f)))
(define-command "isearch-backward" "Do incremental search backward"
  (lambda () (isearch #t)))

;;; --- replace ---------------------------------------------------------------
;;; Replacement uses the same literal search primitive as isearch. Collect
;;; matches before editing, then apply them from right to left so byte
;;; positions stay valid when the replacement has a different length.

(define (replace--matches buf old from acc)
  (let ((m #f))
    (with-current-buffer buf (lambda () (set! m (buffer-search old from))))
    (if m
        (replace--matches buf old (cadr m) (cons m acc))
        (reverse acc))))

(define (replace--all! buf old new from)
  (if (equal? old "")
      0
      (let ((matches (replace--matches buf old from '())))
        (for-each
          (lambda (m)
            (buffer-replace-range! buf (car m)
                                   (- (cadr m) (car m)) new))
          (reverse matches))
        (length matches))))

(define (replace--prompt prompt k)
  (minibuffer-read* prompt '()
    (list (list 'confirm k)
          (list 'cancel (lambda () (message "Quit"))))))

(define (replace--read-new buf old prompt k)
  (replace--prompt prompt k))

(define-command "replace-string" "Replace every literal occurrence of text"
  (lambda ()
    (let ((buf (current-buffer)))
      (replace--prompt "Replace string: "
        (lambda (old)
          (if (equal? old "")
              (message "Replace string cannot be empty")
              (replace--read-new buf old "Replace string with: "
                (lambda (new)
                  (let ((n 0))
                    (with-invoking-buffer
                      (lambda () (set! n (replace--all! buf old new 0))))
                    (message (string-append "Replaced "
                      (number->string n)
                      (if (= n 1) " occurrence" " occurrences"))))))))))))

(define-command "query-replace" "Replace literal text with confirmation"
  (lambda ()
    (let ((buf (current-buffer)) (origin (point)))
      (replace--prompt "Query replace: "
        (lambda (old)
          (if (equal? old "")
              (message "Query replace cannot search for an empty string")
              (replace--read-new buf old "Query replace with: "
                (lambda (new)
                  (let loop ((from origin) (n 0))
                    (let ((m #f))
                      (with-invoking-buffer
                        (lambda () (set! m (buffer-search old from))))
                      (if (not m)
                          (message (string-append "Replaced "
                            (number->string n)
                            (if (= n 1) " occurrence" " occurrences")))
                          (begin
                            (with-invoking-buffer
                              (lambda () (goto-char! (car m))))
                            (y-or-n
                              (string-append "Replace " old " with " new "? ")
                              (lambda ()
                                (buffer-replace-range! buf (car m)
                                  (- (cadr m) (car m)) new)
                                (loop (+ (car m) (string-byte-length new))
                                      (+ n 1)))
                              (lambda () (loop (cadr m) n)))))))))))))))

(catalog-meta! 'command "replace-string" 'domain 'editing 'effects '(write))
(catalog-meta! 'command "query-replace" 'domain 'editing 'effects '(write))

;;; --- files & buffers -------------------------------------------------------

;; Every owner can apply policy to one truly new buffer. Waking a dormant
;; buffer does not run these hooks because that buffer already has state.
;; buffer-created-hook: (FN NAME). on-buffer-created! is the older spelling.
(define (on-buffer-created! fn)
  (add-hook! 'buffer-created-hook fn)
  #t)

(define (buffer-created! name)
  (when (string? name) (buffer-set-local! name 'created-at (current-time)))
  (run-hook-with-args 'buffer-created-hook name)
  name)

;; A buffer carries the two times that say whether anyone still wants it:
;; when it was made, and when the user last had it in front of them. Both
;; are locals, so a checkpoint keeps them, and a local reads out of a
;; dormant buffer without waking it. Nothing else can answer the question:
;; the MRU ring holds names with no times, and it pads its tail with every
;; other known buffer in alphabetical order.
(define buffer-seen-coarse-seconds 60)
(define *buffer-seen-stamps* '())

(define (buffer-seen-memo b)
  (let ((e (assoc b *buffer-seen-stamps*))) (and e (cadr e))))

(define (buffer-seen-memo! b t)
  (set! *buffer-seen-stamps*
    (cons (list b t) (filter (lambda (e) (not (equal? (car e) b))) *buffer-seen-stamps*))))

(define (buffer-note-seen! b)
  ;; one write a minute per buffer. The hook behind this runs on every
  ;; window configuration change, and a local write is a call into the
  ;; buffer's own process.
  (when (and (string? b) (buffer-known? b))
    (let ((now (current-time)) (was (buffer-seen-memo b)))
      (when (or (not (number? was)) (> (- now was) buffer-seen-coarse-seconds))
        (buffer-seen-memo! b now)
        (buffer-set-local! b 'last-seen now))))
  b)

(define (buffer-last-seen b)
  ;; the memo answers a drawn list without touching the buffer; a miss
  ;; reads the local once and keeps it, so a table pays this per boot.
  (let ((memo (buffer-seen-memo b)))
    (or memo
        (and (buffer-known? b)
             (let ((t (buffer-local b 'last-seen)))
               (when (number? t) (buffer-seen-memo! b t))
               (and (number? t) t))))))

(define (buffer-created-at b)
  (and (buffer-known? b) (let ((t (buffer-local b 'created-at))) (and (number? t) t))))

;; The other half. A dormant buffer is absent from (buffer-list), so a
;; pass over the open buffers cannot reach it while it sleeps, and it
;; missed every seam that ran meanwhile. This is where an owner catches
;; that buffer up. It runs on a desktop restore too, which is the same
;; event: state came back from a checkpoint, not from nothing.
;; buffer-woken-hook: (FN NAME). on-buffer-woken! is the older spelling.
(define (on-buffer-woken! fn)
  (add-hook! 'buffer-woken-hook fn)
  #t)

(define (buffer-woken! name)
  (run-hook-with-args 'buffer-woken-hook name)
  name)

;; A new buffer inherits the directory of the buffer that made it (Emacs:
;; default-directory is buffer-local and copied from the current buffer at
;; creation). Without this, every non-file buffer — chat, shell, agent
;; thread, listing — answers "~" and C-x C-f from it loses your place.

;; A buffer name that is a file on disk names that file. An empty buffer
;; under such a name holds a lie, and the first save turns the lie into
;; a clobber: an agent made ~/.compos/init.scm that way and wrote seven
;; lines over a hundred. A directory name is not a file: a Dired listing
;; is a plain buffer named by its directory.
(define (buffer-shadows-file? name)
  (and (string? name)
       (string-prefix? "/" name)
       (not (remote-path? name))
       (not (buffer-path name))
       (file-exists? name)
       (not (file-directory? name))))

(define (buffer-create name)
  (if (and (not (buffer-known? name)) (buffer-shadows-file? name))
      ;; the name is a file: load it, so the buffer starts as the file
      (find-file name)
      (let ((fresh (not (buffer-exists? name)))
            (new (not (buffer-known? name))))
        (raw-buffer-create name)
        (when (and fresh (boundp (quote default-directory)))
          (buffer-set-local! name 'default-directory (default-directory)))
        (when new (buffer-created! name))
        name)))

;;; --- write policy ----------------------------------------------------------
;; Two primitives put text on disk: write-file! and buffer-save!. Every write
;; this editor makes goes through one of them, so they are the one door, and
;; this is the one guard on it. Elixir supplies the raw write. The rules here
;; decide which writes happen.
;;
;; A rule is a record: a name, a reason, a confirmable flag, and a predicate.
;; The predicate reads the target PATH and the SOURCE buffer, and answers #t
;; to refuse. SOURCE is #f when a program writes a file it owns (a theme file,
;; a cache, a test fixture), and the rules that need a buffer pass on those.
;;
;; The list is data: write-rules reads it, a package appends to it. This is
;; why there is no policy language here. A rule needs buffer-path, the buffer
;; locals and the file system, and Scheme already reads all three. A language
;; that could express this rule would have to reach the same three things,
;; and then it would be Scheme with worse spelling.
;;
;; The rule that exists first: on 2026-09-09 layouts.ex, 3982 lines, became
;; the 730-line transcript of a chat buffer. The daemon then could not boot,
;; because a clobbered .ex fails the compile.

(domain! 'files)
(effects! '(pure))

(defvar '*write-rules* '())

;; a one-shot permit, and it names the file it permits. The door spends it,
;; so an error on the way cannot leave the rules off, and a permit for one
;; file can never carry a write to another.
(defvar '*write-permit* #f)

;; The raw primitives, kept under their own names before the shadows below
;; take the plain ones. The boundp guard matters: a hot reload of this file
;; re-evaluates these two forms, and without it the raw name would capture
;; the shadow and the door would call itself.
(define raw-write-file!
  (if (boundp 'raw-write-file!) raw-write-file! write-file!))
(define raw-buffer-save!
  (if (boundp 'raw-buffer-save!) raw-buffer-save! buffer-save!))

;; CONFIRMABLE? says whether a human answering a question can set this rule
;; aside. A rule about clobbering is confirmable, because overwriting a file
;; on purpose is a real gesture. A rule about where a kind of file may live
;; is not: no answer makes a .scm belong outside a Scheme root.
(define (defwrite-rule! name reason confirmable? pred)
  (set! *write-rules*
        (append (remove (lambda (r) (equal? (car r) name)) *write-rules*)
                (list (list name reason confirmable? pred))))
  name)

(define (write-rules) *write-rules*)

(define (write-rule-name r) (car r))
(define (write-rule-reason r) (cadr r))
(define (write-rule-confirmable? r) (caddr r))
(define (write-rule-pred r) (cadr (cddr r)))

;; #f when the write is allowed, else the reason it is not.
(define (write-refusal path source permitted?)
  (let loop ((rules *write-rules*))
    (cond ((null? rules) #f)
          ((and permitted? (write-rule-confirmable? (car rules)))
           (loop (cdr rules)))
          (((write-rule-pred (car rules)) path source)
           (string-append (write-rule-reason (car rules))
                          " [" (symbol->string (write-rule-name (car rules))) "]"))
          (else (loop (cdr rules))))))

;; Let the next write to PATH set the confirmable rules aside. Only a human
;; answer reaches this: the overwrite question in write-file. An agent never
;; sees that question, so an agent never gets the permit.
(define (allow-one-write! path)
  (set! *write-permit* path)
  path)

;; the door. Spend the permit whatever the verdict, so it never outlives the
;; write it was given for.
(define (write-check! path source)
  (let ((permitted? (equal? *write-permit* path)))
    (set! *write-permit* #f)
    (write-refusal path source permitted?)))

(define (write-refuse! path reason)
  (error (string-append "Refused to write " (abbreviate-file-name path)
                        ": " reason)))

(effects! '(write))

;; PATH is the file; TEXT is what goes in it; SOURCE is the buffer whose text
;; this is, or absent when a program writes a file it owns.
(define (write-file! path &optional text source)
  (let ((no (write-check! path (if source source #f))))
    (if no
        (write-refuse! path no)
        (raw-write-file! path text))))

(define (buffer-save! &optional path)
  (let* ((source (current-buffer))
         (target (if path path (buffer-path source))))
    (if (not target)
        (raw-buffer-save!)
        (let ((no (write-check! target source)))
          (cond (no (write-refuse! target no))
                (path (raw-buffer-save! path))
                (else (raw-buffer-save!)))))))

(effects! '(read))

;; #t when writing OLD to P replaces a file that OLD is not already the
;; buffer for. This is the question write-file asks a person.
(define (write-overwrites? old p)
  (and (file-exists? p)
       (not (file-directory? p))
       (not (equal? (buffer-path old) p))))

(define (write--under-root? path root)
  (and (string? root)
       (let ((r (file-realpath root)))
         (or (equal? path r)
             (string-prefix? (string-append r "/") path)))))

;; Where a .scm file may live. The priv tree is the editor's own source; the
;; config home holds init.scm, custom.scm and the user's packages. Add a
;; directory here to work on Scheme somewhere else.
(defvar '*scheme-write-roots* '())

(define (scheme-write-roots)
  (append (list (compos-priv-dir) (compos-home)) *scheme-write-roots*))

(effects! '(pure))

;; 1. The disaster rule. A buffer writes the file it read, or a file that is
;;    not there yet. It never writes over a file whose text it never held:
;;    that text is not the file plus edits, it is a replacement.
(defwrite-rule! 'buffer-reads-what-it-writes
  "the file is there and this buffer never read it" #t
  (lambda (path source)
    (and source (write-overwrites? source path))))

;; A directory that already holds a .scm file is a Scheme directory. This is
;; what lets the rule below leave every worktree and every other project
;; alone, while a stray .scm still cannot appear in a directory that has
;; none. The scan runs only when the file is not there yet.
(define (scheme-directory? dir)
  (let loop ((names (list-dir dir)))
    (cond ((null? names) #f)
          ((string-suffix? ".scm" (car names)) #t)
          (else (loop (cdr names))))))

(define (under-scheme-root? path)
  (let ((real (file-realpath path)))
    (let loop ((roots (scheme-write-roots)))
      (cond ((null? roots) #f)
            ((write--under-root? real (car roots)) #t)
            (else (loop (cdr roots)))))))

;; 2. A Scheme file is source, and source belongs where the source is. A .scm
;;    may join a directory that already holds one, and it may start a new one
;;    under a Scheme root. It may not appear anywhere else. No answer to a
;;    question changes where a kind of file lives, so this rule is absolute:
;;    to work on Scheme somewhere new, name the directory in
;;    *scheme-write-roots*.
(defwrite-rule! 'scheme-files-in-scheme-roots
  "a .scm file belongs beside other Scheme, or under a Scheme root; see *scheme-write-roots*" #f
  (lambda (path source)
    (and source
         (string-suffix? ".scm" path)
         (not (file-exists? path))
         (not (under-scheme-root? path))
         (not (scheme-directory? (path-directory path))))))

;; 3. A chat buffer holds a rendering of a conversation. The only files it
;;    can become are the ones that read back as one. No answer to a question
;;    puts a transcript in a source file, so this rule is absolute too.
(defwrite-rule! 'chat-writes-chat-files
  "a chat buffer writes only a .chat or a .md file" #f
  (lambda (path source)
    (and source
         (buffer-local source 'agent-slug)
         (not (string-suffix? ".chat" path))
         (not (string-suffix? ".md" path)))))

(effects! '(read))

(define-command "write-rules" "List the rules that decide which writes happen"
  (lambda ()
    (for-each
      (lambda (r)
        (message (string-append (symbol->string (write-rule-name r))
                                (if (write-rule-confirmable? r)
                                    " (a person can confirm past it): "
                                    " (absolute): ")
                                (write-rule-reason r))))
      *write-rules*)
    (message (string-append (number->string (length *write-rules*))
                            " write rules; see *messages*"))))

;; remote buffers save over ssh, never through the local filesystem
(define (save-remote-buffer! bpath)
  (let ((hp (remote-parse bpath)))
    (let ((r (remote-write (car hp) (cadr hp) (buffer-text (current-buffer)))))
      (if (pair? r)   ; (error MSG)
          (message (string-append "Write failed: " (cadr r)))
          (begin
            (buffer-mark-saved! (current-buffer))
            (run-hooks 'after-save-hook)
            (message (string-append "Wrote " bpath)))))))

(define-command "save-buffer" "Save the current buffer to its file"
  (lambda ()
    (run-hooks 'before-save-hook)
    (let ((bpath (buffer-path (current-buffer))))
      (cond ((and bpath (remote-path? bpath)) (save-remote-buffer! bpath))
            ;; a rich chat's buffer text is a rendering (cards, folds, the
            ;; input marker); what belongs in the FILE is its identity plus
            ;; the portable transcript, which is what an opened .chat reads
            ((and bpath (boundp (quote chat-file-text))
                  (chat-file-text (current-buffer)))
             (write-file! bpath (chat-file-text (current-buffer))
                          (current-buffer))
             (buffer-mark-saved! (current-buffer))
             (run-hooks 'after-save-hook)
             (message (string-append "Wrote " bpath)))
            (else (save-local-buffer!))))))

(define (save-local-buffer!)
    (let ((path (buffer-save!)))
      (cond
        (path
         (run-hooks 'after-save-hook)
         (message (string-append "Wrote " path)))
        ;; the name is a file on disk, and this buffer never read it: the
        ;; text here is not that file plus edits, so writing it there is
        ;; a clobber. write-file is the gesture that writes over a file
        ;; on purpose.
        ((buffer-shadows-file? (current-buffer))
         (error (string-append
                  (abbreviate-file-name (current-buffer))
                  " exists on disk and this buffer never read it."
                  " Use write-file to write over it.")))
        ;; the buffer name IS an absolute path: the file name is known,
        ;; so save there and adopt the path — no prompt. C-x C-w is the
        ;; gesture that picks a different file.
        ((and (string-prefix? "/" (current-buffer))
              (not (remote-path? (current-buffer))))
         (let ((p (buffer-save! (current-buffer))))
           (unless (buffer-local (current-buffer) 'mode-name)
             (auto-mode p))
           (run-hooks 'after-save-hook)
           (message (string-append "Wrote " p))))
        ;; no file name at all: C-x C-s falls through to write-file
        (else (run-command "write-file")))))

;; write-file makes the buffer BECOME the file buffer: visit reads the
;; file back and auto-mode applies — a chat saved as .chat opens as a
;; chat, forever after C-x C-s just saves.
;; An answer that names a directory writes the buffer's own name into
;; it, as Emacs does. A chat that a person writes somewhere on purpose
;; works there from then on: the directory is chat identity, and the
;; .chat header carries it across a restart.
(define (write-file-target old path0)
  (let ((p (expand-path (normalize-file-input (string-trim path0)))))
    (if (file-directory? p)
        (string-append p "/" (write-file-default-name old))
        p)))

;; C-x C-w over a file that is already there is a real gesture, so a person
;; may do it. The question is the only way past the confirmable write rules,
;; and the answer buys exactly one write, to exactly this file. An agent
;; never sees a question, so this door does not open for one.
(define (write-buffer-to-file! old path0)
  (unless (equal? (string-trim path0) "")
    (let ((p (write-file-target old path0)))
      (if (write-overwrites? old p)
          (y-or-n (string-append (abbreviate-file-name p) " is a file. Replace it with "
                                 old "?")
                  (lambda ()
                    (allow-one-write! p)
                    (write-buffer-to-file-now! old p)))
          (write-buffer-to-file-now! old p)))))

(define (write-buffer-to-file-now! old p)
  (if (equal? p old)
          ;; the buffer already carries this name: adopt, do not re-visit
          (begin
            (buffer-save! p)
            (run-hooks 'after-save-hook)
            (message (string-append "Wrote " p)))
          (let ((g (buffer-group old))
                (record (buffer-local old 'chat-wire-turns))
                (chat? (buffer-local old 'agent-slug)))
            (when chat?
              (buffer-set-local! old 'chat-directory (path-directory p)))
            (write-file! p (or (chat-file-text old) (buffer-text old)) old)
            (visit p)
            (when g (buffer-set-local! (current-buffer) 'group g))
            (when record
              (buffer-set-local! (current-buffer) 'chat-wire-turns record))
            (when chat?
              (buffer-set-local! (current-buffer) 'chat-directory
                                 (path-directory p)))
            (buffer-kill! old)
            (run-hooks 'after-save-hook)
            (message (string-append "Wrote " p)))))

;; A pathless buffer still has a useful name and mode. Use both when C-x C-w
;; asks for a destination. Outer stars are editor notation, not filename
;; characters. The mode supplies an extension only when the name has none
;; that the editor already recognizes.
(define (write-file-buffer-stem name)
  (let ((n (string-length name)))
    (let ((stem (if (and (> n 1)
                         (string-prefix? "*" name)
                         (string-suffix? "*" name))
                    (substring name 1 (- n 1))
                    name)))
      (if (equal? (string-trim stem) "") "untitled" stem))))

(define (write-file-mode-extension mode)
  (let loop ((entries *auto-mode-alist*))
    (cond ((or (not mode) (null? entries)) "")
          ((equal? mode (cadr (car entries))) (car (car entries)))
          (else (loop (cdr entries))))))

(define (write-file-default-name buf)
  (let* ((stem (write-file-buffer-stem buf))
         (mode (buffer-local buf 'mode-name))
         (ext (if (auto-mode-for stem)
                  ""
                  (write-file-mode-extension mode))))
    (string-append stem ext)))

(define (write-file-default-path buf)
  (let ((path (buffer-path buf)))
    (if (and (string? path) (not (equal? path "")))
        path
        (string-append (default-directory) (write-file-default-name buf)))))

;;; --- delete-file ---------------------------------------------------------------
;;; Emacs delete-file, as a command. The prompt starts on this buffer's
;;; file, and a yes-or-no question stands between RET and the disk. The
;;; file goes to the trash (Emacs delete-by-moving-to-trash); a prefix
;;; argument deletes it for good. A buffer that visits the file stays:
;;; its text is still yours, as in Emacs.

;; what the prompt offers first: this buffer's file, else the directory
(define (delete-file-default buf)
  (or (buffer-path buf) (default-directory)))

;; trash or delete PATH. -> the path acted on, or #f when nothing is there
(define (delete-file-path! path permanent?)
  (let ((full (expand-path (normalize-file-input path))))
    (cond ((not (or (file-exists? full) (file-directory? full))) #f)
          (permanent? (delete-file! full) full)
          (else (trash-file! full) full))))

(define (delete-file--ask! path permanent?)
  (let ((full (expand-path (normalize-file-input path))))
    (if (not (or (file-exists? full) (file-directory? full)))
        (message (string-append "No such file: " (abbreviate-file-name full)))
        (yes-or-no-p
          (string-append (if permanent? "Delete permanently " "Move to trash ")
                         (abbreviate-file-name full) "?")
          (lambda (yes)
            (if (not yes)
                (message "Cancelled")
                (begin
                  (delete-file-path! full permanent?)
                  (message (string-append (if permanent? "Deleted " "Trashed ")
                                          (abbreviate-file-name full))))))))))

(define-command "delete-file"
  "Delete a file, this buffer's by default: to the trash, or for good with a prefix argument"
  (interactive 'P)
  (lambda (arg)
    (read-file-name-initial "Delete file: " (delete-file-default (current-buffer))
      (lambda (input) (delete-file--ask! input (and arg #t))))))

(public! 'delete-file-path!
  "(delete-file-path! PATH PERMANENT?) — move PATH to the trash, or delete it when PERMANENT?; the path, or #f when nothing is there")

(define-command "write-file" "Write the buffer to a file; the buffer becomes that file's buffer"
  (lambda ()
    (let ((old (current-buffer)))
      ;; the answer names a NEW file: RET writes the typed text, and a
      ;; fuzzy match on a file already there does not take the write.
      ;; C-n and TAB still pick a candidate on purpose.
      (read-file-name-initial (string-append "Write " old " to file: ")
        (write-file-default-path old)
        (lambda (p) (write-buffer-to-file! old p))
        (list (list 'preselect 'prompt))))))

;; Save a buffer that is not the current one. save-buffer acts on the
;; current buffer, and it must: the remote, chat and no-file branches all
;; read it. So the save borrows the window and gives it back. A caller
;; that saves a whole set — save-some-buffers, project-kill-all — needs
;; exactly this and nothing more.
(define (save-buffer-named! b)
  (let ((here (current-buffer)))
    (switch-to-buffer-here! b)
    (run-command "save-buffer")
    (when (buffer-exists? here) (switch-to-buffer-here! here))))

;; Filename completion — pure Scheme over list-dir/string primitives.
;; A completion fn maps input -> (list new-input candidates).
;; Emacs' double-slash rule: "~/foo//etc" means "/etc" — typing an absolute
;; path over the default-directory prefill just works.
(define (normalize-file-input input)
  (let ((i (string-rindex input "//")))
    (if i
        (substring input (+ i 1) (string-length input))
        input)))

;; The host file primitive creates a buffer below the Scheme buffer-create
;; wrapper. Wrap it here so file buffers use the same creation event.
;;
;; UNREAD? binds the buffer to the file without reading it. The file is
;; shown from disk by its own viewer, so the buffer holds no bytes: see
;; file-shown-from-disk? below and browser-file-mode.
(define (find-file path &optional session-only? unread?)
  (let* ((name (expand-path (normalize-file-input path)))
         (new (not (buffer-known? name)))
         (buf (raw-find-file name (not session-only?) (not unread?))))
    (when new
      (buffer-created! buf)
      ;; find-file is the quiet loading boundary used by agent read/edit
      ;; tools. A real user visit below promotes this canonical buffer.
      (when (boundp (quote buffer-context-only!))
        (buffer-context-only! buf)))
    buf))

(define (path-split input)
  (let ((idx (string-rindex input "/")))
    (if idx
        (list (substring input 0 (+ idx 1))
              (substring input (+ idx 1) (string-length input)))
        (list "" input))))

;; A candidate is a bare name and the annotator stats a path, so the
;; listing says which directory it listed. Every file prompt goes through
;; here, and nothing else has to know the annotator needs it.
;; A prompt shows eight rows at a time. Annotating every entry to show
;; eight is the file prompt's worst case: the annotator stats the file and
;; reads auto-mode-alist for each one, so 5000 entries cost 1.8s on the
;; :ui lane and the editor stops between keystrokes. Past this many
;; entries a person does not read the listing, they type to narrow it, so
;; hand over bare names and let the typing do the work. The core takes
;; plain strings wherever it takes (NAME HINT) pairs.
(define *file-annotate-limit* 500)

(define (file-candidates dir names)
  (set! *marginalia-file-dir* dir)
  (if (> (length names) *file-annotate-limit*)
      names
      (annotate 'file names)))

;; (file-complete input selected) -> (list new-input candidates)
;; selected: a candidate the user arrowed onto — inserted into the path,
;; directories auto-descend and list their contents.
(define (file-complete input0 selected)
  (if selected
      ;; insert the arrowed-onto candidate verbatim: directories descend to
      ;; their listing, files complete to themselves — no further chaining
      (let ((parts (path-split (normalize-file-input input0))))
        (let ((ni (string-append (car parts) selected)))
          (if (string-suffix? "/" selected)
              (list ni (file-candidates ni (list-dir ni)))
              (list ni (file-candidates (car parts) (list selected))))))
      (let ((input (normalize-file-input input0)))
        (let ((parts (path-split input)))
          (let ((dir (car parts))
                (base (cadr parts)))
            (let ((entries (list-dir dir)))
              (let ((matches (filter (lambda (e) (string-prefix? base e)) entries)))
                (if (null? matches)
                    (list input (file-candidates dir entries))
                    (let ((ni (string-append dir (common-prefix matches))))
                      (if (and (null? (cdr matches))
                               (string-suffix? "/" (car matches)))
                          ;; unique directory: descend and list (stop there —
                          ;; don't chain-complete into a lone file)
                          (list ni (file-candidates ni (list-dir ni)))
                          (list ni (file-candidates dir matches))))))))))))

;; live listing while typing (vertico-style) — but only re-list when the
;; DIRECTORY part changes; basename narrowing is the core's display filter.
;; Re-listing big directories on every keystroke stats thousands of files.
(define *file-nav-dir* #f)

(define (file-nav-change inp)
  (let ((dir (car (path-split (normalize-file-input inp)))))
    (if (equal? dir *file-nav-dir*)
        #t
        (begin
          (set! *file-nav-dir* dir)
          (minibuffer-set-candidates! (file-candidates dir (list-dir dir)))))))

;; ONE file prompt (dup #17): minibuffer with filename completion. INITIAL
;; chooses its starting directory and text. K receives the confirmed text
;; exactly as typed. OPTS is an alist of extra prompt options, such as
;; (preselect prompt).
;; match-hint: the annotation names the mode the file opens in, so "dired"
;; narrows the listing to the directories and "elixir" to the .ex files.
(define (read-file-name-initial prompt initial k &optional opts)
  (let* ((dd (default-directory))
         (seed (if (and (string? initial) (not (equal? initial ""))) initial dd))
         (seed-dir (car (path-split (normalize-file-input seed))))
         (dir (if (equal? seed-dir "") dd seed-dir)))
    (set! *file-nav-dir* dir)
    (let ((cands (file-candidates dir (list-dir dir))))
      (minibuffer-read* prompt cands
        (append
          (list (list 'complete file-complete)
                (list 'change file-nav-change)
                (list 'initial seed)
                ;; the icon leads the annotation, so the mode is the second
                ;; field: both must be in reach for "dired" to find a directory
                (list 'match-hint 2)
                (list 'style #f)
                (list 'confirm k))
          (or opts '()))))))

(define (read-file-name prompt k)
  (read-file-name-initial prompt (default-directory) k))

;; Emacs' abbreviate-file-name: the home directory is "~". A modeline or a
;; prompt says the short form; the buffer keeps the absolute path.
(define (abbreviate-file-name path)
  (let ((home (getenv "HOME")))
    (cond ((not (string? path)) path)
          ((not (and (string? home) (> (string-length home) 1))) path)
          ((equal? path home) "~")
          ((string-prefix? (string-append home "/") path)
           (string-append "~" (substring path (string-length home)
                                         (string-length path))))
          (else path))))

;;; --- remote files (/ssh:host:/path — TRAMP-lite) ---------------------------
;;; Transport is two primitives (remote-read / remote-write; ssh underneath,
;;; so ~/.ssh/config aliases, agent and ControlMaster all apply). Everything
;;; else is policy here: a remote buffer is an ordinary file buffer whose
;;; path starts with /ssh: — modes, undo, revert (kill + re-visit) and
;;; desktop restore (re-fetch via visit) just work; only visit and
;;; save-buffer branch on the prefix.

(define (remote-path? p) (string-prefix? "/ssh:" p))

;; "/ssh:user@host:/path" -> (host path), #f if malformed
(define (remote-parse p)
  (let ((rest (substring p 5 (string-length p))))
    (let ((i (string-index rest ":")))
      (and i (> i 0)
           (list (substring rest 0 i)
                 (substring rest (+ i 1) (string-length rest)))))))

;; One ls -lA round-trip per directory feeds both list-dir and file-stat:
;; listing a dir re-fetches and caches, stat lookups ride the cache — so a
;; dired refresh costs one ssh call, not one per file.
(define *remote-ls-cache* '())   ; ((dir ((name (perms size date)) ...)) ...)
(define *remote-ls-errors* '())  ; ((dir message) ...)

(define (remote-dir-key d)       ; ".../log/" -> ".../log", but keep ":/" roots
  (if (and (string-suffix? "/" d) (not (string-suffix? ":/" d)))
      (substring d 0 (- (string-length d) 1))
      d))

(define (remote-ls! dir0)
  (let ((dir (remote-dir-key dir0)))
    (let ((hp (remote-parse dir)))
      (if (not hp)
          '()
          (let ((r (remote-list-dir (car hp) (cadr hp))))
            (if (and (pair? r) (symbol? (car r)))   ; (error MSG)
                (begin
                  (set! *remote-ls-errors*
                    (cons (list dir (cadr r))
                          (filter (lambda (e) (not (equal? (car e) dir)))
                                  *remote-ls-errors*)))
                  (message (cadr r))
                  '())
                (begin
                  (set! *remote-ls-errors*
                    (filter (lambda (e) (not (equal? (car e) dir)))
                            *remote-ls-errors*))
                  (set! *remote-ls-cache*
                    (cons (list dir r)
                          (filter (lambda (c) (not (equal? (car c) dir)))
                                  *remote-ls-cache*)))
                  r)))))))

(define (remote-ls-cached dir0)
  (let ((c (assoc (remote-dir-key dir0) *remote-ls-cache*)))
    (if c (cadr c) (remote-ls! dir0))))

(define (remote-sh! host cmd)
  (let ((r (remote-sh host cmd)))
    (if (pair? r) (begin (message (cadr r)) #f) #t)))

;; list-dir / file-stat / delete-file! / make-directory! grow a remote
;; branch under the same names and contracts — dired, file completion and
;; friends work on /ssh: paths without knowing it.
(define (list-dir dir)
  (if (remote-path? dir)
      (map car (remote-ls! dir))
      (local-list-dir dir)))


(define (remote-entry-type perms)
  (cond ((string-prefix? "d" perms) "directory")
        ((string-prefix? "l" perms) "symlink")
        ((string-prefix? "-" perms) "regular")
        (else "other")))

(define (remote-entry-info entry)
  (let* ((name (car entry))
         (st (cadr entry))
         (n (string->number (cadr st))))
    (list 'name name
          'type (remote-entry-type (car st))
          'bytes (if (number? n) n 0)
          'mtime 0
          'size (cadr st)
          'date (caddr st)
          'perms (car st))))

(define (directory-entries dir)
  (if (remote-path? dir)
      (let ((entries (remote-ls! dir))
            (failure (assoc (remote-dir-key dir) *remote-ls-errors*)))
        (if failure
            (list 'error (cadr failure))
            (map remote-entry-info entries)))
      (local-directory-entries dir)))

(define (file-stat p0)
  (if (remote-path? p0)
      (let ((parts (path-split (remote-dir-key p0))))
        (let ((entries (remote-ls-cached (car parts)))
              (base (cadr parts)))
          (let ((e (or (assoc base entries)
                       (assoc (string-append base "/") entries))))
            (if e (cadr e) (list "----------" "?" "?")))))
      (local-file-stat p0)))

(define (delete-file! p)
  (if (remote-path? p)
      (let ((hp (remote-parse p)))
        (let ((q (sh-quote (cadr hp))))
          ;; parity with the local primitive: files rm, dirs rmdir (empty only)
          (remote-sh! (car hp)
            (string-append "if [ -L " q " ]; then rm -- " q
                           "; elif [ -d " q " ]; then rmdir -- " q
                           "; else rm -- " q "; fi"))))
      (local-delete-file! p)))

(define (make-directory! p)
  (if (remote-path? p)
      (let ((hp (remote-parse p)))
        (remote-sh! (car hp) (string-append "mkdir -p -- " (sh-quote (cadr hp)))))
      (local-make-directory! p)))

(define (rename-file! source destination)
  (cond
    ((and (remote-path? source) (remote-path? destination))
     (let ((from (remote-parse source)) (to (remote-parse destination)))
       (if (not (equal? (car from) (car to)))
           (begin (message "Remote rename requires one host") #f)
           (and (remote-sh! (car from)
                  (string-append "mkdir -p -- "
                                 (sh-quote (path-directory (cadr to)))
                                 " && test ! -e " (sh-quote (cadr to))
                                 " && mv -- " (sh-quote (cadr from))
                                 " " (sh-quote (cadr to))))
                destination))))
    ((or (remote-path? source) (remote-path? destination))
     (message "Copy between local and remote paths first")
     #f)
    (else (local-rename-file! source destination))))

(define (copy-file! source destination)
  (cond
    ((and (remote-path? source) (remote-path? destination))
     (let ((from (remote-parse source)) (to (remote-parse destination)))
       (if (not (equal? (car from) (car to)))
           (begin (message "Remote copy requires one host") #f)
           (and (remote-sh! (car from)
                  (string-append "mkdir -p -- "
                                 (sh-quote (path-directory (cadr to)))
                                 " && test ! -e " (sh-quote (cadr to))
                                 " && cp -R -- " (sh-quote (cadr from))
                                 " " (sh-quote (cadr to))))
                destination))))
    ((or (remote-path? source) (remote-path? destination))
     (message "Local and remote copy is not available")
     #f)
    (else (local-copy-file! source destination))))

(define (trash-file! p)
  (if (remote-path? p)
      (let* ((hp (remote-parse p))
             (q (sh-quote (cadr hp))))
        (remote-sh! (car hp)
          (string-append
            "trash=\"$HOME/.local/share/Trash/files\"; mkdir -p -- \"$trash\"; "
            "base=$(basename -- " q "); target=\"$trash/$base\"; n=1; "
            "while [ -e \"$target\" ]; do target=\"$trash/$base.$n\"; n=$((n+1)); done; "
            "mv -- " q " \"$target\"")))
      (local-trash-file! p)))

(define (set-file-mode! p mode)
  (if (remote-path? p)
      (let ((hp (remote-parse p)))
        (remote-sh! (car hp)
          (string-append "chmod -- " (sh-quote mode) " " (sh-quote (cadr hp)))))
      (local-set-file-mode! p mode)))

(define (touch-file! p)
  (if (remote-path? p)
      (let ((hp (remote-parse p)))
        (remote-sh! (car hp) (string-append "touch -- " (sh-quote (cadr hp)))))
      (local-touch-file! p)))

(define (make-symlink! target link)
  (cond
    ((and (remote-path? target) (remote-path? link))
     (let ((from (remote-parse target)) (to (remote-parse link)))
       (if (not (equal? (car from) (car to)))
           (begin (message "Remote link requires one host") #f)
           (remote-sh! (car from)
             (string-append "ln -s -- " (sh-quote (cadr from))
                            " " (sh-quote (cadr to)))))))
    ((remote-path? link)
     (let ((to (remote-parse link)))
       (remote-sh! (car to)
         (string-append "ln -s -- " (sh-quote target)
                        " " (sh-quote (cadr to))))))
    ((remote-path? target)
     (message "A local link cannot target a remote path")
     #f)
    (else (local-make-symlink! target link))))

(define (remote-visit path)
  (if (buffer-exists? path)
      (begin
        (switch-to-buffer! path)
        (current-buffer))
      (let ((hp (remote-parse path)))
        (if (not hp)
            (begin
              (message "Remote path is /ssh:HOST:/PATH")
              #f)
            (let ((r (remote-read (car hp) (cadr hp))))
              (cond
                ((equal? r 'directory) (dired-open path))
                ((pair? r)   ; (error MSG) — unreachable host, unreadable file
                 (message (string-append path ": " (cadr r)))
                 #f)
                (else
                  (begin
                    ;; find-file names the buffer after the path and records
                    ;; it as the buffer's file (no such local file — empty)
                    (find-file path)
                    (when (string? r)
                      (buffer-insert! path 0 r)
                      (buffer-mark-saved! path))
                    (switch-to-buffer! path)
                    (goto-char! 0)
                    (auto-mode path)
                    (run-hooks 'find-file-hook)
                    (if (equal? r 'absent) (message "(New remote file)"))
                    (current-buffer)))))))))

(define (agent-edit-author? author)
  (and (string? author) (string-prefix? "agent:" author)))

(define (visit-apply-group! buf group existing)
  (when (and buf group)
    (if existing
        (buffer-add-group! buf group)
        (buffer-move-to-group! buf group))))

;;; A file too big to open
;;;
;;; Emacs asks before it visits a large file (large-file-warning-threshold,
;;; 10 MB). Here the read is the small half of the cost. The text becomes a
;;; rope, the rope becomes a checkpoint on disk, the checkpoint restores at
;;; every boot, and the renderer builds segments for every line. A 189 MB
;;; screen recording opened by accident wrote a 361 MB checkpoint, pinned
;;; the Editor for seven seconds on each boot, and through that took the
;;; desktop's own globals down with it.
;;;
;;; So a visit REFUSES, and the reader who means it answers a question. The
;;; refusal is the mechanism, the question is the policy, and a caller that
;;; cannot ask one — an agent, a restore, a peek — gets the refusal.
;;;
;;; layouts.scm makes the variable customizable.

(define large-file-warning-threshold 10485760)

;; #t when PATH opens in a viewer that reads the file from disk itself: a
;; picture, a sound, a video. The buffer is bound to the path and holds no
;; bytes, so the size of the file costs the editor nothing and no cap here
;; applies to it. file-view.scm answers which files those are.
(define (file-shown-from-disk? path)
  (and (string? path)
       (boundp (quote browser-file-path?))
       (browser-file-path? (normalize-file-input path))
       #t))

;; #t when the buffer was bound to its file and never read it. Nothing in
;; it stands for the file: it must not be saved over it, and following the
;; file would read the bytes the viewer exists to avoid.
(define (buffer-unread-file? buf)
  (and (buffer-known? buf)
       (buffer-local buf 'unread-file)
       #t))

;; #t when opening PATH would cost more than a file should. A path with a
;; buffer already answers #f: the work is paid. A directory and a remote
;; path answer #f, because file-size reads local files only. A file shown
;; from disk answers #f whatever its size: it is never read.
(define (file-too-big? path)
  (and (> large-file-warning-threshold 0)
       (string? path)
       (not (file-shown-from-disk? path))
       (let ((p (normalize-file-input path)))
         (and (not (buffer-known? p))
              (not (remote-path? p))
              (not (file-directory? p))
              (> (file-size p) large-file-warning-threshold)))))

;; Say the size, and say the way in. The reader reaches the file through
;; the question, so the message names the command that asks it.
(define (file-too-big-message path)
  (let ((p (normalize-file-input path)))
    (string-append (cadr (path-split p)) " is " (cadr (file-stat p))
                   ", over large-file-warning-threshold. "
                   "M-x find-file asks before it opens it.")))

;; The way in. The buffer is not persistent: it holds the file for this
;; session, writes no checkpoint, and is not there at the next boot. That
;; is the whole point — one yes must not cost every later boot.
(define (visit-anyway path0 &optional group)
  (let* ((path (normalize-file-input path0))
         (existing (buffer-known? path))
         ;; session-only: no checkpoint, and no work at the next boot
         (file-buffer (find-file path #t)))
    (visit-apply-group! file-buffer group existing)
    (switch-to-buffer! file-buffer)
    (auto-mode path)
    (run-hooks 'find-file-hook)
    (message (string-append (cadr (path-split path))
                            " is open for this session only; it is not saved across a restart."))
    (current-buffer)))

(define (visit path0 &optional group)
  (let* ((path (normalize-file-input path0))
         ;; A directory answers to one buffer name whatever the prompt
         ;; spelled: file completion offers "/dir/" and Dired names the
         ;; buffer "/dir". Reading existence from the raw path calls a
         ;; live buffer new, and a new buffer MOVES to the destination
         ;; group instead of joining it, which silently drops the
         ;; memberships it already had.
         (existing (or (buffer-known? path)
                       (and (boundp (quote dired-normalize-dir))
                            (file-directory? path)
                            (buffer-known? (dired-normalize-dir path)))))
         (buf
           (cond
             ((remote-path? path) (remote-visit path))
             ((file-directory? path) (dired-open path))
             ((file-too-big? path) (message (file-too-big-message path)) #f)
             (else
               (let ((file-buffer (find-file path #f (file-shown-from-disk? path))))
                 ;; An explicit destination joins before display. The derived
                 ;; current group therefore never sees a half-placed buffer.
                 (visit-apply-group! file-buffer group existing)
                 (switch-to-buffer! file-buffer)
                 (auto-mode path)
                 (run-hooks 'find-file-hook)
                 (current-buffer))))))
    ;; A user visit reveals the canonical buffer with all unsaved state.
    ;; Agent visits keep context-only buffers out of user-facing lists.
    (when (and buf
               (boundp (quote buffer-promote!))
               (not (agent-edit-author? (current-edit-author))))
      (buffer-promote! buf))
    ;; A named destination overrides the inherited frame group for new work.
    ;; Existing work adds the destination without losing its memberships.
    (visit-apply-group! buf group existing)
    buf))

;; The same open, without a window: the buffer is made, joins the
;; group, and takes its mode with the buffer current but not shown. A
;; peek opens this way, so the selected window never shows the file on
;; its way to the popup (find-file-noselect).
(define (visit-quietly path0 &optional group)
  (let* ((path (normalize-file-input path0))
         (existing (buffer-known? path)))
    (if (or (remote-path? path) (file-directory? path))
        (visit path group)
      (if (file-too-big? path)
          (begin (message (file-too-big-message path)) #f)
        (let ((file-buffer (find-file path #f (file-shown-from-disk? path))))
          (visit-apply-group! file-buffer group existing)
          (with-current-buffer file-buffer
            (lambda ()
              (auto-mode path)
              (run-hooks 'find-file-hook)))
          file-buffer)))))

;; Compatibility name for packages and user config.
(define (visit-in-group path group) (visit path group))

;; A package supplies the prefix reader. Its callback receives the chosen
;; group. This keeps the prefix mechanism separate from file completion.
(define find-file-group-reader (lambda (receive) (receive (frame-group))))

(define (find-file-read &optional group)
  (read-file-name "Find file: "
    (lambda (path)
      (let* ((normalized (normalize-file-input path))
             (existing (buffer-known? normalized)))
        (if (file-too-big? normalized)
            ;; the reader is here, so the reader can answer
            (y-or-n-p
              (string-append (cadr (path-split normalized)) " is "
                             (cadr (file-stat normalized))
                             ". Open it for this session only?")
              (lambda (yes)
                (when yes (visit-anyway normalized (if existing #f group)))))
            (visit normalized (if existing #f group)))))))

(define-command "find-file" "Visit a file, prompting with filename completion"
  (lambda ()
    (if (current-prefix-arg)
        (find-file-group-reader find-file-read)
        (find-file-read (frame-group)))))
(catalog-meta! 'command "find-file" 'domain 'buffers 'effects '(write display))

;; the project a buffer belongs to, as a short name for the prompt.
;; project.scm supplies the real answer through this seam (dup #6);
;; without the package every buffer is projectless.
(define buffer-project-label (lambda (b) ""))

;; Optional workspace packages add one concise identity column to C-x b.
(define buffer-workspace-label (lambda (b) ""))

;; ...and as the ROOT, for context switching (a project is also a group)
(define buffer-project-root (lambda (b) ""))

;; what a buffer name means in a prompt: its mode, its group, its
;; project, then the file it is visiting. The group and project columns
;; show which buffers belong together, and the prompt matches on them
;; (match-hint), so a group or project name finds every member.
(marginalia! 'buffer
  (lambda (b)
    (list (buffer-icon b)
          (or (buffer-local b 'mode-name) "Fundamental")
          (buffer-group-summary b)
          (buffer-project-label b)
          (buffer-workspace-label b)
          ;; a chat has no file: its last column is the group's
          ;; metadata, so the group says what it is for
          (or (buffer-path b)
              (and (chat-buffer? b) (buffer-group b)
                   (group-meta (buffer-group b)))
              ""))))

;; ONE candidate shape for every buffer prompt (dup #6): the name, the
;; marginalia annotator supplies the rest, MRU-ordered — the recency
;; stream, whatever context each buffer lives in. Containers (groups)
;; ride ABOVE this stream in the switcher; see switch-to-buffer.
;; Internals (space-prefixed) stay hidden, as ibuffer hides them.
(define (buffer-candidates-all)
  (annotate 'buffer
    (filter (lambda (b)
              (and (not (string-prefix? " " b))
                   (not (buffer-context-only? b))))
            (buffer-list-mru))))

;; current excluded: first candidate = the buffer you just left, so
;; C-x b RET toggles between two buffers (Emacs buffer ring)
(define (buffer-candidates)
  (filter (lambda (c) (not (equal? (car c) (current-buffer))))
          (buffer-candidates-all)))

;; the buffer prompt's extension seam (dup #6). The command calls this
;; at prompt open with the base candidates; it returns (pool standing
;; pick). POOL is the full candidate list. STANDING is where you are
;; now, and therefore the one place RET must never mean. PICK sees the
;; choice first and returns #t when it handled it. chrome adds browser
;; tabs through this seam instead of redefining the command.
(define switch-buffer-source
  (lambda (cands)
    (list cands (current-buffer) (lambda (picked) #f))))

;; RET with nothing typed takes the FIRST candidate, so the top of the
;; pool IS the default — the prompt must advertise exactly that.
;; containers: every group answers as ONE candidate above the recency
;; stream — the container first, its buffers after. The label is
;; [name]; RET on it switches to the group and restores its layout.
(define (group-container-label g) (string-append "[" (group-label g) "]"))

;; a buffer's short name for a chip: the last path segment. A starred
;; name wrapping a path (*writing:/long/path.md*) shortens the same
;; way and keeps its closing star, so the chip still reads as special.
(define (buffer-short-label b)
  (if (string-contains? b "/")
      (car (reverse (string-split b "/")))
      b))

;; a container renders as its own row shape: kind "container", the
;; group's members as chips, the metadata as the annotation
(define (group-container-candidate g)
  (list (group-container-label g)
        (string-append "group  "
          (number->string (length (group-buffers g))) " buffers"
          (let ((m (group-meta g))) (if m (string-append "  ·  " m) "")))
        "container"
        (map buffer-short-label (take-n (group-buffers-mru g) 4))))

;; C-RET: the picked buffer's CONTEXT comes up — its group, or its
;; project materialized as one. A project is also a group: the first
;; context switch tags the project's open buffers and founds it.
(define (buffer-context-switch! b)
  (let ((focus (lambda ()
                 (let ((w (window-showing b)))
                   (if w (select-window! w) (switch-to-buffer! b)))))
        (bg (buffer-group b)))
    (cond
      (bg (switch-to-group! bg) (focus))
      (else
        (let ((root (buffer-project-root b)))
          (if (equal? root "")
              (begin
                ;; no context to enter — say so instead of a silent
                ;; plain switch that reads as "C-RET did nothing"
                (switch-to-buffer! b)
                (message (string-append b " has no group and no project — plain switch")))
              (begin
                (for-each (lambda (x)
                            (when (and (not (buffer-group x))
                                       (equal? (buffer-project-root x) root))
                              (buffer-set-local! x 'group root)))
                          (buffer-list))
                (switch-to-group! root)
                (focus))))))))

;; ONE history: buffers and groups woven by recency. A group switch
;; was itself an entry (mru-note-group!), so its card sits exactly
;; where history puts it — above the members its restore bumped. The
;; group's card and its buffers all match the group's name, so one
;; search shows the context and its contents together.
(define (switch-history-pool my-group)
  (let* ((bufs (filter (lambda (b)
                              (and (not (string-prefix? " " b))
                                   (not (buffer-context-only? b))))
                            (buffer-list-mru)))
         (annotated (annotate 'buffer bufs)))
    (let loop ((rows (mru-list)) (out '()))
      (if (null? rows)
          ;; buffers never woven (unvisited, or visited but filtered)
          ;; trail behind in their annotated order
          (let ((woven (reverse out)))
            (append woven
                    (filter (lambda (c) (not (member c woven))) annotated)))
          (let* ((r (car rows))
                 (kind (car r))
                 (name (car (cdr r))))
            (cond
              ((and (equal? kind "group")
                    (not (equal? name my-group))
                    (pair? (group-buffers name)))
               (loop (cdr rows) (cons (group-container-candidate name) out)))
              ((equal? kind "buffer")
               (let ((c (assoc name annotated)))
                 (loop (cdr rows) (if c (cons c out) out))))
              (else (loop (cdr rows) out))))))))

;; Packages can repair windows after the core releases a killed buffer.
;; The callback returns a thunk because its policy must inspect the old buffer
;; before the core removes it, then repair the surviving windows afterwards.
(define buffer-kill-raw!
  (if (boundp 'buffer-kill-raw!) buffer-kill-raw! buffer-kill!))
(define buffer-kill-repair (lambda (name) (lambda () #f)))

(define (buffer-kill! name)
  (let ((repair (buffer-kill-repair name)))
    (buffer-kill-raw! name)
    (when repair (repair))))

(define (kill-buffer-confirm! target done)
  ;; The high-level named-buffer kill: process policy, modified-file
  ;; confirmation, user feedback, and completion all live here.
  (let* ((finish (lambda (killed?)
                   (when done (done killed?))))
         (kill! (lambda ()
                  (if (process-running? target) (process-kill! target))
                  (buffer-kill! target)
                  (message (string-append "Killed " target))
                  (finish #t))))
    (cond
      ((not (buffer-known? target))
       (message (string-append "Buffer already gone: " target))
       (finish #f))
      ((and (buffer-path target) (buffer-modified? target))
       (y-or-n (string-append "Buffer " target " modified; kill anyway?")
               kill!
               (lambda ()
                 (message "Not killed")
                 (finish #f))))
      (else (kill!)))))

(define-command "kill-buffer" "Kill a buffer, defaulting to the current one"
  (lambda ()
    (let ((cur (current-buffer)))
      ;; current buffer is the default: first candidate, RET kills it
      (minibuffer-read (string-append "Kill buffer (default " cur "): ")
        (cons (list cur "current") (buffer-candidates))
        (lambda (name)
          (kill-buffer-confirm! (if (equal? name "") cur name)
                                (lambda (killed?) #t)))))))

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
;;; The actions, each a function of NAME and ALIST on *display-buffer-actions*:
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
(define *display-buffer-actions* '())

(define (define-display-action! name fn)
  (set! *display-buffer-actions*
    (cons (list name fn)
          (filter (lambda (e) (not (equal? (car e) name))) *display-buffer-actions*))))

(define (display-action-fn name)
  (let ((e (assoc name *display-buffer-actions*)))
    (and e (cadr e))))

;; Explicit layouts remain targets as their occupied pane count changes.
(define (layout-target) (frame-local 'layout-target))
(define (layout-target-set! name)
  (set-frame-local! 'layout-target name)
  (unless name (set-frame-local! 'layout-slots #f))
  (when (and name (not (frame-local 'layout-slots)))
    (let ((visible (layout-visible-buffers)))
      (layout-target-note-slots!
        (if (and (member name '(main-left main-top)) (pair? visible))
            (cons (car (reverse visible)) (take-n visible (- (length visible) 1)))
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
        (cons (car (reverse visible)) (take-n visible (- (length visible) 1)))
        visible)))

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

;; A user open selects its result. A display records how to quit and keeps focus.
(define (layout-target-open! name select? inhibit-same?)
  (and (fill-candidate? name) (window-fill-member? name)
       (not (buffer-context?))
       (let* ((selected (active-window))
              (focus (window-buffer selected))
              (shown (if inhibit-same?
                         (window-showing-other name selected)
                         (window-showing name)))
              (panes (layout-target-visible-buffers))
              (capacity (layout-target-capacity (layout-target))))
         (cond (shown
                (when select? (select-window! shown))
                shown)
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

;; One window per mode. A group keeps its chats in one window -- the chat
;; pane -- its dired listings in one window, and a list's detail beside the
;; list when the two share a mode. Nothing is remembered: the mode of what a
;; window already holds is the memory, so it lapses of its own accord the
;; moment that window shows something else.
(define (window-mode win)
  (let ((buf (window-buffer win)))
    (and (string? buf) (buffer-local buf 'mode-name))))

(define (window-showing-mode mode &optional except)
  (and (string? mode)
       (let loop ((ws (display--work-windows)))
         (cond ((null? ws) #f)
               ((and (not (equal? (car ws) except))
                     (equal? (window-mode (car ws)) mode))
                (car ws))
               (else (loop (cdr ws)))))))

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

(defvar '*peek-recent* '())
(define *peek-recent-max* 50)

(persist-global! 'peek-recent
  (lambda () *peek-recent*)
  (lambda (v) (set! *peek-recent* (if (or (pair? v) (null? v)) v '()))))

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
        (take-n (cons e (filter (lambda (x) (not (equal? (nth 2 x) (nth 2 e))))
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

(define *mode-layouts* '())        ; ((mode spec) ...)

(define (define-mode-layout! mode spec)
  (set! *mode-layouts*
    (cons (list mode spec)
          (remove (lambda (e) (equal? (car e) mode)) *mode-layouts*)))
  mode)

(define (mode-layout mode)
  (let ((e (assoc mode *mode-layouts*)))
    (and e (cadr e))))

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
  (let* ((kept (take-n buffers capacity))
         (focus (window-buffer (active-window))))
    (if (and (member focus buffers) (not (member focus kept)))
        (append (take-n kept (- capacity 1)) (list focus))
        kept)))

(define (layout--fill-to buffers capacity)
  (let loop ((rest (filter window-fill-primary? (window-fill-buffers)))
             (result (layout--fit buffers capacity)))
    (cond ((>= (length result) capacity) result)
          ((null? rest) result)
          ((member (car rest) result) (loop (cdr rest) result))
          (else (loop (cdr rest) (append result (list (car rest))))))))

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
             (left (take-n buffers left-count))
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
         (panes (if (equal? algorithm 'two-pane) (take-n known 2) known)))
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
        '( ("adaptive" "choose from usable monitor width")
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
        (lambda () (restore-preview!))))))

(define-command "window-layout-free"
  "Drop the frame's target layout: a display may split a window again"
  (lambda ()
    (layout-target-set! #f)
    (message "Layout free: a display may split a window again")))

(for-each
  (lambda (name) (catalog-meta! 'command name 'domain 'windows 'effects '(write display)))
  '("window-layout" "window-layout-free" "window-layout-two-pane"
    "window-layout-columns" "window-layout-rows"
    "window-layout-grid" "window-layout-main-right" "window-layout-main-bottom"))

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

;; q in special buffers: close the popup, or kill this buffer and go back.
;; Every buffer that binds q is a listing you can make again — dired,
;; ibuffer, help, diff, notmuch, agents, mcp-hub. The kill is what stops q
;; from flipping between two listings: a buffer that only moves down the
;; MRU ring is still the candidate the next q picks. buffer-kill! puts the
;; most recent buffer that is not on screen in the window.
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
              (begin
                ;; The core releases the killed buffer's windows: each one
                ;; stays and shows what it showed before (Emacs kill-buffer
                ;; deletes no window), and buffer-kill-repair then fills a
                ;; group window from its group. Only a display's own work is
                ;; undone here first: the window a display made goes with
                ;; the listing; a window the display took shows again what
                ;; it showed.
                (window-quit-restore! (active-window))
                ;; a live process (tail, shell) dies with its buffer
                (if (process-running? cur) (process-kill! cur))
                (buffer-kill! cur))))))))

;; q quits every buffer you cannot type in. The read-only keymap sits
;; between the buffer's own map and the global one, so a mode that wants q
;; for something else — code-mode's exit, notmuch's search — still wins.
(local-set-key* " *read-only*" "q" "quit-window")

;;; --- collect: the prompt continues as a buffer (embark-collect) ------------
;;; C-c C-o closes the prompt and collects the candidates that survive its
;;; input. A prompt can route them to a reusable domain list such as ibuffer.
;;; Other prompts use *Collect*, which keeps preview, accept, and cancel.
;;; The handlers come from the prompt itself — minibuffer-detach! closes it
;;; without firing anything and hands them over.

(define *collect-buffer* "*Collect*")

;; the detached prompt lives in globals, not in buffer-locals: a closure
;; cannot survive a restart, and desktop.etf must not hold one. After a
;; restart the buffer is text — the keys say so and stop.
(define *collect-select* #f)     ; the preview hook, from minibuffer-read-preview
(define *collect-confirm* #f)
(define *collect-cancel* #f)
(define *collect-complete* #f)   ; path prompts resolve a label through it
(define *collect-input* "")
(define *collect-window* #f)     ; the window the prompt ran in

(define (collect-forget!)
  (set! *collect-select* #f)
  (set! *collect-confirm* #f)
  (set! *collect-cancel* #f)
  (set! *collect-complete* #f))

(define (collect-fill! prompt cands)
  (let ((buf *collect-buffer*))
    (buffer-delete-range! buf 0 (buffer-size buf))
    (buffer-append! buf
      (string-append ";; " (string-trim prompt) " "
                     (number->string (length cands))
                     " candidates · n/p previews · RET accepts · q quits\n"))
    (buffer-set-local! buf 'collect-labels (map car cands))
    (for-each
      (lambda (c)
        (buffer-append! buf
          (string-append (car c)
                         (if (equal? (cadr c) "") "" (string-append "  " (cadr c)))
                         "\n")))
      cands)))

;; the list opens in another window: the window the prompt ran in must keep
;; showing what the preview acts on
(define (collect-open! prompt cands)
  (buffer-create *collect-buffer*)
  (collect-fill! prompt cands)
  (let ((showing (window-showing *collect-buffer*)))
    (if showing
        (select-window! showing)
        (begin (split-window! 'v 0.6) (other-window!))))
  (switch-to-buffer! *collect-buffer*)
  (set-mode! "collect-mode")
  (goto-char! 0)
  (next-line!)
  (beginning-of-line!)
  (collect-preview!))

;; the label on the current line — the header is line 0, entries follow
(define (collect-current)
  (if (not (buffer-exists? *collect-buffer*))
      #f
      (collect-label-at)))

(define (collect-label-at)
  (let* ((labels (or (buffer-local *collect-buffer* 'collect-labels) '()))
         (before (substring-bytes (buffer-text *collect-buffer*) 0 (point)))
         (ln (- (length (string-split before "\n")) 2)))
    (if (and (>= ln 0) (< ln (length labels))) (list-ref labels ln) #f)))

;; the preview goes where the prompt's preview went: the window the prompt
;; ran in. If that window is gone, any other window does. The preview must
;; never land in the list itself, so a lone *Collect* window previews
;; nothing.
(define (collect-target-window)
  (let ((me (active-window)))
    (if (and *collect-window* (window-exists? *collect-window*)
             (not (equal? *collect-window* me)))
        *collect-window*
        (other-window-id me))))

(define (collect-preview!)
  (let ((label (collect-current)) (w (collect-target-window)))
    (when (and *collect-select* label)
      (if w
          (let ((back (active-window)))
            (select-window! w)
            (*collect-select* label)
            (set! *collect-window* w)
            (select-window! back))
          (message "No other window to preview in")))))

;; path prompts resolve a label through their completion fn — that is how
;; find-file turns "editor.scm" back into a full path (see mb_confirm_value)
(define (collect-resolve label)
  (if *collect-complete*
      (let ((r (*collect-complete* *collect-input* label)))
        (if (and (pair? r) (string? (car r))) (car r) label))
      label))

(define (collect-close!)
  (if (null? (cdr (window-list)))
      (run-command "quit-window")        ; kills *Collect* and goes back
      (begin (delete-window!) (buffer-kill! *collect-buffer*))))

(define-command "collect-next" "Move down; the preview follows"
  (lambda () (next-line!) (beginning-of-line!) (collect-preview!)))

(define-command "collect-prev" "Move up; the preview follows"
  (lambda ()
    (previous-line!) (beginning-of-line!)
    (unless (collect-current) (next-line!) (beginning-of-line!))
    (collect-preview!)))

(define-command "collect-accept" "Accept the candidate on this line"
  (lambda ()
    (let ((label (collect-current))
          (fn *collect-confirm*)
          (w (collect-target-window)))
      (cond ((not label) (message "No candidate on this line"))
            ((not fn) (message "This list is stale — run the command again"))
            (else
              (let ((value (collect-resolve label)))
                (collect-forget!)
                (collect-close!)
                (when (and w (window-exists? w)) (select-window! w))
                (fn value)))))))

(define-command "collect-quit" "Close the list; put back what the preview moved"
  (lambda ()
    (let ((fn *collect-cancel*) (w (collect-target-window)))
      (collect-forget!)
      (collect-close!)
      (when (and w (window-exists? w)) (select-window! w))
      (when fn (fn)))))

(define-command "minibuffer-collect" "Write the prompt's candidates into a buffer"
  (lambda ()
    (let ((d (minibuffer-detach!)))
      (if (not d)
          (message "No prompt to collect")
          (let* ((select *mb-select-fn*)
                 (cands (cadr (assoc 'candidates d)))
                 (collector-entry (assoc 'collect d))
                 (collector (and collector-entry (cadr collector-entry))))
            (set! *mb-select-fn* #f)
            ;; the prompt is gone, so the list behind it no longer owns the
            ;; minibuffer's arrows
            (set! *mb-list-buffer* #f)
            (if collector
                (begin
                  (collect-forget!)
                  (collector cands))
                (begin
                  (set! *collect-select* select)
                  (set! *collect-confirm* (cadr (assoc 'confirm d)))
                  (set! *collect-cancel* (cadr (assoc 'cancel d)))
                  (set! *collect-complete* (cadr (assoc 'complete d)))
                  (set! *collect-input* (cadr (assoc 'input d)))
                  (set! *collect-window* (active-window))
                  (collect-open! (cadr (assoc 'prompt d)) cands))))))))

(define-mode "collect-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-local! buf 'mode-name "collect-mode")
      ;; line movement REMAPS, so arrows, C-n/C-p and any user binding of
      ;; next-line all move-and-preview identically
      (local-remap! "next-line" "collect-next")
      (local-remap! "previous-line" "collect-prev")
      (buffer-set-read-only! buf #t))))

(mode-keys! "collect-mode"
  '(("n" "collect-next") ("p" "collect-prev") ("RET" "collect-accept") ("q" "collect-quit")))

(mode-doc! "collect-mode"
  "The prompt's candidates, as a buffer you can move around in. Moving previews the candidate in the other window. `RET` confirms it in the prompt you came from.")

;; Emacs' C-x C-q. The way out of a read-only buffer, and the reason a mode
;; may open files read-only without trapping the reader.
(define-command "read-only-mode" "Toggle whether this buffer refuses edits"
  (lambda ()
    (let* ((buf (current-buffer))
           (ro? (buffer-read-only? buf)))
      (buffer-set-read-only! buf (not ro?))
      (message (if ro? "writable" "read-only")))))

(global-set-key "C-x C-q" "read-only-mode")

;; A file you reach from a browsing surface (diff-mode, code.scm) opens
;; READ-ONLY. You came to read it, and a stray keystroke in a file you are
;; only passing through is an edit you did not mean. C-x C-q makes it
;; writable. Set *browse-read-only* to #f in init.scm to opt out.
(define *browse-read-only* #t)

(define (browse-visit path)
  (visit path)
  (when *browse-read-only*
    (buffer-set-read-only! (current-buffer) #t)))

(public! 'browse-visit "(browse-visit PATH) — open a file the way the code browser does: read-only unless *browse-read-only* is #f. C-x C-q makes it writable")

;; A file the process cannot write opens READ-ONLY, as in Emacs. A
;; generated file (a Morg tangle) is write-protected on disk for this
;; reason: the document is the source, and the buffer says so before a
;; stray keystroke edits the copy. C-x C-q still makes the buffer
;; writable; the save then fails on the mode bits.
(define (write-protected--find-file-hook!)
  (let* ((buf (current-buffer))
         (path (buffer-path buf)))
    (when (and path (file-exists? path) (not (file-writable? path)))
      (buffer-set-read-only! buf #t)
      (message "File is write-protected"))))

(add-hook! 'find-file-hook 'write-protected--find-file-hook!)

;; DELTA in lines, positive forward. A preview window has no lines, so
;; scroll-window! turns the count into pixels for it — the caller says
;; "a screen" and every kind of window understands.
;; the window the other-window scroll moves: the popup when it shows
;; and is not where you are (a peek, the messages, the telemetry: the
;; look beside your work), else the next window
(define (scroll-other-window-target)
  (let ((me (active-window)))
    (or (and (popup-open?) (not (equal? (popup-window) me)) (popup-window))
        (let ((wins (window-list)))
          (and (pair? (cdr wins))
               (let loop ((ws wins))
                 (cond ((null? ws) (car (car wins)))
                       ((equal? (car (car ws)) me)
                        (car (if (null? (cdr ws)) (car wins) (car (cdr ws)))))
                       (else (loop (cdr ws))))))))))

(define (scroll-other-window-by! delta)
  (let ((target (scroll-other-window-target)))
    (if target
        (scroll-window! target delta)
        (message "No other window"))))

;; A page belongs to the window that scrolls, never to the window the key
;; was pressed in: the two can differ in height and in line height.
;;
;; A page always overlaps and never gaps: the rows it keeps are the reader's
;; thread back to where they were, and a row scrolled past unseen is gone.
;; Every rounding on this path leans the same way. (Emacs
;; next-screen-context-lines; defcustom in layouts.scm, a plain define here
;; because editor.scm loads before custom.scm.)
(define next-screen-context-lines 2)

(define (window-page-rows win)
  (let ((context (max 1 (or next-screen-context-lines 2))))
    (max 1 (- (window-rows win) context))))

(define (scroll-other-window-page! sign)
  (let ((target (scroll-other-window-target)))
    (if target
        (scroll-window! target (* sign (window-page-rows target)))
        (message "No other window"))))

;; the popup by name, for a binding of your own; nothing else scrolls
(define-command "scroll-popup" "Scroll the popup up nearly a full screen"
  (lambda ()
    (if (popup-open?)
        (scroll-window! (popup-window) (window-page-rows (popup-window)))
        (message "No popup"))))

(define-command "scroll-popup-down" "Scroll the popup down nearly a full screen"
  (lambda ()
    (if (popup-open?)
        (scroll-window! (popup-window) (- (window-page-rows (popup-window))))
        (message "No popup"))))

(define-command "scroll-other-window" "Scroll the next window up nearly a full screen"
  (lambda () (scroll-other-window-page! 1)))

(define-command "scroll-other-window-down"
  "Scroll the next window down nearly a full screen"
  (lambda () (scroll-other-window-page! -1)))

;;; --- terminal and comint ---------------------------------------------------

(domain! 'processes)
(effects! '(write execute))

;; The terminal receives raw PTY bytes outside the editor render loop. Its
;; bounded plain transcript stays in the buffer for search, agents, and /raw.
;; The login flag works for zsh, bash, and fish. Override this in init.scm.
(define *terminal-command* "exec \"${SHELL:-/bin/zsh}\" -l")

(define (terminal-mode-init! buf)
  (buffer-set-local! buf 'render-mode "terminal")
  (buffer-set-local! buf 'line-numbers "off")
  (buffer-set-read-only! buf #t)
  (unless (process-running? buf)
    ;; A terminal app records its own launch command in the buffer.  That
    ;; local rides the desktop, so waking *opencode* starts OpenCode again
    ;; instead of silently turning the buffer into a login shell.
    (start-terminal! buf
      (or (buffer-local buf 'terminal-command) *terminal-command*))))

;; shell-mode remains a terminal mode so old desktop snapshots migrate on
;; their next wake. term-mode is the explicit name for new terminal buffers.
(define-mode "shell-mode"
  (lambda () (terminal-mode-init! (current-buffer))))
(define-mode "term-mode"
  (lambda () (terminal-mode-init! (current-buffer))))

(mode-doc! "shell-mode"
  "A raw PTY terminal. Full-screen programs and app servers render outside the editor document loop. The bounded transcript stays readable as buffer text.")
(mode-doc! "term-mode"
  "A raw PTY terminal. Full-screen programs and app servers render outside the editor document loop. The bounded transcript stays readable as buffer text.")

(define-command "shell" "Open a raw PTY shell in the *shell* buffer"
  (lambda ()
    (buffer-create "*shell*")
    (buffer-set-local! "*shell*" 'mode-name "term-mode")
    (with-current-buffer "*shell*"
      (lambda () (terminal-mode-init! "*shell*")))
    (display-buffer "*shell*")))

;; OpenCode is a terminal application, not an editor mode: it gets the same
;; fast raw PTY, ANSI colour, keyboard routing, and readable transcript as
;; *shell*.  One semantic `opencode` role per group makes renamed groups keep
;; finding their session without encoding durable identity in the buffer name.
(define *opencode-command* "exec opencode")

(define (opencode-buffer-name group)
  (if group
      (string-append "*opencode:" (group-name group) "*")
      "*opencode*"))

(define (opencode-open! group)
  (let* ((dir (default-directory))
         (known (and group (group-buffer-as group 'opencode)))
         (buf (or known (opencode-buffer-name group))))
    (buffer-create buf)
    ;; A stopped or restored app keeps the directory and exact command it was
    ;; born with.  Re-running M-x opencode therefore resumes the same session.
    (unless (buffer-local buf 'terminal-command)
      (buffer-set-local! buf 'default-directory dir)
      (buffer-set-local! buf 'terminal-command
        (string-append "cd -- " (sh-quote dir) " && " *opencode-command*)))
    (buffer-set-local! buf 'mode-name "term-mode")
    (when group (buffer-add-group-as! buf group 'opencode))
    (with-current-buffer buf (lambda () (terminal-mode-init! buf)))
    (display-buffer buf)))

;; groups.scm replaces this seam with its native reader.  Keeping the reader
;; out of terminal code also lets compos boot without the optional workspace
;; package loaded.
(define opencode-group-reader
  (lambda (receive) (receive (frame-group))))

(define-command "opencode"
  "Open OpenCode for this group; with C-u, choose a group"
  (lambda ()
    (if (current-prefix-arg)
        (opencode-group-reader opencode-open!)
        (opencode-open! (frame-group)))))

;;; RET in a comint process sends the current line to the process. RET
;;; elsewhere inserts a newline.

;; Comint contract: processes run with TERM=dumb and are expected to degrade
;; (bash does automatically; zsh needs zle/prompt padding off — the flags
;; below, or the classic `[[ $TERM == dumb ]] && unsetopt zle prompt_cr
;; prompt_sp` in your zshrc). fish refuses dumb terminals — it belongs in
;; term-mode (real terminal emulator pane), not comint.
;; Override *shell-command* in your init.scm.
(define *shell-command* "exec /bin/zsh -f -i +o zle +o prompt_cr +o prompt_sp")

;; The text-buffer shell remains available for tools that want comint.
(define-mode "comint-shell-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (unless (process-running? buf)
        (start-process! buf *shell-command*)))))

(mode-doc! "comint-shell-mode"
  "A shell under the editor. `RET` sends the text after the process mark to the shell. A restart keeps the transcript and starts a new shell.")

(define-command "comint-shell" "Open a text-buffer shell in *comint-shell*"
  (lambda ()
    (if (not (process-running? "*comint-shell*"))
        (start-process! "*comint-shell*" *shell-command*))
    (pop-to-buffer "*comint-shell*")
    (buffer-set-local! "*comint-shell*" 'mode-name "comint-shell-mode")
    (end-of-buffer!)))

(define-command "newline-or-send" "Send input to the process, or insert a newline"
  (lambda ()
    (if (process-running? (current-buffer))
        ;; comint: input = text after the process mark. Typed input STAYS in
        ;; the buffer (pty echo is off) — nothing flickers or disappears.
        (let ((pm (process-mark (current-buffer)))
              (eob (end-of-buffer!)))
          (let ((input (buffer-substring pm eob)))
            (insert! "\n")
            (process-send! (current-buffer) (string-append input "\n"))))
        (insert! "\n"))))

;;; --- tail (follow a growing file) ------------------------------------------
;;; tail -F under the comint layer — local or /ssh: remote. The buffer is
;;; 'special: a view of a file, not the file. desktop-skip! decides what
;;; is saved; tail-mode's setup restarts the tail on restore. end-of-buffer! puts
;;; point at the end, where process appends keep pushing it — follow for free.

(define (sh-quote s)
  (string-append "'" (string-join (string-split s "'") "'\\''") "'"))

(define (tail-command path)
  (if (remote-path? path)
      (let ((hp (remote-parse path)))
        ;; double-quoted: the inner quoting survives to the remote shell
        (string-append "exec " (sh-quote (ssh-command)) " " (sh-quote (car hp)) " "
                       (sh-quote (string-append "tail -n 200 -F " (sh-quote (cadr hp))))))
      (string-append "exec tail -n 200 -F " (sh-quote path))))

(mode-parent! "tail-mode" "special-mode")
(define-mode "tail-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (let ((path (buffer-local buf 'tail-path)))
        (buffer-set-read-only! buf #t)
        (when (and path (not (process-running? buf)))
          (start-process! buf (tail-command path)))))))
(mode-keys! "tail-mode" '(("q" "quit-window")))

(mode-doc! "tail-mode"
  "A file that follows itself, local or over `ssh`. New lines append at the end. The buffer is read-only, and `q` closes it.")

(define (tail-open path)
  (if (and (remote-path? path) (not (remote-parse path)))
      (message "Remote path is /ssh:HOST:/PATH")
      (let ((buf (string-append "*tail: " path "*")))
        (buffer-create buf)
        (buffer-set-local! buf 'tail-path path)
        (switch-to-buffer! buf)
        (set-mode! "tail-mode")
        (end-of-buffer!))))

(define-command "tail-file" "Follow a file as it grows (local or /ssh: remote)"
  (lambda ()
    (read-file-name "Tail file: "
      (lambda (input) (tail-open (normalize-file-input input))))))

;;; --- LLM pipes (gptel) -----------------------------------------------------
;;; (llm prompt handler) is the async primitive; everything here is
;;; composition. Handlers are ordinary closures — build your own pipelines.

(define (llm-on-region instruction handler)
  (let ((text (region-text)))
    (if (equal? text "")
        (message "No region — set the mark first (C-SPC)")
        (begin
          (message "LLM thinking...")
          (llm (string-append instruction
                              "\n\nReturn ONLY the result, no commentary.\n\n"
                              text)
               handler)))))

;; M-| : region -> LLM -> *llm* buffer
(define-command "llm-pipe-region" "Pipe the region through the LLM into *llm*"
  (lambda ()
    (minibuffer-read "LLM instruction: " '()
      (lambda (instr)
        (llm-on-region instr
          (lambda (result)
            (buffer-create "*llm*")
            (buffer-append! "*llm*" (string-append "\n;; " instr "\n" result "\n"))
            (message "LLM done -> *llm*")))))))

;; The block subsystems: a block that waits in the document with a record
;; and verbs, indicated by its fence line alone. One file per block under
;; editor/blocks/; an action that creates a block loads after it.
(load (string-append (compos-priv-dir) "/editor/blocks/block.scm"))
(load (string-append (compos-priv-dir) "/editor/blocks/diff-block.scm"))
(load (string-append (compos-priv-dir) "/editor/blocks/llm-rewrite.scm"))
(global-set-key "M-|" "llm-pipe-region")

;; gptel's most Emacs-shaped operation: the buffer is both the prompt and
;; the transcript. M-o puts the answer where point was when it was sent. A
;; stateful backend gets one durable session per buffer and only the new tail;
;; the stateless API lane still receives the immutable whole-buffer snapshot.
;; The overlay makes authorship visible without writing chat markers into the
;; document itself.
(define *llm-mode-hooks* '())

(define (llm-mode--addressable-kind buf kind)
  (filter
    (lambda (record)
      (and record
           (equal? (plist-get record 'kind) kind)
           (not (equal? (plist-get record 'state) 'deleted))))
    (map (lambda (record)
           (block-resolve-id buf (plist-get record 'id)))
         (block-records buf))))

(define (llm-mode--kind-ranges buf kind)
  (map (lambda (record)
         (list (plist-get record 'start) (plist-get record 'end)))
       (llm-mode--addressable-kind buf kind)))

(define (llm-mode--active-prompt-ranges buf)
  (map (lambda (record)
         (list (plist-get record 'start) (plist-get record 'end)))
       (filter (lambda (record) (equal? (plist-get record 'state) 'sent))
               (llm-mode--addressable-kind buf 'llm-prompt))))

(define (llm-mode--range-overlaps? a b)
  (and (< (car a) (cadr b)) (< (car b) (cadr a))))


(define (llm-mode--range-overlaps-any? range ranges)
  (cond ((null? ranges) #f)
        ((llm-mode--range-overlaps? range (car ranges)) #t)
        (else (llm-mode--range-overlaps-any? range (cdr ranges)))))
(define (llm-mode--addressable-turn-ranges buf)
  (filter (lambda (range) (< (car range) (cadr range)))
          (append (llm-mode--kind-ranges buf 'llm-prompt)
                  (llm-mode--kind-ranges buf 'llm-response))))

(define (llm-mode--legacy-response-ranges buf)
  (let ((legacy (or (buffer-local buf 'llm-legacy-responses)
                    (if (null? (llm-mode--kind-ranges buf 'llm-response))
                        (or (buffer-local buf 'llm-responses) '())
                        '())))
        (turns (llm-mode--addressable-turn-ranges buf)))
    (filter
      (lambda (range)
        (and (number? (car range)) (number? (cadr range))
             (< (car range) (cadr range))
             (not (llm-mode--range-overlaps-any? range turns))))
      legacy)))

(define (llm-mode--visible-response-ranges buf)
  (map (lambda (record)
         (list (plist-get record 'start) (plist-get record 'end)))
       (filter
         (lambda (record)
           (and (member (plist-get record 'state)
                        '(streaming complete failed cancelled))
                (< (plist-get record 'start) (plist-get record 'end))))
         (llm-mode--addressable-kind buf 'llm-response))))

(define (llm-mode--response-ranges buf)
  (append (llm-mode--legacy-response-ranges buf)
          (llm-mode--visible-response-ranges buf)))
(define (llm-mode--thinking-chrome buf)
  (map
    (lambda (record)
      (chrome-before
        (plist-get record 'start)
        (or (plist-get (plist-get record 'metadata) 'label) "Thinking")
        "llm-thinking-spinner"))
    (llm-mode--addressable-kind buf 'llm-thinking)))


(define (llm-mode--paint! buf)
  (overlay-set! buf 'llm-mode-responses
    (map (lambda (range)
           (list (car range) (cadr range) 'llm-response))
         (llm-mode--response-ranges buf)))
  (overlay-set! buf 'llm-mode-prompts
    (map (lambda (range)
           (list (car range) (cadr range) 'llm-prompt))
         (llm-mode--active-prompt-ranges buf)))
  (overlay-set! buf 'llm-mode-thinking (llm-mode--thinking-chrome buf)))

(define (llm-mode--sync-ranges! buf)
  ;; Addressable markers are the source of truth for new turns. Legacy
  ;; desktops still mirror their overlay ranges until their first new send.
  (when (minor-mode-on? buf "llm-mode")
    (if (pair? (llm-mode--kind-ranges buf 'llm-response))
        (begin
          (buffer-set-local! buf 'llm-responses
            (llm-mode--response-ranges buf))
          (llm-mode--paint! buf))
        (let ((tracked
                (filter (lambda (ov) (equal? (caddr ov) "llm-response"))
                        (buffer-overlays buf))))
          (when (or (pair? tracked)
                    (not (buffer-local buf 'llm-responses))
                    (null? (buffer-local buf 'llm-responses)))
            (buffer-set-local! buf 'llm-responses
              (map (lambda (ov) (list (car ov) (cadr ov))) tracked)))))))

(define (llm-mode--agent-write? buf source)
  (let ((inline (buffer-local buf 'llm-session-id)))
    (and inline (equal? source (string-append "agent:" inline)))))

(define (llm-mode--change-touches-result? result pos inserted deleted)
  (let ((start (plist-get result 'start))
        (end (plist-get result 'end))
        (added (or inserted 0))
        (removed (or deleted 0)))
    (or (and (> added 0) (<= start pos) (< pos end))
        (and (> removed 0)
             (< pos (+ end removed))
             (< start (+ pos removed))))))

;; Authorship is a live property. The first non-agent edit inside a completed
;; result retires its addressable turn and children; the bytes remain untouched.
(define (llm-mode--declassify-edited-results! buf pos inserted deleted)
  (let ((changed #f))
    (for-each
      (lambda (result)
        (when (and (member (plist-get result 'state) '(complete failed cancelled))
                   (llm-mode--change-touches-result?
                     result pos inserted deleted))
          ;; Freeze the compatibility layer before retiring the native turn.
          ;; Otherwise the now-stale llm-responses mirror can be mistaken for
          ;; an old desktop's legacy overlay and repaint the edited result.
          (unless (buffer-local buf 'llm-legacy-responses)
            (buffer-set-local! buf 'llm-legacy-responses
              (llm-mode--legacy-response-ranges buf)))
          (let ((response-id (plist-get result 'parent)))
            (block-retire-children! buf (plist-get result 'id))
            (block-set-state! buf (plist-get result 'id) 'deleted)
            (when response-id
              (llm-mode--retire-thinking! buf response-id)
              (block-set-state! buf response-id 'deleted))
            (set! changed #t))))
      (llm-mode--addressable-kind buf 'llm-result))
    (when changed
      (buffer-set-local! buf 'llm-session-dirty #t)
      (buffer-set-local! buf 'llm-responses
        (llm-mode--response-ranges buf))
      (llm-mode--paint! buf))
    changed))

(define (llm-mode--ensure-hook! buf)
  (unless (assoc buf *llm-mode-hooks*)
    (set! *llm-mode-hooks*
      (cons (list buf
                  (on-change! buf
                    (lambda (pos inserted deleted source)
                      (unless (or (equal? source "locals")
                                  (llm-mode--agent-write? buf source))
                        (llm-mode--declassify-edited-results!
                          buf pos inserted deleted))
                      (llm-mode--sync-ranges! buf)
                      ;; Text after the last answer is the next user turn.
                      ;; Editing anything earlier rewrites conversation
                      ;; history, so the next send starts a new native thread.
                      (let ((end (llm-mode--last-response-end buf)))
                        (when (and end
                                   (not (equal? source "locals"))
                                   (not (llm-mode--agent-write? buf source))
                                   (< pos end))
                          (buffer-set-local! buf 'llm-session-dirty #t))))))
            *llm-mode-hooks*))))

(define (llm-mode--remove-hook! buf)
  (let ((hit (assoc buf *llm-mode-hooks*)))
    (when hit
      (remove-on-change! (cadr hit))
      (set! *llm-mode-hooks*
        (remove (lambda (entry) (equal? (car entry) buf))
                *llm-mode-hooks*)))))

(define (llm-mode--retire-thinking! buf response-id)
  (let* ((active-id (buffer-local buf 'llm-active-thinking))
         (active (and active-id (block-resolve-id buf active-id))))
    (for-each
      (lambda (child)
        (when (equal? (plist-get child 'kind) 'llm-thinking)
          (block-set-state! buf (plist-get child 'id) 'deleted)))
      (block-children buf response-id))
    (when (and active (equal? (plist-get active 'parent) response-id))
      (buffer-set-local! buf 'llm-active-thinking #f))
    (llm-mode--paint! buf)))

;; A restored or interrupted buffer cannot still have a live callback for an
;; old pending/streaming block. Retire those records before their advancing end
;; markers absorb later document edits. Preserve partial streamed text.
(define (llm-mode--heal-orphaned-turns! buf)
  (let ((active (buffer-local buf 'llm-active-response)))
    (for-each
      (lambda (response)
        (let* ((id (plist-get response 'id))
               (state (plist-get response 'state))
               (metadata (plist-get response 'metadata))
               (prompt-id (plist-get metadata 'prompt))
               (result-id (plist-get metadata 'result)))
          (when (and (member state '(pending streaming))
                     (not (equal? id active)))
            (llm-mode--retire-thinking! buf id)
            (when (equal? state 'pending)
              (block-close-end! buf id (plist-get response 'start))
              (when result-id
                (block-close-end! buf result-id (plist-get response 'start))))
            (block-set-state! buf id 'cancelled)
            (when result-id (block-set-state! buf result-id 'cancelled))
            (when prompt-id (block-set-state! buf prompt-id 'complete)))))
      (llm-mode--addressable-kind buf 'llm-response))
    (let ((saved (buffer-local buf 'llm-legacy-responses)))
      (when saved
        (buffer-set-local! buf 'llm-legacy-responses
          (llm-mode--legacy-response-ranges buf))))))

(define (llm-mode--apply! buf)
  (llm-mode--heal-orphaned-turns! buf)
  (buffer-set-local! buf 'llm-responses (llm-mode--response-ranges buf))
  (llm-mode--paint! buf)
  (llm-mode--ensure-hook! buf))

(define (llm-mode--teardown! buf)
  (llm-mode-reset-runtime! buf #f)
  (llm-mode--remove-hook! buf)
  (overlay-clear! buf 'llm-mode-responses)
  (overlay-clear! buf 'llm-mode-prompts)
  (overlay-clear! buf 'llm-mode-thinking))

;; the change rule behind M-o's response ranges is registered under the name
;; the buffer had. A renamed chat needs the rule again, under the new one.
(on-buffer-renamed!
  (lambda (old new)
    (when (assoc old *llm-mode-hooks*)
      (llm-mode--remove-hook! old)
      (when (minor-mode-on? new "llm-mode")
        (llm-mode--ensure-hook! new)
        ;; Session callbacks close over the buffer name. Reattach them under
        ;; the new name while preserving the native Codex thread itself.
        (llm-mode-reset-runtime! new #t)))))

(register-minor-mode! "llm-mode" llm-mode--apply! llm-mode--teardown!)
(minor-mode-keys! "llm-mode"
  '(("M-o" "llm-send-buffer") ("C-g" "llm-mode-abort")
    ("C-c m" "llm-set-model") ("C-c b" "llm-configure")))

(define-command "llm-mode" "Toggle in-buffer LLM interaction and response formatting"
  (lambda ()
    (if (toggle-minor-mode! "llm-mode")
        (message "LLM mode enabled")
        (message "LLM mode disabled"))))

(mode-doc! "llm-mode"
  "In-buffer LLM interaction. `M-o` shows transient thinking/tool activity at point, then streams the durable result there. `C-g` cancels an in-flight reply and restores the prompt face; `C-c b` chooses backend, model, effort, tools, and prompt sections.")

;; Inline sessions are durable agent conversations by default, matching
;; Codex's editor integrations: one native thread stays attached to the
;; buffer and M-o sends only the next turn.  The direct API lane remains an
;; explicit choice in C-c b for users who want a stateless replay.
(define *llm-mode-connector* "codex-app-server")

;; One model wears two names: the API lane spells it "openai:gpt-5.6-luna" and
;; a subscription connector spells the same model "gpt-5.6-luna".
(define (llm--model-bare m)
  (let ((parts (string-split m ":")))
    (if (> (length parts) 1) (car (cdr parts)) #f)))

;; The name CNAME lists for this model, or #f when that connector does not
;; have the model at all.
(define (connector-model-id cname m)
  (let ((models (if (boundp (quote connector-models)) (connector-models cname) '())))
    (cond ((not m) #f)
          ((member m models) m)
          (else (let ((bare (llm--model-bare m)))
                  (and bare (member bare models) bare))))))

;; the connector that has this model, or #f. Hidden connectors are
;; compatibility names for saved chats; a new session never picks one. The
;; metered lane answers last: it serves nearly every model, and a
;; subscription connector that has the model is the cheaper lane.
(define (llm--connector-owning m)
  (let* ((names (if (boundp (quote connector-names)) (connector-names) '()))
         (ordered
           (append (filter (lambda (c) (not (connector-can? c 'metered))) names)
                   (filter (lambda (c) (connector-can? c 'metered)) names))))
    (let loop ((cs ordered))
      (cond ((null? cs) #f)
            ((connector-model-id (car cs) m) (car cs))
            (else (loop (cdr cs)))))))

;; The model names the lane. A model the default connector does not have must
;; reach the connector that does: Codex answers a model id it does not know
;; with a 400 on the first send, so a buffer holding an API model id — the
;; editor's own default model is one — got no answer and no reason for it.
(define (llm-connector-for-model m)
  (cond ((not (boundp (quote connector-models))) *llm-mode-connector*)
        ((not m) *llm-mode-connector*)
        ((connector-model-id *llm-mode-connector* m) *llm-mode-connector*)
        ((llm--connector-owning m))
        (else "api")))

(define (buffer-llm-connector buf)
  (or (buffer-local buf 'llm-connector)
      (llm-connector-for-model (buffer-llm-model buf))))

(define (buffer-llm-model buf)
  (or (buffer-local buf 'llm-model) (llm-model)))

;; Runtime ids are buffer identities, not turn identities. The local survives
;; desktop restore and buffer rename; the persisted counter prevents a new
;; buffer from colliding with an old renamed one.
(defvar '*llm-inline-next* 0)

(persist-global! 'llm-inline-next
  (lambda () *llm-inline-next*)
  (lambda (v) (set! *llm-inline-next* v)))

(define (llm-mode--session-id buf)
  (or (buffer-local buf 'llm-session-id)
      (begin
        (set! *llm-inline-next* (+ *llm-inline-next* 1))
        (let ((id (string-append "inline-" (number->string *llm-inline-next*))))
          (buffer-set-local! buf 'llm-session-id id)
          id))))

(define (llm-mode--runtime-live? buf)
  (let ((id (buffer-local buf 'llm-session-id)))
    (and id (member id (agent-list)) (not (equal? (agent-status id) 'dead)) #t)))

;; KEEP-THREAD preserves Codex's durable thread identity while dropping only
;; this editor process. A changed history or connector passes #f and starts a
;; genuinely new conversation on the next send.
(define (llm-mode-reset-runtime! buf keep-thread)
  (let ((id (buffer-local buf 'llm-session-id)))
    (when (and id (member id (agent-list))) (llm-session-close! id)))
  (unless keep-thread (buffer-set-local! buf 'llm-thread-id #f))
  (buffer-set-local! buf 'llm-session-dirty #f)
  #t)

(define-command "llm-set-model" "Choose the model for M-o in this buffer"
  (lambda ()
    (let ((buf (current-buffer)))
      (minibuffer-read
        (string-append "Model for this buffer (now " (buffer-llm-model buf) "): ")
        *llm-models*
        (lambda (model)
          (unless (equal? (string-trim model) "")
            (buffer-set-local! buf 'llm-model model)
            ;; Codex fixes model identity in the thread instructions. Resume
            ;; the same thread through a fresh runtime with the new override.
            (llm-mode-reset-runtime! buf #t)
            (message (string-append "M-o · " model))))))))


;; Inline/document requests use the same session facade, connector resolution,
;; normalized event stream and tool loop as chat; only their presentation
;; differs. One entry exists while the buffer's durable session is running a
;; turn; completion removes the entry, not the session.
(define *llm-inline-sends* '())

(define (llm-inline-put! entry)
  (let ((id (car entry)))
    (set! *llm-inline-sends*
      (cons entry
            (remove (lambda (e) (equal? (car e) id)) *llm-inline-sends*)))))

(define (llm-inline-add-chunk! id text)
  (let ((e (assoc id *llm-inline-sends*)))
    (when (and e (not (equal? text "")))
      ;; (id buffer completion accumulated error chunk-handler)
      (llm-inline-put!
        (list id (car (cdr e)) (car (cdr (cdr e)))
              (string-append (car (cdr (cdr (cdr e)))) text)
              (car (cdr (cdr (cdr (cdr e)))))
              (car (cdr (cdr (cdr (cdr (cdr e))))))))
      ;; The response belongs in its document as it arrives. Waiting for
      ;; turn-end hid useful prose when a later tool call stalled or failed.
      ((car (cdr (cdr (cdr (cdr (cdr e)))))) text))))

(define (llm-inline-error! id text)
  (let ((e (assoc id *llm-inline-sends*)))
    (when e
      (llm-inline-put!
        (list id (car (cdr e)) (car (cdr (cdr e)))
              (car (cdr (cdr (cdr e)))) text)))))

(define (llm-inline-finish! id)
  (let ((e (assoc id *llm-inline-sends*)))
    (when e
      ;; Remove before invoking user presentation code: completion may start
      ;; another turn on this same session.
      (set! *llm-inline-sends*
        (remove (lambda (x) (equal? (car x) id)) *llm-inline-sends*))
      (let ((result (car (cdr (cdr (cdr e)))))
            (error (car (cdr (cdr (cdr (cdr e))))))
            (completion (car (cdr (cdr e)))))
        ;; Completion closes a streamed range. It also keeps a partial reply
        ;; readable when the backend reports an error after one or more chunks.
        (completion result error)
        (when error (message (string-append "LLM failed · " error)))))))

(define (llm-inline-note-activity! id event)
  (let ((entry (assoc id *llm-inline-sends*)))
    (when entry
      (let ((buf (cadr entry)))
        (when (buffer-exists? buf)
          (llm-mode--note-activity! buf event))))))

(define (llm-inline-events! id events)
  (for-each
    (lambda (event)
      (let ((type (plist-get event 'type)))
        (when (member type '(thought tool-call tool-update plan permission question))
          (llm-inline-note-activity! id event))
        (cond ((equal? type 'chunk)
               (llm-inline-add-chunk! id (or (plist-get event 'text) "")))
              ((equal? type 'thread-id)
               (let ((e (assoc id *llm-inline-sends*)))
                 (when e
                   (buffer-set-local! (cadr e) 'llm-thread-id
                     (plist-get event 'id)))))
              ((equal? type 'error)
               ;; A failed turn ends in turn-failed, which the status machine
               ;; consumes: no turn-end ever reaches this buffer. Finish here.
               (llm-inline-error! id (or (plist-get event 'text) "request failed"))
               (llm-inline-finish! id))
              ((equal? type 'permission)
               (llm-inline-allow! id event))
              ((equal? type 'question)
               (llm-inline-answer! id event))
              ((equal? type 'turn-end)
               (llm-inline-finish! id)))))
    events))

;; the option that says yes for the rest of the session, else the plain yes
(define (llm-inline--allow-option event)
  (let loop ((os (or (plist-get event 'options) '())) (once #f))
    (cond ((null? os) (or once "allow_once"))
          ((equal? (car (car os)) "allow_always") "allow_always")
          (else (loop (cdr os) (or once (car (car os))))))))

(define (llm-inline-allow! id event)
  (let ((rpc (plist-get event 'rpc-id)))
    (when rpc
      (agent-permission-respond! id rpc (llm-inline--allow-option event)))))

(define (llm-inline-answer! id event)
  (let ((qid (plist-get event 'id))
        (answers (or (plist-get event 'answers) '())))
    (when qid
      ;; An enum question chooses its first allowed answer. A question with
      ;; no choices is the boolean approval emitted by the compos MCP bridge.
      (agent-question-respond! id qid
        (if (pair? answers) (car answers) "true")))))

;; Presets supply the complete tool surface. The runtime opens lazily on the
;; first send, stays attached to BUF, and (for Codex) records a native thread
;; id that a restored buffer resumes.
(define (llm-mode--complete buf wire display model mark handler chunk-handler)
  (let* ((id (llm-mode--session-id buf))
         (connector (buffer-llm-connector buf))
         ;; the name this connector knows the model by: the API lane says
         ;; "openai:gpt-5.6-luna" and Codex says "gpt-5.6-luna"
         (model (or (connector-model-id connector model) model))
         (effort (buffer-local buf 'llm-effort))
         (config (agent-resolve-config
                   (append
                     (list 'connector connector 'model model
                           'buffer buf 'mark mark
                           ;; ReqLLM consumes SPECS above directly. ACP
                           ;; sessions instead mount the MCP servers named by
                           ;; these same presets at session/new, exactly as a
                           ;; chat buffer does. Without this, an ACP-backed
                           ;; llm-mode buffer advertises the companion by name
                           ;; but has no editor tool with which to read it.
                           'presets (if (boundp (quote chat-presets-of))
                                        (chat-presets-of buf)
                                        '())
                           'persist-thread #t)
                     (let ((thread (buffer-local buf 'llm-thread-id)))
                       (if thread (list 'thread-id thread) '()))
                     (if effort (list 'effort effort) '())))))
    (when (and (member id (agent-list)) (equal? (agent-status id) 'dead))
      (llm-session-close! id))
    (llm-inline-put! (list id buf handler "" #f chunk-handler))
    (unless (llm-mode--runtime-live? buf)
      (llm-session-open! id config
        (lambda (_id _display)
          (list 'turns '()
                'system
                (if (boundp (quote chat-prompt-live-parts))
                    (prompt-parts-text (chat-prompt-live-parts buf))
                    (chat-tool-system buf))
                'tools (if (boundp (quote chat-extra-tool-specs))
                           (chat-extra-tool-specs buf)
                           '())
                'dispatcher llm-tool-call))
        (lambda (_id events) (llm-inline-events! id events))
        (lambda (_id _role _blocks _wire) #t)
        ;; Inline M-o historically executed its selected tools directly.
        (lambda (_id _name _kind _raw) 'allow)))
    (llm-session-send! id wire display)))

(define (llm-mode--last-response-range buf)
  (let loop ((ranges (llm-mode--response-ranges buf)) (latest #f))
    (cond ((null? ranges) latest)
          ((or (not latest) (> (cadr (car ranges)) (cadr latest)))
           (loop (cdr ranges) (car ranges)))
          (else (loop (cdr ranges) latest)))))

(define (llm-mode--last-response-end buf)
  (let ((range (llm-mode--last-response-range buf)))
    (and range (cadr range))))

;; Keep the old range local current for clients and saved desktops that read it.
(define (llm-mode--sync-addressable-responses! buf)
  (let ((ranges (llm-mode--response-ranges buf)))
    (when (pair? ranges) (buffer-set-local! buf 'llm-responses ranges))
    (llm-mode--paint! buf)))

;; The legacy writer remains for restored transcripts without block records.
(define (llm-mode--stream-range! buf start end replace-last)
  (let* ((ranges (or (buffer-local buf 'llm-responses) '()))
         (before (if (and replace-last (pair? ranges))
                     (reverse (cdr (reverse ranges)))
                     ranges)))
    (buffer-set-local! buf 'llm-responses
      (append before (list (list start end))))
    (llm-mode--paint! buf)))

(define (llm-mode--last-response-start buf)
  (let ((range (llm-mode--last-response-range buf)))
    (and range (car range))))

(define (llm-mode--stateful? buf)
  (not (connector-can? (buffer-llm-connector buf) 'stateless)))

(define (llm-mode--wire-text buf snapshot)
  (let* ((range (llm-context-range buf))
         (end (llm-mode--last-response-end buf))
         (relative-end
           (if range
               (and end (<= (car range) end) (<= end (cadr range))
                    (- end (car range)))
               end)))
    (if (and (llm-mode--stateful? buf)
             relative-end
             (or (llm-mode--runtime-live? buf)
                 (buffer-local buf 'llm-thread-id))
             (not (buffer-local buf 'llm-session-dirty)))
        (let ((tail (substring-bytes snapshot relative-end
                                     (string-byte-length snapshot))))
          (if (equal? (string-trim tail) "") "" tail))
        snapshot)))

;; Where a reply goes. A reply is a block of its own, so it belongs after the
;; block point sits in — never inside it, and never above the prompt just
;; typed. The scan is morg-scan, the one fence-aware line scanner, so an
;; answer cannot land between two backtick lines, and the landing agrees
;; with every Morg view of the same bytes.
(define (llm-mode--blocks buf)
  ;; The document as (START END) blocks. A fenced block runs from its opening
  ;; fence to the end of its closing fence; any other run of non-blank lines
  ;; is a paragraph; a blank line separates two of them.
  (let loop ((es (morg-scan buf)) (open #f) (last 0) (acc '()))
    (if (null? es)
        (reverse (if open (cons (list open last) acc) acc))
        (let* ((e (car es))
               (start (car e))
               (k (morg-kind e))
               (end (+ start (string-byte-length (cadr e))))
               (flushed (if open (cons (list open last) acc) acc)))
          (cond
            ((equal? k 'open) (loop (cdr es) start end flushed))
            ((equal? k 'code) (loop (cdr es) open end acc))
            ((equal? k 'close)
             (loop (cdr es) #f end (cons (list (or open start) end) acc)))
            ((and (equal? k 'text) (equal? (string-trim (cadr e)) ""))
             (loop (cdr es) #f end flushed))
            (else (loop (cdr es) (or open start) end acc)))))))

;; A newly typed prompt can share a Morg paragraph with the result immediately
;; before it. Cut the parsed span at every addressable boundary it would cross,
;; keeping the side that contains point. Repeating handles nested old turns.
(define (llm-mode--fit-prompt-range buf range pos)
  (let ((records
          (filter
            (lambda (record)
              (and record (not (equal? (plist-get record 'state) 'deleted))))
            (map (lambda (raw)
                   (block-resolve-id buf (plist-get raw 'id)))
                 (block-records buf)))))
    (let loop ((candidate range))
      (let ((next
              (fold
                (lambda (current record)
                  (let ((start (car current)) (end (cadr current))
                        (rstart (plist-get record 'start))
                        (rend (plist-get record 'end)))
                    (cond
                      ((and (< rstart start) (< start rend) (< rend end))
                       (if (< pos rend) (list start rend) (list rend end)))
                      ((and (< start rstart) (< rstart end) (< end rend))
                       (if (<= pos rstart) (list start rstart) (list rstart end)))
                      (else current))))
                candidate records)))
        (if (equal? next candidate) next (loop next))))))

(define (llm-mode--block-range-at buf pos)
  (let* ((at (max 0 (min pos (buffer-size buf))))
         (raw
           (let loop ((blocks (llm-mode--blocks buf)))
             (cond ((null? blocks) (list at at))
                   ((and (<= (car (car blocks)) at)
                         (<= at (cadr (car blocks))))
                    (car blocks))
                   (else (loop (cdr blocks)))))))
    (llm-mode--fit-prompt-range buf raw at)))

;; Mark the prompt now and reserve one transient activity block plus one durable
;; result block before the request starts. Only the final result owns text.
(define (llm-mode--begin-turn! buf pos insert-at &optional model)
  (let* ((prompt-range (llm-mode--block-range-at buf pos))
         (_legacy
           (when (not (buffer-local buf 'llm-legacy-responses))
             (buffer-set-local! buf 'llm-legacy-responses
               (or (buffer-local buf 'llm-responses) '()))))
         ;; Validate/claim the prompt before touching the document. Insertion at
         ;; its end advances the marker, so reset it to exclude the separator.
         (prompt-id
           (block-create! buf 'llm-prompt
             (car prompt-range) (cadr prompt-range) #f 'sent '()))
         (_separator (buffer-insert! buf insert-at "\n\n"))
         (_prompt-end (block-close-end! buf prompt-id (cadr prompt-range)))
         (response-at (+ insert-at 2))
         (response-id
           (block-create! buf 'llm-response response-at response-at
             #f 'pending (list 'prompt prompt-id)))
         (thinking-id
           (block-create! buf 'llm-thinking response-at response-at response-id
             'streaming
             (list 'label (if model (string-append "Thinking · " model) "Thinking")
                   'activity 'thinking)))
         (result-id
           (block-create! buf 'llm-result response-at response-at response-id
             'pending '())))
    (block-set-metadata! buf response-id
      (list 'prompt prompt-id 'thinking thinking-id 'result result-id))
    (block-set-metadata! buf prompt-id (list 'response response-id))
    (buffer-set-local! buf 'llm-active-prompt prompt-id)
    (buffer-set-local! buf 'llm-active-response response-id)
    (buffer-set-local! buf 'llm-active-thinking thinking-id)
    (buffer-set-local! buf 'llm-active-result result-id)
    (llm-mode--aim! buf response-at)
    (llm-mode--sync-addressable-responses! buf)
    (list 'prompt prompt-id 'response response-id 'thinking thinking-id
          'result result-id 'insert-at insert-at)))

(define (llm-mode--clip-activity text)
  (let* ((clean (string-trim (or text "")))
         (line (if (equal? clean "") "" (car (string-split clean "\n")))))
    (if (> (string-length line) 92)
        (string-append (substring line 0 91) "…")
        line)))

(define (llm-mode--activity-label event)
  (let ((type (plist-get event 'type)))
    (cond
      ((equal? type 'thought)
       (let ((text (llm-mode--clip-activity (plist-get event 'text))))
         (if (equal? text "") "Thinking" (string-append "Thinking · " text))))
      ((equal? type 'tool-call)
       (let* ((title (or (plist-get event 'title) (plist-get event 'name)
                         (plist-get event 'kind) "tool"))
              (shown (if (equal? title "") "tool" title)))
         (string-append "Running · " (llm-mode--clip-activity shown))))
      ((equal? type 'tool-update)
       (let ((status (or (plist-get event 'status) "working")))
         (string-append "Tool · " (if (equal? status "") "working" status))))
      ((equal? type 'plan) "Planning")
      ((equal? type 'permission) "Approving tool")
      ((equal? type 'question) "Answering tool")
      (else "Thinking"))))

(define (llm-mode--note-activity! buf event)
  (let* ((response-id (buffer-local buf 'llm-active-response))
         (response (and response-id (block-resolve-id buf response-id)))
         (thinking-id (and response
                        (plist-get (plist-get response 'metadata) 'thinking)))
         (thinking (and thinking-id (block-resolve-id buf thinking-id))))
    (when (and thinking (equal? (plist-get thinking 'state) 'streaming))
      (block-set-metadata! buf thinking-id
        (list 'label (llm-mode--activity-label event)
              'activity (plist-get event 'type)))
      (llm-mode--paint! buf))))

(define (llm-mode--append-response! buf response-id text)
  (let* ((response (block-resolve-id buf response-id))
         (result-id (and response
                      (plist-get (plist-get response 'metadata) 'result))))
    (if (or (equal? text "")
            (not (member (plist-get response 'state) '(pending streaming))))
        #f
        (begin
          (llm-mode--retire-thinking! buf response-id)
          (agent-append! (llm-mode--session-id buf) text)
          (block-set-state! buf response-id 'streaming)
          (when result-id (block-set-state! buf result-id 'streaming))
          (llm-mode--sync-addressable-responses! buf)
          #t))))

(define (llm-mode--fence-for-span buf span)
  (let ((fence (block-at buf (car span))))
    (and fence
         (= (nth 0 fence) (car span))
         (= (nth 1 fence) (cadr span))
         fence)))

;; A completed response contains one durable result block. Morg paragraphs and
;; fences become children of that result; transient thinking remains a sibling.
(define (llm-mode--adopt-response-children! buf response-id)
  (let* ((response (block-resolve-id buf response-id))
         (result-id (and response
                      (plist-get (plist-get response 'metadata) 'result)))
         (container-id (or result-id response-id))
         (container (and response (block-resolve-id buf container-id))))
    (when container
      (block-retire-children! buf container-id)
      (for-each
        (lambda (span)
          (when (and (<= (plist-get container 'start) (car span))
                     (<= (cadr span) (plist-get container 'end))
                     (< (car span) (cadr span)))
            (let* ((fence (llm-mode--fence-for-span buf span))
                   (language (and fence (block-lang fence)))
                   (kind (cond ((and language (equal? language "scheme")) 'scheme)
                               (fence 'code)
                               (else 'paragraph)))
                   (metadata (if language (list 'language language) '()))
                   (id (block-create! buf kind (car span) (cadr span)
                         container-id 'complete metadata)))
              (block-close-end! buf id))))
        (llm-mode--blocks buf)))))

(define (llm-mode--finish-response! buf response-id streamed error)
  (let* ((response (block-resolve-id buf response-id))
         (end (plist-get response 'end))
         (metadata (plist-get response 'metadata))
         (prompt-id (plist-get metadata 'prompt))
         (result-id (plist-get metadata 'result))
         (cancelled (equal? (plist-get response 'state) 'cancelled))
         (state (if cancelled 'cancelled (if error 'failed 'complete))))
    (llm-mode--retire-thinking! buf response-id)
    (when streamed (agent-append! (llm-mode--session-id buf) "\n"))
    ;; The final line break belongs to the document, not to either result span.
    (block-close-end! buf response-id end)
    (when result-id (block-close-end! buf result-id end))
    (block-set-state! buf response-id state)
    (when result-id (block-set-state! buf result-id state))
    (when prompt-id (block-set-state! buf prompt-id 'complete))
    (when (equal? (buffer-local buf 'llm-active-response) response-id)
      (buffer-set-local! buf 'llm-active-response #f)
      (buffer-set-local! buf 'llm-active-result #f)
      (buffer-set-local! buf 'llm-active-prompt #f))
    (llm-mode--adopt-response-children! buf response-id)
    (llm-mode--sync-addressable-responses! buf)))

(define (llm-mode--insert-at buf pos)
  ;; Between two blocks POS is already the right place.
  (let* ((size (buffer-size buf))
         (at (max 0 (min pos size))))
    (let loop ((bs (llm-mode--blocks buf)))
      (cond ((null? bs) at)
            ((and (<= (car (car bs)) at) (<= at (cadr (car bs))))
             (cadr (car bs)))
            (else (loop (cdr bs)))))))

(define (llm-mode--aim! buf at)
  ;; The reply streams at the buffer's agent mark, and that mark otherwise
  ;; only remembers where the last reply ended — above anything written
  ;; since. A document aims it at this send. A chat's mark owns the input
  ;; region and is never ours to move.
  (unless (chat-buffer? buf)
    (buffer-set-local! buf 'agent-saved-mark at)))


(define-command "llm-mode-abort" "Cancel the inline reply and restore the prompt face"
  (lambda ()
    (let* ((buf (current-buffer))
           (response-id (buffer-local buf 'llm-active-response))
           (response (and response-id (block-resolve-id buf response-id)))
           (state (and response (plist-get response 'state)))
           (prompt-id (buffer-local buf 'llm-active-prompt))
           (result-id (and response
                        (plist-get (plist-get response 'metadata) 'result))))
      (if (not (member state '(pending streaming)))
          (run-command "keyboard-quit")
          (begin
            (when (and (llm-mode--runtime-live? buf)
                       (member (agent-status (llm-mode--session-id buf))
                               '(running starting needs_attention)))
              (llm-session-cancel! (llm-mode--session-id buf)))
            (llm-mode--retire-thinking! buf response-id)
            (block-set-state! buf response-id 'cancelled)
            (when result-id
              (block-set-state! buf result-id 'cancelled)
              (block-close-end! buf result-id (plist-get response 'end)))
            (when prompt-id (block-set-state! buf prompt-id 'complete))
            (block-close-end! buf response-id (plist-get response 'end))
            (buffer-set-local! buf 'llm-active-response #f)
            (buffer-set-local! buf 'llm-active-result #f)
            (buffer-set-local! buf 'llm-active-prompt #f)
            (llm-mode--sync-addressable-responses! buf)
            (message "LLM response cancelled"))))))
(define-command "llm-send-buffer" "Send this document to the LLM and stream its reply below the block at point"
  (lambda ()
    (let* ((buf (current-buffer))
           (at (point))
           (context (llm-context-text buf (buffer-text buf)))
           ;; Where the answer belongs: after the block point sits in.
           (insert-at (llm-mode--insert-at buf at))
           (model (buffer-llm-model (current-buffer))))
      (unless (minor-mode-on? buf "llm-mode")
        (enable-minor-mode! buf "llm-mode"))
      ;; A rewritten earlier turn cannot be reconciled with a native thread.
      ;; Close it and send the edited whole transcript as a new conversation.
      (let ((resync (buffer-local buf 'llm-session-dirty)))
        (when resync (llm-mode-reset-runtime! buf #f))
        (let ((wire (if resync context (llm-mode--wire-text buf context))))
          (cond
            ((and (llm-mode--runtime-live? buf)
                  (not (equal? (agent-status (llm-mode--session-id buf)) 'idle)))
             (message "LLM is still working"))
            ((and (llm-mode--stateful? buf) (equal? wire ""))
             (message "Nothing new to send"))
            (else
              ;; Claim both sides of the turn before the request begins. The
              ;; response marker is the only place callbacks may write.
              (let* ((turn (llm-mode--begin-turn! buf at insert-at model))
                     (response-id (plist-get turn 'response))
                     (response (block-resolve-id buf response-id))
                     (streamed #f))
                (message (string-append "LLM thinking · " model))
                (llm-mode--complete buf wire context model
                  (plist-get response 'start)
                  (lambda (result error)
                    (if (not (buffer-exists? buf))
                        (message "LLM reply discarded — its buffer was killed")
                        (begin
                          ;; A non-streaming backend can still return one final
                          ;; result. Both paths use the reserved response block.
                          (when (and (not streamed) (not (equal? result "")))
                            (when (llm-mode--append-response! buf response-id result)
                              (set! streamed #t)))
                          (llm-mode--finish-response!
                            buf response-id streamed error)
                          (when streamed
                            ;; An insertion in the middle dirties the native
                            ;; thread because its untouched suffix was sent.
                            (buffer-set-local! buf 'llm-session-dirty
                              (< insert-at (string-byte-length context))))
                          (when (not error)
                            (message "LLM response inserted")))))
                  (lambda (chunk)
                    (when (and (buffer-exists? buf)
                               (not (equal? chunk "")))
                      (when (llm-mode--append-response! buf response-id chunk)
                        (set! streamed #t)))))))))))))

(global-set-key "M-o" "llm-send-buffer")
(global-set-key "C-c m" "llm-set-model")
(global-set-key "C-c b" "llm-configure")
(catalog-meta! 'command "llm-send-buffer"
  'domain "llm" 'effects '("write" "external" "spend"))
(catalog-meta! 'command "llm-mode" 'domain "llm" 'effects '("write"))
(catalog-meta! 'mode "llm-mode" 'domain "llm" 'effects '("write"))

;;; --- chat buffer (gptel-style) -------------------------------------------------
;;; *chat* is an ordinary editable buffer. Type after the "### You" marker,
;;; press C-c RET, and the whole buffer becomes the conversation context.


(define (chat-prompt-marker) "\n### You\n")
(define (chat-reply-marker) "\n### Assistant\n")

;; a real mode so desktop restore can rebuild the local keys. A chat that
;; carries the block model ('agent-saved-mark) is a rich companion surface:
;; it opts into the same native renderer as agent threads, RET sends, and
;; a stale "⋯ thinking" from before a restart is swept away.
(mode-doc! "chat-mode"
  "A conversation with a model. `RET` sends what you typed and `S-RET` starts a new line. `C-g` stops the answer. `C-c C-k` clears the conversation but keeps the model.")

(define *chat-restart-message*
  "Continue the work interrupted by the editor restart. Recheck the current workspace state before acting.")

;; Code-mode can grant a chat permission to continue after a daemon restart.
;; Other chats restore their transcript but do not start external work.
(define (chat-recover-interrupted! buf)
  (when (and (buffer-exists? buf)
             (buffer-local buf 'chat-turn-active)
             (not (chat-live-runtime? buf)))
    (if (boundp (quote agent-send-msg!))
        (begin
          (chat-finalize-hung-tools! buf)
          (let ((slug (chat-attach! buf)))
            (agent-send-msg! slug *chat-restart-message*)
            (message (string-append "agent " slug ": continuing after restart"))))
        (debounce! (string-append "chat-recover:" buf) 100
                   chat-recover-interrupted! buf))))

;; the transcript half of a lost turn: tool cards still "running", and
;; permission or question blocks that nobody can answer any more.
;; agent-transcript.scm owns these fns and loads later, so guard each call.
(define (chat-finalize-hung-tools! buf)
  (when (boundp (quote agent-finalize-running-tools!))
    (agent-finalize-running-tools! buf "failed"))
  (when (boundp (quote agent-block-drop-kind!))
    (agent-block-drop-kind! buf "permission")
    (agent-block-drop-kind! buf "question"))
  (when (boundp (quote chat-activity!))
    (chat-activity! buf #f)))

;; #t when the buffer says a turn runs and its live runtime says none does.
;; A real turn holds the agent in 'running or 'needs_attention, so 'idle
;; under the flag means the turn-end event was lost — a reload mid-turn,
;; or a crashed event handler. A restart cannot clear this state: the flag
;; is a conversation local, and the dead-runtime recovery does not fire
;; because the runtime is alive.
(define (chat-turn-stale? buf)
  (and (buffer-local buf 'chat-turn-active)
       (chat-live-runtime? buf)
       (equal? (agent-status (buffer-local buf 'agent-slug)) 'idle)))

;; land what the lost turn-end would have landed. Never invents a reply.
(define (chat-drop-stale-turn! buf)
  (buffer-set-local! buf 'chat-turn-active #f)
  (buffer-set-local! buf 'agent-cancelling #f)
  (buffer-set-local! buf 'agent-turn-text #f)
  (buffer-set-local! buf 'agent-turn-any #f)
  (chat-finalize-hung-tools! buf)
  (message "chat unstuck: the hung turn is cleared, RET sends again"))

;; The chat's companion directory: the git root of the directory the chat
;; was born in (buffer-create copies the spawner's default-directory), or
;; that directory outside a repo. One git-root call per chat, at birth.
(define (chat-stamp-directory! buf)
  (let* ((born (or (buffer-local buf 'default-directory)
                   (string-append (expand-path "~") "/")))
         (root (git-root born)))
    (buffer-set-local! buf 'chat-directory
      (if (and (string? root) (not (equal? root "")))
          (string-append root "/")
          born))))

(define-mode "chat-mode"
  (lambda ()
    (let ((buf (current-buffer))
          (interrupted? (buffer-local (current-buffer) 'chat-turn-active)))
      (buffer-provenance-stop! buf "mode:chat-mode" "mode-policy" "mode")
      ;; On desktop restore EVERY runtime local is a lie: the process it
      ;; described died with the daemon. Clear the whole class — not just
      ;; the 'agent-queued that once deadlocked RET — so that bug cannot
      ;; grow a new head. Guarded on the runtime being gone, because this
      ;; same setup fn also runs via set-mode! on LIVE chats, where the
      ;; slug is the only handle on a running thread.
      (chat-sweep-runtime-locals! buf)
      (when interrupted?
        (if (chat-live-runtime? buf)
            ;; the runtime survived but its turn did not: land the lost
            ;; turn-end so the chat does not stay hung on a tool call
            (when (chat-turn-stale? buf) (chat-drop-stale-turn! buf))
            (debounce! (string-append "chat-recover:" buf) 100
                       chat-recover-interrupted! buf)))
      ;; a chat saved before the conversation of record existed carries the
      ;; old (role text) pairs — read them once, here, so a restored chat
      ;; has a record like any other
      (chat-record-migrate! buf)
      ;; the companion directory is identity: stamped once, never derived
      (unless (buffer-local buf 'chat-directory)
        (chat-stamp-directory! buf))
      ;; a .chat file just opened from disk: if we wrote it, its header
      ;; restores the identity and its transcript becomes the record, so
      ;; the conversation continues instead of restarting. Headerless files
      ;; (hand-written, or saved before this) are left exactly as they are.
      (when (and (buffer-path buf)
                 (not (buffer-local buf 'agent-saved-mark))
                 (boundp (quote chat-file-init!)))
        (chat-file-init! buf))
      ;; legacy: pre-group companions carried a 'companion-of pointer —
      ;; upgrade both ends to the 'group tag (idempotent, so desktop
      ;; restore migrates old sessions by itself)
      (let ((doc (buffer-local buf 'companion-of)))
        (when (and doc (not (buffer-local buf 'group)))
          (let ((g (or (and (buffer-exists? doc) (buffer-local doc 'group))
                       doc)))
            (buffer-set-local! buf 'group g)
            (when (and (buffer-exists? doc)
                       (not (buffer-local doc 'group)))
              (buffer-set-local! doc 'group g)))))
      (when (buffer-local buf 'agent-saved-mark)
        ;; the view is identity: default it only when never chosen (S11)
        (unless (buffer-local buf 'render-mode)
          (buffer-set-local! buf 'render-mode "agent"))
        ;; the live input carries no marker bytes; a chat from before
        ;; that change still has them at the mark, and loses them here
        (chat-input-migrate! buf)
        ;; Rebuild presentation from the CONVERSATION locals — overlays and
        ;; folds come back, and chrome belonging to a runtime that didn't
        ;; survive the restart is dropped. None of this depends on there
        ;; being a live thread (the sweep above may just have removed the
        ;; slug), so it is not gated on one.
        (when (boundp (quote agent-block-drop-kind!))
          (agent-block-drop-kind! buf "permission")
          ;; a LIVE runtime owns its waiting line, its queue, and its
          ;; pending prose tail; a dead one leaves stale chrome to sweep
          (unless (chat-live-runtime? buf)
            ;; the waiting line and its block leave together
            (agent-sweep-waiting! buf)
            ;; a queued message the dead runtime never read returns to
            ;; the input
            (agent-unqueue-renders-to-input! buf)
            ;; prose the dead runtime streamed but never revealed joins
            ;; the prose block
            (agent-adopt-prose-tail! buf))
          ;; coalesced once here: a chat saved before the join in
          ;; agent-add-overlay! holds one range per streamed delta
          (let ((ovs (buffer-local buf 'agent-overlays)))
            (when ovs
              (let ((joined (agent-overlays-coalesce ovs)))
                (unless (= (length joined) (length ovs))
                  (buffer-set-local! buf 'agent-overlays joined))
                (overlay-set! buf 'agent joined))))
          (agent-apply-folds! buf))
        ;; the modeline states the chat's identity — its connector, which
        ;; survives everything. A chat that has never attached one will
        ;; get "api" on its first send, so that is what it advertises.
        (if (and (buffer-local buf 'agent-connector)
                 (boundp (quote agent-update-modeline!)))
            (agent-update-modeline! buf)
            (begin
              (buffer-set-local! buf 'modeline-info #f)
              (buffer-set-local! buf 'modeline-info-command #f)
              (buffer-set-local! buf 'modeline-preset #f)))
        (chat-clear-waiting! buf)
        ;; ONE key set for every chat: RET is agent-send everywhere — a
        ;; chat without a runtime attaches the api backend on first send
        (when (boundp (quote agent-install-keys!))
          (agent-install-keys! buf))
        ;; a restored point can land inside the marker — typing/pasting
        ;; there corrupts the input boundary (bytes end up pre-marker)
        (chat-snap-to-input!)))))

;; the chat's editor keys; agent-session.scm adds the send and permission
;; keys to the same map
(mode-keys! "chat-mode"
  '(("C-c m" "chat-set-model") ("C-c $" "chat-cost") ("C-c b" "llm-configure")
    ("C-c C-k" "chat-reset") ("S-RET" "newline") ("C-c C-v" "chat-toggle-view")))

;; there is only one chat interface: the rich group-chat surface. C-c c
;; opens the current buffer's group chat (founding a group if needed);
;; from inside a chat it is a no-op.
(define-command "chat" "Open the group chat for this buffer"
  (lambda ()
    (let ((cur (current-buffer)))
      (unless (chat-buffer? cur)
        (group-chat-show! (group-ensure! cur))))))

;;; The system prompt is the cache prefix. Every byte is resent on every turn
;;; and tool round, so changing group membership must not change it. The static
;;; context section tells the agent to call chat-context for current members,
;;; roles, companions, workspace, and visible state.

;; Stable instructions for reading and changing live buffers. Prompt composition
;; places this text in the selectable code section.
(define *chat-edit-protocol*
  (string-append
    "Never guess buffer contents. With eval-scheme, inspect source via "
    "(code-outline \"NAME\") and (code-read \"NAME\" LINE); edit via "
    "(code-replace! \"NAME\" LINE NEW) or (code-sexp-replace! \"NAME\" "
    "ANCHOR NEW). Read prose with (buffer-text \"NAME\") and make exact "
    "text edits with (buffer-replace! \"NAME\" OLD NEW). Edits affect the "
    "live buffer and never display it. Treat \"buffer\" and \"window\" precisely. When the "
    "user says \"open it in the other buffer\" or \"show it in the other "
    "buffer\", show the named target with (display-buffer-other-window! NAME). "
    "When the user says \"switch to "
    "the other buffer\", run (run-command \"previous-buffer\"). Do not ask a "
    "question when the target is clear."))

;; The dynamic group belongs to chat-context, not to the cached prompt.
;; These fragments stay stable while buffers join, leave, or change roles.
(define (chat-code-prompt _buf)
  (string-append
    *chat-edit-protocol*
    (if (and (boundp (quote code-instructions))
             (not (equal? code-instructions "")))
        (string-append "\n\n" code-instructions)
        "")))

(define (chat-preamble _buf)
  (chat-preamble-body #f '()))

(define (chat-preamble-body _g _docs)
  (string-append
    "You are the assistant in an editor chat buffer. The transcript "
    "follows; reply to the last user turn only, in markdown.\n\n"))

;;; --- chat backends -------------------------------------------------------------
;;; A chat can ride an ACP agent (claude-code, codex — subscription billing)
;;; instead of the metered API: the buffer stays the same conversation, a
;;; thread binds to it by slug, and the agent's MCP servers come from the
;;; chat's presets plus the editor's own tool proxy. C-c b switches.

;; opts (a config plist) rides in front, so per-call keys — cmd, model,
;; cwd — win over the connector's declared config, first-wins
;; the slug IS the chat's durable id ('chat-id), made git-ref safe for
;; the agent/<slug> worktree branch. A per-boot counter collides across
;; restarts — a restored buffer can claim a live slug and take its
;; events — and a stale 'agent-slug local from an old boot is just as
;; wrong, so neither is consulted: the chat's runtime belongs to the chat.
(define (chat-runtime-slug buf)
  (string-join (string-split (chat-stable-id! buf) ":") "-"))

(define (chat-attach-agent! buf connector &optional model opts)
  (let ((slug (chat-runtime-slug buf))
        ;; a model pinned on the buffer (C-c m before the first send, or a
        ;; .chat header) is part of the chat's identity — carry it in, but
        ;; only if it actually belongs to THIS connector: a bare id left
        ;; over from an earlier ACP session (its own "default" sentinel,
        ;; say) must not ride into the api lane's wire unmodified
        (model (if (and model (not (equal? model "")))
                   model
                   (agent-model-for-connector buf connector))))
    (buffer-set-local! buf 'agent-slug slug)
    (buffer-set-local! buf 'agent-connector connector)
    (when (and model (not (equal? model "")))
      (buffer-set-local! buf 'agent-model model))
    (let ((mark (or (buffer-local buf 'agent-saved-mark)
                    ;; plain chat: give it the marker structure threads use
                    (let ((m (buffer-size buf)))
                      (buffer-set-local! buf 'agent-marker-bytes 0)
                      (buffer-set-local! buf 'render-mode "agent")
                      m))))
      (buffer-set-local! buf 'agent-saved-mark mark)
      (agent-install-keys! buf)
      (agent-update-modeline! buf)
      ;; the previous incarnation of this chat's session can still be
      ;; registered — a dead backend keeps its process. Free the id so the
      ;; same chat can open it again.
      (when (member slug (agent-list))
        (llm-session-close! slug))
      (llm-session-open! slug
        (append (list 'buffer buf 'mark mark)
                (agent-resolve-config
                  (append
                    ;; isolation (packages/worktrees.scm): an isolated
                    ;; thread gets its own worktree as cwd
                    (if (boundp (quote agent-worktree-opts))
                        (agent-worktree-opts buf slug opts)
                        (or opts '()))
                    (list 'connector connector 'buffer buf
                          'presets (if (boundp (quote chat-presets-of))
                                       (chat-presets-of buf)
                                       '()))
                    (let ((effort (buffer-local buf 'agent-effort)))
                      (if effort (list 'effort effort) '()))
                    (if (and model (not (equal? model "")))
                        (list 'model model)
                        '())))))
      slug)))

;; Every chat surface is built the same way: one meta card of help, then
;; the >>> you: input region. Only the card's words differ, so only the
;; words are a parameter — the two builders had drifted into setting
;; different locals for the same layout.
(define (chat-surface-init! buf title lines)
  (let ((help (string-append title "\n" lines)))
    (buffer-append! buf help)
    (chat-blocks-push! buf 0 (string-byte-length help) "meta" '())
    (buffer-set-local! buf 'agent-saved-mark (string-byte-length help))
    (buffer-set-local! buf 'agent-marker-bytes 0)
    buf))

;; a task chat's surface, used by (execute ...)
(define (chat-task-init! buf label)
  (chat-surface-init! buf (string-append "chat · " label)
    (string-append
      "RET sends · C-g aborts · C-RET interrupts · TAB folds tool output · "
      "C-c b LLM and tools · C-c m model\n")))

;; a chat saved as a file IS a revivable conversation: the transcript
;; format is ### You / ### Assistant (whole buffer = context) and .chat
;; files open straight into chat-mode. One save gesture — C-x C-s — does
;; the right thing: block chats flatten to that portable form via this
;; helper; everything else saves its text.
(define (chat-flatten buf)
  (and (buffer-local buf 'agent-saved-mark)
       (pair? (chat-turns buf))
       (let loop ((ts (reverse (chat-turns buf))) (acc ""))
         (if (null? ts)
             (string-append acc (chat-prompt-marker))
             (loop (cdr ts)
                   (string-append acc
                     (cond ((equal? (car (car ts)) "user")
                            (chat-prompt-marker))
                           ((equal? (car (car ts)) "status")
                            "\n### Status\n")
                           (else (chat-reply-marker)))
                     (cadr (car ts)) "\n"))))))

;;; --- .chat files carry their identity ------------------------------------------
;;; A flattened transcript is text; a chat is text PLUS who was running it.
;;; One optional header line closes that gap, so an opened .chat continues
;;; where it ran instead of starting over on the default backend:
;;;
;;;   #+chat: (connector "codex" model "gpt-5.5" presets (dev) permission-mode approve)
;;;
;;; The header is written by us and read on visit. It never reaches a
;;; model: chat-flatten (the seed) does not include it. Headerless files —
;;; anything written before this, or by hand — behave exactly as before.

(define *chat-file-header* "#+chat:")

(define (chat-header-line buf)
  (string-append *chat-file-header* " (connector "
    (value->string (or (buffer-local buf 'agent-connector) "api"))
    (let ((m (buffer-local buf 'agent-model)))
      (if m (string-append " model " (value->string m)) ""))
    (let ((effort (buffer-local buf 'agent-effort)))
      (if effort (string-append " effort " (value->string effort)) ""))
    (let ((ps (buffer-local buf 'chat-presets)))
      (if (pair? ps) (string-append " presets " (value->string ps)) ""))
    (let ((d (buffer-local buf 'chat-directory)))
      (if (string? d) (string-append " directory " (value->string d)) ""))
    (let ((s (and (boundp (quote chat-title-of)) (chat-title-of buf))))
      (if (and (string? s) (not (equal? s "")))
          (string-append " title " (value->string s))
          ""))
    (let ((s (buffer-local buf 'chat-summary)))
      (if (and (string? s) (not (equal? s "")))
          (string-append " summary " (value->string s))
          ""))
    " permission-mode "
    (symbol->string (if (boundp (quote chat-permission-mode))
                        (chat-permission-mode buf)
                        'approve))
    ")\n"))

;;; The v2 section carries what the transcript cannot: the conversation of
;;; record, tool calls and tool results included, as one JSON line below
;;; the transcript. Everything above it is exactly what v1 wrote, so a v2
;;; file still reads as a v1 file, and a v1 file (or a hand-written one)
;;; still opens — it simply has no blocks to replay.

(define *chat-record-marker* "#+chat-record: ")

;; what C-x C-s writes: identity, the portable transcript, then the record
(define (chat-file-text buf)
  (let ((body (chat-flatten buf)))
    (and body
         (string-append (chat-header-line buf) body
           (let ((r (chat-record buf)))
             (if (null? r)
                 ""
                 (string-append "\n" *chat-record-marker*
                                (json-encode (reverse r)) "\n")))))))

;; where the record section starts, in bytes, or #f
(define (chat-file-record-at text)
  (string-index text (string-append "\n" *chat-record-marker*)))

;; the recorded turns, oldest first, or #f
(define (chat-file-record text)
  (let ((i (chat-file-record-at text)))
    (and i
         (let* ((start (+ i 1 (string-byte-length *chat-record-marker*)))
                (rest (substring-bytes text start (string-byte-length text)))
                (nl (string-index rest "\n"))
                (v (json-parse (if nl (substring-bytes rest 0 nl) rest))))
           (and (pair? v) v)))))

;; the header's plist, or #f. Read INSIDE a quote so a hand-edited file can
;; never execute anything: the reader sees one quoted datum, and a failed
;; read just means "no header".
(define (chat-parse-header line)
  (and (string-prefix? *chat-file-header* line)
       (let ((r (eval-string-safe
                  (string-append "(quote "
                                 (substring line (string-length *chat-file-header*)
                                            (string-length line))
                                 ")"))))
         (and (equal? (car r) 'ok) (pair? (cadr r)) (cadr r)))))

;; "### You\nhi\n\n### Assistant\nhello\n" -> (("user" "hi") ("assistant" "hello"))
(define (chat-parse-transcript text)
  (let loop ((parts (cdr (string-split text "\n### "))) (acc '()))
    (if (null? parts)
        (reverse acc)
        (let* ((p (car parts))
               (role (cond ((string-prefix? "You\n" p) "user")
                           ((string-prefix? "Assistant\n" p) "assistant")
                           ((string-prefix? "Status\n" p) "status")
                           (else #f)))
               ;; string-index counts bytes, so the cut must too — a
               ;; transcript is arbitrary prose, not ASCII
               (body (and role
                          (string-trim
                            (substring-bytes p (string-index p "\n")
                                             (string-byte-length p))))))
          (loop (cdr parts)
                (if (and role (not (equal? body "")))
                    (cons (list role body) acc)
                    acc))))))

;; a headered .chat opened from disk becomes a live chat again: its
;; identity comes back, its turns become the conversation of record (the
;; truth every backend runs against), and the rich surface is rebuilt from
;; those turns so RET continues the conversation.
(define (chat-file-init! buf)
  (let* ((text (buffer-text buf))
         (nl (string-index text "\n"))
         (line (if nl (substring-bytes text 0 nl) text))
         (header (chat-parse-header line)))
    (when header
      (for-each
        (lambda (pair)
          (let ((v (plist-get header (car pair))))
            (when v (buffer-set-local! buf (cadr pair) v))))
        '((connector agent-connector) (model agent-model) (effort agent-effort)
          (presets chat-presets) (permission-mode chat-permission-mode)
          (title chat-title) (summary chat-summary)
          (directory chat-directory)))
      ;; A chat wears its title, not its file name. chat-restore renamed
      ;; the buffer itself; every other door into an archived conversation
      ;; -- the desktop, the chats list, plain find-file -- left it named
      ;; after the .chat path, so the modeline said the path.
      (let ((title (buffer-local buf 'chat-title)))
        (when (and (string? title) (not (equal? (string-trim title) "")))
          (rename-buffer! buf title)))
      (let* ((end (or (chat-file-record-at text) (string-byte-length text)))
             (recorded (chat-file-record text))
             (turns (chat-parse-transcript (substring-bytes text (or nl 0) end))))
        ;; v2 replays the record whole — tool calls and tool results come
        ;; back, so the next request repeats the prefix the file recorded.
        ;; v1 has only the transcript: its turns become text turns.
        (buffer-set-local! buf 'chat-wire-turns
          (if recorded
              (reverse recorded)
              (map (lambda (t) (list 'role (car t)
                                     'blocks (list (list "text" (car (cdr t))))))
                   (reverse turns))))
        ;; rebuild the surface from the turns, exactly as a live chat
        ;; renders them — the header and the ### markers are file format,
        ;; not transcript
        (buffer-delete-range! buf 0 (buffer-size buf))
        (buffer-set-local! buf 'agent-blocks '())
        (buffer-set-local! buf 'agent-saved-mark 0)
        (for-each
          (lambda (t)
            (let* ((role (car t))
                   (start (chat-render! buf
                            (cond ((equal? role "user")
                                   (string-append "\n>>> you: " (cadr t) "\n\n"))
                                  ((equal? role "status")
                                   (string-append "\n" (cadr t) "\n\n"))
                                  (else (string-append (cadr t) "\n"))))))
              (chat-blocks-push! buf start (chat-mark buf)
                (cond ((equal? role "user") "user")
                      ((equal? role "status") "status")
                      (else "prose"))
                (if (equal? role "user") (list (cadr t)) '()))))
          turns)
        (buffer-set-local! buf 'agent-marker-bytes 0)
        (buffer-set-local! buf 'render-mode "agent")
        ;; a fresh ACP session has to be told what was already said; the
        ;; api lane replays the record on every request anyway
        (buffer-set-local! buf 'agent-seed-context
          (and (pair? turns)
               (boundp (quote connector-can?))
               (not (chat-stateless? buf))))
        ;; the rewrite is presentation, not an edit the user made
        (buffer-mark-saved! buf))
      #t)))

;;; --- what a chat is made of -----------------------------------------------------
;;; The reset/restore bug class (a stale 'agent-queued deadlocking RET, a
;;; banner from a runtime that no longer exists, a help card fed back to a
;;; model as context) had ONE cause: which local means what was implicit,
;;; and reset, restore, and save each kept their own partial list. So the
;;; partition is defined once, here, and everything else consults it.
;;;
;;; STANDING RULE: any new chat buffer-local goes into exactly one of these
;;; three lists, in the same commit that introduces it.

;; who the chat IS — survives reset, restart, and save
;; ('default-directory is on every buffer, chats included: where it was
;; opened from, which is identity, not conversation or runtime)
;; 'render-mode is the chat's chosen VIEW ("agent" rich, "plain" text) —
;; a choice about the chat, so identity (S11)
(define chat-identity-locals
  '(group group-id modeline-groups chat-id group-meta group-layout group-noise
    ;; the last name the chat DERIVED from its group: a name the person
    ;; typed does not match it, and that is what makes a manual rename stick
    chat-derived-name
    agent-connector agent-model agent-effort
    chat-presets prompt-disabled-parts chat-permission-mode render-mode default-directory
    ;; the directory the spawner chose; group companions never override it
    chat-directory
    agent-permission-profile window-class header-line
    ;; which locals are markers is a fact about how the buffer works, so
    ;; it survives a reset with the rest of the identity
    marker-locals
    code-agent-saved
    workspace-id workspace-name workspace-root workspace-project-root
    workspace-backend workspace-daemon workspace-llm-defaults
    workspace-isolation-choice project-defaults-inherited))

;; what was SAID — survives restart and save; reset clears it
;; ('chat-turns is the pre-record shape: chat-record-migrate! reads it once
;; on setup and clears it, and it stays listed so a reset cannot leave one
;; behind for the migration to read again)
(define chat-conversation-locals
  '(chat-wire-turns chat-turns agent-blocks agent-overlays agent-folds
    agent-open-cards
    chat-turn-active
    ;; where the unrevealed prose tail starts: text the model said that
    ;; the prose block does not cover yet — restore adopts it, reset
    ;; clears it with the transcript
    agent-prose-from
    chat-tool-specs
    ;; The exact named system fragments this conversation sends. The first
    ;; turn sets them. Prompt refresh replaces them. Reset clears them.
    chat-prompt-snapshot
    chat-cost chat-last-usage chat-usage-total
    ;; a one-shot note for the next send (a skill body a mode pushed):
    ;; undelivered it must survive a restart, and a reset drops it
    chat-note-once
    ;; images the user pasted and did not send yet: same rule as the note,
    ;; they survive a restart and a reset drops them
    chat-pending-images
    ;; the file this conversation logs itself to under <compos-home>/chats:
    ;; a reset starts a new conversation, which gets a new file, and the
    ;; old file stays as the archive
    chat-log-id
    ;; the running summary and every paragraph before it: a reset starts
    ;; a new conversation with nothing to say yet
    chat-summary chat-summary-log
    ;; and the title the first one wrote, fixed for the life of the
    ;; conversation: a reset earns a new one
    chat-title
    agent-saved-mark agent-marker-bytes))

;; PROCESS state — mirrors a live runtime, so it is always stale after a
;; restart and meaningless after a reset: both clear it wholesale
;; ('agent-queued is retired — queued messages live in the transcript as
;; "queued" blocks now — but stays listed so old sessions' stale values
;; are still swept)
(define chat-runtime-locals
  '(agent-slug agent-queued agent-waiting chat-waiting chat-activity
    agent-cancelling agent-seed-context agent-tool-bodies
    agent-turn-text agent-turn-any chat-compacting
    agent-models agent-mode agent-modes chat-mcp-dirty
    chat-history-pos chat-history-draft
    agent-unstick agent-scroll-top
    code-agent-switch-pending prompt-parts editing-state))

(define (chat-clear-locals! buf keys)
  (for-each (lambda (k) (buffer-set-local! buf k #f)) keys))

;; a chat whose runtime is gone (restored from desktop, or crashed) is
;; carrying a description of a process that no longer exists — drop it.
;; A LIVE runtime's locals are the handle on it and must never be swept.
(define (chat-live-runtime? buf)
  (let ((slug (buffer-local buf 'agent-slug)))
    (and slug
         (boundp (quote agent-list))
         (member slug (agent-list))
         ;; slugs restart at a1 on every boot: a live slug bound to a
         ;; DIFFERENT buffer is another chat's runtime, not this one's.
         ;; Say #f so the sweep clears the stale local.
         (let ((owner (plist-get (agent-info slug) 'buffer)))
           (or (not owner) (equal? owner buf)))
         #t)))

(define (chat-sweep-runtime-locals! buf)
  (unless (chat-live-runtime? buf)
    (chat-clear-locals! buf chat-runtime-locals)))

;; wipe the conversation, keep the identity: group, backend, model,
;; presets and permission mode survive; every chat comes back as the one
;; rich surface (a legacy plain chat upgrades on reset). Idempotent.
(define-command "chat-reset" "Reset this chat: clear the transcript, start fresh"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (not (or (chat-buffer? buf) (buffer-local buf 'agent-saved-mark)))
          (message "not a chat buffer")
          (let ((g (buffer-group buf)))
            ;; FIRST: resolve anything the runtime is waiting on. A pending
            ;; permission answered after its blocks are gone is the
            ;; blind-banner race; killing the thread resolves it cancelled.
            (let ((slug (buffer-local buf 'agent-slug)))
              (when (and slug (boundp (quote llm-session-close!)))
                (unless (equal? (agent-status slug) 'dead)
                  (llm-session-close! slug))))
            (overlay-clear! buf "all")
            ;; every tag: a reset empties the buffer, so no owner's ranges
            ;; still mean anything
            (fold-clear! buf 'all)
            (chat-clear-locals! buf chat-conversation-locals)
            (chat-clear-locals! buf chat-runtime-locals)
            (buffer-delete-range! buf 0 (buffer-size buf))
            (group-chat-init! buf (or g buf))
            (set-mode! "chat-mode")
            (end-of-buffer!)
            (message "Chat reset"))))))

;; the manual door for the same repair the mode setup runs on restore. A
;; turn that shows as running while the runtime is idle or gone stays hung
;; forever without it, because no event will ever clear the flag.
(define-command "chat-unstick" "Clear a turn this chat shows as running when no runtime runs one"
  (lambda ()
    (let ((buf (current-buffer)))
      (cond
        ((not (or (chat-buffer? buf) (buffer-local buf 'agent-saved-mark)))
         (message "not a chat buffer"))
        ((not (buffer-local buf 'chat-turn-active))
         (message "no turn is stuck in this chat"))
        ((and (chat-live-runtime? buf) (not (chat-turn-stale? buf)))
         (message "this turn is live: C-g cancels it"))
        (else (chat-drop-stale-turn! buf))))))

;;; --- switching, transparently ---------------------------------------------------
;;; "Transparent" means testable: the buffer, its group, the record,
;;; presets, permission mode, cost history, and keybindings survive EVERY
;;; switch — the user just keeps typing. Keys are free (RET is agent-send
;;; on every lane), so one function with two mechanisms covers it:
;;;
;;;   live session + backend takes the model + target is offered
;;;       -> set_model in place; server-side context survives
;;;   anything else (lane change, dead session, model not takeable)
;;;       -> close the handle, attach the new backend, seed the transcript

;; can this chat's RUNNING backend take this model without a new session?
(define (chat-model-takeable? buf slug model)
  (and slug
       (not (equal? (agent-status slug) 'dead))
       (let ((cname (or (buffer-local buf 'agent-connector) *default-connector*)))
         (or (connector-can? cname 'stateless)   ; no session to lose
             (let ((offered (map car (or (buffer-local buf 'agent-models) '()))))
               (and (pair? offered) (member model offered)))))))

;; a transcript from before the mark was a buffer-local: it sits at the
;; marker's last occurrence
(define (chat-legacy-mark buf)
  (let loop ((ms (re-find* *chat-input-marker* (buffer-text buf)))
             (last (buffer-size buf)))
    (if (null? ms) last (loop (cdr ms) (car (car ms))))))

;; ONE attach. A chat that never had a runtime and a chat whose runtime
;; died are the same situation: put a fresh thread on the chat's OWN
;; connector — identity survives resets, restarts, and the runtime sweep,
;; so a restored claude-code chat comes back as claude-code — and tell it
;; what was already said. The two functions that did this had drifted:
;; one reset 'agent-queued and rescued a legacy mark, the other decided
;; seeding from a different test.
(define (chat-attach! buf)
  (let* ((cname (or (buffer-local buf 'agent-connector) "api"))
         (mark (or (buffer-local buf 'agent-saved-mark) (chat-legacy-mark buf)))
         (said (string-trim (agent-seed-transcript buf))))
    (buffer-set-local! buf 'agent-saved-mark mark)
    (chat-input-migrate! buf)
    ;; a fresh ACP session starts empty and has to be seeded; the api lane
    ;; replays the record on every request anyway
    (buffer-set-local! buf 'agent-seed-context
      (and (not (connector-can? cname 'stateless)) (> mark 0) (not (equal? said ""))))
    (let ((slug (chat-attach-agent! buf cname)))
      (unless (equal? said "")
        (message (string-append "agent " slug ": revived (fresh session)")))
      slug)))

(define (chat-ensure-runtime! buf)
  (or (buffer-local buf 'agent-slug) (chat-attach! buf)))

;; the one switch. connector #f keeps the current one; model "" means the
;; connector's own default. An omitted effort preserves it on the same lane;
;; "default" asks the backend to use the selected model's default.
(define (chat-switch! buf connector model &optional effort)
  (let* ((slug (buffer-local buf 'agent-slug))
         (cur (or (buffer-local buf 'agent-connector) *default-connector*))
         (cname (or connector cur))
         (same-lane? (equal? cname cur)))
    (cond
      ;; in place: nothing restarts, so nothing can be lost
      ((and same-lane? slug (not (equal? (agent-status slug) 'dead))
            (or (equal? model "")
                (and (chat-model-takeable? buf slug model)
                     (llm-session-set-model! slug model)))
            (or (not effort) (llm-session-set-effort! slug effort)))
       (unless (equal? model "") (buffer-set-local! buf 'agent-model model))
       (when effort
         (buffer-set-local! buf 'agent-effort
           (if (equal? effort "default") #f effort)))
       (agent-update-modeline! buf)
       'in-place)
      (else
        ;; identity that belongs to the OLD backend must not follow the
        ;; conversation across (a foreign model id is silently ignored by
        ;; an adapter while the modeline keeps repeating it)
        (unless same-lane?
          (buffer-set-local! buf 'agent-models #f)
          (buffer-set-local! buf 'agent-modes #f)
          (buffer-set-local! buf 'agent-mode #f)
          ;; a mode parked for the old backend names nothing on the new one
          (buffer-set-local! buf 'agent-mode-wanted #f)
          (buffer-set-local! buf 'agent-effort #f))
        (when effort
          (buffer-set-local! buf 'agent-effort
            (if (equal? effort "default") #f effort)))
        (buffer-set-local! buf 'chat-mcp-dirty #f)
        ;; the restart itself is agent-reconnect!'s job — the same one
        ;; C-RET and a preset change use. Reimplementing it here is how
        ;; the two paths drifted.
        (if slug
            (agent-reconnect! slug cname model)
            (begin
              (buffer-set-local! buf 'agent-connector cname)
              (buffer-set-local! buf 'agent-model (if (equal? model "") #f model))
              (chat-attach! buf)))
        'reattached))))

(define (chat-llm-apply! buf connector model effort)
  (chat-switch! buf connector (if (equal? model "default") "" model) effort)
  (message
    (string-append "chat LLM: " connector
      (if (equal? model "default") "" (string-append " · " model))
      (if (equal? effort "default") "" (string-append " · " effort))
      " — the conversation carries over")))

;;; --- one LLM setup, whole -------------------------------------------------
;;; A bundle is the ENTIRE choice behind C-c b: the backend, the model, the
;;; reasoning effort, the tool presets that session loads, and the permission
;;; stance it runs under. Remembering three of those five and dropping the
;;; rest is how a recalled combination came back with the wrong tools. A
;;; bundle that carries a name is one you keep.
;;;
;;; The representation is a plist, so a new field costs nothing that is
;;; already on disk:
;;;   (name "review" key "A" connector "claude-code" model "opus[1m]" effort "high"
;;;    presets (compos web) permission "ask" agent-mode "plan")

(define (llm-bundle-get bundle key fallback)
  (let loop ((xs bundle))
    (cond ((or (not (pair? xs)) (not (pair? (cdr xs)))) fallback)
          ((equal? (car xs) key) (cadr xs))
          (else (loop (cdr (cdr xs)))))))

(define (llm-bundle-put bundle key value)
  (append (list key value)
    (let loop ((xs bundle))
      (cond ((or (not (pair? xs)) (not (pair? (cdr xs)))) '())
            ((equal? (car xs) key) (loop (cdr (cdr xs))))
            (else (cons (car xs) (cons (cadr xs) (loop (cdr (cdr xs))))))))))

;; The persisted history predates presets: an old entry is a bare
;; (CONNECTOR MODEL EFFORT) list. It reads as a bundle that names no presets
;; and takes no stance, so recalling it changes only what it knew.
(define (llm-bundle-normalize b)
  (if (and (pair? b) (string? (car b)))
      (list 'connector (car b)
            'model (if (pair? (cdr b)) (cadr b) "default")
            'effort (if (and (pair? (cdr b)) (pair? (cdr (cdr b))))
                        (caddr b)
                        "default"))
      b))

(define (llm-bundle-name b) (llm-bundle-get b 'name #f))
(define (llm-bundle-key b) (llm-bundle-get b 'key #f))
(define (llm-bundle-connector b) (llm-bundle-get b 'connector *default-connector*))
(define (llm-bundle-model b) (llm-bundle-get b 'model "default"))
(define (llm-bundle-effort b) (llm-bundle-get b 'effort "default"))

;; #f is "this bundle recorded no presets", and applying it keeps the ones
;; already loaded. The empty list is "exactly none", which is a choice.
(define (llm-bundle-presets b) (llm-bundle-get b 'presets #f))
(define (llm-bundle-permission b) (llm-bundle-get b 'permission #f))
(define (llm-bundle-agent-mode b) (llm-bundle-get b 'agent-mode #f))
(define (llm-bundle-prompt-disabled b) (llm-bundle-get b 'prompt-disabled #f))

;; What a bundle SETS, without its name: two bundles that configure the
;; same session are one recent choice, however each was reached.
(define (llm-bundle-setup b)
  (list (llm-bundle-connector b) (llm-bundle-model b) (llm-bundle-effort b)
        (llm-bundle-presets b) (llm-bundle-permission b)
        (llm-bundle-agent-mode b) (llm-bundle-prompt-disabled b)))

;; The whole setup on one line, with every part that is already the default
;; left out: a label says what is unusual about this bundle.
(define (llm-bundle-label b)
  (string-join
    (append
      (list (llm-bundle-connector b))
      (let ((m (llm-bundle-model b))) (if (equal? m "default") '() (list m)))
      (let ((e (llm-bundle-effort b))) (if (equal? e "default") '() (list e)))
      (let* ((p (llm-bundle-presets b))
             (extra (and p (remove (lambda (x) (equal? x 'compos)) p))))
        (cond ((not p) '())
              ((null? p) (list "no tools"))
              ;; the compos bridge is on in every session; naming it says nothing
              ((null? extra) '())
              (else (list (string-join (map symbol->string extra) "+")))))
      (let ((k (llm-bundle-permission b)))
        (if (or (not k) (equal? k "approve")) '() (list k)))
      (let ((a (llm-bundle-agent-mode b)))
        (if (or (not a) (equal? a "") (equal? a "default")) '() (list a)))
      (let ((off (llm-bundle-prompt-disabled b)))
        (if (and off (pair? off))
            (list (string-append (number->string (length off)) " prompt off"))
            '())))
    " · "))

;; The buffer whose LLM session the presets and the stance belong to. A chat
;; or an llm-mode buffer is its own session; a grouped work buffer shares its
;; group chat's session. This never CREATES a chat: the menu redraws on every
;; keystroke.
;; The session of a work buffer is its group's most recent chat. The scan
;; walks the MRU list once and asks each buffer the cheap question first
;; (is it a chat?); group-buffers-mru asked every buffer for its groups,
;; which was 60 ms per call in a hundred-buffer editor, and the dashboard
;; asks after every command. A group whose chat never reached the MRU
;; answers with its primary chat.
(define (llm-config-session buf)
  ;; No buffer means the caller had no scope: M-x runs a config command
  ;; outside the transient, and the answer must still be this buffer's
  ;; session rather than #f, which reads as "the defaults" everywhere
  ;; downstream and reports a stance the chat does not have.
  (let ((buf (or buf (current-buffer))))
    (cond ((or (chat-buffer? buf) (minor-mode-on? buf "llm-mode")) buf)
          ((and (boundp (quote buffer-group)) (buffer-group buf))
           (let* ((g (buffer-group buf))
                  (chats (filter (lambda (b)
                                   (and (chat-buffer? b)
                                        (equal? (chat-group-id b) g)))
                                 (buffer-list-mru))))
             (cond ((pair? chats) (car chats))
                   ((and (boundp (quote group-primary-chat)) (group-primary-chat g)))
                   (else buf))))
          (else buf))))

(define (llm-config-permission buf)
  (if (boundp (quote chat-permission-mode)) (chat-permission-mode buf) 'auto))

;; The configuration menu keeps recent complete choices, not three unrelated
;; input histories. The transient records one final choice when it closes.
(defvar '*llm-config-history* '())
(define llm-config-history-limit 10)

;; Named bundles, newest first. These outlive the history: the history
;; forgets at ten, a named bundle is kept until it is forgotten by name.
(defvar '*llm-bundles* '())

;; A named bundle keeps its first menu key. List order may change; identity does not.
(define *llm-config-bundle-keys*
  '("a" "b" "c" "d" "e" "f" "g" "h" "i" "j" "k" "l" "m" "n" "o" "p" "q" "r"
    "t" "v" "w" "y" "z"))

(define (llm-bundle-next-key used)
  (let loop ((keys *llm-config-bundle-keys*))
    (cond ((null? keys) #f)
          ((member (car keys) used) (loop (cdr keys)))
          (else (car keys)))))

;; Old persisted bundles had no key, or an upper-case one from the first
;; menu. Assign one from the pool once, and keep a key that is in the pool.
;; The pool is the lower-case letters minus the menu's own keys (s u x).
(define (llm-bundles-assign-keys bundles)
  (let loop ((bs (map llm-bundle-normalize bundles)) (used '()) (out '()))
    (if (null? bs)
        (reverse out)
        (let* ((bundle (car bs))
               (saved (llm-bundle-key bundle))
               (key (if (and (member saved *llm-config-bundle-keys*)
                             (not (member saved used)))
                        saved
                        (llm-bundle-next-key used)))
               (keyed (if key (llm-bundle-put bundle 'key key) bundle)))
          (loop (cdr bs) (if key (cons key used) used) (cons keyed out))))))

(persist-global! 'llm-config-history
  (lambda () *llm-config-history*)
  (lambda (v) (set! *llm-config-history* (map llm-bundle-normalize (or v '())))))

(persist-global! 'llm-bundles
  (lambda () *llm-bundles*)
  (lambda (v) (set! *llm-bundles* (llm-bundles-assign-keys (or v '())))))

;; Hot reload also migrates bundles already restored into this process.
(set! *llm-bundles* (llm-bundles-assign-keys *llm-bundles*))

;; The three parts that are always cheap to read: buffer-locals, and no
;; walk to find the session. The menu redraws on every keystroke, so what
;; the menu shows comes from here.
(define (llm-config-core buf)
  (let ((chat? (equal? (buffer-local buf 'mode-name) "chat-mode")))
    (list
      'connector
      (or (buffer-local buf (if chat? 'agent-connector 'llm-connector))
          (if chat? *default-connector* "codex-app-server"))
      'model
      (or (buffer-local buf (if chat? 'agent-model 'llm-model)) "default")
      'effort
      (or (buffer-local buf (if chat? 'agent-effort 'llm-effort)) "default"))))

;; The whole setup, including the parts that belong to the session rather
;; than to this buffer. This is what gets remembered and what gets saved.
(define (llm-config-combination buf)
  (let ((session (llm-config-session buf)))
    (append (llm-config-core buf)
      (list
        'presets
        (if (boundp (quote chat-presets-of)) (chat-presets-of session) '())
        'permission
        (symbol->string (llm-config-permission session))
        'agent-mode
        (or (buffer-local session 'agent-mode) "")
        'prompt-disabled
        (or (buffer-local session 'prompt-disabled-parts) '())))))

(define (llm-config-remember! bundle)
  (let ((b (llm-bundle-normalize bundle)))
    (set! *llm-config-history*
      (take-n
        (cons b
          (remove (lambda (old)
                    (equal? (llm-bundle-setup (llm-bundle-normalize old))
                            (llm-bundle-setup b)))
                  *llm-config-history*))
        llm-config-history-limit))
    b))

(define (llm-bundle-named name)
  (let loop ((bs *llm-bundles*))
    (cond ((null? bs) #f)
          ((equal? (llm-bundle-name (car bs)) name) (car bs))
          (else (loop (cdr bs))))))

;; The name is the identity: saving over one replaces it without changing its key.
(define (llm-bundle-save! name bundle)
  (set! *llm-bundles* (llm-bundles-assign-keys *llm-bundles*))
  (let* ((old (llm-bundle-named name))
         (used (filter string? (map llm-bundle-key *llm-bundles*)))
         (key (or (and old (llm-bundle-key old)) (llm-bundle-next-key used)))
         (named (llm-bundle-put (llm-bundle-normalize bundle) 'name name))
         (b (if key (llm-bundle-put named 'key key) named)))
    (set! *llm-bundles*
      (cons b (remove (lambda (old) (equal? (llm-bundle-name old) name))
                      *llm-bundles*)))
    b))

(define (llm-bundle-forget! name)
  (set! *llm-bundles*
    (remove (lambda (old) (equal? (llm-bundle-name old) name)) *llm-bundles*))
  name)

;; One configuration surface for every LLM frontend. Chat buffers apply the
;; choice to their durable session; ordinary buffers persist it as llm-mode
;; locals, and their next turn resumes or starts the matching session.
(define (llm-config-apply! buf connector model effort)
  (if (equal? (buffer-local buf 'mode-name) "chat-mode")
      (chat-llm-apply! buf connector model effort)
      (begin
        (let ((same-connector
                (equal? connector (buffer-llm-connector buf))))
          ;; A model/effort change can resume the same Codex thread with new
          ;; overrides. A connector change cannot carry a foreign thread id.
          (llm-mode-reset-runtime! buf same-connector))
        (buffer-set-local! buf 'llm-connector connector)
        (buffer-set-local! buf 'llm-model
          (if (equal? model "default") #f model))
        (buffer-set-local! buf 'llm-effort
          (if (equal? effort "default") #f effort))
        (unless (minor-mode-on? buf "llm-mode")
          (enable-minor-mode! buf "llm-mode"))
        (message
          (string-append "LLM: " connector
            (if (equal? model "default") "" (string-append " · " model))
            (if (equal? effort "default") "" (string-append " · " effort))))))
  (when (boundp (quote workspace-llm-defaults-note!))
    (workspace-llm-defaults-note! buf)))

;; Applying a bundle applies ALL of it, in one pass: the stance and the
;; presets go in first so the reattach that a connector or model change
;; already performs carries the new tool surface too. A preset change on an
;; otherwise unchanged session reconnects at the end, without asking —
;; naming a whole setup IS the answer to that question.
(define (llm-bundle-apply! buf bundle)
  (let* ((b (llm-bundle-normalize bundle))
         (session (llm-config-session buf))
         (presets (llm-bundle-presets b))
         (permission (llm-bundle-permission b))
         (mode (llm-bundle-agent-mode b))
         (prompt-disabled (llm-bundle-prompt-disabled b)))
    (when (and permission (boundp (quote chat-permission-mode-set!)))
      (chat-permission-mode-set! session (string->symbol permission)))
    (when (and presets (boundp (quote chat-presets-set!)))
      (chat-presets-set! session presets))
    (when (and (not (equal? prompt-disabled #f))
               (boundp (quote chat-prompt-sections-set!)))
      (chat-prompt-sections-set! session prompt-disabled))
    (llm-config-apply! buf (llm-bundle-connector b) (llm-bundle-model b)
                       (llm-bundle-effort b))
    (when (boundp (quote chat-apply-pending-presets!))
      (chat-apply-pending-presets! session))
    (when (and mode (not (equal? mode "")) (boundp (quote agent-mode-set!)))
      (agent-mode-set! session mode))
    b))

;; Transient uses these catalog helpers to show the live model choices.
(define (chat-live-model-entry buf connector model)
  (and (equal? connector (buffer-local buf 'agent-connector))
       (let loop ((entries (or (buffer-local buf 'agent-models) '())))
         (cond ((null? entries) #f)
               ((and (pair? (car entries))
                     (equal? (car (car entries)) model))
                (car entries))
               (else (loop (cdr entries)))))))

;; A live backend model/list wins. Its compact entry is
;; (id display-name effort-values default-effort). Before that arrives (or
;; while choosing another connector), use the same normalized LLMDB catalog
;; that req_llm uses. Unknown is deliberately empty: never offer a
;; connector-wide superset that the selected model may reject.
(define (chat-model-effort-info buf connector model)
  (let* ((actual (if (equal? model "default")
                     (or (and (equal? connector (buffer-local buf 'agent-connector))
                              (buffer-local buf 'agent-model))
                         (and (connector-can? connector 'stateless) (llm-model)))
                     model))
         (live (and actual (chat-live-model-entry buf connector actual))))
    (if live
        (list (if (pair? (cddr live)) (caddr live) '())
              (if (pair? (cdr (cdr (cdr live))))
                  (car (cdr (cdr (cdr live)))) ""))
        (let* ((r (and actual (llm-model-reasoning actual)))
               (effort (and r (plist-get r 'effort))))
          (list (or (and effort (plist-get effort 'values)) '())
                (or (and effort (plist-get effort 'default)) ""))))))

;; A live backend tells its session which models it serves. That answer is
;; the truth about the CONNECTOR, not about one session, so keep it: the
;; next chat on that connector — and the picker aimed at a connector nothing
;; is attached to — offers the same list, instead of a hand-written seed
;; that ages the day the provider ships a model.
(defvar '*llm-connector-models* '())

(persist-global! 'llm-connector-models
  (lambda () *llm-connector-models*)
  (lambda (v) (set! *llm-connector-models* (or v '()))))

(define (llm-models-remembered connector)
  (let ((e (assoc connector *llm-connector-models*)))
    (if e (cadr e) '())))

(define (llm-models-seen! connector entries)
  (when (and connector (pair? entries))
    (set! *llm-connector-models*
      (cons (list connector entries)
            (remove (lambda (e) (equal? (car e) connector))
                    *llm-connector-models*))))
  entries)

;; Known models keep their order and their display names; a declared model
;; the live list never mentioned still shows, at the end. A catalog that
;; drops what it cannot confirm is how a working model left the menu.
(define (llm-model-options-merge known extra)
  (append known
    (filter (lambda (o) (not (assoc (car o) known))) extra)))

(define (chat-model-options buf connector)
  (let* ((live (and (equal? connector (buffer-local buf 'agent-connector))
                    (buffer-local buf 'agent-models)))
         (entries (if (pair? live) live (llm-models-remembered connector))))
    (llm-model-options-merge
      (map (lambda (e)
             (list (car e) (if (pair? (cdr e)) (or (cadr e) "") "")))
           entries)
      (map (lambda (m) (list m "")) (connector-models connector)))))

;; A backend's session modes are the connector's truth as well, and they
;; arrive on the same asynchronous event. Remembering them is what lets the
;; menu offer them to a chat that has not attached yet, and to one whose
;; session is still restarting after a backend switch — the wait for the
;; first mode-state event is why the row used to read "none".
(defvar '*llm-connector-modes* '())

(persist-global! 'llm-connector-modes
  (lambda () *llm-connector-modes*)
  (lambda (v) (set! *llm-connector-modes* (or v '()))))

(define (llm-modes-remembered connector)
  (let ((e (assoc connector *llm-connector-modes*)))
    (if e (cadr e) '())))

(define (llm-modes-seen! connector entries)
  (when (and connector (pair? entries))
    (set! *llm-connector-modes*
      (cons (list connector entries)
            (remove (lambda (e) (equal? (car e) connector))
                    *llm-connector-modes*))))
  entries)

;; the live session's own list when it has one, the connector's remembered
;; list otherwise. Entries are (id label description), as the adapter sends.
(define (chat-mode-options buf connector)
  (let ((live (and (equal? connector (buffer-local buf 'agent-connector))
                   (buffer-local buf 'agent-modes))))
    (if (pair? live) live (llm-modes-remembered connector))))

;; NOTE is the rail's footer: one line on what RET does here.
(define (llm-config-read! prompt candidates confirm cancel &optional note)
  (minibuffer-read* prompt candidates
    (append
      (list (list 'confirm confirm)
            (list 'cancel cancel)
            (list 'style "palette")
            (list 'legend '(("RET" "pick") ("C-n C-p" "select") ("TAB" "complete")
                            ("C-g" "back"))))
      (if (string? note) (list (list 'note note)) '()))))

;; A palette row with facts: (LABEL HINT "" () "" ((KEY VALUE) ...)). The
;; rail shows the facts while the row is highlighted.
(define (llm-config-row label hint facts)
  (list label hint "" '() "" facts))

;; Candidate palettes select their first row. Put CURRENT there and label it
;; explicitly; unlike pre-filling the minibuffer, this keeps every alternative
;; visible while still showing which value is active. A row's other columns
;; (its facts) ride along.
(define (llm-config-current-first candidates current)
  (let ((selected
          (map (lambda (c)
                 (cons (car c)
                       (cons (string-append "current"
                               (if (equal? (cadr c) "") ""
                                   (string-append " · " (cadr c))))
                             (cddr c))))
               (filter (lambda (c) (equal? (car c) current)) candidates)))
        (others (filter (lambda (c) (not (equal? (car c) current))) candidates)))
    (append selected others)))

;; Compatibility command for saved bindings and existing callers.
(define-command "chat-set-backend" "Choose this chat's LLM backend, model, and effort"
  (lambda () (run-command "llm-configure")))

;;; --- rich chat transcript (the agent thread design) ---------------------------
;;; A companion chat maintains the exact locals the native agent renderer
;;; reads — render-mode "agent", 'agent-blocks byte ranges, 'agent-saved-mark
;;; — so it inherits the serif prose, user cards, and tool cards wholesale.
;;; No runtime behind it: the mark lives in 'agent-saved-mark, the
;;; conversation in 'chat-wire-turns.
;;; Buffer layout: [help][transcript … mark][input].

;; the prefix of a user line in the transcript. RET writes it in front of
;; the sent message; the live input carries no marker bytes at all, so no
;; edit can damage the input boundary. A chat saved before this change
;; still holds the marker at its mark; chat-input-migrate! removes it.
(define *chat-input-marker* "\n>>> you: ")

;; the mark never points past the end: an edit the local did not see
;; (undo, a whole-region replace from the client) could leave it there.
;; A stranded local is written back to the end, so the next keystroke
;; lands in the input instead of behind a mark nobody can reach. A whole
;; local is not written: a read must not dirty the buffer.
(define (chat-mark buf)
  (let ((saved (or (buffer-local buf 'agent-saved-mark) 0))
        (size (buffer-size buf)))
    (if (> saved size)
        (begin (buffer-set-local! buf 'agent-saved-mark size) size)
        saved)))

(define (chat-blocks-push! buf start end kind meta)
  (buffer-set-local! buf 'agent-blocks
    (cons (append (list start end kind) meta)
          (or (buffer-local buf 'agent-blocks) '()))))

(define (chat-blocks-drop! buf kind)
  (buffer-set-local! buf 'agent-blocks
    (filter (lambda (b) (not (equal? (car (cdr (cdr b))) kind)))
            (or (buffer-local buf 'agent-blocks) '()))))

;; append at the mark — after every recorded range, so stored offsets
;; never shift; the input region past the marker slides along
(define (chat-render! buf text)
  (- (buffer-insert-at-local! buf 'agent-saved-mark text)
     (string-byte-length text)))

;;; --- the input region ------------------------------------------------------------
;;; Layout: [transcript … mark][live input]
;;;
;;; ONE function says where it starts. "Where does the input begin" used to
;;; be computed five ways — twice in Scheme off the runtime mark, once off
;;; the buffer-local, once in the payload builder, once in the renderer —
;;; and only one of them knew about 'agent-marker-bytes. Every reader takes
;;; it from here now, and the payload ships the same number to the client.
;;; 'agent-marker-bytes is 0 for every chat made after the marker left the
;;; live input; a restored chat keeps its old value until it migrates.
;;;
;;; It reads buffer-locals, never a runtime: a restored chat has no thread
;;; until its first send, and up-arrow has to work before then.

;; where the live input begins, never past the end of the buffer. A
;; message queued mid-turn does not live here — RET echoes it into the
;; transcript as a muted "queued" block (agent-echo-queued!), and the
;; input clears.
(define (chat-input-start buf)
  (min (+ (chat-mark buf) (or (buffer-local buf 'agent-marker-bytes) 0))
       (buffer-size buf)))

;; a chat from before the marker left the live input still carries the
;; marker bytes at its mark: remove them, keep the draft after them, and
;; record that the input starts at the mark. Runs on mode setup and on
;; attach, and does nothing to a chat that is already in the new layout.
(define (chat-input-migrate! buf)
  (when (buffer-local buf 'agent-saved-mark)
    (let* ((size (buffer-size buf))
           (m (chat-mark buf))
           (mb (string-byte-length *chat-input-marker*)))
      (when (and (<= (+ m mb) size)
                 (equal? (substring-bytes (buffer-text buf) m (+ m mb))
                         *chat-input-marker*))
        (buffer-delete-range! buf m mb))
      ;; the local cannot sit past the end after the delete
      (buffer-set-local! buf 'agent-saved-mark (chat-mark buf))
      (buffer-set-local! buf 'agent-marker-bytes 0))))

;; (START END) of the LIVE input — what RET sends
(define (chat-input-region buf)
  (list (chat-input-start buf) (buffer-size buf)))

(define (chat-input-text buf)
  (let ((r (chat-input-region buf)))
    (substring-bytes (buffer-text buf) (car r) (car (cdr r)))))

(define (chat-clear-input! buf)
  (let ((r (chat-input-region buf)))
    (buffer-delete-range! buf (car r) (- (car (cdr r)) (car r)))))

(define (chat-replace-input! buf text)
  (chat-clear-input! buf)
  (end-of-buffer!)
  (unless (equal? text "") (insert! text)))

;;; --- the conversation of record ------------------------------------------------
;;; ...moved to packages/chat.scm: the record, compaction, healing, the
;;; tool surface, the usage ledger, and the direct lane's turn context.
;;; Policy about a conversation is not the editor's business.



;; a mode whose buffer went stale OFF screen registers a catch-up
;; here; the switcher runs it for every window it just (re)filled.
;; diff-mode uses it: hidden diffs skip the expensive re-render and
;; catch up the moment they show.
;; buffer-shown-hook: (FN BUFFER). on-buffer-shown! is the older spelling.
(define (on-buffer-shown! fn) (add-hook! 'buffer-shown-hook fn))

(define (windows-shown-catchup!)
  (for-each (lambda (w) (run-hook-with-args 'buffer-shown-hook (car (cdr w))))
            (window-list)))

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
        (set-frame-local! 'winner-ring (take-n (cons now ring) *winner-depth*)))
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
(on-buffer-renamed!
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

;;; --- the modeline dashboard -----------------------------------------------------
;;; modeline-expand toggles a popup that says everything about HERE: the
;;; buffer, its modes, its group — and the LLM ledger with a spend
;;; sparkline. The modeline is the summary; this is the expansion.
;;; Clicking the modeline's name opens it too.


(define-style! 'dashboard "
.dash { font-family: var(--font-sans); padding: 2px 6px 8px; }
.dash-head { display: flex; align-items: flex-end; gap: 16px;
             padding: 10px 16px 12px; border-bottom: 1px solid var(--border, #e2dbc9); }
.dash-name { font-family: var(--font-serif); font-size: 24px; letter-spacing: -0.4px; }
.dash-file { font-family: var(--font-mono); font-size: 11px; color: var(--dim-fg, #8a857a);
             padding-top: 4px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.dash-headmain { min-width: 0; }
.dash-sp { flex: 1; }
.dash-pills { display: flex; flex-wrap: wrap; justify-content: flex-end; gap: 6px; }
.dash-pill { padding: 2px 9px; border-radius: 999px; border: 1px solid var(--border, #cbc4b1);
             color: var(--dim-fg, #57534a); font-family: var(--font-mono); font-size: 10.5px;
             white-space: nowrap; }
.dash-pill.warn { border-color: var(--diff-hunk-fg, #7a5a1a); color: var(--diff-hunk-fg, #7a5a1a); }
.dash-pill.good { border-color: var(--diff-add-fg, #2e6b45); color: var(--diff-add-fg, #2e6b45); }
.dash-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); }
.dash-cell { padding: 12px 18px 14px; display: flex; flex-direction: column; gap: 8px;
             border-right: 1px solid var(--border, #e2dbc9); min-width: 0; }
.dash-cell:last-child { border-right: none; }
.dash-title { font-family: var(--font-mono); font-size: 9.5px; letter-spacing: 0.18em;
              text-transform: uppercase; color: var(--dim-fg, #8a857a); }
.dash-big { font-family: var(--font-mono); font-size: 13px; font-weight: 600;
            color: var(--accent-fg, #26356b); }
.dash-row { display: flex; align-items: baseline; gap: 8px;
            font-family: var(--font-mono); font-size: 11.5px; }
.dash-k { color: var(--dim-fg, #8a857a); flex: 0 0 auto; }
.dash-row .dash-sp { border-bottom: 1px dotted var(--border, #cfc8b6);
                     transform: translateY(-3px); }
.dash-v { color: var(--default-fg, #1b1a17); text-align: right; min-width: 0;
          overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.dash-v.dim { color: var(--dim-fg, #b3ac9c); }
.dash-v.good { color: var(--diff-add-fg, #2e6b45); }
.dash-v.warn { color: var(--diff-hunk-fg, #7a5a1a); }
.dash-chips { display: flex; flex-wrap: wrap; gap: 5px; }
.dash-chip { padding: 2px 8px; border-radius: 6px; background: var(--window-bg, #fdfcf8);
             border: 1px solid var(--border, #e2dbc9); font-family: var(--font-mono);
             font-size: 10.5px; color: var(--dim-fg, #57534a); }
.dash-chip.dim { color: var(--faint-fg, #b3ac9c); border-style: dashed; }
.dash-chiprow { display: flex; flex-wrap: wrap; align-items: baseline; gap: 5px; }
.dash-chipkey { flex: 0 0 auto; font-family: var(--font-mono); font-size: 9.5px;
                letter-spacing: .14em; text-transform: uppercase;
                color: var(--dim-fg, #8a857a); }
.dash-persistent { display: flex; align-items: center; gap: 20px; min-width: 0;
                   overflow: hidden;
                   padding: 7px 18px 8px; border-bottom: 2px solid var(--buffer-group-color, var(--accent-fg, #26356b));
                   background: var(--window-bg, #fdfcf8); cursor: pointer; }
/* every keyed segment shows its whole value; only the wide one gives way */
.dseg { display: flex; flex-direction: column; gap: 1px; flex: 0 0 auto;
        font-family: var(--font-mono); }
.dseg-r { align-items: flex-end; }
.dseg-inline { flex-direction: row; align-items: baseline; gap: 7px; }
.dseg-k { font-size: 10.5px; letter-spacing: .16em; text-transform: uppercase;
          color: var(--faint-fg, #b3ac9c); white-space: nowrap; }
.dseg-v { font-size: 14px; color: var(--default-fg, #1b1a17); white-space: nowrap; }
.dseg-strong { font-weight: 600; }
/* The window you are in says where the Cmd-arrows go. In focus, where
   they move the window, the state reads as a filled badge in the group's
   colour and a rule runs down the left edge of the headline; in editing,
   where they move the caret, both are gone. The rule is an inset shadow,
   so no segment moves when the state turns. Only the selected window is
   marked, because only it answers the arrows. */
.window.active .dash-persistent:has(.dash-state-focus) {
  box-shadow: inset 3px 0 0 var(--buffer-group-color, var(--accent-fg, #26356b)); }
.window.active .dash-persistent .dash-state-focus .dseg-strong {
  background: var(--buffer-group-color, var(--accent-fg, #26356b));
  color: var(--window-bg, #fdfcf8);
  border-radius: 999px; padding: 1px 9px 2px; font-size: 12.5px; }
.dseg-group-current { color: var(--buffer-group-color, var(--default-fg, #1b1a17)); }
.dseg-rule { width: 1px; height: 24px; flex: 0 0 auto;
             background: var(--border-bg, #cbc4b1); opacity: .5; }
.dseg-gap { flex: 1 1 auto; }
.dseg-stack { display: flex; flex-direction: column; gap: 3px; flex: 0 0 auto; }
.dseg-wide { flex: 1 1 0; min-width: 0; }
.dseg-wide .dseg-v { white-space: normal; overflow: hidden; text-overflow: ellipsis;
                     display: -webkit-box; -webkit-box-orient: vertical;
                     -webkit-line-clamp: 2; }
")

(define (dash--row k v &optional cls)
  (list 'tag "div" 'class "dash-row"
        'segs (list (list "dash-k" k) (list "dash-sp" "")
                    (list (string-append "dash-v" (if cls (string-append " " cls) "")) v))))

(define (dash--chip m) (list 'tag "span" 'class "dash-chip" 'text m))

(define (dash--pill text cls)
  (list 'tag "span" 'class (string-append "dash-pill" (if cls (string-append " " cls) ""))
        'text text))

(define (dash--section title children)
  (list 'tag "div" 'class "dash-cell"
        'children (cons (list 'tag "div" 'class "dash-title" 'text title) children)))

(define (dash--head buf)
  (list 'tag "div" 'class "dash-head"
        'children
        (list
          (list 'tag "div" 'class "dash-headmain"
                'children
                (append
                  (list (list 'tag "div" 'class "dash-name" 'text (buffer-short-label buf)))
                  (let ((p (buffer-path buf)))
                    (if p (list (list 'tag "div" 'class "dash-file" 'text p)) '()))))
          (list 'tag "span" 'class "dash-sp" 'text "")
          (list 'tag "div" 'class "dash-pills"
                'children
                (append
                  (list (dash--pill (if (buffer-modified? buf) "modified" "saved")
                                    (if (buffer-modified? buf) "warn" "good")))
                  (if (buffer-read-only? buf) (list (dash--pill "read-only" #f)) '())
                  (list (dash--pill
                          (string-append (number->string (buffer-size buf)) " B") #f)))))))

(define (dash--chip-row key chips)
  (list 'tag "div" 'class "dash-chiprow"
        'children (cons (list 'tag "div" 'class "dash-chipkey" 'text key) chips)))

;; A keymap is read as the mode of the same name: "cua-mode-map" is
;; cua-mode. The buffer's own map wears the buffer's name, and the global
;; map is nobody's mode.
(define (dash--map-mode name)
  (if (string-suffix? "-map" name)
      (substring name 0 (- (string-length name) 4))
      name))

;; Every mode that answers here. The modeline shows the major mode and the
;; buffer's minor modes; other maps answer with nothing said -- cua-mode's,
;; the editing state's, a global minor map -- and the card names those as
;; the hidden ones. The state is the last fact: the movement state gives
;; the Cmd-arrows to the window focus, the editing state to the caret.
(define (dash--modes buf)
  (let* ((major (or (buffer-local buf 'mode-name) "Fundamental"))
         (minors (or (buffer-local buf 'minor-modes) '()))
         (shown (cons major minors))
         (maps (append (or (buffer-minor-maps buf) '())
                       (or (buffer-keymaps buf) '())
                       (or (global-minor-maps) '())))
         (hidden (dedupe-names
                   (filter (lambda (m)
                             (and (not (member m shown))
                                  (not (equal? m buf))
                                  (not (equal? m "global"))))
                           (map dash--map-mode maps)))))
    (dash--section "modes"
      (append
        (list (list 'tag "div" 'class "dash-big" 'text (dashboard--mode-name major)))
        (list (dash--chip-row "shown"
                (if (pair? minors)
                    (map (lambda (m) (dash--chip (dashboard--mode-name m))) minors)
                    (list (dash--chip "none")))))
        (if (pair? hidden)
            (list (dash--chip-row "hidden"
                    (map (lambda (m)
                           (list 'tag "span" 'class "dash-chip dim"
                                 'text (dashboard--mode-name m)))
                         hidden)))
            '())
        (list (dash--row "state" (dash--state buf)))))))

(define (dash--group buf)
  (let* ((ids (if (chat-buffer? buf)
                  (let ((g (chat-group-id buf))) (if g (list g) '()))
                  (buffer-group-ids buf)))
         (current (frame-local 'current-group))
         (primary (cond ((and current (member current ids)) current)
                        ((pair? ids) (car ids))
                        (else #f))))
    (if (null? ids)
        (dash--section "group"
          (list (dash--row "group" "none" "dim")
                (dash--row "join" "C-c g" "dim")))
        (dash--section (if (null? (cdr ids)) "group" "groups")
          (append
            ;; C-x ? is the unabridged counterpart to the compact modeline:
            ;; every membership is named, with the frame's current one first.
            (list (list 'tag "div" 'class "dash-chips"
                        'children
                        (map (lambda (g) (dash--chip (group-label g)))
                             (if (and current (member current ids))
                                 (cons current
                                       (remove (lambda (g) (equal? g current)) ids))
                                 ids))))
            ;; the members are the group list's work (M-x group-members),
            ;; not this panel's: the panel says where HERE stands
            (list (dash--row "members"
                             (number->string (length (group-buffers-mru primary))))
                  (dash--row "companion" (group-noise primary))
                  (dash--row "layout" (if (group-layout primary) "saved" "default")))
            (let ((m (group-meta primary)))
              (if m (list (dash--row "about" m)) '())))))))

;; the ledger, folded by day: today's cost and the total come from the
;; same rows
(define (dash--day-costs rows)
  (let loop ((rs rows) (acc '()))
    (if (null? rs)
        acc
        (let* ((r (car rs))
               (day (plist-get r 'day))
               (cost (or (plist-get r 'cost) 0))
               (hit (assoc day acc)))
          (loop (cdr rs)
                (if hit
                    (cons (list day (+ (cadr hit) cost))
                          (remove (lambda (e) (equal? (car e) day)) acc))
                    (cons (list day cost) acc)))))))

;; The chat that speaks for HERE: this buffer when it is one, else its
;; group's chat. The cost, the presets and the tool surface all live on
;; that buffer, so every card asks this one question.
(define (dash--here-chat buf)
  (if (chat-buffer? buf)
      buf
      (let ((g (buffer-group buf)))
        (and g (group-primary-chat g)))))

;; what HERE cost: the buffer's own chat, or its group's chat
(define (dash--here-cost buf)
  (or (buffer-local buf 'chat-cost)
      (let ((c (dash--here-chat buf)))
        (and c (buffer-local c 'chat-cost)))))

;; the model HERE would talk to, and through which lane: a chat's own
;; agent-model, a writing buffer's llm-model, else the global default.
;; The lane is acp when a connector is attached, api otherwise.
(define (dash--model buf)
  (or (buffer-local buf 'agent-model)
      (buffer-local buf 'llm-model)
      (llm-model)))

(define (dash--lane buf)
  (let ((c (buffer-local buf 'agent-connector)))
    (if (and c (not (equal? c "api")))
        (string-append "acp · " c)
        "api")))

;; the tool presets in force here: the buffer's own, or its group chat's
(define (dash--presets buf)
  (let ((p (or (buffer-local buf 'chat-presets)
               (let ((c (dash--here-chat buf)))
                 (and c (buffer-local c 'chat-presets))))))
    (and (pair? p)
         (string-join (map (lambda (x) (value->string x)) p) " · "))))

;;; The tools HERE can call. A chat freezes its tool list at its first
;;; send, so the frozen list is what the model sees; before that, the
;;; live surface is what the next send will freeze. The card names the
;;; state, so a stale list is visible where the chat is, not only in the
;;; modeline.
;;;
;;; This asks the live surface, which starts a preset's MCP servers. The
;;; panel builds only when it opens and when its fingerprint moves, so
;;; the question costs the same as the modeline already costs per turn.

(define (dash--tool-state chat)
  (cond ((pair? (buffer-local chat 'chat-tool-specs))
         (list (if (and (boundp (quote chat-tools-stale?))
                        (chat-tools-stale? chat))
                   "stale"
                   "frozen")
               (buffer-local chat 'chat-tool-specs)))
        ((boundp (quote chat-live-tool-specs))
         (list "live" (chat-live-tool-specs chat)))
        (else (list "none" '()))))

;; A preset whose server is not ready serves no tools yet. Name those
;; servers: "0 tools" with a preset set is otherwise unexplainable.
(define (dash--pending-servers chat)
  (if (not (and (boundp (quote chat-active-servers))
                (boundp (quote mcp-server-detail))))
      '()
      (let ((remote (filter (lambda (s) (not (equal? s 'compos)))
                            (chat-active-servers chat))))
        (map (lambda (s) (value->string s))
             (filter (lambda (s)
                       (let ((d (mcp-server-detail (value->string s))))
                         (not (and (pair? d)
                                   (equal? (plist-get d 'status) "ready")))))
                     remote)))))

;; twenty names, then a count: a server with fifty tools must not push
;; the ledger off the panel
(define (dash--tool-chips names)
  (let ((n (length names)))
    (list 'tag "div" 'class "dash-chips"
          'children
          (append
            (map dash--chip (if (> n 20) (take-n names 20) names))
            (if (> n 20)
                (list (dash--chip (string-append "+" (number->string (- n 20))
                                                 " more")))
                '())))))

(define (dash--tools buf)
  (let ((chat (dash--here-chat buf)))
    (if (not chat)
        (dash--section "tools"
          (list (dash--row "chat" "none" "dim")
                (dash--row "open" "C-c c" "dim")))
        (let* ((st (dash--tool-state chat))
               (state (car st))
               (names (map car (car (cdr st))))
               (n (length names))
               (ps (dash--presets buf)))
          (dash--section "tools"
            (append
              (list (list 'tag "div" 'class "dash-big"
                          'text (string-append (number->string n)
                                               (if (= n 1) " tool" " tools")))
                    (dash--row "presets" (or ps "none") (if ps #f "dim"))
                    (dash--row "list" state
                               (cond ((equal? state "stale") "warn")
                                     ((equal? state "frozen") "good")
                                     (else "dim"))))
              (if (equal? state "stale")
                  (list (dash--row "adopt" "C-c t"))
                  '())
              ;; a server that is not ready serves nothing, and the count
              ;; above says so without saying why. Name it at any count:
              ;; a surface missing one server still looks complete.
              (let ((pending (dash--pending-servers chat)))
                (if (pair? pending)
                    (list (dash--row "waiting on"
                                     (string-join pending " · ") "warn"))
                    '()))
              (if (pair? names) (list (dash--tool-chips names)) '())
              (list (dash--row "servers" "M-x mcp-hub" "dim"))))))))

(define (dash--llm buf)
  (let* ((rows (llm-cost-report))
         (days (sort-by-car (dash--day-costs rows)))
         (total (fold (lambda (a d) (+ a (cadr d))) 0 days))
         (today (if (pair? days) (car (reverse days)) #f))
         (here (dash--here-cost buf)))
    (dash--section "llm"
      (append
        (list (list 'tag "div" 'class "dash-big" 'text (dash--model buf))
              (dash--row "lane" (dash--lane buf)))
        (if here (list (dash--row "this chat" (format-usd here))) '())
        (list (dash--row "today, all" (if today (format-usd (cadr today)) "$0") #f)
              (dash--row "total, all" (format-usd total))
              (dash--row "ledger" "M-x llm-costs" "dim"))))))

;; an ISO day as one integer (20260816): the dialect has no string<?
(define (dash--day-int d)
  (or (string->number (string-join (string-split d "-") "")) 0))

(define (sort-by-car xs)
  (let loop ((rest xs) (out '()))
    (if (null? rest)
        out
        (loop (cdr rest)
              (let ins ((ys out))
                (cond ((null? ys) (list (car rest)))
                      ((< (dash--day-int (car (car rest)))
                          (dash--day-int (car (car ys))))
                       (cons (car rest) ys))
                      (else (cons (car ys) (ins (cdr ys))))))))))

(define (last-n xs n)
  (let ((k (length xs)))
    (if (<= k n) xs (list-tail-n xs (- k n)))))

(define (list-tail-n xs n)
  (if (= n 0) xs (list-tail-n (cdr xs) (- n 1))))

;; the expansion is a panel INSIDE the buffer's window, pinned above
;; the text — the buffer stays editable beneath it. The state is one
;; buffer-local; the blocks are derived and never saved.
(define (desktop-skip! buf key)
  (let ((cur (or (buffer-local buf 'desktop-skip-locals) '())))
    (unless (member key cur)
      (buffer-set-local! buf 'desktop-skip-locals (cons key cur)))))

;; the panel PULLS like the bar: everything per-buffer (position,
;; modes, read-only) renders in the view from live state. Only the
;; cross-buffer cards ship as blocks: the group's detail and the
;; ledger. post-command! keeps those honest.
(define (dashboard-blocks buf)
  (list (dash--head buf)
        (dash--modes buf)
        (dash--group buf)
        (dash--tools buf)
        (dash--llm buf)))

(define (dashboard--group-ids buf)
  (if (chat-buffer? buf)
      (let ((g (chat-group-id buf))) (if g (list g) '()))
      (buffer-group-ids buf)))

(define (dashboard--mode-name name)
  (let ((s (if (symbol? name) (symbol->string name) name)))
    (if (and (string? s) (string-suffix? "-mode" s))
        (substring s 0 (- (string-length s) 5))
        (or s "Fundamental"))))

;; The compact dashboard stays at the top of the window. It keeps the LLM
;; context and every group visible in one line, then opens the full panel.
;; PRESET-CELL, when given, is (list PRESET): the sync reads the preset
;; once for both the line and the blocks, because the read walks the
;; saved bundles against the live setup
(define (dashboard-one-line buf &optional preset-cell)
  (let* ((ids (dashboard--group-ids buf))
         (modes (cons (or (buffer-local buf 'mode-name) "Fundamental")
                      (or (buffer-local buf 'minor-modes) '())))
         (mode-text (string-join (map dashboard--mode-name modes) " · "))
         (preset (if preset-cell (car preset-cell) (dash--preset buf)))
         (groups (if (pair? ids)
                     (string-join (map group-label ids) " · ")
                     "none")))
    (string-append "mode " mode-text
                   "   state " (dash--state buf)
                   "   groups " groups
                   (if preset
                       (string-append "   preset " preset)
                       (string-append "   llm " (dash--model buf)
                                      "   lane " (dash--lane buf))))))

;;; The same facts, keyed. A flat run of tokens spends one weight on
;;; every word, so nothing reads first. Each segment puts a whisper-sized
;;; key over its value, and the value carries the line. Place goes left,
;;; machine state goes right, and a hairline rule separates them.

(define (dash--seg key segs align &optional extra-class)
  (list 'tag "c-field"
        'class (string-append
                (if (equal? align 'right) "dseg dseg-r" "dseg")
                (if extra-class (string-append " " extra-class) ""))
        'attrs (if key (list (list "name" key)) '())
        'children
        (append
          (if key
              (list (list 'tag "c-label" 'class "dseg-k" 'text key))
              '())
          (list (list 'tag "c-value" 'class "dseg-v" 'segs segs)))))

(define (dash--seg-rule)
  (list 'tag "span" 'class "dseg-rule"))

(define (dash--seg-gap)
  (list 'tag "span" 'class "dseg-gap"))

;; the major mode carries the weight; the minor modes trail it
(define (dash--mode-segs buf)
  (let* ((major (dashboard--mode-name (or (buffer-local buf 'mode-name) "Fundamental")))
         (minors (or (buffer-local buf 'minor-modes) '()))
         ;; a rendered preview is a mode the reader can see. It rides
         ;; 'render-mode, not the minor-mode list, so read it here.
         (render (buffer-local buf 'render-mode))
         ;; preview-mode already names itself when it is on; the render
         ;; mode fills in only for a page some other route rendered
         (extra (if (and (string? render)
                         (member render '("html" "markdown"))
                         (not (member "preview-mode" minors)))
                    (list "preview")
                    '())))
    (cons (list "dseg-strong" major)
          (map (lambda (m)
                 (list "f-dim" (string-append " · " (dashboard--mode-name m))))
               (append minors extra)))))

;; the last group is where you are; the ones before it are the path
(define (dash--group-segs buf)
  (let ((labels (map group-label (dashboard--group-ids buf))))
    (if (null? labels)
        (list (list "f-faint" "none"))
        (let loop ((rest labels) (out '()))
          (if (null? (cdr rest))
              (reverse (cons (list "dseg-strong dseg-group-current" (car rest)) out))
              (loop (cdr rest)
                    (cons (list "f-faint" " / ")
                          (cons (list "f-dim" (car rest)) out))))))))

;; "openrouter:sonnet" reads as one word until the provider steps back
(define (dash--model-segs buf)
  (let* ((model (dash--model buf))
         (parts (string-split model ":")))
    (if (> (length parts) 1)
        (list (list "f-dim" (string-append (car parts) ":"))
              (list "dseg-strong" (string-join (cdr parts) ":")))
        (list (list "dseg-strong" model)))))

;; the open jj change of the buffer's repo: jj.scm keeps a cache by root,
;; so a chat that lives in the repo shows the line as well as a file does
(define (dash--vcs buf)
  (and (boundp 'jj-modeline-line) (jj-modeline-line buf)))

;; The two states of an editable buffer, in one word, and the word says
;; where the Cmd-arrows go. "focus" gives them to the window; "editing"
;; gives them to the caret. The caret map is the whole question, so the
;; word reads that map and not the editing-state flag: a mode that refuses
;; the caret map keeps the window chords in the editing state, and a chat
;; is such a mode, so a chat says focus while you type in it. A read-only
;; buffer never leaves focus.
(define (dash--state buf)
  (if (member "editing-caret-map" (buffer-minor-maps buf)) "editing" "focus"))

(define (dash--preset buf)
  (and (boundp (quote llm-config-preset-name))
       (llm-config-preset-name buf)))

;; the chat's title: the first label its running summary wrote. The bar
;; names the chat, and a name that changes under you names nothing --
;; the paragraph the summary says now is a click away, in the log.
(define (dash--summary buf)
  (and (chat-buffer? buf)
       (let ((s (if (boundp (quote chat-title-of))
                    (chat-title-of buf)
                    (buffer-local buf 'chat-title))))
         (and (string? s) (not (equal? s "")) s))))

;;; What a mode's headline keeps when its window is narrow. Where narrow
;;; starts is narrow-cols, the system's answer; a mode declares only WHICH
;;; of the segments survive it. The names are mode, group, llm and wide. A
;;; mode that declares nothing keeps every segment and lets the row clip.
(define *mode-headlines* '())

(define (define-mode-headline! mode narrow)
  (set! *mode-headlines*
    (cons (list mode narrow)
          (remove (lambda (e) (equal? (car e) mode)) *mode-headlines*)))
  mode)

(define (mode-headline mode)
  (let ((e (assoc mode *mode-headlines*))) (and e (cadr e))))

;; A chat in a narrow pane keeps what it is and what is behind it. Its
;; group is already the colour of the headline's own border and its title
;; is already the modeline name, so neither needs the room; the model and
;; the lane have nowhere else to appear, because the chat modeline gave
;; them up.
(define-mode-headline! "chat-mode" '(mode llm))

;; The minor modes first, then the major mode: the same walk buffer-layout
;; makes, so one buffer answers with one declaration. WIDTH is the columns
;; of the window showing BUF; a wide window keeps everything and answers #f.
(define (dash--headline-keep buf width)
  (and (< width narrow-cols)
       (let loop ((names (append (or (buffer-local buf 'minor-modes) '())
                                 (let ((m (buffer-local buf 'mode-name)))
                                   (if m (list m) '())))))
         (if (null? names)
             #f
             (let ((keep (mode-headline (car names))))
               (or keep (loop (cdr names))))))))

;; The rules separate whatever survives. They are not segments: dropping a
;; segment must never leave the rule that stood beside it dangling.
(define (dash--ruled blocks)
  (if (null? blocks)
      '()
      (cons (car blocks)
            (let loop ((rest (cdr blocks)))
              (if (null? rest)
                  '()
                  (cons (dash--seg-rule)
                        (cons (car rest) (loop (cdr rest)))))))))

(define (dashboard-line-blocks buf &optional preset-cell)
  (let* ((vcs (dash--vcs buf))
         (summary (dash--summary buf))
         (preset (if preset-cell (car preset-cell) (dash--preset buf)))
         ;; every segment carries its name, so a narrow window keeps the
         ;; ones its mode declared and drops the rest
         (cells
           (append
             (list
               (list 'mode (dash--seg "mode" (dash--mode-segs buf) 'left))
               ;; which keys the buffer answers: focus moves the window,
               ;; editing moves the caret
               ;; the state also names itself as a class, so the headline
               ;; of the window you are in can wear the colour of the state
               (list 'state (let ((state (dash--state buf)))
                              (dash--seg "state"
                                (list (list "dseg-strong" state)) 'left
                                (string-append "dash-state-" state))))
               (list 'group (dash--seg "group" (dash--group-segs buf) 'left))
               ;; the preset names the whole setup, so it stands alone: the model
               ;; and the lane are what it chose, and repeating them says nothing
               (list 'llm
                 (if preset
                     (dash--seg "preset" (list (list "dseg-strong" preset)) 'right)
                     (list 'tag "div" 'class "dseg-stack"
                           'children
                           (list (dash--seg "llm" (dash--model-segs buf) 'right "dseg-inline")
                                 (dash--seg "lane"
                                   (list (list "f-ok dseg-strong" (dash--lane buf)))
                                   'right "dseg-inline"))))))
             ;; one wide segment at the end, wrapping to two lines with the key
             ;; inline: a chat says what it is doing, and every other buffer of
             ;; the repo names the open jj change, kept fresh by jj.scm
             ;; A click on it opens the log of every line it showed.
             (cond (summary (list (list 'wide (dash--wide-seg #f summary))))
                   (vcs (list (list 'wide (dash--wide-seg "jj" vcs))))
                   (else '()))))
         (keep (dash--headline-keep buf (buffer-cols buf))))
    (dash--ruled
      (map cadr
           (if keep
               (filter (lambda (cell) (member (car cell) keep)) cells)
               cells)))))

(define (dash--wide-seg key text)
  (let ((base (dash--seg key (list (list "f-dim" text)) 'left "dseg-inline dseg-wide")))
    (list 'tag "c-action"
          'class (plist-get base 'class)
          'children (plist-get base 'children)
          'click "summary-log"
          'attrs (append (if key (list (list "name" key)) '())
                         (list (list "target" "summary-log")
                               (list "title" "open the summary log"))))))

;; The modeline names the buffer the short way: project coordinates inside
;; a project, "~" for the home directory outside one. The buffer name keeps
;; the absolute path, and the modeline's tooltip still says it.
;; A buffer with no file can still name one: "*chat:/Users/me/notes.md*".
;; Write the home directory as ~ wherever it appears in the name.
(define (abbreviate-home-in text)
  (let ((home (getenv "HOME")))
    (if (and (string? text) (string? home) (> (string-length home) 1))
        (string-join (string-split text home) "~")
        text)))

;; A chat is known by its title, not by *chat:GROUP:N*. A titled chat
;; wears its title as its buffer name already; an untitled one keeps its
;; derived name until its running summary writes the first label.
(define (buffer-modeline-chat-name buf)
  (let ((label (and (chat-buffer? buf)
                    (boundp 'chat-prompt-label)
                    (chat-prompt-label buf))))
    (if (and (string? label) (not (equal? label "")))
        label
        (abbreviate-home-in buf))))

(define (buffer-modeline-name buf)
  (let* ((path (buffer-path buf))
         (root (buffer-project-root buf))
         (name (cond ((not (string? path)) (buffer-modeline-chat-name buf))
                     ((and (string? root) (not (equal? root ""))
                           (string-prefix? (string-append root "/") path))
                      (substring path (+ 1 (string-length root)) (string-length path)))
                     (else (abbreviate-file-name path)))))
    ;; a peek says so where the name is: the one mark the feature has
    (if (peek-buffer? buf)
        (string-append "peek · " name)
        name)))

;; A file names its project beside its modeline name. A chat has no file,
;; so that same context slot names the directory where its tools run.
(define (buffer-modeline-context buf)
  (if (chat-buffer? buf)
      (abbreviate-file-name (buffer-directory buf))
      (buffer-project-label buf)))

;;; --- the buffer-name grammar --------------------------------------------------
;;; A name renders. Every chrome that shows a buffer or a group draws the
;;; same small markup and never the raw characters: *Messages* was always
;;; meant to read as a bold "Messages", and the naming convention the
;;; editor already had IS the grammar.
;;;
;;;   *text*   strong        :key:  one icon; :mode: is the buffer's own
;;;   ~text~   dim           \\x     a literal x
;;;   `text`   mono
;;;
;;; The delimiters are the ones a name does not carry by accident.
;;; Markdown's _ is absent on purpose: editor_live.ex and __init__.py would
;;; each lose a word to it. A delimiter that never closes is text, and so is
;;; :key: for an icon nobody registered, which keeps a name like
;;; notmuch:thread:0005 whole.
;;;
;;; A format string says what a name is made of, so a mode changes its own
;;; without touching a renderer: set the buffer-local name-format, or
;;; buffer-name-format for the rest. name-format-expand fills the
;;; %-directives and name-segments parses the result; both are pure. The
;;; value is the ((CLASS TEXT) ...) list the modeline extra already speaks,
;;; so Scheme names the classes and the client draws one span each.

(define *name-icons* '())            ; ((KEY GLYPH) ...) what :key: reaches

(define (name-icon! key glyph)
  (set! *name-icons*
    (cons (list key glyph)
          (remove (lambda (e) (equal? (car e) key)) *name-icons*))))

;; a caller's own icons come first: :mode: belongs to the buffer, not here
(define (name--icon key icons)
  (let ((e (or (assoc key icons) (assoc key *name-icons*))))
    (and e (cadr e))))

;; the character position of CH in TEXT at or after FROM, or #f. string-index
;; counts bytes where substring counts characters, and a name carries icons:
;; the scan must count characters or the two disagree.
(define (name--index text ch from)
  (let ((n (string-length text)))
    (let loop ((i from))
      (cond ((>= i n) #f)
            ((equal? (substring text i (+ i 1)) ch) i)
            (else (loop (+ i 1)))))))

(define (name--class ch)
  (cond ((equal? ch "*") "bn-strong")
        ((equal? ch "~") "bn-dim")
        ((equal? ch "`") "bn-code")
        ((equal? ch ":") "bn-icon")
        (else #f)))

(define (name--flush plain out)
  (if (equal? plain "") out (cons (list "bn-text" plain) out)))

(define (name--trim-left s)
  (let ((n (string-length s)))
    (let loop ((i 0))
      (cond ((>= i n) "")
            ((equal? (substring s i (+ i 1)) " ") (loop (+ i 1)))
            (else (substring s i n))))))

(define (name--trim-right s)
  (let loop ((n (string-length s)))
    (cond ((= n 0) "")
          ((equal? (substring s (- n 1) n) " ") (loop (- n 1)))
          (else (substring s 0 n)))))

(define (name--drop-empty segs)
  (filter (lambda (s) (not (equal? (cadr s) ""))) segs))

(define (name--edge segs trim)
  (if (null? segs)
      '()
      (cons (list (car (car segs)) (trim (cadr (car segs)))) (cdr segs))))

;; A mode that declares no icon leaves the space that stood beside it, and a
;; name never begins or ends on one. Drop the empty segments first, so that
;; space is an edge by the time the edges are trimmed.
(define (name--tidy segs)
  (let* ((a (name--drop-empty segs))
         (b (name--edge a name--trim-left))
         (c (reverse (name--edge (reverse b) name--trim-right))))
    (name--drop-empty c)))

(define (name-segments spec &optional icons)
  (let* ((text (if (string? spec) spec ""))
         (icons (or icons '()))
         (n (string-length text)))
    (name--tidy
      (let loop ((i 0) (plain "") (out '()))
        (if (>= i n)
            (reverse (name--flush plain out))
            (let ((ch (substring text i (+ i 1))))
              (cond
                ((and (equal? ch "\\") (< (+ i 1) n))
                 (loop (+ i 2)
                       (string-append plain (substring text (+ i 1) (+ i 2)))
                       out))
                ((name--class ch)
                 (let ((close (name--index text ch (+ i 1))))
                   ;; no partner, or an empty body: the delimiter is text
                   (if (or (not close) (= close (+ i 1)))
                       (loop (+ i 1) (string-append plain ch) out)
                       (let ((body (substring text (+ i 1) close)))
                         (if (equal? ch ":")
                             (let ((glyph (name--icon body icons)))
                               (if glyph
                                   (loop (+ close 1) ""
                                         (cons (list "bn-icon" glyph)
                                               (name--flush plain out)))
                                   (loop (+ i 1) (string-append plain ch) out)))
                             (loop (+ close 1) ""
                                   (cons (list (name--class ch) body)
                                         (name--flush plain out))))))))
                (else (loop (+ i 1) (string-append plain ch) out)))))))))

;; VALS is ((KEY VALUE) ...) over one-character keys. An unknown directive
;; stays as it was written, so a name that carries a per cent sign survives.
(define (name-format-expand format vals)
  (let* ((text (if (string? format) format ""))
         (n (string-length text)))
    (let loop ((i 0) (out ""))
      (if (>= i n)
          out
          (let ((ch (substring text i (+ i 1))))
            (if (and (equal? ch "%") (< (+ i 1) n))
                (let* ((key (substring text (+ i 1) (+ i 2)))
                       (e (assoc key vals)))
                  (cond ((equal? key "%") (loop (+ i 2) (string-append out "%")))
                        (e (loop (+ i 2) (string-append out (or (cadr e) ""))))
                        (else (loop (+ i 2) (string-append out ch key)))))
                (loop (+ i 1) (string-append out ch))))))))

;; the same name as one string, for a tooltip and for a caller with no spans
(define (name-text segments)
  (string-join (map cadr segments) ""))

;; How a buffer names itself: the mode's icon, then the compact name, whose
;; own asterisks make a special buffer bold. A mode with something else to
;; say sets the buffer-local name-format instead. %n is that compact name,
;; %N the buffer name, %m the mode, %p the project or the working directory.
(define buffer-name-format ":mode: %n")

(define (buffer-name-segments buf)
  (name-segments
    (name-format-expand
      (or (buffer-local buf 'name-format) buffer-name-format)
      (list (list "n" (buffer-modeline-name buf))
            (list "N" buf)
            (list "m" (or (buffer-local buf 'mode-name) "Fundamental"))
            (list "p" (buffer-modeline-context buf))))
    (list (list "mode" (buffer-icon buf)))))

(define (dashboard--sync! buf)
  (desktop-skip! buf 'dashboard-line)
  (desktop-skip! buf 'dashboard-line-blocks)
  (desktop-skip! buf 'modeline-name)
  (desktop-skip! buf 'modeline-name-segments)
  (desktop-skip! buf 'modeline-project)
  ;; one preset read for the line and the blocks; one change for the five
  ;; locals, so the frame refreshes once for the sync
  (let ((preset-cell (list (dash--preset buf))))
    (buffer-set-locals! buf
      (list 'dashboard-line (dashboard-one-line buf preset-cell)
            'dashboard-line-blocks (dashboard-line-blocks buf preset-cell)
            'modeline-name (buffer-modeline-name buf)
            ;; the same name as the spans that draw it: the client shows
            ;; these and falls back to the plain string only without them
            'modeline-name-segments (buffer-name-segments buf)
            ;; The project stands beside a file name. A chat shows its
            ;; working directory in the same context slot.
            'modeline-project (buffer-modeline-context buf)))))

;; The fingerprint reads locals only — never the live tool surface. It
;; runs after every command, and asking the surface there would start
;; MCP servers on a cursor move. The frozen list and the presets are the
;; state that moves the tools card, and both are locals.
(define (dash--fingerprint buf)
  (let ((chat (dash--here-chat buf)))
    (list (buffer-local buf 'mode-name)
          (buffer-local buf 'minor-modes)
          ;; the modes card names every map that answers here, and the
          ;; editing state adds and drops maps as you type
          (buffer-minor-maps buf)
          (dashboard--group-ids buf)
          (frame-local 'current-group)
          (buffer-local buf 'agent-model)
          (buffer-local buf 'agent-connector)
          (buffer-local buf 'llm-model)
          (and chat (buffer-local chat 'chat-presets))
          (and chat (map car (or (buffer-local chat 'chat-tool-specs) '()))))))

(define-command "modeline-expand"
  "Toggle this buffer's expanded modeline panel"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (buffer-local buf 'modeline-expanded)
          (begin
            (buffer-set-local! buf 'modeline-expanded #f)
            (buffer-set-local! buf 'modeline-dash-blocks #f))
          (begin
            (desktop-skip! buf 'modeline-expanded)
            (desktop-skip! buf 'modeline-dash-blocks)
            (desktop-skip! buf 'modeline-dash-fp)
            (buffer-set-local! buf 'modeline-dash-fp (dash--fingerprint buf))
            (buffer-set-local! buf 'modeline-dash-blocks (dashboard-blocks buf))
            (buffer-set-local! buf 'modeline-expanded #t))))))

;; before every command and every self-insert: packages that must act
;; before the buffer changes (the chat keeps point in its input) hang
;; on pre-command-hook
(define (pre-command!)
  (run-hooks 'pre-command-hook))

;; after every command: an expanded panel that no longer matches its
;; buffer rebuilds itself — modes, group, model all change under it
(define (post-command!)
  (let ((buf (current-buffer)))
    ;; the dashboard of the buffer the command ran in. A silent buffer
    ;; costs nothing here: the event that changes its dashboard (a jj
    ;; line, a summary, a restore) calls dashboard--sync! on it itself.
    (dashboard--sync! buf)
    (list-post-command! buf)
    ;; a list on screen shows what is, not what was: the command may have
    ;; killed a buffer the list beside it still names
    (for-each (lambda (w)
                (unless (equal? (cadr w) buf)
                  (list-post-command! (cadr w))))
              (window-list))
    (when (buffer-local buf 'modeline-expanded)
      (let ((fp (dash--fingerprint buf)))
        (unless (equal? fp (buffer-local buf 'modeline-dash-fp))
          (buffer-set-local! buf 'modeline-dash-fp fp)
          (buffer-set-local! buf 'modeline-dash-blocks (dashboard-blocks buf)))))
    ;; the extension seam: packages react to the command that just ran
    ;; (paredit paints the matching delimiter here)
    (run-hooks 'post-command-hook)))

;; members in MRU order; buffers never visited this session trail
;; behind. A group is a SET: the list dedupes by name, whatever the
;; sources produce.
(define (dedupe-names xs)
  (let loop ((xs xs) (seen '()) (out '()))
    (cond ((null? xs) (reverse out))
          ((member (car xs) seen) (loop (cdr xs) seen out))
          (else (loop (cdr xs) (cons (car xs) seen) (cons (car xs) out))))))

(define (chat-buffer? b)
  (equal? (buffer-local b 'mode-name) "chat-mode"))

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

;;; --- llm cost inspection -----------------------------------------------------
;;; Every request is priced (models.dev catalog, cached in ~/.compos/llmdb.json,
;;; refreshed daily) and recorded in ~/.compos/llm-usage.jsonl; each chat also
;;; sums its own spend in the 'chat-cost buffer-local.

;; What a chat cost, and — the number that decides whether it was worth it
;; — how much of its input the provider served from cache. A conversation
;; resends its whole history every turn. At a healthy hit rate that history
;; bills at about a tenth of the price; at 0% it bills at full price twice
;; over, because a cache WRITE costs more than a plain read.
(define-command "chat-cost" "Show what this chat has cost, and its cache hit rate"
  (lambda ()
    (let* ((buf (current-buffer))
           (c (buffer-local buf 'chat-cost))
           (u (buffer-local buf 'chat-last-usage))
           (ctx (chat-context-tokens buf))
           (total (chat-usage-total buf))
           (rate (chat-hit-rate total)))
      (if (not (or c u ctx))
          (message "No usage reported in this chat yet")
          (message
            (string-append
              "This chat: " (if c (format-usd c) "unpriced")
              ;; what it occupies right now, which is the number a reader
              ;; asks for when a conversation feels long
              (if ctx
                  (string-append " · context "
                    (number->string (plist-get ctx 'used))
                    (let ((size (plist-get ctx 'size)))
                      (if size (string-append " of " (number->string size)) ""))
                    " tokens")
                  "")
              " · cache " (number->string (or (plist-get total 'cache-read) 0)) " read / "
              (number->string (or (plist-get total 'cache-write) 0)) " written"
              (if rate (string-append " · " rate " of input cached") "")
              (if u
                  (string-append " · last turn "
                    (number->string (or (custom--plist-get u 'input) 0)) "→"
                    (number->string (or (custom--plist-get u 'output) 0)) " tokens"
                    (let ((tc (custom--plist-get u 'cost)))
                      (if tc (string-append " (" (format-usd tc) ")") "")))
                  "")))))))

(define-command "llm-costs" "Show LLM spend by day and model (the usage ledger)"
  (lambda ()
    (let ((rows (llm-cost-report))
          (buf "*llm-costs*"))
      (buffer-create buf)
      (buffer-delete-range! buf 0 (string-byte-length (buffer-text buf)))
      (buffer-append! buf
        (fold (lambda (acc r)
                (string-append acc
                  (custom--plist-get r 'day) "  "
                  (format-usd (custom--plist-get r 'cost)) "  "
                  (number->string (custom--plist-get r 'requests)) " reqs  "
                  (number->string (custom--plist-get r 'input)) "→"
                  (number->string (custom--plist-get r 'output)) "  "
                  ;; the cache columns: read is what the prefix cost a tenth
                  ;; of, written is what it cost a quarter more than usual
                  "cache " (number->string (custom--plist-get r 'cache-read)) "r/"
                  (number->string (custom--plist-get r 'cache-write)) "w  "
                  (let ((h (custom--plist-get r 'hit-rate)))
                    (string-pad-right
                      (if h (string-append (number->string h) "% cached") "") 12))
                  "  " (custom--plist-get r 'model) "\n"))
              (string-append
                "LLM spend · ledger ~/.compos/llm-usage.jsonl · per-chat: C-c $\n"
                "hit rate is cached input over billed input: low means the "
                "prefix is being rewritten every turn\n\n")
              rows))
      (switch-to-buffer! buf))))

;; a new chat buffer in the current group; the old conversation stays.
;; The frame's group wins; a buffer outside any group founds one only
;; when the frame stands in none.
(define-command "chat-new" "Start a new chat buffer; with a prefix, choose or create its group"
  (interactive 'P)
  (lambda (prefix)
    (if prefix
        (group-read-or-create! "New chat in group: "
          (lambda (g) (group-chat-new! g)))
        (let ((g (or (frame-group) (group-ensure! (current-buffer)))))
          (if (not g)
              (message "No group for a chat")
              (group-chat-new! g))))))

;; C-c q from anywhere: the prompt becomes a turn in this buffer's group
;; chat (founding the group first if needed) — one chat interface, always
(define-command "llm-ask" "Ask the LLM from anywhere via the minibuffer"
  (lambda ()
    (group-ask! (group-ensure! (current-buffer)))))

(global-set-key "C-c c" "chat")
(global-set-key "C-c n" "chat-new")
(global-set-key "C-c r" "chat-send-region")
(global-set-key "C-c q" "llm-ask")
(global-set-key "C-c w" "chat-companion")




;; Cmd-p is intent search; M-x remains literal command-name completion.
(global-set-key "s-p" "command-palette")
;; winner: any layout change is one keystroke from undone
(global-set-key "C-c <left>" "winner-previous")
(global-set-key "C-c <right>" "winner-next")
;; the modeline, expanded — also a click on the modeline's name
(global-set-key "C-x ?" "modeline-expand")
(global-set-key "C-c RET" "chat-companion-ask")

;;; --- minibuffer history (vertico-style: last-used first) --------------------
;;; The candidate ranking in the core is a stable sort, so passing
;;; candidates history-first keeps them first among equal matches — the
;;; empty prompt shows pure recency, typing re-ranks fuzzily within it.

(defvar '*minibuffer-history* '())  ; ((key (item ...)) ...), most recent first
(define *minibuffer-history-max* 50)

;; savehist: which commands, themes and searches you use is worth more
;; than one session. Every keyed history rides in this one variable, so
;; M-x, apropos, project, ripgrep and the theme prompt all persist here.
(persist-global! 'minibuffer-history
  (lambda () *minibuffer-history*)
  (lambda (v) (set! *minibuffer-history* v)))

(define (history-items key)
  (let ((e (assoc key *minibuffer-history*)))
    (if e (cadr e) '())))

(define (take-n lst n)
  (if (or (null? lst) (= n 0))
      '()
      (cons (car lst) (take-n (cdr lst) (- n 1)))))

(define (history-push! key item)
  (let ((items (cons item (filter (lambda (x) (not (equal? x item)))
                                  (history-items key)))))
    (set! *minibuffer-history*
      (cons (list key (take-n items *minibuffer-history-max*))
            (filter (lambda (e) (not (equal? (car e) key)))
                    *minibuffer-history*)))))

;; reorder candidates so remembered ones lead, in recency order
(define (history-order key candidates)
  (let ((hist (filter (lambda (h) (member h candidates)) (history-items key))))
    (append hist (filter (lambda (c) (not (member c hist))) candidates))))

;;; --- M-x and eval ----------------------------------------------------------

;; what a command name means in a prompt: how to reach it, and what it
;; does. Two fields, so the docs line up under each other whether or not
;; the command above them has a binding.
(define (command-annotation c)
  (list (key-for-command c) (command-doc c)))

(marginalia! 'command command-annotation)

(define-command "execute-extended-command"
  "Run a command by name, with its keybinding and doc alongside"
  (lambda ()
    ;; M-x itself finishes before its minibuffer callback runs. Preserve the
    ;; raw prefix across that boundary, then consume it after the selected
    ;; command has had the same view it would get from a direct keybinding.
    (let ((prefix (current-prefix-arg)))
      (minibuffer-read "M-x "
        (annotate 'command (history-order 'M-x (command-names)))
        (lambda (cmd)
          (history-push! 'M-x cmd)
          (when prefix (set-prefix-arg! prefix))
          (run-command cmd)
          (when prefix (set-prefix-arg! #f)))))))

;;; Cmd-p answers "how do I do this?" while M-x answers "what is the
;;; command called?". Apropos supplies task-language matches from command
;;; docs and recipes; the palette projects that broad catalog down to things
;;; a reader can act on here.
(define (command-palette--candidate hit)
  (let ((kind (plist-get hit 'kind))
        (name (or (plist-get hit 'name) (plist-get hit 'task))))
    (cond
      ((equal? kind "command")
       (list name
             (string-append "command  "
                            (let ((key (plist-get hit 'key))) (if key key ""))
                            "  " (or (plist-get hit 'doc) ""))))
      ((equal? kind "recipe")
       (let ((inputs (or (plist-get hit 'inputs) '())))
         (list name
               (if (null? inputs)
                   "recipe  runs immediately"
                   (string-append "recipe  asks for "
                                  (number->string (length inputs))
                                  (if (= (length inputs) 1) " input" " inputs"))))))
      (else #f))))

;; A command the palette can draw: name, key and doc, in apropos hit shape.
(define (command-palette--command-hit name)
  (list 'kind "command" 'name name 'doc (command-doc name)
        'key (let ((k (key-for-command name))) (if (equal? k "") #f k))))

;; The palette draws commands and recipes, so it searches those two alone.
;; The whole catalog costs an index rebuild after every package load, and
;; the semantic pass costs a network call. The palette searches again on
;; every keystroke burst and can pay neither.
(define (command-palette--search query)
  (let ((words (apropos-query-words query)))
    (append
      (if (boundp (quote recipe-search)) (recipe-search query) '())
      (map command-palette--command-hit
           (filter (lambda (name)
                     (apropos-text-hit?
                       (string-append name " " (command-doc name)) words))
                   (command-names))))))

(define (command-palette-candidates query)
  (if (equal? (string-trim query) "")
      ;; The resting palette is familiar and cheap: the same MRU command
      ;; table as M-x. The search takes over as soon as the user states intent.
      (annotate 'command (history-order 'M-x (command-names)))
      (filter (lambda (candidate) candidate)
              (map command-palette--candidate (command-palette--search query)))))

(define *command-palette-debounce-ms* 80)

(define (command-palette--refresh input)
  ;; A timer can outlive the prompt that scheduled it. Never put Cmd-p's
  ;; results into a later prompt, and never let an old query replace a newer
  ;; one after the user has kept typing.
  (let ((state (minibuffer-state)))
    (when (and state
               (equal? (plist-get state 'prompt) "Command: ")
               (equal? (plist-get state 'input) input))
      (minibuffer-set-candidates! (command-palette-candidates input)))))

(define (command-palette--render-recipe expr bindings)
  ;; Every input becomes a printed Scheme string, not source. Quotes,
  ;; backslashes and newlines are escaped by value->string before the token is
  ;; replaced, so a path or prompt value cannot turn into executable code.
  (if (null? bindings)
      expr
      (let* ((binding (car bindings))
             (token (string-append "{{" (symbol->string (car binding)) "}}"))
             (rendered (string-join (string-split expr token)
                                    (value->string (cadr binding)))))
        (command-palette--render-recipe rendered (cdr bindings)))))

(define (command-palette--eval-recipe recipe bindings)
  (let ((result
          (eval-string-safe
            (command-palette--render-recipe (cadr recipe) bindings))))
    (if (equal? (car result) 'ok)
        (message (value->string (cadr result)))
        (message (string-append "Recipe error: " (cadr result))))))

(define (command-palette--collect-recipe recipe inputs bindings)
  (if (null? inputs)
      (command-palette--eval-recipe recipe bindings)
      (let ((input (car inputs)))
        (minibuffer-read (cadr input) '()
          (lambda (value)
            (command-palette--collect-recipe
              recipe (cdr inputs) (append bindings (list (list (car input) value)))))))))

(define (command-palette--run-recipe recipe)
  (command-palette--collect-recipe recipe (caddr recipe) '()))

(define (command-palette--run choice)
  (cond
    ((command-fn choice)
     (history-push! 'M-x choice)
     (run-command choice))
    ((and (boundp (quote *recipes*)) (assoc choice *recipes*))
     (command-palette--run-recipe (assoc choice *recipes*)))
    (else (message (string-append "No command or recipe named " choice)))))

(domain! 'interaction)
(effects! '(write execute))

(define-command "command-palette"
  "Find an action by intent across command docs and recipes"
  (lambda ()
    (minibuffer-read* "Command: " (command-palette-candidates "")
      (list (list 'confirm command-palette--run)
            (list 'change
              (lambda (input)
                (debounce!
                  (string-append "command-palette:" (selected-frame))
                  *command-palette-debounce-ms*
                  command-palette--refresh
                  input)))
            ;; Apropos already matched and ranked these results. In
            ;; particular, a doc match need not contain INPUT in its label.
            (list 'filter #f)
            (list 'style "palette")))))

(domain! 'unknown)
(effects! '(unknown))

(define-command "eval-expression" "Evaluate a Scheme expression from the minibuffer"
  (lambda ()
    (minibuffer-read "Eval: " '()
      (lambda (src) (message (value->string (eval-string src)))))))

;;; --- live eval: the editor is its own REPL -----------------------------------

(define (echo-value v) (message (string-append "=> " (value->string v))))

(define (char-before i)
  (if (> i 0) (buffer-substring (- i 1) i) #f))

(define (eval-skip-ws-back i)
  (if (member (char-before i) '(" " "\n" "\t"))
      (eval-skip-ws-back (- i 1))
      i))

;; matching opener for the closer just before i (naive about escaped quotes)
(define (sexp-open-before i depth in-str)
  (if (= i 0) 0
      (let ((c (char-before i)))
        (cond
          (in-str (sexp-open-before (- i 1) depth (not (equal? c "\""))))
          ((equal? c "\"") (sexp-open-before (- i 1) depth #t))
          ((equal? c ")") (sexp-open-before (- i 1) (+ depth 1) #f))
          ((equal? c "(") (if (= depth 1) (- i 1)
                              (sexp-open-before (- i 1) (- depth 1) #f)))
          (else (sexp-open-before (- i 1) depth #f))))))

(define (atom-start i)
  (if (or (= i 0) (member (char-before i) '(" " "\n" "\t" "(" ")")))
      i
      (atom-start (- i 1))))

(define (last-sexp-start p)
  (if (equal? (char-before p) ")")
      (sexp-open-before p 0 #f)
      (atom-start p)))

(define-command "eval-last-sexp" "Evaluate sexp before point and echo the value"
  (lambda ()
    (let* ((p (eval-skip-ws-back (point)))
           (s (last-sexp-start p)))
      (if (< s p)
          (echo-value (eval-region (current-buffer) s p))
          (message "No sexp before point")))))

(define-command "eval-buffer" "Evaluate the current buffer as Scheme"
  (lambda () (echo-value (eval-buffer (current-buffer)))))
(catalog-meta! 'command "eval-buffer" 'domain 'commands 'effects '(write execute))

(define-command "eval-region" "Evaluate the region as Scheme"
  (lambda ()
    (if (mark)
        (echo-value (eval-region (current-buffer) (region-beginning) (region-end)))
        (message "No region — set the mark first (C-SPC)"))))

;; hot-reload a Scheme file into the live session (stdlib included)
(define-command "load-file" "Load a Scheme file into the live session"
  (lambda ()
    (read-file-name "Load file: "
      (lambda (path)
        (load path)
        (message (string-append "Loaded " path))))))

(domain! 'interaction)
(effects! '(write))

(define (prefix-numeric-value raw)
  (cond ((number? raw) raw)
        ((and (pair? raw) (number? (car raw))) (car raw))
        ((equal? raw '-) -1)
        (else 1)))

(define-command "universal-argument" "Start or multiply the next command's prefix argument"
  (lambda ()
    (run-hooks 'universal-argument-hook)
    (let ((raw (current-prefix-arg)))
      (set-prefix-arg!
        (cond ((number? raw) (list (* raw 4)))
              ((and (pair? raw) (number? (car raw))) (list (* (car raw) 4)))
              ((equal? raw '-) (list -4))
              (else (list 4)))))))

(define-command "digit-argument" "Add a digit to the next command's prefix argument"
  (lambda ()
    (run-hooks 'universal-argument-hook)
    (let* ((raw (current-prefix-arg))
           (key (car (reverse (last-keys))))
           ;; "1" after C-u, or "M-1" on its own: the digit is the last character
           (digit (string->number (substring key (- (string-length key) 1) (string-length key))))
           (negative? (or (equal? raw '-) (and (number? raw) (< raw 0))))
           (base (if (number? raw) (abs raw) 0))
           (value (+ (* base 10) digit)))
      (set-prefix-arg! (if negative? (- value) value)))))

(define-command "negative-argument" "Negate the next command's prefix argument"
  (lambda ()
    (run-hooks 'universal-argument-hook)
    (let ((raw (current-prefix-arg)))
      (set-prefix-arg!
        (cond ((number? raw) (- raw))
              ((equal? raw '-) 1)
              (else '-))))))

(undo-exempt! "universal-argument")
(undo-exempt! "digit-argument")
(undo-exempt! "negative-argument")

;; Emacs's universal-argument-map: while a prefix argument is pending, the
;; digits, - and C-u come from this map, the frame's overriding map until
;; the next command. Every prefix command arms it.
(define-keymap! "universal-argument-map")
(for-each (lambda (d) (define-key "universal-argument-map" d "digit-argument"))
          '("0" "1" "2" "3" "4" "5" "6" "7" "8" "9"))
(define-key "universal-argument-map" "-" "negative-argument")
(define-key "universal-argument-map" "C-u" "universal-argument")

(define (universal-argument--arm!)
  (overriding-map! "universal-argument-map" #f #t))

(add-hook! 'universal-argument-hook 'universal-argument--arm!)

;; M-1 .. M-9, M-0 and M-- are the digit arguments, as in Emacs
(for-each (lambda (d) (global-set-key (string-append "M-" d) "digit-argument"))
          '("0" "1" "2" "3" "4" "5" "6" "7" "8" "9"))
(global-set-key "M--" "negative-argument")

;;; --- the prefix keymaps -------------------------------------------------------
;;; A prefix key leads to a keymap, as C-x leads to ctl-x-map in Emacs: the
;;; binding's value is (keymap NAME), and the rest of the sequence resolves
;;; in that keymap. A package binds into the map its keys belong to and
;;; never writes the global map; the global map belongs to the user's
;;; init. The names are Emacs's where Emacs has them.

(define (define-prefix-command name)
  (define-keymap! name)
  name)

;; (bind-prefix! MAP KEYS NAME): in MAP, KEYS leads to the keymap NAME
(define (bind-prefix! map keys name)
  (define-prefix-command name)
  (if (equal? map "global")
      (global-set-key keys (list 'keymap name))
      (define-key map keys (list 'keymap name))))

(bind-prefix! "global" "C-x" "ctl-x-map")
(bind-prefix! "global" "C-c" "mode-specific-map")
(bind-prefix! "global" "C-h" "help-map")
(bind-prefix! "global" "M-g" "goto-map")
(bind-prefix! "global" "M-s" "search-map")
(bind-prefix! "ctl-x-map" "r" "ctl-x-r-map")
(bind-prefix! "ctl-x-map" "4" "ctl-x-4-map")
(bind-prefix! "ctl-x-map" "p" "project-prefix-map")
(bind-prefix! "ctl-x-map" "v" "vc-prefix-map")
(bind-prefix! "ctl-x-map" "g" "group-map")
(bind-prefix! "ctl-x-map" "C-g" "buffer-group-map")
(bind-prefix! "mode-specific-map" "a" "agent-map")
(bind-prefix! "mode-specific-map" "S" "spotify-map")
(bind-prefix! "mode-specific-map" "!" "annotate-map")

;;; --- self-insert-command --------------------------------------------------------
;;; Every printable key and SPC are bound to self-insert-command in the
;;; global map, as in Emacs, so a key that inserts itself reaches that
;;; command through a keymap like any other, and a mode can rebind a
;;; letter. The dispatcher inserts the key itself, with the count and
;;; the region rule; the command body below serves M-x and command-call.

(define self-insert--printables
  (string-append
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"))

(define (self-insert--keys)
  (let loop ((i 0) (acc (list "SPC")))
    (if (>= i (string-length self-insert--printables))
        (reverse acc)
        (loop (+ i 1) (cons (substring self-insert--printables i (+ i 1)) acc)))))

(define-command "self-insert-command" "Insert the character you typed" (interactive 'p)
  (lambda (n)
    (let* ((ks (last-keys))
           (k (if (pair? ks) (car (reverse ks)) ""))
           (ch (cond ((equal? k "SPC") " ")
                     ((= (string-length k) 1) k)
                     (else ""))))
      (repeat-count n (lambda () (insert! ch))))))

(for-each (lambda (k) (global-set-key k "self-insert-command")) (self-insert--keys))
;; and into the completion popup: typing narrows it in place
(for-each (lambda (k) (local-set-key* " *completion*" k "self-insert-command")) (self-insert--keys))

(public! 'interactive "(interactive CODE ...) — a command's argument spec: 'p numeric prefix, 'P raw prefix, 'r region start and end, 'b buffer, 'd point, 'm mark, \"sPrompt: \" a string, \"nPrompt: \" a number, \"fPrompt: \" a file")
(public! 'command-call "(command-call NAME ARG ...) — run a command's function with explicit arguments")
(public! 'command-function "(command-function NAME) — the function behind a command, or #f")
(public! 'call-interactively "(call-interactively NAME) — run NAME as a key would, collecting its arguments from the spec")
(public! 'kill-text! "(kill-text! TEXT [BEFORE?]) — TEXT onto the kill ring: appended to the newest entry after a kill command, else as a new entry")
(public! 'kill-new "(kill-new TEXT) — a new kill-ring entry")
(public! 'current-kill "(current-kill N) — kill-ring entry N, 0 the newest")
(public! 'prefix-numeric-value
  "(prefix-numeric-value RAW) -> RAW as an integer; #f becomes 1")

(domain! 'unknown)
(effects! '(unknown))

(define-command "keyboard-quit" "Quit the current operation; close the active popup or clear the mark"
  (lambda ()
    (editing-quit!)
    (set-mark! #f)
    (if (and (popup-open?) (equal? (active-window) (popup-window)))
        (popup-close!)
        (message "Quit"))))
(catalog-meta! 'command "keyboard-quit" 'domain 'interaction 'effects '(write))

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

;; Swap this window's buffer with the directional neighbor's and follow it
;; (window-left/right/up/down — the window family)
(define (window-swap! dir)
  (let ((nb (window-in-direction dir)))
    (if nb
        (let ((mine (current-buffer)))
          (switch-to-buffer-here! (cadr nb))
          (select-window! (car nb))
          (switch-to-buffer-here! mine)
          (chat-snap-to-input!))
        (message (string-append "No window " (symbol->string dir))))))

(define-command "window-left" "Swap this window's buffer leftward and follow it"
  (lambda () (window-swap! 'left)))
(define-command "window-right" "Swap this window's buffer rightward and follow it"
  (lambda () (window-swap! 'right)))
(define-command "window-up" "Swap this window's buffer upward and follow it"
  (lambda () (window-swap! 'up)))
(define-command "window-down" "Swap this window's buffer downward and follow it"
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

;;; --- the movement state and the editing state ------------------------------
;;; An editable buffer has two states, and neither is a mode. The user lands
;;; on a window in the movement state: the Cmd-arrows move the focus. The first
;;; command that is not keyboard-quit enters the editing state: the state's
;;; maps are in force, ahead of the buffer's maps, and the Cmd-arrows on
;;; editing-caret-map move point to the line and buffer ends. A mode may
;;; refuse a map of the state (editing-state-maps-off!): chat-mode refuses
;;; the caret map, so a chat answers the Cmd-arrows with the window motion
;;; whether it is armed or not. keyboard-quit (ESC,
;;; C-g) returns the buffer to the movement state. A change of the active
;;; window or of its buffer is a new landing. A read-only buffer stays in the
;;; movement state. The client keeps the same state for a contenteditable
;;; surface (layouts.ex editingAfterKey), where the Cmd-arrows are native in
;;; the editing state and never reach this map.
(define-keymap! "editing-state-map")

;; The Cmd-arrows the editing state hands to the caret sit on a map of
;; their own, so a mode can refuse that map and keep the chords for window
;; motion. A chat is such a mode: you type in it without pause, so it would
;; hold the Cmd-arrows for good. The unset drops the bindings a reload left
;; on editing-state-map, which is now the state's marker and nothing else.
(for-each (lambda (k) (keymap-unset! "editing-state-map" k))
          '("s-<left>" "s-<right>" "s-<up>" "s-<down>"))
(define-keymap! "editing-caret-map")
(define-key "editing-caret-map" "s-<left>" "beginning-of-line")
(define-key "editing-caret-map" "s-<right>" "end-of-line")
(define-key "editing-caret-map" "s-<up>" "beginning-of-buffer")
(define-key "editing-caret-map" "s-<down>" "end-of-buffer")

(define *editing-landing* #f)   ; (frame window buffer) of the last landing

(define (editing-state? buf)
  (if (member "editing-state-map" (buffer-minor-maps buf)) #t #f))

;; The maps the editing state puts in force in the buffer. editing-state-map
;; is the state's marker; editing-caret-map holds the Cmd-arrows; cua.scm
;; adds cua-mode-map, so the Shift selections answer in a buffer you are
;; editing and a buffer you have just landed on keeps the plain meaning of
;; those chords. The ladder reads a minor map's own bindings and not its
;; parents, so a map that must answer here is on this list and not a parent
;; of another.
(define *editing-state-maps* '("editing-state-map" "editing-caret-map"))

(define (editing-state-maps! names)
  (for-each (lambda (n)
              (unless (member n *editing-state-maps*)
                (set! *editing-state-maps* (append *editing-state-maps* (list n)))))
            names))

(define (editing-state-maps-drop! names)
  (set! *editing-state-maps*
    (remove (lambda (m) (member m names)) *editing-state-maps*)))

;; A mode can refuse one of those maps, by name, for its buffers. The
;; marker map is not refusable: it is what says the buffer is in the state.
(define *editing-state-maps-off* '())   ; ((MODE (MAP ...)) ...)

(define (editing-state-maps-off! mode names)
  (set! *editing-state-maps-off*
    (cons (list mode (remove (lambda (m) (equal? m "editing-state-map")) names))
          (remove (lambda (e) (equal? (car e) mode)) *editing-state-maps-off*))))

(define (editing--maps-for buf)
  (let ((off '()))
    (for-each (lambda (e)
                (when (buffer-derived-mode? buf (car e))
                  (set! off (append off (cadr e)))))
              *editing-state-maps-off*)
    (if (null? off)
        *editing-state-maps*
        (remove (lambda (m) (member m off)) *editing-state-maps*))))

;; A chat keeps the Cmd-arrows on the window motion, armed or not: it is a
;; conversation you type in without pause, and a buffer that never returns
;; to the movement state would never answer the focus chords again.
(editing-state-maps-off! "chat-mode" '("editing-caret-map"))

(define (editing-state-on! buf)
  (unless (editing-state? buf)
    (buffer-minor-maps! buf (append (editing--maps-for buf) (buffer-minor-maps buf))))
  (unless (equal? (buffer-local buf 'editing-state) #t)
    (buffer-set-local! buf 'editing-state #t)
    (desktop-skip! buf 'editing-state)))

(define (editing-state-off! buf)
  (when (editing-state? buf)
    (buffer-minor-maps! buf
      (remove (lambda (m) (member m *editing-state-maps*)) (buffer-minor-maps buf))))
  (when (buffer-local buf 'editing-state)
    (buffer-set-local! buf 'editing-state #f)))

(define (editing--landing)
  (let ((w (active-window)))
    (and w (list (selected-frame) w (window-buffer w)))))

;; a new landing starts in the movement state
(define (editing--check-landing!)
  (let ((here (editing--landing)))
    (unless (equal? here *editing-landing*)
      (set! *editing-landing* here)
      (let ((buf (and here (caddr here))))
        (when (and buf (buffer-exists? buf))
          (editing-state-off! buf))))))

;; after a command: CMD is the command that ran. A named command is still
;; this-command when post-command-hook runs; a self-insert has finished
;; and is last-command.
(define (editing--command-name)
  (let ((this (this-command)))
    (if (and (string? this) (not (equal? this "")))
        this
        (last-command))))

;; A quit returns the buffer to the movement state. keyboard-quit is one.
;; A command that runs keyboard-quit inside itself (chat-abort when no
;; reply runs) is one too: keyboard-quit sets this flag, and the hook
;; reads it after the outer command, whatever that command is named.
(define *editing-quit* #f)
(define (editing-quit!) (set! *editing-quit* #t))

;; A window command (split, delete, layout, an arrow move) changes what you
;; look at, not the text. It is a landing: the buffer returns to the
;; movement state, and the next Cmd-arrow moves the focus. The catalog's
;; domain says which commands those are. One lookup walks the whole
;; catalog (4ms), so the answer is kept per command name until the
;; catalog changes.
(define *editing--domain-cache* '())
(define *editing--domain-gen* -1)

;; The directional commands are window commands by name, so a
;; redefinition that loses their catalog domain still counts as a landing.
(define *direction-command-names*
  '("focus-left" "focus-right" "focus-up" "focus-down"
    "window-left" "window-right" "window-up" "window-down"
    "buffer-left" "buffer-right" "buffer-up" "buffer-down"))

(define (editing--window-command? cmd)
  (and (string? cmd)
       (or (and (member cmd *direction-command-names*) #t)
           (begin
             (unless (equal? *editing--domain-gen* (catalog-generation))
               (set! *editing--domain-cache* '())
               (set! *editing--domain-gen* (catalog-generation)))
             (let ((hit (assoc cmd *editing--domain-cache*)))
               (if hit
                   (cadr hit)
                   (let* ((e (catalog-entry 'command cmd))
                          (yes (if (and e (equal? (catalog--get e 'domain) "windows")) #t #f)))
                     (set! *editing--domain-cache* (cons (list cmd yes) *editing--domain-cache*))
                     yes)))))))

;; A Shift chord is the selection keys' own chord. Pressing one says
;; nothing about whether you are editing this buffer, so it leaves the
;; state as it found it: cua.scm and groups.scm name the commands those
;; chords run, and every other key still arms the editing state.
(define *editing-neutral-commands* '())

(define (editing-neutral-commands! names)
  (for-each (lambda (n)
              (unless (member n *editing-neutral-commands*)
                (set! *editing-neutral-commands* (cons n *editing-neutral-commands*))))
            names))

(define (editing-neutral-command? cmd)
  (if (and (string? cmd) (member cmd *editing-neutral-commands*)) #t #f))

(define (editing--after-command! &optional cmd)
  (let ((buf (current-buffer))
        (cmd (or cmd (editing--command-name)))
        (quit *editing-quit*))
    (set! *editing-quit* #f)
    (cond ((not (and buf (buffer-exists? buf))) #t)
          ((buffer-read-only? buf) (editing-state-off! buf))
          ((or quit (equal? cmd "keyboard-quit")) (editing-state-off! buf))
          ((editing-neutral-command? cmd) #t)
          ((equal? cmd "self-insert-command") (editing-state-on! buf))
          ((editing--window-command? cmd) (editing-state-off! buf))
          (else (editing-state-on! buf)))))

(add-hook! 'window-configuration-change-hook 'editing--check-landing!)
(add-hook! 'pre-command-hook 'editing--check-landing!)
(add-hook! 'post-command-hook 'editing--after-command!)

(catalog-meta! 'function "editing-state?" 'domain 'windows 'effects '(read))
(catalog-meta! 'function "editing-state-on!" 'domain 'windows 'effects '(write))
(catalog-meta! 'function "editing-state-off!" 'domain 'windows 'effects '(write))
(catalog-meta! 'function "editing-quit!" 'domain 'windows 'effects '(write))
(catalog-meta! 'function "editing-state-maps!" 'domain 'windows 'effects '(write))
(catalog-meta! 'function "editing-state-maps-drop!" 'domain 'windows 'effects '(write))
(catalog-meta! 'function "editing-state-maps-off!" 'domain 'windows 'effects '(write))
(catalog-meta! 'function "editing-neutral-commands!" 'domain 'windows 'effects '(write))
(catalog-meta! 'function "editing-neutral-command?" 'domain 'windows 'effects '(read))

;; S-<left>/<right>: walk buffer history — S-<left> goes to the buffer you
;; just left (MRU), pressing again goes deeper; S-<right> walks back. The
;; list freezes for the duration of a run (yank-pop's last-command trick),
;; else each switch would reorder MRU and the walk would toggle forever.
(define *buffer-cycle-ring* '())
(define *buffer-cycle-pos* 0)

(define (buffer-cycle! dir)
  (unless (member (last-command) '("next-buffer" "previous-buffer"))
    (set! *buffer-cycle-ring*
      (cons (current-buffer)
            (filter (lambda (b)
                      (and (not (string-prefix? " " b))
                           (not (buffer-context-only? b))
                           ;; in a group, the ring cycles the group
                           (not (display-foreign? b))
                           (not (equal? b (current-buffer)))))
                    (buffer-list-mru))))
    (set! *buffer-cycle-pos* 0))
  (let ((n (length *buffer-cycle-ring*)))
    (if (< n 2)
        (message "No other buffer")
        (begin
          (set! *buffer-cycle-pos* (modulo (+ *buffer-cycle-pos* dir) n))
          (switch-to-buffer! (list-ref *buffer-cycle-ring* *buffer-cycle-pos*))))))

(define-command "previous-buffer" "Switch to the previously used buffer (again = deeper)"
  (lambda () (buffer-cycle! 1)))
(define-command "next-buffer" "Walk back toward the most recently used buffer"
  (lambda () (buffer-cycle! -1)))
(catalog-meta! 'command "previous-buffer" 'domain 'buffers 'effects '(write display))
(catalog-meta! 'command "next-buffer" 'domain 'buffers 'effects '(write display))

(define-command "buffer-select" "Toggle selection on the active buffer"
  (lambda ()
    (let* ((buf (current-buffer))
           (selected (not (buffer-local buf 'buffer-selected))))
      (buffer-set-local! buf 'buffer-selected selected)
      (message (string-append buf (if selected " selected" " deselected"))))))

(define-command "buffer-unselect" "Clear selection on the active buffer"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-local! buf 'buffer-selected #f)
      (message (string-append buf " unselected")))))

(define-command "buffer-unselect-all" "Clear selection on every buffer"
  (lambda ()
    (let ((cleared 0))
      (for-each
        (lambda (buf)
          (when (buffer-local buf 'buffer-selected)
            (buffer-set-local! buf 'buffer-selected #f)
            (set! cleared (+ cleared 1))))
        (buffer-list))
      (message (string-append "Unselected " (number->string cleared)
                             " buffer" (if (= cleared 1) "" "s"))))))

;; the UI reports clicks; which window gets focus and what that means
;; (chat focuses its input) is policy
(define (mouse-select-window! id)
  (select-window! id)
  (chat-snap-to-input!))

;;; --- Input intents ---------------------------------------------------------
;;; The browser's own text pipeline (input methods, dead keys, dictation,
;;; autocorrect, spellcheck, native selection) reports what the user meant
;;; through `beforeinput`. The client sends each intent as a type, a byte
;;; range, and text. A collapsed intent at point is a key, and KeyDispatch
;;; routes it as one. A ranged intent comes here: what the range means is
;;; policy.

(define *input-intent-handlers* '())

;; (on-input-intent! TYPE FN): FN takes (from to text) and returns #t when
;; it handled the intent. A mode registers "formatBold" here.
(define (on-input-intent! type fn)
  (set! *input-intent-handlers*
    (cons (list type fn)
          (remove (lambda (entry) (equal? (car entry) type))
                  *input-intent-handlers*))))

(define (input-intent--replace! from to text)
  (goto-char! from)
  (set-mark! to)
  (delete-region!)
  (set-mark! #f)
  (goto-char! from)
  (when (> (string-length text) 0) (insert! text))
  #t)

(define (input-intent! type from to text)
  (let ((handler (assoc type *input-intent-handlers*)))
    (cond
      ((and handler ((cadr handler) from to text)) #t)
      ((member type '("insertText" "insertReplacementText" "insertCompositionText"
                      "insertFromPaste" "insertFromDrop" "insertFromYank"
                      "insertTranspose"))
       (input-intent--replace! from to text))
      ((member type '("insertParagraph" "insertLineBreak"))
       (input-intent--replace! from to "\n"))
      ;; a collapsed delete acts at point through the command it stands for
      ((and (= from to) (equal? type "deleteWordBackward"))
       (run-command "backward-kill-word") #t)
      ((and (= from to) (equal? type "deleteWordForward"))
       (run-command "kill-word") #t)
      ((and (= from to) (member type '("deleteSoftLineForward" "deleteHardLineForward")))
       (run-command "kill-line") #t)
      ((and (= from to) (member type '("deleteSoftLineBackward" "deleteHardLineBackward")))
       (let ((bol (line-start-position (line-number-at-pos (point)))))
         (input-intent--replace! bol (point) "")))
      ((string-prefix? "delete" type)
       (input-intent--replace! from to ""))
      ((equal? type "historyUndo") (run-command "undo") #t)
      (else
        (message (string-append "Unhandled input intent: " type))
        #f))))

;; one gate for clicks that run a command (dup #24). A transcript button
;; sends a command name; the modeline-info segment sends its buffer. The
;; whitelist lives here: a button runs agent-* commands only, a modeline
;; click runs the buffer's own modeline-info-command.
(define (ui-command! cmd buf)
  (cond ((and (string? cmd) (string-prefix? "agent-" cmd))
         (run-command cmd))
        ;; the modeline's name is the dashboard's click target
        ((equal? cmd "modeline-expand") (run-command cmd))
        ((equal? cmd "dismiss-buffer") (run-command cmd))
        ;; a mode name in the modeline toggles that mode
        ((and (string? cmd) (string-prefix? "mode:" cmd))
         (modeline-toggle-mode! (string-join (cdr (string-split cmd ":")) ":")))
        ((string? buf)
         (let ((c (buffer-local buf 'modeline-info-command)))
           (when (string? c) (run-command c))))
        (else #f)))

;; System clipboard delivery stops here. Paste policy belongs to Scheme: a
;; major or minor mode can register a named handler, and user config loaded
;; after the stock packages therefore gets first refusal. A handler receives
;; KIND, DATA, and MIME and returns #t only when it consumed the paste.
;; Replacing a named entry in place is important: reloading a package updates
;; its closure without moving it ahead of later user registrations.
(unless (boundp '*paste-hooks*)
  (set-symbol-value! '*paste-hooks* '()))

(define (paste-mode-name mode)
  (if (symbol? mode) (symbol->string mode) mode))

(define (paste-hook-replace hooks mode name fn)
  (cond ((null? hooks) #f)
        ((and (equal? (car (car hooks)) mode)
              (equal? (cadr (car hooks)) name))
         (cons (list mode name fn) (cdr hooks)))
        (else
          (let ((rest (paste-hook-replace (cdr hooks) mode name fn)))
            (and rest (cons (car hooks) rest))))))

(define (add-paste-hook! mode name fn)
  (let* ((mode-name (paste-mode-name mode))
         (replaced (paste-hook-replace *paste-hooks* mode-name name fn)))
    (set! *paste-hooks*
      (if replaced replaced (cons (list mode-name name fn) *paste-hooks*))))
  name)

(define (remove-paste-hook! mode name)
  (let ((mode-name (paste-mode-name mode)))
    (set! *paste-hooks*
      (remove
        (lambda (entry)
          (and (equal? (car entry) mode-name)
               (equal? (cadr entry) name)))
        *paste-hooks*)))
  name)

(define (paste-mode-active? buf mode)
  ;; a derived major mode keeps the hooks of the mode it is built from
  (or (buffer-derived-mode? buf mode)
      (minor-mode-on? buf mode)))

(define (run-paste-hooks! kind data mime)
  (let ((buf (current-buffer)))
    (let loop ((hooks *paste-hooks*))
      (cond ((null? hooks) #f)
            ((and (paste-mode-active? buf (car (car hooks)))
                  ((car (cdr (cdr (car hooks)))) kind data mime))
             #t)
            (else (loop (cdr hooks)))))))

(define (clipboard-paste! text)
  (unless (run-paste-hooks! "text" text "text/plain")
    (kill-push! text)
    ;; System paste follows the ordinary editor rule: replace the active
    ;; region, then leave point active rather than continuing selection mode.
    (when (mark) (delete-region!))
    (insert! text)
    (set-mark! #f)
    ;; A prompt is an ordinary buffer, so the text went into it. Only the key
    ;; path tells the prompt what its buffer now says, and a paste arrives off
    ;; that path, so say it here and let the prompt's live filter run.
    (when (minibuffer-active?)
      (minibuffer-change! (buffer-text (minibuffer-buffer))))))

(define (clipboard-image-paste! data mime)
  (unless (run-paste-hooks! "image" data mime)
    (message "No paste hook handled this image")))

;; Cmd-C with no native selection (S12, dup #26): the region when one
;; exists — pushed to the kill ring, Emacs interprogram-cut — else the
;; newest kill
(define (clipboard-copy)
  (let* ((bounds (region-action-bounds))
         (text (buffer-substring (car bounds) (cadr bounds))))
    (if (equal? text "")
        (kill-top)
        (begin (kill-push! text) text))))

;;; --- buffer links ----------------------------------------------------------
;;; A link is one string that points at a buffer, and two readers follow it.
;;; A person opens BASE/b/NAME and this editor shows the buffer at the line.
;;; A terminal or an agent reads BASE/raw/NAME and gets the text. The name is
;;; one percent-encoded segment, so a file buffer keeps the slashes in its
;;; path. The line rides in the query string, because a fragment never
;;; reaches this daemon.

(domain! 'buffers)
(effects! '(read))

(define (buffer-link &optional buf line)
  (let ((name (or buf (current-buffer)))
        (n (or line (if buf #f (line-number-at-pos (point))))))
    (string-append (editor-url) "/b/" (url-encode name)
                   (if n (string-append "?line=" (number->string n)) ""))))

(define (compos-link &optional buf line)
  (let ((name (or buf (current-buffer)))
        (n (or line (if buf #f (line-number-at-pos (point))))))
    (string-append "compos://open?path=" (url-encode name)
                   "&socket=" (url-encode (compos-socket-path))
                   (if n (string-append "&line=" (number->string n)) ""))))

(define (buffer-raw-link &optional buf)
  (string-append (editor-url) "/raw/" (url-encode (or buf (current-buffer)))))

(effects! '(write))

(define-command "copy-buffer-link"
  "Copy an compos:// link to this buffer and line to the clipboard"
  (lambda ()
    (let ((link (compos-link)))
      ;; the kill ring too: a client with no clipboard permission still
      ;; pastes it with C-y
      (kill-push! link)
      (clipboard-put! link)
      (message link))))

;; What a link means when a browser opens it. An open buffer wins, because
;; the link names a buffer. A name that is also a file path opens that file
;; — a link outlives the buffer it came from.
(define (open-buffer-link! name line)
  (cond ((buffer-known? name) (switch-to-buffer! name))
        ((file-exists? name) (visit name))
        (else (message (string-append "Dead link: no buffer " name))))
  (when (and line (buffer-exists? name))
    (goto-char! (line-start-position line))
    (recenter!)))

(domain! 'unknown)
(effects! '(unknown))

;;; --- daemon control ----------------------------------------------------------

(domain! 'system)
(effects! '(destroy execute))

;; A restart saves the desktop first, so every buffer and window comes back.
;; Interactive use asks once. An agent tool uses the shared permission policy:
;; modes can grant this command with allow-command-when!.
(define (restart-daemon-now!)
  (if (daemon-restart!)
      (message "Restarting…")
      (message "Restart refused")))

(define-command "restart-daemon" "Save the desktop and restart the daemon"
  (lambda ()
    (let ((tool-buf (and (boundp (quote *llm-tool-buffer*)) *llm-tool-buffer*)))
      (if tool-buf
          (let ((verdict
                  (if (boundp (quote *permission-policy*))
                      (*permission-policy* tool-buf "restart-daemon" "command" "")
                      'ask)))
            (if (member verdict '(allow allow-always))
                (restart-daemon-now!)
                (error "restart-daemon requires user permission")))
          (y-or-n "Restart the daemon?" restart-daemon-now!)))))

(domain! 'unknown)
(effects! '(unknown))

;;; --- default keymap --------------------------------------------------------

(global-set-key "C-f" "forward-char")
(global-set-key "C-b" "backward-char")
(global-set-key "C-n" "next-line")
(global-set-key "C-p" "previous-line")
(global-set-key "C-a" "beginning-of-line")
(global-set-key "C-e" "end-of-line")
(global-set-key "M-<" "beginning-of-buffer")
(global-set-key "M->" "end-of-buffer")
(global-set-key "<left>" "backward-char")
(global-set-key "<right>" "forward-char")
(global-set-key "<up>" "previous-line")
(global-set-key "<down>" "next-line")
(global-set-key "<home>" "beginning-of-line")
(global-set-key "<end>" "end-of-line")
;; word motion on the arrow chords, the Emacs default; a mode map may
;; take C-<right>/C-<left> for itself (paredit slurps with them)
(global-set-key "C-<right>" "forward-word")
(global-set-key "C-<left>" "backward-word")
(global-set-key "M-<right>" "forward-word")
(global-set-key "M-<left>" "backward-word")

(global-set-key "RET" "newline-or-send")
(global-set-key "DEL" "delete-backward-char")
(global-set-key "<delete>" "delete-char")
(global-set-key "C-d" "delete-char")
(global-set-key "C-k" "kill-line")
(global-set-key "C-y" "yank")
(global-set-key "C-/" "undo")
(global-set-key "C-_" "undo")
(global-set-key "C-x u" "undo")
(global-set-key "C-g" "keyboard-quit")
(global-set-key "C-u" "universal-argument")
;; ESC quits, like C-g. Emacs makes a lone ESC the Meta prefix; here it
;; echoed "ESC-" and waited, and the user presses ESC to leave the editing
;; state of a buffer (layouts.ex editingAfterKey). Meta is the Option key.
;; Dispatch still translates an unbound ESC k to M-k in a map that leaves
;; ESC unbound.
(global-set-key "ESC" "keyboard-quit")

(global-set-key "M-f" "forward-word")
(global-set-key "M-b" "backward-word")
(global-set-key "M-d" "kill-word")
(global-set-key "M-DEL" "backward-kill-word")
(global-set-key "C-t" "transpose-chars")
(global-set-key "M-y" "yank-pop")
(global-set-key "TAB" "indent-for-tab")
(global-set-key "M-g g" "goto-line")
(global-set-key "M-g M-g" "goto-line")
(global-set-key "M-m" "back-to-indentation")
(global-set-key "C-c l" "copy-buffer-link")
(global-set-key "C-c C-v" "preview-mode")
(global-set-key "C-c C-a" "app-preview")
(global-set-key "C-c C-r" "app-reload")
;; the backtick family reads as one hand: C-` walks this pane's own kind of
;; buffer (groups.scm), M-` shows and hides the popup, C-M-` turns the popup
;; into a real window.
(global-set-key "M-`" "popup-toggle")
(global-set-key "C-M-`" "popup-bufferize")
(global-set-key "C-M-v" "scroll-other-window")
;; the other window, without leaving this one — the reference page beside
;; the work is the case this exists for. org-mode keeps M-<up>/M-<down>
;; for its subtrees: a buffer-local key wins over a global one.
(global-set-key "M-<down>" "scroll-other-window")
(global-set-key "M-<up>" "scroll-other-window-down")
(global-set-key "C-v" "scroll-up-command")
(global-set-key "M-v" "scroll-down-command")
(global-set-key "<next>" "scroll-up-command")
(global-set-key "<prior>" "scroll-down-command")
(global-set-key "C-l" "recenter-top-bottom")
(global-set-key "C-M-i" "completion-at-point")
(global-set-key "M-/" "completion-at-point")
(global-set-key "C-M-f" "forward-sexp")
(global-set-key "C-M-b" "backward-sexp")
(global-set-key "C-M-u" "backward-up-list")
(global-set-key "C-M-d" "down-list")

(global-set-key "C-SPC" "set-mark-command")
;; macOS gives C-SPC to the input-source switch, so the mark has a second
;; key. Emacs' own M-SPC (cycle-spacing) is not bound here.
(global-set-key "M-SPC" "set-mark-command")
(global-set-key "C-w" "kill-region")
(global-set-key "M-w" "copy-region-as-kill")
(global-set-key "C-x C-x" "exchange-point-and-mark")
(global-set-key "C-x C-SPC" "pop-global-mark")
(global-set-key "C-s" "isearch-forward")
(global-set-key "C-r" "isearch-backward")
(global-set-key "M-%" "query-replace")

(global-set-key "C-x C-f" "find-file")
(global-set-key "C-x C-s" "save-buffer")
(global-set-key "C-x C-w" "write-file")
(global-set-key "C-x b" "switch-to-buffer-prompt")
(global-set-key "C-x k" "kill-buffer")
(global-set-key "C-x n n" "narrow-to-region")
(global-set-key "C-x n N" "narrow-context-also")
(global-set-key "C-x n w" "widen")

(global-set-key "M-x" "execute-extended-command")
(global-set-key "M-<" "beginning-of-buffer")
(global-set-key "M->" "end-of-buffer")
(global-set-key "M-:" "eval-expression")
(global-set-key "C-x C-e" "eval-last-sexp")

(global-set-key "C-x 2" "split-window-below")
(global-set-key "C-x 3" "split-window-right")
(global-set-key "C-x 0" "delete-window")
(global-set-key "C-x 1" "delete-other-windows")
(global-set-key "C-x e" "window-eat")
(global-set-key "C-x o" "other-window")
(global-set-key "C-x l" "window-layout")
(global-set-key "C-c p" "popup-buffer")
;; Cmd-arrows move the focus; Cmd-Shift-arrows swap the two panes
(focus-default-keybindings 'super)
(window-default-keybindings '(shift super))
(global-set-key "S-<left>" "previous-buffer")
(global-set-key "S-<right>" "next-buffer")
(global-set-key "C-x <left>" "previous-buffer")
(global-set-key "C-x <right>" "next-buffer")

;;; --- the public API ----------------------------------------------------------
;;; The supported, documented surface — what apropos shows the LLM (and
;;; anyone) by default. One line each; keep it curated, not exhaustive.
;;; Each section opens with (category! 'name): the category is how an agent
;;; asks for the shape of an area instead of guessing at a search.

(category! 'buffers)
;; The scope declares what each name costs. It was a guess in a generated
;; artifact before, and a guess must not reach the permission policy.
(domain! 'buffers)
(effects! '(read))
(public! 'buffer-list "All buffer names")
(public! 'buffer-list-mru "Buffer names, most recently used first")
(public! 'buffer-exists? "(buffer-exists? NAME) -> bool")
(public! 'buffer-known? "(buffer-known? NAME) -> bool: live OR dormant. A list shows dormant buffers, so a verb asks this one")
(catalog-meta! 'function "buffer-known?" 'domain 'buffers 'effects '(read))
(effects! '(write))
(public! 'buffer-sleep! "(buffer-sleep! NAME) — checkpoint NAME and stop its process; the buffer stays known. #f when NAME is on screen, busy, or pinned")
(catalog-meta! 'function "buffer-sleep!" 'domain 'buffers 'effects '(write))
(public! 'buffer-last-seen "(buffer-last-seen NAME) — unix seconds when NAME was last shown in the active window, or #f; reads without waking a dormant buffer")
(catalog-meta! 'function "buffer-last-seen" 'domain 'buffers 'effects '(read))
(public! 'buffer-created-at "(buffer-created-at NAME) — unix seconds when NAME was made, or #f")
(catalog-meta! 'function "buffer-created-at" 'domain 'buffers 'effects '(read))
(public! 'buffer-note-seen! "(buffer-note-seen! NAME) — stamp NAME as seen now, at most one write a minute")
(catalog-meta! 'function "buffer-note-seen!" 'domain 'buffers 'effects '(write))
(effects! '(read))
(public! 'buffer-text "(buffer-text NAME) -> the buffer's full text")
(public! 'buffer-size "(buffer-size NAME) -> size in bytes")
(effects! '(write))
(public! 'buffer-create "(buffer-create NAME) — create if missing")
(effects! '(destroy))
(public! 'buffer-kill! "(buffer-kill! NAME) — kill a buffer; repoint its windows first")
(public! 'kill-buffer-confirm! "(kill-buffer-confirm! NAME DONE) — confirm before discarding modified file text, then call DONE with #t when killed")
(catalog-meta! 'function "kill-buffer-confirm!" 'domain 'buffers 'effects '(destroy))
(effects! '(write))
(public! 'buffer-append! "(buffer-append! NAME TEXT) — append; the usual way to add text")
(public! 'buffer-insert! "(buffer-insert! NAME BYTE-POS TEXT)")
(public! 'buffer-delete-range! "(buffer-delete-range! NAME BYTE-POS BYTE-LEN)")
(effects! '(read))
(public! 'buffer-authors "(buffer-authors NAME) -> (START END AUTHOR) spans: who wrote each byte range")
(public! 'buffer-author-lines "(buffer-author-lines NAME) -> (LINE AUTHOR BYTES) rows: who wrote each line, and how much of it")
(public! 'buffer-edit-log "(buffer-edit-log NAME) -> (VERSION AUTHOR POS INS DEL) records, newest first")
(public! 'buffer-provenance-status "(buffer-provenance-status NAME) -> the durable recording state and accepted head")
(public! 'buffer-history "(buffer-history NAME) -> every change to the buffer, oldest first, with its actor")
(effects! '(write))
(public! 'buffer-provenance-start! "(buffer-provenance-start! NAME [ACTOR REASON POLICY]) -> start or resume recording")
(public! 'buffer-provenance-stop! "(buffer-provenance-stop! NAME [ACTOR REASON POLICY]) -> stop without deleting history")
(public! 'buffer-provenance-checkpoint! "(buffer-provenance-checkpoint! NAME) -> close the current changeset")
(public! 'with-edit-author "(with-edit-author AUTHOR THUNK) — attribute THUNK's buffer edits to AUTHOR")
(public! 'current-edit-author "(current-edit-author) — the caller process's edit author string, or #f")
(catalog-meta! 'function "current-edit-author" 'domain 'buffers 'effects '(read))
(effects! '(read))
(public! 'buffer-path "(buffer-path NAME) -> file path or #f")
(public! 'buffer-modified? "(buffer-modified? NAME) -> unsaved changes?")
(public! 'buffer-local "(buffer-local NAME KEY) -> buffer-local value or #f")
(effects! '(write))
(public! 'buffer-set-local! "(buffer-set-local! NAME KEY VALUE) — locals persist with the desktop")
(effects! '(read))
(public! 'current-buffer "Name of the buffer point is in")
(effects! '(write display))
(public! 'switch-to-buffer! "(switch-to-buffer! NAME) — show in the active window; a buffer outside the frame's group takes another window (category foreign)")
(public! 'switch-to-buffer-here! "(switch-to-buffer-here! NAME) — show in the active window whatever the group: the mechanism a layout, a swap, or a restore uses")
(public! 'display-foreign? "(display-foreign? NAME) — #t when a pane on NAME would take the frame out of its group; groups.scm answers")
(public! 'visit "(visit PATH [GROUP]) — open a file; GROUP joins it to that context; /ssh:HOST:/PATH opens over ssh")
(public! 'find-file-read "(find-file-read [GROUP]) — prompt for a file and join it to GROUP; no GROUP keeps it ungrouped")
(for-each
  (lambda (name) (catalog-meta! 'function name 'domain 'buffers 'effects '(write display)))
  '("switch-to-buffer!" "visit" "find-file-read"))
(domain! 'unknown)
(effects! '(read))
(public! 'buffer-link "(buffer-link [NAME] [LINE]) -> a URL that opens the buffer here; no NAME means this buffer at point")
(public! 'compos-link "(compos-link [NAME] [LINE]) -> an compos:// URL for the buffer and line; no NAME means this buffer at point")
(public! 'buffer-raw-link "(buffer-raw-link [NAME]) -> a URL that serves the buffer text as plain text")
(effects! '(write))
(public! 'open-buffer-link! "(open-buffer-link! NAME LINE) — show the buffer a link names; LINE may be #f")
(catalog-meta! 'function "open-buffer-link!" 'domain 'buffers 'effects '(write display))
(effects! '(unknown))
(public! 'tail-open "(tail-open PATH) — follow a file with tail -F, local or /ssh: remote")
(public! 'sh-quote "(sh-quote S) — S as one safe single-quoted word for a shell command")
(public! 'buffer-save! "(buffer-save! [PATH]) — save the current buffer to its path; with PATH, save there and adopt PATH")
(public! 'write-rules "(write-rules) — the rules that decide which writes happen, as (NAME REASON CONFIRMABLE? PRED) records")
(public! 'defwrite-rule! "(defwrite-rule! 'NAME REASON CONFIRMABLE? PRED) — add or replace a write rule; PRED reads (PATH SOURCE) and answers #t to refuse")
(public! 'write-refusal "(write-refusal PATH SOURCE PERMITTED?) — #f when the write is allowed, else the reason it is not")
(public! 'allow-one-write! "(allow-one-write! PATH) — let the next write to PATH set the confirmable rules aside; a person's answer buys this, and it is spent once")
(public! '*scheme-write-roots* "extra directories where a buffer may start a new .scm file")
(public! 'save-buffer-named! "(save-buffer-named! NAME) — save another buffer; the window goes back where it was")
(catalog-meta! 'function "save-buffer-named!" 'domain 'files 'effects '(write))
(catalog-meta! 'command "write-file" 'domain 'files 'effects '(write))

(category! 'editing)
(public! 'point "Point as a byte offset")
(public! 'buffer-point "(buffer-point NAME) — a named buffer's point as a byte offset")
(public! 'buffer-line-at-point
         "(buffer-line-at-point NAME) — (LINE TEXT) at the named buffer's point")
(catalog-meta! 'function "buffer-line-at-point" 'domain 'editing 'effects '(read))
(public! 'json-parse "(json-parse STR) — JSON to Scheme: objects become plists with symbol keys, null becomes #f; #f on bad input")
(public! 'register-context-provider! "(register-context-provider! MODE FN) — FN buf -> description of what the user is looking at, or #f; chat/agent sends prepend it")
(public! 'editor-context "(editor-context EXCLUDE-BUF) — visible-window contexts from registered providers, \"\" if none")
(public! 'goto-char! "(goto-char! BYTE-POS)")
(public! 'set-mb-redirect! "(set-mb-redirect! BOOL) — #f makes current-buffer ignore an active minibuffer, so a preview hook can act on the invoking buffer; restore to #t after")
(public! 'line-start-position "(line-start-position LINE) — 1-based line's start byte offset, O(log n)")
(public! 'insert! "(insert! TEXT) at point")
(public! 'delete-char! "(delete-char! N) — negative deletes backward")
(public! 'region-text "Text between mark and point (\"\" when no mark)")
(public! 'set-mark! "(set-mark! BYTE-POS or #f)")
(public! 'buffer-substring "(buffer-substring START END) of the current buffer")
(public! 'line-text "Text of the current line")
(public! 'symbol-at-point "(symbol-at-point) — the name around point, or #f")
(public! 'symbol-at-point-in "(symbol-at-point-in CHARS) — the name around point over the alphabet CHARS, or #f")
(public! 'end-of-buffer! "Move point to the end")
(public! 'beginning-of-buffer! "Move point to the start")
(for-each
  (lambda (name) (catalog-meta! 'function name 'domain 'editing 'effects '(write display)))
  '("goto-char!" "set-mb-redirect!" "insert!" "delete-char!" "set-mark!"
    "end-of-buffer!" "beginning-of-buffer!"))

(category! 'windows)
(domain! 'windows)
(effects! '(read))
(public! 'window-list "((id buffer-name) ...) for every window")
(public! 'frame-cols "(frame-cols) — usable text columns across the selected frame")
(public! 'window-showing "(window-showing NAME) — the window showing NAME, or #f")
(public! 'window-buffer "(window-buffer ID) — the buffer that window shows, or #f")
(public! 'other-window-id "(other-window-id ME) — any window that is not ME, or #f")
(public! 'active-window "Id of the selected window")
(effects! '(write display))
(public! 'select-window! "(select-window! ID)")
(public! 'split-window! "(split-window! 'h|'v [RATIO]) — ratio = first pane's share")
(public! 'delete-window-id! "(delete-window-id! ID)")
(public! 'delete-other-windows! "Make the active window the only one")
(public! 'other-window! "Select the next window")
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
(public! 'window-showing-mode
  "(window-showing-mode MODE [EXCEPT]) — the work window whose buffer is in MODE, or #f; a group keeps one window per mode")
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
(for-each
  (lambda (name) (catalog-meta! 'function name 'domain 'windows 'effects '(write display)))
  '("select-window!" "split-window!" "delete-window-id!"
    "delete-other-windows!" "other-window!" "display-buffer" "pop-to-buffer"
    "define-display-action!" "split-window-sensibly" "window-quit-restore!"
    "display-buffer-popup!" "display-buffer-other-window!" "apply-layout!"
    "tile-windows!" "tile-visible-windows!" "window-eat!"))
(effects! '(write))
(public! 'add-display-rule!
  "(add-display-rule! PATTERN ACTION [PARAMS]) — set display policy without showing a buffer. PATTERN is a name substring or (category KIND); ACTION is one action name or a list: pop-up-window, reuse-window, use-some-window, same-window")
(public! 'define-mode-layout!
  "(define-mode-layout! MODE '(h|v RATIO PANE ...)) — set a mode layout without applying it")
(public! 'define-mode-headline!
  "(define-mode-headline! MODE '(mode group llm wide)) — which headline segments MODE keeps in a narrow window")
(effects! '(read))
(public! 'buffer-layout "(buffer-layout NAME) — the layout NAME's modes declare, or #f")
(effects! '(write))
(public! 'with-layout-suppressed "(with-layout-suppressed THUNK) — run THUNK without the layout engine arranging the frame")

(domain! 'unknown)
(effects! '(unknown))
(category! 'interaction)
(public! 'message "(message TEXT [LEVEL]) — log TEXT and show it in the echo area")
(public! 'minibuffer-read "(minibuffer-read PROMPT CANDIDATES HANDLER) — async; HANDLER gets the choice")
(public! 'debounce! "(debounce! KEY MS CALLBACK ARG) — after MS idle, call CALLBACK with ARG; rescheduling KEY cancels the older callback")
(catalog-meta! 'function "debounce!" 'domain 'interaction 'effects '(write execute))
(public! 'y-or-n "(y-or-n PROMPT YES &optional NO) — a one-key question; y runs YES, n and C-g run NO")
(catalog-meta! 'function "y-or-n" 'domain 'interaction 'effects '(read))
(catalog-meta! 'command "reset-layout" 'domain 'windows 'effects '(write display))
(catalog-meta! 'function "define-mode-layout!" 'domain 'windows 'effects '(write))
(catalog-meta! 'function "define-mode-headline!" 'domain 'windows 'effects '(write))
(public! 'read-file-name "(read-file-name PROMPT K) — prompt with filename completion from default-directory; K gets the typed path")
(public! 'abbreviate-file-name "(abbreviate-file-name PATH) — PATH with the home directory written as ~")
(public! 'buffer-modeline-name "(buffer-modeline-name BUF) — BUF's name for the modeline: project-relative, or ~ for home")
;; the buffer-name grammar: *strong* ~dim~ `mono` :icon:, and \x for a literal x
(public! 'name-segments "(name-segments SPEC [ICONS]) — the ((CLASS TEXT) ...) spans SPEC draws: *strong* ~dim~ `mono` :icon:; ICONS is ((KEY GLYPH) ...) the caller adds")
(public! 'name-format-expand "(name-format-expand FORMAT VALS) — fill a name format's %-directives from ((KEY VALUE) ...)")
(public! 'name-text "(name-text SEGMENTS) — the rendered name as one plain string")
(public! 'name-icon! "(name-icon! KEY GLYPH) — register the icon :KEY: reaches in a name")
(public! 'buffer-name-segments "(buffer-name-segments BUF) — the spans that draw BUF's name, from the buffer-local name-format or buffer-name-format")
(catalog-meta! 'function "name-segments" 'domain 'interaction 'effects '(pure))
(catalog-meta! 'function "name-format-expand" 'domain 'interaction 'effects '(pure))
(catalog-meta! 'function "name-text" 'domain 'interaction 'effects '(pure))
(catalog-meta! 'function "name-icon!" 'domain 'interaction 'effects '(write))
(catalog-meta! 'function "buffer-name-segments" 'domain 'interaction 'effects '(read))
(public! 'minibuffer-read-preview "(minibuffer-read-preview PROMPT CANDIDATES ON-SELECT ON-CONFIRM ON-CANCEL &optional MATCH-HINT STYLE COMPLETE COLLECT) — preview candidates and optionally route collected rows")
(public! 'minibuffer-buffer? "(minibuffer-buffer? BUF) — whether BUF is a prompt's input buffer, i.e. in minibuffer-mode")
(public! 'minibuffer-mode-ensure! "(minibuffer-mode-ensure! &optional BUF) — put minibuffer-mode on this frame's prompt buffer; answers the buffer")
(public! 'window-preview-buffer! "(window-preview-buffer! NAME) — show NAME in the active window without touching the MRU ring")
(catalog-meta! 'function "window-preview-buffer!"
  'domain 'interaction 'effects '(write display))

(category! 'commands)
(public! 'define-command "(define-command NAME [DOC] THUNK) — register an M-x command; DOC shows in M-x")
(public! 'domain! "(domain! 'NAME) — stamp following catalog declarations with their subject area")
(public! 'effects! "(effects! '(LEVEL MODIFIERS...)) — LEVEL is pure/read/write/destroy/unknown; modifiers include external/execute/spend/display")
(public! 'namespace! "(namespace! 'NAME) — set the public vocabulary for following declarations")
(public! 'catalog-meta! "(catalog-meta! KIND NAME 'domain D 'effects '(E ...)) — override catalog discovery metadata")
(public! 'run-command "(run-command NAME) — invoke any M-x command")
(public! 'command-names "All M-x command names")
(public! 'command-doc "(command-doc NAME) -> the command's docstring (\"\" if none)")
(public! 'key-for-command "(key-for-command NAME [BUF]) -> the tersest key bound to NAME, in BUF's keymap and the global one (\"\" if none)")
(public! 'global-set-key "(global-set-key KEYS COMMAND-NAME), e.g. \"C-c x\"")
(public! 'global-unset-key "(global-unset-key KEYS) — remove one global binding")
(public! 'focus-default-keybindings "(focus-default-keybindings &optional MODIFIERS) — bind the arrows with MODIFIERS (shift control meta super; default shift) to focus-left/right/up/down")
(public! 'editing-state? "(editing-state? BUF) — #t when BUF is in the editing state: the state's maps are in force, and the Cmd-arrows move point rather than the focus unless the mode refuses editing-caret-map")
(public! 'editing-state-on! "(editing-state-on! BUF) — enter the editing state in BUF; the first command after a landing does this")
(public! 'editing-state-off! "(editing-state-off! BUF) — return BUF to the movement state, where the Cmd-arrows move the focus; keyboard-quit, a window command, and a new landing do this")
(public! 'editing-state-maps-off! "(editing-state-maps-off! MODE MAPS) — MODE's buffers refuse those maps in the editing state; chat-mode refuses editing-caret-map, so the Cmd-arrows stay the window motion in a chat")
(public! 'editing-quit! "(editing-quit!) — mark the running command as a quit: after it the buffer is in the movement state; keyboard-quit calls this, and a command that aborts something calls it too")
(public! 'window-default-keybindings "(window-default-keybindings &optional MODIFIERS) — bind the arrows with MODIFIERS (default shift super) to window-left/right/up/down; the two panes' buffers swap and the focus follows")
(public! 'buffer-default-keybindings "(buffer-default-keybindings &optional MODIFIERS) — bind the arrows with MODIFIERS (default shift super) to buffer-left/right/up/down; the buffer moves to the neighbor and its previous buffer shows here")
(public! 'arrow-chord "(arrow-chord MODIFIERS KEY) — the key spec for KEY under MODIFIERS, e.g. (arrow-chord '(meta shift) \"<left>\") is \"M-S-<left>\"")
(public! 'local-set-key "(local-set-key KEYS COMMAND-NAME) in the current buffer's own map")
(public! 'define-derived-mode "(define-derived-mode NAME PARENT SETUP) — NAME is PARENT with SETUP on top: PARENT's setup, keymap and hook come first")
(public! 'major-mode-set! "(major-mode-set! NAME) — enter the major mode NAME and say so; the M-x form of a mode")
(public! 'kill-all-local-variables! "(kill-all-local-variables! BUF) — forget every local that is not permanent, and the buffer's own keys")
(public! 'permanent-local! "(permanent-local! NAME) — kill-all-local-variables! keeps the local NAME")
(public! 'define-globalized-minor-mode! "(define-globalized-minor-mode! GLOBAL LOCAL ELIGIBLE? [DOC]) — the command GLOBAL turns LOCAL on in every buffer ELIGIBLE? accepts, now and as buffers appear")
(public! 'globalized-minor-mode-on? "(globalized-minor-mode-on? GLOBAL) — #t while the globalized mode is on")
(public! 'auto-mode-for-buffer "(auto-mode-for-buffer BUF [NAME]) — the mode BUF would open in: magic-mode-alist, then the interpreter line, then the name")
(public! 'define-prefix-command "(define-prefix-command NAME) — a keymap a prefix key leads to")
(public! 'bind-prefix! "(bind-prefix! MAP KEYS NAME) — in MAP (\"global\" for the global map), KEYS leads to the keymap NAME")
(public! 'mode-keys! "(mode-keys! MODE ((KEYS COMMAND) ...)) — bind once on MODE's map; every buffer in the mode answers")
(public! 'minor-mode-keys! "(minor-mode-keys! NAME ((KEYS COMMAND) ...)) — the minor mode's map, in force while the mode is on")
(public! 'minor-mode-keymap! "(minor-mode-keymap! NAME KEYMAP) — give a registered minor mode its keymap")
(public! 'mode-keymap "(mode-keymap MODE) — the name of the keymap MODE owns, MODE-map; bind there with define-key and every buffer in the mode answers")
(public! 'minor-mode-keymap "(minor-mode-keymap NAME) — the keymap a minor mode registered, or #f")
(public! 'local-remap! "(local-remap! FROM-COMMAND TO-COMMAND) — Emacs [remap]: every key bound to FROM runs TO in this buffer (arrows, C-n/C-p, user bindings alike)")
(public! 'local-remap*! "(local-remap*! BUF FROM-COMMAND TO-COMMAND) — remap in an explicit buffer")
(public! 'define-mode "(define-mode NAME SETUP) — major mode; SETUP must rebuild from locals")
(public! 'mode-parent! "(mode-parent! NAME PARENT) — record that NAME is built from PARENT")
(public! 'derived-mode? "(derived-mode? MODE NAME) — #t when MODE is NAME or descends from it")
(public! 'buffer-derived-mode? "(buffer-derived-mode? BUF NAME) — #t when the buffer's major mode is NAME or descends from it")
(public! 'mode-setup! "(mode-setup! NAME) — run NAME's setup in the current buffer, the way a derived mode inherits it")
(public! 'define-list-mode!
  "(define-list-mode! NAME OPTS) — create a selectable text-table mode. Set transient to #f for persistent app buffers (default #t). Responsive layouts are ordered profiles selected by min-cols, max-cols, or default; profiles may override columns, cells, footer, and compact. Every text list exposes c-list/c-item semantic records. Optional composml-root and composml-record callbacks supply domain tags without changing text layout. Optional collection tag and composml (buf entry) callback project string-keyed rows as semantic blocks; the shared list styles field roles and owns navigation."
  'ui)
(catalog-meta! 'function "define-list-mode!" 'domain 'ui 'effects '(write))
(public! 'marginalia! "(marginalia! CATEGORY FN) — FN turns one candidate of CATEGORY ('file 'buffer 'command) into the text beside it; replaces the annotator for that category")
(public! 'annotate "(annotate CATEGORY NAMES) — NAMES as (LABEL HINT) candidates, through CATEGORY's annotator; NAMES unchanged when nothing registered one")
(public! 'set-mode! "(set-mode! NAME) on the current buffer")
(public! 'mode-icon! "(mode-icon! MODE ICON) — the one wide glyph that names MODE in every list")
(public! 'mode-icon "(mode-icon MODE) — MODE's icon, or the plain document icon")
(public! 'mode-link-syntax! "(mode-link-syntax! MODE FN) — FN of (PATH LABEL) writes a file link in MODE's syntax; a child mode inherits it")
(public! 'mode-link-syntax "(mode-link-syntax MODE) — the link syntax fn of MODE or its nearest ancestor; #f when the path alone is the link")
(public! 'mode-label "(mode-label MODE) — MODE's icon and name, for a column that shows the mode")
(public! 'buffer-icon "(buffer-icon NAME) — the icon of the mode NAME is in")
(public! 'file-icon "(file-icon NAME) — the icon of the mode the file NAME would open in; a name ending in / is a directory")
(catalog-meta! 'function "mode-icon!" 'domain 'interaction 'effects '(write))
(catalog-meta! 'function "mode-icon" 'domain 'interaction 'effects '(pure))
(catalog-meta! 'function "mode-label" 'domain 'interaction 'effects '(pure))
(catalog-meta! 'function "buffer-icon" 'domain 'interaction 'effects '(read))
(catalog-meta! 'function "file-icon" 'domain 'interaction 'effects '(pure))
(public! 'font-lock-add-keywords! "(font-lock-add-keywords! MODE ((REGEXP FACE) ...)) — every match wears FACE in MODE's buffers; a derived mode inherits")
(public! 'font-lock-set-keywords! "(font-lock-set-keywords! MODE KEYWORDS) — replace MODE's keywords")
(public! 'font-lock-keywords "(font-lock-keywords MODE) — the keywords of MODE and its parents")
(public! 'font-lock-refontify! "(font-lock-refontify! BUF) — paint BUF's font-lock keywords now")
(public! 'font-lock-enable! "(font-lock-enable! BUF) — paint BUF's keywords and repaint on every change")
(public! 'font-lock-disable! "(font-lock-disable! BUF) — stop painting BUF's keywords")
(public! 'isearch-matches "(isearch-matches Q) — every (START END) of Q in the current buffer, up to isearch-lazy-highlight-max")
(public! 'hl-line-on? "(hl-line-on? BUF) — #t unless hl-line-mode turned the line highlight off in BUF")
(public! 'overriding-map! "(overriding-map! KEYMAP [LOCK?] [UNTIL-COMMAND?]) — the frame's overriding keymap; #f clears it")
(public! 'buffer-at-point-map! "(buffer-at-point-map! BUF KEYMAP) — the keymap of the thing at point in BUF, ahead of the minor maps; #f clears it")
(public! 'defvar "(defvar NAME DEFAULT [DOC]) — NAME takes DEFAULT unless it is bound already")
(public! 'defvar-local "(defvar-local NAME DEFAULT [DOC]) — defvar, and variable-set! writes the current buffer's own value")
(public! 'default-value "(default-value NAME) — the global value, or #f")
(public! 'set-default! "(set-default! NAME VALUE) — the global value")
(public! 'buffer-local-value "(buffer-local-value NAME [BUF]) — BUF's own value, else the default")
(public! 'setq-local! "(setq-local! NAME VALUE) — the current buffer's own value")
(public! 'kill-local-variable! "(kill-local-variable! NAME [BUF]) — forget the buffer's own value")
(public! 'local-variable-p "(local-variable-p NAME [BUF]) — #t when the buffer holds its own value")
(public! 'variable-value "(variable-value NAME) — the current buffer's own value, else the default")
(public! 'variable-set! "(variable-set! NAME VALUE) — locally for a defvar-local, else globally")
(public! 'push-mark! "(push-mark! [POS] [NOMSG]) — the old mark goes on the ring, the mark is set at POS or point")
(public! 'pop-to-mark! "(pop-to-mark!) — point goes to the mark, the ring turns, no region stays")
(public! 'read-char "(read-char PROMPT K) — the next key; K gets the character, or #f on C-g")
(public! 'completing-read "(completing-read PROMPT COLLECTION K 'predicate FN 'require-match #t 'initial TEXT 'default TEXT 'history SYM 'category SYM 'style SYM) — Emacs's completing-read, asynchronous: K gets the choice. COLLECTION is rows or a procedure of the input")
(public! 'read-string "(read-string PROMPT K [OPTS ...]) — a line of text; K gets it")
(public! 'read-number "(read-number PROMPT K [OPTS ...]) — a number; K gets it, 0 for not a number")
(public! 'read-buffer "(read-buffer PROMPT K [OPTS ...]) — a buffer name; K gets it")
(public! 'read-char-choice "(read-char-choice PROMPT CHARS K) — one key from CHARS; K gets it, or #f on C-g")
(public! 'y-or-n-p "(y-or-n-p PROMPT K) — one key; K gets #t for y, #f for n or C-g")
(public! 'yes-or-no-p "(yes-or-no-p PROMPT K) — the word yes or no; K gets #t or #f")
(public! 'minibuffer-active? "(minibuffer-active?) — #t while a prompt is up")
(public! 'capf-collect "(capf-collect SOURCES) — the first capf answer among SOURCES, honouring 'exclusive 'no, or #f")
(public! 'add-hook! "(add-hook! 'name-hook FN [APPEND] [LOCAL]) — put FN on the hook once; FN is a quoted function name, resolved when the hook runs, or a closure. APPEND puts it last. LOCAL puts it on the current buffer's own list, which runs first")
(public! 'remove-hook! "(remove-hook! 'name-hook FN [LOCAL]) — take FN off the hook")
(public! 'run-hook-with-args "(run-hook-with-args 'name-hook ARG ...) — run every function of the hook with ARGS")
(public! 'run-hook-with-args-until-success "(run-hook-with-args-until-success 'name-hook ARG ...) — run until one answers a true value; that value")
(public! 'run-hook-with-args-until-failure "(run-hook-with-args-until-failure 'name-hook ARG ...) — run until one answers #f; #t when none did")
(public! 'hook-functions "(hook-functions 'name-hook) — the functions the hook runs here, local then global")
(public! 'add-paste-hook! "(add-paste-hook! MODE NAME FN) — for a major or minor MODE, register named FN(kind data mime); #t consumes the paste")
(public! 'remove-paste-hook! "(remove-paste-hook! MODE NAME) — remove a named paste handler")
(public! 'layout-arranging? "(layout-arranging?) — #t while the layout engine is building the frame; a package that moves windows must stand down")
(public! 'layout-abort! "(layout-abort!) — clear a layout build left in progress by a failure; a top-level build calls this first")
(public! 'frame-attached! "(frame-attached!) — a client attached this frame; runs frame-attach-hook so per-frame display state is pushed again")
(public! 'overlay-set! "(overlay-set! NAME TAG ((START END FACE) ...)) — replaces TAG's ranges")
(public! 'overlay-clear! "(overlay-clear! NAME TAG)")

;; the buffer cache — external data drawn from what the buffer already
;; holds; the fetch runs off the UI lane through a continuation
(category! 'buffers)
(public! 'cache-declare! "(cache-declare! BUF FETCH RENDER TTL) — FETCH is (buf k): do the work off the UI lane and call (k DATA), (k #f) on failure; RENDER is (buf data); TTL seconds, #f = manual refresh only")
(public! 'cache-refresh! "(cache-refresh! BUF) — fetch and re-render; one flight at a time; the buffer shows what it has until the data lands")
(public! 'cache-wake! "(cache-wake! BUF) — refresh only when the cache is stale; the wake rule for restored and previewed buffers")
(public! 'cache-stale? "(cache-stale? BUF) — no stamp yet, or older than the declared TTL")
(public! 'cache-age "(cache-age BUF) — seconds since the last successful render, or #f")
(public! 'cache-age-label "(cache-age-label BUF) — \"just now\", \"40s ago\", \"5m ago\", for a header or modeline")
(public! 'cache-stamp! "(cache-stamp! BUF) — mark the buffer's content as fetched now")

(category! 'chat)
(public! 'llm "(llm PROMPT HANDLER) — async completion; HANDLER gets the text")
(catalog-meta! 'function "llm" 'domain 'llm 'effects '(read external execute spend))
(public! 'llm-with-model "(llm-with-model PROMPT MODEL HANDLER) — async completion with an explicit model")
(public! 'llm-model "Current model id")
(public! 'set-llm-model! "(set-llm-model! ID) — a \"provider:model\" prefix routes to that provider; a bare id is Anthropic")





;; git
;; Every one takes an optional trailing CALLBACK. With one the call returns
;; at once and the callback gets the value; without one the caller waits.
;; An error comes back as the plist (error "message").
(public! 'git-root "(git-root DIR [CB]) -> absolute work-tree root; resolves from a subdirectory")
(public! 'git-status "(git-status DIR [CB]) -> list of (path P orig-path P2|#f index X worktree Y); X/Y are the git status columns, ? is untracked")
(public! 'git-diff "(git-diff DIR [OPTS] [CB]) -> list of (file-a A file-b B binary? BOOL hunks (...)); each hunk is (header H old-start N old-count N new-start N new-count N lines ((ctx|add|del TEXT) ...)). OPTS: (base \"HEAD\" path P staged #t); a #f base diffs the work tree against the index")
(public! 'git-log "(git-log DIR N [CB]) -> last N commits as (sha S short-sha S author A date ISO subject S)")
(public! 'git-show "(git-show DIR REF [CB]) -> the raw text of one commit")

;; the file watcher
;; The event is content-free: it names the root, and the handler re-queries.
;; Watch coalesces a burst of writes into one event per root.
(public! 'watch-path! "(watch-path! DIR ['deep]) -> the watched root; refcounted, so two watchers of one directory share one subscription. A plain watch sees the direct children of DIR; 'deep sees the whole tree, for a repository")
(public! 'unwatch-path! "(unwatch-path! DIR ['deep]) — drop one reference, 'deep for a deep one; the subscription stops at zero")
(public! 'watched-paths "The watched roots")
(public! 'on-fs-change! "(on-fs-change! FN) — FN gets the root string when a watched tree changes; keep it small, it schedules a refresh")

;; folds
;; Tagged, because a buffer has several fold owners. Each owner replaces
;; only its own tag; the display hides the union of every tag.
(public! 'fold-set! "(fold-set! BUF TAG RANGES) — replace TAG's hidden byte ranges, a list of (START END)")
(public! 'fold-get "(fold-get BUF [TAG]) -> TAG's hidden ranges; no TAG, or 'all, gives the union")
(public! 'fold-clear! "(fold-clear! BUF [TAG]) — drop TAG's folds; no TAG, or 'all, drops every owner's")
(public! 'fold-toggle! "(fold-toggle! BUF TAG RANGE) — add or remove one (START END) in TAG; for owners whose state is the range list itself")
(namespace! 'core)
(effects! '(write display))
(public! 'buffer-narrow! "(buffer-narrow! BUF START END) — narrow visible text to the exclusive byte range without changing buffer access" 'buffers)
(effects! '(read))
(public! 'buffer-narrow-range "(buffer-narrow-range BUF) -> active (START END) narrowing, or #f" 'buffers)
(effects! '(write display))
(public! 'buffer-widen! "(buffer-widen! BUF) — make the complete buffer visible" 'buffers)
(catalog-meta! 'function "buffer-narrow!"
  'namespace 'core 'qualified-name "core/buffer-narrow!"
  'domain 'buffers 'effects '(write display))
(catalog-meta! 'function "buffer-narrow-range"
  'namespace 'core 'qualified-name "core/buffer-narrow-range"
  'domain 'buffers 'effects '(read))
(catalog-meta! 'function "buffer-widen!"
  'namespace 'core 'qualified-name "core/buffer-widen!"
  'domain 'buffers 'effects '(write display))

(category! 'interaction)
(effects! '(write display))
(public! 'global-mode-string-set! "(global-mode-string-set! KEY VALUE) — own one segment at the right of the frame modeline; VALUE is a string, a (CLASS TEXT) pair, or a thunk; #f removes it")
(public! 'global-mode-string-remove! "(global-mode-string-remove! KEY) — drop a package's segment")
(public! 'global-mode-string-refresh! "(global-mode-string-refresh!) — recompose the segments; call after a thunk's answer changed")
(effects! '(read))
(public! 'global-mode-string-segments "(global-mode-string-segments) -> ((CLASS TEXT) ...) the frame modeline shows now")

(message "editor.scm loaded")
