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

(define (whatsapp--message-header line)
  (let ((chat-parts
          (and (string-prefix? "[" line)
               (string-split line "] Chat: "))))
    (if (and (pair? chat-parts) (pair? (cdr chat-parts)))
        (let* ((stamp (car chat-parts))
               (after-chat (string-join (cdr chat-parts) "] Chat: "))
               (from-parts (string-split after-chat " From: ")))
          (if (and (pair? from-parts) (pair? (cdr from-parts)))
              (let* ((sender-body
                       (string-join (cdr from-parts) " From: "))
                     (body-parts (string-split sender-body ": ")))
                (if (and (pair? body-parts) (pair? (cdr body-parts)))
                    (let ((sender (car body-parts)))
                      (list
                        (substring-bytes stamp 1 (string-byte-length stamp))
                        sender
                        (string-join (cdr body-parts) ": ")
                        (equal? sender "Me")))
                    #f))
              #f))
        #f)))

(define (whatsapp--finish-message row)
  (list (nth 0 row) (nth 1 row) (nth 2 row)
        (whatsapp--clean-message-body (string-trim (nth 3 row)))
        (nth 4 row)))

(define (whatsapp--parse-messages text)
  (if (not (string? text))
      #f
      (if (equal? (string-trim text) "")
          '()
          (let loop ((lines (string-split text "\n"))
                     (current #f) (rows '()) (next-id 0))
            (if (null? lines)
                (let ((done
                        (reverse
                          (if current
                              (cons (whatsapp--finish-message current) rows)
                              rows))))
                  (if (pair? done) done #f))
                (let ((header (whatsapp--message-header (car lines))))
                  (if header
                      (loop
                        (cdr lines)
                        (list (number->string next-id)
                              (nth 0 header) (nth 1 header)
                              (nth 2 header) (nth 3 header))
                        (if current
                            (cons (whatsapp--finish-message current) rows)
                            rows)
                        (+ next-id 1))
                      (if current
                          (loop
                            (cdr lines)
                            (list (nth 0 current) (nth 1 current)
                                  (nth 2 current)
                                  (string-append
                                    (nth 3 current) "\n" (car lines))
                                  (nth 4 current))
                            rows next-id)
                          (loop (cdr lines) #f rows next-id)))))))))

(define (whatsapp--short-time stamp)
  (if (> (string-byte-length stamp) 15)
      (substring-bytes stamp 5 16)
      stamp))

(define (whatsapp--message-block row)
  (component 'ui/row
    (list
      'class
        (if (nth 4 row)
            "whatsapp-message whatsapp-message-me"
            "whatsapp-message")
      'segs
        (list
          (list "whatsapp-message-time"
                (whatsapp--short-time (nth 1 row)))
          (list "whatsapp-message-sender"
                (string-append "  " (nth 2 row)))
          (list "whatsapp-message-body"
                (string-append "\n" (nth 3 row)))))))

(define (whatsapp--conversation-blocks rows notice)
  (cons
    (component 'ui/actions
      (list 'class "whatsapp-actions"
            'actions
              '(("whatsapp-reply" "Reply" "r")
                ("whatsapp-refresh" "Refresh" "g"))))
    (if (pair? rows)
        (map whatsapp--message-block rows)
        (list
          (component 'ui/empty
            (list 'class "whatsapp-empty"
                  'text
                    (if (and (string? notice)
                             (not (equal? (string-trim notice) "")))
                        (string-trim notice)
                        "No messages.")))))))

(define (whatsapp--render-message-rows! buf rows notice)
  (when (buffer-known? buf)
    (let ((name
            (whatsapp--text
              (buffer-local buf 'whatsapp-name) "WhatsApp")))
      (whatsapp--replace-text! buf
        (whatsapp--conversation-text rows notice))
      (buffer-set-local! buf 'whatsapp-messages rows)
      (buffer-set-local! buf 'whatsapp-messages-jid
        (buffer-local buf 'whatsapp-jid))
      (buffer-set-local! buf 'render-mode "blocks")
      (buffer-set-local! buf 'render-blocks
        (whatsapp--conversation-blocks rows notice))
      (buffer-set-local! buf 'modeline-info
        (string-append "WhatsApp · " name))
      (buffer-set-read-only! buf #t))))

(define (whatsapp--conversation-buffer jid)
  *whatsapp-show-buffer*)

(define (whatsapp--conversation-text rows &optional notice)
  (cond
    ((pair? rows)
     (string-append
       (string-join
         (map (lambda (row)
                (string-append
                  (whatsapp--short-time (nth 1 row))
                  "  " (nth 2 row) "\n" (nth 3 row)))
              rows)
         "\n\n")
       "\n"))
    ((and (string? notice) (not (equal? (string-trim notice) "")))
     (string-append (string-trim notice) "\n"))
    (else "No messages.\n")))

(domain! 'chat)
(effects! '(write))

(define (whatsapp--replace-text! buf text)
  (let ((p (buffer-point buf)))
    (buffer-delete-range! buf 0 (buffer-size buf))
    (buffer-append! buf text)
    (buffer-goto! buf (min p (buffer-size buf)))))

(define (whatsapp--render-conversation! buf messages)
  (let ((rows (whatsapp--parse-messages messages)))
    (if rows
        (whatsapp--render-message-rows! buf rows #f)
        (whatsapp--render-message-rows! buf #f messages))))

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
  (cond
    ((layout-arranging?) #t)
    (else
      (let ((pane (scene-window 'show)))
        (if pane
            (let ((back (active-window)))
              (select-window! pane)
              (switch-to-buffer! buf)
              (select-window! back))
            (pop-to-buffer buf))))))

(define (whatsapp--open-chat! chat)
  (let* ((jid (whatsapp--text (plist-get chat 'jid) ""))
         (name (whatsapp--text (plist-get chat 'name) jid))
         (buf (whatsapp--conversation-buffer jid)))
    (if (equal? jid "")
        (message "This chat has no WhatsApp JID")
        (begin
          (unless (buffer-known? buf) (buffer-create buf))
          ;; The scene reuses one middle pane. Its parsed rows belong to
          ;; the old JID, so discard them before mode setup fetches the
          ;; newly selected conversation.
          (unless (equal? jid (buffer-local buf 'whatsapp-messages-jid))
            (buffer-set-local! buf 'whatsapp-messages #f)
            (buffer-set-local! buf 'whatsapp-messages-jid #f)
            (buffer-set-local! buf 'render-blocks #f))
          (buffer-set-local! buf 'whatsapp-jid jid)
          (buffer-set-local! buf 'whatsapp-name name)
          (with-current-buffer buf
            (lambda () (set-mode! "whatsapp-chat-mode")))
          (whatsapp--display-conversation! buf)))))

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
           (else #f)))))

(define-mode "whatsapp-chat-mode"
  (lambda ()
    (let* ((buf (current-buffer))
           (jid (buffer-local buf 'whatsapp-jid))
           (rows
             (and (equal? jid (buffer-local buf 'whatsapp-messages-jid))
                  (buffer-local buf 'whatsapp-messages))))
      (whatsapp--join-group! buf)
      (buffer-set-read-only! buf #t)
      (buffer-set-local! buf 'transient #t)
      (buffer-set-local! buf 'desktop-skip-locals
        '(render-blocks whatsapp-messages whatsapp-messages-jid))
      (buffer-set-local! buf 'render-mode "blocks")
      (buffer-set-local! buf 'modeline-info
        (string-append
          "WhatsApp · "
          (whatsapp--text (buffer-local buf 'whatsapp-name) "chat")))
      (if rows
          (whatsapp--render-message-rows! buf rows #f)
          (if jid
              (whatsapp--refresh-conversation! buf)
              (whatsapp--render-message-rows! buf '() #f))))))

(mode-doc! "whatsapp-chat-mode"
  "Compact WhatsApp message rows. Use r to reply and g to refresh.")

(mode-keys! "whatsapp-chat-mode"
  '(("r" "whatsapp-reply")
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
    'preview (lambda (buf chat) (whatsapp--open-chat! chat))
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
          (whatsapp--open-chat! chat)
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

(define-command "whatsapp-reply" "Send a reply to this WhatsApp chat"
  (lambda ()
    (let ((buf (current-buffer)))
      (read-string "Reply: "
        (lambda (text)
          (let ((trimmed (string-trim text)))
            (unless (equal? trimmed "")
              (whatsapp--send! buf trimmed))))
        'history 'whatsapp-reply-history))))

(mode-icon! "whatsapp-mode" "W")
(mode-icon! "whatsapp-chat-mode" "W")

