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

(define (whatsapp--conversation-buffer jid)
  (string-append "*whatsapp:" jid "*"))

(define (whatsapp--conversation-text name messages)
  (string-append
    "WhatsApp · " name "\n"
    "r reply   g refresh   q quit\n\n"
    (if (and (string? messages) (not (equal? (string-trim messages) "")))
        messages
        "No messages.\n")))

(domain! 'chat)
(effects! '(write))

(define (whatsapp--replace-text! buf text)
  (buffer-delete-range! buf 0 (buffer-size buf))
  (buffer-append! buf text))

(define (whatsapp--render-conversation! buf messages)
  (when (buffer-known? buf)
    (let ((name (whatsapp--text (buffer-local buf 'whatsapp-name) "WhatsApp")))
      (whatsapp--replace-text! buf (whatsapp--conversation-text name messages))
      (buffer-set-local! buf 'modeline-info (string-append "WhatsApp · " name))
      (buffer-set-read-only! buf #t))))

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
        (k rows)
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
          (when (buffer-known? buf)
            (whatsapp--render-conversation! buf
              (if ok
                  text
                  (string-append
                    "Could not load messages: "
                    (whatsapp--text text "unknown error")
                    "\n")))))))))

(define (whatsapp--open-chat! chat)
  (let* ((jid (whatsapp--text (plist-get chat 'jid) ""))
         (name (whatsapp--text (plist-get chat 'name) jid))
         (buf (whatsapp--conversation-buffer jid)))
    (if (equal? jid "")
        (message "This chat has no WhatsApp JID")
        (begin
          (unless (buffer-known? buf) (buffer-create buf))
          (buffer-set-local! buf 'whatsapp-jid jid)
          (buffer-set-local! buf 'whatsapp-name name)
          (with-current-buffer buf
            (lambda () (set-mode! "whatsapp-chat-mode")))
          (whatsapp--refresh-conversation! buf)
          (pop-to-buffer buf)))))

(domain! 'chat)
(effects! '(write external))

(define *whatsapp-reply-tool* (string-append "send" "_" "message"))

(define (whatsapp--send! buf text)
  (let ((jid (buffer-local buf 'whatsapp-jid)))
    (if (not jid)
        (message "This buffer has no WhatsApp recipient")
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
(effects! '(write))

(define-mode "whatsapp-chat-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-read-only! buf #t)
      (buffer-set-local! buf 'modeline-info
        (string-append
          "WhatsApp · "
          (whatsapp--text (buffer-local buf 'whatsapp-name) "chat"))))))

(mode-doc! "whatsapp-chat-mode"
  "A WhatsApp conversation. Use r to reply and g to refresh.")

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
           "Use g to refresh, / to filter, and q to quit.")
    'buffer *whatsapp-buffer*
    'rows (lambda (buf) (list-entries buf))
    'cache-fetch whatsapp--fetch-chats
    'cache-ttl whatsapp-cache-ttl
    'columns (lambda (buf)
               (list (list "chat" 24) (list "last active" 25)
                     (list "message" #f)))
    'cells whatsapp--cells
    'title (lambda (buf) "WhatsApp chats")
    'meta (lambda (buf)
            (string-append
              (number->string (length (list-entries buf)))
              " recent chats"))
    'total (lambda (buf) (length (list-entries buf)))
    'no-marks #t
    'key (lambda (buf chat) (plist-get chat 'jid))
    'footer (lambda (buf)
              '(("RET" "read") ("/" "filter") ("g" "refresh")
                ("q" "quit")))
    'keys '(("RET" "whatsapp-open")
            ("g" "whatsapp-refresh")
            ("q" "quit-window"))))

(mode-doc! "whatsapp-mode"
  "Recent WhatsApp chats. RET reads a conversation. Use g to refresh.")

(domain! 'chat)
(effects! '(read external display))

(define-command "whatsapp" "List recent WhatsApp chats"
  (lambda () (list-mode-show! "whatsapp-mode")))

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

