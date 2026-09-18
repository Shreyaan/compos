;;; chat-view-test.scm --- The rich chat is a block tree that Scheme composes.
;;;
;;; chat-view-sync! maps the transcript model to 'render-blocks. These tests
;;; call it and read the tree as data; the renderer is tested in Elixir.

(domain! 'testing)
(effects! '(write))

(define (chat-view-test--buffer name)
  (let ((buf (test-buffer! name "hello\nPaint is **fast**.\n▸ run\n{\"x\":1}\ndraft")))
    (buffer-set-local! buf 'agent-blocks
      '((26 34 "tool" "t1" "Read: a.txt" "read" "done" 32 1400)
        (6 26 "prose")
        (0 6 "user" "hello")))
    (buffer-set-local! buf 'agent-saved-mark 34)
    (buffer-set-local! buf 'render-mode "blocks")
    buf))

(define (chat-view-test--children b) (or (plist-get b 'children) '()))

(deftest 'chat-view-composes-the-transcript-as-blocks
  "a rich chat's model becomes the transcript list, the prompt, and the input"
  (lambda ()
    (let ((buf (chat-view-test--buffer "*zz-chat-view*")))
      (chat-view-sync! buf)
      (let* ((tree (buffer-local buf 'render-blocks))
             (list-block (car tree))
             (rows (chat-view-test--children list-block))
             (tool (nth 2 rows))
             (details (car (chat-view-test--children tool)))
             (summary (car (chat-view-test--children details))))
        (check-equal! (length tree) 2 "the transcript and the prompt, no activity")
        (check-equal! (plist-get list-block 'isolate) #t "the transcript is an isolated list")
        (check-equal! (plist-get list-block 'follow) #t "the transcript follows its tail")
        (check-equal! (map (lambda (r) (plist-get r 'tag)) rows)
                      '("c-user" "c-agent" "c-toolcall") "oldest block first")
        (check-equal! (plist-get (nth 1 rows) 'range) '(6 26) "prose is a range of the buffer")
        (check-equal! (plist-get (nth 1 rows) 'format) "markdown" "prose draws as Markdown")
        (check-equal! (plist-get details 'open) #f "a card starts closed")
        (check-equal! (plist-get summary 'click) "chat-card:t1" "the summary toggles its card")
        (check-equal! (buffer-local buf 'render-input) "agent-saved-mark"
                      "the input starts at the chat mark")
        (check-equal! (plist-get (car (buffer-local buf 'render-root)) 'tag) #f
                      "the root is one plist")
        (check-equal! (plist-get (buffer-local buf 'render-root) 'class) "agent-view"
                      "the root names the chat's layout"))
      (buffer-kill! buf))))

(deftest 'chat-view-keeps-older-views-when-a-block-lands
  "a pushed block adds one view and keeps every older view"
  (lambda ()
    (let ((buf (chat-view-test--buffer "*zz-chat-view-push*")))
      (chat-view-sync! buf)
      (let ((before (chat-view-test--children (car (buffer-local buf 'render-blocks)))))
        (agent-block-push! buf 34 34 "meta" '())
        (chat-view-sync! buf)
        (let ((after (chat-view-test--children (car (buffer-local buf 'render-blocks)))))
          (check-equal! (length after) 4 "the new block has a view")
          (check-equal! (reverse (cdr (reverse after))) before "the older views are the same")))
      (buffer-kill! buf))))

(deftest 'chat-view-card-click-opens-the-card
  "the block click on a card summary opens the card and drops its preview"
  (lambda ()
    (let ((buf (chat-view-test--buffer "*zz-chat-view-card*")))
      (chat-view-sync! buf)
      (check-true! (run-hook-with-args-until-success 'block-click buf "chat-card:t1")
                   "the chat handles its own click")
      (let* ((tool (nth 2 (chat-view-test--children (car (buffer-local buf 'render-blocks)))))
             (details (car (chat-view-test--children tool))))
        (check-equal! (plist-get details 'open) #t "the card is open")
        (check-equal! (agent-open-cards buf) '("t1") "the open set holds the card"))
      (buffer-kill! buf))))

(deftest 'chat-view-plain-view-writes-no-tree
  "a plain chat keeps no block tree"
  (lambda ()
    (let ((buf (chat-view-test--buffer "*zz-chat-view-plain*")))
      (buffer-set-local! buf 'render-mode "plain")
      (chat-view-sync! buf)
      (check-equal! (buffer-local buf 'render-blocks) #f "no tree")
      (buffer-kill! buf))))

(deftest 'chat-view-labels
  "the card's duration and token labels"
  (lambda ()
    (check-equal! (chat-view-duration-label 340) "340ms" "milliseconds")
    (check-equal! (chat-view-duration-label 1400) "1.4s" "seconds, one decimal")
    (check-equal! (chat-view-duration-label 125000) "2m 05s" "minutes")
    (check-equal! (chat-view-duration-label #f) #f "no duration")
    (check-equal! (chat-view-token-label 3) #f "too small to say")
    (check-equal! (chat-view-token-label 400) "~100 tok" "tokens")
    (check-equal! (chat-view-token-label 6000) "~1.5k tok" "thousands")))

(deftest 'chat-view-reuses-views-after-an-excise
  "a change deep in the model keeps the views of the unchanged blocks"
  (lambda ()
    (let ((buf (chat-view-test--buffer "*zz-chat-view-deep*")))
      (chat-view-sync! buf)
      (buffer-set-local! buf 'agent-blocks
        '((26 34 "tool" "t1" "Read: a.txt" "read" "done" 32 1400)
          (6 20 "prose")
          (0 6 "user" "hello")))
      (chat-view-sync! buf)
      (let ((rows (chat-view-test--children (car (buffer-local buf 'render-blocks)))))
        (check-equal! (length rows) 3 "every block has a view")
        (check-equal! (plist-get (nth 1 rows) 'range) '(6 20) "the changed block is new"))
      (buffer-kill! buf))))
