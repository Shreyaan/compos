;;; profile.scm --- one command, measured.
;;;
;;; `M-x profile` arms the editor and waits. The next command you run is
;;; counted: the BEAM's call counters over the editor's own modules, the
;;; reductions and the garbage every process made, and the telemetry rows
;;; the same command left in the scheme, live and browser layers. The
;;; report lands in *Profile*.
;;;
;;; The window is wide on purpose. It opens on pre-command-hook, before
;;; the command, and closes on post-command-hook, after the dashboard
;;; sync, the list redraws and every other package's hook. All of that is
;;; the cost of pressing the key, so all of it is in the profile.
;;;
;;; Counting is cheap, so the wall clock in the report is the real one:
;;; the command runs at its own speed. A call counter is VM-wide, so
;;; anything else the editor did in the same window is counted with it,
;;; and the process section is what says who did the work. Elixir owns
;;; the counters in Compos.Core.Profiler; this package owns when to arm,
;;; what the report says, and where it shows.

(package! 'profile)
(domain! 'diagnostics)
(effects! '(read))

(define *profile-buffer* "*Profile*")

(defcustom 'profile-function-rows 30
  "How many function rows one profile shows."
  'group 'profile 'type 'number)

(defcustom 'profile-site-rows 15
  "How many Scheme call-site rows one profile shows."
  'group 'profile 'type 'number)

(defcustom 'profile-process-rows 8
  "How many process rows one profile shows."
  'group 'profile 'type 'number)

(defcustom 'profile-layer-rows 14
  "How many telemetry rows one profile shows."
  'group 'profile 'type 'number)

;;; --- arming -----------------------------------------------------------------
;;; The prompt that armed the profile is still closing when the profile
;;; is armed: the commands it runs on its way out are not what the reader
;;; meant to measure. A sample of one of those is dropped and the
;;; profiler arms again.

(define *profile-ignored*
  '("profile" "profile-cancel" "execute-extended-command" "keyboard-quit"
    "minibuffer-complete" "minibuffer-exit" "minibuffer-quit"))

(define *profile-armed* #f)
(define *profile-open* #f)

(define (profile--ignored? cmd) (and (member cmd *profile-ignored*) #t))

(define (profile--command)
  (let ((c (this-command)))
    (if (or (not c) (equal? c "")) "self-insert-command" c)))

;;; --- the call sites ---------------------------------------------------------
;;;
;;; An Elixir profile names the Elixir function that ran, so every list
;;; walk in a command arrives as one anonymous `-all/0-fun-82-` with no way
;;; back to the Scheme that ran it. The builtin knows the lambda it was
;;; handed, and a lambda's parameters name its call site: `fold (out
;;; bucket)` is one place in the source and nothing else.
;;;
;;; The count lives here and not in the interpreter on purpose. A check in
;;; the evaluator's builtin path costs a lookup on every builtin call --
;;; measured at 40ms for one C-x b, paid by every command forever, to
;;; serve a tool that is off. Instead the profiler swaps these builtins
;;; for counting wrappers while it is armed and puts them back after, so
;;; nothing is added to the path a command normally takes.

(define *profile-site-builtins* '(map filter fold for-each remove))
(define *profile-site-saved* '())
(define *profile-site-counts* '())
;; #t while a wrapper does its own bookkeeping. The bookkeeping calls
;; fold and remove, which are wrappers too, so without this flag a fold
;; counts itself until the recursion bound stops it.
(define *profile-site-busy* #f)

(define (profile--site-bump! name sig n)
  (let* ((key (list name sig))
         (cell (assoc key *profile-site-counts*)))
    (set! *profile-site-counts*
          (cons (list key (+ 1 (if cell (nth 1 cell) 0)) (+ n (if cell (nth 2 cell) 0)))
                (if cell
                    (remove (lambda (c) (equal? (car c) key)) *profile-site-counts*)
                    *profile-site-counts*)))))

;; the longest list the builtin was given is what it had to walk
(define (profile--site-elements args)
  (fold (lambda (n a) (if (pair? a) (max n (length a)) n)) 0 args))

;; the lambda's own source, clipped: enough to find the one place in the
;; source that wrote it, short enough to be a row
(define (profile--site-of f)
  (let ((src (if (procedure? f) (function-source f) "")))
    (if (string? src)
        (let ((one (string-trim (car (string-split src "\n")))))
          (if (> (string-length one) 58) (string-append (substring one 0 58) "…") one))
        "")))

(define (profile--sites-on!)
  (set! *profile-site-busy* #f)
  (set! *profile-site-counts* '())
  (set! *profile-site-saved*
    (map (lambda (name) (list name (symbol-value name))) *profile-site-builtins*))
  (for-each
    (lambda (saved)
      (let ((name (car saved)) (orig (nth 1 saved)))
        (set-symbol-value! name
          (lambda (f &rest rest)
            (unless *profile-site-busy*
              (set! *profile-site-busy* #t)
              (profile--site-bump! (symbol->string name) (profile--site-of f)
                                   (profile--site-elements rest))
              (set! *profile-site-busy* #f))
            (apply orig (cons f rest))))))
    *profile-site-saved*))

(define (profile--sites-off!)
  (for-each (lambda (saved) (set-symbol-value! (car saved) (nth 1 saved)))
            *profile-site-saved*)
  (set! *profile-site-saved* '())
  (set! *profile-site-busy* #f))

(define (profile--sites-report)
  (map (lambda (c)
         (list 'name (car (car c)) 'site (nth 1 (car c))
               'calls (nth 1 c) 'elements (nth 2 c)))
       *profile-site-counts*))

;; first on pre-command-hook: the trace must be running before the
;; command, and everything after this point is the command's own cost
(define (profile--pre!)
  (when *profile-armed*
    (set! *profile-armed* #f)
    (set! *profile-open* (list 'buffer (current-buffer)))
    (profile--sites-on!)
    (profile-start!)))

;; last on post-command-hook
(define (profile--post!)
  (when *profile-open*
    (let ((open *profile-open*)
          (cmd (profile--command)))
      (set! *profile-open* #f)
      (if (profile--ignored? cmd)
          (begin (profile--sites-off!) (profile-cancel!) (set! *profile-armed* #t))
          (let ((data (profile-stop))
                (sites (begin (profile--sites-off!) (profile--sites-report))))
            (when data
              (profile--show!
                (append (list 'command cmd 'buffer (plist-get open 'buffer)
                              'sites sites)
                        data))))))))

(add-hook! 'pre-command-hook 'profile--pre!)
(add-hook! 'post-command-hook 'profile--post! #t)

;;; --- numbers ----------------------------------------------------------------

(define (profile--take xs n)
  (if (or (null? xs) (<= n 0))
      '()
      (cons (car xs) (profile--take (cdr xs) (- n 1)))))

;; a value already counted in tenths, as "12.3"
(define (profile--tenths n)
  (string-append (number->string (quotient n 10)) "." (number->string (remainder n 10))))

;; microseconds as milliseconds, one decimal
(define (profile--ms us)
  (profile--tenths (quotient (+ us 50) 100)))

(define (profile--count n)
  (cond ((>= n 1000000) (string-append (profile--tenths (quotient (* n 10) 1000000)) " M"))
        ((>= n 1000) (string-append (profile--tenths (quotient (* n 10) 1000)) " k"))
        (else (number->string n))))

;; a delta: the sign is the point of it
(define (profile--bytes n)
  (let* ((down (< n 0))
         (a (if down (- 0 n) n))
         (s (cond ((>= a 1048576) (string-append (profile--tenths (quotient (* a 10) 1048576)) " MB"))
                  ((>= a 1024) (string-append (profile--tenths (quotient (* a 10) 1024)) " KB"))
                  (else (string-append (number->string a) " B")))))
    (string-append (if down "-" "+") s)))

(define (profile--share part whole)
  (if (<= whole 0) 0 (min 100 (quotient (* part 100) whole))))

(define *profile-bar-width* 8)

(define (profile--bar share)
  (let ((n (min *profile-bar-width*
                (quotient (+ (* share *profile-bar-width*) 99) 100))))
    (string-append (string-repeat "█" n)
                   (string-repeat "·" (- *profile-bar-width* n)))))

;;; --- the rows ---------------------------------------------------------------
;;; One table, four sections. Each section says its own unit in its
;;; heading, because own milliseconds, reductions and bytes do not share
;;; a column.

(define (profile--sep label) (list 'kind "sep" 'what label))

(define (profile--report buf) (buffer-local buf 'profile-report))

(define (profile--function-rows r)
  (let ((total (plist-get r 'calls))
        (fns (profile--take (plist-get r 'functions) profile-function-rows)))
    (if (null? fns)
        '()
        (cons (profile--sep
                (string-append "what ran · calls, "
                               (number->string (plist-get r 'functions-seen))
                               " functions of the editor's own code"))
              (map (lambda (f)
                     (list 'kind "fn"
                           'what (string-append (plist-get f 'module) "." (plist-get f 'function))
                           'count (plist-get f 'calls)
                           'value ""
                           'share (profile--share (plist-get f 'calls) total)))
                   fns)))))

;; A builtin call counts itself against the lambda it was handed, so the
;; list work of a command reads as the Scheme that ran it. An Elixir
;; profile can only say `-all/0-fun-82-`; this says `fold (out bucket)`,
;; which names one call site in the source. ELEMENTS is what the builtin
;; walked, and it is the number that matters: a thousand folds over four
;; things is nothing, one fold over a thousand is the command.
(define (profile--site-rows r)
  ;; most elements walked first: sort pairs the count in front, because
  ;; sort orders lists by their own head
  (let* ((all (or (plist-get r 'sites) '()))
         (ranked (map (lambda (p) (nth 1 p))
                      (sort (map (lambda (s) (list (- 0 (plist-get s 'elements)) s)) all))))
         (sites (profile--take ranked profile-site-rows)))
    (if (null? sites)
        '()
        (let ((total (fold (lambda (n s) (+ n (plist-get s 'elements))) 0 sites)))
          (cons (profile--sep "what the lists walked · elements, by call site")
                (map (lambda (s)
                       (let ((site (plist-get s 'site)))
                         (list 'kind "site"
                               'what (string-append (plist-get s 'name)
                                                    (if (equal? site "") "" (string-append "  " site)))
                               'count (plist-get s 'elements)
                               'value (string-append (profile--count (plist-get s 'calls)) " calls")
                               'share (profile--share (plist-get s 'elements) total))))
                     sites))))))

(define (profile--process-rows r)
  (let ((total (plist-get r 'reductions))
        (ps (profile--take (plist-get r 'processes) profile-process-rows)))
    (if (null? ps)
        '()
        (cons (profile--sep "who did the work · reductions")
              (map (lambda (p)
                     (list 'kind "proc"
                           'what (string-append (plist-get p 'name) "  " (plist-get p 'pid))
                           'count (plist-get p 'reductions)
                           'value (profile--bytes (plist-get p 'memory))
                           'share (profile--share (plist-get p 'reductions) total)))
                   ps)))))

;; the live layer renders and the browser paints after the command
;; returns, so their rows reach the collector after the profile does. The
;; first draw shows what had landed; `g` reads the stream again.
(define (profile--layer-rows r)
  (let* ((at (plist-get r 'at-ms))
         (rows (filter (lambda (e) (>= (plist-get e 'time-ms) at)) (telemetry-events 200)))
         (rows (profile--take (reverse rows) profile-layer-rows)))
    (if (null? rows)
        '()
        (cons (profile--sep "the layers · ms, oldest first")
              (map (lambda (e)
                     (let ((detail (or (plist-get e 'detail) "")))
                       (list 'kind "layer"
                             'what (string-append (plist-get e 'layer) "  " (plist-get e 'label)
                                                  (if (equal? detail "") "" (string-append "  " detail)))
                             'value (number->string (plist-get e 'duration-ms)))))
                   rows)))))

(define (profile--vm-rows r)
  (list (profile--sep "what the vm paid")
        (list 'kind "vm" 'what "reductions" 'value (profile--count (plist-get r 'reductions)))
        (list 'kind "vm" 'what "garbage collections" 'value (number->string (plist-get r 'gcs)))
        (list 'kind "vm" 'what "words collected" 'value (profile--count (plist-get r 'gc-words)))
        (list 'kind "vm" 'what "memory" 'value (profile--bytes (plist-get r 'memory)))
        (list 'kind "vm" 'what "process memory" 'value (profile--bytes (plist-get r 'memory-processes)))
        (list 'kind "vm" 'what "binary memory" 'value (profile--bytes (plist-get r 'memory-binary)))
        (list 'kind "vm" 'what "modules traced" 'value (number->string (plist-get r 'modules)))))

(define (profile--rows buf)
  (let ((r (profile--report buf)))
    (if (not r)
        '()
        (append (profile--site-rows r)
                (profile--function-rows r)
                (profile--process-rows r)
                (profile--layer-rows r)
                (profile--vm-rows r)))))

;;; --- the look ---------------------------------------------------------------

(define (profile--separator? buf e) (equal? (plist-get e 'kind) "sep"))

(define (profile--columns buf)
  (list (list "what" #f)
        (list "count" 11 'right)
        (list "value" 10 'right)
        (list "share" *profile-bar-width*)))

(define (profile--cells buf e)
  (let ((kind (plist-get e 'kind))
        (what (plist-get e 'what)))
    (cond
      ((equal? kind "sep")
       (list (list (string-append "── " what " ") "accent") "" "" ""))
      ((equal? kind "fn")
       (list what
             (list (profile--count (plist-get e 'count)) "dim")
             (plist-get e 'value)
             (list (profile--bar (plist-get e 'share)) "faint")))
      ((equal? kind "site")
       (list what
             (list (profile--count (plist-get e 'count)) "dim")
             (list (plist-get e 'value) "faint")
             (list (profile--bar (plist-get e 'share)) "faint")))
      ((equal? kind "proc")
       (list what
             (list (profile--count (plist-get e 'count)) "dim")
             (list (plist-get e 'value) "faint")
             (list (profile--bar (plist-get e 'share)) "faint")))
      ((equal? kind "layer")
       (list (list what "faint") "" (plist-get e 'value) ""))
      (else
       (list what "" (plist-get e 'value) "")))))

(define (profile--meta buf)
  (let ((r (profile--report buf)))
    (if (not r)
        "nothing profiled yet · M-x profile arms the next command"
        (string-append (plist-get r 'command)
                       " in " (plist-get r 'buffer)
                       " · " (profile--ms (plist-get r 'wall-us)) " ms"
                       " · " (profile--count (plist-get r 'calls)) " calls"
                       " · " (profile--count (plist-get r 'reductions)) " reductions"
                       " · " (profile--bytes (plist-get r 'memory))))))

(mode-icon! "profile-mode" "")

(define-list-mode! "profile-mode"
  (list
    'doc (string-append
           "One command, measured. The first section is what ran: one row "
           "per function of the editor's own code that was called, how "
           "many times, and its share of every call in the window. The "
           "counters are VM-wide, so work the editor did beside the "
           "command is in them too. The second section is which BEAM "
           "processes did the work, in reductions, with the memory each "
           "one gained; that one is per process and says who. The third "
           "is the telemetry the same command left in the scheme, live "
           "and browser layers, oldest first. The last is what the VM "
           "paid. g reads the layers again once the browser has "
           "reported, / narrows, p arms the next command, q quits.")
    'buffer *profile-buffer*
    'rows profile--rows
    'columns profile--columns
    'cells profile--cells
    'key (lambda (buf e) (plist-get e 'what))
    'title (lambda (buf) "Profile")
    'meta profile--meta
    'separator? profile--separator?
    'section? profile--separator?
    'no-marks #t
    'local-filter #t
    'footer (lambda (buf)
              '(("g" "refresh") ("p" "profile again") ("/" "filter") ("q" "quit")))
    'keys '(("g" "list-revert")
            ("p" "profile")
            ("q" "quit-window"))))

;; a report is one command's measurement: it means nothing after a
;; restart, so the desktop never carries it. Registered after
;; define-list-mode!, so this setup wins and still runs the list init.
(define-mode "profile-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (desktop-skip! buf 'profile-report)
      (list-mode-init! buf "profile-mode"))))

;;; --- the commands -----------------------------------------------------------

(effects! '(read write display))

(define (profile--show! report)
  (unless (buffer-exists? *profile-buffer*) (buffer-create *profile-buffer*))
  (buffer-set-local! *profile-buffer* 'profile-report report)
  (list-mode-show! "profile-mode"))

(define-command "profile" "Profile the next command and show where its time went"
  (lambda ()
    (set! *profile-armed* #t)
    (message "Profile: run one command.")))

(define-command "profile-cancel" "Disarm the profiler and drop any running trace"
  (lambda ()
    (set! *profile-armed* #f)
    (set! *profile-open* #f)
    (profile-cancel!)
    (message "Profile off.")))

(effects! '(read))

(public! 'profile-armed?
  "(profile-armed?) — #t while the profiler waits for a command")

(define (profile-armed?) (and *profile-armed* #t))
