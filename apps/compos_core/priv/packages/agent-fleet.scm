;;; agent-fleet.scm --- Chat fleet list, archive, and attention UI.
;;;
;;; This module owns the *chats* list and actions across chat buffers. Runtime
;;; lifecycle and transcript rendering remain in agent.scm.

(domain! 'chat)
(effects! '(write))
(category! 'chat)

(define *agents-buffer* "*chats*")

(add-display-rule! *agents-buffer* 'popup)

(define (agent-threads)
  (map (lambda (b) (list (buffer-local b 'agent-slug) (chat-row-status b)))
       (filter (lambda (b) (buffer-local b 'agent-slug)) (chat-list-bufs))))

(define (agent-status-rank s)
  (cond ((equal? s 'needs_attention) 0)
        ((equal? s 'running) 1)
        ((equal? s 'starting) 1)
        ((equal? s 'idle) 2)
        ((equal? s 'api) 2)
        (else 3)))

(define (agent-status-glyph s)
  (cond ((equal? s 'needs_attention) "!")
        ((equal? s 'running) "*")
        ((equal? s 'starting) "*")
        ((equal? s 'idle) "-")
        ((equal? s 'api) "-")
        (else "x")))

(define (chat-list-bufs)
  (let loop ((bs (buffer-list)) (acc '()))
    (cond ((null? bs) (reverse acc))
          ((and (not (string-prefix? " " (car bs)))
                (or (buffer-local (car bs) 'agent-slug)
                    (chat-buffer? (car bs))))
           (loop (cdr bs) (cons (car bs) acc)))
          (else (loop (cdr bs) acc)))))

(define (chat-row-status b)
  (let ((slug (buffer-local b 'agent-slug)))
    (if slug (agent-status slug) 'api)))

(define (agents-sorted &optional bufs)
  (let ((bs (or bufs (chat-list-bufs))))
    (let loop ((rank 0) (acc '()))
      (if (> rank 3) (reverse acc)
          (loop (+ rank 1)
                (let inner ((bs bs) (acc acc))
                  (cond ((null? bs) acc)
                        ((= (agent-status-rank (chat-row-status (car bs))) rank)
                         (inner (cdr bs) (cons (car bs) acc)))
                        (else (inner (cdr bs) acc)))))))))

(category! 'chat)

(effects! '(read))

(defcustom 'chats-archived-limit 15
  "How many saved chats the *chats* list shows below the live ones."
  'group 'chat 'type 'integer)

(define (chats-live-log-paths)
  (let loop ((bs (chat-list-bufs)) (acc '()))
    (if (null? bs)
        acc
        (let ((id (buffer-local (car bs) 'chat-log-id)))
          (loop (cdr bs)
                (if id
                    (cons (string-append (chat-log-dir) "/" id ".chat") acc)
                    acc))))))

(define (chats-archived-rows)
  (if (not (boundp (quote chat-log-files-newest)))
      '()
      (let ((live (chats-live-log-paths)))
        (take-n (filter (lambda (path)
                          (and (not (buffer-known? path))
                               (not (member path live))))
                        (chat-log-files-newest))
                chats-archived-limit))))

(define (chats-archived-row? e)
  (and (string? e) (not (buffer-known? e))))

;; The name of a saved chat is the sentence its header carries, not the
;; group slug its file is named for. The header is line one, and an
;; archived file no longer changes, so one read per path answers for the
;; whole session.
(define *chats-archived-summaries* '())

(define (chats-archived-summary--read path)
  (let ((text (ignore-errors (lambda () (read-file path)))))
    (and (string? text)
         (let* ((nl (string-index text "\n"))
                (head (chat-parse-header
                        (if nl (substring-bytes text 0 nl) text)))
                (s (and head (plist-get head 'summary))))
           (and (string? s) (not (equal? s "")) s)))))

(define (chats-archived-summary path)
  (let ((hit (assoc path *chats-archived-summaries*)))
    (if hit
        (cadr hit)
        (let ((title (chats-archived-summary--read path)))
          (set! *chats-archived-summaries*
                (cons (list path title) *chats-archived-summaries*))
          title))))

(define (chats-archived-title path)
  (or (chats-archived-summary path)
      (let* ((leaf (chat-log-leaf path))
             (title (re-replace "\\.chat$" (re-replace "^[0-9]+-" leaf "") "")))
        (if (equal? title "") leaf title))))

;;; --- the table: sections, order, folds -----------------------------------------
;;; C-x b splits the buffers by group, and so does this list. A section is
;;; a group, a state, or a model; `;` cycles it. Inside a section the rows
;;; order by urgency, recency, title, or context size; `,` cycles that.
;;; TAB folds the section at point. A row takes two lines: the title and
;;; its numbers, then the running summary and the model. The saved
;;; conversations make the last section. The view state lives on the list
;;; buffer, so it survives a quit and a reopen the way the filters do.

(defcustom 'chats-default-grouping 'group
  "What a section of the *chats* list is: 'group, 'state, or 'model."
  'group 'chat 'type 'choice)

(defcustom 'chats-default-sort 'urgency
  "The order inside a section: 'urgency, 'recent, 'title, or 'tokens."
  'group 'chat 'type 'choice)

(defface! 'chats-heading 'bg "rgba(128, 128, 128, 0.10)")
(defface! 'chats-marked 'bg "rgba(213, 172, 102, 0.13)")

(define *chats-groupings* '(group state model))
(define *chats-sorts* '(urgency recent title tokens))

(define (chats-grouping)
  (or (buffer-local *agents-buffer* 'chats-grouping) chats-default-grouping))

(define (chats-sort)
  (or (buffer-local *agents-buffer* 'chats-sort) chats-default-sort))

(define (chats-collapsed)
  (or (buffer-local *agents-buffer* 'chats-collapsed) '()))

(define (chats-cycle-after item items)
  (let ((rest (member item items)))
    (if (and rest (pair? (cdr rest))) (cadr rest) (car items))))

(define (chats-set-grouping! mode)
  (buffer-set-locals! *agents-buffer*
    (list 'chats-grouping mode 'chats-collapsed '()))
  (when (buffer-known? *agents-buffer*) (list-refresh! *agents-buffer*)))

(define (chats-set-sort! mode)
  (buffer-set-local! *agents-buffer* 'chats-sort mode)
  (when (buffer-known? *agents-buffer*) (list-refresh! *agents-buffer*)))

(define (chats-folded? key) (if (member key (chats-collapsed)) #t #f))

(define (chats-toggle-fold! key)
  (let ((now (chats-collapsed)))
    (buffer-set-local! *agents-buffer* 'chats-collapsed
      (if (member key now)
          (filter (lambda (k) (not (equal? k key))) now)
          (cons key now)))
    (list-refresh! *agents-buffer*)))

;;; --- last activity ------------------------------------------------------------
;;; The editor keeps no clock on a chat. This table notes the time the
;;; last event batch reached each chat. It starts empty at boot, so a
;;; chat with no event since the restart shows no age.

(define *chats-activity* '())

(define (chats-note-activity! b)
  (when (string? b)
    (set! *chats-activity*
      (cons (list b (current-time))
            (filter (lambda (e) (not (equal? (car e) b))) *chats-activity*)))))

(define (chats-activity-at b)
  (let ((e (assoc b *chats-activity*)))
    (and e (cadr e))))

(define (chats-age-label t)
  (ibuffer-age-label (and t (- (current-time) t))))

;;; --- one row's facts ----------------------------------------------------------

(define (chats-row-buffer? e) (and (string? e) (buffer-known? e)))

;; the state in the words the row shows: what the chat waits for
(define (chats-state-label status)
  (cond ((equal? status 'needs_attention) "your turn")
        ((equal? status 'running) "streaming")
        ((equal? status 'starting) "starting")
        ((equal? status 'idle) "idle")
        ((equal? status 'api) "idle")
        (else "stopped")))

(define (chats-state-face status)
  (cond ((equal? status 'needs_attention) "alert")
        ((or (equal? status 'running) (equal? status 'starting)) "accent")
        ((equal? status 'dead) "faint")
        (else "dim")))

(define (chats-live? b)
  (and (chats-row-buffer? b)
       (buffer-local b 'agent-slug)
       (not (equal? (chat-row-status b) 'dead))))

(define (chats-waiting? b)
  (and (chats-row-buffer? b) (equal? (chat-row-status b) 'needs_attention)))

(define (chats-model b)
  (or (buffer-local b 'agent-model) (buffer-local b 'llm-model) ""))

(define (chats-tokens b)
  (let ((n (and (chats-row-buffer? b) (buffer-local b 'chat-context-used))))
    (if (number? n) n 0)))

(define (chats-tokens-label n)
  (if (> n 0) (chat-tokens-short n) ""))

(define (chats-summary b)
  (let ((s (buffer-local b 'chat-summary)))
    (and (string? s) (not (equal? s "")) s)))

(define (chats-titled? b) (not (string-prefix? "*" b)))

;; line one names the chat the way the C-x c prompt does: its title, else
;; the sentence its summary wrote, else its buffer name
(define (chats-title b) (chat-prompt-label b))

;; line two says what the chat is about, unless line one already did;
;; then it says which buffer that is
(define (chats-detail b)
  (let ((s (chats-summary b)))
    (cond ((chats-titled? b) (or s ""))
          (s b)
          (else ""))))

;;; --- headings -----------------------------------------------------------------
;;; A heading row is a list: (LABEL "" KIND KEY LIVE WAITING COUNT TOKENS
;;; FACE MEMBERS). KIND is "separator" for an open section, whose rows
;;; follow it, or "folded" for a closed one, whose rows it stands for. A
;;; folded heading is a row of its own: the narrowing keeps it when a
;;; member matches, the highlight can rest on it, and RET or TAB opens it.

(define (chats-heading label key kind members face)
  (list label "" kind key
        (length (filter chats-live? members))
        (length (filter chats-waiting? members))
        (length members)
        (fold (lambda (n b) (+ n (chats-tokens b))) 0 members)
        face
        members))

(define (chats-heading? row) (and (pair? row) (> (length row) 2)))
(define (chats-heading-label row) (car row))
(define (chats-heading-key row) (nth 3 row))
(define (chats-heading-live row) (nth 4 row))
(define (chats-heading-waiting row) (nth 5 row))
(define (chats-heading-count row) (nth 6 row))
(define (chats-heading-tokens row) (nth 7 row))
(define (chats-heading-face row) (nth 8 row))
(define (chats-heading-members row) (nth 9 row))
(define (chats-heading-folded? row) (equal? (nth 2 row) "folded"))

(define (chats-separator? buf row)
  (and (chats-heading? row) (equal? (nth 2 row) "separator")))

;; MEMBERS arrive in the order the section keeps; ORDER? #t sorts them.
;; The heading holds its members in the order the rows show.
(define (chats-section label key members face order?)
  (if (null? members)
      '()
      (let ((ordered (if order? (chats-sort-rows members) members)))
        (if (chats-folded? key)
            (list (chats-heading label key "folded" ordered face))
            (cons (chats-heading label key "separator" ordered face) ordered)))))

;;; --- sorting ------------------------------------------------------------------

(define (chats-mru-order rows)
  (let ((mru (filter (lambda (b) (member b rows)) (buffer-list-mru))))
    (append mru (filter (lambda (b) (not (member b mru))) rows))))

(define (chats-sort-rows rows)
  (let ((mode (chats-sort)))
    (cond ((equal? mode 'recent) (chats-mru-order rows))
          ((equal? mode 'title)
           (map cadr (sort (map (lambda (b) (list (string-downcase (chats-title b)) b))
                                rows))))
          ((equal? mode 'tokens)
           (map cadr (sort (map (lambda (b) (list (- 0 (chats-tokens b)) b)) rows))))
          (else (agents-sorted (chats-mru-order rows))))))

;;; --- sections -----------------------------------------------------------------

;; the current group first, then the groups by name, then the chats no
;; group claims. A chat belongs to one group, so each row appears once.
(define (chats-group-sections rows current)
  (let* ((owner (map (lambda (b) (list b (buffer-group b))) rows))
         (of (lambda (b) (cadr (assoc b owner))))
         (named (sort (map (lambda (id)
                             (list (string-downcase (or (group-name id) "")) id))
                           (filter (lambda (id) (not (equal? id current)))
                                   (group-ids)))))
         (ordered (append (if current (list current) '()) (map cadr named)))
         (grouped
           (fold (lambda (out id)
                   (append out
                     (chats-section
                       (or (group-name id) id)
                       (string-append "group:" id)
                       (filter (lambda (b) (equal? (of b) id)) rows)
                       (group-color-face id)
                       #t)))
                 '() ordered))
         (ungrouped (filter (lambda (b) (not (member (of b) ordered))) rows)))
    (append grouped (chats-section "ungrouped" "group:" ungrouped "faint" #t))))

;; the rows bucketed by a key fn, one section per key, in ORDER; a key
;; ORDER does not name comes after the named ones, by name
(define (chats-keyed-sections rows key-of face-of order)
  (let* ((keys (dedupe-names (map key-of rows)))
         (rest (map cadr (sort (map (lambda (k) (list (string-downcase k) k))
                                    (filter (lambda (k) (not (member k order))) keys)))))
         (ordered (append (filter (lambda (k) (member k keys)) order) rest)))
    (fold (lambda (out k)
            (append out
              (chats-section k (string-append "key:" k)
                (filter (lambda (b) (equal? (key-of b) k)) rows)
                (face-of k)
                #t)))
          '() ordered)))

(define *chats-state-order*
  '("your turn" "streaming" "starting" "idle" "stopped"))

(define (chats-state-sections rows)
  (chats-keyed-sections rows
    (lambda (b) (chats-state-label (chat-row-status b)))
    (lambda (k) (cond ((equal? k "your turn") "alert")
                      ((or (equal? k "streaming") (equal? k "starting")) "accent")
                      (else "dim")))
    *chats-state-order*))

(define (chats-model-sections rows)
  (chats-keyed-sections rows
    (lambda (b) (let ((m (chats-model b))) (if (equal? m "") "no model" m)))
    (lambda (k) "accent")
    '()))

;; the saved conversations, newest first, as they come
(define (chats-archived-section)
  (chats-section "archived" "archived" (chats-archived-rows) "faint" #f))

;; The list fetches its rows on open, on g, and when a burst of events
;; settles. A mark or a narrowing redraws the rows it already has.
(define (chats-rows)
  (let* ((bufs (chat-list-bufs))
         (grouping (chats-grouping))
         (live (cond ((equal? grouping 'state) (chats-state-sections bufs))
                     ((equal? grouping 'model) (chats-model-sections bufs))
                     (else (chats-group-sections
                             bufs (and (boundp 'frame-group) (frame-group)))))))
    (append live (chats-archived-section))))

(effects! '(write))

;;; --- columns and cells --------------------------------------------------------
;;; Two lines per row. The first names the chat and gives its numbers:
;;; the queue, the turns, the context tokens, the state, and the age of
;;; its last event. The second is the running summary and the model.

(define (chats-columns buf)
  (list (list (list "" 1) (list "chat" #f 'left 'end) (list "queue" 5 'right)
              (list "turns" 5 'right) (list "ctx" 6 'right) (list "state" 10)
              (list "last" 4 'right))
        (list (list "" 1) (list "summary" #f 'left 'end) (list "model" 24 'right))))

(define (chats-live-lines b)
  (let* ((slug (buffer-local b 'agent-slug))
         (status (chat-row-status b))
         (info (and slug (agent-info slug)))
         (face (chats-state-face status))
         (queued (if info (or (plist-get info 'queued) 0) 0)))
    (list (list (list (agent-status-glyph status) face)
                (list (chats-title b)
                      (if (equal? status 'needs_attention) "alert" "accent"))
                (list (if (> queued 0) (string-append "+" (number->string queued)) "")
                      "warn")
                (list (number->string (chat-turn-count b)) "dim")
                (list (chats-tokens-label (chats-tokens b)) "dim")
                (list (chats-state-label status) face)
                (list (chats-age-label (chats-activity-at b)) "dim"))
          (list ""
                (list (chats-detail b) "dim")
                (list (chats-model b) "faint")))))

(define (chats-archived-lines path)
  (let ((at (file-mtime path)))
    (list (list (list "." "faint")
                (list (chats-archived-title path) "dim")
                "" "" ""
                (list "archived" "faint")
                (list (chats-age-label at) "faint"))
          (list ""
                (list (format-time at "%Y-%m-%d %H:%M") "faint")
                ""))))

;; the counts a heading carries, as words; a zero says nothing
(define (chats-tally row)
  (let ((live (chats-heading-live row))
        (waiting (chats-heading-waiting row))
        (count (chats-heading-count row))
        (tokens (chats-heading-tokens row)))
    (string-join
      (append
        (if (> live 0) (list (string-append (number->string live) " live")) '())
        (if (> waiting 0) (list (string-append (number->string waiting) " waiting")) '())
        (list (string-append (number->string count) (if (= count 1) " chat" " chats")))
        (if (> tokens 0) (list (string-append (chat-tokens-short tokens) " tok")) '()))
      " · ")))

(define (chats-chevron row) (if (chats-heading-folded? row) "▸" "▾"))

(define (chats-heading-lines row)
  (list (list (list (chats-chevron row) "dim")
              (list (string-append (chats-heading-label row) "  " (chats-tally row))
                    (or (chats-heading-face row) "accent"))
              "" "" "" "" "")))

(define (chats-cells buf e)
  (cond ((chats-heading? e) (chats-heading-lines e))
        ((chats-archived-row? e) (chats-archived-lines e))
        (else (chats-live-lines e))))

;;; --- bands --------------------------------------------------------------------
;;; A heading and a marked row wear a background over their whole width.
;;; The tally on a heading is dim: a span over the tail of the label
;;; cell, which starts after the mark, the chevron, and two gaps.

(define (chats-row-bytes buf e)
  (fold (lambda (n line) (+ n (string-byte-length (car line)) 1))
        0 (list-row-lines buf e)))

(define (chats-band buf e off face)
  (list (list off (+ off (chats-row-bytes buf e) -1) face)))

(define (chats-tally-overlay buf row off)
  (let* ((line (car (car (list-row-lines buf row))))
         (start (+ off 2 (string-byte-length (chats-chevron row)) 2
                   (string-byte-length (chats-heading-label row)) 2))
         (end (min (+ start (string-byte-length (chats-tally row)))
                   (+ off (string-byte-length line)))))
    (if (< start end) (list (list start end "dim")) '())))

(define (chats-row-overlays buf e off)
  (cond ((chats-heading? e)
         (append (chats-band buf e off "chats-heading")
                 (chats-tally-overlay buf e off)))
        ((not (equal? (list-mark-of buf e) " "))
         (chats-band buf e off "chats-marked"))
        (else '())))

;;; --- the head, the narrowing, the key bar -------------------------------------

(define (chats-counts-line n live waiting saved tokens)
  (string-append
    (number->string n) (if (= n 1) " chat" " chats")
    " · " (number->string live) " live"
    " · " (number->string waiting) " waiting on you"
    (if (> saved 0) (string-append " · " (number->string saved) " saved") "")
    (if (> tokens 0) (string-append " · " (chat-tokens-short tokens) " tok") "")))

(define (chats-meta buf)
  (let loop ((rows (list-entries buf)) (n 0) (live 0) (waiting 0) (saved 0) (tokens 0))
    (cond ((null? rows)
           (ibuffer-join-parts
             (append
               (list (list (chats-counts-line n live waiting saved tokens) "dim")
                     (list "   " #f))
               (ibuffer-chips "GROUP" (map symbol->string *chats-groupings*)
                              (symbol->string (chats-grouping)))
               (list (list "   " #f))
               (ibuffer-chips "SORT" (map symbol->string *chats-sorts*)
                              (symbol->string (chats-sort))))))
          ((chats-heading? (car rows))
           (let ((row (car rows)))
             (if (not (chats-heading-folded? row))
                 (loop (cdr rows) n live waiting saved tokens)
                 (if (equal? (chats-heading-key row) "archived")
                     (loop (cdr rows) n live waiting
                           (+ saved (chats-heading-count row)) tokens)
                     (loop (cdr rows)
                           (+ n (chats-heading-count row))
                           (+ live (chats-heading-live row))
                           (+ waiting (chats-heading-waiting row))
                           saved
                           (+ tokens (chats-heading-tokens row)))))))
          ((chats-archived-row? (car rows))
           (loop (cdr rows) n live waiting (+ saved 1) tokens))
          (else
           (let ((b (car rows)))
             (loop (cdr rows) (+ n 1)
                   (+ live (if (chats-live? b) 1 0))
                   (+ waiting (if (chats-waiting? b) 1 0))
                   saved
                   (+ tokens (chats-tokens b))))))))

;; what `/` reads: the title, the summary, the model, the state, the slug,
;; and the buffer name; a heading matches when a member does
(define (chats-match? buf row input)
  (cond ((chats-heading? row)
         (let loop ((ms (chats-heading-members row)))
           (and (pair? ms)
                (or (chats-match? buf (car ms) input) (loop (cdr ms))))))
        ((chats-archived-row? row)
         (completion-match?
           (string-append (chats-archived-title row) " archived saved " row)
           input 'substring))
        (else
         (completion-match?
           (string-append row " " (chats-title row) " "
                          (or (chats-summary row) "") " "
                          (chats-model row) " "
                          (chats-state-label (chat-row-status row)) " "
                          (or (buffer-local row 'agent-slug) ""))
           input 'substring))))

(define (chats-footer buf)
  '(("RET" "resume") ("SPC" "mark") ("a" "archive") ("r" "retitle")
    ("TAB" "fold") ("," "sort") (";" "group by") ("s" "steer")
    ("y/n" "permission") ("k/d" "flag") ("x" "execute") ("+" "new")
    ("/" "filter") ("g" "refresh") ("q" "quit")))

;; the heading of the section the highlight is in: the row itself when
;; it is a heading, else the nearest heading above it
(define (chats-section-at)
  (let ((i (list-clamped-index *agents-buffer*))
        (es (list-entries *agents-buffer*)))
    (and i
         (let loop ((k (min i (- (length es) 1))))
           (cond ((< k 0) #f)
                 ((chats-heading? (nth k es)) (nth k es))
                 (else (loop (- k 1))))))))

;; A streaming turn hands the fleet an event batch many times a second,
;; and the old refresh drew the list for every one of them. That is what
;; made it jump: the rows re-sort under the reader as a status flips, and
;; every draw is a patch to the browser. Two rules settle it. A list
;; nobody is looking at is not drawn at all, and a burst of events draws
;; once, when it stops.
(define *agents-refresh-ms* 800)

(define (agents-buffer-shown?)
  (and (buffer-exists? *agents-buffer*)
       (or (equal? (current-buffer) *agents-buffer*)
           (let loop ((ws (window-list-all)))
             (cond ((null? ws) #f)
                   ((equal? (cadr (car ws)) *agents-buffer*) #t)
                   (else (loop (cdr ws))))))))

(define (agents-refresh!)
  (when (agents-buffer-shown?)
    (list-refresh! *agents-buffer*)))

;; the fleet's surfaces after an event batch: the modeline answers at
;; once, because a chat that needs you is news; the list settles.
(define (agents-note-event! &optional slug)
  (when slug (chats-note-activity! (agent-buf slug)))
  (agents-modeline-refresh!)
  (when (agents-buffer-shown?)
    (debounce! "agents-refresh" *agents-refresh-ms*
      (lambda (ignored) (agents-refresh!)) #f)))

(define (agents-current-buf) (list-current *agents-buffer*))

(define (agents-current-slug)
  (let ((b (agents-current-buf)))
    (and b (buffer-local b 'agent-slug))))

(define (agents-targets)
  (filter (lambda (b) (buffer-exists? b)) (list-targets *agents-buffer*)))

(define (agents-report verb bs)
  (message (if (= (length bs) 1)
               (string-append verb " " (car bs))
               (string-append verb " " (number->string (length bs)) " chats"))))

(define (agents-visit-current)
  (let ((b (agents-current-buf)))
    (cond ((not b) #f)
          ((chats-heading? b) (chats-toggle-fold! (chats-heading-key b)))
          ((chats-archived-row? b)
           (visit-in-group b (frame-group))
           (end-of-buffer!))
          (else (switch-to-buffer! b) (end-of-buffer!)))))

;; the row under the highlight shows in the other window and leaves no
;; trace there: a preview, not a switch, so the recency order holds still
(define (agents-preview! buf b)
  (when (and (string? b) (buffer-exists? b))
    (let ((w (other-window-id (active-window))))
      (if w
          (window-preview-buffer! b w)
          (display-buffer-other-window! b)))))

(define-command "agents-next" "Move down and preview the chat in another window"
  (lambda () (list-move! 1)))

(define-command "agents-prev" "Move up and preview the chat in another window"
  (lambda () (list-move! -1)))

(define-command "chats-toggle-fold" "Fold or unfold the section at point"
  (lambda ()
    (let ((row (chats-section-at)))
      (if row
          (chats-toggle-fold! (chats-heading-key row))
          (message "no section here")))))

(define-command "chats-toggle-sort"
  "Cycle the order inside a section: urgency, recent, title, tokens"
  (lambda ()
    (let ((next (chats-cycle-after (chats-sort) *chats-sorts*)))
      (chats-set-sort! next)
      (message (string-append "sorted by " (symbol->string next))))))

(define-command "chats-toggle-grouping"
  "Cycle what a section is: group, state, model"
  (lambda ()
    (let ((next (chats-cycle-after (chats-grouping) *chats-groupings*)))
      (chats-set-grouping! next)
      (message (string-append "grouped by " (symbol->string next))))))

(define-command "chats-retitle" "Give the chat at point a title"
  (lambda ()
    (let ((b (agents-current-buf)))
      (if (not (and (string? b) (buffer-exists? b)))
          (message "no chat here")
          (minibuffer-read
            (string-append "Title for " b ": ")
            '()
            (lambda (name)
              (unless (equal? name "")
                (chat-title b name)
                (list-refresh! *agents-buffer*))))))))

(define-command "agents-visit" "Visit the thread on the current line"
  (lambda () (agents-visit-current)))

(define (agents-live-slug buf)
  (let ((slug (or (buffer-local buf 'agent-slug) (chat-ensure-runtime! buf))))
    (if (equal? (agent-status slug) 'dead) (agent-revive! slug) slug)))

(define-command "agents-steer" "Send a steering message to the marked chats"
  (lambda ()
    (let ((bs (agents-targets)))
      (if (null? bs)
          (message "no chat here")
          (minibuffer-read
            (if (= (length bs) 1)
                (string-append "Steer " (car bs) ": ")
                (string-append "Steer " (number->string (length bs)) " chats: "))
            '()
            (lambda (msg)
              (unless (equal? msg "")
                (for-each (lambda (b) (agent-send-msg! (agents-live-slug b) msg)) bs)
                (agents-refresh!)
                (agents-report "steered" bs))))))))

(define (agents-answer! exact prefix verb)
  (let ((bs (filter (lambda (b) (buffer-local b 'agent-slug)) (agents-targets))))
    (if (null? bs)
        (message "no chat with a runtime here")
        (begin
          (for-each (lambda (b)
                      (agent-answer-permission! (buffer-local b 'agent-slug)
                                                exact prefix))
                    bs)
          (agents-refresh!)
          (agents-report verb bs)))))

(define-command "agents-allow" "Allow the pending permission for the marked chats"
  (lambda () (agents-answer! "allow_once" "allow" "allowed")))

(define-command "agents-deny" "Deny the pending permission for the marked chats"
  (lambda () (agents-answer! "reject_once" "reject" "denied")))

(define (agent-note-stopped! slug)
  (unless (equal? (agent-status slug) 'dead)
    (let ((buf (agent-buf slug)))
      (agent-clear-waiting! slug)
      (agent-block-drop-kind! buf "permission")
      (let ((start (agent-render! slug "\n[agent stopped]\n" "agent-meta")))
        (agent-block-push! buf start (agent-mark slug) "meta" '())))))

(define (agent-release-windows! buf)
  (let* ((others (filter (lambda (b) (and (not (equal? b buf))
                                          (not (string-prefix? "*agent" b))))
                         (buffer-list-mru)))
         (repl (if (null? others) "*scratch*" (car others))))
    (for-each
      (lambda (w)
        (when (equal? (car (cdr w)) buf)
          (window-set-buffer! (car w) repl)))
      (window-list-all))))

(define (agents-kill-runtime! b)
  (let ((slug (buffer-local b 'agent-slug)))
    (and slug
         (begin (agent-note-stopped! slug)
                (llm-session-close! slug)
                #t))))

(define (agents-archive! b)
  (let ((here (active-window)))
    (agents-kill-runtime! b)
    (agent-release-windows! b)
    (buffer-kill! b)
    (when (window-exists? here) (select-window! here))))

(define-command "agents-refresh" "Refresh the chat list"
  (lambda () (agents-refresh!)))

(define-command "chats-archive"
  "Archive the marked chats, or the chat at point: the runtime stops, the buffer goes, the file stays"
  (lambda ()
    (let ((bs (agents-targets)))
      (if (null? bs)
          (message "no chat here")
          (begin
            (for-each agents-archive! bs)
            (list-clear-marks! *agents-buffer*)
            (list-refresh! *agents-buffer*)
            (agents-report "archived" bs))))))

(mode-icon! "chats-mode" "")

(define-list-mode! "chats-mode"
  (list
    'doc (string-append
           "Every chat and agent thread in one table, split by group the way "
           "C-x b is. A section is a group, a state, or a model; ; cycles "
           "the grouping. Rows inside a section order by urgency, recency, "
           "title, or context size; , cycles the order. TAB folds the "
           "section at point. A row is two lines: the title with its "
           "queue, turns, context, state, and age; then the running summary "
           "and the model. m marks a chat, SPC toggles the mark, u unmarks "
           "it and U drops every mark. s steers, y and n answer a permission "
           "request for the marked chats, or for the chat at point when "
           "nothing is marked. a archives now and r sets a title. k flags a "
           "runtime to kill, d flags a whole chat to archive, and x runs "
           "the flags. RET opens the chat at point. The last section holds "
           "the newest saved conversations; RET on one reads its file back "
           "and revives the chat.")
    'buffer *agents-buffer*
    'rows (lambda (buf) (chats-rows))
    'row-columns chats-columns
    'row-cells chats-cells
    'separator? chats-separator?
    'section? (lambda (buf e) (chats-heading? e))
    'key (lambda (buf e)
           (if (chats-heading? e)
               (string-append "section:" (chats-heading-key e))
               e))
    'match chats-match?
    'overlays chats-row-overlays
    'local-filter #t
    'title (lambda (buf) "Chats")
    'meta chats-meta
    'total (lambda (buf) (length (filter string? (list-entries buf))))
    'footer chats-footer
    ;; two flags, both destructive, neither irreversible: k stops a runtime
    ;; and keeps the transcript, d drops the chat as well
    'flags (list (list "k" "K" "kill runtime"
                       (lambda (buf b)
                         (and (buffer-exists? b) (agents-kill-runtime! b))))
                 (list "d" "D" "archive"
                       (lambda (buf b)
                         (and (buffer-exists? b)
                              (begin (agents-archive! b) #t)))))
    'noun "chat"
    ;; a heading is not a chat, and an archive row has no runtime, so no
    ;; verb here can act on either
    'markable? (lambda (buf e) (and (string? e) (not (chats-archived-row? e))))
    'preview agents-preview!
    'keys '(("RET" "agents-visit") ("SPC" "list-toggle-mark")
            ("a" "chats-archive") ("r" "chats-retitle")
            ("TAB" "chats-toggle-fold") ("," "chats-toggle-sort")
            (";" "chats-toggle-grouping")
            ("s" "agents-steer") ("y" "agents-allow") ("n" "agents-deny")
            ("g" "agents-refresh") ("+" "agent-open") ("q" "quit-window"))
    ;; line movement remaps to move-and-preview (n is taken: deny)
    'remap '(("next-line" "agents-next") ("previous-line" "agents-prev"))))

(define-command "chat-list" "List every chat: agent threads and API companions"
  (lambda () (list-mode-show! "chats-mode")))

;;; --- C-x c: the chats, as a prompt ----------------------------------------
;;; C-x b, for chats alone. You know a chat by what it is about, so every
;;; row leads with its title -- the name somebody gave it, or the sentence
;;; its running summary wrote -- and the title is what you type at. The
;;; buffer name and the status follow as the annotation, which tells two
;;; chats apart when they read alike. The saved conversations come under
;;; the live ones, and RET on one reads its file back.

(define *chat-prompt-label-width* 62)

(define (chat-prompt-clip s)
  (if (> (string-length s) *chat-prompt-label-width*)
      (string-append (substring s 0 (- *chat-prompt-label-width* 3)) "...")
      s))

;; a titled chat wears its title as its buffer name (chat-title renames
;; it). A derived *chat:group* name is not a title, so the running
;; summary -- the sentence saying what the chat is about -- stands in.
(define (chat-prompt-label b)
  (if (not (string-prefix? "*" b))
      b
      (let ((s (buffer-local b 'chat-summary)))
        (if (and (string? s) (not (equal? s ""))) (chat-prompt-clip s) b))))

;; a row is (LABEL ANNOTATION KIND TARGET); the prompt gets the first
;; three, and the annotation's first two fields are typeable kinds, so
;; "run" narrows to the running chats and "saved" to the archive
(define (chat-prompt-live-row b)
  (list (chat-prompt-label b)
        (string-append (symbol->string (chat-row-status b)) "  " b)
        "chat"
        b))

(define (chat-prompt-saved-row path)
  (list (chat-prompt-clip (chats-archived-title path))
        (string-append "saved  " (format-time (file-mtime path) "%Y-%m-%d %H:%M"))
        "saved"
        path))

;; attention first, then the order you last used them: the chat you were
;; last in is the one you come back to
(define (chat-prompt-live-bufs)
  (let* ((bs (chat-list-bufs))
         (mru (filter (lambda (b) (member b bs)) (buffer-list-mru))))
    (agents-sorted (append mru (filter (lambda (b) (not (member b mru))) bs)))))

(define (chat-prompt-tag r)
  (if (equal? (nth 2 r) "saved") (chat-log-leaf (nth 3 r)) (nth 3 r)))

;; two chats can wear one sentence, and the prompt answers with the
;; label: a repeat takes its buffer name and stays its own row
(define (chat-prompt-rows)
  (let loop ((rs (append (map chat-prompt-live-row (chat-prompt-live-bufs))
                         (map chat-prompt-saved-row (chats-archived-rows))))
             (seen '())
             (out '()))
    (if (null? rs)
        (reverse out)
        (let* ((r (car rs))
               (label (if (member (car r) seen)
                          (string-append (car r) "  (" (chat-prompt-tag r) ")")
                          (car r))))
          (loop (cdr rs) (cons label seen) (cons (cons label (cdr r)) out))))))

(define-command "chat-switch-prompt"
  "Switch to a chat by its title; with a prefix, show it in another window"
  (lambda ()
    (let* ((other-window? (and (current-prefix-arg) #t))
           (here (or (window-buffer (active-window)) (current-buffer)))
           (rows (chat-prompt-rows))
           (row-of (lambda (label) (assoc label rows)))
           (restore-here! (lambda ()
                            (when (buffer-known? here) (window-preview-buffer! here))))
           ;; the preview wakes a sleeping chat; every one nobody picked
           ;; goes back to sleep (the switcher's contract)
           (woken '())
           (sleep-woken! (lambda (keep)
                           (for-each (lambda (b)
                                       (unless (equal? b keep) (buffer-sleep! b)))
                                     woken)
                           (set! woken '()))))
      (if (null? rows)
          (message "No chats")
          (minibuffer-read-preview
            "Chat: "
            (map (lambda (r) (list (nth 0 r) (nth 1 r) (nth 2 r))) rows)
            ;; the invoking window previews the live chat under the
            ;; cursor; a saved conversation is a file, and waits for RET
            (lambda (label)
              (let ((r (row-of label)))
                (when (and r (equal? (nth 2 r) "chat") (buffer-known? (nth 3 r)))
                  (let* ((b (nth 3 r))
                         (sleeping (not (buffer-exists? b))))
                    (window-preview-buffer! b)
                    (when (and sleeping (buffer-exists? b))
                      (restore-buffer-runtime! b)
                      (set! woken (cons b woken)))))))
            (lambda (label)
              (let ((r (row-of label)))
                (cond
                  ((not r) (restore-here!) (message "No chat by that name"))
                  ((equal? (nth 2 r) "saved")
                   (restore-here!)
                   (visit-in-group (nth 3 r) (frame-group))
                   (end-of-buffer!))
                  (other-window?
                   (restore-here!)
                   (let ((win (display-buffer-other-window! (nth 3 r))))
                     (when win (select-window! win))))
                  (else (switch-to-buffer! (nth 3 r)) (end-of-buffer!)))
                (sleep-woken! (and r (nth 3 r)))))
            ;; C-g: the window takes back what it was showing
            (lambda () (restore-here!) (sleep-woken! #f))
            ;; the status and the buffer name match what you type, so a
            ;; chat is found by its title first and by its state second
            2)))))


(define (agents-attention)
  (let loop ((ts (agent-threads)) (acc '()))
    (cond ((null? ts) (reverse acc))
          ((equal? (car (cdr (car ts))) 'needs_attention)
           (loop (cdr ts) (cons (car (car ts)) acc)))
          (else (loop (cdr ts) acc)))))

(define *agents-attention-last* #f)

(define (agents-modeline-refresh!)
  (let* ((att (agents-attention))
         (text (if (null? att) #f (string-append "! " (string-join att " ")))))
    ;; unchanged is not news: the old refresh repainted the modeline of
    ;; every frame on every event batch to say the same thing
    (unless (equal? text *agents-attention-last*)
      (set! *agents-attention-last* text)
      (global-mode-string-set! 'agents-attention
        (if text (list "ml-attention" text) #f)))))

(define-command "agent-goto-attention" "Jump to the first thread needing attention"
  (lambda ()
    (let ((att (agents-attention)))
      (if (null? att)
          (message "no agent needs attention")
          (begin (switch-to-buffer! (agent-buf (car att)))
                 (end-of-buffer!))))))

(define-key "agent-map" "n" "agent-open")

(define-key "agent-map" "l" "chat-list")

(define-key "agent-map" "a" "agent-goto-attention")

;; C-x b is the buffers; C-x c is the chats. The same prompt, the same
;; keys, one pool.
(global-set-key "C-x c" "chat-switch-prompt")

(category! 'chat)
(catalog-meta! 'command "chats-archive" 'domain 'chat 'effects '(destroy))
(public! 'chats-set-grouping!
  "(chats-set-grouping! MODE) — section the *chats* table by 'group, 'state, or 'model")
(public! 'chats-set-sort!
  "(chats-set-sort! MODE) — order the rows of a section by 'urgency, 'recent, 'title, or 'tokens")
(public! 'chats-toggle-fold!
  "(chats-toggle-fold! KEY) — fold or unfold the section KEY names")
(public! 'chats-note-activity!
  "(chats-note-activity! BUF) — stamp the time of the last event that reached the chat BUF")
(public! 'chats-state-label
  "(chats-state-label STATUS) — the words a *chats* row shows for a runtime status")
