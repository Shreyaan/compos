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

;; first on pre-command-hook: the trace must be running before the
;; command, and everything after this point is the command's own cost
(define (profile--pre!)
  (when *profile-armed*
    (set! *profile-armed* #f)
    (set! *profile-open* (list 'buffer (current-buffer)))
    (profile-start!)))

;; last on post-command-hook
(define (profile--post!)
  (when *profile-open*
    (let ((open *profile-open*)
          (cmd (profile--command)))
      (set! *profile-open* #f)
      (if (profile--ignored? cmd)
          (begin (profile-cancel!) (set! *profile-armed* #t))
          (let ((data (profile-stop)))
            (when data
              (profile--show!
                (append (list 'command cmd 'buffer (plist-get open 'buffer)) data))))))))

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
        (append (profile--function-rows r)
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
