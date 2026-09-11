;;; notmuch.scm --- email client over the notmuch CLI, userland Scheme.
;;;
;;; No Elixir knows what email is. Sync is external (lieer/mbsync cron);
;;; this package reads the local database with `notmuch ... --format=json`,
;;; renders search and thread buffers, tags, replies, and sends. The
;;; extensibility bar, same as dired: primitives + shell + json-parse.
;;;
;;; HTML first — we are in a browser. When a message carries a text/html
;;; part the thread buffer becomes an HTML document rendered by the UI's
;;; sandboxed iframe (render-mode "html" + preview-authored); v toggles the
;;; text view. Tools always read text, through notmuch-html-renderer when
;;; a message has no text/plain part.
;;;
;;; Search buffer keys (ported from the user's Emacs config):
;;;   n/p next/prev (n marks read; both auto-preview) · RET open · SPC preview
;;;   a archive · d trash · u smart-untag · . toggle unread · @ by sender
;;;   m mark+advance · M or * mark all (again unmarks) · U unmark all · F show marked
;;;   a archive marked · d trash marked · t tag marked · T tag this thread
;;;   / custom query filter · l add a tag filter · \ remove the last filter
;;;   s new search · g refresh · q quit
;;; Thread buffer keys:  v html/text view · a archive · r reply · q quit
;;; Compose buffer keys: C-c C-c send · C-c C-k abort
;;;
;;; Chat integration: context providers tell chat/agent what "this" means
;;; (the selected search line, or the thread being read), and tools let
;;; the model search and read mail itself.

(defgroup 'notmuch "Email: notmuch search, reading, and sending.")

(defcustom 'notmuch-program "notmuch"
  "The notmuch executable." 'group 'notmuch)
(defcustom 'notmuch-profile ""
  "NOTMUCH_PROFILE for every call; \"\" uses the default database."
  'group 'notmuch)
;;; The mail store can live on another machine. One host at a time: search,
;;; show, count and tag all run where the database is, so a thread id always
;;; means the same thing.
(defcustom 'notmuch-host ""
  "Machine that owns the mail store; empty is this one, anything else is an ssh destination."
  'group 'notmuch)

(defcustom 'notmuch-hosts '("")
  "The machines notmuch-switch-host offers; empty is this one."
  'group 'notmuch)

(defcustom 'notmuch-ssh-program
  "ssh -o BatchMode=yes -o ControlMaster=auto -o ControlPath=~/.compos/ssh-%C -o ControlPersist=300"
  "How a remote mail host is reached; one multiplexed connection keeps a call cheap."
  'group 'notmuch)

(defcustom 'notmuch-search-limit 50
  "How many threads a search buffer shows." 'group 'notmuch)
(defcustom 'notmuch-default-query "tag:inbox"
  "The query the notmuch command opens with." 'group 'notmuch)
(defcustom 'notmuch-prefer-html #t
  "Render threads as HTML when a message has an HTML part (v toggles text)."
  'group 'notmuch)
(defcustom 'notmuch-html-original-colors #f
  "Render emails with their authored colors on a white canvas. Off, the
theme repaints them (shr-style: layout survives, colors follow the theme
— readable in dark mode)." 'group 'notmuch)
(defcustom 'notmuch-html-renderer "w3m -dump -O utf-8 -T text/html"
  "Command that turns HTML into text, for the text view and the mail tools
when a message has no text/plain part." 'group 'notmuch)
(defcustom 'notmuch-show-newest-first #t
  "Show the newest message of a thread first." 'group 'notmuch)
(defcustom 'notmuch-auto-preview #t
  "n/p in the search buffer preview the thread in the other window."
  'group 'notmuch)

(defcustom 'notmuch-preview-delay 500
  "How long the highlight rests on a row before the mail pane fetches it, in milliseconds. A fetch is a round trip to the mail host, so a held n reaches the row you want before one call goes out. 0 fetches on every move."
  'group 'notmuch 'type 'number)

;; (substring-of-From-or-filename  send-command) — first match wins,
;; "" is the fallback route. set! your accounts' routes in init.scm.
(define notmuch-send-routes
  '(("" "msmtp -t")))

(define *notmuch-search-buffer* "*notmuch*")

;; A search has one base and a stack of added terms. Commands change only
;; these two locals. The effective query is derived, so no command can leave
;; the rows and the filter stack describing different searches.
(define (nm--query-with-filters base filters)
  (if (null? filters)
      base
      (let ((filter (car filters)))
        (if (and (pair? filter) (equal? (car filter) "only"))
            (cadr filter)
            (string-append "( "
                           (nm--query-with-filters base (cdr filters))
                           " ) and " filter)))))

(define (nm--query-base-of buf)
  (let ((base (buffer-local buf 'notmuch-query-base)))
    (if base
        base
        ;; Migrate a buffer saved before the query stack became authoritative.
        (let ((legacy (or (buffer-local buf 'notmuch-query)
                          notmuch-default-query)))
          (buffer-set-local! buf 'notmuch-query-base legacy)
          (buffer-set-local! buf 'notmuch-query-filters '())
          (buffer-set-local! buf 'notmuch-query #f)
          legacy))))

(define (nm--query-filters-of buf)
  (or (buffer-local buf 'notmuch-query-filters) '()))

(define (nm--query-of buf)
  (nm--query-with-filters (nm--query-base-of buf)
                          (nm--query-filters-of buf)))

(define (nm--query-reset! buf query)
  (buffer-set-local! buf 'notmuch-selection #f)
  (buffer-set-local! buf 'notmuch-query-base query)
  (buffer-set-local! buf 'notmuch-query-filters '())
  (buffer-set-local! buf 'notmuch-query-positions '())
  ;; Keep a restored legacy local inert. The stack now owns the query.
  (buffer-set-local! buf 'notmuch-query #f))

(define (nm--query-push! buf term)
  (buffer-set-local! buf 'notmuch-selection #f)
  (nm--query-base-of buf)
  (buffer-set-local! buf 'notmuch-query-positions
    (cons (list-index buf)
          (or (buffer-local buf 'notmuch-query-positions) '())))
  (buffer-set-local! buf 'notmuch-query-filters
    (cons term (nm--query-filters-of buf))))

(define (nm--query-push-only! buf term)
  (buffer-set-local! buf 'notmuch-selection #f)
  (nm--query-base-of buf)
  (buffer-set-local! buf 'notmuch-query-positions
    (cons (list-index buf)
          (or (buffer-local buf 'notmuch-query-positions) '())))
  (buffer-set-local! buf 'notmuch-query-filters
    (cons (list "only" term) (nm--query-filters-of buf))))

(define (nm--query-pop! buf)
  (let ((filters (nm--query-filters-of buf)))
    (if (null? filters)
        #f
        (begin
          (buffer-set-local! buf 'notmuch-selection #f)
          (buffer-set-local! buf 'notmuch-query-filters (cdr filters))
          (let ((positions (or (buffer-local buf 'notmuch-query-positions) '())))
            (unless (null? positions)
              (buffer-set-local! buf 'notmuch-query-positions (cdr positions))))
          #t))))

;;; --- CLI plumbing -------------------------------------------------------------

(define (nm--quote s)
  (string-append "'" (string-join (string-split s "'") "'\\''") "'"))

(define (nm--cmd args)
  (let ((here (string-append
                (if (equal? notmuch-profile "")
                    ""
                    (string-append "NOTMUCH_PROFILE=" (nm--quote notmuch-profile) " "))
                notmuch-program " " args)))
    (if (equal? notmuch-host "")
        here
        ;; the remote shell reads the whole call as one word
        (string-append notmuch-ssh-program " " (nm--quote notmuch-host)
                       " " (nm--quote here)))))

(define (nm--host-label)
  (if (equal? notmuch-host "") "this machine" notmuch-host))

;; which notmuch: several databases answer to the same program name, so
;; the identity is the host, the profile, and the database that profile
;; opens. The path costs one round trip, so hold it per identity and drop
;; the cache when the host changes.
(define *nm-db-paths* '())

(define (nm--db-key)
  (string-append (nm--host-label) "|" notmuch-profile))

(define (nm--db-path)
  (let ((hit (assoc (nm--db-key) *nm-db-paths*)))
    (if hit
        (cadr hit)
        (let ((path (string-trim (nm--run "config get database.path"))))
          ;; a failed lookup is not an answer: leave it uncached and retry
          (when (not (equal? path ""))
            (set! *nm-db-paths* (cons (list (nm--db-key) path) *nm-db-paths*)))
          path))))

(define (nm--source-label)
  (let ((path (nm--db-path)))
    (string-append (nm--host-label)
                   (if (equal? notmuch-profile "")
                       ""
                       (string-append " [" notmuch-profile "]"))
                   (if (equal? path "") "" (string-append ":" path)))))

;; Tag writes must report failure before callers refresh or say Done.
(define (nm--tag-result output)
  (let* ((lines (string-split output "\n"))
         (status (car lines))
         (body (string-join (cdr lines) "\n")))
    (if (equal? status "0") body
        (error (string-append "Notmuch tag failed: "
                 (if (equal? (string-trim body) "") output (string-trim body)))))))

(define (nm--run args)
  (if (string-prefix? "tag " args)
      (nm--tag-result
        (shell-command->string
          (string-append "compos_tag_output=$(" (nm--cmd args)
            " 2>&1); compos_tag_status=$?; printf '%s\\n%s' \"$compos_tag_status\" \"$compos_tag_output\"")))
      (shell-command->string (nm--cmd args))))

(define (nm--json args)
  (json-parse (nm--run args)))

(define (nm--get pl key) (custom--plist-get pl key))

(define (nm--fit s n)
  (let ((s (or s "")))
    (if (> (string-length s) n)
        (substring s 0 n)
        (string-pad-right s n))))

(define (nm--trunc s n)
  (let ((s (or s "")))
    (if (> (string-length s) n) (substring s 0 n) s)))

(define (nm--html-escape s)
  (let* ((s (string-join (string-split s "&") "&amp;"))
         (s (string-join (string-split s "<") "&lt;"))
         (s (string-join (string-split s ">") "&gt;")))
    s))

(define (nm--html->text html)
  (let ((tmp (string-append (expand-path "~") "/.compos/mail-part.html")))
    (write-file! tmp html)
    (shell-command->string
      (string-append notmuch-html-renderer " < " (nm--quote tmp)))))

;;; --- search buffer ------------------------------------------------------------

(defface! 'nm-date 'fg "#8a8a8a")
(defface! 'nm-author 'fg "#26356b")
(defface! 'nm-unread 'weight "700")
(defface! 'nm-tags 'fg "#9a9a72")
(defface! 'nm-marked 'fg "#a03020" 'weight "700")
(defface! 'nm-bar 'fg "#26356b")

(define (nm--search-json query limit)
  (or (nm--json (string-append "search --format=json --limit="
                               (number->string limit) " -- " (nm--quote query)))
      '()))

;; stored per row: (thread-id subject authors tags date)
(define (nm--th-id th) (car th))
(define (nm--th-subject th) (cadr th))
(define (nm--th-authors th) (caddr th))
(define (nm--th-tags th) (list-ref th 3))
(define (nm--th-date th) (list-ref th 4))

(define (nm--search-rows buf)
  (let* ((query (nm--query-of buf))
         (rows (map (lambda (th) (list (nm--get th 'thread)
                                      (or (nm--get th 'subject) "")
                                      (or (nm--get th 'authors) "")
                                      (or (nm--get th 'tags) '())
                                      (or (nm--get th 'date_relative) "")))
                    (nm--search-json query notmuch-search-limit))))
    (nm--draw-marks! buf rows)
    ;; the tag column measures itself against the threads this search
    ;; found. It reads the number here, and not from the entries: a draw
    ;; lays the columns out while the entries it replaces are still the
    ;; ones on the buffer.
    (buffer-set-local! buf 'nm-tags-need
      (fold (lambda (acc th) (max acc (string-length (nm--tags-text th)))) 6 rows))
    rows))

;; Two lines per thread. The subject owns the first line, so a narrow
;; window never truncates it; the date sits at the right of that line,
;; where a compressed date still reads. The author and the tags share
;; the second line, and the bar in front of the row says the tag you
;; read first: unread.
;;
;; The reader sees EVERY tag a thread carries, and reads each one in
;; full while the column has the room. A narrow window takes that room
;; back: then a tag longer than five characters keeps its first three
;; letters and says the rest is missing, so "attachment" reads "att..".
;; The author is what gives way first.
(define nm-tag-width 5)

(define (nm--short-tag t)
  (if (> (string-length t) nm-tag-width)
      (string-append (substring t 0 3) "..")
      t))

(define (nm--fit-tags s w)
  (let* ((tags (filter (lambda (t) (not (equal? t ""))) (string-split s " ")))
         (full (string-join tags " "))
         (short (string-join (map nm--short-tag tags) " ")))
    (cond ((null? tags) "")
          ;; the column asks for what the busiest row needs, so a tag
          ;; normally reads under its own name
          ((<= (string-length full) w) full)
          ((<= (string-length short) w) short)
          ;; not even the short forms fit: one letter per tag, and the
          ;; reader still counts them
          (else (string-join (map (lambda (t) (substring t 0 1)) tags) "")))))

(define (nm--tags-text th)
  (string-join (nm--th-tags th) " "))

;; The tag column is as wide as the busiest thread of this search needs,
;; so every thread shows every tag it has. It stops at half the window:
;; past that the author has nothing left to say, and a thread with that
;; many tags falls back to the initials.
(define (nm--tags-width buf)
  (let ((need (or (buffer-local buf 'nm-tags-need) 6)))
    (min need (max 10 (quotient (list-view-width buf) 2)))))

(define (nm--search-columns buf)
  (list (list (list "" 1) (list "subject" #f 'left 'end) (list "date" 13 'right))
        (list (list "" 1) (list "author" #f)
              (list "tags" (nm--tags-width buf) 'right nm--fit-tags))))

(define (nm--subject-face tags)
  (cond ((member "unread" tags) "nm-unread")
        (else "nm-subject")))

(define (nm--search-cells buf th)
  (let* ((tags (nm--th-tags th))
         (bar (if (member "unread" tags) "▌" " ")))
    (list (list (list bar "nm-bar")
                (list (nm--th-subject th) (if (nm--row-marked? buf th) "nm-marked" (nm--subject-face tags)))
                (list (nm--th-date th) "nm-date"))
          (list " "
                (list (nm--th-authors th) "nm-author")
                (list (nm--tags-text th) "nm-tags")))))

;; every draw asks for this line, and one draw must not cost a round
;; trip: count once per database and query, and let nm--refresh! drop the
;; answer when the mail behind it can have changed.
(define (nm--count-for buf query)
  (let ((key (string-append (nm--source-label) "|" query))
        (hit (buffer-local buf 'nm-count)))
    (if (and (pair? hit) (equal? (car hit) key))
        (cadr hit)
        ;; count, and not count --output=threads: grouping threads over a
        ;; large query costs seconds
        (let ((n (string-trim
                   (nm--run (string-append "count -- " (nm--quote query))))))
          (buffer-set-local! buf 'nm-count (list key n))
          n))))

(define (nm--selection-label buf)
  (let ((s (nm--selection buf)))
    (if (not (nm--any-marked? buf)) ""
      (let ((n (length (list-ref s 3))))
        (if (caddr s)
            (if (= n 0)
                (string-append "All " (nm--count-for buf (nm--query-of buf)) " matching messages selected")
                (string-append "All matching messages selected except " (number->string n)
                               (if (= n 1) " thread" " threads")))
            (string-append (number->string n) (if (= n 1) " thread selected" " threads selected")))))))

(define (nm--search-meta buf)
  (let ((query (nm--query-of buf)))
    (string-append (let ((selection (nm--selection-label buf)))
                     (if (equal? selection "") "" (string-append selection " · ")))
                   (nm--count-for buf query) " messages · "
                   (nm--source-label) " · " query)))

;; the list machinery owns the refresh, the row lookup and the header
;; offset (R8); these names stay for the commands and tests that call them
(define (nm--refresh! buf)
  (buffer-set-local! buf 'nm-count #f)
  (list-refresh! buf))
(define (nm--index-at buf) (list-index buf))
(define (nm--thread-at buf) (list-current buf))

(mode-icon! "notmuch-mode" "")

;; Footer hints read the buffer's own keymap. A hardcoded hint goes stale the
;; moment a key is rebound or taken by another map, so only the label is written
;; here and the key is looked up.
(define (nm--footer-key buf names)
  (let loop ((n (if (pair? names) names (list names))))
    (if (null? n)
        ""
        (let ((k (key-for-command (car n) buf)))
          (if (equal? k "") (loop (cdr n)) k)))))

(define (nm--footer buf specs)
  (let loop ((s specs) (acc '()))
    (if (null? s)
        (reverse acc)
        (let ((k (nm--footer-key buf (car (car s)))))
          (loop (cdr s)
                (if (equal? k "") acc (cons (list k (cadr (car s))) acc)))))))

;; Fields keep their full values; CSS controls the visual compression.
(define (nm--field tag value &optional field)
  (list 'tag tag 'attrs (if field (list (list "field" field)) '()) 'text (if (number? value) (number->string value) (or value ""))))

(define (nm--thread-composml buf th)
  (list 'tag "mail-thread"
        'attrs (list (list "unread" (if (member "unread" (nm--th-tags th)) "true" "false"))
                     (list "marked" (if (nm--row-marked? buf th) "true" "false")))
        'children
        (list (nm--field "mail-subject" (nm--th-subject th) "primary")
              (nm--field "mail-date" (nm--th-date th) "trailing")
              (nm--field "mail-participants" (nm--th-authors th) "secondary")
              (list 'tag "mail-tags" 'attrs '(("field" "tags")) 'children
                    (map (lambda (tag) (nm--field "mail-tag" tag)) (nm--th-tags th))))))

(define (nm--click-thread! buf th)
  ;; The shared list already moved point to this record. Match n/p behavior.
  (nm--maybe-preview! buf))

(define-list-mode! "notmuch-mode"
  (list
    'doc (string-append
           "One notmuch search as a list of threads. `RET` opens, `SPC` "
           "previews, `a`/`d` tag, `t` classifies with the mailbox's own tags, "
           "`L` files a thread for the agent (+liked -inbox), "
           "`0` strips every tag, `m` marks and the capital keys act "
           "on every marked thread. Selection is local and clears after bulk actions or filter changes. `/` adds a custom query filter. "
           "`l` adds a tag filter; `\\` removes it. "
           "`s` starts a new search; `q` removes the last filter, "
           "or goes back to mailboxes when no filters remain.")
    'on-click (lambda (buf th) (nm--click-thread! buf th))
    'composml-root (lambda (buf)
      (list 'tag "mailbox" 'attrs
        (list (list "source" (nm--host-label))
              (list "profile" notmuch-profile)
              (list "query" (nm--query-of buf)))))
    'collection "mail-threads"
    'composml (lambda (buf th) (nm--thread-composml buf th))
    'rows (lambda (buf) (nm--search-rows buf))
    'key (lambda (buf th) (nm--th-id th))
    'selection-face "select"
    'row-columns (lambda (buf) (nm--search-columns buf))
    'row-cells (lambda (buf th) (nm--search-cells buf th))
    'title (lambda (buf)
               (if (equal? notmuch-host "")
                   "Mail"
                   (string-append "Mail on " notmuch-host)))
    'meta (lambda (buf) (nm--search-meta buf))
    'total (lambda (buf) (length (list-entries buf)))
    'footer (lambda (buf)
              (nm--footer buf
                (if (nm--any-marked? buf)
                    '(("notmuch-archive" "archive") ("notmuch-trash" "trash")
                      ("notmuch-autotag" "autotag")
                      ("notmuch-tag-marked" "tag") ("notmuch-like" "like")
                      ("notmuch-filter-marked" "filter")
                      ("notmuch-unmark-all" "unmark")
                      ("notmuch-mark-toggle" "unmark this")
                      ("notmuch-open-thread" "open")
                      ("notmuch-refresh" "refresh")
                      (("notmuch-back" "dismiss-buffer") "back"))
                    '(("notmuch-open-thread" "open") ("notmuch-preview" "preview")
                      ("notmuch-mark-toggle" "mark")
                      ("notmuch-archive" "archive") ("notmuch-trash" "trash")
                      ("notmuch-edit-tags" "tag") ("notmuch-autotag" "autotag")
                      ("notmuch-like" "like")
                      ("notmuch-search" "search")
                      ("notmuch-filter" "custom filter")
                      ("notmuch-filter-by-tag" "tag filter")
                      ("notmuch-unfilter-last" "unfilter")
                      ("notmuch-refresh" "refresh")
                      (("notmuch-back" "dismiss-buffer") "back")))))
    'keys '(("n" "notmuch-next") ("p" "notmuch-prev")
            ("RET" "notmuch-open-thread") ("SPC" "notmuch-preview")
            ("M-<" "notmuch-first-thread") ("M->" "notmuch-last-thread")
            ("r" "notmuch-reply") ("a" "notmuch-archive") ("d" "notmuch-trash")
            ("u" "notmuch-smart-untag") ("." "notmuch-toggle-unread")
            ("@" "notmuch-filter-by-sender")
            ("m" "notmuch-mark-toggle") ("M" "notmuch-mark-all")
            ("*" "notmuch-mark-all") ("U" "notmuch-unmark-all")
            ("F" "notmuch-filter-marked") ("A" "notmuch-archive-marked")
            ("D" "notmuch-trash-marked") ("t" "notmuch-autotag")
            ("C-c t" "notmuch-tag-marked")
            ("T" "notmuch-edit-tags") ("+" "notmuch-add-tag")
            ("-" "notmuch-remove-tag") ("0" "notmuch-remove-all-tags")
            ("L" "notmuch-like")
            ("j" "notmuch-jump")
            ("/" "notmuch-filter")
            ("\\" "notmuch-unfilter-last") ("l" "notmuch-filter-by-tag")
            ("s" "notmuch-search") ("g" "notmuch-refresh")
            ("C-c a" "notmuch-open-attachment")
            ("q" "notmuch-back"))
    'remap '(("next-line" "notmuch-next") ("previous-line" "notmuch-prev"))))

(define (nm--open-index! query)
  (let* ((buf *notmuch-search-buffer*)
         (cached? (and (buffer-exists? buf)
                       (pair? (buffer-local buf 'list-entries)))))
    (unless (buffer-exists? buf) (buffer-create buf))
    (nm--query-reset! buf query)
    (switch-to-buffer! buf)
    (set-mode! "notmuch-mode")
    ;; The mode setup can reuse cached rows. A mailbox selection requests
    ;; current rows for its new base query.
    (when cached? (nm--refresh! buf))
    (list-goto-first-entry buf)
    ;; Opening selects a row just as n/p do. Populate its detail now.
    ;; During scene construction, the declared show pane does this itself.
    (unless (layout-arranging?) (nm--maybe-preview! buf))))

(define-command "notmuch-inbox" "Open the mail index on the default query"
  (lambda () (nm--open-index! notmuch-default-query)))

;;; --- mailboxes (notmuch-hello): saved searches with counts -----------------------

(define *notmuch-hello-buffer* "*mailboxes*")

;; query.NAME.query=Q entries from the notmuch config
(define (nm--saved-searches)
  (let loop ((ls (string-split (nm--run "config list") "\n")) (acc '()))
    (if (null? ls)
        (reverse acc)
        (let ((line (car ls)))
          (if (string-prefix? "query." line)
              (let* ((name (car (string-split
                                  (substring line 6 (string-length line)) ".")))
                     (parts (string-split line "="))
                     (q (if (pair? (cdr parts)) (string-join (cdr parts) "=") "")))
                (loop (cdr ls) (cons (list name q) acc)))
              (loop (cdr ls) acc))))))

(define (nm--tag-query tag)
  (string-append "tag:\"" (string-join (string-split tag "\"") "\"\"") "\""))

(define (nm--tag-search? query tag)
  (or (equal? query (nm--tag-query tag))
      (and (re-match? "^[A-Za-z0-9_.@+-]+$" tag)
           (equal? query (string-append "tag:" tag)))))

;; Tags belong to the selected database. A mailbox does not need a
;; separately configured saved search just to make its tag visible.
(define (nm--mailboxes)
  (let ((saved (nm--saved-searches)))
    (append saved
      (map (lambda (tag) (list tag (nm--tag-query tag)))
           (filter
             (lambda (tag)
               (null? (filter (lambda (s) (nm--tag-search? (cadr s) tag)) saved)))
             (nm--all-tags))))))

(define (nm--batch-count-command queries)
  (string-append "printf '%s\\n' "
                 (string-join (map nm--quote queries) " ")
                 " | " (nm--cmd "count --batch")))

(define (nm--parse-counts output)
  (map string->number (string-split (string-trim output) "\n")))

;; Kept for callers that need a synchronous count outside the UI.
(define (nm--batch-count queries)
  (if (null? queries) '()
      (nm--parse-counts
        (shell-command->string (nm--batch-count-command queries)))))

;; Count pairs share one database open and SSH call. A thread expansion
;; in a saved search can take seconds even over a warm SSH connection.
;; Show selectable mailbox names first; counts must never hold navigation.
(define *nm-hello-request* 0)

(define (nm--hello-count-queries searches)
  (fold (lambda (acc s)
          (append acc (list (cadr s)
                            (string-append "( " (cadr s) " ) and tag:unread"))))
        '() searches))

(define (nm--hello-count-rows searches counts)
  (if (null? searches) '()
      (cons (list (car (car searches)) (cadr (car searches)) (car counts) (cadr counts))
            (nm--hello-count-rows (cdr searches) (cddr counts)))))

(define (nm--hello-rows buf)
  (let* ((searches (nm--mailboxes))
         (identity (nm--db-key))
         (request (+ *nm-hello-request* 1)))
    (set! *nm-hello-request* request)
    (desktop-skip! buf 'nm-hello-request)
    (desktop-skip! buf 'nm-hello-status)
    (buffer-set-local! buf 'nm-hello-request request)
    (buffer-set-local! buf 'nm-hello-status
      (if (null? searches) "" " · loading counts…"))
    (unless (null? searches)
      (shell-command->string
        (nm--batch-count-command (nm--hello-count-queries searches))
        (lambda (output)
          ;; An older refresh, another account, or a recreated buffer must
          ;; never receive these results. The callback never selects a window.
          (when (and (buffer-exists? buf)
                     (equal? identity (nm--db-key))
                     (equal? request (buffer-local buf 'nm-hello-request)))
            (let ((counts (nm--parse-counts output)))
              (if (and (= (length counts) (* 2 (length searches)))
                       (null? (filter (lambda (n) (not (and (number? n) (>= n 0)))) counts)))
                  (begin
                    (buffer-set-local! buf 'list-source-entries
                      (nm--hello-count-rows searches counts))
                    (buffer-set-local! buf 'nm-hello-status ""))
                  (buffer-set-local! buf 'nm-hello-status " · counts unavailable; g retries"))
              (list-redraw! buf))))))
    (map (lambda (s) (list (car s) (cadr s) #f #f)) searches)))

(define (nm--hello-count-label n)
  (if (number? n) (number->string n) "…"))

(define (nm--hello-unread? row)
  (let ((n (list-ref row 3))) (and (number? n) (> n 0))))

(define (nm--hello-cols row)
  (list (nm--fit (car row) 16)
        (string-append
          (string-pad-left (nm--hello-count-label (list-ref row 3)) 6) " / "
          (string-pad-left (nm--hello-count-label (list-ref row 2)) 6))))

(define (nm--hello-line row)
  (let ((c (nm--hello-cols row)))
    (string-append "  " (car c) (cadr c) "   " (cadr row))))

(define (nm--hello-overlays buf row off)
  (let* ((c (nm--hello-cols row))
         (n-start (+ off 2))
         (n-end (+ n-start (string-byte-length (car c))))
         (c-end (+ n-end (string-byte-length (cadr c))))
         (l-end (+ off (string-byte-length (nm--hello-line row)))))
    (list (list n-start n-end
                (if (nm--hello-unread? row) "nm-unread" "nm-author"))
          (list n-end c-end "nm-date")
          (list c-end l-end "nm-tags"))))

(define (nm--hello-cells buf row)
  (list (list (car row) (if (nm--hello-unread? row) "nm-unread" "nm-author"))
        (list (nm--hello-count-label (list-ref row 3)) "nm-date")
        (list (nm--hello-count-label (list-ref row 2)) "nm-date")
        (list (cadr row) "nm-tags")))

(define (nm--hello-at buf) (list-current buf))

(mode-icon! "notmuch-hello-mode" "")

(define (nm--mailbox-composml buf row)
  (list 'tag "mailbox" 'attrs (list (list "query" (cadr row)))
        'children (list (nm--field "mailbox-name" (car row) "primary")
                        (nm--field "unread-count" (nm--hello-count-label (list-ref row 3)) "count")
                        (nm--field "message-count" (nm--hello-count-label (list-ref row 2)) "count")
                        (nm--field "mail-query" (cadr row) "detail"))))

(define-list-mode! "notmuch-hello-mode"
  (list
    'doc (string-append
           "The account’s tags and saved searches with their unread and total "
           "counts. `RET` opens one as a thread list; `s` runs a free-form "
           "search. Counts load in the background; mailboxes open immediately.")
    'buffer *notmuch-hello-buffer*
    'collection "mailboxes"
    'composml (lambda (buf row) (nm--mailbox-composml buf row))
    'rows (lambda (buf) (nm--hello-rows buf))
    'key (lambda (buf row) (cadr row))
    'columns (lambda (buf)
               (list (list "mailbox" 16) (list "unread" 7 'right)
                     (list "total" 7 'right) (list "query" #f)))
    'cells (lambda (buf row) (nm--hello-cells buf row))
    'title (lambda (buf)
               (if (equal? notmuch-host "")
                   "Mailboxes"
                   (string-append "Mailboxes on " notmuch-host)))
    'meta (lambda (buf)
            (string-append (number->string (length (list-entries buf)))
                           " mailboxes · " (nm--source-label)
                           (or (buffer-local buf 'nm-hello-status) "")))
    'total (lambda (buf) (length (list-source-entries buf)))
    'local-filter #t
    'footer (lambda (buf)
              '(("RET" "open") ("s" "search") ("/" "filter")
                ("h" "host") ("g" "refresh") ("q" "quit")))
    'keys '(("n" "next-line") ("p" "previous-line")
            ("RET" "notmuch-hello-open") ("g" "notmuch-hello-refresh")
            ("j" "notmuch-jump") ("s" "notmuch-search")
            ("h" "notmuch-switch-host")
            ("q" "quit-window"))))

(define (nm--hello-wake!)
  ;; Pending callbacks and their status do not survive desktop restore.
  ;; Cached mailbox rows still need fresh counts after the mode wakes.
  (let ((buf (current-buffer)))
    (unless (buffer-local buf 'nm-hello-status)
      (list-refresh! buf))))

(add-hook! 'notmuch-hello-mode-hook 'nm--hello-wake!)

(define-command "notmuch" "Open the mailboxes (saved searches)"
  (lambda ()
    (let ((buf *notmuch-hello-buffer*))
      (unless (buffer-exists? buf) (buffer-create buf))
      (switch-to-buffer! buf)
      (set-mode! "notmuch-hello-mode")
      (list-goto-first-entry buf))))

(define-command "notmuch-hello-open" "Open the saved search at point"
  (lambda ()
    (let ((s (nm--hello-at (current-buffer))))
      (if s
          (nm--open-index! (cadr s))
          (message "No mailbox on this line")))))

(define-command "notmuch-hello-refresh" "Refresh the mailbox counts"
  (lambda () (list-refresh! (current-buffer)) (message "Refreshed")))

;;; A thread id belongs to one database, so a host change makes every cached
;;; view stale. Drop the rows and read again rather than keep ids that no
;;; longer resolve.
(define (nm--host-changed! buf)
  (set! *nm-db-paths* '())
  (for-each (lambda (b)
              (when (buffer-exists? b) (buffer-set-local! b 'list-entries '())))
            (list *notmuch-search-buffer* *notmuch-hello-buffer*))
  (when (buffer-exists? *notmuch-search-buffer*)
    (nm--query-reset! *notmuch-search-buffer* notmuch-default-query))
  (list-refresh! buf)
  (message (string-append "Mail on " (nm--source-label))))

(define-command "notmuch-switch-host" "Read mail from another machine"
  (lambda ()
    (let ((buf (current-buffer)))
      (minibuffer-read "Mail host: "
        (map (lambda (h) (if (equal? h "") "local" h)) notmuch-hosts)
        (lambda (h)
          (let* ((typed (string-trim h))
                 (host (if (or (equal? typed "local") (equal? typed "")) "" typed)))
            (customize-save! 'notmuch-host host)
            (nm--host-changed! buf)))))))

;; the mail views are derived state — killing them loses nothing. The
;; chat survives (it holds a conversation); a scene toggle in init.scm
;; can lean on this for teardown.
(define (nm--view-buffers)
  (filter (lambda (b) (member b (list *notmuch-search-buffer*
                                      *notmuch-hello-buffer*
                                      *notmuch-show-buffer*)))
          (buffer-list)))

(define-command "notmuch-quit" "Close mail: kill the view buffers, back to work"
  (lambda ()
    ;; land on real work: not a mail view, and not a member of whatever
    ;; group the mail scene lives in. That group is the index's own — the
    ;; name is the user's to choose, and buffer-group answers with an id,
    ;; so neither one can be compared against a literal here.
    (let* ((mail-ids (if (buffer-exists? *notmuch-search-buffer*)
                         (buffer-group-ids *notmuch-search-buffer*)
                         '()))
           (others (filter (lambda (b)
                             (and (not (member b (nm--view-buffers)))
                                  (not (fold (lambda (hit id)
                                               (or hit (buffer-in-group? b id)))
                                             #f mail-ids))))
                           (buffer-list-mru))))
      (delete-other-windows!)
      (switch-to-buffer! (if (null? others) "*scratch*" (car others)))
      (for-each buffer-kill! (nm--view-buffers))
      (message "Mail closed"))))

;; the preview helpers target the *next* window in cyclic order, so any
;; window arrangement works: put the index left of where you want mail
;; shown and SPC/n/p keep filling that pane. Personal scenes (three-pane
;; layouts, per-account profile commands, keybindings) belong in init.scm.

;;; --- preview: thread in the other window, focus stays --------------------------

;; Render into the mail pane. A window already showing the mail view IS
;; that pane — reuse it. other-window! only means "the mail pane" in a
;; two-window frame; in a three-pane scene it can be the chat, and the
;; preview would then evict the chat and leave the frame a window short.
;; Only when no pane shows the mail view does this fall back to making
;; one, and it always puts focus back where it started.
(define (nm--show-pane! buf)
  (cond
    ;; the layout engine is mid-build: it places every declared pane
    ;; itself, so the view is rendered and no window is touched. A split
    ;; here lands between the engine's own splits and leaves the frame in
    ;; neither arrangement, and a switch here takes the index's window.
    ((layout-arranging?) #f)
    (else
      (let ((pane (or (scene-window 'show) (window-showing buf))))
        (cond
          ;; a scene names its mail pane, and a window already showing the
          ;; mail view IS the pane: fill it, select nothing
          (pane (window-set-buffer! pane buf) pane)
          (else
            ;; A one-window frame has no other window, and a frame target
            ;; never splits on its own (display--keep-shape drops
            ;; pop-up-window), so make the pane here. Without it the
            ;; display chain runs out of actions and its last resort,
            ;; same-window, hands the mail view the index's own window.
            (when (null? (cdr (window-list))) (split-window! 'h 0.45))
            ;; the chain places it in a window that is not this one and
            ;; selects nothing, so focus and point stay where the user
            ;; left them
            (display-buffer-other-window! buf)
            (window-showing buf)))))))

;; #t once a thread has been shown for the live index. A pane that was
;; shown and is gone was dismissed, and a dismissal stays dismissed.
(define *notmuch-pane-shown* #f)

(define (nm--preview! buf)
  (let ((th (nm--thread-at buf)))
    (when th
      (let* ((origin (active-window))
             (mail (nm--open-thread! (nm--th-id th) (nm--th-subject th) 'defer-read)))
        (window-set-buffer! origin buf)
        (select-window! origin)
        (nm--show-pane! mail)
        (set! *notmuch-pane-shown* #t))
      ;; Keep the list focused before a database write can fail.
      (nm--run (string-append "tag -unread -- thread:" (nm--th-id th)))
      ;; opening marked it read — show that in the index right away
      (when (member "unread" (nm--th-tags th))
        (nm--refresh! buf)))))

(define-command "notmuch-preview" "Preview the thread at point in the other window"
  (lambda () (nm--preview! (current-buffer))))

;; The pane-builder form of the same thing. A scene declares its panes as
;; (ensure "*mail*" "notmuch-show-current"), and an ensure command has one
;; job: make that buffer exist. So it reads the index by name and never
;; consults the current buffer, point, or the windows — none of which mean
;; anything while a layout is being built.
(define-command "notmuch-show-current"
  "Make the mail pane, showing the index's current thread if there is one"
  (lambda ()
    (let ((th (and (buffer-exists? *notmuch-search-buffer*)
                   (with-current-buffer *notmuch-search-buffer*
                     (lambda () (nm--thread-at *notmuch-search-buffer*))))))
      (if th
          (nm--open-thread! (nm--th-id th) (nm--th-subject th))
          ;; The index fetches its rows off this lane, so a freshly built
          ;; index has none yet and there is no thread to open. The pane is
          ;; part of the declared shape all the same: make it now and let
          ;; the first move in the index fill it. An ensure command that
          ;; only sometimes makes its buffer is not an ensure command.
          (unless (buffer-exists? *notmuch-show-buffer*)
            (buffer-create *notmuch-show-buffer*)
            ;; no mode yet: the empty pane says for itself that it is a view
            (buffer-set-local! *notmuch-show-buffer* 'special #t)
            (buffer-append! *notmuch-show-buffer* "No message selected.\n"))))))

(define (nm--maybe-preview! buf)
  (when notmuch-auto-preview (nm--preview! buf)))

;; #t when the mail pane already holds the thread at point. A focus change
;; fires the configuration hook often, and a preview is an ssh round trip,
;; so only a pane that disagrees with point is worth refilling.
(define (nm--pane-at-point? buf)
  (let ((th (nm--thread-at buf))
        (pane *notmuch-show-buffer*))
    (or (not th)
        (and (buffer-exists? pane)
             (window-showing pane)
             (equal? (buffer-local pane 'notmuch-thread) (nm--th-id th))))))

;; Landing on the index is the same event as moving inside it: the mail
;; pane shows the thread at point. A return from another buffer, a group
;; switch or a restored scene left the pane stale, so the first n or SPC
;; after every arrival was spent on catching the pane up.
(define (nm--landed-preview!)
  (let ((buf *notmuch-search-buffer*))
    (when (and notmuch-auto-preview
               (buffer-exists? buf)
               (not (layout-arranging?))
               (not (minibuffer-active?))
               ;; q closed the pane. The kill changes the configuration, so
               ;; without this the landing rule reopened what the reader
               ;; just dismissed. n or SPC brings it back.
               (not (and *notmuch-pane-shown*
                         (not (buffer-exists? *notmuch-show-buffer*))))
               (equal? (window-buffer (active-window)) buf)
               (not (nm--pane-at-point? buf)))
      (nm--preview! buf))))

(add-hook! 'window-configuration-change-hook 'nm--landed-preview!)

;; the shown mail follows the highlight: every move previews, and opening
;; a thread marks it read (the open itself tags -unread)
;; a thread is a ROW, and a row is two lines — the list moves by rows,
;; so every move here goes through the list and none of them counts
;; lines
(define (nm--move! step)
  (let ((buf (current-buffer)))
    (list-move-in! buf step)
    (nm--maybe-preview! buf)))

(define-command "notmuch-next" "Move down; the shown mail follows"
  (lambda () (nm--move! 1)))

(define-command "notmuch-prev" "Move up; the shown mail follows"
  (lambda () (nm--move! -1)))

(define-command "notmuch-first-thread" "Jump to the newest thread"
  (lambda ()
    (let ((buf (current-buffer)))
      (list-goto-first-entry buf)
      (nm--maybe-preview! buf))))

(define-command "notmuch-last-thread" "Jump to the oldest listed thread"
  (lambda ()
    (let* ((buf (current-buffer)) (n (length (list-entries buf))))
      (when (> n 0) (list-goto-index! buf (- n 1)))
      (nm--maybe-preview! buf))))

(define-command "notmuch-refresh" "Re-run the search and refresh the listing"
  (lambda () (nm--refresh! (current-buffer)) (message "Refreshed")))

(define-command "notmuch-search" "Prompt for a notmuch query and show it"
  (lambda ()
    (let ((buf (current-buffer)))
      (minibuffer-read "Notmuch search: " '()
        (lambda (q)
          (nm--query-reset! buf q)
          (nm--refresh! buf)
          (list-goto-first-entry buf))))))

;;; --- tagging ------------------------------------------------------------------

(define (nm--goto-index! buf i) (list-goto-index! buf i))

;; tag, refresh, stay at the same list INDEX — when the change removes the
;; row (archive/trash on an inbox view) that index IS the next thread —
;; then the shown mail follows
(define (nm--tag! buf changes &optional skip-preview)
  (let ((th (nm--thread-at buf)) (i (nm--index-at buf)))
    (if th
        (begin
          (nm--run (string-append "tag " changes " -- thread:" (nm--th-id th)))
          (nm--refresh! buf)
          (let ((n (length (list-entries buf))))
            (when (and i (> n 0)) (nm--goto-index! buf (min i (- n 1)))))
          (unless skip-preview (nm--maybe-preview! buf))
          (message
            (if (and (equal? changes "-inbox")
                     (member (nm--th-id th) (map nm--th-id (list-entries buf))))
                "Archive: this search also includes mail outside the inbox"
                changes)))
        (message "No thread on this line"))))

;; A mark is a standing instruction, so the verb obeys the marks while
;; there are any and the row under point when there are none. The reader
;; learns one key for archiving, and the footer says which set it means.
(define-command "notmuch-archive" "Archive the marked threads, or the thread at point (-inbox)"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (nm--any-marked? buf)
          (nm--confirm-marked buf "Archive" "-inbox")
          (nm--tag! buf "-inbox")))))
(define-command "notmuch-trash" "Trash the marked threads, or the thread at point (+trash -inbox -unread)"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (nm--any-marked? buf)
          (nm--confirm-marked buf "Trash" "+trash -inbox -unread")
          (nm--tag! buf "+trash -inbox -unread")))))
(catalog-meta! 'command "notmuch-trash" 'domain 'mail 'effects '(destroy))

(define-command "notmuch-toggle-unread" "Toggle the unread tag on the thread at point"
  (lambda ()
    (let* ((buf (current-buffer)) (th (nm--thread-at buf)))
      (if th
          ;; Reading a preview clears unread. An explicit toggle must
          ;; keep its new state instead of immediately reading it again.
          (nm--tag! buf (if (member "unread" (nm--th-tags th)) "-unread" "+unread") #t)
          (message "No thread on this line")))))

;; on a plain tag:X search, u strips that tag from the thread — inbox zero
;; as a single keystroke on any tag view
(define-command "notmuch-smart-untag" "Remove the searched-for tag from this thread"
  (lambda ()
    (let* ((buf (current-buffer))
           (query (nm--query-of buf))
           (th (nm--thread-at buf)))
      (cond ((not th) (message "No thread on this line"))
            ((and (string-prefix? "tag:" query)
                  (not (string-contains? query " ")))
             (nm--tag! buf (string-append "-" (substring query 4 (string-length query)))))
            (else (message "Not a simple tag: search"))))))

(define-command "notmuch-edit-tags" "Edit tags of the thread at point (+tag -tag ...)"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (nm--thread-at buf)
          (minibuffer-read "Tags (+add -remove): " '()
            (lambda (changes) (nm--tag! buf changes)))
          (message "No thread on this line")))))

;; every tag in the database — the completion source for +
(define (nm--all-tags)
  (filter (lambda (t) (not (equal? t "")))
          (string-split (string-trim (nm--run "search --output=tags --exclude=false -- '*'")) "\n")))

;; Only offer tags that occur in the current result. The menu cannot lead
;; from a useful inbox view to an empty result through an unrelated tag.
(define (nm--query-tags buf)
  (filter (lambda (t) (not (equal? t "")))
          (string-split
            (string-trim
              (nm--run (string-append "search --output=tags -- "
                                      (nm--quote (nm--query-of buf)))))
            "\n")))

(define-command "notmuch-add-tag" "Add a tag to marked threads, or the thread at point (completes)"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (or (nm--any-marked? buf) (nm--thread-at buf))
          (minibuffer-read "Add tag: " (nm--all-tags)
            (lambda (tag)
              (unless (equal? (string-trim tag) "")
                (if (nm--any-marked? buf)
                    (nm--tag-marked! buf (nm--quote (string-append "+" (string-trim tag))))
                    (nm--tag! buf (nm--quote (string-append "+" (string-trim tag))))))))
          (message "No thread on this line")))))

(catalog-meta! 'command "notmuch-add-tag" 'domain 'mail 'effects '(write external execute))

(define-command "notmuch-remove-tag" "Remove a tag from marked threads, or the thread at point (completes)"
  (lambda ()
    (let* ((buf (current-buffer)) (th (nm--thread-at buf))
           (marked? (nm--any-marked? buf)))
      (if (or marked? th)
          (minibuffer-read "Remove tag: "
            (if marked? (nm--marked-tags buf) (nm--th-tags th))
            (lambda (tag)
              (unless (equal? (string-trim tag) "")
                (if (nm--any-marked? buf)
                    (nm--tag-marked! buf (nm--quote (string-append "-" (string-trim tag))))
                    (nm--tag! buf (nm--quote (string-append "-" (string-trim tag))))))))
          (message "No thread on this line")))))
(catalog-meta! 'command "notmuch-remove-tag" 'domain 'mail 'effects '(write external execute))
;; Archive drops one tag and trash swaps three. This is the blunt one:
;; after it the thread answers to no tag: search at all, so it names the
;; tags it is about to take and asks first.
;; Archive drops one tag and trash swaps three. This is the blunt one:
;; notmuch's own --remove-all takes them all, whatever they are. (`-*` is
;; the tag-file spelling of that wildcard; on the command line it reads as
;; a literal tag named * and quietly does nothing.) After it the thread
;; answers to no tag: search at all, so it asks first.
(define-command "notmuch-remove-all-tags" "Remove every tag from the marked threads, or the thread at point"
  (lambda ()
    (let* ((buf (current-buffer)) (th (nm--thread-at buf))
           (marked? (nm--any-marked? buf)))
      (if (not (or marked? th))
          (message "No thread on this line")
          (minibuffer-read
            (if marked?
                "Remove all tags from the marked threads? "
                (string-append "Remove all tags (" (string-join (nm--th-tags th) " ") ")? "))
            (list "yes" "no")
            (lambda (ans)
              (if (equal? ans "yes")
                  (if marked?
                      (nm--tag-marked! buf "--remove-all")
                      (nm--tag! buf "--remove-all"))
                  (message "Cancelled"))))))))
(catalog-meta! 'command "notmuch-remove-all-tags" 'domain 'mail 'effects '(destroy))
;; Autotag: the mailbox's own tag list is the label set. The model reads one
;; thread and picks from that list, so it cannot invent a folder. The state tags
;; (inbox, unread, replied) are not on offer, and nothing is ever removed, so a
;; classification can only add tags this mailbox already uses.
(defcustom 'notmuch-autotag-exclude
  '("inbox" "unread" "attachment" "signed" "encrypted" "draft" "sent"
    "replied" "trash" "flagged" "compos-mark")
  "Tags notmuch-autotag never offers. These say delivery state, not subject.")

(defcustom 'notmuch-autotag-limit 6000
  "How much of a thread's text notmuch-autotag sends to the model.")

(define (nm--autotag-vocabulary)
  (filter (lambda (t) (not (member t notmuch-autotag-exclude))) (nm--all-tags)))

(define (nm--thread-tags id)
  (filter (lambda (t) (not (equal? t "")))
    (string-split
      (string-trim (nm--run (string-append "search --output=tags -- thread:" id)))
      "\n")))

(define (nm--uniq lst)
  (let loop ((l lst) (acc '()))
    (cond ((null? l) (reverse acc))
          ((member (car l) acc) (loop (cdr l) acc))
          (else (loop (cdr l) (cons (car l) acc))))))

(define (nm--autotag-prompt id vocab)
  (string-append
    "Classify one email thread for a mail client.\n\n"
    "These are the only tags you may use:\n" (string-join vocab ", ") "\n\n"
    "Pick every tag that tells the truth about this thread. Copy each tag "
    "exactly. Do not invent a tag. Pick nothing rather than a tag that only "
    "nearly fits.\n\n"
    "Answer with the tags on one line, separated by commas. Answer NONE when no "
    "tag fits. Write no other words.\n\n"
    "--- thread ---\n"
    (nm--trunc (mail-read-thread id) notmuch-autotag-limit)))

(define (nm--autotag-word s)
  (let* ((s (string-trim s))
         (s (if (and (> (string-length s) 1)
                     (member (substring s 0 1) '("-" "*" "+")))
                (string-trim (substring s 1 (string-length s)))
                s)))
    (string-join (string-split s "\"") "")))

(define (nm--autotag-words reply)
  ;; The answer is one line of commas when the model obeys, and a bullet list or
  ;; a sentence when it does not. Both cut into candidate words the same way.
  (let loop ((lines (string-split (string-trim reply) "\n")) (acc '()))
    (if (null? lines)
        (reverse acc)
        (loop (cdr lines)
              (append (reverse (map nm--autotag-word (string-split (car lines) ",")))
                      acc)))))

(define (nm--autotag-choose reply vocab)
  (nm--uniq (filter (lambda (t) (member t vocab)) (nm--autotag-words reply))))

(define (nm--autotag-thread-id line)
  (if (and (>= (string-length line) 7) (equal? (substring line 0 7) "thread:"))
      (substring line 7 (string-length line))
      line))

(define (nm--autotag-targets buf)
  (if (nm--any-marked? buf)
      (map nm--autotag-thread-id
           (filter (lambda (l) (not (equal? l "")))
             (string-split
               (string-trim (nm--run (string-append "search --output=threads -- "
                                       (nm--quote (nm--marked-query buf)))))
               "\n")))
      (let ((th (nm--thread-at buf))) (if th (list (nm--th-id th)) '()))))

(define (nm--autotag-one! id vocab k)
  ;; K gets the tags this thread actually gained, so the caller reports a real
  ;; change and never a blind \"done\".
  (llm (nm--autotag-prompt id vocab)
    (lambda (reply)
      (let* ((have (nm--thread-tags id))
             (new (filter (lambda (t) (not (member t have)))
                          (nm--autotag-choose reply vocab))))
        (unless (null? new)
          (nm--run (string-append "tag "
                     (string-join
                       (map (lambda (t) (nm--quote (string-append "+" t))) new) " ")
                     " -- thread:" id)))
        (k new)))))

(define (nm--autotag-run! buf ids vocab added)
  ;; One thread at a time: the model call is the slow part, and a queue of them
  ;; would spend on threads the user can no longer see going wrong.
  (if (null? ids)
      (begin
        (nm--refresh! buf)
        (message (if (null? added)
                     "Autotag: no tag fits"
                     (string-append "Autotag: "
                       (string-join (map (lambda (t) (string-append "+" t))
                                         (nm--uniq added)) " ")))))
      (begin
        (message (string-append "Autotag: " (number->string (length ids)) " to go"))
        (nm--autotag-one! (car ids) vocab
          (lambda (new)
            (nm--autotag-run! buf (cdr ids) vocab (append added new)))))))

(define-command "notmuch-autotag"
  "Classify the marked threads, or the thread at point, with this mailbox's own tags"
  (lambda ()
    (let* ((buf (current-buffer))
           (vocab (nm--autotag-vocabulary))
           (ids (nm--autotag-targets buf)))
      (cond ((null? ids) (message "No thread on this line"))
            ((null? vocab) (message "This mailbox has no tags to classify with"))
            (else (nm--autotag-run! buf ids vocab '()))))))
(catalog-meta! 'command "notmuch-autotag" 'domain 'mail
               'effects '(write external execute spend))



;;; --- jump & filter ---------------------------------------------------------------

;; ((key name query) ...) — personal jump table, set in init.scm; empty
;; falls back to the saved searches by name
(define notmuch-jump-searches '())

(define-command "notmuch-jump" "Jump to a saved search (j, then its key)"
  (lambda ()
    (if (null? notmuch-jump-searches)
        (let ((ss (nm--saved-searches)))
          (minibuffer-read "Jump: "
            (map (lambda (s) (list (car s) (cadr s))) ss)
            (lambda (name)
              (let ((e (assoc name ss)))
                (when e (nm--open-index! (cadr e)))))))
        (minibuffer-read "Jump: "
          (map (lambda (s) (list (car s) (string-append (cadr s) " · " (caddr s))))
               notmuch-jump-searches)
          (lambda (key)
            (let ((e (assoc key notmuch-jump-searches)))
              (when e (nm--open-index! (caddr e)))))))))

(define-command "notmuch-filter" "Narrow this search with more terms (and)"
  (lambda ()
    (let ((buf (current-buffer)))
      (minibuffer-read "Filter (and): " '()
        (lambda (terms)
          (let ((term (string-trim terms)))
            (unless (equal? term "")
              (nm--query-push! buf term)
              (nm--refresh! buf)
              (list-goto-first-entry buf))))))))

(domain! 'mail)
(effects! '(write external execute))

(define-command "notmuch-filter-by-tag"
  "Choose a tag from the current results and add it to this search"
  (lambda ()
    (let* ((buf (current-buffer))
           (tags (nm--query-tags buf)))
      (if (null? tags)
          (message "No tags occur in this search")
          (minibuffer-read "Add tag filter: " tags
            (lambda (choice)
              (let ((tag (string-trim choice)))
                (unless (equal? tag "")
                  (nm--query-push! buf (string-append "tag:" tag))
                  (nm--refresh! buf)
                  (list-goto-first-entry buf)
                  (message (string-append "Added tag filter: " tag))))))))))

(effects! '(unknown))

(define-command "notmuch-unfilter-last" "Remove the most recently added notmuch filter"
  (lambda ()
    (let* ((buf (current-buffer))
           (positions (or (buffer-local buf 'notmuch-query-positions) '()))
           (i (if (null? positions) #f (car positions))))
      (if (not (nm--query-pop! buf))
          (message "No structured notmuch filters to remove")
          (begin
            (nm--refresh! buf)
            (let ((n (length (list-entries buf))))
              (when (and i (> n 0))
                (nm--goto-index! buf (min i (- n 1)))))
            (message "Removed last notmuch filter"))))))

(define-command "notmuch-back" "Remove the last mail filter, or return to mailboxes"
  (lambda ()
    (if (pair? (nm--query-filters-of (current-buffer)))
        (run-command "notmuch-unfilter-last")
        (run-command "notmuch"))))
(catalog-meta! 'command "notmuch-back" 'domain 'mail 'effects '(write external execute))

(define-command "notmuch-filter-by-sender" "Narrow the search to this thread's sender"
  (lambda ()
    (let* ((buf (current-buffer)) (th (nm--thread-at buf)))
      (if (not th)
          (message "No thread on this line")
          (let* ((msgs (nm--flatten-msgs
                         (or (nm--json (string-append "show --format=json --body=false thread:"
                                                      (nm--th-id th)))
                             '())))
                 (from (if (null? msgs)
                           ""
                           (or (nm--get (nm--get (car msgs) 'headers) 'From) "")))
                 (email (let ((parts (string-split from "<")))
                          (if (null? (cdr parts))
                              (string-trim from)
                              (car (string-split (cadr parts) ">"))))))
            (if (equal? email "")
                (message "Could not extract the sender")
                (begin
                  (nm--query-push-only! buf (string-append "from:" email))
                  (nm--refresh! buf)
                  (list-goto-first-entry buf)
                  (message (string-append "from:" email)))))))))

(define-command "notmuch-delete-all-from-sender"
  "Trash every message in the mailbox from this thread's sender (works on a *notmuch* list row or an open notmuch-show buffer)"
  (lambda ()
    (let* ((buf (current-buffer))
           (thread-id (if (buffer-derived-mode? buf "notmuch-show-mode")
                          (buffer-local buf 'notmuch-thread)
                          (let ((th (nm--thread-at buf))) (and th (nm--th-id th))))))
      (if (not thread-id)
          (message "No thread here")
          (let* ((msgs (nm--flatten-msgs
                         (or (nm--json (string-append "show --format=json --body=false thread:" thread-id))
                             '())))
                 (from (if (null? msgs)
                           ""
                           (or (nm--get (nm--get (car msgs) 'headers) 'From) "")))
                 (email (let ((parts (string-split from "<")))
                          (if (null? (cdr parts))
                              (string-trim from)
                              (car (string-split (cadr parts) ">"))))))
            (if (equal? email "")
                (message "Could not extract the sender")
                (let ((n (nm--count (string-append "from:" email))))
                  (nm--run (string-append "tag +trash -inbox -unread -- " (nm--quote (string-append "from:" email))))
                  (when (buffer-exists? *notmuch-search-buffer*)
                    (nm--refresh! *notmuch-search-buffer*))
                  (message (string-append "trashed " (number->string n) " message"
                                          (if (= n 1) "" "s") " from " email)))))))))
(catalog-meta! 'command "notmuch-delete-all-from-sender" 'domain 'mail 'effects '(destroy))

(define (nm--contains? haystack needle)
  (> (length (string-split (string-downcase haystack) (string-downcase needle))) 1))

(define (nm--looks-unsubscribed? html)
  (or (nm--contains? html "unsubscribed")
      (nm--contains? html "successfully removed")
      (nm--contains? html "been removed")
      (nm--contains? html "you're unsubscribed")
      (nm--contains? html "miss you")
      (nm--contains? html "no longer receive")))

;; RFC 2369/8058: List-Unsubscribe (and List-Unsubscribe-Post for the
;; one-click POST variant) are plain header text, never quoted-printable —
;; decoding them would corrupt hash params like "u=80fc49..." that happen
;; to look like =XX escapes. Read them raw; only the body fallback below
;; needs QP decoding, and only as a last resort for senders with no header.
(define (nm--unsubscribe-header-links msg-id)
  (let* ((hdr (string-trim (nm--run (string-append
                 "show --format=raw -- " (nm--quote (string-append "id:" msg-id))
                 " | grep -i '^list-unsubscribe:' | head -1"))))
         (post (string-trim (nm--run (string-append
                 "show --format=raw -- " (nm--quote (string-append "id:" msg-id))
                 " | grep -i '^list-unsubscribe-post:' | head -1"))))
         (https (let ((m (string-trim (shell-command->string
                    (string-append "printf '%s' " (nm--quote hdr)
                                   " | grep -oE '<https?://[^>]*>' | head -1")
                    (default-directory)))))
                  (if (equal? m "") #f (substring m 1 (- (string-length m) 1)))))
         (mailto (let ((m (string-trim (shell-command->string
                    (string-append "printf '%s' " (nm--quote hdr)
                                   " | grep -oE '<mailto:[^>]*>' | head -1")
                    (default-directory)))))
                   (if (equal? m "") #f (substring m 1 (- (string-length m) 1)))))
         (one-click? (nm--contains? post "one-click")))
    (list https mailto one-click?)))

;; last resort when there's no List-Unsubscribe header at all: naive
;; whole-message quoted-printable decode, then hunt for an "unsubscribe"
;; link in the body. No real MIME parsing, so it can find the wrong link
;; or nothing on an oddly-encoded message — acceptable as a fallback only.
(define (nm--unsubscribe-body-link msg-id)
  (let* ((cmd (string-append
                "show --format=raw -- " (nm--quote (string-append "id:" msg-id))
                " | perl -MMIME::QuotedPrint -0777 -ne '"
                "my $raw = $_; my $dec = eval { decode_qp($raw) }; $dec = $raw unless defined $dec; "
                "if ($dec =~ /(https?:\\/\\/[^\\s\"\\x27<>]*unsubscribe[^\\s\"\\x27<>]*)/i) { print \"$1\\n\"; exit } "
                "if ($raw =~ /(https?:\\/\\/[^\\s\"\\x27<>]*unsubscribe[^\\s\"\\x27<>]*)/i) { print \"$1\\n\"; exit }'"))
         (out (string-trim (nm--run cmd))))
    (if (equal? out "") #f out)))

(define (nm--curl-text url)
  (shell-command->string (string-append "curl -sL --max-time 15 " (nm--quote url)) (default-directory)))

(define (nm--purge-unsubscribe! msg-id)
  (let* ((links (and msg-id (nm--unsubscribe-header-links msg-id)))
         (https (and links (car links)))
         (mailto (and links (cadr links)))
         (one-click? (and links (caddr links))))
    (cond
      ((and https one-click?)
       (let ((code (string-trim (shell-command->string
                      (string-append "curl -sL --max-time 15 -X POST "
                                     "-H 'Content-Type: application/x-www-form-urlencoded' "
                                     "-d 'List-Unsubscribe=One-Click' -o /dev/null -w '%{http_code}' "
                                     (nm--quote https))
                      (default-directory)))))
         (if (member code '("200" "202" "204"))
             (string-append "unsubscribed (RFC 8058 one-click, " code ")")
             (string-append "tried the one-click unsubscribe but got HTTP " code " — check by hand: " https))))
      (https
       (if (nm--looks-unsubscribed? (nm--curl-text https))
           "unsubscribed (confirmed)"
           (string-append "visited " https " but couldn't confirm — check by hand")))
      (mailto
       (string-append "unsubscribe is by email only, not sent: " mailto))
      (else
        (let ((body-link (and msg-id (nm--unsubscribe-body-link msg-id))))
          (cond
            ((not body-link) "no unsubscribe link found")
            ((nm--looks-unsubscribed? (nm--curl-text body-link))
             "unsubscribed (found in body, confirmed)")
            (else (string-append "found a possible link in the body but couldn't confirm — check by hand: " body-link))))))))

(define-command "notmuch-purge-sender"
  "Trash every message from this thread's sender and try to unsubscribe: RFC 8058 one-click POST when offered, else a plain GET, else a best-effort scan of the body (works on a *notmuch* list row or an open notmuch-show buffer)"
  (lambda ()
    (let* ((buf (current-buffer))
           (thread-id (if (buffer-derived-mode? buf "notmuch-show-mode")
                          (buffer-local buf 'notmuch-thread)
                          (let ((th (nm--thread-at buf))) (and th (nm--th-id th))))))
      (if (not thread-id)
          (message "No thread here")
          (let* ((msgs (nm--flatten-msgs
                         (or (nm--json (string-append "show --format=json --body=false thread:" thread-id))
                             '())))
                 (from (if (null? msgs)
                           ""
                           (or (nm--get (nm--get (car msgs) 'headers) 'From) "")))
                 (email (let ((parts (string-split from "<")))
                          (if (null? (cdr parts))
                              (string-trim from)
                              (car (string-split (cadr parts) ">"))))))
            (if (equal? email "")
                (message "Could not extract the sender")
                (let* ((n (nm--count (string-append "from:" email)))
                       (msg-id (nm--newest-msg-id thread-id))
                       (verdict (nm--purge-unsubscribe! msg-id)))
                  (nm--run (string-append "tag +trash -inbox -unread -- " (nm--quote (string-append "from:" email))))
                  (when (buffer-exists? *notmuch-search-buffer*)
                    (nm--refresh! *notmuch-search-buffer*))
                  (message (string-append "trashed " (number->string n) " message"
                                          (if (= n 1) "" "s") " from " email "; " verdict)))))))))
(catalog-meta! 'command "notmuch-purge-sender" 'domain 'mail 'effects '(destroy external))

(define-command "notmuch-unsubscribe"
  "Try to unsubscribe from this thread's sender without deleting anything: RFC 8058 one-click POST when offered, else a plain GET, else a best-effort scan of the body (works on a *notmuch* list row or an open notmuch-show buffer)"
  (lambda ()
    (let* ((buf (current-buffer))
           (thread-id (if (buffer-derived-mode? buf "notmuch-show-mode")
                          (buffer-local buf 'notmuch-thread)
                          (let ((th (nm--thread-at buf))) (and th (nm--th-id th))))))
      (if (not thread-id)
          (message "No thread here")
          (let* ((msgs (nm--flatten-msgs
                         (or (nm--json (string-append "show --format=json --body=false thread:" thread-id))
                             '())))
                 (from (if (null? msgs)
                           ""
                           (or (nm--get (nm--get (car msgs) 'headers) 'From) "")))
                 (email (let ((parts (string-split from "<")))
                          (if (null? (cdr parts))
                              (string-trim from)
                              (car (string-split (cadr parts) ">"))))))
            (if (equal? email "")
                (message "Could not extract the sender")
                (let* ((msg-id (nm--newest-msg-id thread-id))
                       (verdict (nm--purge-unsubscribe! msg-id)))
                  (message (string-append email ": " verdict)))))))))
(catalog-meta! 'command "notmuch-unsubscribe" 'domain 'mail 'effects '(write external))

;; Filing for the agent: `+liked` marks a thread as worth keeping and takes it
;; out of the inbox. The tag is the whole record, so any agent query can read it
;; back later with tag:liked.
(define-command "notmuch-like"
  "File this thread for the agent (+liked -inbox): the marked threads on a list row, or the thread at point, or the open thread"
  (lambda ()
    (let ((buf (current-buffer)))
      (cond
        ((buffer-derived-mode? buf "notmuch-show-mode")
         (let ((th (buffer-local buf 'notmuch-thread)))
           (if (not th)
               (message "No thread here")
               (begin
                 (nm--run (string-append "tag +liked -inbox -- thread:" th))
                 (when (buffer-exists? *notmuch-search-buffer*)
                   (nm--refresh! *notmuch-search-buffer*))
                 (message "Liked")))))
        ((nm--any-marked? buf) (nm--confirm-marked buf "Like" "+liked -inbox"))
        (else (nm--tag! buf "+liked -inbox"))))))

(catalog-meta! 'command "notmuch-like" 'domain 'mail 'effects '(write))

 ;;; --- local selection ---------------------------------------------------------

;; Selection is an editor operation, never a mail tag. ALL selects the query;
;; IDS then excludes individual threads. Otherwise IDS names selected threads.
;; The query is evaluated when the mail action runs, including unseen results.
(define (nm--selection buf)
  (let ((s (buffer-local buf 'notmuch-selection)))
    (if (and s (equal? (car s) (nm--db-key))
               (equal? (cadr s) (nm--query-of buf)))
        s
        (begin (buffer-set-local! buf 'notmuch-selection #f) #f))))

(define (nm--set-selection! buf all? ids)
  (desktop-skip! buf 'notmuch-selection)
  (buffer-set-local! buf 'notmuch-selection
    (list (nm--db-key) (nm--query-of buf) all? ids)))

(define (nm--row-marked? buf th)
  (let ((s (nm--selection buf)))
    (and s (if (caddr s)
               (not (member (nm--th-id th) (list-ref s 3)))
               (if (member (nm--th-id th) (list-ref s 3)) #t #f)))))

(define (nm--any-marked? buf)
  (let ((s (nm--selection buf)))
    (and s (or (caddr s) (pair? (list-ref s 3))))))

(define (nm--draw-marks! buf rows)
  (buffer-set-local! buf 'list-marks
    (map (lambda (th) (list (nm--th-id th) *list-mark-char*))
         (filter (lambda (th) (nm--row-marked? buf th)) rows))))

(define (nm--redraw-marks! buf)
  (nm--draw-marks! buf (list-entries buf))
  ;; Plain list redraws fetch their source. Cached rendering keeps the rows,
  ;; exact count, point, and preview, with no external command.
  (when (pair? (list-entries buf)) (list-render! buf 'cached)))

(define (nm--marked-query buf)
  (let* ((s (nm--selection buf))
         (ids (if s (list-ref s 3) '()))
         (threads (string-join (map (lambda (id) (string-append "thread:" id)) ids) " or ")))
    (if (not (nm--any-marked? buf))
        "tag:inbox and not tag:inbox"
        (string-append "( " (cadr s) " )"
          (if (null? ids) ""
              (string-append (if (caddr s) " and not ( " " and ( ") threads " )"))))))

(define (nm--marked-tags buf)
  (filter (lambda (tag) (not (equal? tag "")))
    (string-split (string-trim
      (nm--run (string-append "search --output=tags -- " (nm--quote (nm--marked-query buf)))))
      "\n")))

(define (nm--tag-marked! buf changes)
  (if (not (nm--any-marked? buf))
      (message "No selected messages")
      (begin
        (nm--run (string-append "tag " changes " -- " (nm--quote (nm--marked-query buf))))
        ;; Keep the local selection across the refresh. The selected thread IDs
        ;; remain valid even when their displayed tags change.
        (nm--refresh! buf))))

(define (nm--toggle-selection! buf id)
  (let* ((s (nm--selection buf))
         (ids (if s (list-ref s 3) '())))
    (nm--set-selection! buf (and s (caddr s))
      (if (member id ids)
          (filter (lambda (other) (not (equal? other id))) ids)
          (cons id ids)))
    (nm--redraw-marks! buf)))

(define-command "notmuch-mark-toggle" "Toggle local selection of this thread, move down"
  (lambda ()
    (let* ((buf (current-buffer)) (th (nm--thread-at buf)))
      (if th
          (begin (nm--toggle-selection! buf (nm--th-id th)) (list-move-in! buf 1))
          (message "No thread on this line")))))

(define-command "notmuch-mark-all" "Select the entire filtered inbox or search locally; again clears selection"
  (lambda ()
    (let* ((buf (current-buffer)) (unmark? (nm--any-marked? buf)))
      (cond
        (unmark?
          (buffer-set-local! buf 'notmuch-selection #f)
          (nm--redraw-marks! buf)
          (message "Unmarked all"))
        ((and (or (equal? (nm--query-base-of buf) "tag:inbox")
                  (equal? (nm--query-base-of buf) notmuch-default-query))
              (null? (nm--query-filters-of buf)))
          (message "Add a filter before selecting all inbox messages"))
        ((null? (list-entries buf)) (message "No messages to select"))
        (else
          (nm--set-selection! buf #t '())
          (nm--redraw-marks! buf)
          (message "Selected entire search"))))))

(define-command "notmuch-unmark-all" "Clear local mail selection"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-local! buf 'notmuch-selection #f)
      (nm--redraw-marks! buf)
      (message "Unmarked all"))))

(define-command "notmuch-filter-marked" "Open the selected messages as a search"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (not (nm--any-marked? buf))
          (message "No selected messages")
          (begin
            (nm--query-push-only! buf (nm--marked-query buf))
            (nm--refresh! buf)
            (list-goto-first-entry buf))))))

(for-each (lambda (name)
            (catalog-meta! 'command name 'domain 'mail 'effects '(read write display)))
  '("notmuch-mark-toggle" "notmuch-mark-all" "notmuch-unmark-all"))

(define (nm--confirm-marked buf verb changes)
  (minibuffer-read (string-append verb " all marked threads? ")
    (list "yes" "no")
    (lambda (ans)
      (if (equal? ans "yes")
          (begin (nm--tag-marked! buf changes) (message "Done"))
          (message "Cancelled")))))

(define-command "notmuch-archive-marked" "Archive all marked threads"
  (lambda () (nm--confirm-marked (current-buffer) "Archive"
                        "-inbox")))
(define-command "notmuch-trash-marked" "Trash all marked threads"
  (lambda () (nm--confirm-marked (current-buffer) "Trash"
                        "+trash -inbox -unread")))

(define-command "notmuch-tag-marked" "Apply tag changes to all marked threads"
  (lambda ()
    (let ((buf (current-buffer)))
      (minibuffer-read "Tag marked (+add -remove): " '()
        (lambda (changes) (nm--tag-marked! buf changes) (message changes))))))

;;; --- thread (show) buffer -------------------------------------------------------

(define (nm--attachment-parts parts)
  (fold (lambda (acc part)
          (append acc
            (cond ((and (nm--get part 'filename) (number? (nm--get part 'id))) (list part))
                  ((pair? (nm--get part 'content))
                   (nm--attachment-parts (nm--get part 'content)))
                  (else '()))))
        '() parts))

(define (nm--attachment-text msg)
  (let ((parts (nm--attachment-parts (nm--get msg 'body))))
    (if (null? parts) ""
        (string-append "Attachments (C-c a to open):\n"
          (string-join (map (lambda (p) (string-append "  " (nm--get p 'filename))) parts) "\n")
          "\n\n"))))

(define (nm--attachment-html msg)
  (let ((parts (nm--attachment-parts (nm--get msg 'body))))
    (if (null? parts) ""
        (string-append "<mail-attachments><strong>Attachments</strong>"
          (string-join (map (lambda (p)
                             (string-append "<mail-attachment part-id=\"" (number->string (nm--get p 'id)) "\">" (nm--html-escape (nm--get p 'filename)) "</mail-attachment>"))
                           parts) "")
          "<small>C-c a to open an attachment</small></mail-attachments>"))))

;; Capture the full fetch command while this message's account is active.
;; The user can switch accounts while the attachment picker is open.
(define (nm--attachment-options msgs)
  (fold (lambda (acc msg)
          (append acc
            (map (lambda (part)
                   (list (nm--get part 'filename)
                         (nm--cmd (string-append "show --format=raw --part="
                           (number->string (nm--get part 'id)) " -- "
                           (nm--quote (string-append "id:" (nm--get msg 'id)))))))
                 (nm--attachment-parts (nm--get msg 'body)))))
        '() msgs))

(define (nm--attachment-filename name)
  (let ((base (car (reverse (string-split
                             (string-join (string-split name "\\") "/") "/")))))
    (if (member base '("" "." "..")) "attachment" base)))

(define (nm--open-attachment! attachment)
  (let* ((root (string-append (compos-home) "/attachments")))
    (make-directory! root)
    (let ((dir (string-trim (shell-command->string
                 (string-append "mktemp -d " (nm--quote (string-append root "/part-XXXXXX")))))))
      (if (not (string-prefix? (string-append root "/part-") dir))
          (message "Could not create an attachment directory")
          (let ((path (string-append dir "/" (nm--attachment-filename (car attachment)))))
            (message (string-append "Downloading " (car attachment) "…"))
            ;; Redirect bytes locally: binary attachments must never pass
            ;; through Scheme strings or text-buffer decoding.
            (shell-command->string
              (string-append (cadr attachment) " > " (nm--quote path) " && printf attachment-ok")
              (lambda (result)
                (if (equal? result "attachment-ok")
                    (visit path)
                    (begin
                      (when (file-exists? path) (delete-file! path))
                      (message "Attachment download failed"))))))))))

(define-command "notmuch-open-attachment" "Choose and open an attachment from the selected mail thread"
  (lambda ()
    (let* ((buf (current-buffer))
           (th (if (equal? buf *notmuch-search-buffer*)
                   (let ((row (nm--thread-at buf))) (and row (nm--th-id row)))
                   (buffer-local buf 'notmuch-thread)))
           (cached? (and (buffer-exists? *notmuch-show-buffer*)
                         (equal? th (buffer-local *notmuch-show-buffer* 'notmuch-thread))
                         (buffer-local *notmuch-show-buffer* 'nm-attachment-source)
                         (or (equal? buf *notmuch-show-buffer*)
                             (equal? (nm--db-key) (buffer-local *notmuch-show-buffer* 'nm-attachment-source)))))
           (attachments (if cached?
                            (or (buffer-local *notmuch-show-buffer* 'notmuch-attachments) '())
                            (if th (nm--attachment-options (nm--show-msgs th)) '())))
           (choices (let loop ((rest attachments) (i 1) (acc '()))
                      (if (null? rest) (reverse acc)
                          (loop (cdr rest) (+ i 1)
                            (cons (list (string-append (number->string i) ". " (car (car rest)))
                                        (car rest)) acc))))))
      (if (null? choices)
          (message "No attachments in this thread")
          (minibuffer-read "Open attachment: " (map car choices)
            (lambda (choice)
              (let ((hit (assoc choice choices)))
                (when hit (nm--open-attachment! (cadr hit))))))))))
(catalog-meta! 'command "notmuch-open-attachment" 'domain 'mail 'effects '(write external execute display))

;; Body text excludes attachments, which have their own visible list.
;; multipart/alternative prefers its text/plain child.
(define (nm--part-text part)
  (let ((ct (or (nm--get part 'content-type) ""))
        (content (nm--get part 'content)))
    (cond ((nm--get part 'filename) "")
          ((and (string-prefix? "multipart/alternative" ct) (pair? content))
           (let ((plains (filter (lambda (p)
                                   (string-prefix? "text/plain"
                                     (or (nm--get p 'content-type) "")))
                                 content)))
             (if (null? plains)
                 (nm--parts-text content)
                 (nm--part-text (car plains)))))
          ((pair? content) (nm--parts-text content))
          ((and (string-prefix? "text/plain" ct) (string? content)) content)
          ((and (string-prefix? "text/html" ct)) "")
          (else ""))))

(define (nm--parts-text parts)
  (fold (lambda (acc p) (string-append acc (nm--part-text p))) "" parts))

;; first text/html part's content, or #f
(define (nm--part-html part)
  (let ((ct (or (nm--get part 'content-type) ""))
        (content (nm--get part 'content)))
    (cond ((nm--get part 'filename) #f)
          ((and (string-prefix? "text/html" ct) (string? content)) content)
          ((pair? content) (nm--parts-html content))
          (else #f))))

(define (nm--parts-html parts)
  (let loop ((ps parts))
    (if (null? ps)
        #f
        (let ((h (nm--part-html (car ps))))
          (if h h (loop (cdr ps)))))))

;; notmuch show nests messages as [msg, [replies...]] pairs — flatten
(define (nm--flatten-msgs forest)
  (if (null? forest)
      '()
      (append
        (let ((entry (car forest)))
          (if (and (pair? entry) (nm--get (car entry) 'id))
              (cons (car entry) (nm--flatten-msgs (cadr entry)))
              (nm--flatten-msgs entry)))
        (nm--flatten-msgs (cdr forest)))))

(define (nm--show-msgs thread-id)
  (let ((msgs (nm--flatten-msgs
                (or (nm--json (string-append
                                "show --format=json --include-html thread:" thread-id))
                    '()))))
    (if notmuch-show-newest-first (reverse msgs) msgs)))

;; text body of one message; falls back to the html part through
;; notmuch-html-renderer when there is no text/plain
(define (nm--msg-body-text msg)
  (let ((plain (nm--parts-text (nm--get msg 'body))))
    (if (equal? (string-trim plain) "")
        (let ((html (nm--parts-html (nm--get msg 'body))))
          (if html (nm--html->text html) plain))
        plain)))

(define (nm--msg-render msg)
  (let ((h (nm--get msg 'headers)))
    (string-append
      "From: " (or (nm--get h 'From) "") "\n"
      "Date: " (or (nm--get h 'Date) "") "\n"
      (let ((to (nm--get h 'To)))
        (if to (string-append "To: " to "\n") ""))
      "\n"
      (nm--attachment-text msg)
      (nm--msg-body-text msg)
      "\n")))

;; -> (text ((byte-offset id filename) ...))
(define (nm--render-text subject msgs)
  (if (null? msgs)
      (list "" '())
      (let loop ((ms msgs) (n 1)
                 (text (string-append subject "\n"))
                 (offsets '()))
        (if (null? ms)
            (list text (reverse offsets))
            (let ((header (string-append
                            "\n── message " (number->string n) " of "
                            (number->string (length msgs)) " ──\n")))
              (loop (cdr ms) (+ n 1)
                    (string-append text header (nm--msg-render (car ms)))
                    (cons (list (string-byte-length text)
                                (nm--get (car ms) 'id)
                                (nm--get (car ms) 'filename))
                          offsets)))))))

;; the whole thread as one HTML document for the sandboxed iframe:
;; our headers, their bodies (plain text becomes <pre>)
(define (nm--msg-html msg)
  (let* ((h (nm--get msg 'headers))
         (html (nm--parts-html (nm--get msg 'body)))
         (body (or html
                   (string-append "<pre style=\"white-space:pre-wrap;font:inherit\">"
                                  (nm--html-escape (nm--parts-text (nm--get msg 'body)))
                                  "</pre>"))))
    (string-append
      "<mail-message message-id=\"" (nm--html-escape (or (nm--get msg 'id) "")) "\">"
      "<header><mail-from>" (nm--html-escape (or (nm--get h 'From) "")) "</mail-from> · "
      "<mail-date>" (nm--html-escape (or (nm--get h 'Date) "")) "</mail-date>"
      (let ((to (nm--get h 'To)))
        (if to (string-append " · to <mail-to>" (nm--html-escape to) "</mail-to>") ""))
      "</header>" (nm--attachment-html msg) "<mail-body>" body "</mail-body></mail-message>")))

(define (nm--thread-html subject msgs)
  (string-append
    "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>"
    (nm--html-escape subject)
    "</title><style>mail-thread,mail-message,mail-body,mail-attachments,mail-attachment{display:block}"
    "mail-message>header{border-top:1px solid #d0c8b8;margin-top:14px;padding:6px 0;font:12px system-ui;color:#666}"
    "mail-from{font-weight:bold}mail-subject{display:block;font:600 15px system-ui}</style></head>"
    "<body style=\"margin:14px;font-family:system-ui\"><mail-thread>"
    "<mail-subject>" (nm--html-escape subject) "</mail-subject>"
    (fold (lambda (acc m) (string-append acc (nm--msg-html m))) "" msgs)
    "</mail-thread></body></html>"))

;; The plain-text view keeps the text buffer's message offsets for commands,
;; but renders records rather than asking the client to infer mail from lines.
(define (nm--msg-composml msg)
  (let ((h (nm--get msg 'headers)))
    (list 'tag "mail-message" 'class "semantic-document-section"
          'attrs (list (list "message-id" (or (nm--get msg 'id) "")))
          'children
          (list (nm--field "mail-from" (or (nm--get h 'From) ""))
                (nm--field "mail-date" (or (nm--get h 'Date) ""))
                (nm--field "mail-to" (or (nm--get h 'To) ""))
                (list 'tag "mail-attachments" 'children
                      (map (lambda (part)
                             (list 'tag "mail-attachment"
                                   'attrs (list (list "part-id" (nm--get part 'id))
                                                (list "content-type" (or (nm--get part 'content-type) "")))
                                   'text (nm--get part 'filename)))
                           (nm--attachment-parts (nm--get msg 'body))))
                (list 'tag "mail-body" 'children
                      (list (list 'tag "pre" 'text (nm--msg-body-text msg))))))))

(define (nm--thread-composml! buf subject msgs offsets)
  (desktop-skip! buf 'render-blocks)
  (buffer-set-local! buf 'render-blocks
    (list (list 'tag "mail-thread" 'class "semantic-document"
                'attrs (list (list "record-id" (buffer-local buf 'notmuch-thread)))
                'children (cons (component 'ui/section (list 'title subject 'level 1))
                                (let loop ((ms msgs) (offsets offsets) (out '()))
                                  (if (null? ms) (reverse out)
                                    (let* ((start (car (car offsets)))
                                           (stop (if (pair? (cdr offsets)) (car (cadr offsets)) (buffer-size buf)))
                                           (first (length (string-split (substring-bytes (buffer-text buf) 0 start) "\n")))
                                           (last (length (string-split (substring-bytes (buffer-text buf) 0 stop) "\n"))))
                                      (loop (cdr ms) (cdr offsets)
                                        (cons (append (list 'anchor (string-append "message:" (url-encode (or (nm--get (car ms) 'id) "")))
                                                            'lines (list first (max first (- last 1)))
                                                            'mark "current-message")
                                                      (nm--msg-composml (car ms))) out)))))))))
  (buffer-set-local! buf 'render-mode "blocks"))

(define (nm--any-html? msgs)
  (let loop ((ms msgs))
    (cond ((null? ms) #f)
          ((nm--parts-html (nm--get (car ms) 'body)) #t)
          (else (loop (cdr ms))))))

(mode-doc! "notmuch-show-mode"
  "One mail thread, read. `a` archives it, `L` files it for the agent (+liked -inbox) and `r` starts a reply. `C-c a` opens an attachment. `v` changes between HTML and plain text. `q` goes back to the search.")

(mode-icon! "notmuch-show-mode" "")

(mode-parent! "notmuch-show-mode" "special-mode")
(define-mode "notmuch-show-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-read-only! buf #t)
      (when (and (boundp 'buffer-child!) (buffer-known? *notmuch-search-buffer*))
        (buffer-child! *notmuch-search-buffer* buf))
      (let ((th (buffer-local buf 'notmuch-thread)))
        (when th
          (let* ((subject (or (buffer-local buf 'notmuch-subject) ""))
                 (msgs (nm--show-msgs th))
                 (html? (and notmuch-prefer-html
                             (not (equal? (buffer-local buf 'notmuch-view) "text"))
                             (nm--any-html? msgs))))
            (desktop-skip! buf 'notmuch-attachments)
            (desktop-skip! buf 'nm-attachment-source)
            (buffer-set-local! buf 'notmuch-attachments (nm--attachment-options msgs))
            (buffer-set-local! buf 'nm-attachment-source (nm--db-key))
            (buffer-delete-range! buf 0 (buffer-size buf))
            (if html?
                (begin
                  (buffer-append! buf (nm--thread-html subject msgs))
                  (buffer-set-local! buf 'render-mode "html")
                  ;; authored colors assume a white canvas — by default the
                  ;; theme repaints the document instead (dark mode stays
                  ;; readable); customize notmuch-html-original-colors to
                  ;; get the untouched rendering back
                  (buffer-set-local! buf 'preview-authored
                    notmuch-html-original-colors)
                  ;; fake ascending offsets: point stays 0 in the html view,
                  ;; so "message at point" means the first (newest) message
                  (buffer-set-local! buf 'notmuch-msgs
                    (let loop ((ms msgs) (i 0) (acc '()))
                      (if (null? ms)
                          (reverse acc)
                          (loop (cdr ms) (+ i 1)
                                (cons (list i (nm--get (car ms) 'id)
                                            (nm--get (car ms) 'filename))
                                      acc))))))
                (let ((rendered (nm--render-text subject msgs)))
                  (buffer-append! buf (car rendered))
                  (nm--thread-composml! buf subject msgs (cadr rendered))
                  (buffer-set-local! buf 'notmuch-msgs (cadr rendered))))
            (goto-char! 0)))))))

(mode-keys! "notmuch-show-mode"
  '(
    ("a" "notmuch-show-archive")
    ("r" "notmuch-show-reply")
    ("v" "notmuch-show-toggle-view")
    ("L" "notmuch-like")
    ("j" "notmuch-jump")
    ("C-c a" "notmuch-open-attachment")
    ("A" "notmuch-open-attachment")
    ("q" "quit-window")))

;; ONE show buffer, reused — it is a view, not a document. The subject
;; lives in the modeline; 'special says so (the mode re-renders from
;; 'notmuch-thread on restore).
(define *notmuch-show-buffer* "*mail*")

(define (nm--open-thread! thread-id subject &rest opts)
  (let ((buf *notmuch-show-buffer*))
    (unless (buffer-exists? buf) (buffer-create buf))
    (buffer-set-local! buf 'notmuch-thread thread-id)
    (buffer-set-local! buf 'notmuch-subject subject)
    ;; a view inherits its index's groups, so a grouped mail scene keeps
    ;; the open message inside the group (group-docs, chat read-doc, ⊞).
    ;; Membership is 'group-ids and joining is buffer-add-group!: writing
    ;; the legacy 'group local here left the view ungrouped, because the
    ;; reader clears that local the moment a buffer has real memberships.
    (when (buffer-exists? *notmuch-search-buffer*)
      (for-each (lambda (id) (buffer-add-group! buf id))
                (buffer-group-ids *notmuch-search-buffer*)))
    ;; render into the buffer and into no window at all. Placement belongs
    ;; to the caller (nm--show-pane!): a switch here takes whichever window
    ;; happens to be current, which is the index's own window.
    (with-current-buffer buf (lambda () (set-mode! "notmuch-show-mode")))
    ;; reading marks read, like every mail client
    (when (null? opts)
      (nm--run (string-append "tag -unread -- thread:" thread-id)))
    buf))

(define-command "notmuch-open-thread" "Open the thread at point in the mail pane"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (nm--thread-at buf)
          ;; The thread never takes the index's window: it is rendered into
          ;; the mail pane exactly as SPC renders it. RET then goes to that
          ;; pane, so `a`, `r` and `v` act on the message that was opened.
          ;; A scene is the exception — its panes are all on screen at once
          ;; and the reading is done from the index, so focus stays there.
          (let ((scene (scene-window 'show)))
            (nm--preview! buf)
            (unless scene
              (let ((pane (window-showing *notmuch-show-buffer*)))
                (when pane (select-window! pane)))))
          (message "No thread on this line")))))

(define-command "notmuch-show-toggle-view" "Switch between the HTML and text views"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-local! buf 'notmuch-view
        (if (equal? (buffer-local buf 'notmuch-view) "text") "html" "text"))
      (set-mode! "notmuch-show-mode"))))

(define-command "notmuch-show-archive" "Archive this thread and go back"
  (lambda ()
    (let ((th (buffer-local (current-buffer) 'notmuch-thread)))
      (when th
        (nm--run (string-append "tag -inbox -- thread:" th))
        (run-command "quit-window")
        (when (buffer-exists? *notmuch-search-buffer*)
          (nm--refresh! *notmuch-search-buffer*))
        (message "Archived")))))

;; the message the point is in: last offset <= point (above the first
;; message — on the subject line — it means the first message)
(define (nm--msg-at buf)
  (let ((ms (or (buffer-local buf 'notmuch-msgs) '())))
    (let loop ((rest ms) (found (if (null? ms) #f (car ms))))
      (cond ((null? rest) found)
            ((<= (car (car rest)) (buffer-point buf)) (loop (cdr rest) (car rest)))
            (else found)))))

;;; --- compose / reply ------------------------------------------------------------

(mode-icon! "mail-compose-mode" "")

(define-mode "mail-compose-mode"
  (lambda ()
    ))

(mode-keys! "mail-compose-mode"
  '(
    ("C-c C-c" "mail-send")
    ("C-c C-k" "mail-abort")))

(mode-doc! "mail-compose-mode"
  "A message you are writing. The headers sit above the separator line and the body below it. `C-c C-c` sends the message, and `C-c C-k` abandons it.")

;; message-mode layout: headers, the separator, an empty line for the
;; reply (point lands there), attribution, the original quoted as text
(define *mail-header-separator* "--text follows this line--")

(defface! 'nm-hdr 'fg "#26356b" 'weight "600")
(defface! 'nm-sep 'fg "#9a9a72")

(define (nm--quote-text text)
  (string-append "> "
    (string-join (string-split (string-trim text) "\n") "\n> ")
    "\n"))

;; face the header names and the separator — they sit above point, so
;; typing in the body never shifts them
(define (nm--compose-overlays! buf head)
  (let loop ((lines (string-split head "\n")) (off 0) (ovs '()))
    (if (null? lines)
        (overlay-set! buf 'compose (reverse ovs))
        (let* ((line (car lines))
               (len (string-byte-length line))
               (parts (string-split line ": ")))
          (loop (cdr lines) (+ off len 1)
                (cond ((equal? line *mail-header-separator*)
                       (cons (list off (+ off len) "nm-sep") ovs))
                      ((and (> len 0) (pair? (cdr parts)))
                       (cons (list off (+ off (string-byte-length (car parts)) 1) "nm-hdr")
                             ovs))
                      (else ovs)))))))

(define (nm--compose-reply! msg-id)
  (let* ((j (nm--json (string-append "reply --format=json id:" (nm--quote msg-id))))
         (rh (and j (nm--get j 'reply-headers)))
         (orig (and j (nm--get j 'original))))
    (if (not rh)
        (message "notmuch reply failed")
        (let* ((buf "*compose*")
               (hdr (lambda (name key)
                      (let ((v (nm--get rh key)))
                        (if v (string-append name ": " v "\n") ""))))
               (head (string-append
                       (hdr "From" 'From) (hdr "To" 'To) (hdr "Cc" 'Cc)
                       (hdr "Subject" 'Subject)
                       (hdr "In-Reply-To" 'In-reply-to)
                       (hdr "References" 'References)
                       *mail-header-separator* "\n"))
               (attrib (let ((h (and orig (nm--get orig 'headers))))
                         (if (and h (nm--get h 'From))
                             (string-append (nm--get h 'From) " writes:\n\n")
                             "")))
               ;; quote the RENDERED text (nm--msg-body-text goes through the
               ;; html renderer when there is no text/plain) — never raw html
               (quoted (if orig (nm--quote-text (nm--msg-body-text orig)) "")))
          (unless (buffer-exists? buf) (buffer-create buf))
          (buffer-delete-range! buf 0 (buffer-size buf))
          (buffer-append! buf (string-append head "\n" attrib quoted))
          (switch-to-buffer! buf)
          (set-mode! "mail-compose-mode")
          (nm--compose-overlays! buf head)
          (goto-char! (string-byte-length head))
          (message "C-c C-c sends, C-c C-k aborts")))))

(define-command "notmuch-show-reply" "Reply to the message at point"
  (lambda ()
    (let ((msg (nm--msg-at (current-buffer))))
      (if msg
          (nm--compose-reply! (cadr msg))
          (message "No message at point")))))

;; newest message id of a thread (search sorts newest-first)
(define (nm--newest-msg-id thread-id)
  (let ((out (string-trim
               (nm--run (string-append "search --output=messages --limit=1 -- thread:"
                                       thread-id)))))
    (and (string-prefix? "id:" out)
         (substring out 3 (string-length out)))))

(define-command "notmuch-reply" "Reply to the newest message of the thread at point"
  (lambda ()
    (let ((th (nm--thread-at (current-buffer))))
      (if (not th)
          (message "No thread on this line")
          (let ((id (nm--newest-msg-id (nm--th-id th))))
            (if id
                (nm--compose-reply! id)
                (message "No message found in thread")))))))

(define (nm--send-route text)
  (let loop ((rs notmuch-send-routes))
    (cond ((null? rs) #f)
          ((or (equal? (car (car rs)) "")
               (string-contains? text (car (car rs))))
           (cadr (car rs)))
          (else (loop (cdr rs))))))

(define-command "mail-send" "Send this buffer as an email"
  (lambda ()
    (let* ((buf (current-buffer))
           ;; the separator line becomes the RFC822 blank line
           (text (string-join
                   (string-split (buffer-text buf)
                                 (string-append "\n" *mail-header-separator* "\n"))
                   "\n\n"))
           (route (nm--send-route text))
           (tmp (string-append (expand-path "~") "/.compos/outgoing.eml")))
      (if (not route)
          (message "No send route matches — set notmuch-send-routes")
          (begin
            (write-file! tmp text)
            (let ((out (shell-command->string
                         (string-append "cat " (nm--quote tmp) " | " route
                                        " && echo SENT-OK"))))
              (if (string-contains? out "SENT-OK")
                  (begin (run-command "quit-window") (message "Sent"))
                  (message (string-append "Send failed: " (string-trim out))))))))))

(define-command "mail-abort" "Abandon this compose buffer"
  (lambda ()
    (let* ((buf (current-buffer))
           (others (filter (lambda (b) (not (equal? b buf))) (buffer-list-mru))))
      (buffer-kill! buf)
      (switch-to-buffer! (if (null? others) "*scratch*" (car others)))
      (message "Aborted"))))

;;; --- targets & actions: the email at point, embark-style -------------------------

;; C-. and the model's act tool both land here — one real tag-and-verify
;; (mail-tag!), not a second copy that discards nm--run's outcome the way
;; this used to (echoing CHANGES back via message regardless of whether
;; anything was actually tagged)
(define (nm--email-tag-act changes)
  (lambda (id)
    (let ((result (mail-tag! id changes)))
      (message result)
      result)))

(register-target-provider! "notmuch-mode"
  (lambda (buf)
    (let ((th (nm--thread-at buf)))
      (and th (list 'email (nm--th-id th) (nm--th-subject th))))))

(register-target-provider! "notmuch-show-mode"
  (lambda (buf)
    (let ((th (buffer-local buf 'notmuch-thread)))
      (and th (list 'email th (or (buffer-local buf 'notmuch-subject) ""))))))

(register-actions! 'email
  (list (list "archive"  (nm--email-tag-act "-inbox"))
        (list "trash"    (nm--email-tag-act "+trash -inbox -unread"))
        (list "unread"   (nm--email-tag-act "+unread"))
        (list "mark"     (lambda (id)
                           (nm--toggle-selection! *notmuch-search-buffer* id)))
        (list "read"     (lambda (id)
                           (nm--show-pane!
                             (nm--open-thread! id
                               (let ((th (nm--thread-at (current-buffer))))
                                 (if th (nm--th-subject th) ""))))))
        (list "reply"    (lambda (id)
                           (let ((mid (nm--newest-msg-id id)))
                             (if mid
                                 (nm--compose-reply! mid)
                                 (message "no message in thread")))))))

;;; --- context: "this" in a chat means the selected email --------------------------

(register-context-provider! "notmuch-mode"
  (lambda (buf)
    (let ((th (nm--thread-at buf)))
      (and th
           (string-append "the email thread selected in the mail list: \""
                          (nm--th-subject th) "\" from " (nm--th-authors th)
                          " (notmuch thread:" (nm--th-id th) ")")))))

(register-context-provider! "notmuch-show-mode"
  (lambda (buf)
    (let ((th (buffer-local buf 'notmuch-thread))
          (msg (nm--msg-at buf)))
      (and th
           (string-append "the open email thread \""
                          (or (buffer-local buf 'notmuch-subject) "") "\""
                          " (notmuch thread:" th ")"
                          (if msg (string-append ", message id:" (cadr msg)) ""))))))

;;; --- mail for the model -------------------------------------------------------
;;; No per-domain tools: mail is reached through eval-scheme + act. Search
;;; and read are public functions over the same code the UI uses.

(define (mail-search query)
  (let ((threads (nm--search-json query 20)))
    (if (null? threads)
        "no matches"
        (fold (lambda (acc th)
                (string-append acc
                  (nm--get th 'date_relative) " | "
                  (nm--get th 'authors) " | "
                  (nm--get th 'subject) " | "
                  (string-join (nm--get th 'tags) ",") " | thread:"
                  (nm--get th 'thread) "\n"))
              "" threads))))

(define (mail-read-thread raw)
  (let* ((id (if (string-prefix? "thread:" raw)
                 (substring raw 7 (string-length raw))
                 raw))
         (msgs (nm--show-msgs id))
         (text (car (nm--render-text "" msgs))))
    (cond ((equal? (string-trim text) "") "no such thread")
          ;; char-based cut — a byte cut could split utf-8 and poison
          ;; the json encoder
          ((> (string-length text) 8000)
           (string-append (substring text 0 8000) "\n[...truncated]"))
          (else text))))

;; how many messages match QUERY — ground truth for whether a tag change
;; actually landed, instead of trusting a shell call whose exit status
;; nm--run already throws away. #f (NOT 0) when notmuch's output can't be
;; parsed as a number — a genuinely empty result and a surprising one
;; (a warning line, a hiccup) must not collapse into the same "zero", or
;; a parse failure reads as "no such thread" for one that exists: the
;; same blind-trust shape mail-tag! exists to fix, one level down.
(define (nm--count query)
  (string->number
    (string-trim (nm--run (string-append "count -- " (nm--quote query))))))

(define (mail-tag! raw changes)
  (let* ((id (if (string-prefix? "thread:" raw)
                 (substring raw 7 (string-length raw))
                 raw))
         (n (nm--count (string-append "thread:" id))))
    (cond
      ((not n)
       (string-append "couldn't verify thread " id
                      " — notmuch count gave an unexpected answer"))
      ((= n 0) (string-append "no such thread: " id))
      (else
        (nm--run (string-append "tag " changes " -- thread:" id))
        (when (buffer-exists? *notmuch-search-buffer*)
          (nm--refresh! *notmuch-search-buffer*))
          (string-append "tagged " (number->string n) " message"
                         (if (= n 1) "" "s") " in thread " id
                         " (" changes ")")))))

(define (notmuch-sender-count query limit)
  (let* ((raw (nm--run (string-append
                "address --output=sender --output=count --deduplicate=address -- "
                (nm--quote query))))
         (lines (filter (lambda (l) (> (string-length l) 0)) (string-split raw "\n")))
         (rows (map (lambda (l)
                      (let ((parts (string-split l "\t")))
                        (list (string->number (car parts)) (cadr parts))))
                    lines))
         (top (list-head (reverse (sort rows)) (min limit (length rows)))))
    (if (null? top)
        "no matches"
        (fold (lambda (acc row)
                (string-append acc (number->string (car row)) "\t" (cadr row) "\n"))
              "" top))))

;; the raw CLI, for whatever mail-search/mail-tag! don't cover — bulk
;; tag/archive by QUERY ("tag -inbox -- from:luma.com") in one call
;; instead of enumerating thread ids and tagging them one at a time, or
;; "count -- QUERY" to check a result instead of trusting a blind "done".
;; notmuch's own syntax is public, stable, and already in every model's
;; training data — better to let it speak that directly than force
;; everything through a bespoke per-thread wrapper. Same shell nm--run
;; always used; refreshes the search buffer since ARGS may have mutated
;; tags, same as mail-tag!.
(define (notmuch args)
  (let ((out (nm--run args)))
    (when (buffer-exists? *notmuch-search-buffer*)
      (nm--refresh! *notmuch-search-buffer*))
    (if (equal? (string-trim out) "") "(no output)" out)))

(category! 'mail)
(public! 'mail-search
  "(mail-search QUERY) — notmuch search (from:, to:, subject:, tag:, dates, free text); one thread per line with its thread:ID")
(public! 'mail-read-thread
  "(mail-read-thread THREAD-ID) — full text of an email thread, thread: prefix optional")
(public! 'mail-tag!
  "(mail-tag! THREAD-ID CHANGES) — apply space-separated +tag/-tag changes to a thread; returns how many messages it actually matched (a real count, not a blind \"done\") — 0 means the thread id was wrong")
(public! 'notmuch-sender-count
  "(notmuch-sender-count QUERY LIMIT) — biggest senders matching QUERY (from: addresses, deduplicated), top LIMIT as \"COUNT\\tSENDER\" lines, most first")
(public! 'notmuch
  "(notmuch ARGS) — the raw notmuch CLI, ARGS is everything after `notmuch` as one string, e.g. \"tag -inbox -- from:luma.com\" or \"count -- tag:inbox from:luma.com\"; prefer this for bulk ops by query (archive/tag many at once) and for verifying a change actually happened, instead of enumerating thread ids one at a time")
