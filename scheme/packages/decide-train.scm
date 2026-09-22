;;; decide-train.scm --- a fine-tuning set for the decide chooser
;;;
;;; Laya answers near chance on typed decisions out of the box. Its model
;;; card says so plainly, and decide-apropos showed it: asked to pick
;;; among eight near-identical *-other-window names it chose the wrong
;;; one at 0.046 confidence, below the 0.125 that eight options give you
;;; for free. There is no prompt to improve, because the model generates
;;; nothing. The only lever is a fine-tune on the question the editor
;;; actually asks.
;;;
;;; So this file builds that question offline, thousands of times, and
;;; labels it with a teacher. Two passes. The first invents directives a
;;; user might type for a known operation. The second is handed the
;;; shortlist the real recall pipeline returned for each directive, and
;;; says how the probability mass should fall across it.
;;;
;;; The shortlist is never invented. decide-apropos--shortlist is the
;;; same code that runs at inference, and decide-apropos-instructions is
;;; the same wording, so a row here trains the question the editor asks
;;; rather than a paraphrase of it.
;;;
;;; The teacher answers with a distribution, not a winner. RLCD rewards a
;;; strictly proper scoring rule, so one-hot targets would teach nothing
;;; but overconfidence -- and plenty of directives are honestly
;;; ambiguous. "show it beside this" fits three operations; a training
;;; set that pretends otherwise is training in a lie.
;;;
;;; Rows match the LocalLLaMA/typed-decisions columns the laya notebook
;;; reads -- state, questions, gold, each a JSON string -- so
;;; build_training_item consumes them unchanged.

