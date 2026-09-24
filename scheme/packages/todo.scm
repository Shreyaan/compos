;;; todo.scm --- the shared todo list every app and agent coordinates through.
;;;
;;; A task is a level-2 morg heading in a file under todo-directory. The
;;; file is the project: hiring.md holds the tasks of project "hiring".
;;; The heading keyword stays TODO or DONE, so morg-todo, morg-todos and
;;; the agenda read these files unchanged; the finer state is #+state.
;;;
;;;   ## TODO Nudge Anusha on the offer :opptra:client:
;;;   DEADLINE: <2026-09-26>
;;;   #+id: t-260924-154612-073
;;;   #+state: todo
;;;   #+assignee: agent:closer
;;;   #+priority: A
;;;   #+source: gmail:18c2f0a
;;;   #+created: 2026-09-24 15:46
;;;   #+by: agent:mail-trawler
;;;
;;;   Free notes.
;;;
;;;   #+log: 2026-09-24 15:46 agent:mail-trawler created
;;;
;;; States: inbox (found, not yet triaged by a human) · todo (triaged,
;;; free to take) · doing (claimed) · waiting (blocked on someone) ·
;;; review (needs a human OK, e.g. before anything goes out) · done ·
;;; cancelled.
;;;
;;; Every writer goes through todo-create and todo-update, so each change
;;; lands in the task's log under the name of whoever made it. An open
;;; file buffer is edited live, and saved only when it held no unsaved
;;; work of its own. A task without #+id is the writer's own note, and the
;;; API leaves it alone.
;;;
;;; OFFSET RULE: byte offsets only (string-byte-length, substring-bytes).

