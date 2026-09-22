;;; decide.scm --- unified typed-decision API over JEV, Laya, and LLM backends
;;;
;;; User config sets the chain and the purpose-to-model map:
;;;   (setq! decide-backends '(jev laya haiku))
;;;   (setq! decide-default '((default . haiku) (fast . jev)))
;;;
;;; Then just (decide STATE QUESTIONS).

(domain! 'decide)
(effects! '(read external execute spend))

;; ── Variables ──────────────────────────────────────────────

(defcustom 'decide-backends
  '(jev laya haiku)
  "Backends 'decide' tries in priority order. Set in ai-config.scm."
  'group 'decide)

(defcustom 'decide-default
  '((fast   . jev)
    (coding . "claude-sonnet-4-20250514"))
  "((purpose . backend-or-model-id) ...). No 'default' row: a purpose that names no model leaves the choice to the backend, and the LLM backend takes the session's fast preset from llm-models!. Pinning an id here made every unnamed call pay for a model nobody had chosen."
  'group 'decide)

;; ── Declaration ───────────────────────────────────────────
;; ai-config.scm declares the setup once, the way it registers an MCP
;; server: one form, and no variable is set by hand.
;;
;; Which model a job uses is not decide's business - that is the
;; llm-model-presets table.
;;
;;   (decide-config! '(jev laya))

(define (decide-config! backends)
  (customize-set! 'decide-backends backends)
  (list 'backends decide-backends))

;; Laya runs as a daemon now, and laya.scm owns it: the python, the
;; checkpoints, and the pipe that holds the weights between questions.
;; Nothing about it is configured twice.

;; ── Entry point ───────────────────────────────────────────

;; &rest is this interpreter's spelling of a rest parameter: a dotted
;; (state questions . opts) reads the dot and the name as two more fixed
;; parameters, so every option a caller passed went nowhere.
(define (decide state questions &rest opts)
  (let* ((backend (or (plist-get opts 'backend) 'auto))
         (purpose (plist-get opts 'purpose))
         (purpose-row (and purpose (assq purpose decide-default)))
         (purpose-val (and purpose-row (cdr purpose-row)))
         (model (or (plist-get opts 'model)
                    (and (string? purpose-val) purpose-val)
                    (let ((d (assq 'default decide-default)))
                      (and d (cdr d)))))
         (timeout (or (plist-get opts 'timeout) 30))
         (effective-backend
          (cond ((equal? backend 'auto)
                 (or (and (symbol? purpose-val) purpose-val)
                     (decide--first-live)))
                (else backend)))
         (fn (assq effective-backend
                    (list (list 'jev decide--call-jev)
                          (list 'laya decide--call-laya)
                          (list 'haiku decide--call-haiku)))))
    (unless fn
      (error (string-append "decide: unknown backend " (symbol->string effective-backend))))
    ;; assq answers (BACKEND FN), so the function is the second element:
    ;; cdr here is a list holding it, and calling that is calling a list
    ((cadr fn) state questions model timeout)))

(define (decide--first-live)
  (let loop ((bs decide-backends))
    (cond ((null? bs) 'jev)
          ;; jev lives in a user package, so the adapter is only reachable
          ;; when that package is loaded; unloaded, it would raise here.
          ((equal? (car bs) 'jev)
           (if (boundp 'jev-systemone) 'jev (loop (cdr bs))))
          ((equal? (car bs) 'laya)
           (if (laya-available?) 'laya (loop (cdr bs))))
          ((equal? (car bs) 'haiku)
           (if (llm-key "anthropic") 'haiku (loop (cdr bs))))
          (else (loop (cdr bs))))))

;; ── JEV backend ───────────────────────────────────────────

(define (decide--call-jev state questions model timeout)
  (let* ((t0 (monotonic-ms))
         (reply (jev-systemone state questions))
         (ms (- (monotonic-ms) t0)))
    (if reply
        (let ((usage (or (plist-get reply 'usage) '(0 0))))
          (list 'answers (decide--answers-from-jev reply)
                'usage (list (or (plist-get usage 'input_tokens) 0)
                             (or (plist-get usage 'output_tokens) 0)
                             'jev ms)))
        (list 'answers '() 'usage (list 0 0 'jev ms)))))

;; JEV answers a plist too - (urgent (noul 0.92 ...) other (...)) - so the
;; same pairing the daemon's reply needs applies here. Reading it as an
;; alist called car on the key symbol and raised out of the backend.
(define (decide--answers-from-jev reply)
  (let ((raw (plist-get reply 'answers)))
    (if (pair? raw) (decide--rows raw) '())))

;; ── Laya backend ──────────────────────────────────────────
;; One question over the daemon laya.scm keeps open. The first question
;; of a cold daemon waits for the weights; the rest pay nothing.

(define (decide--call-laya state questions model timeout)
  ;; The model decide carries is a chat model id, because that is what
  ;; decide-default holds. Laya answers from a checkpoint, which is
  ;; laya-model's business, so nothing about a chat model reaches it.
  ;; app-await answers the moment the daemon's continuation fires, so no
  ;; poll interval stands between the reply and the caller. It blocks, so
  ;; it runs inside a task and never on the editor lane.
  (let* ((t0 (monotonic-ms))
         (reply (task-await
                  (task-spawn
                    (lambda ()
                      (app-await (lambda (k) (laya-predict state questions #f k))
                                 timeout)))
                  (* timeout 1000)))
         (ms (- (monotonic-ms) t0)))
    (if (and reply (plist-get reply 'ok))
        (decide--laya->standard (plist-get (plist-get reply 'json) 'result) ms)
        (begin
          (when reply
            (message (string-append "decide: laya - "
                                    (or (plist-get reply 'error) "no answer"))))
          (list 'answers '() 'usage (list 0 0 'laya ms))))))

(define (decide--laya->standard result ms)
  (let ((raw (if (pair? result) (plist-get result 'answers) '()))
        (usage (or (and (pair? result) (plist-get result 'usage)) '(0 0))))
    (list 'answers (decide--rows (if (pair? raw) raw '()))
          'usage (list (or (plist-get usage 'input_tokens) 0)
                       (or (plist-get usage 'output_tokens) 0)
                       'laya ms))))

;; The daemon answers JSON, so one question's answer is a plist pair and
;; not an alist cell: (KEY VALUE KEY VALUE ...) becomes ((KEY VALUE) ...).
(define (decide--rows plist)
  (if (or (null? plist) (null? (cdr plist)))
      '()
      (cons (list (car plist) (decide--normalize (cadr plist)))
            (decide--rows (cddr plist)))))

;; ── Haiku (LLM) backend ───────────────────────────────────

;; The completion arrives as a value, so no scratch buffer stands in for it
;; and no poll waits on a flag. The task carries the block off the lane.
;; The model fallback. It does not pin an id: llm-models! names one model
;; per job, so the fast preset moves every caller at once and no package
;; carries an id of its own. "claude-3-5-haiku-latest" was hard-coded here
;; and in decide-default, which is how a session configured for a different
;; fast model still paid for a model nobody had chosen.
(define (decide--fast-model)
  (or (ignore-errors (lambda () (llm-model-for 'fast)))
      "claude-3-5-haiku-latest"))

(define (decide--call-haiku state questions model timeout)
  (let* ((model-id (or model (decide--fast-model)))
         (prompt (decide--build-prompt state questions))
         (t0 (monotonic-ms))
         (text (task-await
                 (task-spawn
                   (lambda ()
                     (app-await (lambda (k) (llm-with-model prompt model-id k))
                                timeout)))
                 (* timeout 1000)))
         (ms (- (monotonic-ms) t0))
         (reply (if (string? text) (string-trim text) "")))
    (if (> (string-length reply) 0)
        (decide--parse-llm reply questions ms)
        (list 'answers '() 'usage (list 0 0 'haiku ms)))))

(define (decide--build-prompt state questions)
  (let ((qlines
         (string-join
          (map (lambda (pair)
                 (let ((k (car pair)) (spec (cdr pair)))
                   (format "- ~a: ~a (type: ~a, criteria: ~a)"
                           k
                           (or (plist-get spec 'instructions) "")
                           (or (plist-get spec 'type) "")
                           (or (plist-get spec 'criteria) "-"))))
               questions)
          "\n")))
    (string-append
     "Given this situation:\n\n"
     (if (string? state) state (json-encode state #t))
     "\n\nAnswer as a single JSON object with keys matching the questions.
For 'choice use the chosen string, for 'score use the number,
for 'noul use true or false.\n\nQuestions:\n" qlines "\n")))

(define (decide--parse-llm text questions ms)
  (let* ((start (string-index text "{"))
         (end (and start (string-rindex text "}")))
         (json-text (and start end (substring text start (+ end 1))))
         (parsed (and json-text (json-parse json-text))))
    (if (and parsed (pair? parsed))
        (list 'answers
              (map (lambda (pair)
                     (let* ((k (car pair))
                            (spec (cdr pair))
                            (sk (if (symbol? k) k (string->symbol k)))
                            (val (or (plist-get parsed sk)
                                     (plist-get parsed (string->symbol (string-downcase (symbol->string sk)))))))
                       (list k (decide--llm-val val spec))))
                   questions)
              'usage (list 0 0 'haiku ms))
        (list 'answers '() 'usage (list 0 0 'haiku ms)))))

(define (decide--llm-val val spec)
  ;; jev-noul and jev-choice write the type as a string ("noul"), so a
  ;; comparison against the symbol never matched and every LLM answer came
  ;; back #f at confidence 1.0 — a confident wrong answer, not an error.
  (let* ((raw (or (plist-get spec 'type) 'noul))
         (type (if (string? raw) (string->symbol raw) raw)))
    (list 'type raw
          'choice (and (equal? type 'choice) (if (string? val) val ""))
          'score (and (equal? type 'score) (if (number? val) val 0))
          'noul (and (member type '(noul noul?)) (if val 1.0 0.0))
          'confidence 1.0
          'action '(act_probability 1.0))))

;; ── Normalizer ────────────────────────────────────────────

(define (decide--normalize v)
  (if (pair? v)
      (let ((type (or (plist-get v 'type)
                      (and (plist-get v 'choice) 'choice)
                      (and (plist-get v 'score) 'score)
                      'noul)))
        (list 'type type
              'choice (plist-get v 'choice)
              'score (plist-get v 'score)
              'noul (plist-get v 'noul)
              'confidence (or (plist-get v 'confidence) 1.0)
              'action (or (plist-get v 'action) '(act_probability 1.0))))
      v))

;; ── Catalog ───────────────────────────────────────────────

;; ── Questions ─────────────────────────────────────────────────────
;; The three question shapes, owned here rather than by any one backend.
;; Packages used to build them with jev-choice and jev-noul, which binds
;; a caller to a user package that may not be loaded and routes past the
;; backend chain; these read the same and work on every backend.

(effects! '(pure))

(define (decide-noul instructions &optional criteria)
  (if criteria
      (list 'type "noul" 'instructions instructions 'criteria criteria)
      (list 'type "noul" 'instructions instructions)))

(define (decide-choice instructions criteria)
  (list 'type "choice" 'instructions instructions 'criteria criteria))

(define (decide-score instructions criteria)
  (list 'type "score" 'instructions instructions 'criteria criteria))

(effects! '(read external execute))

(category! 'decide)
(effects! '(pure))
(public! 'decide-noul "(decide-noul INSTRUCTIONS [CRITERIA]) — a yes/no question")
(public! 'decide-choice "(decide-choice INSTRUCTIONS CRITERIA) — a pick-one question; criteria is a plist of option -> description")
(public! 'decide-score "(decide-score INSTRUCTIONS CRITERIA) — a rated question; criteria is a list of level descriptions")
(effects! '(read external execute))

(public! 'decide
  "(decide STATE QUESTIONS [OPTS ...]) — typed decisions over JEV, Laya, or LLM. Returns (answers ((KEY VALUE) ...) usage (INPUT OUTPUT BACKEND ELAPSED-MS)).")
(public! 'decide-config!
  "(decide-config! '(BACKEND ...)) — declare the backend chain. Which model a job uses is llm-model-presets, not this.")
(public! 'decide-backends
  "Backends 'decide' tries in order.")
(public! 'decide-default
  "((purpose . backend-or-model) ...) purpose routing.")
