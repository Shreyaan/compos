(package! 'chat-perf)
(domain! 'diagnostics)
(effects! '(read))

(define *chat-perf-buffer* "*Chat Performance*")

(define (chat-perf--events path)
  (let ((text (and path (file-exists? path) (read-file path))))
    (if (not text)
        '()
        (let loop ((lines (string-split text "\n")) (out '()))
          (if (null? lines)
              (reverse out)
              (let ((row (json-parse (car lines))))
                (loop (cdr lines) (if row (cons row out) out))))))))

(define (chat-perf--rows buf)
  (chat-perf--events (buffer-local buf 'chat-perf-path)))

(define (chat-perf--duration row)
  (let ((us (plist-get row 'duration_us)) (ms (plist-get row 'duration_ms)))
    (cond (us (string-append (number->string (/ us 1000)) "ms"))
          (ms (string-append (number->string ms) "ms"))
          (else ""))))

(define (chat-perf--detail row)
  (or (plist-get row 'title) (plist-get row 'backend) (plist-get row 'model) ""))

(define (chat-perf--cells buf row)
  (list (or (plist-get row 'epoch) "")
        (or (plist-get row 'kind) "")
        (or (plist-get row 'type) "")
        (or (plist-get row 'status) "")
        (chat-perf--duration row)
        (chat-perf--detail row)))

(define (chat-perf--columns buf)
  (list (list "turn" 5 'right) (list "event" 16) (list "type" 14)
        (list "status" 10) (list "time" 10 'right) (list "detail" #f)))

(mode-icon! "chat-perf-mode" "")
(define-list-mode! "chat-perf-mode"
  (list 'doc (string-append
               "This trace shows one chat turn from input through context, backend, tool, and completion events. "
               "Durations come from the measured operation. Press g to read the append-only trace again.")
        'buffer *chat-perf-buffer* 'rows chat-perf--rows
        'columns chat-perf--columns 'cells chat-perf--cells
        'title (lambda (buf) "Chat performance")
        'meta (lambda (buf)
                (let ((path (buffer-local buf 'chat-perf-path)))
                  (string-append (number->string (length (chat-perf--rows buf))) " events · " (or path ""))))
        'no-marks #t 'local-filter #t
        'footer (lambda (buf) '(("g" "refresh") ("/" "filter") ("q" "quit")))
        'keys '(("g" "list-revert") ("q" "quit-window"))))

(effects! '(read write display))
(define-command "chat-perf" "Show the performance trace for this chat"
  (lambda ()
    (let ((slug (agent-slug-of (current-buffer))))
      (if (not slug)
          (message "This buffer has no chat runtime.")
          (let ((path (string-append (compos-home) "/chat-perf/" slug ".chat-perf.jsonl")))
            (unless (buffer-exists? *chat-perf-buffer*) (buffer-create *chat-perf-buffer*))
            (buffer-set-local! *chat-perf-buffer* 'chat-perf-path path)
            (list-mode-show! "chat-perf-mode"))))))

(public! 'chat-perf--events
  "(chat-perf--events PATH) — parse the append-only JSON trace and skip incomplete lines")
