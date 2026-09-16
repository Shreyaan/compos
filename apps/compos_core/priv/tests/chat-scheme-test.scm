;;; chat-scheme-test.scm --- the chat prompt is a REPL as well as a prompt.
;;;
;;; An input that reads as a parenthesised expression runs in the editor and
;;; prints into the transcript: no turn is spent, and the model is never told
;;; it happened. Prose that has to open with a paren escapes it.

(domain! 'testing)
(effects! '(read))

(define t--cs-buf "*zz-chat-scheme*")

(effects! '(write))

(define (t--cs-chat! input)
  (test-buffer! t--cs-buf "transcript\n")
  (buffer-set-local! t--cs-buf 'mode-name "chat-mode")
  (buffer-set-local! t--cs-buf 'render-mode "agent")
  (buffer-set-local! t--cs-buf 'agent-saved-mark (buffer-size t--cs-buf))
  (buffer-append! t--cs-buf input)
  t--cs-buf)

(deftest 'a-parenthesised-input-is-scheme
  "and prose that merely mentions a call is not"
  (lambda ()
    (check-true! (chat-scheme-input? "(+ 1 2)") "a bare expression runs")
    (check-false! (chat-scheme-input? "what does (foo) do?") "prose is prose")
    (check-false! (chat-scheme-input? "(foo) and then?") "a tail after it is prose")
    (check-false! (chat-scheme-input? "\\(+ 1 2)") "a backslash sends it as text")
    (check-equal! (chat-scheme-unescape "\\(+ 1 2)") "(+ 1 2)"
                  "and the backslash never reaches the model")))

(deftest 'ret-on-an-expression-prints-its-value
  "the value lands in the transcript and the input clears"
  (lambda ()
    (let ((buf (t--cs-chat! "(+ 1 2)")))
      (with-current-buffer buf (lambda () (run-command "agent-send")))
      (check-equal! (buffer-text buf) "transcript\n\nλ (+ 1 2)\n3\n"
                    "the expression and its value are in the transcript")
      (check-equal! (chat-input-text buf) "" "the input is clear")
      (buffer-kill! buf))))

(deftest 'an-error-prints-instead-of-breaking-ret
  "a bad expression is a printed line, not a dead key"
  (lambda ()
    (let ((buf (t--cs-chat! "(zz-cs-not-bound)")))
      (with-current-buffer buf (lambda () (run-command "agent-send")))
      (check-true! (string-contains? (buffer-text buf) "error: unbound variable")
                   "the error shows where it was typed")
      (check-equal! (chat-input-text buf) "" "the input is clear")
      (buffer-kill! buf))))

(deftest 'the-expression-runs-in-its-own-chat
  "current-buffer inside it is the chat, the way a shell has a directory"
  (lambda ()
    (let ((buf (t--cs-chat! "(current-buffer)")))
      (with-current-buffer buf (lambda () (run-command "agent-send")))
      (check-true! (string-contains? (buffer-text buf) t--cs-buf)
                   "the chat is the current buffer")
      (buffer-kill! buf))))

(deftest 'a-repl-row-is-status-not-conversation
  "it is saved with the chat and filtered from every model-facing path"
  (lambda ()
    (let ((buf (t--cs-chat! "(+ 2 2)")))
      (with-current-buffer buf (lambda () (run-command "agent-send")))
      (check-equal! (plist-get (car (chat-record buf)) 'role) "status"
                    "the row is status")
      (buffer-kill! buf))))

(deftest 'the-repl-can-be-turned-off
  "with chat-scheme-input #f every input is a message again"
  (lambda ()
    (let ((saved chat-scheme-input))
      (customize-set! 'chat-scheme-input #f)
      (check-false! (chat-scheme-input? "(+ 1 2)") "nothing runs locally")
      (customize-set! 'chat-scheme-input saved)
      (check-true! (chat-scheme-input? "(+ 1 2)") "and it comes back"))))
