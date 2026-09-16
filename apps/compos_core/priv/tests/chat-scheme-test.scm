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
    (check-false! (chat-scheme-input? "\\(+ 1 2)") "a backslash sends it as text")
    (check-equal! (chat-scheme-unescape "\\(+ 1 2)") "(+ 1 2)"
                  "and the backslash never reaches the model")))

(deftest 'malformed-scheme-goes-nowhere
  "an unbalanced expression is neither evaluated nor sent"
  (lambda ()
    (check-false! (chat-scheme-well-formed? "(+ 1 1") "an unterminated list")
    (check-false! (chat-scheme-well-formed? "(foo))") "a stray closer")
    (check-true! (chat-scheme-well-formed? "(+ 1 1)") "a whole expression")
    (let ((buf (t--cs-chat! "(+ 1 1")))
      (with-current-buffer buf (lambda () (run-command "agent-send")))
      (check-equal! (buffer-text buf) "transcript\n(+ 1 1\n"
                    "RET took a newline and left the text where it was typed")
      (buffer-kill! buf))))

(deftest 'a-value-is-pretty-printed
  "a plist too wide for one line breaks a key and its value per line"
  (lambda ()
    (check-equal! (chat-scheme-pp '(a 1 b 2) 0) "(a 1 b 2)"
                  "what fits stays on its line")
    (check-true! (string-contains?
                   (chat-scheme-pp (list 'kind "command" 'name "agent-send"
                                         'doc "Send the input to the agent, reviving it if dead")
                                   0)
                   "\n name \"agent-send\"")
                 "a wide plist breaks, one key to a line")))

(deftest 'completion-at-the-prompt-is-the-editors-own-vocabulary
  "inside an expression it completes orderless; in prose it offers nothing"
  (lambda ()
    (let ((buf (t--cs-chat! "(buf-tex")))
      (with-current-buffer buf
        (lambda ()
          (chat-scheme--mode-hook!)
          (end-of-buffer!)
          (check-equal! (car (car (caddr (chat-scheme--capf)))) "buffer-text"
                        "buf-tex finds buffer-text, terms in any order")))
      (buffer-kill! buf))
    (let ((buf (t--cs-chat! "what does buf")))
      (with-current-buffer buf
        (lambda ()
          (chat-scheme--mode-hook!)
          (end-of-buffer!)
          (check-equal! (caddr (capf-collect (capf-sources))) '()
                        "prose offers nothing, and dabbrev is not asked either")))
      (buffer-kill! buf))))

(deftest 'ret-on-an-expression-prints-its-value
  "the value lands in the transcript and the input clears"
  (lambda ()
    (let ((buf (t--cs-chat! "(+ 1 2)")))
      (with-current-buffer buf (lambda () (run-command "agent-send")))
      (check-equal! (buffer-text buf) "transcript\n\nλ (+ 1 2)\n3\n"
                    "the expression and its value are in the transcript")
      (check-equal! (caddr (car (buffer-local buf 'agent-blocks))) "eval"
                    "the block is its own kind: the reader is shown code, not a summary")
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

(deftest 'prompt-history-is-one-ring-for-every-chat
  "what you ran in one chat, up-arrow reaches from another"
  (lambda ()
    (let ((saved *chat-input-history*))
      (set! *chat-input-history* '())
      (let ((a (t--cs-chat! "(+ 3 4)")))
        (with-current-buffer a (lambda () (run-command "agent-send")))
        (buffer-kill! a))
      (check-equal! (car (chat-history)) "(+ 3 4)"
                    "the expression joined the history")
      (let ((b (t--cs-chat! "")))
        (with-current-buffer b
          (lambda ()
            (end-of-buffer!)
            (run-command "chat-history-previous")
            (check-equal! (chat-input-text b) "(+ 3 4)"
                          "a prompt in another chat recalls it")
            (run-command "chat-history-next")
            (check-equal! (chat-input-text b) ""
                          "and down comes back to the draft")))
        (buffer-kill! b))
      (set! *chat-input-history* saved))))

(deftest 'the-history-collapses-consecutive-repeats
  "the same input twice running takes one slot, and blanks take none"
  (lambda ()
    (let ((saved *chat-input-history*))
      (set! *chat-input-history* '())
      (chat-history-push! "(foo)")
      (chat-history-push! "(foo)")
      (chat-history-push! "   ")
      (check-equal! (length (chat-history)) 1 "one entry")
      (set! *chat-input-history* saved))))

(deftest 'a-bare-command-call-runs-the-command
  "an M-x command is not a variable, so (name) reads as the command"
  (lambda ()
    (check-equal! (chat-scheme-command "(previous-buffer)") "previous-buffer"
                  "a command name the environment does not bind")
    (check-equal! (chat-scheme-command "(buffer-list)") #f
                  "a bound function stays a function")
    (check-equal! (chat-scheme-command "(+ 1 2)") #f
                  "an ordinary expression is left alone")
    (check-equal! (chat-scheme-command "(apropos \"windows\")") #f
                  "only a one-word call qualifies")))

(deftest 'an-unbound-command-name-says-where-it-lives
  "nested, the rewrite cannot help, so the error names the command table"
  (lambda ()
    (let ((body (chat-scheme-report "(list (previous-buffer))"
                                    (eval-string-safe "(list (previous-buffer))"))))
      (check-true! (string-index body "is an M-x command")
                   "the hint follows the error")
      (check-true! (string-index body "(run-command \"previous-buffer\")")
                   "and spells the call out"))
    (check-equal! (chat-scheme-hint "unbound variable: not-a-command-anywhere") ""
                  "a name no command table knows gets no hint")))
