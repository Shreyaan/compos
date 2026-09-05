;;; whatsapp-test.scm --- WhatsApp list and conversation policy.

(package! "whatsapp-test")

(domain! 'diagnostics)
(effects! '(read))

(define t--whatsapp-chat-stream
  (string-append
    "{\"jid\":\"123@s.whatsapp.net\",\"name\":\"Mukund\","
    "\"last_message_time\":\"2026-09-05T11:49:38+05:30\","
    "\"last_message\":\"line one\\nline two\",\"last_is_from_me\":1}\n"
    "{\"jid\":\"456@g.us\",\"name\":\"Team\","
    "\"last_message_time\":\"2026-09-05T10:00:00+05:30\","
    "\"last_message\":\"hello\",\"last_is_from_me\":0}"))

(define t--whatsapp-message-stream
  (string-append
    "[2026-09-05 11:49:38] Chat: Mukund From: Me: line one\n"
    "line two\n"
    "[2026-09-05 11:48:00] Chat: Mukund From: Mukund: "
    "[image - Message ID: ABC - Chat JID: 123@s.whatsapp.net] \n"))

(deftest 'whatsapp-parses-chat-stream-and-flattens-previews
  "The chat stream becomes rows with one-line previews."
  (lambda ()
    (let* ((rows (whatsapp--parse-chats t--whatsapp-chat-stream))
           (cells (whatsapp--cells "*WhatsApp*" (car rows))))
      (check-equal! (length rows) 2 "both JSON objects become rows")
      (check-equal! (car cells) "Mukund" "the chat name is the first cell")
      (check-equal! (caddr cells) "me: line one line two"
                    "the preview is one line and marks my message"))))

(deftest 'whatsapp-parses-one-chat-object
  "One JSON object becomes one selectable chat row."
  (lambda ()
    (let ((rows
            (whatsapp--parse-chats
              "{\"jid\":\"123@s.whatsapp.net\",\"name\":\"Mukund\"}")))
      (check-equal! (length rows) 1 "one object still becomes one row")
      (check-equal! (plist-get (car rows) 'jid) "123@s.whatsapp.net"
                    "the JID stays attached to the row"))))

(deftest 'whatsapp-parses-message-stream-into-compact-rows
  "Message rows keep the sender and body without repeated chat labels."
  (lambda ()
    (let* ((rows (whatsapp--parse-messages t--whatsapp-message-stream))
           (first (car rows))
           (second (cadr rows))
           (text (whatsapp--conversation-text rows #f))
           (blocks (whatsapp--conversation-blocks rows #f)))
      (check-equal! (length rows) 2 "both messages become rows")
      (check-equal! (nth 3 first) "line one\nline two"
                    "continuation lines stay with their message")
      (check-true! (nth 4 first) "messages from Me are identified")
      (check-equal! (nth 2 second) "Mukund" "the sender stays visible")
      (check-equal! (nth 3 second) "[image]"
                    "media rows hide transport identifiers")
      (check-contains! text "09-05 11:49  Me"
                       "timestamps are compact")
      (check-false! (string-contains? text "Chat: ")
                    "the chat name is not repeated")
      (check-false! (string-contains? text "From: ")
                    "the sender has no redundant label")
      (check-false! (string-contains? text "Message ID")
                    "transport identifiers stay hidden")
      (check-equal! (length blocks) 3
                    "the actions and two message rows render"))))

(deftest 'whatsapp-conversation-shows-actions-and-empty-state
  "The conversation uses catalogued actions and an empty state."
  (lambda ()
    (let ((text (whatsapp--conversation-text '() #f))
          (blocks (whatsapp--conversation-blocks '() #f)))
      (check-contains! text "No messages." "an empty conversation says so")
      (check-equal! (length blocks) 2
                    "actions and the empty state render")
      (check-contains! (value->string blocks) "Reply"
                       "the reply action is visible")
      (check-contains! (value->string blocks) "Refresh"
                       "the refresh action is visible"))))
