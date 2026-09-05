;;; whatsapp.scm --- Read and reply to WhatsApp chats through MCP.

(package! "whatsapp")

(domain! 'chat)
(effects! '(write))

(defgroup 'whatsapp "Read and reply to WhatsApp chats through the whatsapp MCP server.")

(defcustom 'whatsapp-cache-ttl 30
  "Seconds before the chat list refreshes from WhatsApp."
  'group 'whatsapp 'type 'number)

(defcustom 'whatsapp-chat-limit 30
  "Maximum recent chats to show."
  'group 'whatsapp 'type 'number)

(defcustom 'whatsapp-message-limit 50
  "Maximum recent messages to show in one conversation."
  'group 'whatsapp 'type 'number)

(define *whatsapp-buffer* "*WhatsApp*")
(defcustom 'whatsapp-group ""
  "Group to open WhatsApp in. Empty uses the current group."
  'group 'whatsapp 'type 'string)
(define *whatsapp-show-buffer* "*WhatsApp conversation*")

(define (whatsapp--join-group! buf)
  (let ((group (frame-group)))
    (when group (buffer-add-group! buf group)))
  buf)
(define *whatsapp-call* mcp-call!)

(domain! 'chat)
(effects! '(pure))

(define (whatsapp--text value fallback)
  (if (and (string? value) (not (equal? value ""))) value fallback))

(define (whatsapp--one-line value)
  (string-join (string-split (whatsapp--text value "") "\n") " "))

(define (whatsapp--parse-chats text)
  (if (not (string? text))
      #f
      (let* ((trimmed (string-trim text))
             (direct (and (not (equal? trimmed "")) (json-parse trimmed))))
        (cond
          ((equal? trimmed "") '())
          ((and (pair? direct) (symbol? (car direct))) (list direct))
          ((or (pair? direct) (null? direct)) direct)
          (else
            (json-parse
              (string-append
                "["
                (string-join (string-split trimmed "}\n{") "},{")
                "]")))))))

(define (whatsapp--from-me? chat)
  (let ((value (plist-get chat 'last_is_from_me)))
    (or (equal? value 1) (equal? value #t))))

(define (whatsapp--cells buf chat)
  (let ((jid (whatsapp--text (plist-get chat 'jid) "unknown")))
    (list
      (whatsapp--text (plist-get chat 'name) jid)
      (whatsapp--text (plist-get chat 'last_message_time) "")
      (string-append
        (if (whatsapp--from-me? chat) "me: " "")
        (whatsapp--one-line (plist-get chat 'last_message))))))

(define (whatsapp--clean-message-body body)
  (cond
    ((string-prefix? "[image - Message ID:" body) "[image]")
    ((string-prefix? "[video - Message ID:" body) "[video]")
    ((string-prefix? "[audio - Message ID:" body) "[audio]")
    ((string-prefix? "[document - Message ID:" body) "[document]")
    (else body)))

;;; The conversation as a tree.
;;;
;;; The transcript the server prints is the source, and it reaches the
;;; buffer as it came. The whatsapp grammar parses it; the rows, the
;;; view, and the motion between messages are three readings of that
;;; one parse. Nothing here scans lines.

(define (whatsapp--node-of kind nodes)
  (let loop ((ns nodes))
    (cond ((null? ns) #f)
          ((equal? (car (car ns)) kind) (car ns))
          (else (loop (cdr ns))))))

(define (whatsapp--slice text node)
  (if node (substring-bytes text (nth 1 node) (nth 2 node)) ""))

(define (whatsapp--msg-start row) (nth 0 row))
(define (whatsapp--msg-end row) (nth 1 row))
(define (whatsapp--msg-time row) (nth 2 row))
(define (whatsapp--msg-sender row) (nth 3 row))
(define (whatsapp--msg-body row) (nth 4 row))
(define (whatsapp--msg-mine? row) (nth 5 row))

;; every message in BUF as (START END TIME SENDER BODY MINE?)
(define (whatsapp--messages buf)
  (let ((text (buffer-text buf)))
    (with-current-buffer buf
      (lambda ()
        (map
          (lambda (node)
            (let* ((parts (ts-children "message" (nth 1 node) (nth 2 node)))
                   (sender
                     (whatsapp--slice text
                       (whatsapp--node-of "sender" parts))))
              (list
                (nth 1 node) (nth 2 node)
                (whatsapp--slice text
                  (whatsapp--node-of "timestamp" parts))
                sender
                (whatsapp--clean-message-body
                  (string-trim
                    (whatsapp--slice text
                      (whatsapp--node-of "body" parts))))
                (equal? sender "Me"))))
          ;; Name the root. One message covers the whole buffer on its
          ;; own, and the smallest node over that range would then be
          ;; the message, not the conversation holding it.
          ;;
          ;; A loading notice or an error is not a transcript, and the
          ;; grammar says so by giving back an error node instead.
          (filter (lambda (node) (equal? (car node) "message"))
                  (ts-children "conversation" 0
                               (string-byte-length text))))))))

;; The message a position stands in. A position past the last one
;; belongs to it: a reader at the end of the buffer is reading the
;; last thing said.
(define (whatsapp--message-at rows pos)
  (let loop ((rs rows) (best #f))
    (cond ((null? rs) best)
          ((> (whatsapp--msg-start (car rs)) pos) best)
          (else (loop (cdr rs) (car rs))))))

(define (whatsapp--current-message buf)
  (and (buffer-mode-is? buf "whatsapp-chat-mode")
       (whatsapp--message-at (whatsapp--messages buf)
                             (buffer-point buf))))





(define (whatsapp--short-time stamp)
  (if (> (string-byte-length stamp) 15)
      (substring-bytes stamp 5 16)
      stamp))

(define (whatsapp--message-block row current?)
  (component 'ui/row
    (list
      'class
        (string-append
          "whatsapp-message"
          (if (whatsapp--msg-mine? row) " whatsapp-message-me" "")
          (if current? " whatsapp-message-current" ""))
      ;; the node's own start names the row, so a click selects the
      ;; message the same motion keys would
      'click
        (string-append "msg:"
                       (number->string (whatsapp--msg-start row)))
      'segs
        (list
          (list "whatsapp-message-time"
                (whatsapp--short-time (whatsapp--msg-time row)))
          (list "whatsapp-message-sender"
                (string-append "  " (whatsapp--msg-sender row)))
          (list "whatsapp-message-body"
                (string-append "\n" (whatsapp--msg-body row)))))))

;; WhatsApp's own reply carries the message it answers. This transport
;; has no field for one, so the quote goes into the text — the reader
;; on the other end still sees what was answered.
(define (whatsapp--quote row)
  (let loop ((words (string-split
                      (whatsapp--one-line (whatsapp--msg-body row)) " "))
             (kept '()) (width 0))
    (if (or (null? words) (> width 120))
        (string-append
          "> " (whatsapp--msg-sender row) ": "
          (string-join (reverse kept) " ")
          (if (null? words) "" " …")
          "\n")
        (loop (cdr words) (cons (car words) kept)
              (+ width 1 (string-byte-length (car words)))))))

(define (whatsapp--conversation-blocks rows current notice)
  (cons
    (component 'ui/actions
      (list 'class "whatsapp-actions"
            'actions
              '(("whatsapp-reply" "Reply" "r")
                ("whatsapp-refresh" "Refresh" "g"))))
    (if (pair? rows)
        (map (lambda (row)
               (whatsapp--message-block row
                 (and current
                      (= (whatsapp--msg-start row)
                         (whatsapp--msg-start current)))))
             rows)
        (list
          (component 'ui/empty
            (list 'class "whatsapp-empty"
                  'text
                    (if (and (string? notice)
                             (not (equal? (string-trim notice) "")))
                        (string-trim notice)
                        "No messages.")))))))



(define (whatsapp--conversation-buffer jid)
  *whatsapp-show-buffer*)



(domain! 'chat)
(effects! '(write))

(define (whatsapp--replace-text! buf text)
  (let ((p (buffer-point buf)))
    (buffer-delete-range! buf 0 (buffer-size buf))
    (buffer-append! buf text)
    (buffer-goto! buf (min p (buffer-size buf)))))

;; The view is a projection of the tree, rebuilt from the buffer text
;; every time. Nothing about a message is kept anywhere else, so the
;; blocks a reader sees and the text the grammar read cannot drift.
(define (whatsapp--paint! buf)
  (when (buffer-known? buf)
    (let* ((rows (whatsapp--messages buf))
           (current (whatsapp--message-at rows (buffer-point buf))))
      (buffer-set-local! buf 'render-mode "blocks")
      (buffer-set-local! buf 'render-blocks
        (whatsapp--conversation-blocks rows current
          (buffer-local buf 'whatsapp-notice)))
      (buffer-set-local! buf 'modeline-info
        (string-append
          "WhatsApp · "
          (whatsapp--text (buffer-local buf 'whatsapp-name) "chat")
          (if current
              (string-append " · " (whatsapp--msg-sender current))
              ""))))))

;; RAW is what the server printed. It goes in as it came: the grammar
;; reads the buffer, so anything this rewrote would be a second
;; opinion about what was said.
(define (whatsapp--render-conversation! buf raw)
  (let ((text (if (string? raw) raw "")))
    (whatsapp--replace-text! buf text)
    (buffer-set-local! buf 'whatsapp-notice text)
    (buffer-set-local! buf 'whatsapp-messages-jid
      (buffer-local buf 'whatsapp-jid))
    (whatsapp--paint! buf)
    (buffer-set-read-only! buf #t)))

;; Motion belongs to the tree: the next message is the next sibling of
;; the node point stands in, and every mode with a grammar moves this
;; way.
(define (whatsapp--select-at! buf pos)
  (buffer-goto! buf pos)
  (whatsapp--paint! buf))

(define (whatsapp--goto-message! buf op)
  (let* ((rows (whatsapp--messages buf))
         (here (whatsapp--message-at rows (buffer-point buf))))
    (if (not here)
        (message "No messages here")
        (let ((target
                (with-current-buffer buf
                  (lambda ()
                    (ts-node "message"
                             (whatsapp--msg-start here)
                             (whatsapp--msg-end here) op)))))
          (if target
              (whatsapp--select-at! buf (nth 1 target))
              (message (if (equal? op 'next)
                           "Last message"
                           "First message")))))))

(domain! 'chat)
(effects! '(read external))

(define (whatsapp--fetch-chats buf k)
  (let* ((text
           (*whatsapp-call* 'whatsapp "list_chats"
             (list 'limit whatsapp-chat-limit
                   'page 0
                   'include_last_message #t
                   'sort_by "last_active")))
         (rows (whatsapp--parse-chats text)))
    (if rows
        (begin
          ;; A cache callback redraws with the cached rows. Seed the
          ;; unfiltered rows first so local filtering cannot retain the
          ;; empty source installed by the mode's initial render.
          (buffer-set-local! buf 'list-source-entries rows)
          (k rows))
        (begin
          (message "WhatsApp did not return a chat list")
          (k #f)))))

(define (whatsapp--refresh-conversation! buf)
  (let ((jid (buffer-local buf 'whatsapp-jid)))
    (when jid
      (whatsapp--render-conversation! buf "Loading messages…\n")
      (*whatsapp-call* 'whatsapp "list_messages"
        (list 'chat_jid jid
              'limit whatsapp-message-limit
              'page 0
              'include_context #f)
        (lambda (ok text)
          ;; One shared scene pane serves every chat. Ignore a response
          ;; whose request no longer owns that pane.
          (when (and (buffer-known? buf)
                     (equal? jid (buffer-local buf 'whatsapp-jid)))
            (whatsapp--render-conversation! buf
              (if ok
                  text
                  (string-append
                    "Could not load messages: "
                    (whatsapp--text text "unknown error")
                    "\n")))))))))

(define (whatsapp--display-conversation! buf)
  ;; Show the conversation without selecting its window; the index keeps
  ;; keyboard focus so moving up/down continues to preview chats.
  (display-buffer-other-window! buf))

(define (whatsapp--open-chat! chat &optional display?)
  (let* ((jid (whatsapp--text (plist-get chat 'jid) ""))
         (name (whatsapp--text (plist-get chat 'name) jid))
         (buf (whatsapp--conversation-buffer jid)))
    (if (equal? jid "")
        (message "This chat has no WhatsApp JID")
        (begin
          (unless (buffer-known? buf) (buffer-create buf))
          ;; Keep the conversation buffer's text attached to the selected
          ;; JID: the transcript in it is the only copy of this chat.
          (unless (equal? jid (buffer-local buf 'whatsapp-messages-jid))
            (buffer-set-local! buf 'whatsapp-messages-jid #f)
            (buffer-set-local! buf 'whatsapp-notice #f)
            (buffer-set-local! buf 'render-blocks #f))
          (buffer-set-local! buf 'whatsapp-jid jid)
          (buffer-set-local! buf 'whatsapp-name name)
          (with-current-buffer buf
            (lambda () (set-mode! "whatsapp-chat-mode")))
          (when display? (whatsapp--display-conversation! buf))))))

(domain! 'chat)
(effects! '(write external))

(define *whatsapp-reply-tool* (string-append "send" "_" "message"))

(define (whatsapp--send! buf text)
  (let* ((chat
           (and (buffer-mode-is? buf "whatsapp-mode")
                (list-current *whatsapp-buffer*)))
         (jid
           (if chat
               (plist-get chat 'jid)
               (buffer-local buf 'whatsapp-jid))))
    (if (not jid)
        (message "No WhatsApp chat is selected")
        (begin
          (message "Sending WhatsApp reply…")
          (*whatsapp-call* 'whatsapp *whatsapp-reply-tool*
            (list 'recipient jid 'message text)
            (lambda (ok result)
              (when (buffer-known? buf)
                (if ok
                    (begin
                      (message "WhatsApp reply sent")
                      (whatsapp--refresh-conversation! buf))
                    (message
                      (string-append
                        "WhatsApp reply failed: "
                        (whatsapp--text result "unknown error")))))))))))

(domain! 'chat)
(effects! '(write external))

(define-style! 'whatsapp
  "
.whatsapp-actions { padding: 2px 8px 8px; }
.whatsapp-message { margin: 0 0 4px; padding: 7px 9px; border-left: 2px solid transparent; }
.whatsapp-message-me { background: var(--hl-line-bg); border-left-color: var(--accent-fg); }
.whatsapp-message-current { outline: 1px solid var(--accent-fg); outline-offset: -1px; }
.whatsapp-message-time { color: var(--dim-fg); font-size: 11px; }
.whatsapp-message-sender { color: var(--dim-fg); font-weight: 600; }
.whatsapp-message-me .whatsapp-message-sender { color: var(--accent-fg); }
.whatsapp-message-body { display: block; margin-top: 3px; color: var(--fg); white-space: pre-wrap; }
.whatsapp-empty { margin: 4px 8px; }
")

(on-block-click! 'whatsapp
  (lambda (buf id)
    (and (equal? (buffer-local buf 'mode-name) "whatsapp-chat-mode")
         (cond
           ((equal? id "whatsapp-reply")
            (with-current-buffer buf
              (lambda () (run-command "whatsapp-reply")))
            #t)
           ((equal? id "whatsapp-refresh")
            (with-current-buffer buf
              (lambda () (run-command "whatsapp-chat-refresh")))
            #t)
           ((string-prefix? "msg:" id)
            (let ((pos (string->number
                         (substring-bytes id 4 (string-byte-length id)))))
              (when (number? pos) (whatsapp--select-at! buf pos)))
            #t)
           (else #f)))))

(define-mode "whatsapp-chat-mode"
  (lambda ()
    (let* ((buf (current-buffer))
           (jid (buffer-local buf 'whatsapp-jid))
           (loaded?
             (and jid
                  (equal? jid (buffer-local buf 'whatsapp-messages-jid)))))
      (whatsapp--join-group! buf)
      ;; before anything reads the buffer: every question below is a
      ;; question for the grammar
      (buffer-set-local! buf 'ts-lang "whatsapp")
      (buffer-set-read-only! buf #t)
      (buffer-set-local! buf 'transient #f)
      (buffer-set-local! buf 'desktop-skip-locals
        '(render-blocks whatsapp-notice whatsapp-messages-jid))
      (buffer-set-local! buf 'render-mode "blocks")
      (cond
        (loaded? (whatsapp--paint! buf))
        (jid (whatsapp--refresh-conversation! buf))
        (else (whatsapp--render-conversation! buf ""))))))

(mode-doc! "whatsapp-chat-mode"
  (string-append
    "One WhatsApp conversation, read as messages rather than as lines. "
    "Up and down move between messages and mark the one you stand on; "
    "n/p and j/k do the same. r replies to that message, quoting it, "
    "and g refreshes."))

(mode-keys! "whatsapp-chat-mode"
  '(("<down>" "whatsapp-next-message")
    ("<up>" "whatsapp-prev-message")
    ("n" "whatsapp-next-message")
    ("p" "whatsapp-prev-message")
    ("j" "whatsapp-next-message")
    ("k" "whatsapp-prev-message")
    ("r" "whatsapp-reply")
    ("g" "whatsapp-chat-refresh")
    ("q" "quit-window")))

(domain! 'chat)
(effects! '(read external))

(define-list-mode! "whatsapp-mode"
  (list
    'doc (string-append
           "Recent WhatsApp chats. RET reads the selected conversation. "
           "Use r to reply, g to refresh, / to filter, and q to quit.")
    'buffer *whatsapp-buffer*
    'transient #f
    'rows (lambda (buf)
            (whatsapp--join-group! buf)
            (list-entries buf))
    'cache-fetch whatsapp--fetch-chats
    'cache-ttl whatsapp-cache-ttl
    'columns (lambda (buf)
               (list (list "chat" 24) (list "last active" 25)
                     (list "message" #f)))
    'cells whatsapp--cells
    'title (lambda (buf) "WhatsApp chats")
    'meta (lambda (buf)
            (string-append
              (number->string (length (list-source-entries buf)))
              " recent chats"))
    'total (lambda (buf) (length (list-source-entries buf)))
    'local-filter #t
    'no-marks #t
    'preview (lambda (buf chat) (whatsapp--open-chat! chat #f))
    'key (lambda (buf chat) (plist-get chat 'jid))
    'footer (lambda (buf)
              '(("RET" "read") ("r" "reply") ("/" "filter")
                ("g" "refresh") ("q" "quit")))
    'keys '(("RET" "whatsapp-open")
            ("r" "whatsapp-reply")
            ("g" "whatsapp-refresh")
            ("q" "quit-window"))))

(mode-doc! "whatsapp-mode"
  "Recent WhatsApp chats. RET reads a conversation. Use g to refresh.")

(domain! 'chat)
(effects! '(read external display))

(define-command "whatsapp-list" "Show the recent WhatsApp chat index"
  (lambda () (list-mode-show! "whatsapp-mode")))

(define-command "whatsapp-show-current" "Prepare the WhatsApp conversation pane"
  (lambda ()
    ;; Opening the scene must not turn the list's incidental first row
    ;; into a conversation choice. Keep the last explicitly opened chat;
    ;; RET in the index is the only operation that replaces this pane.
    (unless (buffer-known? *whatsapp-show-buffer*)
      (buffer-create *whatsapp-show-buffer*))
    (whatsapp--join-group! *whatsapp-show-buffer*)
    (when (and (not (buffer-local *whatsapp-show-buffer* 'whatsapp-jid))
               (= (buffer-size *whatsapp-show-buffer*) 0))
      (buffer-append! *whatsapp-show-buffer* "No conversation selected.\n")
      (buffer-set-read-only! *whatsapp-show-buffer* #t))))

(define-scene! "whatsapp"
  '(h 0.32
      (as index (ensure "*WhatsApp*" "whatsapp-list"))
      (as show (ensure "*WhatsApp conversation*" "whatsapp-show-current"))
      (as chat group-chat)))

(define-command "whatsapp" "Open the WhatsApp workspace"
  (lambda () (scene-open! "whatsapp" whatsapp-group)))

(define-command "whatsapp-open" "Read the WhatsApp chat on this row"
  (lambda ()
    (let ((chat (list-current *whatsapp-buffer*)))
      (if chat
          (whatsapp--open-chat! chat #t)
          (message "No WhatsApp chat is selected")))))

(domain! 'chat)
(effects! '(read external))

(define-command "whatsapp-refresh" "Refresh recent WhatsApp chats"
  (lambda ()
    (message "Refreshing WhatsApp chats…")
    (cache-refresh! *whatsapp-buffer*)))

(define-command "whatsapp-chat-refresh" "Refresh this WhatsApp conversation"
  (lambda () (whatsapp--refresh-conversation! (current-buffer))))

(domain! 'chat)
(effects! '(write external))

(define-command "whatsapp-reply" "Reply to the selected message, or to the chat"
  (lambda ()
    (let* ((buf (current-buffer))
           (row (whatsapp--current-message buf)))
      (read-string
        (if row
            (string-append "Reply to " (whatsapp--msg-sender row) ": ")
            "Reply: ")
        (lambda (text)
          (let ((trimmed (string-trim text)))
            (unless (equal? trimmed "")
              (whatsapp--send! buf
                (if row
                    (string-append (whatsapp--quote row) trimmed)
                    trimmed)))))
        'history 'whatsapp-reply-history))))

(define-command "whatsapp-next-message" "Move to the next message"
  (lambda () (whatsapp--goto-message! (current-buffer) 'next)))

(define-command "whatsapp-prev-message" "Move to the previous message"
  (lambda () (whatsapp--goto-message! (current-buffer) 'prev)))

(mode-icon! "whatsapp-mode" "W")
(mode-icon! "whatsapp-chat-mode" "W")

