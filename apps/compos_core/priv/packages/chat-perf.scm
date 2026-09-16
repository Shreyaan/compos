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
              (map cadr (sort (map (lambda (row) (list (or (plist-get row 'mono_us) 0) row)) out)))
              (let ((row (json-parse (car lines))))
                (loop (cdr lines) (if row (cons row out) out))))))))

;; The editor's own record of a proxy call, from the lane telemetry ring.
;; The lane label reads: eval (mcp-proxy-call "NAME" "<base64 args>" ...
;; so the first quoted field is the tool.
(define (chat-perf--lane-tool label)
  (and label
       (string-contains? label "mcp-proxy-call")
       (let ((parts (string-split label "\"")))
         (and (> (length parts) 1) (list-ref parts 1)))))

;; (END-MS DURATION-MS QUEUE-MS) per proxy call the ring still holds. The
;; ring keeps telemetry-event-limit events, so an older turn has no span
;; left and shows no editor cell. A blank cell is honest; a zero is not.
(define (chat-perf--lane-spans)
  (let loop ((rows (telemetry-events 1000)) (out '()))
    (if (null? rows)
        out
        (let ((row (car rows)))
          (loop (cdr rows)
                (if (chat-perf--lane-tool (plist-get row 'label))
                    (cons (list (or (plist-get row 'time-ms) 0)
                                (or (plist-get row 'duration-ms) 0)
                                (or (plist-get row 'queue-ms) 0))
                          out)
                    out))))))

(define (chat-perf--span-in spans lo hi)
  (let loop ((s spans))
    (cond ((null? s) #f)
          ((and (>= (car (car s)) lo) (<= (car (car s)) hi)) (car s))
          (else (loop (cdr s))))))

;; A completed tool-update carries the agent's round trip. The lane span
;; that ended inside that window carries what the editor spent. Attach it
;; so the two numbers sit side by side.
;; The pure half: given the spans, attach them. A completed tool-update
;; carries the agent's round trip; the lane span that ended inside that
;; window carries what the editor spent. Attach it so the two numbers sit
;; side by side.
(define (chat-perf--join-spans-with events spans)
  (if (null? spans)
      events
      (let loop ((rest events) (open '()) (out '()))
        (if (null? rest)
            (reverse out)
            (let* ((row (car rest))
                   (ty (plist-get row 'type))
                   (id (plist-get row 'id))
                   (at (or (plist-get row 'at_us) 0)))
              (cond
                ((equal? ty "tool-call")
                 (loop (cdr rest) (cons (list id at) open) (cons row out)))
                ((and (equal? ty "tool-update")
                      (equal? (plist-get row 'status) "completed"))
                 (let* ((hit (assoc id open))
                        (span (and hit (chat-perf--span-in
                                         spans
                                         (quotient (cadr hit) 1000)
                                         (quotient at 1000)))))
                   (loop (cdr rest) open
                         (cons (if span (append row (list 'editor_ms (cadr span))) row)
                               out))))
                (else (loop (cdr rest) open (cons row out)))))))))

(define (chat-perf--join-spans events)
  (chat-perf--join-spans-with events (chat-perf--lane-spans)))

(define (chat-perf--rows buf)
  (chat-perf--join-spans (chat-perf--events (buffer-local buf 'chat-perf-path))))

(define (chat-perf--text v)
  (cond ((string? v) v)
        ((number? v) (number->string v))
        ((symbol? v) (symbol->string v))
        (else "")))

;; The agent's announce-to-announce interval, stamped where the backend
;; events serialize: the tool-call notice to the tool-update notice. It
;; holds the agent's own dispatch and its handling of the result as well
;; as the work, so it is a round trip, not a tool time. The editor column
;; is what the call cost here.
;; A whole millisecond prints without a decimal point: 2ms, not 2.0ms.
;; N/1000 without a trailing .0 when it divides evenly: 2, not 2.0.
;; Microseconds read as milliseconds, milliseconds as seconds.
(define (chat-perf--thousandths n)
  (if (= 0 (remainder n 1000))
      (number->string (quotient n 1000))
      (number->string (/ n 1000))))

(define (chat-perf--round-trip row)
  (let ((us (plist-get row 'duration_us)) (ms (plist-get row 'duration_ms)))
    (cond ((number? us) (string-append (chat-perf--thousandths us) "ms"))
          ((number? ms) (string-append (number->string ms) "ms"))
          (else ""))))

(define (chat-perf--editor row)
  (let ((ms (plist-get row 'editor_ms)))
    (if (number? ms) (string-append (number->string ms) "ms") "")))

(define (chat-perf--detail row)
  (let loop ((keys '(title backend model)))
    (if (null? keys)
        ""
        (let ((v (chat-perf--text (plist-get row (car keys)))))
          (if (equal? v "") (loop (cdr keys)) v)))))

(define (chat-perf--cells buf row)
  (list (chat-perf--text (plist-get row 'epoch))
        (chat-perf--text (plist-get row 'kind))
        (chat-perf--text (plist-get row 'type))
        (chat-perf--text (plist-get row 'status))
        (chat-perf--round-trip row)
        (chat-perf--editor row)
        (chat-perf--detail row)))

(define (chat-perf--columns buf)
  (list (list "turn" 5 'right) (list "event" 16) (list "type" 14)
        (list "status" 10) (list "round trip" 11 'right) (list "editor" 9 'right)
        (list "detail" #f)))

;; (ROUND-TRIP-MS EDITOR-MS TOOLS) over the rows the list holds.
(define (chat-perf--totals rows)
  (let loop ((r rows) (trip 0) (edit 0) (n 0))
    (if (null? r)
        (list trip edit n)
        (let* ((row (car r))
               (done? (and (equal? (plist-get row 'type) "tool-update")
                           (equal? (plist-get row 'status) "completed")))
               (ms (plist-get row 'duration_ms))
               (ed (plist-get row 'editor_ms)))
          (loop (cdr r)
                (if (and done? (number? ms)) (+ trip ms) trip)
                (if (number? ed) (+ edit ed) edit)
                (if done? (+ n 1) n))))))

;; The two totals this trace exists to separate: what the agent charged
;; for tools, and what the editor spent inside them.
(define (chat-perf--meta buf)
  (let* ((rows (list-entries buf))
         (t (chat-perf--totals rows))
         (path (buffer-local buf 'chat-perf-path)))
    (string-append
      (number->string (length rows)) " events · "
      (number->string (caddr t)) " tools · round trip "
      (chat-perf--thousandths (car t)) "s · editor "
      (number->string (cadr t)) "ms · "
      (or path ""))))

(mode-icon! "chat-perf-mode" "")
(define-list-mode! "chat-perf-mode"
  (list 'doc (string-append
               "This trace shows one chat turn from input through context, backend, tool, and completion events. "
               "`round trip` is the agent's own announce-to-announce interval for a tool: it holds the agent's "
               "dispatch and its handling of the result, not just the work. `editor` is what the call cost "
               "inside compos, from the lane's own record. The difference between them is the agent's, not "
               "the editor's. An `editor` cell is blank once the telemetry ring has dropped the span. "
               "Press g to read the append-only trace again.")
        'buffer *chat-perf-buffer* 'rows chat-perf--rows
        'columns chat-perf--columns 'cells chat-perf--cells
        'title (lambda (buf) "Chat performance")
        'meta chat-perf--meta
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
