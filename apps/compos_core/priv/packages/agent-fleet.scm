;;; agent-fleet.scm --- Chat fleet list, archive, and attention UI.
;;;
;;; This module owns the *chat-list* application and the actions across chat
;;; buffers. Runtime lifecycle and transcript rendering remain in agent.scm.

(domain! 'chat)
(effects! '(write))
(category! 'chat)

;; one list over the chats: the application's buffer, which every fleet
;; action reads its targets from. docs/CHAT-LIST.md is the contract.
(define *chat-list-buffer* "*chat-list*")


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

;; Every chat, most recently used first. The order is the editor's one
;; MRU, so a view that sorts by recency reads it and sorts nothing: the
;; chat you were last in leads the table. The MRU names sleeping chats
;; too, and (buffer-list) catches a chat nobody has shown yet.
(define (chat-list-buf? b)
  (and (not (string-prefix? " " b))
       (or (buffer-local b 'agent-slug) (chat-buffer? b))))

(define (chat-list-bufs)
  (let ((mru (filter chat-list-buf? (buffer-list-mru))))
    (append mru
            (filter (lambda (b) (and (chat-list-buf? b) (not (member b mru))))
                    (buffer-list)))))

;; the ibuffer row kind asks this three times for one row (dot, label,
;; face), and a read from a chat buffer's own process is far slower than
;; from a plain one. The second and third ask of the same row reuse the
;; first's answer instead of paying its cost again.
(define *chat-row-status-memo* (list #f #f))

(define (chat-row-status b)
  (if (equal? (car *chat-row-status-memo*) b)
      (cadr *chat-row-status-memo*)
      (let* ((slug (buffer-local b 'agent-slug))
             (status (if slug (agent-status slug) 'api)))
        (set! *chat-row-status-memo* (list b status))
        status)))

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
  "How many saved chats the candidate prompt shows below the live ones."
  'group 'chat 'type 'integer)

(define (chats-live-log-paths)
  (let loop ((bs (chat-list-bufs)) (acc '()))
    (if (null? bs)
        acc
        (let ((id (buffer-local (car bs) 'chat-log-id)))
          (loop (cdr bs)
                (if id
                    (cons (string-append (chat-log-dir-for (car bs)) "/" id ".chat") acc)
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

;; The colours a chat's state wears. They are this package's defaults,
;; so a theme can say otherwise, and they are the ones the design names:
;; a live chat teal, a stopped one coral, an idle one out of the way.
(defface! 'chat-live 'fg "#6fb8a5")
(defface! 'chat-stopped 'fg "#e08d78")
(defface! 'chat-idle 'fg "#4a4660")
(defface! 'chat-archived 'fg "#3a3746")

(define (chats-state-face status)
  (cond ((equal? status 'needs_attention) "alert")
        ((or (equal? status 'running) (equal? status 'starting)) "chat-live")
        ((equal? status 'dead) "chat-stopped")
        (else "chat-idle")))

(define (chats-model b)
  (or (buffer-local b 'agent-model) (buffer-local b 'llm-model) ""))

;; the size of a chat is the size of its transcript on disk -- the
;; number dired would show for that file: what the size column shows,
;; what the size sort reads, what a heading adds up. A chat that has
;; not written its file yet has no size to show
(define (chats-filesize b)
  ;; the id the chat already carries, never a fresh one: drawing a row
  ;; must not name a file the chat has not asked for
  (let ((id (buffer-local b 'chat-log-id)))
    (and (string? id)
         (let ((p (string-append (chat-log-dir-for b) "/" id ".chat")))
           (and (file-exists? p) (file-size p))))))

(define (chats-summary b)
  (let ((s (buffer-local b 'chat-summary)))
    (and (string? s) (not (equal? s "")) s)))

;; the row names the chat by its title -- the name somebody gave it, or
;; the first label its summary wrote -- else its buffer name. The table
;; is the broad form, in a window or in the wide C-x c popup, so the
;; whole title stands; only the narrow candidate line clips.
(define (chats-title b) (chat-prompt-full-label b))

;; a chat needing a reply wears its alert glyph in the name itself, so it
;; survives even a narrow table that drops the dot and label columns
(define (chats-alert-name b)
  (if (equal? (chat-row-status b) 'needs_attention)
      (string-append "! " (chats-title b))
      (chats-title b)))

(define (chats-match-text b)
  ;; the name filter reads the title first and the state second; a chat the
  ;; keyword search found carries its snippet here as well, so one filter
  ;; line keeps both the chats named like this and the chats that say it
  (string-append (chats-title b) " "
                 (or (chats-summary b) "") " "
                 (chats-model b) " "
                 (chats-state-label (chat-row-status b)) " "
                 (or (buffer-local b 'agent-slug) "") " "
                 (or (chat-list-hit b) "")))

(ibuffer-kind! 'chat
  (list 'when? (lambda (b) (and (buffer-known? b) (chat-buffer? b)))
        ;; a round dot, lit by what the chat is doing: the eye reads a
        ;; colour before it reads a word, and the live one pulses
        'dot (lambda (b)
               (let ((s (chat-row-status b)))
                 (list (if (equal? s 'needs_attention) "!" "●")
                       (chats-state-face s))))
        'name (lambda (b) (list "" (chats-alert-name b)))
        'size chats-filesize
        ;; a chat found by a word in its text says which word, in place of
        ;; the state: you searched for the words, not for the state
        'label (lambda (b)
                 (let ((hit (chat-list-hit b)))
                   (if hit
                       (chat-prompt-clip hit)
                       (chats-state-label (chat-row-status b)))))
        'last (lambda (b)
                (let ((t (chats-activity-at b)))
                  (if t (chats-age-label t) (ibuffer-last-label b))))
        ;; by name, not by value: a reload redefines chats-match-text after
        ;; this form runs, and a captured procedure would stay the old one
        'match (lambda (b) (chats-match-text b))
        'face (lambda (b)
                (if (equal? (chat-row-status b) 'needs_attention) "alert" "accent"))
        'modified? (lambda (b) #f)))

;; a saved conversation is a file no buffer holds
(ibuffer-kind! 'archived
  (list 'when? (lambda (b) (and (not (buffer-known? b)) (string-suffix? ".chat" b)))
        'dot (lambda (b) (list "●" "chat-archived"))
        'name (lambda (b) (list "" (chats-archived-title b)))
        ;; the row is the file, so its size is the file's own
        'size (lambda (b) (and (file-exists? b) (file-size b)))
        'label (lambda (b) "archived")
        'match (lambda (b) (string-append (chats-archived-title b) " archived"))
        'face (lambda (b) "dim")
        'modified? (lambda (b) #f)))

(effects! '(write))

;; The chat list is a still picture. A streaming turn hands the fleet an
;; event batch many times a second, and a list that redraws under the
;; reader re-sorts its rows and carries the cursor off the chat they were
;; reading. So no event ever draws it. The modeline carries the news
;; instead, and g draws the list again when the reader asks for it.
(define (agents-refresh!)
  (when (buffer-known? *chat-list-buffer*)
    (list-refresh! *chat-list-buffer*)))

;; a verb ran on the chat at point, so the row it acted on is stale and so
;; is the pane that previews it: the list draws again and looks again
(define (agents-relist!)
  (when (buffer-known? *chat-list-buffer*)
    (list-refresh! *chat-list-buffer*)
    (chat-list-preview!)))

;; the fleet's surfaces after an event batch: the modeline answers, and
;; it answers alone -- the chat list is never drawn behind its reader.
(define (agents-note-event! &optional slug)
  (when slug (chats-note-activity! (agent-buf slug)))
  (agents-modeline-refresh!))

(define (agents-current-buf)
  (let ((row (list-current *chat-list-buffer*)))
    (and (string? row) row)))

(define (agents-current-slug)
  (let ((b (agents-current-buf)))
    (and b (buffer-local b 'agent-slug))))

;; the chats a verb acts on: the row at point, or every chat under it
;; when that row is a group
(define (agents-targets)
  (filter (lambda (b) (buffer-exists? b)) (ibuffer-targets *chat-list-buffer*)))

(define (agents-report verb bs)
  (message (if (= (length bs) 1)
               (string-append verb " " (car bs))
               (string-append verb " " (number->string (length bs)) " chats"))))

(define-command "chats-retitle" "Give the chat at point a title"
  (lambda ()
    (let ((b (ibuffer-current *chat-list-buffer*)))
      (if (not (and (string? b) (buffer-exists? b)))
          (message "no chat here")
          (minibuffer-read
            (string-append "Title for " b ": ")
            '()
            (lambda (name)
              (unless (equal? name "")
                (chat-title b name)
                (agents-relist!))))))))

(define (agents-live-slug buf)
  (let ((slug (or (buffer-local buf 'agent-slug) (chat-ensure-runtime! buf))))
    (if (equal? (agent-status slug) 'dead) (agent-revive! slug) slug)))

(define-command "agents-steer" "Send a steering message to the chat at point"
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
                (agents-relist!)
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
          (agents-relist!)
          (agents-report verb bs)))))

(define-command "agents-allow" "Allow the pending permission of the chat at point"
  (lambda () (agents-answer! "allow_once" "allow" "allowed")))

(define-command "agents-deny" "Deny the pending permission of the chat at point"
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
  "Archive the chat at point: the runtime stops, the buffer goes, the file stays"
  (lambda ()
    (let ((bs (agents-targets)))
      (if (null? bs)
          (message "no chat here")
          (begin
            (for-each agents-archive! bs)
            (agents-relist!)
            (agents-report "archived" bs))))))

;; k stops the runtime and keeps the transcript: the chat stays in the
;; list, readable, and the next message you send revives it
(define-command "chats-kill-runtime"
  "Stop the runtime of the chat at point and keep its transcript"
  (lambda ()
    (let ((bs (filter agents-kill-runtime! (agents-targets))))
      (if (null? bs)
          (message "no chat with a runtime here")
          (begin (agents-relist!) (agents-report "stopped" bs))))))

;;; --- the chats, as a candidate prompt -------------------------------------
;;; The chat list is the application; this is the same chats drawn as a
;;; plain candidate prompt, for a surface that can only draw one.
;;; You know a chat by what it is about, so every
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
(define (chat-prompt-live-bufs) (chat-list-bufs))

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
                  (or (group-name id) id)
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

;; C-x C-b is the buffers in a window; C-x C-c is the chats. There is one
;; chat list and one arrival, so both keys reach the same application.
(define-key "ctl-x-map" "C-c" "chat-list")

(define-key "agent-map" "a" "agent-goto-attention")

;; C-x b is the buffers; C-x c is the chats. chat-switch-prompt, the
;; candidate prompt, stays for the surfaces that draw only a prompt.
(global-set-key "C-x c" "chat-list")

(category! 'chat)
(catalog-meta! 'command "chats-archive" 'domain 'chat 'effects '(destroy))
(catalog-meta! 'command "chats-kill-runtime" 'domain 'chat 'effects '(destroy))
(public! 'chats-note-activity!
  "(chats-note-activity! BUF) — stamp the time of the last event that reached the chat BUF")
(public! 'chats-state-label
  "(chats-state-label STATUS) — the words a chat list row shows for a runtime status")


;;; ------------------------------------------------------------ the chat list
;; The chat list is an application: one state, one buffer, one group, one
;; arrival. You open it to switch to a chat whose name you half remember,
;; and it leaves as soon as you pick one. docs/CHAT-LIST.md is the contract.
(category! 'chat)
(effects! '(write display))

(define *chat-list-buffer* "*chat-list*")
(define *chat-list-group-name* "chat-list")
(define *chat-list-groupings* '(none group state model))

(defcustom 'chat-list-recent-limit 40
  "How many chats the chat list shows at rest. A search reads every chat.")

(define (chat-list-query)
  (if (buffer-known? *chat-list-buffer*)
      (or (buffer-local *chat-list-buffer* 'chat-list-search) (list-query *chat-list-buffer*))
      ""))

;; at rest the list is the recent chats; the moment you type, the scope is
;; every chat, so the limit bounds the resting list and never the search
(define (chat-list-scope)
  (let ((all (chat-list-bufs)))
    (if (equal? (chat-list-query) "")
        (take-n all chat-list-recent-limit)
        all)))
(ibuffer-scope! 'chat-list (lambda () (chat-list-scope)))

;; A keyword search reads the text of every alive chat. Alive is every chat
;; that is not archived: an awake one answers from its buffer and a sleeping
;; one from its log file, so the search wakes nothing. Typing narrows, so a
;; query that extends the last one searches only what the last one found.
(define *chat-list-hits* '())        ; (QUERY (BUF SNIPPET) ...)
(define *chat-list-text-cache* '())  ; (BUF TEXT), lowercase, one search burst

(define (chat-list-text b)
  (let ((memo (assoc b *chat-list-text-cache*)))
    (if memo
        (cadr memo)
        (let* ((raw (if (buffer-exists? b)
                        (buffer-text b)
                        (let ((path (ignore-errors (lambda () (chat-log-path b)))))
                          (and (string? path)
                               (file-exists? path)
                               (ignore-errors (lambda () (read-file path)))))))
               (text (string-downcase (if (string? raw) raw ""))))
          (set! *chat-list-text-cache* (cons (list b text) *chat-list-text-cache*))
          text))))

;; the row shows why it matched, so the words around the hit stand in for
;; the line: a transcript holds no short lines to quote
(define (chat-list-snippet text at)
  ;; string-index answers in bytes, so the window is in bytes as well
  (let* ((from (max 0 (- at 40)))
         (to (min (string-byte-length text) (+ at 80))))
    (string-join (string-split (substring-bytes text from to) "\n") " ")))

(define (chat-list-search-hits q)
  (let* ((q (string-downcase (string-trim q)))
         (last (if (pair? *chat-list-hits*) (car *chat-list-hits*) ""))
         ;; a longer query can only match where the shorter one did
         (pool (if (and (not (equal? last ""))
                        (string-prefix? last q))
                   (map car (cdr *chat-list-hits*))
                   (chat-list-bufs))))
    (set! *chat-list-hits*
      (cons q
            (if (< (string-length q) 3)
                '()
                (fold (lambda (out b)
                        (let* ((text (chat-list-text b))
                               (at (string-index text q)))
                          (if at
                              (append out (list (list b (chat-list-snippet text at))))
                              out)))
                      '()
                      pool))))
    (cdr *chat-list-hits*)))

(define (chat-list-hit b)
  (let ((e (assoc b (if (pair? *chat-list-hits*) (cdr *chat-list-hits*) '()))))
    (and e (cadr e))))

(define (chat-list-search-reset!)
  (set! *chat-list-hits* '())
  (set! *chat-list-text-cache* '()))

;; a section is a group, a state or a model, and none is the flat list in
;; most recently used order: the order you last used a chat is the one the
;; half-remembered name arrives in
;; a chat that is running is the one thing about a section you want
;; before you open it; a section with none says only how many it holds
(define (chats-live-note members)
  (let ((live (length (filter (lambda (b)
                                (and (buffer-known? b)
                                     (member (chat-row-status b) '(running starting))))
                              (filter string? members)))))
    (if (> live 0) (string-append (number->string live) " live") "")))

(define (chat-list-rows buf)
  (ibuffer-columns-clear!)
  (let ((grouping (ibuffer-grouping buf)))
    (append
      (if (member grouping '(state model))
          (let ((rows (ibuffer-source buf)))
            (ibuffer-note-kinds! rows)
            (ibuffer-keyed-sections buf rows
              (if (equal? grouping 'state)
                  (lambda (b) (chats-state-label (chat-row-status b)))
                  (lambda (b) (let ((m (chats-model b)))
                                (if (equal? m "") "no model" m))))
              (lambda (k) "faint")
              #f))
          (ibuffer-rows buf))
      ;; a chat you archived is still a chat you switch to: the saved
      ;; conversations come under the live ones, and RET on one reads its
      ;; file back
      (ibuffer-section buf "archived" "archived" (chats-archived-rows) "faint" #t))))

(mode-icon! "chat-list-mode" "")
(define-list-mode! "chat-list-mode"
  (ibuffer-mode-opts
    (list
      'transient #f
      'composml-root (lambda (buf) (list 'tag "chat-list"))
      'composml-record (lambda (buf entry) (ibuffer-composml-record buf entry))
      'doc (string-append
             "The chat list: one application, one state, one group. The rows "
             "are the recent chats, most recently used first. The list has the "
             "focus, so n and p move and the row under the cursor shows its "
             "chat in the preview pane. / opens the filter line: the filter "
             "reads the title first and the state second, and it reads every "
             "chat, not only the recent ones. A word that nobody put in a "
             "title is found in the text of every alive chat, and the row "
             "shows the words around it. C-g closes the filter and leaves the "
             "list standing. RET enters the chat's own group and raises the "
             "window that holds it; q leaves and changes nothing. ; cycles "
             "what a section is: none, group, state, model. , cycles the "
             "order inside a section: most recent first, by name, or by the "
             "size of the transcript on disk. The verbs act on the chat at point "
             "and leave the list standing: s steers it, y and d answer the "
             "permission it waits on, r gives it a title, k stops its "
             "runtime and keeps the transcript, a archives it, g draws the "
             "list again and + starts a new chat. The last section holds "
             "the newest saved conversations; RET on one reads its file "
             "back and revives the chat.")
      'buffer *chat-list-buffer*
      'category 'chat
      'title (lambda (buf) "Chats")
      'noun "chat"
      ;; what a section of chats is worth saying beyond how many: how
      ;; many of them are running right now
      'section-note (lambda (buf members) (chats-live-note members))
      'rows (lambda (buf) (chat-list-rows buf))
      ;; The table stamps itself with the buffer count and redraws after
      ;; any command that moved it, so a buffer opened anywhere -- by a
      ;; chat you are not even reading -- rebuilt this list under the
      ;; cursor. An application is not a table: it stands still, and g
      ;; draws it again when you ask. No stamp, no redraw behind you.
      'stamp #f
      ;; the picker acts on one chat, the one at point: no marks, and no
      ;; flag-then-run, which is a table's idea and not an application's
      'markable? (lambda (buf e) #f)
      'flags '()
      ;; n and p move, so the answer keys are y and d, and k stops a
      ;; runtime without touching the transcript the way the table's k
      ;; would kill the buffer outright
      'keys '((";" "chat-list-regroup") ("," "chat-list-resort")
              ("/" "chat-list-filter") ("RET" "chat-list-visit")
              ("q" "chat-list-quit")
              ("s" "agents-steer") ("y" "agents-allow") ("d" "agents-deny")
              ("a" "chats-archive") ("r" "chats-retitle")
              ("k" "chats-kill-runtime") ("g" "agents-refresh")
              ("+" "agent-open")))))
;; The list rests in sections, one per group: a chat belongs to the work
;; it was opened for, and the group it sits in says which. ; cycles that
;; away for a flat table when you want one.
(ibuffer-view! *chat-list-buffer* 'sort 'recent 'grouping 'group)

;; ---- the application

(define (chat-list-group) (group-ensure-record! *chat-list-group-name*))

;; one arrival: the list at two thirds, the preview at one third, the focus
;; on the list. The application is always in its own group and never joins
;; the group you came from.
(define (chat-list-arrive!)
  (let ((from (frame-group))
        ;; what the frame showed before the application took it: leaving
        ;; puts this back, so the list is never left standing
        (was (let ((b (window-buffer (active-window))))
               (if (equal? b *chat-list-buffer*)
                   (buffer-local *chat-list-buffer* 'chat-list-from-buffer)
                   b)))
        (held (or (group-pinned) 'none)))
    (buffer-create *chat-list-buffer*)
    (buffer-add-group! *chat-list-buffer* (chat-list-group))
    (switch-to-group! (chat-list-group))
    ;; the preview pane shows a chat this group does not hold, and the
    ;; frame's group is derived from the buffers its windows show: without
    ;; a pin, looking at a row would move the frame into that chat's group
    (set-frame-local! 'pinned-group (chat-list-group))
    (delete-other-windows!)
    (switch-to-buffer! *chat-list-buffer*)
    (split-window! 'h 0.67)
    (let ((preview (other-work-window-id (active-window))))
      (buffer-set-locals! *chat-list-buffer*
        (list 'chat-list-from-group from
              'chat-list-from-buffer was
              'chat-list-from-pin held
              'chat-list-preview-window preview
              'line-numbers "off"))
      preview)))

;; the pin is the application's, so it goes back the way it was found
(define (chat-list-unpin!)
  (let ((held (buffer-local *chat-list-buffer* 'chat-list-from-pin)))
    (when (equal? (group-pinned) (chat-list-group))
      (set-frame-local! 'pinned-group (if (or (not held) (equal? held 'none)) #f held)))
    (buffer-set-local! *chat-list-buffer* 'chat-list-from-pin #f)))

(define (chat-list-preview-window)
  (let ((w (buffer-local *chat-list-buffer* 'chat-list-preview-window)))
    (and w (window-exists? w) w)))

;; looking costs nothing: the preview shows the transcript of a sleeping
;; chat and never starts its runtime. Only the chat you pick wakes.
(define (chat-list-preview!)
  (let ((b (list-current *chat-list-buffer*))
        (win (chat-list-preview-window)))
    (when (and win (string? b) (buffer-known? b)
               (not (equal? b *chat-list-buffer*)))
      (window-preview-buffer! b win))))

;; the application leaves the way it arrived: with one move. RET lands you
;; in the chat, in the chat's own group, because switching to a chat is
;; switching to where that chat lives. C-g puts the frame back.
(define (chat-list-clear-search!)
  (chat-list-search-reset!)
  (when (buffer-known? *chat-list-buffer*)
    (buffer-set-local! *chat-list-buffer* 'chat-list-search #f)
    (list-set-query! *chat-list-buffer* "")))

;; the list owns the focus, so every way back into it is the same move
(define (chat-list-focus!)
  (let ((w (window-showing *chat-list-buffer*)))
    (when (and w (window-exists? w)) (select-window! w))))

;; a chat is pinned to the pane its mode owns, so keeping one is never a
;; switch in the window you are standing in: enter the chat's own group and
;; raise the window that already holds it
;; a chat is pinned to the pane its mode owns, so the window that already
;; holds it comes first, then the group's own chat pane, and the active
;; window only when the group shows no chat at all
(define (chat-list-chat-window keep)
  (or (window-showing keep)
      (let loop ((ws (window-list)))
        (cond ((null? ws) #f)
              ((and (string? (cadr (car ws)))
                    (not (equal? (cadr (car ws)) *chat-list-buffer*))
                    (chat-buffer? (cadr (car ws))))
               (car (car ws)))
              (else (loop (cdr ws)))))))

;; keeping a chat is never a switch in the window you are standing in:
;; leave the application's pin behind, enter the chat's own group, and
;; raise the window that holds it
(define (chat-list-keep! keep)
  (chat-list-clear-search!)
  (chat-list-unpin!)
  (chat-list-release-frame!)
  (let ((id (group-home-of keep)))
    (when (and id (not (equal? id (frame-group)))) (switch-to-group! id)))
  (let ((w (chat-list-chat-window keep)))
    (if (and w (window-exists? w))
        (begin
          (select-window! w)
          (unless (equal? (window-buffer w) keep) (switch-to-buffer-here! keep)))
        (switch-to-buffer! keep)))
  (when (equal? (window-buffer (active-window)) keep) (end-of-buffer!)))

;; the application took the whole frame on arrival, so it hands the whole
;; frame back: the panes it made go, and the window it stood in shows what
;; it showed before. A group that keeps its own layout has already put that
;; back, and then no window shows the list and there is nothing to undo.
(define (chat-list-release-frame!)
  (let ((w (window-showing *chat-list-buffer*))
        (was (buffer-local *chat-list-buffer* 'chat-list-from-buffer)))
    (when (and w (window-exists? w))
      (select-window! w)
      (delete-other-windows!)
      (switch-to-buffer-here!
        (if (and (string? was) (buffer-known? was)) was "*scratch*")))))

(define (chat-list-back!)
  (chat-list-clear-search!)
  (chat-list-unpin!)
  (let ((from (buffer-local *chat-list-buffer* 'chat-list-from-group)))
    (when from (switch-to-group! from)))
  (chat-list-release-frame!))

;; a saved conversation is a file and has no group of its own, so reading
;; it back lands it where you stood when you asked for it
(define (chat-list-revive! path)
  (chat-list-back!)
  (visit-in-group path (and (boundp 'group-here) (group-here)))
  (end-of-buffer!))

(define (chat-list-leave! keep)
  (cond ((and (string? keep) (buffer-known? keep)) (chat-list-keep! keep))
        ((and (string? keep) (file-exists? keep)) (chat-list-revive! keep))
        (else (chat-list-back!))))

;; one filter line over one list: what you type reads the titles, and the
;; same words read the text of every alive chat
(define (chat-list-filter-line! &optional standing)
  (let* ((narrow (lambda (q)
                   (chat-list-search-hits q)
                   (list-set-query! *chat-list-buffer* q)
                   ;; the scope widens the moment you type, so the rows are
                   ;; built again and not only filtered
                   (ibuffer-refresh! *chat-list-buffer*)
                   (ibuffer-goto-first-row! *chat-list-buffer*)
                   (chat-list-preview!)))
         (done (lambda () (set! *mb-list-buffer* #f) (set! *mb-list-prompt* #f))))
    (when (and (string? standing) (not (equal? standing "")))
      (buffer-set-local! *chat-list-buffer* 'chat-list-search standing)
      (narrow standing))
    (set! *mb-list-buffer* *chat-list-buffer*)
    (set! *mb-list-prompt* "Chat: ")
    (minibuffer-read* "Chat: " '()
      (list (list 'change narrow)
            (list 'confirm
                  (lambda (q)
                    (done)
                    (unless (equal? q (list-query *chat-list-buffer*)) (narrow q))
                    (let ((row (list-current *chat-list-buffer*)))
                      (if (ibuffer-heading? row)
                          (begin
                            (ibuffer-toggle-fold! (ibuffer-heading-key row) *chat-list-buffer*)
                            (chat-list-focus!))
                          (chat-list-leave! row)))))
            ;; the filter is one line over the list, not the life of the
            ;; application: closing it hands the list back its focus
            (list 'cancel
                  (lambda ()
                    (done)
                    (chat-list-clear-search!)
                    ;; the rows widen again under the same cursor: closing
                    ;; the filter is not a move
                    (ibuffer-refresh! *chat-list-buffer*)
                    (chat-list-preview!)
                    (chat-list-focus!)))
            (list 'legend *ibuffer-prompt-legend*)
            (list 'style "filter")))))

(define (chat-list-open! &optional standing)
  (let ((preview (chat-list-arrive!)))
    (buffer-set-local! *chat-list-buffer* 'ibuffer-scope 'chat-list)
    (buffer-set-local! *chat-list-buffer* 'ibuffer-prompt-home-window preview)
    (list-clear-query! *chat-list-buffer*)
    (with-current-buffer *chat-list-buffer*
      (lambda () (with-list-mode-skip-render (lambda () (set-mode! "chat-list-mode")))))
    ;; the chat list is a table, not a picker: a group row takes the
    ;; highlight and the verbs read it as every chat under it
    (buffer-set-local! *chat-list-buffer* 'ibuffer-heading-rows #t)
    (ibuffer-refresh! *chat-list-buffer*)
    ;; the list keeps the row it was left on; only a list that holds no
    ;; row yet starts at the top
    (unless (list-current *chat-list-buffer*)
      (ibuffer-goto-first-row! *chat-list-buffer*))
    (chat-list-preview!)
    ;; the list stands on its own keys; a filter line only opens when you
    ;; ask for one, by / or by arriving with words already typed
    (if (and (string? standing) (not (equal? standing "")))
        (chat-list-filter-line! standing)
        (chat-list-focus!))))

(define-command "chat-list-filter"
  "Narrow the chat list by a word in a title or in a chat"
  (lambda () (chat-list-filter-line!)))

(define-command "chat-list-visit"
  "Enter the chat at point in its own group; on a heading, open the section"
  (lambda ()
    (let ((row (list-current *chat-list-buffer*)))
      (if (ibuffer-heading? row)
          (ibuffer-toggle-fold! (ibuffer-heading-key row) *chat-list-buffer*)
          (chat-list-leave! row)))))

(define-command "chat-list-quit"
  "Leave the chat list and change nothing"
  (lambda () (chat-list-leave! #f)))

(define-command "chat-list"
  "Switch to a chat, by its name or by a word somebody said in it"
  (lambda () (chat-list-open!)))

;; the name is gone but the words are not: you remember what the chat said
(define-command "chat-where"
  "Switch to the chat where this was said"
  (lambda ()
    (minibuffer-read "Chat where: " '()
      (lambda (words) (chat-list-open! (string-trim words))))))

(define-command "chat-list-regroup"
  "Cycle what a section of the chat list is: none, group, state, model"
  (lambda ()
    (let ((next (ibuffer-cycle-after (ibuffer-grouping *chat-list-buffer*)
                                     *chat-list-groupings*)))
      (ibuffer-set-grouping! next *chat-list-buffer*)
      (message (string-append "grouped by " (symbol->string next))))))

(define-command "chat-list-resort"
  "Cycle the order inside a section: recent, name, size on disk"
  (lambda ()
    (let ((next (ibuffer-cycle-after (ibuffer-sort *chat-list-buffer*)
                                     '(recent name size))))
      (ibuffer-set-sort! next *chat-list-buffer*)
      (message (string-append "sorted by " (symbol->string next))))))

(category! 'chat)
(catalog-meta! 'command "chat-list" 'domain 'chat 'effects '(write display))
(catalog-meta! 'command "chat-list-filter" 'domain 'chat 'effects '(write display))
(catalog-meta! 'command "chat-list-visit" 'domain 'chat 'effects '(write display))
(catalog-meta! 'command "chat-list-quit" 'domain 'chat 'effects '(write display))
(catalog-meta! 'command "chat-where" 'domain 'chat 'effects '(write display))
(public! 'chat-list-open!
  "(chat-list-open! [SEARCH]) — open the chat list application, with SEARCH standing")
