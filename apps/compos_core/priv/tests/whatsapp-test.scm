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

(deftest 'whatsapp-conversation-shows-actions-and-empty-state
  "The conversation explains its actions and shows an empty state."
  (lambda ()
    (let ((text (whatsapp--conversation-text "Mukund" "")))
      (check-contains! text "r reply" "the conversation explains the reply action")
      (check-contains! text "g refresh" "the conversation explains refresh")
      (check-contains! text "No messages." "an empty conversation says so"))))
