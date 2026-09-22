;;; decide-apropos.scm --- run a directive: apropos finds the operation, decide picks it
;;;
;;; "open agenda.scm other buffer" becomes (display-buffer-other-window! "agenda.scm").
;;;
;;; decide answers typed choices and never an expression, so no step here
;;; asks a model to write one. Which backend answers is decide's business:
;;; jev, laya, or an LLM, whatever decide-backends names first.
;;;
;;; Every step is a choice over candidates the editor already
;;; holds: apropos supplies the operations, the buffer list and the project
;;; files supply the arguments, and the directive supplies the literals. A
;;; token that matches exactly one name needs no model at all.

(domain! 'decide)
(effects! '(write external execute display))

(defcustom 'decide-apropos-candidates 8
  "How many apropos hits decide-apropos offers the backend to choose among."
  'group 'decide)

;; The chooser's question, in one place. A fine-tuning set is built by
;; asking this same question offline, so a reworded copy there would train
;; the model on a question the editor never asks.
(defcustom 'decide-apropos-instructions
  "Which operation does this directive ask for?"
  "The instructions the chooser sends with its choice question."
  'group 'decide)

;; A flat floor cannot judge a choice: one of two options at 0.45 is worse
;; than a coin toss, while one of eight at 0.37 is three times chance. This
;; is the margin ABOVE chance that an answer must clear, so the bar rises
;; and falls with the number of options.
(defcustom 'decide-apropos-confidence 0.2
  "How far above chance a choice must land before decide-apropos uses it."
  'group 'decide)

(define (decide-apropos--confident? conf n)
  (let ((chance (/ 1.0 (if (< n 2) 2 n))))
    (>= conf (+ chance (* decide-apropos-confidence (- 1.0 chance))))))

;; ── Candidates ────────────────────────────────────────────

;; A private helper is never what a directive meant, and a destructive one is
;; not something to run on a guess: this executes what it picks.
(define (decide-apropos--candidate? e)
  (let ((k (plist-get e 'kind))
        (name (plist-get e 'name)))
    (and (or (equal? k "command") (equal? k "function") (equal? k "recipe"))
         (not (string-contains? name "--"))
         (not (member "destroy" (or (plist-get e 'effects) '()))))))

;; criteria is option -> description, flat: (NAME DOC NAME DOC ...)
(define (decide-apropos--criteria cands)
  (let loop ((xs cands) (acc '()))
    (if (null? xs)
        (reverse acc)
        (let ((e (car xs)))
          (loop (cdr xs)
                (cons (or (plist-get e 'doc) (plist-get e 'name))
                      (cons (string->symbol (plist-get e 'name)) acc)))))))

(define (decide-apropos--name-criteria names)
  (let loop ((xs names) (acc '()))
    (if (null? xs)
        (reverse acc)
        (loop (cdr xs) (cons (car xs) (cons (string->symbol (car xs)) acc))))))

;; ── Slots ─────────────────────────────────────────────────
;; A function's signature already names its parameters, so the arity and the
;; intent of each argument are catalogued facts. A command takes none.

(define (decide-apropos--params e)
  ;; apropos calls it sig, the catalog calls it signature, and the arity fit
  ;; silently read nothing when the entry came from the catalog.
  (let ((sig (or (plist-get e 'sig) (plist-get e 'signature))))
    (if (not (string? sig))
        '()
        (let ((open (string-index sig " ")))
          (if (not open)
              '()
              (filter (lambda (w)
                        (and (> (string-length w) 0)
                             (not (string-contains? w "["))
                             (not (string-contains? w "&"))))
                      (string-split
                        (substring sig (+ open 1) (- (string-length sig) 1))
                        " ")))))))

;; ── Targets ───────────────────────────────────────────────
;; The directive supplies the literal ("agenda.scm"); the editor supplies the
;; real names. A token matching exactly one buffer or file needs no model:
;; the backend is asked only where the directive is genuinely ambiguous.

(defcustom 'decide-apropos-stopwords
  '("the" "this" "that" "these" "those" "and" "for" "with" "into" "from"
    "please" "can" "you" "its" "here" "there" "over" "some" "any"
    "one" "now" "then" "but" "not" "was" "are" "have" "get" "got")
  "Directive words that carry no operation meaning. They match catalog names by accident and flatten the ranking."
  'group 'decide)

(define (decide-apropos--strip s)
  ;; A directive is typed prose, so words arrive wearing punctuation:
  ;; "other window, don't switch me away" tokenises to "window," which matches
  ;; no catalog name at all, and the one query that would have found the
  ;; operation is never issued.
  ;; A dot and a slash are deliberately not in this set: they are how
  ;; --named-tokens recognises a target, and stripping them made every
  ;; directive look like it named nothing.
  (let loop ((cs (list "," ";" ":" "!" "?" "'" "\"" "(" ")" "[" "]")) (out s))
    (if (null? cs) out (loop (cdr cs) (string-replace out (car cs) "")))))

(define (decide-apropos--tokens directive)
  (filter (lambda (w) (and (> (string-length w) 2)
                           (not (member w decide-apropos-stopwords))))
          (map decide-apropos--strip
               (string-split (string-downcase directive) " "))))

;; A target names itself: "agenda.scm" carries a dot, a path carries a slash.
;; Generic words ("open", "buffer") name the operation instead, and matching
;; targets on those is how "open agenda.scm other buffer" first answered with
;; four unrelated buffers.
(define (decide-apropos--named-tokens directive)
  (filter (lambda (w) (or (string-contains? w ".") (string-contains? w "/")))
          (decide-apropos--tokens directive)))

(define (decide-apropos--target-tokens directive)
  (let ((named (decide-apropos--named-tokens directive)))
    (if (pair? named) named (decide-apropos--tokens directive))))

;; What is left once the target is taken out is the operation, and that is
;; what apropos should be asked. A filename in the query only pulls the
;; search toward whatever file happens to share its words.
(define (decide-apropos--operation-words directive)
  (let ((named (decide-apropos--named-tokens directive)))
    (if (null? named)
        directive
        (string-join
          (filter (lambda (w) (not (member (string-downcase w) named)))
                  (string-split directive " "))
          " "))))

;; git-root answers (error MSG) outside a repository, and that list is
;; truthy: only a string is a root.
;; The chat's own directory need not be a project - this one is ~ - and the
;; open buffers need not belong to the project the directive means. The
;; editor already keeps every root it has seen, so a target is findable in
;; any project the user works in, open or not. The current project leads.
(define (decide-apropos--roots)
  (let* ((here (project-current))
         (seen (known-projects))
         (rest (if (string? here) (filter (lambda (r) (not (equal? r here))) seen) seen)))
    (if (string? here) (cons here rest) rest)))

(defcustom 'decide-apropos-names-ttl 60
  "Seconds a directive's file listing is reused before the project trees are read again.")

(define *decide-apropos--files* #f)
(define *decide-apropos--files-at* 0)

;; project-files answers paths relative to its root, and the same file can
;; sit under two roots, so a name is absolutized here and deduped below.
;;
;; Listing six project trees costs seconds, and it is the whole cost of a
;; directive that names a file. What it answers changes when a file is
;; added, not between two words of one directive, so hold it. Open buffers
;; are gathered fresh: a buffer the user just opened is a likely target.
(define (decide-apropos--files)
  (let ((now (monotonic-ms)))
    (if (and *decide-apropos--files*
             (< (- now *decide-apropos--files-at*)
                (* 1000 decide-apropos-names-ttl)))
        *decide-apropos--files*
        (let ((files (let loop ((rs (take-n (decide-apropos--roots) 6)) (acc '()))
                       (if (null? rs)
                           acc
                           (loop (cdr rs)
                                 (append acc
                                         (map (lambda (p) (string-append (car rs) "/" p))
                                              (project-files (car rs)))))))))
          (set! *decide-apropos--files* files)
          (set! *decide-apropos--files-at* now)
          files))))

;; Deduplicating 33,000 names costs a quadratic scan and answers a question
;; nobody asked: the few names a directive actually matches are deduplicated
;; in decide-apropos--matches, where the list is short.
(define (decide-apropos--names)
  (append (buffer-list) (decide-apropos--files)))

(define (decide-apropos--distinct xs)
  (let loop ((rest xs) (seen '()))
    (cond ((null? rest) (reverse seen))
          ((member (car rest) seen) (loop (cdr rest) seen))
          (else (loop (cdr rest) (cons (car rest) seen))))))

(define (decide-apropos--matches directive)
  (let ((toks (decide-apropos--target-tokens directive)))
    (decide-apropos--distinct
     (filter (lambda (n)
              (let ((low (string-downcase n)))
                (let loop ((ts toks))
                  (cond ((null? ts) #f)
                        ((string-contains? low (car ts)) #t)
                        (else (loop (cdr ts)))))))
            (decide-apropos--names)))))

;; ── Choosing ──────────────────────────────────────────────
;; One typed question, one answer, and the confidence decides whether the
;; answer is used at all. Returns (CHOICE CONFIDENCE MS) or #f.

(define (decide-apropos--choose instructions criteria state)
  (let* ((r (decide state
                    (list 'pick (list 'type "choice"
                                      'instructions instructions
                                      'criteria criteria))
                    ))
         (row (assq 'pick (plist-get r 'answers)))
         (v (and row (car (cdr row)))))
    (and v
         (let ((choice (plist-get v 'choice))
               (conf (or (plist-get v 'confidence) 0))
               (usage (plist-get r 'usage)))
           (and (string? choice)
                (decide-apropos--confident? conf (/ (length criteria) 2))
                (list choice conf (car (cdr (cdr (cdr usage))))))))))

;; ── Building the expression ───────────────────────────────

(define (decide-apropos--quote s) (string-append "\"" s "\""))

;; One argument for now. A two-argument operation needs a slot-by-slot
;; choice, and guessing which name fills which slot is exactly the kind of
;; invention this design refuses.
(defcustom 'decide-apropos-state
  '((buffer  "the name of a buffer that is open now"  "(buffer-list)")
    (file    "the path of a file in the project"      "(decide-apropos--files)")
    (theme   "the name of a colour theme"             "(map car *themes*)")
    (setting "the name of a customizable setting"     "(decide-apropos--catalog-names \"variable\")"))
  "The state spaces an argument can be drawn from: (KEY DESCRIPTION EXPRESSION). The catalog holds verbs; their arguments are live values no catalog entry names, so each space says how to enumerate itself. The expression is read and run when the space is consulted, so a space is data and a user can add one here without writing a function. Command names are deliberately absent: apropos already resolves the verb, and offering the same names as argument values made every directive with a common word in it match a hundred commands."
  'group 'decide)

(define (decide-apropos--catalog-names kind)
  (decide-apropos--distinct
    (map (lambda (e) (plist-get e 'name))
         (filter (lambda (e) (equal? (plist-get e 'kind) kind)) (catalog)))))

;; The names in one state space, right now. A space is enumerated only
;; when it is consulted: the file space walks the project and the command
;; space walks the catalog, and gathering all of them for every directive
;; would cost more than the decision it feeds.
(define (decide-apropos--state-names key)
  (let* ((row (assq key decide-apropos-state))
         (v (and row (ignore-errors (lambda () (eval-string (car (cdr (cdr row)))))))))
    (and (pair? v) (map (lambda (x) (if (pair? x) (car x) x)) v))))

;; (LOWERCASE NAME) for one space. Matching downcases every name it looks
;; at, and the file space holds 33,000 paths: downcasing them once per
;; directive was most of the 1.5 seconds "open fast-code.scm" took, with no
;; model involved. A space small enough to lower on the spot is lowered on
;; the spot; a big one is kept until the space itself changes.
;;
;; The cache turns on the space, not on a clock. A clock re-lowered 33,000
;; paths every time it ran out, which is 900ms of work to reproduce a list
;; that had not changed — and the enumeration behind it is already cached,
;; so the length and the first name are enough to notice when it has.
(define decide-apropos-lower-cache-min 1000)
(define *decide-apropos--lowered* '())

(define (decide-apropos--base name)
  (let loop ((xs (string-split name "/")) (b name))
    (if (null? xs) b (loop (cdr xs) (car xs)))))

;; (STAMP PAIRS INDEX) for one space: the lowered names, and an index from
;; a name's last path segment to the name itself.
(define (decide-apropos--state-cache key)
  (let* ((names (decide-apropos--state-names key))
         (ns (if (pair? names) names '()))
         (stamp (list (length ns) (if (pair? ns) (car ns) "")))
         (row (assq key *decide-apropos--lowered*)))
    (if (and row (equal? (car (cdr row)) stamp))
        (cdr row)
        (let* ((pairs (map (lambda (n) (list (string-downcase n) n)) ns))
               (index (map (lambda (p)
                             (list (decide-apropos--base (car p)) (car (cdr p))))
                           pairs)))
          (when (> (length pairs) decide-apropos-lower-cache-min)
            (set! *decide-apropos--lowered*
                  (cons (list key stamp pairs index)
                        (filter (lambda (r) (not (equal? (car r) key)))
                                *decide-apropos--lowered*))))
          (list stamp pairs index)))))

(define (decide-apropos--state-lowered key)
  (car (cdr (decide-apropos--state-cache key))))

(define (decide-apropos--state-index key)
  (car (cdr (cdr (decide-apropos--state-cache key)))))

;; A named token is a whole file name — "fast-code.scm", not a fragment of
;; a path. Looking one up in the index answers in 0ms where scanning 33,000
;; paths for the substring took 400, so the index is asked first and the
;; scan is what happens when the token is not a whole name.
;; A named token is a whole file name — "fast-code.scm", not a fragment of
;; a path. Looking one up in the index answers in 0ms where scanning 33,000
;; paths for the substring took 400, so the index is asked first and the
;; scan is what happens when the token is not a whole name.
(define (decide-apropos--file-scored words)
  (let* ((index (decide-apropos--state-index 'file))
         (exact (filter (lambda (x) x)
                        (map (lambda (w)
                               (let ((row (assoc w index)))
                                 (and row
                                      (list (+ (* decide-apropos-length-weight
                                                  (string-length w))
                                               decide-apropos-count-weight
                                               1)
                                            (car (cdr row))))))
                             words))))
    (if (pair? exact)
        exact
        (decide-apropos--space-scored (decide-apropos--state-lowered 'file)
                                      words))))
(define decide-apropos-lower-cache-min 1000)
(define *decide-apropos--lowered* '())

(define (decide-apropos--state-lowered key)
  (let* ((now (monotonic-ms))
         (row (assq key *decide-apropos--lowered*)))
    (if (and row (< (- now (car (cdr row)))
                    (* 1000 decide-apropos-names-ttl)))
        (car (cdr (cdr row)))
        (let* ((names (decide-apropos--state-names key))
               (pairs (if (pair? names)
                          (map (lambda (n) (list (string-downcase n) n)) names)
                          '())))
          (when (> (length pairs) decide-apropos-lower-cache-min)
            (set! *decide-apropos--lowered*
                  (cons (list key now pairs)
                        (filter (lambda (r) (not (equal? (car r) key)))
                                *decide-apropos--lowered*))))
          pairs))))

(define (decide-apropos--state-keys)
  (map car decide-apropos-state))

;; The state a directive names outright: (KEY NAME ...) per space. A word
;; the caller typed is evidence; nothing else is, and the longest word that
;; lands wins — across every space, not within one. "switch to the paperized
;; theme" puts "switch" in the command space and "theme" in the file space,
;; and only a global comparison lets "paperized" throw both out.
;;
;; A space's own name is not a value in it. "buffer" in "move this buffer
;; right" named the space and matched 6,676 files that carry the word in
;; their path, so the key words are struck out before anything is scored.
;; Resolving one directive asks for its state three times — the shortlist
;; needs it to know whether the verb takes an argument, the ranker needs to
;; know which words were spent on it, and the fill needs the names. Scoring
;; 33,000 paths three times was most of the second that "open fast-code.scm"
;; took. One entry, and it expires, so a buffer opened between two directives
;; is never missed.
(define *decide-apropos--hits* #f)
(define *decide-apropos--hits-at* 0)
(define decide-apropos-hits-ttl 5)

(define (decide-apropos--state-hits directive)
  (let ((now (monotonic-ms)))
    (if (and *decide-apropos--hits*
             (equal? (car *decide-apropos--hits*) directive)
             (< (- now *decide-apropos--hits-at*)
                (* 1000 decide-apropos-hits-ttl)))
        (car (cdr *decide-apropos--hits*))
        (let ((hits (decide-apropos--state-hits--compute directive)))
          (set! *decide-apropos--hits* (list directive hits))
          (set! *decide-apropos--hits-at* now)
          hits))))

;; The state a directive names outright: (KEY NAME ...) per space. A word
;; the caller typed is evidence; nothing else is, and the longest word that
;; lands wins — across every space, not within one. "switch to the paperized
;; theme" puts "switch" in the command space and "theme" in the file space,
;; and only a global comparison lets "paperized" throw both out.
;;
;; A space's own name is not a value in it. "buffer" in "move this buffer
;; right" named the space and matched 6,676 files that carry the word in
;; their path, so the key words are struck out before anything is scored.
(define (decide-apropos--state-hits--compute directive)
  (let* ((keys (decide-apropos--state-keys))
         (space-words (map symbol->string keys))
         (named (decide-apropos--named-tokens directive))
         (ws (filter (lambda (w) (not (member w space-words)))
                     (decide-apropos--tokens directive)))
         (scored (map (lambda (key)
                        ;; A path is only ever named outright. Matching one
                        ;; on a bare word makes every file carrying that word
                        ;; a candidate.
                        (let ((words (if (equal? key 'file) named ws)))
                          (list key
                                (cond
                                  ((null? words) '())
                                  ((equal? key 'file)
                                   (decide-apropos--file-scored words))
                                  (else
                                    (let ((pairs (decide-apropos--state-lowered key)))
                                      (if (pair? pairs)
                                          (decide-apropos--space-scored pairs words)
                                          '())))))))
                      keys))
         (top (let loop ((rs scored) (best 0))
                (if (null? rs)
                    best
                    (loop (cdr rs)
                          (let inner ((xs (car (cdr (car rs)))) (b best))
                            (if (null? xs)
                                b
                                (inner (cdr xs) (if (> (car (car xs)) b)
                                                    (car (car xs))
                                                    b)))))))))
    (if (= top 0)
        '()
        (filter (lambda (row) (pair? (car (cdr row))))
                (map (lambda (row)
                       (list (car row)
                             (map (lambda (x) (car (cdr x)))
                                  (filter (lambda (x) (= (car x) top))
                                          (car (cdr row))))))
                     scored)))))

;; (LENGTH NAME) for every name a directive word lands in, the length being
;; how much of the directive that name accounts for.
;; (LENGTH NAME) for every name a directive word lands in, the length being
;; how much of the directive that name accounts for. Written as a fold: the
;; file space holds 33,000 paths, and map-then-filter built and threw away
;; two lists that size on every directive.
;; (LENGTH NAME) for every name a directive word lands in, the length being
;; how much of the directive that name accounts for. PAIRS is (LOWERCASE
;; NAME), already folded by the caller. Written as a fold: the file space
;; holds 33,000 paths, and map-then-filter built and threw away two lists
;; that size on every directive.
;; (SCORE NAME) for every name a directive word lands in. The score is the
;; longest word that landed, then how many landed at all: "tokyo night theme"
;; puts "night" in tokyo-night and in paper-night at the same length, and
;; only the count separates them — tokyo-night answers for two of the words
;; the caller typed and paper-night for one. Ranking on length alone called
;; that a tie and asked which theme was meant, about a theme the caller had
;; just named.
;;
;; PAIRS is (LOWERCASE NAME), already folded by the caller. Written as a
;; fold: the file space holds 33,000 paths, and map-then-filter built and
;; threw away two lists that size on every directive.
(define decide-apropos-length-weight 100)

;; (SCORE NAME) for every name a directive word lands in. Three things, in
;; order: the longest word that landed, then how many landed, then whether
;; a word IS the name.
;;
;; Each tier answers a case the one before it ties. Length alone tied
;; "night" across tokyo-night and paper-night; count sees that tokyo-night
;; answers for two of the words typed and paper-night for one. Count alone
;; tied "paper" across paper, paper-night and paperized; exactness sees
;; that one of them is the word. Exactness last, not first: ranking it above
;; count turned "paper night theme" into the paper theme, because "paper"
;; is exactly a theme's name and paper-night merely covers more of what the
;; caller said.
;;
;; PAIRS is (LOWERCASE NAME), already folded by the caller. Written as a
;; fold: the file space holds 33,000 paths, and map-then-filter built and
;; threw away two lists that size on every directive.
(define decide-apropos-length-weight 10000)
(define decide-apropos-count-weight 100)

(define (decide-apropos--space-scored pairs ws)
  (let loop ((ps pairs) (acc '()))
    (if (null? ps)
        acc
        (let* ((p (car ps))
               (low (car p))
               (scored (let inner ((xs ws) (best 0) (n 0) (exact 0))
                         (if (null? xs)
                             (list best n exact)
                             (let ((w (car xs)))
                               (if (string-contains? low w)
                                   (inner (cdr xs)
                                          (if (> (string-length w) best)
                                              (string-length w)
                                              best)
                                          (+ n 1)
                                          (if (equal? low w) 1 exact))
                                   (inner (cdr xs) best n exact))))))
               (best (car scored))
               (n (car (cdr scored)))
               (exact (car (cdr (cdr scored)))))
          (loop (cdr ps)
                (if (> best 0)
                    (cons (list (+ (* decide-apropos-length-weight best)
                                   (* decide-apropos-count-weight n)
                                   exact)
                                (car (cdr p)))
                          acc)
                    acc))))))

;; The longest directive word that lands wins: "paperized" beats "theme", so
;; naming a theme outright is not drowned by the category word matching every
;; test fixture that carries it.
(define (decide-apropos--space-matches space directive)
  (let* ((ws (decide-apropos--tokens directive))
         (scored (map (lambda (n)
                        (let ((low (string-downcase n)))
                          (list (let loop ((xs ws) (best 0))
                                  (if (null? xs)
                                      best
                                      (loop (cdr xs)
                                            (if (and (string-contains? low (car xs))
                                                     (> (string-length (car xs)) best))
                                                (string-length (car xs))
                                                best))))
                                n)))
                      space))
         (hits (filter (lambda (r) (> (car r) 0)) scored))
         (top (let loop ((rs hits) (b 0)) (if (null? rs) b (loop (cdr rs) (if (> (car (car rs)) b) (car (car rs)) b))))))
    (map (lambda (r) (car (cdr r)))
         (filter (lambda (r) (= (car r) top)) hits))))

;; One round trip, one answer per key. The backends take a dict of
;; questions, so settling four arguments costs the same trip as settling
;; one — which is the whole reason state is gathered in a stage of its own
;; instead of one model call per argument.
(define (decide-apropos--choose-many questions state)
  (let* ((qs (let loop ((rows questions) (out '()))
               (if (null? rows)
                   (reverse out)
                   (let ((row (car rows)))
                     (loop (cdr rows)
                           (cons (list 'type "choice"
                                       'instructions (car (cdr row))
                                       'criteria (car (cdr (cdr row))))
                                 (cons (car row) out)))))))
         (answers (plist-get (decide state qs) 'answers)))
    (filter (lambda (x) x)
            (map (lambda (row)
                   (let* ((a (assq (car row) answers))
                          (v (and a (car (cdr a))))
                          (choice (and v (plist-get v 'choice)))
                          (conf (or (and v (plist-get v 'confidence)) 0)))
                     (and (string? choice)
                          (decide-apropos--confident?
                            conf (/ (length (car (cdr (cdr row)))) 2))
                          (list (car row) choice conf))))
                 questions))))

;; Gather, then write. Every argument's state is settled before a single
;; character of code is written: a call assembled while its arguments are
;; still unknown is how (load-theme) came out with an empty NAME. One trip
;; settles them all, whatever space each is drawn from, so a two-argument
;; operation costs what a one-argument operation costs.
;; Gather, then write. Every argument's state is settled before a single
;; character of code is written: a call assembled while its arguments are
;; still unknown is how (load-theme) came out with an empty NAME. One trip
;; settles them all, whatever space each is drawn from, so a two-argument
;; operation costs what a one-argument operation costs.
;; The live values a directive narrowed to, across every space that
;; answered. This is what there is to ask about when it narrowed to a few
;; and not to one.
(define (decide-apropos--fill-candidates directive)
  (decide-apropos--distinct
    (let loop ((rs (decide-apropos--state-hits directive)) (acc '()))
      (if (null? rs)
          acc
          (loop (cdr rs) (append acc (car (cdr (car rs)))))))))

(define (decide-apropos--fill params directive e)
  (let* ((hits (decide-apropos--state-hits directive))
         (names (decide-apropos--distinct
                  (let loop ((rs hits) (acc '()))
                    (if (null? rs)
                        acc
                        (loop (cdr rs) (append acc (car (cdr (car rs))))))))))
    (cond
      ;; No enumerated space holds a word the directive typed. A buffer or
      ;; a file is usually named by a word that is in no list, so recall
      ;; still answers for a single argument.
      ((null? hits) (decide-apropos--fill-by-recall params directive))
      ;; One argument, and every space that answered answered with the same
      ;; single name: settled, with no model at all. A path lands in the
      ;; buffer space and the file space both, and that is agreement, not
      ;; ambiguity.
      ((and (null? (cdr params)) (null? (cdr names))) (list (car names)))
      (else (decide-apropos--fill-by-model params directive hits)))))

(define (decide-apropos--fill-by-recall params directive)
  (and (null? (cdr params))
       (let ((ms (take-n (decide-apropos--matches directive)
                         decide-apropos-candidates)))
         (cond
           ((null? ms) #f)
           ((null? (cdr ms)) (list (car ms)))
           ;; Several names match and the directive named none of them — the
           ;; word "file" in "open a file in a split" matched every file with
           ;; it in the path. Asking a model to pick one is inventing an
           ;; argument, which is the one thing this design refuses.
           ((not (pair? (decide-apropos--named-tokens directive))) #f)
           (else
             (let ((picked (decide-apropos--choose
                             "Which buffer or file does this directive name?"
                             (decide-apropos--name-criteria ms)
                             directive)))
               (and picked (list (car picked)))))))))

(define (decide-apropos--fill-by-model params directive hits)
  (let* ((pool (decide-apropos--distinct
                 (let loop ((rs hits) (acc '()))
                   (if (null? rs)
                       acc
                       (loop (cdr rs) (append acc (car (cdr (car rs)))))))))
         (qs (let loop ((ps params) (i 1) (out '()))
               (if (null? ps)
                   (reverse out)
                   (loop (cdr ps) (+ i 1)
                         (cons (list (string->symbol
                                       (string-append "arg" (number->string i)))
                                     (string-append
                                       "Which of these does the directive give as "
                                       (car ps) "?")
                                     (decide-apropos--name-criteria pool))
                               out)))))
         (picked (decide-apropos--choose-many qs directive)))
    ;; Every argument or none: a call with one slot guessed and one left
    ;; empty does not run, and reporting the miss beats emitting it.
    (and (= (length picked) (length params))
         (map (lambda (row) (car (cdr row))) picked))))

;; A call that moves what the user sees has to run against the frame. Eval
;; from an agent or from the chat prompt has the chat as its logical current
;; buffer, so a display-effect call returned its value and changed nothing:
;; switch-to-buffer-in-group! answered a group id, and no window moved. The
;; catalog names the effect, so the wrap is read off the entry rather than
;; kept here as a list of the names that happen to move windows.
(define (decide-apropos--displays? e)
  (let ((fx (plist-get e 'effects)))
    (and (pair? fx) (member "display" fx) #t)))

(define (decide-apropos--frame-wrap expr)
  (let ((forms (and (string? expr) (scheme-read expr))))
    (if (pair? forms)
        (format "~s" (list 'with-frame-windows (list 'lambda '() (car forms))))
        expr)))

;; Narrowed to a few and not to one: ask. The uncertainty becomes a prompt
;; in the generated program rather than an error about it, so "light theme"
;; offers the four light themes instead of listing them in a refusal. This
;; is not a guess and not a fallback — it is the one question the catalog
;; cannot answer, put to the person who can.
;;
;; The handler carries the frame wrap, not the prompt: the call runs later,
;; from the minibuffer's callback, and that is where it has to reach the
;; frame.
(define (decide-apropos--ask prompt candidates callee displays?)
  (let ((call (list callee 'choice)))
    (format "~s"
            (list 'minibuffer-read prompt (list 'quote candidates)
                  (list 'lambda '(choice)
                        (if displays?
                            (list 'with-frame-windows (list 'lambda '() call))
                            call))))))

(define (decide-apropos--expression e directive)
  ;; Code is built as a list and written once with ~s. Assembling source by
  ;; string-append is how a name or an argument carrying a quote produces
  ;; source that will not read; the writer already knows how to quote.
  (let* ((params (decide-apropos--params e))
         (name (plist-get e 'name))
         (displays? (decide-apropos--displays? e))
         (call
           (cond
             ;; A recipe's name is prose, not a call: emitting it as one
             ;; produced the expression (open a file in a split).
             ((equal? (plist-get e 'kind) "recipe")
              (decide-apropos--recipe-expression e directive))
             ((equal? (plist-get e 'kind) "command")
              (format "~s" (list 'run-command name)))
             ((null? params) (format "~s" (list (string->symbol name))))
             (else
               (let ((args (decide-apropos--fill params directive e)))
                 (and args (format "~s" (cons (string->symbol name) args))))))))
    (cond
      (call (if displays? (decide-apropos--frame-wrap call) call))
      ;; one slot, and the directive narrowed to more than one value for it
      ((and (pair? params) (null? (cdr params)))
       (let ((cs (decide-apropos--fill-candidates directive)))
         (and (pair? cs) (pair? (cdr cs))
              (decide-apropos--ask
                (string-append (car params) ": ")
                cs (string->symbol name) displays?))))
      (else #f))))

;; ── Recall ────────────────────────────────────────────────
;; apropos ranks literal name matches first and skips the semantic pass
;; whenever any literal hit exists, so a long query NARROWS: every extra
;; word is another word the name must carry. Recall therefore asks many
;; short questions and pools the answers, and the pool is ranked down
;; before a model ever sees it.

(defcustom 'decide-apropos-aliases
  ;; plain lists, not dotted pairs: (cdr '("a" . "b")) answers (. "b") in
  ;; this interpreter, and the string never arrives. A row is WORD then every
  ;; catalog word it implies, because one user word often means two: "beside"
  ;; is the whole of "other window", and adding only "other" leaves the
  ;; ranking unable to tell a split from a sibling.
  '(("buffer" "window") ("pane" "window") ("tab" "window")
    ("open" "visit") ("show" "display") ("view" "display")
    ("beside" "other" "window") ("alongside" "other" "window")
    ("next" "other") ("elsewhere" "other") ("aside" "other" "window")
    ("split" "split" "window") ("close" "delete") ("kill" "delete"))
  "User words mapped to the catalog's words. A user says 'other buffer'; the editor says 'other window'."
  'group 'decide)

(define (decide-apropos--alias-words words)
  ;; Each alias lands immediately after the word that implied it, not at the
  ;; end of the list. The query builder pairs neighbours first, so an alias
  ;; parked in the tail never pairs with the word it came from, and "beside"
  ;; would expand to other and window without ever asking for "other window".
  (decide-apropos--distinct
    (let loop ((ws words) (acc '()))
      (if (null? ws)
          acc
          (let ((row (assoc (car ws) decide-apropos-aliases)))
            (loop (cdr ws)
                  (append acc
                          (list (car ws))
                          (if row (cdr row) '()))))))))

;; every pair of words, because a pair is short enough to hit literally
;; every pair of words, because a pair is short enough to hit literally and
;; apropos skips its semantic pass whenever any literal word matches — so a
;; longer query narrows rather than broadens. A directive can reduce to a
;; single operation word, though ("display README.md over there" leaves just
;; "display"), and a lone word forms no pair at all, which left the pool empty
;; and the ballot blank. The singles follow the pairs, so they only fill a tail
;; the pairs did not use.
;; Pairs, because a pair is short enough to hit literally and apropos skips
;; its semantic pass whenever any literal word matches -- so a longer query
;; narrows rather than broadens. Order matters more than it looks: taking the
;; first ten pairs of the naive nested loop takes ten pairs that all begin with
;; the first word, and a seven-word directive then never asks for "other
;; window" at all. Neighbours first, then wider gaps, so the phrases the user
;; actually typed are the queries that get issued. Singles fill whatever tail
;; is left, since a directive can reduce to one operation word and a lone word
;; forms no pair.
(define (decide-apropos--queries words)
  (let* ((n (length words))
         (at (lambda (i) (car (take-n (list-tail words i) 1))))
         (pairs (let gap ((g 1) (acc '()))
                  (if (>= g n)
                      (reverse acc)
                      (gap (+ g 1)
                           (let row ((i 0) (a acc))
                             (if (>= (+ i g) n)
                                 a
                                 (row (+ i 1)
                                      (cons (string-append (at i) " " (at (+ i g))) a)))))))))
    (take-n (append pairs words) 10)))

;; apropos ranks by meaning; the local scan below does not. That scan
;; replaced apropos for speed — one apropos call rebuilds the catalog and
;; costs ~473ms, ten of them cost 2.7s — and it took the embeddings with
;; it. "cols" is not inside "columns", so nothing lexical could reach
;; window-layout-columns, while apropos answers it for "three columns"
;; first and for "layout 3 cols" fifth. An alias entry papered over that;
;; this is the signal itself.
;;
;; It is an escalation, not the path: almost every directive is answered by
;; the scan in milliseconds, and the 473ms is paid only when the scan came
;; back with nothing that clears the floor.
(defcustom 'decide-apropos-semantic-weight 6.0
  "What a semantic hit is worth at rank one, divided by its rank down the list. It has to be able to lift an entry over decide-apropos-floor on its own, because an entry apropos ranks first for the whole directive may share no word with it at all."
  'group 'decide)

(defcustom 'decide-apropos-semantic-depth 8
  "How far down apropos's answer counts as a hit."
  'group 'decide)

(define (decide-apropos--semantic directive)
  (let loop ((es (take-n (apropos directive) decide-apropos-semantic-depth))
             (i 1)
             (acc '()))
    (if (null? es)
        (reverse acc)
        (loop (cdr es) (+ i 1)
              (cons (list (plist-get (car es) 'name) i) acc)))))

(define (decide-apropos--semantic-bonus e sem)
  (let ((row (and (pair? sem) (assoc (plist-get e 'name) sem))))
    (if row
        (/ decide-apropos-semantic-weight (car (cdr row)))
        0.0)))

(define (decide-apropos--recall words)
  ;; One pass over the catalog, scored here. The ten short queries existed to
  ;; work around apropos matching every word at once — but each apropos call
  ;; rebuilds the entire catalog as Scheme data and costs ~473ms, while
  ;; (catalog) hands over all 2725 entries for nothing. Scoring locally is
  ;; both faster and better recall: "open telemetry" no longer has to find a
  ;; name carrying *both* words.
  (filter (lambda (e)
            (and (decide-apropos--candidate? e)
                 (> (decide-apropos--score e words) 0)))
          (catalog)))

;; ── Ranking ───────────────────────────────────────────────
;; A name that carries more of the directive's words is a better answer:
;; display-buffer-other-window! holds three of them. Cheap, and it spares
;; the backend a hundred-option question it would answer badly.

(define (decide-apropos--score e words)
  ;; The cheap gate recall uses: does any directive word appear in the name at
  ;; all. Kept name-only and integer on purpose — it runs over the whole
  ;; catalog ten times per directive, and the rich scorer below is far too
  ;; expensive to pay there.
  (let ((low (string-downcase (plist-get e 'name))))
    (let loop ((ws words) (n 0))
      (if (null? ws)
          n
          (loop (cdr ws) (if (string-contains? low (car ws)) (+ n 1) n))))))

(define (decide-apropos--name-tokens name)
  (filter (lambda (w) (> (string-length w) 0))
          (string-split
            (string-replace (string-replace (string-downcase name) "!" "") "?" "")
            "-")))

(define (decide-apropos--doc-words e)
  (let ((d (plist-get e 'doc)))
    (if (string? d)
        (filter (lambda (w) (> (string-length w) 2))
                (string-split (string-downcase d) " "))
        '())))

(define (decide-apropos--relevance e words typed want-arity)
  ;; Counting directive words inside the name left hundreds of entries tied at
  ;; 1, and `sort` then broke the tie on spelling — so a ballot of eight was
  ;; whatever the alphabet offered first, and the right answer was rarely on
  ;; it. Three things separate a real match from an accidental one: whether the
  ;; word is a whole token of the name rather than a substring of one, whether
  ;; the doc agrees, and how much of the name the match accounts for. A name
  ;; that is entirely matched words means what the directive said; a long name
  ;; sharing one word with it does not.
  ;;
  ;; A word the user typed is evidence; a word an alias added is conjecture.
  ;; Scoring them alike let ("buffer" "window") lift window-right over
  ;; buffer-right for "move this buffer right": the alias outvoted the noun,
  ;; and a buffer and a window are not the same thing. An alias may still
  ;; carry a name onto the ballot; it may not win the ballot on its own.
  (let* ((toks (decide-apropos--name-tokens (plist-get e 'name)))
         (low  (string-downcase (plist-get e 'name)))
         (doc  (decide-apropos--doc-words e))
         (hits (let loop ((ws words) (raw 0.0) (seen '()))
                 (if (null? ws)
                     (list raw seen)
                     (let* ((w (car ws))
                            (said (and (member w typed) #t)))
                       (cond
                         ((member w toks)
                          (loop (cdr ws) (+ raw (if said 3.0 1.25))
                                (if said (cons w seen) seen)))
                         ((string-contains? low w)
                          (loop (cdr ws) (+ raw (if said 1.5 0.75))
                                (if said (cons w seen) seen)))
                         ((member w doc)
                          (loop (cdr ws) (+ raw (if said 1.0 0.5)) seen))
                         (else (loop (cdr ws) raw seen)))))))
         (raw (car hits))
         (matched (length (decide-apropos--distinct (car (cdr hits)))))
         (density (if (null? toks) 0.0 (/ (* 1.0 matched) (length toks))))
         ;; A directive naming a file wants an operation that takes one
         ;; argument; a bare directive wants one that takes none. Arity is the
         ;; only structural evidence available before the model is asked, and
         ;; it is what separates display-buffer-other-window! from
         ;; other-window! when both match every word.
         (fit (if (and want-arity (= want-arity (length (decide-apropos--params e))))
                  2.0
                  0.0)))
    (+ raw (* 2.0 density) fit)))

;; sort is ascending, so the key is the negated score
;; sort is ascending, so the key is the negated score. The second key is the
;; name's length, not the name: when two operations are equally relevant the
;; shorter one is the plainer one, and breaking the tie on spelling is what
;; filled the ballot with bookmark commands. The name stays as a third key so
;; the order is deterministic.
(define (decide-apropos--rank cands words typed n want-arity)
  ;; A name can appear twice — load-theme is both a command and a function —
  ;; and the ballot used to sort on one entry's score while returning the
  ;; other, so the function's NAME parameter vanished and the theme could
  ;; never be filled in. Score every entry, then keep the best per name.
  ;;
  ;; Keeping the best per name rebuilt the accumulator on every improvement,
  ;; which is quadratic: 385 candidates spent 403ms of the second a directive
  ;; took, and no model was involved in any of it. Sorting by name puts the
  ;; duplicates next to each other, and one pass takes the head of each run.
  (let* ((rows (map (lambda (e)
                      (list (plist-get e 'name)
                            (- 0.0 (decide-apropos--relevance e words typed want-arity))
                            (string-length (plist-get e 'name))
                            e))
                    cands))
         ;; sorted by name, then by score within a name, so the head of each
         ;; run is that name's best entry
         (grouped (let loop ((rs (sort rows)) (acc '()))
                    (cond ((null? rs) acc)
                          ((and (pair? acc)
                                (equal? (car (car rs)) (car (car acc))))
                           (loop (cdr rs) acc))
                          (else (loop (cdr rs) (cons (car rs) acc))))))
         (keyed (map (lambda (r)
                       (list (car (cdr r)) (car (cdr (cdr r))) (car r)))
                     grouped))
         ;; A winner has to account for enough of what was said. Nonsense
         ;; still lands somewhere — "xyzzy weird thing" reached
         ;; goto-thing-at-point on the word "thing" — and it scores 5.5
         ;; where a real directive scores 8 to 11. Refusing under the floor
         ;; is what a strict margin gate used to do by accident, while also
         ;; refusing directives that were merely close.
         (top (filter (lambda (k) (< (car k) (- 0.0 decide-apropos-floor)))
                      (take-n (sort keyed) n))))
    (map (lambda (k)
           (let ((row (assoc (car (cdr (cdr k))) grouped)))
             (car (cdr (cdr (cdr row))))))
         top)))

;; ── Entry points ──────────────────────────────────────────

(define (decide-apropos--shortlist directive)
  (let* ((hits (decide-apropos--state-hits directive))
         (spent (decide-apropos--state-words hits directive))
         (typed (filter (lambda (w) (not (member w spent)))
                        (decide-apropos--tokens
                          (decide-apropos--operation-words directive))))
         (words (decide-apropos--alias-words typed))
         ;; State is gathered before the verb is chosen, because what the
         ;; directive names decides what kind of verb can take it. A named
         ;; target promises one argument, and so does a word that lands in
         ;; a state space: "a dark theme" names no path, and ranking it at
         ;; arity zero picked the predicate theme-dark? over load-theme.
         ;; --target-tokens answers every token when the directive names no
         ;; path, so asking it here made want 1 for almost every directive
         ;; and quietly taxed each operation that takes no argument:
         ;; "layout 3 cols" lost window-layout-columns, whose whole doc is
         ;; "Show three equal columns", for having nothing to take.
         (want (if (or (pair? (decide-apropos--named-tokens directive))
                       (pair? hits))
                   1
                   0)))
    (decide-apropos--rank (decide-apropos--recall words) words typed
                          decide-apropos-candidates want)))

;; A directive word that landed in a state space is spent: it named the
;; argument, so it is not also evidence for the verb. "dark" named the theme
;; compos-dark and then scored theme-dark? as though it described the
;; operation, which is how "switch to a dark theme" came out asking whether
;; the theme is dark instead of loading one.
(define (decide-apropos--state-words hits directive)
  (let ((names (let loop ((rs hits) (acc '()))
                 (if (null? rs)
                     acc
                     (loop (cdr rs) (append acc (car (cdr (car rs)))))))))
    (filter (lambda (w)
              (let loop ((ns names))
                (cond ((null? ns) #f)
                      ((string-contains? (string-downcase (car ns)) w) #t)
                      (else (loop (cdr ns))))))
            (decide-apropos--tokens directive))))

;; A recipe is the catalog's answer to a task phrased the way a person
;; phrases it, and it carries the expression that performs it. When one
;; matches literally there is nothing left to choose and no model is asked.
;; Ranking identifiers is what happens when no recipe covers the task —
;; the fallback, not the road. Add a recipe and the fallback stops running.
(define (decide-apropos--recipe directive)
  ;; apropos already ranks the whole catalog by meaning and indexes each
  ;; recipe's aliases: "maximize" appears in no recipe name and apropos
  ;; still answers "one window again" for it. A second scorer here only
  ;; competes with that one, and every case it got wrong — maximize, cols,
  ;; kill — was a catalog entry to fix, not a rule to add. So ask apropos,
  ;; and take its answer only when a recipe is what it ranked first: a
  ;; recipe that merely ranks first AMONG recipes is not the answer to a
  ;; directive the catalog answers better elsewhere.
  (let ((hits (apropos (decide-apropos--operation-words directive) 'include-display #t)))
    (and (pair? hits)
         (equal? (plist-get (car hits) 'kind) "recipe")
         (car hits)))) 

(define (decide-apropos--recipe-expression hit directive)
  (let ((use (plist-get hit 'use))
        (props (or (plist-get hit 'props) '())))
    (cond
      ((not (string? use)) #f)
      ((null? props) use)
      ((null? (cdr props))
       (let ((args (decide-apropos--fill props directive hit)))
         (and args
              (string-replace use
                (string-append "{{" (catalog--string (car (car props))) "}}")
                (decide-apropos--quote (car args))))))
      ;; Two slots means deciding which name belongs to which, which is the
      ;; invention this whole design refuses.
      (else #f))))

(define (decide-apropos directive)
  (or (let ((hit (decide-apropos--recipe directive)))
        ;; A recipe answers as itself rather than through --expression, so it
        ;; used to miss the frame wrap: "split the window side by side" is a
        ;; display recipe by the catalog's own account and still ran against
        ;; the chat instead of the frame.
        (and hit (let ((expr (decide-apropos--recipe-expression hit directive)))
                   (and expr
                        (if (decide-apropos--displays? hit)
                            (decide-apropos--frame-wrap expr)
                            expr)))))
      (decide-apropos--by-name directive)
      ;; The catalog had nothing. Rather than refuse, hand the directive and
      ;; the names apropos found for it to the fast model — off the lane, so
      ;; the editor stays live while it writes.
      (and decide-apropos-llm
           (pair? (decide-apropos--llm-vocabulary directive))
           (format "~s" (list 'decide-llm-run! directive)))))

(defcustom 'decide-apropos-floor 6.5
  "The relevance a winning entry has to beat. Under it a directive is refused rather than answered: nonsense reaches the catalog on one common word — \"xyzzy weird thing\" found goto-thing-at-point on \"thing\" — and scores about 5.5, where a directive that means something scores 7 or more. The two are close, so this is a floor and not a margin: it asks whether an answer accounts for what was said, never whether two answers are near each other."
  'group 'decide)

(defcustom 'decide-apropos-margin 0.5
  "How far the ranker's best must lead the runner-up before the model is skipped. The catalog is evidence; the model is only worth asking when the evidence is genuinely tied. Measured: leads of 1.0 and 1.25 were both already correct, and asking laya at that point answered wrong."
  'group 'decide)

(define (decide-apropos--margin directive cands)
  (if (or (null? cands) (null? (cdr cands)))
      99.0
      (let* ((typed (decide-apropos--tokens (decide-apropos--operation-words directive)))
             (words (decide-apropos--alias-words typed))
             (want (if (null? (decide-apropos--target-tokens directive)) 0 1)))
        (- (decide-apropos--relevance (car cands) words typed want)
           (decide-apropos--relevance (car (cdr cands)) words typed want)))))

;; What goes on the model's ballot when the directive named a value. An
;; entry that takes no argument cannot use it, and offering it is how
;; "switch to the Browser Selection and JEV Filtering buffer" came back as
;; (run-command "switch-to-buffer") — the picker, which takes nothing, over
;; switch-to-buffer!, which takes the name and enters its group.
;;
;; This narrows the ballot, not the ranking. The ranking is what answers
;; when the catalog already separated the candidates, and a destructive
;; operation is deliberately reachable only through its command, which takes
;; no argument: filtering the ranking too would have left "kill the scratch
;; buffer" choosing between accessors that do not kill anything.
(define (decide-apropos--ballot cands hits)
  (if (null? hits)
      cands
      (let ((takes (filter (lambda (e)
                             (or (equal? (plist-get e 'kind) "recipe")
                                 (pair? (decide-apropos--params e))))
                           cands)))
        (if (pair? takes) takes cands))))

(define (decide-apropos--by-name directive)
  (let ((cands (decide-apropos--shortlist directive)))
    (and (pair? cands)
         (let* ((by-name (map (lambda (e) (cons (plist-get e 'name) e)) cands))
                (lead (decide-apropos--margin directive cands))
                (ballot (decide-apropos--ballot
                          cands (decide-apropos--state-hits directive)))
                (picked
                 (cond
                   ((null? (cdr cands)) (list (plist-get (car cands) 'name) 1.0 0))
                   ;; The catalog already separated them. Asking a model to
                   ;; re-decide costs a quarter of a second and, for buffer
                   ;; against window, answers wrong at 0.099 confidence.
                   ((>= lead decide-apropos-margin)
                    (list (plist-get (car cands) 'name) 1.0 0))
                   ((null? (cdr ballot))
                    (list (plist-get (car ballot) 'name) 1.0 0))
                   (else (decide-apropos--choose
                           decide-apropos-instructions
                           (decide-apropos--criteria ballot)
                           directive))))
                ;; An unconfident model does not get a veto: it defers to the
                ;; ranking rather than answering nothing at all.
                (row (or (and picked (assoc (car picked) by-name))
                         (cons (plist-get (car cands) 'name) (car cands)))))
           (and row (decide-apropos--expression (cdr row) directive))))))

;; decide-apropos answers the expression; this runs it. They stay apart so a
;; caller can see what would happen before anything does.
(define (decide-run directive)
  (let ((expr (decide-apropos directive)))
    (cond
      ((not expr)
       (message "decide: no operation fits that directive")
       #f)
      ;; Generated source is read before it is run. scheme-read answers #f
      ;; for anything that does not parse and costs nothing, so a call that
      ;; came out malformed is reported as text instead of raising from
      ;; inside the evaluator.
      ((not (scheme-read expr))
       (message (string-append expr " — will not read"))
       (list 'expr expr 'result (list 'error "will not read")))
      (else
        (let ((r (eval-string-safe expr)))
          (message (string-append expr
                     (if (equal? (car r) 'ok) " — ok" (string-append " — " (car (cdr r))))))
          (list 'expr expr 'result r))))))

(define-command "decide-do" "Run a directive: apropos finds it, decide picks it"
  (lambda ()
    (minibuffer-read "Directive: " '()
      (lambda (text) (unless (equal? text "") (decide-run text))))))

;; ── Catalog ───────────────────────────────────────────────

(category! 'decide)
(public! 'decide-apropos
  "(decide-apropos DIRECTIVE) — the expression a directive means, as a string, or #f. Runs nothing.")
(public! 'decide-run
  "(decide-run DIRECTIVE) — pick the operation with decide and evaluate it; (expr STR result (ok VAL)) or #f.")

;; ── Warm ──────────────────────────────────────────────────
;; Indexing 33,000 paths takes about three seconds, and the first directive
;; that names a file should not be the one to pay it. It runs in a task, so
;; the lane is free and the editor is usable while it builds; a directive
;; that arrives first gets the scan and the right answer anyway.

(effects! '(read))

(task-spawn (lambda () (decide-apropos--state-index 'file)))

;; ── The fast model, when the catalog has nothing ───────────────
;; The catalog answers almost everything, and it answers in milliseconds.
;; When it answers nothing, the directive was refused outright — the model
;; was never asked, because the model is only consulted to break a tie
;; between candidates and a miss has no candidates to tie. So "layout 3
;; cols" came back as "nothing in the catalog answers that" while
;; window-layout-columns sat in the catalog with "Show three equal columns"
;; for its doc.
;;
;; This runs off the lane. A completion is a second or more, and the ! path
;; is called from the chat prompt, so blocking here would stop every buffer
;; and every keystroke in the editor until the model replied. The expression
;; the resolver answers is therefore the call that starts the work, not its
;; result.

(effects! '(read external execute spend))

(defcustom 'decide-apropos-llm #t
  "Ask the fast model to write the call when the catalog answers nothing. The model named is llm-models!'s fast preset, so one table moves it."
  'group 'decide)

(defcustom 'decide-apropos-llm-vocabulary 24
  "How many catalog entries the model is shown. It may use these names and no others, so this is the whole vocabulary it writes in."
  'group 'decide)

(define (decide-apropos--llm-vocabulary directive)
  (let* ((typed (decide-apropos--tokens
                  (decide-apropos--operation-words directive)))
         (words (decide-apropos--alias-words typed)))
    (take-n (decide-apropos--recall words) decide-apropos-llm-vocabulary)))

(define (decide-apropos--llm-prompt directive vocab)
  (string-append
    "You write one expression in compos Scheme, the language an editor is\n"
    "scripted in. It is not Emacs Lisp and not any other Scheme.\n\n"
    "Use only the names below. Inventing one produces an unbound variable,\n"
    "which is worse than answering nothing.\n\n"
    (string-join
      (map (lambda (e)
             (string-append "  "
               (or (plist-get e 'sig) (plist-get e 'signature)
                   (string-append "(" (plist-get e 'name) ")"))
               "  " (or (plist-get e 'doc) "")))
           vocab)
      "\n")
    "\n\nA command is called as (run-command \"name\").\n"
    "Answer with the expression alone: no prose, no code fence, no\n"
    "explanation. Answer the single word NONE if none of these names does\n"
    "what was asked.\n\nThe request: " directive))

;; Special forms are not variables, so boundp answers #f for every one of
;; them. They are listed rather than guessed at: a name that is neither
;; bound nor on this list is a name the model invented.
(define decide-apropos-special-forms
  '(begin let let* letrec lambda if cond case when unless and or not
    quote quasiquote set! define do while))

(define (decide-apropos--known? sym)
  (or (boundp sym) (member sym decide-apropos-special-forms) #f))

;; Every call in the form, not only the outermost one. Checking the head
;; alone passed (begin (split-window-right) …) — begin is real and
;; split-window-right is not, and the editor would have raised on it after
;; the split had already happened.
(define (decide-apropos--unknown-names form)
  (cond
    ((not (pair? form)) '())
    ((equal? (car form) 'quote) '())
    (else
      (let* ((head (car form))
             (here (if (and (symbol? head) (not (decide-apropos--known? head)))
                       (list head)
                       '())))
        (let loop ((xs (cdr form)) (acc here))
          (if (not (pair? xs))
              acc
              (loop (cdr xs)
                    (append acc (decide-apropos--unknown-names (car xs))))))))))

;; What came back, if it is one form that reads and calls only real names.
(define (decide-apropos--llm-accept text vocab)
  (and (string? text)
       (let* ((s (string-trim text))
              (forms (and (> (string-length s) 0) (scheme-read s))))
         (and (pair? forms)
              (pair? (car forms))
              (let* ((form (car forms))
                     (unknown (decide-apropos--unknown-names form)))
                (if (null? unknown)
                    (format "~s" form)
                    (list 'unknown unknown)))))))

(define (decide-apropos--llm directive k)
  (let* ((vocab (decide-apropos--llm-vocabulary directive))
         (model (decide--fast-model)))
    (if (null? vocab)
        (k #f)
        (llm-with-model (decide-apropos--llm-prompt directive vocab) model
          (lambda (text) (k (decide-apropos--llm-accept text vocab)))))))

;; The expression a miss answers with: start the model, run what it writes.
;; Nothing runs until the reply has read and its head has been found in the
;; session, so a name the model invented stops here and is reported.
(define (decide-llm-run! directive)
  (message (string-append "fast: asking " (decide--fast-model) "…"))
  (decide-apropos--llm directive
    (lambda (code)
      (cond
        ((not code)
         (message (string-append "fast: nothing answers \"" directive "\"")))
        ;; A name the model invented is named back. Running the form to find
        ;; out would have run whatever came before the invented call first.
        ((pair? code)
         (message (string-append "fast: no such name: "
                    (string-join (map symbol->string (car (cdr code))) ", "))))
        (else
          (let ((r (eval-string-safe code)))
            (message (string-append code
                       (if (equal? (car r) 'ok)
                           " — ok"
                           (string-append " — " (car (cdr r))))))))))))

(effects! '(read))

(category! 'decide)
(public! 'decide-llm-run!
  "(decide-llm-run! DIRECTIVE) — ask the fast model to write the call and run it; off the lane, reports in the echo area")
