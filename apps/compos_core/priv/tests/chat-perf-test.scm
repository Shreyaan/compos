;;; chat-perf-test.scm --- the chat trace separates the agent's round trip
;;; from the editor's own work.

(domain! 'testing)
(effects! '(read))

(deftest 'chat-perf-cells-are-strings
  "a numeric field renders as text; the list measures strings, not numbers"
  (lambda ()
    (check-equal! (chat-perf--text 0) "0" "a turn of zero is still a cell")
    (check-equal! (chat-perf--text "") "" "an empty string stays empty")
    (check-equal! (chat-perf--text #f) "" "a missing field is blank")
    (let ((cells (chat-perf--cells #f (list 'epoch 0 'kind "turn_start"))))
      (check-true! (null? (filter (lambda (c) (not (string? c))) cells))
        "every cell is a string"))))

(deftest 'chat-perf-round-trip-ignores-non-numbers
  "the backends write an empty duration on an open call; it is not a time"
  (lambda ()
    (check-equal! (chat-perf--round-trip (list 'duration_ms "")) ""
      "an empty duration is blank, not a printed empty string")
    (check-equal! (chat-perf--round-trip (list 'duration_ms 12)) "12ms" "milliseconds")
    (check-equal! (chat-perf--round-trip (list 'duration_us 2000)) "2ms" "microseconds")
    (check-equal! (chat-perf--round-trip '()) "" "no duration, no cell")))

(deftest 'chat-perf-detail-skips-empty-fields
  "a backend event carries an empty title; the model behind it is the detail"
  (lambda ()
    (check-equal! (chat-perf--detail (list 'title "" 'model "opus")) "opus"
      "an empty title does not win over a real model")
    (check-equal! (chat-perf--detail (list 'title "ToolSearch")) "ToolSearch" "a real title wins")
    (check-equal! (chat-perf--detail '()) "" "nothing to say")))

(deftest 'chat-perf-lane-tool-reads-the-proxy-label
  "the lane label names the tool in its first quoted field"
  (lambda ()
    (check-equal! (chat-perf--lane-tool "eval (mcp-proxy-call \"eval-scheme\" \"eyJ\")")
      "eval-scheme" "the tool name")
    (check-false! (chat-perf--lane-tool "eval (buffer-list)") "another eval is not a proxy call")
    (check-false! (chat-perf--lane-tool #f) "no label, no tool")))

(deftest 'chat-perf-joins-the-editor-span-inside-the-round-trip
  "the lane span that ended between the call and its completion is the editor's"
  (lambda ()
    (let* ((events (list (list 'type "tool-call" 'id "a" 'at_us 1000000)
                         (list 'type "tool-update" 'id "a" 'status "completed"
                               'at_us 3000000 'duration_ms 2000)))
           (spans '((2000 25 0)))
           (joined (chat-perf--join-spans-with events spans))
           (done (cadr joined)))
      (check-equal! (plist-get done 'editor_ms) 25 "the span lands on the completion")
      (check-equal! (chat-perf--editor done) "25ms" "and renders as the editor cell"))))

(deftest 'chat-perf-leaves-an-unmatched-completion-blank
  "a span the ring has dropped shows no editor cell; a zero would be a lie"
  (lambda ()
    (let* ((events (list (list 'type "tool-call" 'id "a" 'at_us 1000000)
                         (list 'type "tool-update" 'id "a" 'status "completed"
                               'at_us 3000000 'duration_ms 2000)))
           (joined (chat-perf--join-spans-with events '((9000 25 0))))
           (done (cadr joined)))
      (check-false! (plist-get done 'editor_ms) "a span outside the window is not ours")
      (check-equal! (chat-perf--editor done) "" "the cell stays blank"))))

(deftest 'chat-perf-totals-separate-the-two-clocks
  "the meta line adds the agent's round trips and the editor's work apart"
  (lambda ()
    (let ((rows (list (list 'type "tool-update" 'status "completed"
                            'duration_ms 2000 'editor_ms 25)
                      (list 'type "tool-update" 'status "completed" 'duration_ms 1000)
                      (list 'type "chunk"))))
      (check-equal! (chat-perf--totals rows) '(3000 25 2)
        "two tools, three seconds charged, twenty-five milliseconds spent"))))
