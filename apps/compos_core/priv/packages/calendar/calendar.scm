;; Calendar: settings and verbs. The agent touches EventKit; this file owns policy.
;; Tangled from README.md.

(domain! 'calendar)
(effects! '(read))

(defcustom 'calendar-file "~/docs/calendar.md"
  "The text store. This file is the truth compos reads and renders.")

(defcustom 'calendar-spool "~/.compos/calendar"
  "Where the daemon and the Aqua agent leave files for each other.")

(defcustom 'calendar-agent-label "io.svs.compos-calendar"
  "The LaunchAgent label. Loaded into gui/UID, never into the daemon.")

(defcustom 'calendar-config-file "~/.compos/calendar.scm"
  "The file that declares the sources. Plain Scheme, loaded on demand.")

(defcustom 'calendar-apple-db
  "~/Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb"
  "Fallback read when no agent is installed. Recurrence is not expanded here.")

(defcustom 'calendar-window-back 365
  "Days before today that the text file keeps.")

(defcustom 'calendar-window-forward 730
  "Days after today that the text file keeps.")

(defcustom 'calendar-week-start 1
  "The first column of the week grid. 0 is Sunday and 1 is Monday.")

(defcustom 'calendar-agent-timeout 20
  "Seconds to wait for the Aqua agent to answer one request.")

(defcustom 'calendar-agent-directory
  "/Users/svs/src/compos/apps/compos_core/priv/packages/calendar/agent"
  "Where the agent's plist and payloads live.")

;; A plist reader that answers #f for a missing key instead of throwing.

(define (calendar--prop plist key)
  (cond ((null? plist) #f)
        ((null? (cdr plist)) #f)
        ((equal? (car plist) key) (car (cdr plist)))
        (else (calendar--prop (cdr (cdr plist)) key))))

;; Providers. macos is one of these, not the design.

(define *calendar-providers* '())

(define (calendar-provider-define! name &rest props)
  (set! *calendar-providers*
        (cons (cons name props)
              (remove (lambda (p) (equal? (car p) name)) *calendar-providers*)))
  name)

(define (calendar-provider name)
  (let ((hit (assoc name *calendar-providers*)))
    (and hit (cdr hit))))

(define (calendar-providers) (map car *calendar-providers*))

(define (calendar-provider-can? name what)
  (let ((props (calendar-provider name)))
    (and props (member what (calendar--prop props 'capabilities)) #t)))

;; Sources come from the config file, and from nowhere else.

(define *calendar-sources* '())
(define *calendar-config-loading* #f)

(define (calendar-source! id &rest plist)
  (if (not *calendar-config-loading*)
      (error "calendar-source! belongs in the calendar config file")
      (begin (set! *calendar-sources* (cons (cons id plist) *calendar-sources*))
             id)))

(define (calendar-sources) (reverse *calendar-sources*))

(define (calendar-source id)
  (let ((hit (assoc id *calendar-sources*)))
    (and hit (cdr hit))))

(define (calendar-source-provider id)
  (calendar--prop (calendar-source id) 'provider))

(define (calendar--expand path)
  (if (string-prefix? "~/" path)
      (string-append (getenv "HOME") (substring path 1 (string-length path)))
      path))

(define (calendar-config-path) (calendar--expand calendar-config-file))

(define (calendar-config-load!)
  (let ((path (calendar-config-path)))
    (set! *calendar-sources* '())
    (if (not (file-exists? path))
        '()
        (begin
          (set! *calendar-config-loading* #t)
          (let ((result (eval-string-safe (read-file path))))
            (set! *calendar-config-loading* #f)
            (if (equal? (car result) 'ok)
                (calendar-sources)
                (begin (message (string-append "calendar.scm: "
                                               (value->string (car (cdr result)))))
                       #f)))))))

;; The macOS providers. The probes settled their capabilities; the functions
;; arrive with P2. macos is one provider among several, not the design.

(calendar-provider-define! 'macos
  'calendars    (lambda (src) (calendar--macos-calendars src))
  'events       (lambda (src from to) (calendar--macos-events src from to))
  'put!         (lambda (src event) (calendar--macos-put! src event))
  'delete!      (lambda (src id expect) (calendar--macos-remove! src id expect))
  'capabilities '(read write expanded)
  'reaches      "every account Calendar.app holds"
  'needs        "the Aqua LaunchAgent")

(calendar-provider-define! 'macos-db
  'capabilities '(read)
  'reaches      "the same accounts, read straight from Calendar.sqlitedb"
  'needs        "nothing")

;; The spool. The daemon writes a request and reads a result; it never calls
;; EventKit, because a Background process is never granted.

(define *calendar-request-n* 0)

(define (calendar--spool) (calendar--expand calendar-spool))

(define (calendar--request! json)
  (set! *calendar-request-n* (+ 1 *calendar-request-n*))
  (let* ((spool (calendar--spool))
         (id (string-append "req" (number->string *calendar-request-n*)))
         (req (string-append spool "/outbox/" id ".json"))
         (res (string-append spool "/results/" id ".json"))
         (err (string-append spool "/results/" id ".err"))
         (cmd (string-append
               "mkdir -p " (sh-quote (string-append spool "/outbox")) " "
                            (sh-quote (string-append spool "/results"))
               "; rm -f " (sh-quote res) " " (sh-quote err)
               "; printf %s " (sh-quote json) " > " (sh-quote req)
               "; for i in $(seq 1 " (number->string calendar-agent-timeout) "); do"
               " [ -f " (sh-quote res) " ] && break; sleep 1; done"
               "; cat " (sh-quote res) " 2>/dev/null"))
         (out (shell-command->string cmd (getenv "HOME"))))
    (cond ((equal? out "")
           (message "calendar: no answer from the agent; try (calendar-agent-install!)")
           #f)
          (else
           (let ((val (json-parse out)))
             (cond ((not val) (message "calendar: unreadable agent reply") #f)
                   ((calendar--prop val 'ok) val)
                   (else (message (string-append "calendar: "
                                                 (value->string (calendar--prop val 'error))))
                         #f)))))))

(define (calendar--json-ids ids)
  (string-append "[" (string-join (map (lambda (s) (string-append "\"" s "\"")) ids) ",") "]"))

;; The macos provider's own functions. Nothing calls these directly; the
;; verbs below reach them through the provider a source names.

(define (calendar--macos-calendars src)
  (let ((r (calendar--request! "{\"op\":\"calendars\"}")))
    (if r (calendar--prop r 'calendars) '())))

(define (calendar--source-wants? plist row)
  (let ((title (calendar--prop row 'title))
        (inc (calendar--prop plist 'include))
        (exc (calendar--prop plist 'exclude)))
    (and (or (not inc) (member title inc) #f)
         (not (and exc (member title exc) #t)))))

(define (calendar--wanted? row sources)
  (cond ((null? sources) #f)
        ((calendar--source-wants? (cdr (car sources)) row) #t)
        (else (calendar--wanted? row (cdr sources)))))

(define (calendar--source-calendars src)
  (filter (lambda (row) (calendar--source-wants? (calendar-source src) row))
          (calendar--macos-calendars src)))

(define (calendar--macos-events src from to)
  (let* ((cals (calendar--source-calendars src))
         (ids (map (lambda (r) (calendar--prop r 'id)) cals))
         (json (string-append "{\"op\":\"events\",\"from\":\"" from
                              "\",\"to\":\"" to "\",\"calendars\":"
                              (calendar--json-ids ids) "}"))
         (r (calendar--request! json)))
    (if r (calendar--prop r 'events) '())))

;; The verbs. Each one walks the configured sources and dispatches to whichever
;; provider that source names, so nothing above this line knows about macOS.

(define (calendar--provider-fn source-id key)
  (let ((p (calendar-source-provider source-id)))
    (and p (calendar--prop (calendar-provider p) key))))

(define (calendar--gather sources f)
  (if (null? sources)
      '()
      (append (f (car sources)) (calendar--gather (cdr sources) f))))

(define (calendar--before? a b)
  (< (calendar--prop a 'starts_at) (calendar--prop b 'starts_at)))

(define (calendar--sort-events rows)
  (if (null? rows)
      '()
      (let ((pivot (car rows)) (rest (cdr rows)))
        (append (calendar--sort-events (filter (lambda (r) (calendar--before? r pivot)) rest))
                (list pivot)
                (calendar--sort-events (filter (lambda (r) (not (calendar--before? r pivot))) rest))))))

(define (calendar-calendars)
  (calendar--gather
   (calendar-sources)
   (lambda (s)
     (let ((fn (calendar--provider-fn (car s) 'calendars)))
       (if fn
           (filter (lambda (row) (calendar--source-wants? (cdr s) row)) (fn (car s)))
           '())))))

(define (calendar-events from to)
  (let ((rows (calendar--gather
               (calendar-sources)
               (lambda (s)
                 (let ((fn (calendar--provider-fn (car s) 'events)))
                   (if fn (fn (car s) from to) '()))))))
    (calendar--sort-events rows)))

;; The agent itself.

(define (calendar--agent-plist)
  (string-append calendar-agent-directory "/" calendar-agent-label ".plist"))

(define (calendar-agent-install!)
  (shell-command->string
   (string-append "mkdir -p " (sh-quote (string-append (calendar--spool) "/outbox")) " "
                  (sh-quote (string-append (calendar--spool) "/results"))
                  "; launchctl bootout gui/$(id -u)/" calendar-agent-label " 2>/dev/null"
                  "; launchctl bootstrap gui/$(id -u) " (sh-quote (calendar--agent-plist)) " 2>&1")
   (getenv "HOME"))
  (calendar-agent-status))

(define (calendar-agent-uninstall!)
  (shell-command->string
   (string-append "launchctl bootout gui/$(id -u)/" calendar-agent-label " 2>&1")
   (getenv "HOME"))
  (calendar-agent-status))

(define (calendar-agent-status)
  (let* ((spool (calendar--spool))
         (out (shell-command->string
               (string-append
                "launchctl print gui/$(id -u)/" calendar-agent-label
                " >/dev/null 2>&1 && echo loaded || echo absent"
                "; cat " (sh-quote (string-append spool "/last-drain")) " 2>/dev/null || echo never"
                "; ls " (sh-quote (string-append spool "/outbox")) " 2>/dev/null | wc -l | tr -d ' '")
               (getenv "HOME")))
         (lines (string-split (string-trim out) "\n")))
    (list 'agent (car lines)
          'last-drain (if (> (length lines) 2) (car (cdr lines)) "never")
          'pending (car (reverse lines))
          'session (string-trim (shell-command->string "launchctl managername" (getenv "HOME")))
          'plist (calendar--agent-plist))))

;; The text store. The file is generated, and the sync refuses to write over
;; anything it did not write itself.

(define *calendar-file-header*
  "<!-- compos calendar: generated by (calendar-sync!). Edits here are replaced. -->")

(define (calendar--file) (calendar--expand calendar-file))

(define (calendar-file-ours?)
  (let ((path (calendar--file)))
    (or (not (file-exists? path))
        (string-prefix? *calendar-file-header* (read-file path)))))

(define (calendar--today)
  (string-trim (shell-command->string "date +%F" (getenv "HOME"))))

(define (calendar--date-plus days)
  (string-trim (shell-command->string
                (string-append "date -v+" (number->string days) "d +%F")
                (getenv "HOME"))))

(define (calendar--event-line e)
  (let ((all-day (calendar--prop e 'all_day))
        (starts (calendar--prop e 'starts))
        (ends (calendar--prop e 'ends))
        (summary (calendar--prop e 'summary))
        (cal (calendar--prop e 'calendar))
        (loc (calendar--prop e 'location)))
    (string-append "- " (if all-day "all day" (string-append starts "-" ends))
                   "  " (if summary summary "(no title)")
                   "  `" (if cal cal "?") "`"
                   (if loc (string-append "\n  " loc) "")
                   "\n")))

(define (calendar--body events day out)
  (if (null? events)
      (apply string-append (reverse out))
      (let* ((e (car events))
             (d (calendar--prop e 'day))
             (head (if (equal? d day)
                       ""
                       (string-append "\n## " d " "
                                      (let ((w (calendar--prop e 'weekday))) (if w w ""))
                                      "\n\n"))))
        (calendar--body (cdr events) d
                        (cons (string-append head (calendar--event-line e)) out)))))

(define (calendar-render from to events)
  (string-append *calendar-file-header* "\n\n# Calendar\n\n"
                 from " to " to ", " (number->string (length events)) " events.\n"
                 (calendar--body events #f '())))

(define (calendar-sync! &rest range)
  (let* ((from (if (null? range) (calendar--today) (car range)))
         (to (if (or (null? range) (null? (cdr range)))
                 (calendar--date-plus 30)
                 (car (cdr range))))
         (path (calendar--file)))
    (if (not (calendar-file-ours?))
        (begin (message (string-append "calendar: " path
                                       " was not written by compos; refusing to replace it"))
               #f)
        (let ((events (calendar-events from to)))
          (if (not events)
              #f
              (let ((text (calendar-render from to events)))
                (find-file path)
                (buffer-delete-range! path 0 (string-length (buffer-text path)))
                (buffer-append! path text)
                (with-current-buffer path (lambda () (buffer-save!)))
                (list 'file path 'from from 'to to 'events (length events))))))))

;; Writing. One event at a time, named explicitly, never from a sync path.

(define (calendar--json-escape s)
  (let loop ((i 0) (out ""))
    (if (>= i (string-length s))
        out
        (let ((c (substring s i (+ i 1))))
          (loop (+ i 1)
                (string-append out
                               (cond ((equal? c "\"") "\\\"")
                                     ((equal? c "\\") "\\\\")
                                     ((equal? c "\n") "\\n")
                                     ((equal? c "\t") "\\t")
                                     (else c))))))))

(define (calendar--json-str s)
  (string-append "\"" (calendar--json-escape s) "\""))

(define (calendar--json-pair key value)
  (string-append (calendar--json-str key) ":"
                 (cond ((equal? value #t) "true")
                       ((equal? value #f) "false")
                       (else (calendar--json-str value)))))

(define (calendar--json-object pairs)
  (string-append "{" (string-join pairs ",") "}"))

(define (calendar--macos-put! src event)
  (let* ((title (calendar--prop event 'title))
         (start (calendar--prop event 'start))
         (end (calendar--prop event 'end))
         (cal (calendar--prop event 'calendar))
         (notes (calendar--prop event 'notes))
         (loc (calendar--prop event 'location))
         (all-day (calendar--prop event 'all-day))
         (pairs (append (list (calendar--json-pair "op" "create")
                              (calendar--json-pair "title" title)
                              (calendar--json-pair "start" start)
                              (calendar--json-pair "end" end))
                        (if cal (list (calendar--json-pair "calendar" cal)) '())
                        (if notes (list (calendar--json-pair "notes" notes)) '())
                        (if loc (list (calendar--json-pair "location" loc)) '())
                        (if all-day (list (calendar--json-pair "all_day" #t)) '()))))
    (calendar--request! (calendar--json-object pairs))))

(define (calendar--macos-remove! src event-id expect)
  (calendar--request!
   (calendar--json-object (list (calendar--json-pair "op" "remove")
                                (calendar--json-pair "event_id" event-id)
                                (calendar--json-pair "expect" expect)))))

(define (calendar--writing-source)
  (let ((writers (filter (lambda (s) (calendar--prop (cdr s) 'writes)) (calendar-sources))))
    (cond ((null? writers)
           (message "calendar: no source in the config file says 'writes #t")
           #f)
          ((not (null? (cdr writers)))
           (message "calendar: more than one source writes; name one with 'source")
           #f)
          (else (car (car writers))))))

(define (calendar-add! &rest event)
  (let ((title (calendar--prop event 'title))
        (start (calendar--prop event 'start))
        (end (calendar--prop event 'end))
        (src (let ((named (calendar--prop event 'source)))
               (if named named (calendar--writing-source)))))
    (cond ((not (and title start end))
           (message "calendar-add!: needs 'title, 'start and 'end")
           #f)
          ((not src) #f)
          ((not (calendar-provider-can? (calendar-source-provider src) 'write))
           (message "calendar: that source's provider cannot write")
           #f)
          (else
           (let ((fn (calendar--provider-fn src 'put!)))
             (if (not fn)
                 (begin (message "calendar: that provider has no put!") #f)
                 (fn src event)))))))

(define (calendar-remove! event-id expect)
  (let ((src (calendar--writing-source)))
    (if (not src)
        #f
        (let ((fn (calendar--provider-fn src 'delete!)))
          (if (not fn)
              (begin (message "calendar: that provider has no delete!") #f)
              (fn src event-id expect))))))

;; The M-x surface. Everything above is callable from Scheme; this is what a
;; person reaches for.

(domain! 'calendar)
(effects! '(write display))

(define (calendar--plus-minutes stamp minutes)
  (string-trim
   (shell-command->string
    (string-append "date -j -v+" (number->string minutes) "M -f '%Y-%m-%d %H:%M' "
                   (sh-quote stamp) " '+%Y-%m-%d %H:%M'")
    (getenv "HOME"))))

(define (calendar--minutes text)
  (let ((n (if (or (not text) (equal? text "")) 60 (string->number text))))
    (if (number? n) n 60)))

(define (calendar--writable-titles)
  (map (lambda (row) (calendar--prop row 'title))
       (filter (lambda (row) (calendar--prop row 'writable)) (calendar-calendars))))

(define (calendar--sync-and-report)
  (let ((done (calendar-sync!)))
    (if done
        (message (string-append "calendar: "
                                (number->string (calendar--prop done 'events))
                                " events to " (calendar--prop done 'to)))
        #f)
    done))

(define-command "calendar" "Show the calendar, refreshed, in the other window"
  (lambda ()
    (calendar--sync-and-report)
    (display-buffer-other-window! (calendar--file))))

(define-command "calendar-sync" "Refresh the calendar file from every configured source"
  (lambda () (calendar--sync-and-report)))

(define-command "calendar-add-event" "Add one event to a calendar"
  (lambda ()
    (read-string "Title: "
      (lambda (title)
        (if (or (not title) (equal? title ""))
            (message "calendar: cancelled")
            (read-string "Start (YYYY-MM-DD HH:MM): "
              (lambda (start)
                (if (or (not start) (equal? start ""))
                    (message "calendar: cancelled")
                    (read-string "Minutes: "
                      (lambda (mins)
                        (completing-read "Calendar: " (calendar--writable-titles)
                          (lambda (cal)
                            (if (not cal)
                                (message "calendar: cancelled")
                                (let ((made (calendar-add!
                                             'title title
                                             'start start
                                             'end (calendar--plus-minutes
                                                   start (calendar--minutes mins))
                                             'calendar cal)))
                                  (if (not made)
                                      (message "calendar: the event was not created")
                                      (begin
                                        (calendar-sync!)
                                        (message (string-append
                                                  "calendar: added \"" title "\" to "
                                                  cal " at "
                                                  (calendar--prop made 'starts_at)))))))))
                        )
                      'initial "60")))
              'initial (string-append (calendar--today) " "))))))) 

(define-command "calendar-agent-status" "Report the calendar agent: loaded, last drain, pending"
  (lambda ()
    (let ((s (calendar-agent-status)))
      (message (string-append "calendar agent " (calendar--prop s 'agent)
                              ", last drain " (calendar--prop s 'last-drain)
                              ", " (calendar--prop s 'pending) " pending")))))

(define-command "calendar-agent-install" "Install and start the calendar agent in the GUI session"
  (lambda ()
    (let ((s (calendar-agent-install!)))
      (message (string-append "calendar agent " (calendar--prop s 'agent))))))

(define-command "calendar-reload-config" "Read ~/.compos/calendar.scm again"
  (lambda ()
    (let ((sources (calendar-config-load!)))
      (message (string-append "calendar: "
                              (number->string (length sources))
                              " sources from " (calendar-config-path))))))