(domain! 'decide)
(effects! '(write external execute spend))

(defcustom 'decide-train-teacher #f
  "Model that invents directives and scores them. #f uses the coding role."
  'group 'decide)

(defcustom 'decide-train-operations 200
  "How many operations to sample from the reachable catalog."
  'group 'decide)

(defcustom 'decide-train-per-operation 8
  "Directives the teacher invents for each operation."
  'group 'decide)

(defcustom 'decide-train-concurrency 6
  "Teacher calls in flight at once."
  'group 'decide)

(defcustom 'decide-train-output "~/.compos/decide-train.jsonl"
  "Where the JSONL lands."
  'group 'decide)

(define decide-train-buffer "*decide-train*")
(define decide-train--task #f)

(define (decide-train--log text)
  (buffer-create decide-train-buffer)
  (buffer-append! decide-train-buffer text))

(define (decide-train--model)
  (or decide-train-teacher (llm-model-for 'coding)))

;; A teacher call blocks until the reply lands, so it belongs inside a
;; task and nowhere else. app-await turns the callback into a value; on
;; the lane it would stall every buffer in the editor.
(defcustom 'decide-train-ask-seconds 240
  "How long a teacher call may take. app-await defaults to twenty seconds and
returns an empty value on expiry rather than raising, so a slow call is
indistinguishable from a model that answered with nothing -- which is how a
whole gold pass was discarded without a word."
  'group 'decide)

(defcustom 'decide-train-ask-tries 3
  "Attempts per teacher call. llm-with-model hands its callback #f when the
provider errors, and #f is indistinguishable from a model that said nothing,
so a single transient failure silently voided a whole gold chunk."
  'group 'decide)

(defcustom 'decide-train-teachers '(coding default summarize)
  "Preset roles to try, in order, for one teacher call. Not redundancy for its
own sake: measured on one operation, claude-opus-5 answered a trivial prompt
and returned nothing for the 989-character directive prompt, while
claude-sonnet-5 wrote directives happily and returned nothing for the
3KB gold prompt. Neither failure is about length, and neither is
predictable, so the call walks models the way decide walks backends."
  'group 'decide)

(define (decide-train--models)
  (if decide-train-teacher
      (list decide-train-teacher)
      (let loop ((rs decide-train-teachers) (acc '()))
        (if (null? rs)
            acc
            (let ((m (llm-model-for (car rs))))
              (loop (cdr rs) (if (member m acc) acc (append acc (list m)))))))))

(define (decide-train--ask prompt)
  ;; An empty answer is the only failure signal there is: llm-with-model hands
  ;; its callback #f on a provider error and app-await returns #f on expiry,
  ;; and neither is distinguishable from a model that said nothing.
  (let round ((n decide-train-ask-tries))
    (let model ((ms (decide-train--models)))
      (if (null? ms)
          (if (<= n 1) "" (round (- n 1)))
          (let ((r (app-await (lambda (k) (llm-with-model prompt (car ms) k))
                              decide-train-ask-seconds)))
            (if (and (string? r) (> (string-length r) 0))
                r
                (model (cdr ms))))))))

;; A model asked for bare JSON still fences it often enough to matter.
(define (decide-train--unfence s)
  (let ((i (string-index s "```")))
    (if (not i)
        s
        (let* ((rest (substring s (+ i 3) (string-length s)))
               (nl (string-index rest "\n"))
               (body (if nl (substring rest (+ nl 1) (string-length rest)) rest))
               (j (string-index body "```")))
          (if j (substring body 0 j) body)))))

;; There is no way to catch a raise in this dialect, so every value the
;; teacher produces is checked before it is used rather than after it
;; explodes.
(define (decide-train--json s)
  (and (string? s)
       (> (string-length s) 0)
       (json-parse (decide-train--unfence s))))

(define (decide-train--strings xs)
  (if (pair? xs)
      (filter (lambda (x) (and (string? x) (> (string-length x) 1))) xs)
      '()))

;; Reachable means decide-apropos--expression can build a call for it:
;; no arguments, or one it can fill from the directive. A doc is
;; required, because the doc is the entire description the chooser --
;; and therefore the trained model -- ever sees.
(define (decide-train--reachable)
  (filter (lambda (e)
            (let ((d (plist-get e 'doc)))
              (and (string? d)
                   (> (string-length d) 0)
                   (< (length (decide-apropos--params e)) 2))))
          (filter decide-apropos--candidate?
                  (apropos "" 'include-display #t 'lexical #t))))

;; Stride rather than prefix. The catalog arrives grouped by package, so
;; the first N operations would all come from one corner of the editor
;; and the model would learn that corner.
(define (decide-train--sample xs n)
  (let ((total (length xs)))
    (if (<= total n)
        xs
        (let loop ((rest xs) (i 0) (acc '()) (got 0))
          (if (or (null? rest) (>= got n))
              (reverse acc)
              (if (< (* got total) (* i n))
                  (loop (cdr rest) (+ i 1) (cons (car rest) acc) (+ got 1))
                  (loop (cdr rest) (+ i 1) acc got)))))))

(define (decide-train--chunk xs n)
  (if (null? xs)
      '()
      (let loop ((rest xs) (head '()) (k 0) (acc '()))
        (cond ((null? rest)
               (reverse (if (null? head) acc (cons (reverse head) acc))))
              ((>= k n)
               (loop rest '() 0 (cons (reverse head) acc)))
              (else
               (loop (cdr rest) (cons (car rest) head) (+ k 1) acc))))))

;; Pass one. Only the bare identifier is banned. Banning every word
;; inside it as well looked rigorous and was a mistake: for
;; display-buffer-other-window! it outlawed display, buffer, other and
;; window, which is precisely the vocabulary recall matches on, and every
;; directive it produced was unfindable. Eight of eight, on the operation
;; that matters most. The point is directives a person would really type,
;; and a person really does type other window.
(define (decide-train--directive-prompt e k)
  (let ((n (number->string k)))
    (string-append
      "You write the terse directives people type into an editor command bar.\n\n"
      "Operation: " (plist-get e 'name) "\n"
      "Signature: " (or (plist-get e 'sig) (plist-get e 'name)) "\n"
      "Does: " (plist-get e 'doc) "\n\n"
      "Write " n " different directives that ask for this operation.\n\n"
      "Rules:\n"
      "- Sound like a hurried person, not like documentation. Lowercase is fine.\n"
      "- Do not write the operation's identifier itself.\n"
      "- Ordinary words that happen to appear inside that identifier are fine\n"
      "  and wanted. A user really does say other window.\n"
      "- Vary how near the wording sits to the identifier across the " n ".\n"
      "  Make some obvious and some oblique: a user says buffer for window,\n"
      "  file for document, close for kill, beside for other window.\n"
      "- If the operation takes an argument, include a plausible one -- a file\n"
      "  like agenda.scm, a buffer name, a project path.\n"
      "- Range from two words to a full sentence.\n\n"
      "Reply with a JSON array of strings and nothing else.")))

(define (decide-train--options cands)
  (string-join
    (map (lambda (e)
           (string-append "  - " (plist-get e 'name) ": "
                          (or (plist-get e 'doc) "")))
         cands)
    "\n"))

(define (decide-train--case i directive cands)
  (string-append "Case " (number->string i) "\n"
                 "directive: " directive "\n"
                 "options:\n" (decide-train--options cands) "\n"))

;; Pass two, batched by operation so the run costs one call per operation
;; rather than one per directive. The teacher never learns which
;; operation the directives were written for -- it judges the directive
;; against the shortlist, exactly as the model being trained will have to.
(define (decide-train--gold-prompt cases)
  (string-append
    "A user typed a directive into an editor command bar, and a shortlist of\n"
    "operations was retrieved for it. For each case, say how likely each\n"
    "option is the one the user meant.\n\n"
    (string-join cases "\n")
    "\nRules:\n"
    "- Probabilities within a case sum to 1.\n"
    "- Be honest about ambiguity. Where two options genuinely both fit, split\n"
    "  the mass between them. A confident wrong answer is worth less here\n"
    "  than an uncertain right one.\n"
    "- If nothing on the shortlist fits the directive, spread the mass evenly.\n"
    "- Use the option names exactly as written.\n\n"
    "Reply with a JSON array holding one object per case, in order, each\n"
    "mapping option name to probability. Nothing else."))

(define (decide-train--sum xs)
  (let loop ((rest xs) (acc 0))
    (if (null? rest) acc (loop (cdr rest) (+ acc (car rest))))))

;; Keep only mass the teacher put on options that are really on the
;; shortlist, then renormalise. A teacher that invents an option name, or
;; scores one it was not offered, must not move the target.
(define (decide-train--probs raw cands)
  (and (pair? raw)
       (let* ((names (map (lambda (e) (plist-get e 'name)) cands))
              (vals (map (lambda (n)
                           (let ((v (plist-get raw (string->symbol n))))
                             (if (and (number? v) (> v 0)) v 0)))
                         names))
              (s (decide-train--sum vals)))
         (and (> s 0)
              (let loop ((ns names) (vs vals) (acc '()))
                (if (null? ns)
                    (reverse acc)
                    (loop (cdr ns) (cdr vs)
                          (cons (/ (car vs) s)
                                (cons (string->symbol (car ns)) acc)))))))))

;; state is the plain directive, not JSON. questions and gold are JSON
;; strings because the notebook parses them back; state is read as text, and
;; encoding it here meant --flush encoded it a second time, so every row
;; arrived with the directive wrapped in escaped quotes.
(define (decide-train--row directive cands probs op)
  (list 'state directive
        'questions (json-encode
                     (list 'pick
                           (list 'type "choice"
                                 'instructions decide-apropos-instructions
                                 'criteria (decide-apropos--criteria cands))))
        'gold (json-encode (list 'pick (list 'probabilities probs)))
        'op op
        'directive directive))

(define (decide-train--holds? cands name)
  (let loop ((xs cands))
    (cond ((null? xs) #f)
          ((string=? (plist-get (car xs) 'name) name) #t)
          (else (loop (cdr xs))))))

;; One shortlist, one process, and this is not tidiness -- it is the only
;; way the work finishes. Every apropos call materialises the whole
;; catalog as Scheme data, decide-apropos--recall makes ten of them per
;; directive, and a task that does seven directives' worth walks into the
;; 1GB max_heap_size bound and is killed outright. Killed, not raised:
;; SchemeTask rescues a raise and hands back an error, but a heap kill
;; takes the process with everything it had not yet written down.
;;
;; A child task starts with a fresh heap and frees all of it on exit,
;; while the parent keeps only the eight rows that come back. The cost of
;; the catalog therefore never accumulates.
(define (decide-train--shortlist directive)
  (task-await (task-spawn (lambda () (decide-apropos--shortlist directive)))
              120000))

;; One operation, end to end. A directive whose shortlist does not
;; contain the operation it was written for is a recall failure, not a
;; hard example: no choice over that shortlist has a right answer. Those
;; are dropped and counted, because the count measures the retrieval
;; half of decide-apropos, which no fine-tune can fix.
(defcustom 'decide-train-gold-batch 3
  "Cases per gold call. One call per operation is cheaper, but the reply is a
JSON object per case and the model truncates before it finishes six of them,
which loses every row in the group rather than one."
  'group 'decide)

(define (decide-train--gold cases)
  ;; Chunked, and a chunk that fails to parse costs only its own cases. The
  ;; single call this replaces returned unparseable JSON on six cases while
  ;; parsing three perfectly, so the failure was length, not content.
  (let loop ((cs (decide-train--chunk cases decide-train-gold-batch)) (acc '()))
    (if (null? cs)
        acc
        (let* ((raw (decide-train--ask (decide-train--gold-prompt (car cs))))
               (g (decide-train--json raw)))
          (decide-train--log
            (string-append "  gold chunk " (number->string (length (car cs)))
                           (if (and (pair? g) (pair? (car g)))
                               " ok"
                               (string-append " BAD <"
                                              (let ((r (if (string? raw) raw "")))
                                                (substring r 0 (min 300 (string-length r))))
                                              ">"))
                           "\n"))
          (loop (cdr cs)
                (append acc
                        ;; exactly one entry per case, always: a short or
                        ;; failed reply pads with #f rather than shortening the
                        ;; group, because appending a short chunk would shift
                        ;; every later case onto the wrong directive.
                        (let pad ((need (car cs)) (got (if (pair? g) g '())) (out '()))
                          (if (null? need)
                              (reverse out)
                              (pad (cdr need)
                                   (if (pair? got) (cdr got) '())
                                   (cons (if (pair? got) (car got) #f) out))))))))))

(define (decide-train--operation e)
  (let* ((op (plist-get e 'name))
         (ds (decide-train--strings
               (decide-train--json
                 (decide-train--ask
                   (decide-train--directive-prompt e decide-train-per-operation))))))
    (if (null? ds)
        (list 'rows '() 'misses 0 'failed 1)
        (let* ((sets (map (lambda (d) (list d (decide-train--shortlist d))) ds))
               (hit (filter (lambda (s)
                              (let ((c (car (cdr s))))
                                (and (pair? c)
                                     (pair? (cdr c))
                                     (decide-train--holds? c op))))
                            sets))
               (miss (- (length sets) (length hit))))
          (if (null? hit)
              (list 'rows '() 'misses miss 'failed 0)
              (let* ((cases (let loop ((xs hit) (i 1) (acc '()))
                              (if (null? xs)
                                  (reverse acc)
                                  (loop (cdr xs) (+ i 1)
                                        (cons (decide-train--case
                                                i (car (car xs)) (car (cdr (car xs))))
                                              acc)))))
                     (gs (decide-train--gold cases)))
                (if (not (pair? gs))
                    (list 'rows '() 'misses miss 'failed 1)
                    (let loop ((xs hit) (rs gs) (acc '()) (bad 0))
                      (if (or (null? xs) (null? rs))
                          (list 'rows (reverse acc) 'misses miss
                                'failed (if (> bad 0) 1 0))
                          (let* ((d (car (car xs)))
                                 (c (car (cdr (car xs))))
                                 (pr (and (pair? (car rs))
                                          (decide-train--probs (car rs) c))))
                            (loop (cdr xs) (cdr rs)
                                  (if pr (cons (decide-train--row d c pr op) acc) acc)
                                  (if pr bad (+ bad 1)))))))))))))

;; The file is rewritten after every group rather than once at the end.
;; A raise inside a task cannot be caught in this dialect, so the only
;; protection against losing an hour of teacher calls is to have already
;; written them down.
(define (decide-train--flush path rows)
  (write-file! path
    (if (null? rows)
        ""
        (string-append (string-join (map json-encode rows) "\n") "\n"))))

(define (decide-train--run ops path)
  (let ((t0 (monotonic-ms))
        (total (length ops)))
    (let loop ((groups (decide-train--chunk ops decide-train-concurrency))
               (rows '()) (misses 0) (failed 0) (done 0))
      (if (null? groups)
          (let ((ms (- (monotonic-ms) t0)))
            (decide-train--flush path rows)
            (decide-train--log
              (string-append "done  rows " (number->string (length rows))
                             "  recall-misses " (number->string misses)
                             "  teacher-failures " (number->string failed)
                             "  ms " (number->string ms)
                             "\n" path "\n" decide-train-done))
            (list 'rows (length rows) 'misses misses 'failed failed
                  'ms ms 'path path))
          (let* ((group (car groups))
                 (ts (map (lambda (e)
                            (task-spawn (lambda () (decide-train--operation e))))
                          group))
                 (rs (map (lambda (t) (task-await t 180000)) ts))
                 (nrows (apply append (map (lambda (r) (plist-get r 'rows)) rs)))
                 (nm (decide-train--sum (map (lambda (r) (plist-get r 'misses)) rs)))
                 (nf (decide-train--sum (map (lambda (r) (plist-get r 'failed)) rs)))
                 (all (append rows nrows))
                 (d (+ done (length group))))
            (decide-train--flush path all)
            (decide-train--log
              (string-append (number->string d) "/" (number->string total)
                             "  rows " (number->string (length all))
                             "  misses " (number->string (+ misses nm))
                             "  " (number->string (- (monotonic-ms) t0)) "ms\n"))
            (loop (cdr groups) all (+ misses nm) (+ failed nf) d))))))

;; Returns the moment the work is handed to a task. Progress lands in
;; decide-train-buffer and rows land on disk, so the caller reads state
;; back later instead of holding the lane for the length of the run.
(define (decide-train-build!)
  (let* ((ops (decide-train--sample (decide-train--reachable)
                                    decide-train-operations))
         (path (expand-path decide-train-output)))
    (buffer-set-text! decide-train-buffer "")
    (decide-train--log
      (string-append "teacher " (decide-train--model)
                     "  operations " (number->string (length ops))
                     "  directives/op " (number->string decide-train-per-operation)
                     "  concurrency " (number->string decide-train-concurrency)
                     "\n"))
    (set! decide-train--task
          (task-spawn (lambda () (decide-train--run ops path))))
    (list 'started (length ops) 'output path)))

(define (decide-train-status)
  (list 'running (and decide-train--task (task-alive? decide-train--task))
        'log (buffer-text decide-train-buffer)))

(define (decide-train-stop!)
  (and decide-train--task (task-cancel! decide-train--task)))

;; One operation's worth, so the prompts and the row shape can be read
;; before a full run is paid for. It returns at once -- awaiting here
;; would hold the lane for two teacher calls, which is the whole editor
;; frozen for ten seconds.
;;
;; The work goes in the task's body, never in a task-run! callback. A
;; callback's writes do not reach the lane at all: neither a set! on a
;; global nor a buffer-append! survives it, so its result is simply lost
;; while the teacher calls are still billed. A body's writes do survive,
;; and so does the task handle, which is what decide-train-result awaits.
(define (decide-train-preview name)
  (let ((e (let loop ((xs (decide-train--reachable)))
             (cond ((null? xs) #f)
                   ((string=? (plist-get (car xs) 'name) name) (car xs))
                   (else (loop (cdr xs)))))))
    (and e
         (begin
           (buffer-set-text! decide-train-buffer "")
           (set! decide-train--task
                 (task-spawn
                   (lambda ()
                     (let ((r (decide-train--operation e)))
                       (decide-train--log
                         (string-append "preview " name
                                        "  rows " (number->string (length (plist-get r 'rows)))
                                        "  misses " (number->string (plist-get r 'misses))
                                        "  failed " (number->string (plist-get r 'failed))
                                        "\n" decide-train-done))
                       r))))
           (list 'started name)))))

;; task-alive? cannot answer "is it finished", because a finished task
;; stays registered for five more minutes and reads as alive; and
;; task-await raises rather than returning when it times out, so it is no
;; predicate either. The body therefore writes a marker when it is done,
;; and the await that follows is already resolved.
(define decide-train-done "-- finished\n")

(define (decide-train-result)
  (and decide-train--task
       (string-contains? (buffer-text decide-train-buffer) decide-train-done)
       (task-await decide-train--task 5000)))

(define-command "decide-train" "Build the decide fine-tuning set"
  (lambda () (message (value->string (decide-train-build!)))))

(category! 'decide)
(public! 'decide-train-build!
  "start the fine-tuning run; (started N output PATH). Progress in *decide-train*.")
(public! 'decide-train-status
  "(running BOOL log TEXT) for the run in flight.")
(public! 'decide-train-stop!
  "cancel the run in flight.")
(public! 'decide-train-preview
  "start one operation's rows; read them back with decide-train-result.")
(public! 'decide-train-result
  "the last preview's (rows ROWS misses N failed N), or #f while it runs.")