(domain! 'writing)
(effects! '(read))

(defcustom 'todo-directory "~/todo"
  "Where the shared todo files live. Each .md file is one project.")

(defcustom 'todo-user "svs"
  "The name a change is logged under when the caller names nobody.")

(defcustom 'todo-default-project "general"
  "The project of a task created without one.")

(define *todo-states* '("inbox" "todo" "doing" "waiting" "review" "done" "cancelled"))
(define *todo-closed* '("done" "cancelled"))
;; the #+ lines, in the order they are written
(define *todo-fields* '(id state assignee priority source parent depends created by))
;; what todo-update may change
(define *todo-settable*
  '(title state project assignee priority deadline scheduled tags source parent depends notes))

;;; --- small helpers -----------------------------------------------------------

(define (todo--dir) (expand-path todo-directory))
(define (todo--now) (format-time (current-time) "%Y-%m-%d %H:%M"))
(define (todo--today) (format-time (current-time) "%Y-%m-%d"))

(define (todo--sub s g i) (substring-bytes s (car (nth i g)) (cadr (nth i g))))
(define (todo--blank? s) (or (not s) (and (string? s) (equal? (string-trim s) ""))))
(define (todo--first pred xs) (let ((hit (filter pred xs))) (and (pair? hit) (car hit))))
(define (todo--words s)
  (filter (lambda (w) (not (equal? w ""))) (string-split (string-trim s) " ")))

(define (todo--fail &rest parts) (error (apply string-append (cons "todo: " parts))))

(define (todo-date s)
  "(todo-date S) — today, tomorrow, +3d, 2w or YYYY-MM-DD as YYYY-MM-DD; blank is #f"
  (let ((day (lambda (n) (format-time (time+ (current-time) n) "%Y-%m-%d"))))
    (cond ((todo--blank? s) #f)
          ((re-match "^[0-9]{4}-[0-9]{2}-[0-9]{2}$" s) s)
          ((equal? s "today") (day 0))
          ((equal? s "tomorrow") (day 1))
          (else
           (let ((g (re-groups "^[+]?([0-9]+)([dw])$" s 0)))
             (if g
                 (let ((n (string->number (todo--sub s g 1))))
                   (day (if (equal? (todo--sub s g 2) "w") (* 7 n) n)))
                 (todo--fail "not a date: " s)))))))

(define (todo--date-num d) (if d (string->number (string-join (string-split d "-") "")) 99999999))

(define (todo--slug s)
  (let ((w (todo--words (string-downcase s))))
    (if (null? w) (todo--fail "empty project name") (string-join w "-"))))

(define (todo--tags v)
  (cond ((not v) '())
        ((pair? v) v)
        ((null? v) '())
        (else (filter (lambda (x) (not (equal? x "")))
                      (string-split (string-join (string-split v " ") ":") ":")))))

(define (todo--ids v)
  (cond ((pair? v) v)
        ((todo--blank? v) '())
        (else (todo--words v))))

(define (todo--priority p)
  (cond ((todo--blank? p) #f)
        ((member (string-upcase p) '("A" "B" "C")) (string-upcase p))
        (else (todo--fail "priority is A, B or C, not " p))))

(define (todo--state s)
  (if (member s *todo-states*) s
      (todo--fail "state is one of " (string-join *todo-states* ", ") ", not " (if (string? s) s "?"))))

(define (todo--new-id)
  (string-append "t-" (format-time (current-time) "%y%m%d-%H%M%S")
                 "-" (number->string (+ 100 (random 900)))))

(define (todo--log-line who text) (string-append (todo--now) " " who " " text))

;;; --- files -------------------------------------------------------------------

(define (todo--files)
  (let ((dir (todo--dir)))
    (if (file-directory? dir)
        (map (lambda (n) (string-append dir "/" n))
             (filter (lambda (n) (and (string-suffix? ".md" n) (not (string-prefix? "." n))))
                     (list-dir dir)))
        '())))

(define (todo--project-file project) (string-append (todo--dir) "/" (todo--slug project) ".md"))

(define (todo--file-project path)
  (let ((n (file-name-nondirectory path)))
    (substring-bytes n 0 (- (string-byte-length n) 3))))

;; an open buffer may hold unsaved edits, so it reads live
(define (todo--text path)
  (if (buffer-exists? path)
      (buffer-text path)
      (let ((t (read-file path))) (if (string? t) t ""))))

;;; --- parse -------------------------------------------------------------------

;; "## TODO title :a:b:" -> (KW TITLE TAGS), else #f
(define (todo--heading line)
  (let ((g (re-groups "^##[ \t]+(TODO|DONE)[ \t]+(.*)$" line 0)))
    (and g
         (let* ((rest (todo--sub line g 2))
                (tg (re-groups "[ \t](:[A-Za-z0-9_@:-]+:)[ \t]*$" rest 0)))
           (list (todo--sub line g 1)
                 (string-trim (if tg (substring-bytes rest 0 (car (car tg))) rest))
                 (if tg (todo--tags (todo--sub rest tg 1)) '()))))))

;; a line that ends the task above it
(define (todo--boundary? line) (re-match "^[#][#]?[ \t]" line))

(define (todo--trim-head ls)
  (if (and (pair? ls) (todo--blank? (car ls))) (todo--trim-head (cdr ls)) ls))
(define (todo--trim-tail ls) (reverse (todo--trim-head (reverse ls))))

(define (todo--set-prop t k v)
  (cond ((equal? k "log") (plist-put t 'log (cons v (plist-get t 'log))))
        ((equal? k "depends") (plist-put t 'depends (todo--ids v)))
        ((member (string->symbol k) *todo-fields*)
         (plist-put t (string->symbol k) (if (equal? v "") #f v)))
        (else (plist-put t 'extra (cons (list k v) (plist-get t 'extra))))))

;; CUR is (FROM POS HEADING BODY-LINES); FROM counts lines from 0
(define (todo--task path cur)
  (let* ((head (caddr cur))
         (body (todo--trim-tail (nth 3 cur)))
         (base (list 'id #f 'kw (car head) 'title (cadr head) 'tags (caddr head)
                     'project (todo--file-project path) 'file path
                     'from (car cur) 'to (+ (car cur) 1 (length body)) 'pos (cadr cur)
                     'deadline #f 'scheduled #f 'depends '() 'log '() 'extra '())))
    (let loop ((ls body) (t base) (notes '()))
      (if (null? ls)
          (let* ((t (plist-put t 'notes (string-join (todo--trim-tail (todo--trim-head (reverse notes))) "\n")))
                 (t (plist-put t 'log (reverse (plist-get t 'log))))
                 (t (plist-put t 'extra (reverse (plist-get t 'extra)))))
            (if (plist-get t 'state) t
                (plist-put t 'state (if (equal? (car head) "DONE") "done" "inbox"))))
          (let* ((line (car ls))
                 (p (re-groups "^#[+]([A-Za-z0-9_-]+):[ \t]*(.*)$" line 0)))
            (cond
              ((re-match "^[ \t]*(SCHEDULED|DEADLINE):" line)
               (let* ((d (re-groups "DEADLINE:[ \t]*<([0-9-]+)" line 0))
                      (s (re-groups "SCHEDULED:[ \t]*<([0-9-]+)" line 0))
                      (t (if d (plist-put t 'deadline (todo--sub line d 1)) t))
                      (t (if s (plist-put t 'scheduled (todo--sub line s 1)) t)))
                 (loop (cdr ls) t notes)))
              (p (loop (cdr ls)
                       (todo--set-prop t (string-downcase (todo--sub line p 1))
                                       (string-trim (todo--sub line p 2)))
                       notes))
              (else (loop (cdr ls) t (cons line notes)))))))))

;; every task in TEXT, in file order; the walk is fence-aware
(define (todo--parse path text)
  (let loop ((ls (split-lines text)) (i 0) (pos 0) (fence #f) (cur #f) (acc '()))
    (let ((close (lambda () (if cur (cons (todo--task path cur) acc) acc)))
          (add (lambda (line) (and cur (list (car cur) (cadr cur) (caddr cur)
                                             (append (nth 3 cur) (list line)))))))
      (if (null? ls)
          (filter (lambda (t) (plist-get t 'id)) (reverse (close)))
          (let* ((line (car ls))
                 (next (+ pos (string-byte-length line) 1))
                 (step (lambda (fence cur acc) (loop (cdr ls) (+ i 1) next fence cur acc))))
            (cond
              ((and fence (morg-fence-close? line)) (step #f (add line) acc))
              (fence (step #t (add line) acc))
              ((morg-fence-info line) (step #t (add line) acc))
              ((todo--heading line) (step #f (list i pos (todo--heading line) '()) (close)))
              ((todo--boundary? line) (step #f #f (close)))
              (else (step #f (add line) acc))))))))

(define (todo--all)
  (fold (lambda (acc f) (append acc (todo--parse f (todo--text f)))) '() (todo--files)))

;;; --- render ------------------------------------------------------------------

(define (todo--render t)
  (let* ((tags (plist-get t 'tags))
         (notes (plist-get t 'notes))
         (logs (plist-get t 'log))
         (field (lambda (k)
                  (let ((v (plist-get t k)))
                    (cond ((null? v) '())
                          ((pair? v) (list (string-append "#+" (symbol->string k) ": " (string-join v " "))))
                          ((todo--blank? v) '())
                          (else (list (string-append "#+" (symbol->string k) ": " v))))))))
    (string-join
      (append
        (list (string-append "## " (if (member (plist-get t 'state) *todo-closed*) "DONE" "TODO")
                             " " (plist-get t 'title)
                             (if (pair? tags) (string-append " :" (string-join tags ":") ":") "")))
        (if (plist-get t 'deadline) (list (string-append "DEADLINE: <" (plist-get t 'deadline) ">")) '())
        (if (plist-get t 'scheduled) (list (string-append "SCHEDULED: <" (plist-get t 'scheduled) ">")) '())
        (fold (lambda (acc k) (append acc (field k))) '() *todo-fields*)
        (map (lambda (kv) (string-append "#+" (car kv) ": " (cadr kv))) (or (plist-get t 'extra) '()))
        (if (todo--blank? notes) '() (list "" notes))
        (if (pair? logs) (cons "" (map (lambda (l) (string-append "#+log: " l)) logs)) '()))
      "\n")))

;;; --- write -------------------------------------------------------------------

(effects! '(write))

(define (todo--save! path) (with-current-buffer path (lambda () (buffer-save!))))

;; replace task T's lines with NEW, or delete them (and one blank after)
;; when NEW is #f
(define (todo--write-span! t new)
  (let* ((path (plist-get t 'file))
         (ls (split-lines (todo--text path)))
         (from (plist-get t 'from))
         (to0 (plist-get t 'to))
         (to (if (and (not new) (< to0 (length ls)) (todo--blank? (nth to0 ls))) (+ to0 1) to0)))
    (if (buffer-exists? path)
        (let* ((old (string-join (list-head (list-tail ls from) (- to from)) "\n"))
               (dirty (buffer-modified? path))
               (r (if new
                      (buffer-replace! path old new)
                      (buffer-replace! path (string-append old "\n") ""))))
          (unless (equal? r "edited") (todo--fail r))
          (unless dirty (todo--save! path)))
        (write-file! path (string-join (append (list-head ls from)
                                               (if new (list new) '())
                                               (list-tail ls to))
                                       "\n")))))

(define (todo--append! path text)
  (let ((sep (lambda (cur) (cond ((equal? cur "") "")
                                 ((string-suffix? "\n" cur) "\n")
                                 (else "\n\n")))))
    (cond ((buffer-exists? path)
           (let ((dirty (buffer-modified? path)))
             (buffer-append! path (string-append (sep (buffer-text path)) text "\n"))
             (unless dirty (todo--save! path))))
          ((file-exists? path)
           (let ((cur (todo--text path)))
             (write-file! path (string-append cur (sep cur) text "\n"))))
          (else
           (unless (file-directory? (todo--dir)) (make-directory! (todo--dir)))
           (write-file! path (string-append "# " (todo--file-project path) "\n\n" text "\n"))))))

;;; --- the API: reading ------------------------------------------------------

(effects! '(read))

(define (todo-get id)
  "(todo-get ID) — the task as a plist, or #f"
  (todo--first (lambda (t) (equal? (plist-get t 'id) id)) (todo--all)))

(define (todo--must id) (or (todo-get id) (todo--fail "no task " (if (string? id) id "?"))))

(define (todo--overdue? t)
  (and (not (member (plist-get t 'state) *todo-closed*))
       (plist-get t 'deadline)
       (< (todo--date-num (plist-get t 'deadline)) (todo--date-num (todo--today)))))

;; every dependency is closed
(define (todo--ready? t all)
  (fold (lambda (ok dep)
          (and ok (let ((d (todo--first (lambda (x) (equal? (plist-get x 'id) dep)) all)))
                    (or (not d) (and (member (plist-get d 'state) *todo-closed*) #t)))))
        #t (plist-get t 'depends)))

(define (todo--match? t spec all)
  (let ((get (lambda (k) (plist-get spec k)))
        (state (plist-get t 'state)))
    (and (cond ((get 'state) (member state (if (pair? (get 'state)) (get 'state) (list (get 'state)))))
               ((get 'all) #t)
               (else (not (member state *todo-closed*))))
         (or (not (get 'project)) (equal? (plist-get t 'project) (todo--slug (get 'project))))
         (or (not (get 'assignee))
             (if (equal? (get 'assignee) "none")
                 (not (plist-get t 'assignee))
                 (equal? (plist-get t 'assignee) (get 'assignee))))
         (or (not (get 'tag)) (member (get 'tag) (plist-get t 'tags)))
         (or (not (get 'text))
             (string-contains? (string-downcase (string-append (plist-get t 'title) " " (plist-get t 'notes)))
                               (string-downcase (get 'text))))
         (or (not (get 'due-before))
             (and (plist-get t 'deadline)
                  (<= (todo--date-num (plist-get t 'deadline)) (todo--date-num (todo-date (get 'due-before))))))
         (or (not (get 'overdue)) (todo--overdue? t))
         (or (not (get 'ready)) (and (equal? state "todo") (todo--ready? t all)))
         (or (not (get 'parent)) (equal? (plist-get t 'parent) (get 'parent)))
         (or (not (get 'source))
             (and (plist-get t 'source) (string-prefix? (get 'source) (plist-get t 'source))))
         #t)))

(define (todo--rank x xs)
  (let loop ((xs xs) (i 0))
    (cond ((null? xs) i) ((equal? (car xs) x) i) (else (loop (cdr xs) (+ i 1))))))

;; review first (it waits on a human), then doing, todo, inbox, waiting;
;; within a state by priority, deadline, age
(define (todo--sort ts)
  (map cadr
       (sort (map (lambda (t)
                    (list (list (todo--rank (plist-get t 'state) '("review" "doing" "todo" "inbox" "waiting" "done" "cancelled"))
                                (todo--rank (or (plist-get t 'priority) "B") '("A" "B" "C"))
                                (todo--date-num (plist-get t 'deadline))
                                (or (plist-get t 'created) ""))
                          t))
                  ts))))

(define (todo-list &optional spec)
  "(todo-list [SPEC]) — tasks, most urgent first. SPEC keys: state (one or a list), all, project, assignee (none = unassigned), tag, text, due-before, overdue, ready, parent, source (a prefix). Without state or all, only open tasks."
  (let ((all (todo--all)) (spec (or spec '())))
    (todo--sort (filter (lambda (t) (todo--match? t spec all)) all))))

(define (todo-next who &optional spec)
  "(todo-next WHO [SPEC]) — the most urgent ready task for WHO: assigned to WHO first, else unassigned; #f when none"
  (let* ((spec (or spec '()))
         (mine (todo-list (append spec (list 'ready #t 'assignee who))))
         (free (todo-list (append spec (list 'ready #t 'assignee "none")))))
    (cond ((pair? mine) (car mine)) ((pair? free) (car free)) (else #f))))

(define (todo-projects)
  "(todo-projects) — every project name"
  (map todo--file-project (todo--files)))

;;; --- the API: writing --------------------------------------------------------
;;; PROPS is a plist. Every writer may pass 'by, the name the change is
;;; logged under; an agent passes its own, e.g. agent:mail-trawler.

(effects! '(write))

(define (todo-create title &optional props)
  "(todo-create TITLE [PROPS]) — file a task; return its id. PROPS: project, state (default inbox), assignee, priority, deadline, scheduled, tags, source, parent, depends, notes, by. A source already filed is not filed twice: that task's id comes back."
  (let* ((props (or props '()))
         (src (plist-get props 'source))
         (dup (and (not (todo--blank? src))
                   (todo--first (lambda (t) (equal? (plist-get t 'source) src)) (todo--all)))))
    (if dup
        (plist-get dup 'id)
        (let* ((who (or (plist-get props 'by) todo-user))
               (id (todo--new-id))
               (t (list 'id id
                        'title (string-join (todo--words (string-join (split-lines title) " ")) " ")
                        'state (todo--state (or (plist-get props 'state) "inbox"))
                        'tags (todo--tags (plist-get props 'tags))
                        'assignee (if (todo--blank? (plist-get props 'assignee)) #f (plist-get props 'assignee))
                        'priority (todo--priority (plist-get props 'priority))
                        'deadline (todo-date (plist-get props 'deadline))
                        'scheduled (todo-date (plist-get props 'scheduled))
                        'source (if (todo--blank? src) #f src)
                        'parent (plist-get props 'parent)
                        'depends (todo--ids (plist-get props 'depends))
                        'created (todo--now)
                        'by who
                        'notes (or (plist-get props 'notes) "")
                        'extra '()
                        'log (list (todo--log-line who "created")))))
          (when (todo--blank? (plist-get t 'title)) (todo--fail "a task needs a title"))
          (todo--append! (todo--project-file (or (plist-get props 'project) todo-default-project))
                         (todo--render t))
          id))))

(define (todo--norm k v)
  (cond ((equal? k 'state) (todo--state v))
        ((equal? k 'project) (todo--slug v))
        ((member k '(deadline scheduled)) (todo-date v))
        ((equal? k 'tags) (todo--tags v))
        ((equal? k 'depends) (todo--ids v))
        ((equal? k 'priority) (todo--priority v))
        ((equal? k 'notes) (or v ""))
        ((equal? k 'title) (if (todo--blank? v) (todo--fail "a task needs a title") (string-trim v)))
        ((todo--blank? v) #f)
        (else v)))

(define (todo--show v)
  (cond ((not v) "-") ((null? v) "-") ((pair? v) (string-join v " ")) (else v)))

(define (todo--change k old new)
  (cond ((equal? k 'notes) "notes edited")
        ((equal? k 'state) (string-append "state " (todo--show old) " -> " (todo--show new)))
        (else (string-append (symbol->string k) " " (todo--show new)))))

(define (todo-update id props)
  "(todo-update ID PROPS) — change a task; return it. PROPS: any of title, state, project, assignee, priority, deadline, scheduled, tags, source, parent, depends, notes (#f or blank clears one), plus note (text added to the notes), log (a line for the log) and by (who). Each change is logged."
  (let* ((t (todo--must id))
         (who (or (plist-get props 'by) todo-user)))
    (let loop ((ps props) (new t) (changes '()))
      (if (pair? ps)
          (let ((k (car ps)) (v (cadr ps)))
            (cond
              ((member k '(by log)) (loop (cddr ps) new changes))
              ((equal? k 'note)
               (if (todo--blank? v)
                   (loop (cddr ps) new changes)
                   (loop (cddr ps)
                         (plist-put new 'notes (if (todo--blank? (plist-get new 'notes)) v
                                                   (string-append (plist-get new 'notes) "\n\n" v)))
                         (cons "note added" changes))))
              ((not (member k *todo-settable*))
               (todo--fail "cannot set " (symbol->string k)))
              (else
               (let ((v (todo--norm k v)))
                 (if (equal? v (plist-get new k))
                     (loop (cddr ps) new changes)
                     (loop (cddr ps) (plist-put new k v) (cons (todo--change k (plist-get new k) v) changes)))))))
          (let* ((text (plist-get props 'log))
                 (lines (map (lambda (c) (todo--log-line who c))
                             (append (reverse changes) (if (todo--blank? text) '() (list text))))))
            (if (null? lines)
                t
                (let ((new (plist-put new 'log (append (plist-get new 'log) lines))))
                  (if (equal? (plist-get new 'project) (plist-get t 'project))
                      (todo--write-span! t (todo--render new))
                      (begin (todo--write-span! t #f)
                             (todo--append! (todo--project-file (plist-get new 'project)) (todo--render new))))
                  (todo-get id))))))))

(define (todo-log id text &optional who)
  "(todo-log ID TEXT [WHO]) — add a line to the task's log"
  (todo-update id (list 'log text 'by (or who todo-user))))

(define (todo-triage id &optional props)
  "(todo-triage ID [PROPS]) — accept an inbox task: state todo, plus any PROPS"
  (todo-update id (append (or props '()) (list 'state "todo"))))

(define (todo-claim id who)
  "(todo-claim ID WHO) — take a ready todo task for WHO: state doing. Return the task, or #f when it is not free: taken, not triaged, or waiting on a dependency."
  (let ((t (todo--must id)))
    (cond ((and (equal? (plist-get t 'state) "doing") (equal? (plist-get t 'assignee) who)) t)
          ((not (equal? (plist-get t 'state) "todo")) #f)
          ((and (plist-get t 'assignee) (not (equal? (plist-get t 'assignee) who))) #f)
          ((not (todo--ready? t (todo--all))) #f)
          (else (todo-update id (list 'state "doing" 'assignee who 'by who))))))

(define (todo-done id &optional result who)
  "(todo-done ID [RESULT] [WHO]) — close the task as done; RESULT goes to the log"
  (todo-update id (list 'state "done" 'log result 'by (or who todo-user))))

(define (todo-cancel id &optional reason who)
  "(todo-cancel ID [REASON] [WHO]) — close the task as cancelled"
  (todo-update id (list 'state "cancelled" 'log reason 'by (or who todo-user))))

(define (todo-wait id reason &optional who)
  "(todo-wait ID REASON [WHO]) — park the task: waiting on someone or something"
  (todo-update id (list 'state "waiting" 'log reason 'by (or who todo-user))))

(define (todo-review id summary &optional who)
  "(todo-review ID SUMMARY [WHO]) — hand the task to a human to approve, e.g. a draft before it is sent"
  (todo-update id (list 'state "review" 'log summary 'by (or who todo-user))))

(define (todo-approve id &optional text who)
  "(todo-approve ID [TEXT] [WHO]) — approve a task in review: back to todo for its assignee, logged as approved"
  (todo-update id (list 'state "todo"
                        'log (if (todo--blank? text) "approved" (string-append "approved: " text))
                        'by (or who todo-user))))

;;; --- the list ----------------------------------------------------------------

(domain! 'writing)
(effects! '(read write))

(define *todo-buffer* "*Todos*")

(define *todo-views*
  (list (list "open" '())
        (list "inbox" '(state "inbox"))
        (list "review" '(state "review"))
        (list "mine" 'mine)
        (list "overdue" '(overdue #t))
        (list "closed" '(state ("done" "cancelled")))))

(define (todo--view buf) (or (buffer-local buf 'todo-view) "open"))

(define (todo--view-spec buf)
  (let ((s (cadr (assoc (todo--view buf) *todo-views*))))
    (if (equal? s 'mine) (list 'assignee todo-user) s)))

(define (todo--rows buf) (todo-list (todo--view-spec buf)))

(define (todo--due t)
  (let ((d (plist-get t 'deadline)))
    (cond ((not d) "") ((todo--overdue? t) (string-append d " !")) (else d))))

;; the state, priority, project, dates and tags under the title
(define (todo--meta t)
  (string-join
    (filter (lambda (s) (not (equal? s "")))
            (list (plist-get t 'state)
                  (let ((p (plist-get t 'priority))) (if p (string-append "#" p) ""))
                  (plist-get t 'project)
                  (if (plist-get t 'deadline) (string-append "due " (todo--due t)) "")
                  (if (plist-get t 'scheduled) (string-append "scheduled " (plist-get t 'scheduled)) "")
                  (let ((tags (plist-get t 'tags)))
                    (if (pair? tags) (string-append ":" (string-join tags ":") ":") ""))))
    "  ·  "))

;; a window this wide shows a task on one line; a narrower one gives the
;; title its own line, so the title is not cut
(define todo-wide-cols 150)

(define (todo--wide-columns buf)
  (list (list "STATE" 9)
        (list "P" 1)
        (list "TODO" #f 'left 'end)
        (list "PROJECT" 12)
        (list "WHO" 16)
        (list "DUE" 12)))

(define (todo--cells buf t)
  (list (plist-get t 'state)
        (or (plist-get t 'priority) "")
        (plist-get t 'title)
        (plist-get t 'project)
        (or (plist-get t 'assignee) "")
        (todo--due t)))

(define (todo--row-columns buf)
  (list (list (list "TODO" #f 'left 'end))
        (list (list "" 2) (list "META" #f 'left 'end) (list "WHO" 20 'right))))

(define (todo--row-cells buf t)
  (list (list (plist-get t 'title))
        (list "" (list (todo--meta t) "org-meta") (list (or (plist-get t 'assignee) "") "org-meta"))))

(define (todo--at) (list-current *todo-buffer*))

(define (todo--with-row f)
  (let ((t (todo--at)))
    (if t
        (begin (f t) (list-refresh! *todo-buffer*))
        (message "No task at point"))))

(define (todo--set-at! k v)
  (todo--with-row (lambda (t) (todo-update (plist-get t 'id) (list k v)))))

(define (todo--ask-at! prompt k)
  (let ((t (todo--at)))
    (if t
        (read-string prompt
          (lambda (s)
            (todo-update (plist-get t 'id) (list k s))
            (list-refresh! *todo-buffer*)))
        (message "No task at point"))))

(define-command "todo-visit" "Open the task's file at its heading"
  (lambda ()
    (let ((t (todo--at)))
      (if t
          (begin (visit (plist-get t 'file)) (goto-char! (plist-get t 'pos)))
          (message "No task at point")))))

(define-command "todo-accept" "Mark the task todo: triage it, or approve it from review"
  (lambda () (todo--set-at! 'state "todo")))
(define-command "todo-mark-done" "Mark the task done"
  (lambda () (todo--set-at! 'state "done")))
(define-command "todo-mark-cancelled" "Cancel the task"
  (lambda () (todo--set-at! 'state "cancelled")))
(define-command "todo-mark-waiting" "Park the task as waiting"
  (lambda () (todo--set-at! 'state "waiting")))
(define-command "todo-mark-doing" "Mark the task in progress"
  (lambda () (todo--set-at! 'state "doing")))

(define-command "todo-cycle-priority" "Cycle the task's priority: A, B, C, none"
  (lambda ()
    (todo--with-row
      (lambda (t)
        (let ((p (plist-get t 'priority)))
          (todo-update (plist-get t 'id)
                       (list 'priority (cond ((not p) "A") ((equal? p "A") "B") ((equal? p "B") "C") (else #f)))))))))

(define-command "todo-assign" "Assign the task to someone, or an agent"
  (lambda () (todo--ask-at! "Assign to: " 'assignee)))
(define-command "todo-set-deadline" "Set the task's deadline: YYYY-MM-DD, today, tomorrow, +3d, 2w"
  (lambda () (todo--ask-at! "Deadline: " 'deadline)))
(define-command "todo-set-project" "Move the task to another project"
  (lambda () (todo--ask-at! "Project: " 'project)))
(define-command "todo-add-note" "Add a note to the task"
  (lambda () (todo--ask-at! "Note: " 'note)))

(define-command "todo-capture" "File a new task"
  (lambda ()
    (read-string "Task: "
      (lambda (s)
        (let ((id (todo-create s (list 'state "todo"))))
          (when (buffer-exists? *todo-buffer*) (list-refresh! *todo-buffer*))
          (message (string-append "Filed " id)))))))

(define-command "todo-next-view" "Cycle the view: open, inbox, review, mine, overdue, closed"
  (lambda ()
    (let* ((names (map car *todo-views*))
           (i (todo--rank (todo--view *todo-buffer*) names))
           (next (nth (modulo (+ i 1) (length names)) names)))
      (buffer-set-local! *todo-buffer* 'todo-view next)
      (list-refresh! *todo-buffer*)
      (message (string-append "Todos: " next)))))

(define-command "todo-refresh" "Re-read the todo files"
  (lambda () (list-refresh! *todo-buffer*)))

(define-list-mode! "todo-mode"
  (list
    'buffer *todo-buffer*
    'title (lambda (buf) (string-append "Todos · " (todo--view buf)))
    'layouts (list (list 'name 'wide
                         'min-cols todo-wide-cols
                         'columns todo--wide-columns
                         'cells todo--cells)
                   (list 'name 'stacked
                         'default #t
                         'row-columns todo--row-columns
                         'row-cells todo--row-cells))
    'key (lambda (buf t) (plist-get t 'id))
    'rows todo--rows
    'render (lambda (buf t) (plist-get t 'title))
    'footer (lambda (buf)
              '(("RET" "open") ("t" "accept") ("d" "done") ("x" "cancel") ("w" "wait")
                ("a" "assign") ("D" "deadline") ("P" "project") ("!" "priority")
                ("c" "capture") ("v" "view") ("g" "refresh") ("q" "quit")))
    'noun "task"
    'keys '(("RET" "todo-visit")
            ("t" "todo-accept")
            ("d" "todo-mark-done")
            ("x" "todo-mark-cancelled")
            ("w" "todo-mark-waiting")
            ("s" "todo-mark-doing")
            ("a" "todo-assign")
            ("D" "todo-set-deadline")
            ("P" "todo-set-project")
            ("N" "todo-add-note")
            ("!" "todo-cycle-priority")
            ("c" "todo-capture")
            ("v" "todo-next-view")
            ("g" "todo-refresh")
            ("q" "quit-window"))
    'doc "The shared todo list from todo-directory, most urgent first: review, then doing, todo, inbox and waiting. `t` accepts a task (triage it, or approve it from review), `d` closes it, `x` cancels, `w` parks it, `s` starts it. `a` assigns, `D` sets a deadline, `P` moves it to a project, `N` adds a note, `!` cycles the priority. `c` files a new task. `v` cycles the view: open, inbox, review, mine, overdue, closed. `RET` opens the task's file."))

(define-command "todo" "Show the shared todo list"
  (lambda ()
    (buffer-create *todo-buffer*)
    (switch-to-buffer! *todo-buffer*)
    (set-mode! "todo-mode")
    *todo-buffer*))
