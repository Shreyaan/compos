;;; agent-fleet.scm --- Chat fleet list, archive, and attention UI.
;;;
;;; This module owns the *chats* list and actions across chat buffers. Runtime
;;; lifecycle and transcript rendering remain in agent.scm.

(domain! 'chat)
(effects! '(write))
(category! 'chat)

(define *agents-buffer* "*chats*")


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
                ;; the title if the file carries one; a file written
                ;; before titles existed answers with its last summary
                (s (and head (or (plist-get head 'title)
                                 (plist-get head 'summary)))))
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

;;; --- the chat rows in the ibuffer template --------------------------------------
;;; *chats* is the ibuffer table over the chat buffers: the same sections,
;;; sort, folds, marks and keys, with the chat verbs added. The table
;;; asks a row's kind what to show; the chat kind and the archived kind
;;; are registered here. C-x C-c opens it in a window, as C-x C-b opens
;;; the buffers; C-x c is the same rows as a prompt.

;;; --- last activity ------------------------------------------------------------
;;; The editor keeps no clock on a chat. This table notes the time the
;;; last event batch reached each chat. It starts empty at boot, so a
;;; chat with no event since the restart shows the time it was last seen.

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

(define (chats-model b)
  (or (buffer-local b 'agent-model) (buffer-local b 'llm-model) ""))

;; the context tokens stand in for the size of a chat: what the size
;; column shows, what the size sort reads, what a heading adds up
(define (chats-tokens b)
  (let ((n (buffer-local b 'chat-context-used)))
    (and (number? n) (> n 0) n)))

(define (chats-summary b)
  (let ((s (buffer-local b 'chat-summary)))
    (and (string? s) (not (equal? s "")) s)))

;; the row names the chat by its title -- the name somebody gave it, or
;; the first label its summary wrote -- else its buffer name. The table
;; is the broad form, in a window or in the wide C-x c popup, so the
;; whole title stands; only the narrow candidate line clips.
(define (chats-title b) (chat-prompt-full-label b))

(define (chats-match-text b)
  (string-append (chats-title b) " "
                 (or (chats-summary b) "") " "
                 (chats-model b) " "
                 (chats-state-label (chat-row-status b)) " "
                 (or (buffer-local b 'agent-slug) "")))

(ibuffer-kind! 'chat
  (list 'when? (lambda (b) (and (buffer-known? b) (chat-buffer? b)))
        'dot (lambda (b)
               (let ((s (chat-row-status b)))
                 (list (agent-status-glyph s) (chats-state-face s))))
        'name (lambda (b) (list "" (chats-title b)))
        'size chats-tokens
        'label (lambda (b) (chats-state-label (chat-row-status b)))
        'last (lambda (b)
                (let ((t (chats-activity-at b)))
                  (if t (chats-age-label t) (ibuffer-last-label b))))
        'match chats-match-text
        'face (lambda (b)
                (if (equal? (chat-row-status b) 'needs_attention) "alert" "accent"))
        'modified? (lambda (b) #f)))

;; a saved conversation is a file no buffer holds
(ibuffer-kind! 'archived
  (list 'when? (lambda (b) (and (not (buffer-known? b)) (string-suffix? ".chat" b)))
        'dot (lambda (b) (list "." "faint"))
        'name (lambda (b) (list "" (chats-archived-title b)))
        'size (lambda (b) #f)
        'label (lambda (b) "archived")
        'match (lambda (b) (string-append (chats-archived-title b) " archived"))
        'face (lambda (b) "dim")
        'modified? (lambda (b) #f)))

(ibuffer-scope! 'chats (lambda () (chat-list-bufs)))

;; No key bar over the rows: ? shows every key with the mode's own
;; words, the same as the buffers table.
(ibuffer-view! *agents-buffer* 'sort 'recent)

;; the table's rows, then the saved conversations as the last section
(define (chats-rows buf)
  (append (ibuffer-rows buf)
          (ibuffer-section buf "archived" "archived" (chats-archived-rows) "faint" #t)))

(effects! '(write))

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

(define-command "chats-retitle" "Give the chat at point a title"
  (lambda ()
    (let ((b (ibuffer-current *agents-buffer*)))
      (if (not (and (string? b) (buffer-exists? b)))
          (message "no chat here")
          (minibuffer-read
            (string-append "Title for " b ": ")
            '()
            (lambda (name)
              (unless (equal? name "")
                (chat-title b name)
                (list-refresh! *agents-buffer*))))))))

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

(mode-icon! "ichat-mode" "")

(define-list-mode! "ichat-mode"
  (ibuffer-mode-opts
    (list
      'doc (string-append
             "Every chat and agent thread in the ibuffer table, split by "
             "group the way C-x b is. A section is a group, a state, or a "
             "model-less mode; ; cycles the grouping. Rows inside a section "
             "sort by name, recency, or context size; , cycles the sort. "
             "TAB folds the section at point. A row shows the state glyph, "
             "the title, and on the right the context tokens, the state, "
             "and the age of the last event. m marks a chat, SPC toggles "
             "the mark, u unmarks it and U drops every mark. s steers, y and "
             "n answer a permission request for the marked chats, or for the "
             "chat at point when nothing is marked. a archives now and r "
             "sets a title. k flags a runtime to kill, d flags a whole chat "
             "to archive, and x runs the flags. RET opens the chat at point. "
             "The last section holds the newest saved conversations; RET on "
             "one reads its file back and revives the chat.")
      'buffer *agents-buffer*
      'category 'chat
      ;; a chat's title is the whole row: nothing else on the line repeats
      ;; it, so the name column takes every column the fields leave
      'name-fit 'full
      'title (lambda (buf) "Chats")
      'noun "chat"
      'rows (lambda (buf) (chats-rows buf))
      ;; two flags, both destructive, neither irreversible: k stops a runtime
      ;; and keeps the transcript, d drops the chat as well
      'flags (list (list "k" "K" "kill runtime"
                         (lambda (buf b)
                           (and (buffer-exists? b) (agents-kill-runtime! b))))
                   (list "d" "D" "archive"
                         (lambda (buf b)
                           (and (buffer-exists? b)
                                (begin (agents-archive! b) #t)))))
      ;; a heading is not a chat, and an archive row has no runtime, so no
      ;; verb here can act on either
      'markable? (lambda (buf e) (and (string? e) (buffer-known? e)))
      'keys '(("s" "agents-steer") ("y" "agents-allow") ("n" "agents-deny")
              ("a" "chats-archive") ("r" "chats-retitle")
              ("+" "agent-open")))))

(define (ichat-open!)
  (ibuffer-open! 'chats *agents-buffer* "ichat-mode"))

;; C-x c: the same table in the minibuffer form, with its own view so
;; the sort and the folds of *chats* stay what you set them to
(define *ichat-prompt-buffer* " *chats*")
(add-display-rule! *ichat-prompt-buffer* 'popup '(side bottom size 0.4))
(ibuffer-view! *ichat-prompt-buffer* 'sort 'recent)

(define-command "ichat-prompt"
  "Switch to a chat from the table"
  (lambda ()
    (ibuffer-prompt! 'chats *ichat-prompt-buffer* "ichat-mode" "Chat: "
      (lambda (row close!)
        (ibuffer-pick! row close!)
        (when (buffer-known? row) (end-of-buffer!))))))

(define-command "chat-list" "List every chat: agent threads and API companions"
  (lambda () (ichat-open!)))

(define-command "ichat" "List every chat in the ibuffer table"
  (lambda () (ichat-open!)))

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
;; it). A derived *chat:group* name is not a title, so the chat's own
;; title -- the first label its running summary wrote -- stands in.
;; The whole title: a broad list shows it in full.
(define (chat-prompt-full-label b)
  (if (not (string-prefix? "*" b))
      b
      (let ((s (chat-title-of b)))
        (if (and (string? s) (not (equal? s ""))) s b))))

;; the narrow form: one candidate line beside an annotation, so it clips
(define (chat-prompt-label b) (chat-prompt-clip (chat-prompt-full-label b)))

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
        (string-append "archived  " (format-time (file-mtime path) "%Y-%m-%d %H:%M"))
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
(define (chat-prompt-unique-rows rows)
  (let loop ((rs rows) (seen '()) (out '()))
    (if (null? rs)
        (reverse out)
        (let* ((r (car rs))
               (label (if (member (car r) seen)
                          (string-append (car r) "  (" (chat-prompt-tag r) ")")
                          (car r))))
          (loop (cdr rs) (cons label seen) (cons (cons label (cdr r)) out))))))

;; a heading row is (LABEL "" "separator"): the prompt steps over it and
;; drops it when its section empties, as C-x b does
(define (chat-prompt-separator label) (list label "" "separator"))

(define (chat-prompt-separator? r) (equal? (nth 2 r) "separator"))

(define (chat-prompt-section label rows)
  (if (pair? rows) (cons (chat-prompt-separator label) rows) '()))

;; the rows in sections by group, the way C-x b is: this group's chats
;; first, then the other groups by name, then the chats no group claims,
;; then the archived conversations
(define (chat-prompt-sectioned-rows live saved current)
  (let* ((tagged (map (lambda (r) (cons (buffer-group (nth 3 r)) r)) live))
         (rows-of (lambda (id)
                    (map cdr (filter (lambda (t) (equal? (car t) id)) tagged))))
         (named (sort (map (lambda (id)
                             (list (string-downcase (or (group-name id) "")) id))
                           (filter (lambda (id) (not (equal? id current)))
                                   (group-ids)))))
         (ordered (append (if current (list current) '()) (map cadr named)))
         (ungrouped (map cdr (filter (lambda (t) (not (member (car t) ordered)))
                                     tagged))))
    (append
      (fold (lambda (out id)
              (append out
                (chat-prompt-section
                  (if (equal? id current) "in this group" (or (group-name id) id))
                  (rows-of id))))
            '() ordered)
      (chat-prompt-section "ungrouped" ungrouped)
      (chat-prompt-section "archived" saved))))

(define (chat-prompt-rows &optional current)
  (let ((rows (chat-prompt-unique-rows
                (append (map chat-prompt-live-row (chat-prompt-live-bufs))
                        (map chat-prompt-saved-row (chats-archived-rows))))))
    (chat-prompt-sectioned-rows
      (filter (lambda (r) (equal? (nth 2 r) "chat")) rows)
      (filter (lambda (r) (equal? (nth 2 r) "saved")) rows)
      current)))

(define-command "chat-switch-prompt"
  "Switch to a chat by its title; with a prefix, show it in another window"
  (lambda ()
    (let* ((other-window? (and (current-prefix-arg) #t))
           (here (or (window-buffer (active-window)) (current-buffer)))
           (rows (chat-prompt-rows
                   (or (buffer-group here)
                       (and (boundp 'frame-group) (frame-group)))))
           ;; a heading is not a chat: typing its label names nothing
           (row-of (lambda (label)
                     (let ((r (assoc label rows)))
                       (and r (not (chat-prompt-separator? r)) r))))
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

;; C-x C-b is the buffers in a window; C-x C-c is the chats in the same table
(define-key "ctl-x-map" "C-c" "ichat")

(define-key "agent-map" "a" "agent-goto-attention")

;; C-x b is the buffers; C-x c is the chats: the same table, the same
;; keys. chat-switch-prompt, the candidate prompt, stays for the surfaces
;; that draw only a prompt.
(global-set-key "C-x c" "ichat-prompt")

(category! 'chat)
(catalog-meta! 'command "chats-archive" 'domain 'chat 'effects '(destroy))
(public! 'chats-note-activity!
  "(chats-note-activity! BUF) — stamp the time of the last event that reached the chat BUF")
(public! 'chats-state-label
  "(chats-state-label STATUS) — the words a *chats* row shows for a runtime status")
