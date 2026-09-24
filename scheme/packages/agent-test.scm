;;; agent-test.scm --- the model a chat shows after the adapter reports one.
;;;
;;; A Claude adapter matches a pinned full id, such as claude-opus-5-5[1m],
;;; to its own picker entry, opus[1m], and reports that entry. The chat
;;; keeps the id the person chose. An adapter that reports its default did
;;; not match the pin, so the chat shows the default.

(domain! 'testing)
(effects! '(read))

(define t--ag-buf "*zz-agent-model*")

(define t--ag-available
  '(("default" "Default (recommended)") ("opus[1m]" "Opus 5.5") ("sonnet" "Sonnet 5")))

(define (t--ag-chat! pin)
  (test-buffer! t--ag-buf "")
  (buffer-set-local! t--ag-buf 'agent-slug "zz-ag")
  (buffer-set-local! t--ag-buf 'agent-connector "zz-connector")
  (buffer-set-local! t--ag-buf 'agent-model pin)
  t--ag-buf)

(define (t--ag-report! cur)
  (agent-handle-event "zz-ag"
    (list 'type 'model-state 'current cur 'available t--ag-available))
  (buffer-local t--ag-buf 'agent-model))

(effects! '(write))

(deftest 'a-pin-the-adapter-matched-keeps-its-id
  "the adapter reports its entry for the pin; the chat keeps the pin"
  (lambda ()
    (t--ag-chat! "claude-opus-5-5[1m]")
    (check-equal! (t--ag-report! "opus[1m]") "claude-opus-5-5[1m]"
                  "the pinned id stays")))

(deftest 'a-pin-the-adapter-did-not-match-shows-the-default
  "an unmatched pin falls back to the adapter's default"
  (lambda ()
    (t--ag-chat! "no-such-model")
    (check-equal! (t--ag-report! "default") "default" "the chat shows the default")))

(deftest 'a-pin-from-the-adapter-list-takes-the-report
  "a listed pin is the adapter's own id, so the report is the truth"
  (lambda ()
    (t--ag-chat! "sonnet")
    (check-equal! (t--ag-report! "opus[1m]") "opus[1m]" "the report wins")))

(deftest 'a-chat-with-no-pin-takes-the-report
  "no pin: the chat shows what the adapter runs"
  (lambda ()
    (t--ag-chat! #f)
    (check-equal! (t--ag-report! "opus[1m]") "opus[1m]" "the report wins")))
