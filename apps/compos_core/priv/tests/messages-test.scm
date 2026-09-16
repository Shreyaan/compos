;;; messages-test.scm --- Structured message log policy.

(domain! 'testing)
(effects! '(read write))

(deftest 'messages-record-level-and-source-context
  "message records its level, source buffer, and source group"
  (lambda ()
    (messages-clear!)
    (let* ((buf "*messages-test-source*")
           (group (group-record-create! "messages-test-group")))
      (buffer-create buf)
      (buffer-add-group! buf group)
      (with-current-buffer buf
        (lambda () (message "structured warning" 'warning)))
      (let ((row (car (messages-events))))
        (check-equal! (plist-get row 'level) "warning" "the row keeps its level")
        (check-equal! (plist-get row 'source) buf "the row keeps its source buffer")
        (check-equal! (plist-get row 'group) "messages-test-group"
                      "the row keeps its source group"))
      (buffer-kill! buf)
      (group-dissolve! group))))

(deftest 'view-messages-builds-the-emacs-named-list
  "view-messages gives most space to the colored message"
  (lambda ()
    (messages-clear!)
    (message "ordinary event" 'info)
    (message "failed event" 'error)
    (run-command "view-messages")
    (check-equal! (current-buffer) "*Messages*" "the command keeps the Emacs buffer name")
    (check-equal! (buffer-local "*Messages*" 'mode-name)
                  "messages-mode" "the buffer records its mode")
    (check-true! (string-contains? (buffer-text "*Messages*") "SOURCE")
                 "the list shows one source column")
    (check-true! (string-contains? (buffer-text "*Messages*") "LEVEL")
                 "the level column carries the colour code")
    (check-true! (string-contains? (buffer-text "*Messages*") "failed event")
                 "the list renders message text")))

(deftest 'the-messages-list-puts-the-newest-line-on-top
  "the log arrives oldest first and the list turns it over"
  (lambda ()
    (messages-clear!)
    (message "older event" 'info)
    (message "newer event" 'info)
    (run-command "view-messages")
    (let ((text (buffer-text "*Messages*")))
      (check-true! (< (car (isearch-matches "newer event"))
                      (car (isearch-matches "older event")))
                   "the newest message is the higher row")
      (check-true! (string-contains? text "older event")
                   "and the older one is still there"))))

(deftest 'the-messages-list-wears-a-smaller-face
  "a log is read in bulk, so *Messages* sits a step below the default size"
  (lambda ()
    (messages-clear!)
    (message "a row" 'info)
    (check-equal! (buffer-local "*Messages*" 'text-scale) messages-text-scale
                  "the buffer carries the configured step")))

(deftest 'the-messages-list-pins-its-keys-in-the-keymap-component
  "the key bar is the shared ui/keymap component, not a header line"
  (lambda ()
    (messages-clear!)
    (message "a row" 'info)
    (run-command "view-messages")
    (let ((blocks (buffer-local "*Messages*" 'footer-line-blocks)))
      (check-true! (pair? blocks) "the footer carries blocks")
      (check-equal! (plist-get (car blocks) 'tag) "c-key-hints"
                    "and those blocks are the keymap component"))))

(deftest 'messages-cells-use-group-source-and-level-color
  "the source prefers the group and the message color carries the level"
  (lambda ()
    (let ((cells
            (messages--cells "*unused*"
              (list 'level "error" 'source "buffer.scm"
                    'group "editor" 'project "compos.el" 'text "failed"))))
      (check-equal! (length cells) 2 "the row has only source and message")
      (check-equal! (car (car cells)) "editor" "the source shows the group")
      (check-equal! (car (car (cdr cells))) "failed" "the message keeps its text")
      (check-equal! (car (cdr (car (cdr cells)))) "alert"
                    "the message uses the error color"))))

(deftest 'messages-level-filter-narrows-the-list
  "the messages list filters exact log levels"
  (lambda ()
    (messages-clear!)
    (message "keep this error" 'error)
    (message "hide this detail" 'debug)
    (run-command "view-messages")
    (list-filter-push! "*Messages*" '("level" "error"))
    (check-true! (string-contains? (buffer-text "*Messages*") "keep this error")
                 "the selected level remains")
    (check-false! (string-contains? (buffer-text "*Messages*") "hide this detail")
                  "other levels leave the view")
    (list-filter-clear! "*Messages*")))

(deftest 'messages-buffer-is-the-list-from-the-start
  "*Messages* wears messages-mode and is read-only before anyone runs view-messages"
  (lambda ()
    (messages-clear!)
    (message "first row" 'info)
    (check-equal! (buffer-local "*Messages*" 'mode-name) "messages-mode" "the mode is on")
    (check-true! (buffer-read-only? "*Messages*") "the list is read-only")
    (list-refresh! "*Messages*")
    (check-true! (string-contains? (buffer-text "*Messages*") "first row")
                 "the list draws the row")))

(deftest 'a-killed-messages-buffer-returns-as-the-list
  "after buffer-kill!, the next message makes *Messages* again in messages-mode"
  (lambda ()
    (messages-clear!)
    (when (buffer-exists? "*Messages*") (buffer-kill! "*Messages*"))
    (message "after the kill" 'info)
    (check-true! (buffer-exists? "*Messages*") "the buffer is back")
    (check-equal! (buffer-local "*Messages*" 'mode-name) "messages-mode" "in messages-mode")
    (check-true! (buffer-read-only? "*Messages*") "and read-only")
    (list-refresh! "*Messages*")
    (check-true! (string-contains? (buffer-text "*Messages*") "after the kill")
                 "with the row")))

(deftest 'a-message-redraws-the-shown-list
  "a message while *Messages* is in a window appears with no refresh"
  (lambda ()
    (messages-clear!)
    (run-command "view-messages")
    (message "live row" 'info)
    (check-true! (string-contains? (buffer-text "*Messages*") "live row")
                 "the shown list follows the log")))
