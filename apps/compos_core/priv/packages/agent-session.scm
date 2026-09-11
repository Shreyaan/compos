;;; agent-session.scm --- Agent session lifecycle and user input.
;;;
;;; This module owns reconnect, send, queue, input history, interruption, and
;;; thread creation. Transcript rendering and backend events remain in agent.scm.

(domain! 'chat)
(effects! '(write))
(category! 'chat)

(define (agent-model-foreign? buf cname m)
  (let ((declared (append (connector-models cname)
                          (map car (or (buffer-local buf 'agent-models) '())))))
    (and m (pair? declared) (not (member m declared)))))

(define (agent-model-for-connector buf cname)
  (let ((m0 (buffer-local buf 'agent-model)))
    (if (agent-model-foreign? buf cname m0)
        (begin
          (buffer-set-local! buf 'agent-model #f)
          (agent-update-modeline! buf)
          (message (string-append m0 " isn't a " cname
                                  " model — using its default"))
          #f)
        m0)))

(define (agent-revive! slug)
  (unless (member slug (agent-list))
    (llm-session-close! slug))
  (chat-attach! (agent-buf slug)))

(define (agent-reconnect! slug cname model)
  (let ((buf (agent-buf slug)))
    (llm-session-close! slug)
    (buffer-set-local! buf 'agent-connector cname)
    (buffer-set-local! buf 'agent-model (if (equal? model "") #f model))
    (agent-update-modeline! buf)
    (agent-revive! slug)))

(define-command "agent-switch" "Reattach this thread to a new connector and model"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (not (agent-slug-of buf))
          (message "not an agent buffer")
          (minibuffer-read "Connector: " (connector-names)
            (lambda (cname)
              (minibuffer-read "Model (empty = connector default): "
                (connector-models cname)
                (lambda (model)
                  ;; one switch function for every path (editor.scm)
                  (chat-switch! buf cname model)
                  (when (boundp (quote workspace-llm-defaults-note!))
                    (workspace-llm-defaults-note! buf))))))))))

(define (agent-conversation-text buf)
  (let ((bs (or (buffer-local buf 'agent-blocks) '()))
        (text (buffer-text buf))
        (mark (or (buffer-local buf 'agent-saved-mark) (buffer-size buf))))
    (if (null? bs)
        (substring-bytes text 0 mark)
        (let loop ((bs (reverse bs)) (acc ""))
          (if (null? bs)
              acc
              (let ((b (car bs)))
                (loop (cdr bs)
                      (if (member (caddr b) (list "meta" "status" "waiting" "permission" "question" "queued"))
                          acc
                          (string-append acc
                            (substring-bytes text (car b)
                                             (min (cadr b) mark)))))))))))

(define (agent-seed-transcript buf)
  (or (and (boundp 'chat-model-flatten) (chat-model-flatten buf))
      (agent-conversation-text buf)))

(define (chat-image-paste! kind data mime)
  ;; The hook only runs in chat-mode, so the mode needs no second test here.
  (if (and (equal? kind "image") (string-prefix? "image/" mime))
      (begin
        (buffer-set-local! (current-buffer) 'chat-pending-images
          (append (or (buffer-local (current-buffer) 'chat-pending-images) '())
                  (list (list mime data))))
        (message "image attached, send it with RET")
        #t)
      #f))

(add-paste-hook! "chat-mode" 'chat-image chat-image-paste!)

(define (agent-send-msg! slug raw)
  (let* ((buf (agent-buf slug))
         ;; a one-shot note - a skill body a mode pushed - rides the next
         ;; message exactly once, then clears
         (once (or (buffer-local buf 'chat-note-once) ""))
         ;; images the user pasted since the last send ride once, then clear
         (images (or (buffer-local buf 'chat-pending-images) '()))
         (image-wire (apply string-append
                       (map (lambda (im)
                              (string-append "\n[compos-image " (car im) " " (cadr im) "]"))
                            images)))
         ;; What the user sees rides as a small navigation hint. Document text
         ;; never rides in the message. The agent reads current context itself.
         (msg (string-append
                (if (equal? once "") "" (string-append once "\n\n"))
                (editor-context-preamble buf) raw image-wire)))
    (buffer-set-local! buf 'chat-note-once #f)
    (buffer-set-local! buf 'chat-pending-images '())
    (if (buffer-local buf 'agent-seed-context)
        (begin
          (buffer-set-local! buf 'agent-seed-context #f)
          ;; Say it. This is not a resumed session — the adapter has no
          ;; memory of any of this, and the conversation above is being
          ;; pasted into its first message. A reader who thinks the agent
          ;; remembers will misread everything that follows.
          (let ((start (agent-render! slug
                         "\n[fresh session — the conversation above was replayed into it]\n"
                         "agent-meta")))
            (agent-block-push! buf start (agent-mark slug) "meta" '()))
          (llm-session-send! slug
            (string-append
              "Context: this continues an earlier conversation from the"
              " user's editor (possibly with a different model). The"
              " conversation so far:\n\n" (agent-seed-transcript buf)
              "\n\nContinue naturally from there. New message:\n" msg)
            raw))
        (llm-session-send! slug msg raw))))

(define (agent-continue! thread text)
  (let ((buf (if (buffer-exists? thread) thread (agent-buf thread))))
    (if (not (and buf (buffer-exists? buf)))
        (error "agent-continue!: unknown chat" thread)
        (let ((slug (or (agent-slug-of buf) (chat-ensure-runtime! buf))))
          (when (equal? (agent-status slug) 'dead)
            (agent-revive! slug))
          (agent-send-msg! slug text)))))

(category! 'chat)

(public! 'agent-continue!
  "(agent-continue! THREAD TEXT) — send to a durable chat buffer or live slug, reviving and replaying it after restart")

(define-command "agent-send" "Send the input to the agent, reviving it if dead"
  (lambda ()
    (let* ((buf (current-buffer))
           ;; say something the moment RET lands: the first send spawns a
           ;; backend and mounts MCP servers, seconds with nothing moving
           (feedback (when (equal? (buffer-local buf 'mode-name) "chat-mode")
                       (chat-activity! buf
                         (if (agent-slug-of buf) "sending…" "starting agent…"))))
           ;; a chat without a runtime gets one on first send, on its own
           ;; connector; RET is agent-send on EVERY chat
           (slug (or (agent-slug-of buf)
                     (and (equal? (buffer-local buf 'mode-name) "chat-mode")
                          (buffer-local buf 'agent-saved-mark)
                          (chat-ensure-runtime! buf)))))
      (cond ((not slug) (message "not an agent buffer"))
            (else
             ;; a preset changed under a live ACP session: its tool list is
             ;; fixed at session/new, so reattach before sending
             (when (boundp (quote chat-apply-pending-presets!))
               (chat-apply-pending-presets! buf))
             (when (equal? (agent-status slug) 'dead)
               (agent-revive! slug))
             (let ((input (string-trim (chat-input-text buf))))
               (if (equal? input "")
                   ;; A blank RET commits the oldest queued message as
                   ;; steering. Non-empty RET only adds to the queue.
                   (let ((info (agent-info slug)))
                     (if (and (plist-get info 'steering)
                              (> (plist-get info 'queued) 0)
                              (member (plist-get info 'status)
                                      (list 'running 'needs_attention)))
                         (if (agent-steer! slug)
                             (message "steering the oldest queued message")
                             (message "the queued message could not steer this turn"))
                         (insert! "\n")))
                   (begin
                     ;; the message itself lands in the record when its
                     ;; turn starts; only the walk position resets here
                     (chat-history-reset! buf)
                     (let ((result (agent-send-msg! slug input)))
                       (if (equal? result 'queued)
                           ;; mid-turn: the message moves up into the
                           ;; transcript at once, muted, and the input clears
                           ;; for the next one. Blank RET can explicitly steer
                           ;; the oldest row; otherwise it runs after this turn.
                           (begin
                             (agent-echo-queued! slug input)
                             (chat-clear-input! buf)
                             (end-of-buffer!)
                             (message
                               (if (plist-get (agent-info slug) 'steering)
                                   "queued — press RET again to steer"
                                   "queued — runs when this turn ends")))
                           (begin
                             (chat-clear-input! buf)
                             (end-of-buffer!)
                             (message (if (equal? result 'answered)
                                          "answered"
                                          "sent")))))))))))))

(define *chat-history-limit* 200)

(define (chat-history buf)
  (chat-take
    (let loop ((ts (if (boundp (quote chat-turns)) (chat-turns buf) '())) (acc '()))
      (cond ((null? ts) (reverse acc))
            ((equal? (car (car ts)) "user")
             (loop (cdr ts) (cons (car (cdr (car ts))) acc)))
            (else (loop (cdr ts) acc))))
    *chat-history-limit*))

(define (chat-history-reset! buf)
  (buffer-set-local! buf 'chat-history-pos #f)
  (buffer-set-local! buf 'chat-history-draft #f))

(define (chat-in-input? buf)
  (>= (point) (or (buffer-local buf 'agent-saved-mark) 0)))

(define (chat-on-first-input-line? buf)
  (let ((start (car (chat-input-region buf))))
    (or (<= (point) start)
        (not (string-contains?
               (substring-bytes (buffer-text buf) start (point))
               "\n")))))

(define (chat-on-last-input-line? buf)
  (not (string-contains?
         (substring-bytes (buffer-text buf) (point) (buffer-size buf))
         "\n")))

(define (chat-history-recall! buf dir)
  (let* ((h (chat-history buf))
         (pos (or (buffer-local buf 'chat-history-pos) -1))
         (next (if (< dir 0) (+ pos 1) (- pos 1))))
    (cond ((>= next (length h)) (message "no earlier message"))
          ((< next -1) #f)
          (else
            ;; hold the draft the first time you step off it
            (when (= pos -1)
              (buffer-set-local! buf 'chat-history-draft (chat-input-text buf)))
            (buffer-set-local! buf 'chat-history-pos (if (= next -1) #f next))
            (chat-replace-input! buf
              (if (= next -1)
                  (or (buffer-local buf 'chat-history-draft) "")
                  (nth next h)))))))

(define (chat-history-move! dir)
  (let* ((buf (current-buffer))
         (motion (if (< dir 0) "previous-line" "next-line")))
    (if (or (not (buffer-local buf 'agent-saved-mark))
            (not (chat-in-input? buf))
            (null? (chat-history buf))
            ;; inside a multi-line input, up and down are still motion
            (if (< dir 0)
                (not (chat-on-first-input-line? buf))
                (not (chat-on-last-input-line? buf))))
        (run-command motion)
        (chat-history-recall! buf dir))))

(define-command "chat-history-previous" "Recall the previous message you sent"
  (lambda () (chat-history-move! -1)))

(define-command "chat-history-next" "Recall the next message you sent"
  (lambda () (chat-history-move! 1)))

(define-command "agent-interrupt-send" "Revive, cancel, or hard-reset the agent"
  (lambda ()
    (let ((slug (agent-slug-of (current-buffer)))
          (buf (current-buffer)))
      (when slug
        (cond ((equal? (agent-status slug) 'dead)
               (agent-revive! slug))
              ((buffer-local buf 'agent-cancelling)
               (buffer-set-local! buf 'agent-cancelling #f)
               (agent-reconnect! slug
                 (or (buffer-local buf 'agent-connector) *default-connector*)
                 (or (buffer-local buf 'agent-model) ""))
               (message "agent restarted (hard reset)"))
              (else
               (buffer-set-local! buf 'agent-cancelling #t)
               (agent-finalize-running-tools! buf "cancelled")
               (agent-discard-queued! buf)
               (llm-session-cancel! slug)
               (message "cancel requested — C-RET again forces a restart")))))))

(define-command "chat-abort" "Stop the reply in flight in this chat"
  (lambda ()
    (let* ((buf (current-buffer))
           (slug (agent-slug-of buf)))
      (if (and slug (member (agent-status slug) '(running starting needs_attention)))
          (begin
            (agent-finalize-running-tools! buf "cancelled")
            (agent-discard-queued! buf)
            (llm-session-cancel! slug)
            ;; both waiting markers: a thread renders its own ('agent-waiting),
            ;; a chat that never attached a runtime renders 'chat-waiting
            (agent-clear-waiting! slug)
            (chat-clear-waiting! buf)
            ;; C-g is a quit either way: the buffer returns to the
            ;; movement state, and the Cmd-arrows move the focus again
            (editing-quit!)
            (message "aborted"))
          (run-command "keyboard-quit")))))

(define (chat-dismiss--hide! buf)
  (let* ((win (window-showing buf))
         (fallback (car (filter (lambda (b)
                                  (and (not (equal? b buf))
                                       (buffer-exists? b)))
                                (window-fill-buffers)))))
    (if (and win fallback)
        (begin
          (switch-to-buffer-here! fallback)
          (buffer-sleep! buf)
          #t)
        (not win))))

(define (chat-dismiss--close! buf slug ok?)
  (if ok?
      (begin
        (when (and slug (not (equal? (agent-status slug) 'dead)))
          (llm-session-close! slug))
        (message "chat dismissed"))
      (message "chat run ended unsuccessfully; chat remains dismissed")))

(on-agent-turn-end! 'chat-dismiss
  (lambda (slug stop-reason ok?)
    (let ((buf (agent-buf slug)))
      (when (buffer-local buf 'chat-dismiss-pending)
        (buffer-set-local! buf 'chat-dismiss-pending #f)
        (chat-dismiss--close! buf slug ok?)))))

(define-command "chat-dismiss"
  "Hide this chat, optionally send a final instruction, and dismiss after the current run"
  (lambda ()
    (let* ((buf (current-buffer))
           (slug (agent-slug-of buf))
           (input (string-trim (chat-input-text buf)))
           (running (and slug (member (agent-status slug) '(running starting)))))
      (if (not (chat-dismiss--hide! buf))
          (message "could not hide chat: no other buffer is available")
          (begin
            (when (and slug (not (equal? input "")))
              (chat-clear-input! buf)
              (agent-send-msg! slug input))
            (if running
                (buffer-set-local! buf 'chat-dismiss-pending #t)
                (chat-dismiss--close! buf slug #t))
            (message (if running
                         "chat hidden; dismissing after the current run"
                         "chat dismissed")))))))



(define-command "chat-dismiss"
  "Hide this chat, send its input as a final instruction, and close it when answered"
  (lambda ()
    (let* ((buf (current-buffer))
           (slug (agent-slug-of buf))
           (input (string-trim (chat-input-text buf))))
      (cond
        ((not slug) (message "not an agent chat"))
        ((equal? input "") (message "final instruction is empty"))
        ((not (chat-dismiss--hide! buf))
         (message "could not hide chat: no other buffer is available"))
        (else
         (chat-clear-input! buf)
         (agent-send-msg! slug input)
         (debounce! (string-append "chat-dismiss:" slug) 250
           'chat-dismiss--finish! (list buf slug))
         (message "chat hidden; running final instruction"))))))

(define-command "chat-unqueue" "Remove the newest queued message and return it to the input"
  (lambda ()
    (let* ((buf (current-buffer))
           (slug (agent-slug-of buf))
           (texts (or (buffer-local buf 'chat-queued) '())))
      (if (null? texts)
          (message "no queued messages")
          (let* ((rev (reverse texts))
                 (text (car rev))
                 (kept (reverse (cdr rev)))
                 (removed (if (and slug (not (equal? (agent-status slug) 'dead)))
                              (agent-dequeue! slug text)
                              #t)))
            (if (not removed)
                (message "already committed as steering")
                (begin
                  (buffer-set-local! buf 'chat-queued (if (null? kept) #f kept))
                  (let ((draft (chat-input-text buf)))
                    (chat-replace-input! buf
                      (if (equal? (string-trim draft) "")
                          text
                          (string-append text "\n" draft))))
                  (message "unqueued — the message is back in the input"))))))))

(define (agent-claimed-slugs)
  (filter (lambda (s) s)
          (map (lambda (b) (buffer-local b 'agent-slug)) (buffer-list))))

(define (agent-chat-buffer slug) (string-append "*chat:" slug "*"))

(define (agent-next-slug)
  ;; The collision check must name the buffer execute* actually creates.
  ;; It used agent-buffer, which still answers "*agent: a1*" from the old
  ;; naming, so a live "*chat:a1*" looked free: buffer-create reused it,
  ;; re-stamped a chat header over the transcript, chat-attach-agent! handed
  ;; back the FIRST chat's slug, and the new prompt was sent into a dead
  ;; session and lost. Two spawns collapsed into one chat.
  (let ((claimed (agent-claimed-slugs)))
    (let loop ((n 1))
      (let ((slug (string-append "a" (number->string n))))
        (if (or (member slug (agent-list))
                (buffer-exists? (agent-chat-buffer slug))
                (buffer-exists? (agent-buffer slug))
                (member slug claimed))
            (loop (+ n 1))
            slug)))))

(define (chat-marker-guard? buf p)
  (and (buffer-local buf 'agent-saved-mark)
       (<= p (chat-input-start buf))))

(effects! '(write))

(define-command "chat-delete-backward" "Delete backward, but never into the transcript"
  (lambda ()
    (if (chat-marker-guard? (current-buffer) (point))
        (message "beginning of input")
        (unless (delete-active-region!) (delete-char! -1)))))

(define-command "chat-delete-forward" "Delete forward, but never the input marker"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (and (buffer-local buf 'agent-saved-mark)
               (>= (point) (chat-mark buf))
               (< (point) (chat-input-start buf)))
          (message "this is the input marker")
          (unless (delete-active-region!) (delete-char! 1))))))

;; the chat keeps point in its input around every command
(define (chat-input-post-command!)
  (chat-snap-to-input!))

(add-hook! 'pre-command-hook 'chat-snap-to-input!)
(add-hook! 'post-command-hook 'chat-input-post-command!)

(define (agent-install-keys! buf)
  ;; the mark is a marker: the buffer keeps the position current through
  ;; every edit. Declared here because every chat passes through this fn,
  ;; on setup, attach, and restore alike.
  ;; 'stay: the input starts AT the mark, so a keystroke there must land
  ;; after it, in the input. The agent's own appends go through
  ;; buffer-insert-at-local!, which advances a stay marker itself.
  (buffer-marker-local! buf 'agent-saved-mark 'stay)
  
  
  
  )

(mode-keys! "chat-mode"
  '(
    ("DEL" "chat-delete-backward")
    ("C-d" "chat-delete-forward")
    ("RET" "agent-send")
    ("C-RET" "agent-interrupt-send")
    ("C-g" "chat-abort")
    ("TAB" "agent-toggle-fold")
    ("<up>" "chat-history-previous")
    ("<down>" "chat-history-next")
    ("C-c C-y" "agent-permission-allow")
    ("C-c C-a" "agent-permission-always")
    ("C-c C-n" "agent-permission-deny")
    ("C-c p" "chat-set-permission-mode")
    ("C-c t" "chat-refresh-tools")
    ("C-c C-d" "chat-unqueue")
    ("C-c C-v" "chat-toggle-view")))

;;; --- the spawn edge -----------------------------------------------------------
;;;
;;; A spawned chat and the chat that spawned it name each other. The edge
;;; lives where group parentage already lives: the group record, in the
;;; record's extension slot. It is durable for the same reason a group's
;;; parent is: the record outlives every buffer in it. A killed child
;;; stays findable, and a killed parent still answers for its children.
;;; The buffer-locals are a cache over this store, never a second copy of
;;; the truth.
;;;
;;; One slot per parent: (PARENT-SLUG STATE CHILD-SLUG ...), children
;;; newest last. STATE is live until the parent chat is killed and gone
;;; after. A child is never killed with its parent.

(domain! 'chat)
(effects! '(pure))

(define *subagent-setting* 'subagents)

(define (subagent-slot-parent slot) (nth 0 slot))
(define (subagent-slot-state slot) (nth 1 slot))
(define (subagent-slot-children slot) (cdr (cdr slot)))

(effects! '(read))

;; a chat names itself by buffer or by slug, the way agent-continue! reads
;; a thread. A killed chat has only its slug left, and the slug is what
;; the store is keyed by.
(define (subagent-slug chat)
  (and (string? chat)
       (or (and (buffer-exists? chat) (agent-slug-of chat)) chat)))

;; the chat that owns this eval. An agent calling over the eval door runs
;; inside with-edit-author agent:SLUG, the same signal jj.scm reads to
;; name a change's author.
(define (subagent-spawner)
  (let ((author (current-edit-author)))
    (and (agent-edit-author? author)
         (let ((slug (substring author 6 (string-length author))))
           (and (not (equal? slug "")) slug)))))

(define (subagent-slots g)
  (let ((held (group-setting g *subagent-setting*)))
    (if (pair? held) held '())))

;; Which group record holds a slot is an accident of where the spawn
;; happened, and a chat can move group afterwards, so a reader scans the
;; records rather than guessing one. -> (GROUP SLOT)
(define (subagent-find-slot pick)
  (let loop ((ids (group-ids)))
    (if (null? ids)
        #f
        (let scan ((slots (subagent-slots (car ids))))
          (cond ((null? slots) (loop (cdr ids)))
                ((pick (car slots)) (list (car ids) (car slots)))
                (else (scan (cdr slots))))))))

(define (subagent-slot-of slug)
  (and slug
       (subagent-find-slot
         (lambda (slot) (equal? (subagent-slot-parent slot) slug)))))

(define (subagent-parent-slot-of slug)
  (and slug
       (subagent-find-slot
         (lambda (slot) (member slug (subagent-slot-children slot))))))

(define (subagent-parent chat)
  (let ((found (subagent-parent-slot-of (subagent-slug chat))))
    (and found (subagent-slot-parent (nth 1 found)))))

(define (subagent-children chat)
  (let ((found (subagent-slot-of (subagent-slug chat))))
    (if found (subagent-slot-children (nth 1 found)) '())))

;; #t when CHAT spawned children and CHAT itself is gone
(define (subagent-gone? chat)
  (let ((found (subagent-slot-of (subagent-slug chat))))
    (and found (equal? (subagent-slot-state (nth 1 found)) "gone"))))

(effects! '(write))

;; the buffer-locals are a cache: written from the store, read by nobody
;; above, and rebuildable at any time.
(define (subagent-cache-rebuild! chat)
  (let* ((slug (subagent-slug chat))
         (here (and (string? chat) (buffer-exists? chat) chat))
         (buf (or here
                  (and slug (let ((b (agent-buf slug)))
                              (and b (buffer-exists? b) b))))))
    (when buf
      (buffer-set-local! buf 'subagent-parent (subagent-parent slug))
      (buffer-set-local! buf 'subagent-children (subagent-children slug)))
    slug))

(define (subagent-slot-put! g slot)
  (let ((rest (filter
                (lambda (s) (not (equal? (subagent-slot-parent s)
                                         (subagent-slot-parent slot))))
                (subagent-slots g))))
    (group-setting-set! g *subagent-setting* (append rest (list slot)))))

;; record PARENT -> CHILD. -> the group holding the edge, or #f when the
;; parent chat is not here to give the edge a durable home.
(define (subagent-record! parent child)
  (let* ((pslug (subagent-slug parent))
         (cslug (subagent-slug child))
         (named (and pslug (agent-buf pslug)))
         (buf (and named (buffer-exists? named) named)))
    (and pslug cslug (not (equal? pslug cslug)) buf
         (let* ((found (subagent-slot-of pslug))
                (home (if found (car found) (group-ensure! buf)))
                (slot (if found (nth 1 found) (list pslug "live")))
                (kids (subagent-slot-children slot)))
           (and home
                (begin
                  (unless (member cslug kids)
                    (subagent-slot-put! home
                      (append (list pslug (subagent-slot-state slot))
                              kids (list cslug))))
                  (subagent-cache-rebuild! pslug)
                  (subagent-cache-rebuild! cslug)
                  home))))))

;; The kill seam (groups.scm group-buffer-kill-repair) calls this for
;; every buffer, while the buffer can still answer for itself. Only a
;; chat with a slot has anything to say: the slot stays, the children keep
;; running, and the state records that the parent is gone.
(define (subagent-chat-killed! name)
  (let* ((slug (and (string? name) (buffer-exists? name) (agent-slug-of name)))
         (found (and slug (subagent-slot-of slug))))
    (when found
      (let ((slot (nth 1 found)))
        (subagent-slot-put! (car found)
          (append (list slug "gone") (subagent-slot-children slot)))))))

(category! 'chat)

(public! 'subagent-parent
  "(subagent-parent CHAT) -> the durable slug of the chat that spawned CHAT, or #f; CHAT is a buffer name or a slug")
(public! 'subagent-children
  "(subagent-children CHAT) -> the slugs of the chats CHAT spawned, newest last")
(public! 'subagent-gone?
  "(subagent-gone? CHAT) -> #t when CHAT spawned children and CHAT itself has been killed")
(public! 'subagent-record!
  "(subagent-record! PARENT CHILD) - record the spawn edge in PARENT's group record; returns the group")
(public! 'subagent-cache-rebuild!
  "(subagent-cache-rebuild! CHAT) - put CHAT's subagent-parent and subagent-children locals back from the store")
(catalog-meta! 'function "subagent-parent" 'domain 'chat 'effects '(read))
(catalog-meta! 'function "subagent-children" 'domain 'chat 'effects '(read))
(catalog-meta! 'function "subagent-gone?" 'domain 'chat 'effects '(read))
(catalog-meta! 'function "subagent-record!" 'domain 'chat 'effects '(write))
(catalog-meta! 'function "subagent-cache-rebuild!" 'domain 'chat 'effects '(write))

;;; --- the result ---------------------------------------------------------------
;;;
;;; A child reports STRUCTURALLY. (subagent-result CHAT) reads the child's
;;; own transcript and costs the parent nothing at all: no turn, no tokens,
;;; no context. A fan-out of ten children therefore costs ten turns, not
;;; twenty, and the parent reads the answers when it wants them.
;;;
;;; A free-text wake is the exception, not the rule. 'notify #t on the spawn
;;; asks for one: when a turn of that child ends, the parent is sent a
;;; message with agent-continue!, which does cost the parent a turn.
;;;
;;; The turn-end hook (agent.scm) is what makes any of this work. It fires
;;; on the :ui lane after the child's transcript has landed, so the last
;;; assistant message a listener reads is the finished one.

(domain! 'chat)
(effects! '(read))

;; how much of a child's own words ride in a free-text wake. Past this the
;; parent is pointed at subagent-result instead of being flooded.
(define *subagent-wake-limit* 4000)

(define (subagent-live-buffer chat)
  (let* ((slug (subagent-slug chat))
         (buf (and slug (agent-buf slug))))
    (and buf (buffer-exists? buf) buf)))

;; a turn is in flight. A chat with no runtime at all is not running.
(define (subagent-running? chat)
  (let ((slug (subagent-slug chat)))
    (if (and slug
             (member slug (agent-list))
             (member (agent-status slug) '(running starting needs_attention)))
        #t
        #f)))

;; the child's last assistant message, from the conversation of record --
;; not from the rendered transcript, which carries tool cards and meta
;; lines the parent has no use for.
(define (subagent-last-assistant chat)
  (let ((buf (subagent-live-buffer chat)))
    (and buf
         (let loop ((ts (reverse (chat-turns buf))))
           (cond ((null? ts) #f)
                 ((equal? (car (car ts)) "assistant") (nth 1 (car ts)))
                 (else (loop (cdr ts))))))))

;; THE reply shape. A plist, because one caller reads one field and a list
;; view reads another:
;;   'slug        the child's durable id
;;   'buffer      its chat buffer, or #f when the chat is gone
;;   'status      running | done | failed | idle | gone
;;   'stop-reason the backend's own word for how the last turn ended
;;   'text        the child's last assistant message, empty when it said nothing
(define (subagent-result chat)
  (let* ((slug (subagent-slug chat))
         (buf (subagent-live-buffer chat))
         (ended (and buf (buffer-local buf 'subagent-turn-end))))
    (list 'slug slug
          'buffer buf
          'status (cond ((not buf) 'gone)
                        ((subagent-running? slug) 'running)
                        ((not ended) 'idle)
                        ((nth 1 ended) 'done)
                        (else 'failed))
          'stop-reason (and ended (nth 0 ended))
          'text (or (subagent-last-assistant chat) ""))))

;; CHATS is one chat or a list of them; the answers come back in that order.
(define (subagent-collect chats)
  (map subagent-result (if (pair? chats) chats (list chats))))

;; #t when CHAT will not reach another turn end on its own: it finished one,
;; or it is gone. A chat that never ran a turn is NOT done -- nothing has
;; happened to it yet.
(define (subagent-done? chat)
  (let ((buf (subagent-live-buffer chat)))
    (cond ((not buf) #t)
          ((subagent-running? chat) #f)
          ((buffer-local buf 'subagent-turn-end) #t)
          (else #f))))


(category! 'chat)

(public! 'execute "(execute \"task\") — spawn a task chat on an ACP backend; returns its slug")

(public! 'execute* "(execute* \"task\" '(connector \"codex\" model \"...\" directory \"/repo/\")) — spawn with config")

(define (execute prompt) (execute* prompt '()))

(define (execute* prompt opts)
  ;; agent-next-slug only names the buffer now; the session slug is the
  ;; chat's durable id, assigned by chat-attach-agent!
  (let* ((name (agent-next-slug))
         (buf (agent-chat-buffer name)))
    (buffer-create buf)
    ;; Callers over RPC have no meaningful selected file buffer to inherit
    ;; from. An explicit directory is ordinary chat identity policy and wins
    ;; over buffer-create's interactive inheritance.
    (let ((dir (plist-get opts 'directory)))
      (when dir
        (buffer-set-local! buf 'default-directory dir)
        ;; the explicit marker: group companions must not override a
        ;; directory the spawner chose
        (buffer-set-local! buf 'chat-directory dir)))
    ;; a spawned chat may declare its permission posture up front — the
    ;; first turn can start before anyone could press C-c p
    (let ((pm (plist-get opts 'permission-mode)))
      (when pm (buffer-set-local! buf 'chat-permission-mode pm)))
    ;; ...and its presets, which must land in the buffer-local, not only in
    ;; this one call's config. 'chat-presets is the single source of truth
    ;; for a chat's optional tools (the compos bridge is intrinsic):
    ;; agent-revive! and desktop restore both read it. A spawn that skips it
    ;; starts with the right extra servers and loses them at first revive.
    (let ((ps (plist-get opts 'presets)))
      (when ps (buffer-set-local! buf 'chat-presets ps)))
    (chat-task-init! buf name)
    (let ((slug (chat-attach-agent! buf
                  (or (plist-get opts 'connector) *default-connector*)
                  (plist-get opts 'model)
                  opts)))
      ;; a spawn is quiet: the child gets its mode on its own buffer, and no
      ;; window, point or focus of the spawner's moves. Interactive callers
      ;; display it themselves.
      (with-current-buffer buf
        (lambda ()
          (set-mode! "chat-mode")
          (end-of-buffer!)))
      ;; the spawner in scope, if there is one: the chat that owns this
      ;; eval. With no parent in scope nothing is recorded and the spawn
      ;; is what it always was.
      (let ((parent (subagent-spawner)))
        (when parent (subagent-record! parent slug)))
      (unless (equal? prompt "")
        (llm-session-send! slug prompt))
      slug)))

(define-command "agent-open" "Prompt for a task and spawn a new agent thread"
  (lambda ()
    (minibuffer-read "Task (empty for blank thread): " '()
      (lambda (task)
        ;; execute is quiet, so the interactive caller is the one that shows
        ;; the new thread — in the other window, never stealing focus
        (let ((slug (execute task)))
          (display-buffer-other-window! (agent-buf slug))
          slug)))))
