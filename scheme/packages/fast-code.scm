;;; fast-code.scm --- fast System-1: decompose -> apropos// -> combine -> fail
;;; Entry point: the command palette. Anything the palette cannot resolve
;;; to a command, bind or recipe is natural language and goes to fast-code.

(domain! 'fast-code)
(effects! '(read write external execute))

(define (fast-now-ms) (monotonic-ms))

(define (fast-drop lst n)
  (if (or (null? lst) (<= n 0)) lst (fast-drop (cdr lst) (- n 1))))

;; Themes are named data, not commands, so apropos can never resolve one:
;; the intent has to name it. An exact word wins; a single partial match
;; wins; more than one is ambiguous and says which.
;; A theme is light or dark by its own default background — the rule
;; theme-dark? applies to the live theme, read from the registry instead.
;; The test fixtures carry no default face, so requiring one drops them.
(define (fast-theme-bg name)
  (let* ((entry (assoc name *themes*))
         (spec (and entry (cadr entry)))
         (def (and spec (assoc 'default spec)))
         (bg (and def (plist-get (cdr def) 'bg))))
    (and (string? bg) (re-match "^#[0-9A-Fa-f]{6}$" bg) bg)))

(define (fast-theme-dark? name)
  (let ((bg (fast-theme-bg name)))
    (and bg (< (+ (* (theme--hex-byte bg 1) 299)
                  (* (theme--hex-byte bg 3) 587)
                  (* (theme--hex-byte bg 5) 114))
               128000))))

(define (fast-theme-names) (filter fast-theme-bg (map car *themes*)))

;; Theme names are values, not definitions, so apropos can never reach them:
;; it finds load-theme and stops. The intent has to name one, describe one,
;; or be told which ones it could mean.
;; Theme names are values, not definitions, so apropos can never reach them.
;; Matching them is the state layer's job and not a second one kept here:
;; this file scored a name by whether any intent word appeared in it at all,
;; so "tokyo night theme" tied tokyo-night with paper-night and asked which
;; theme was meant, about a theme the caller had just named. The state layer
;; ranks by how much of the intent a name accounts for, and answers one.
;;
;; Light and dark are not names. No theme is called "light", so that reading
;; is the theme's own background, and it stays here.
(define (fast-theme-for intent)
  (let* ((ws (apropos-query-words intent))
         (names (fast-theme-names))
         (row (assq 'theme (decide-apropos--state-hits intent)))
         (hits (if row (filter (lambda (n) (member n names)) (car (cdr row))) '()))
         (shade (cond ((member "dark" ws) (filter fast-theme-dark? names))
                      ((member "light" ws)
                       (filter (lambda (n) (not (fast-theme-dark? n))) names))
                      (else '()))))
    (cond
      ((pair? hits) (if (null? (cdr hits)) (list 'one (car hits)) (list 'many hits)))
      ;; only when the intent says it is about a theme, so "paper over the
      ;; cracks" is not a switch
      ((not (member "theme" ws)) #f)
      ((pair? shade) (if (null? (cdr shade)) (list 'one (car shade)) (list 'many shade)))
      (else #f))))

;; the names an intent narrows to when it does not narrow to one
(define (fast-narrow intent)
  (let ((t (fast-theme-for intent)))
    (and t (equal? (car t) 'many) (cadr t))))

(define fast-log-path "/Users/svs/.compos/fast-code-log.jsonl")

(define (fast-append-log! entry)
  (ignore-errors (lambda ()
    (let ((prev (ignore-errors (lambda () (read-file fast-log-path)))))
      (write-file! fast-log-path (string-append (if (string? prev) prev "") (json-encode entry #f) "\n"))))))

;; Resolve an intent to Scheme without running it. The ! path wants the
;; code, not the effect: the chat REPL runs it and reports it.
;; Resolve an intent to Scheme without running it. The catalog decides and
;; the model is not on this path: laya answers buffer-vs-window wrong at 0.099
;; confidence and costs seconds, and jev is not installed here. When the
;; ranking is genuinely tied we hand the ballot back instead — the palette is
;; a better disambiguator than a model, and it is free.
(define (fast-plan intent)
  (let* ((t0 (fast-now-ms))
         (theme (fast-theme-for intent))
         (done (lambda (r) (append r (list 'intent intent 'plan-ms (- (fast-now-ms) t0))))))
    (cond
      ((and theme (equal? (car theme) 'one))
       (done (list 'ok #t 'names (list "load-theme")
                   'code (format "~s" (list 'load-theme (car (cdr theme)))))))
      ;; Narrowed to a few and not to one: ask. No theme is called "light",
      ;; so "light theme" is four themes by their own backgrounds and there
      ;; is no name to prefer among them. Listing them in a refusal made the
      ;; caller retype one of four names the editor had just printed.
      ((and theme (equal? (car theme) 'many))
       (done (list 'ok #t 'choices (car (cdr theme))
                   'code (decide-apropos--ask "Theme: " (car (cdr theme))
                                              'load-theme #f))))
      (else
        ;; decide-apropos owns the recipe, the margin, the ballot and the
        ;; frame wrap. This kept a second, stricter copy of the margin gate,
        ;; so a ! input refused as "too close to call" the very intent that
        ;; decide-apropos resolves — and the recipe branch it kept of its own
        ;; missed the frame wrap, so a split ran against the chat.
        (let ((code (ignore-errors (lambda () (decide-apropos intent)))))
          (if code
              (done (list 'ok #t 'code code))
              (let* ((cands (ignore-errors
                              (lambda () (decide-apropos--shortlist intent))))
                     (names (if (pair? cands)
                                (map (lambda (e) (plist-get e 'name)) cands)
                                '())))
                (done (list 'ok #f 'names names 'choices names
                            'reason (if (null? names)
                                        "nothing in the catalog answers that"
                                        (string-append (car names)
                                          " needs an argument the intent does not name")))))))))))

;; A chat input that opens with ! is prose for fast-code: it resolves to
;; Scheme here, runs here through the same REPL path a parenthesised input
;; takes, spends no turn, and the model never sees it.
(define (fast-chat-input? text)
  (and fast-enabled? (string-prefix? "!" text)))

(define (fast-bare-intent text)
  (string-trim (substring text 1 (string-length text))))

;; A miss resolves to an expression that says so, so the transcript reports
;; it the way it reports any other failed form.
(define (fast-chat-code text)
  (let* ((intent (fast-bare-intent text))
         (plan (fast-plan intent))
         (code (plist-get plan 'code)))
    (fast-append-log! (list 'source "chat-bang" 'intent intent
                            'names (plist-get plan 'names)
                            'lead (plist-get plan 'lead)
                            'resolved (if code #t #f)
                            'total-ms (plist-get plan 'plan-ms)))
    (or code
        ;; built as a list and written with ~s: the reason carries theme names
        ;; and the intent carries whatever the user typed, quotes included,
        ;; and the writer quotes them correctly instead of a hand-rolled strip
        (format "~s" (list 'error (string-append "fast: "
                                                 (or (plist-get plan 'reason) "no hit")
                                                 " — " intent))))))

(define (fast-eval intent)
  (let* ((t0 (fast-now-ms))
         (plan (fast-plan intent))
         (code (plist-get plan 'code))
         (eval-ok #f) (eval-err ""))
    (when code
      (if (ignore-errors (lambda () (eval-string code)))
          (set! eval-ok #t)
          (set! eval-err "eval failed")))
    (let* ((total-ms (- (fast-now-ms) t0))
           (reward (if eval-ok (- 1.0 (/ total-ms 1000.0)) (- 0.0 (/ total-ms 1000.0))))
           (out (list 'intent intent 'names (plist-get plan 'names)
                      'lead (plist-get plan 'lead) 'code code
                      'reason (plist-get plan 'reason)
                      'choices (plist-get plan 'choices)
                      'eval-ok eval-ok 'eval-err eval-err
                      'total-ms total-ms 'reward reward)))
      ;; every resolution is a labelled example: intent, ballot, what was
      ;; chosen, and whether it ran
      (fast-append-log! (cons 'source (cons "palette" out)))
      out)))

;; --- Router (parked): the palette is the entry point, so nothing
;; classifies chat messages yet. fast-enabled? gates the fallthrough.
(define fast-enabled? #t)






;; The originals live under symbols this file never re-defines, so a reload
;; of fast-code cannot wrap the wrapper.
(define (fast-palette-installed?)
  (and (boundp 'fast--palette-orig-run) (symbol-value 'fast--palette-orig-run) #t))

;; What the palette already resolves runs as before. Everything else is
;; natural language -> fast-code. No classifier, so no classification problem.
(define (fast-palette-known? choice)
  (or (command-fn choice)
      (command-palette--bind-parse choice)
      (assoc choice *recipes*)))

(define (fast-palette-eval! intent)
  (let* ((r (fast-eval intent))
         (c (plist-get r 'combined)))
    (message (format "fast ~a ms ~a  ~a"
                     (plist-get r 'total-ms)
                     (if (plist-get r 'eval-ok) "ok" "fail")
                     (or (plist-get c 'code) (plist-get c 'reason) "")))
    r))

;; A query that narrows to a handful of names offers them as rows: the
;; palette is where you choose. Picking one re-enters fast-code as an exact
;; name, so no extra dispatch is needed. This runs on every keystroke, so it
;; reads the registry and never calls apropos.
(define (fast-palette-rows query)
  (let ((narrowed (ignore-errors (lambda () (fast-narrow query)))))
    (if (pair? narrowed)
        (map (lambda (n) (list n "fast  narrowed from your words")) narrowed)
        (list (list query "fast  natural language -> scheme")))))

(define (fast-palette-install!)
  (if (fast-palette-installed?)
      "palette -> fast-code already installed"
      (let ((orig-run command-palette--run)
            (orig-cands command-palette-candidates))
        (set-symbol-value! 'fast--palette-orig-run orig-run)
        (set-symbol-value! 'fast--palette-orig-candidates orig-cands)
        ;; a palette action acts on the frame the user is looking at, not on
        ;; whatever context happens to be evaluating. The recipe branch evals
        ;; its source bare, so "one window again" driven from a chat moved
        ;; nothing at all; fast-code's own path already wraps what it writes.
        (set! command-palette--run
              (lambda (choice)
                (if (fast-palette-known? choice)
                    (with-frame-windows (lambda () (orig-run choice)))
                    (fast-palette-eval! choice))))
        ;; free text is always selectable, so RET on an unmatched query lands here
        (set! command-palette-candidates
              (lambda (query)
                (let ((base (orig-cands query)))
                  (if (equal? (string-trim query) "")
                      base
                      (append base (fast-palette-rows query))))))
        "palette -> fast-code installed")))

(define (fast-palette-remove!)
  (if (not (fast-palette-installed?))
      "palette -> fast-code not installed"
      (begin
        (set! command-palette--run (symbol-value 'fast--palette-orig-run))
        (set! command-palette-candidates (symbol-value 'fast--palette-orig-candidates))
        (set-symbol-value! 'fast--palette-orig-run #f)
        "palette -> fast-code removed")))

(define-command "fast-code" "Decompose -> apropos// -> combine -> fail"
  (lambda ()
    (minibuffer-read "Fast intent: " '()
      (lambda (intent)
        (let ((r (fast-eval intent)))
          (message (format "fast-code ~a ms reward ~a ~a" (plist-get r 'total-ms) (plist-get r 'reward) (if (plist-get r 'eval-ok) "ok" (plist-get r 'eval-err))))
          (when (plist-get (plist-get r 'combined) 'code)
            (let ((buf "*fast-code*"))
              (buffer-create buf)
              (buffer-replace! buf "" (plist-get (plist-get r 'combined) 'code))
              (display-buffer-other-window! buf))))))))

(define-command "fast-palette-install" "Send unmatched palette input to fast-code" (lambda () (message (fast-palette-install!))))
(define-command "fast-palette-remove" "Restore the plain command palette" (lambda () (message (fast-palette-remove!))))
(define-command "fast-toggle" "Toggle fast" (lambda () (set! fast-enabled? (not fast-enabled?)) (message (if fast-enabled? "fast: on" "fast: off"))))

;;; --- Completion -----------------------------------------------------
;;; ! is ( with a wider namespace. ( completes over bound Scheme names;
;;; ! completes over every recipe in the catalog, so the phrase is chosen
;;; from what exists instead of guessed at from what was typed.

(define (fast-capf-terms text)
  (filter (lambda (t) (not (equal? t "")))
          (string-split (string-downcase text) " ")))

(define (fast-capf-match? terms hay)
  (let ((lower (string-downcase hay)))
    (null? (filter (lambda (t) (not (string-contains? lower t))) terms))))

(define (fast-recipe-entries)
  (filter (lambda (e) (equal? (catalog--get e 'kind) "recipe")) (catalog)))

;;; The popup shows the expression as the doc: what RET will run is the
;;; only thing that separates two recipes with similar words.
(define (fast-capf-row e)
  (let ((name (catalog--get e 'name))
        (use (catalog--get e 'use)))
    (list name "recipe" "symbol" '() ""
          (if (string? use) (list (list "Documentation" use)) '()))))

;;; Aliases match but never display: accepting writes the title, so the
;;; input line ends up naming a recipe that exists.
(define (fast-capf-candidates query)
  (let* ((es (fast-recipe-entries))
         (terms (fast-capf-terms query))
         (lower (string-downcase query))
         (lead (filter (lambda (e)
                         (string-prefix? lower (string-downcase (catalog--get e 'name))))
                       es))
         (led (map (lambda (e) (catalog--get e 'name)) lead))
         (rest (filter (lambda (e)
                         (and (not (member (catalog--get e 'name) led))
                              (fast-capf-match?
                                terms
                                (string-append (catalog--get e 'name) " "
                                               (or (catalog--get e 'aliases) "")))))
                       es)))
    (map fast-capf-row
         (append lead
                 (map caddr
                      (sort (map (lambda (e)
                                   (list (string-byte-length (catalog--get e 'name))
                                         (catalog--get e 'name) e))
                                 rest)))))))

;;; The byte just past the leading !, skipping any space the input carries
;;; before it. #f when this input is not a bang input at all.
(define (fast-capf-start buf)
  (let ((text (buffer-text buf))
        (lim (buffer-size buf)))
    (let loop ((i (chat-input-start buf)))
      (cond ((>= i lim) #f)
            ((equal? (substring-bytes text i (+ i 1)) "!") (+ i 1))
            ((member (substring-bytes text i (+ i 1)) '(" " "\t")) (loop (+ i 1)))
            (else #f)))))

;;; Replaces the whole phrase after the !, not the word before point: a
;;; recipe title is several words, and completing only the last would
;;; leave the line saying something no recipe is called.
(define (fast-chat-capf)
  (let* ((buf (current-buffer))
         (s (and fast-enabled? (fast-capf-start buf)))
         (e (point)))
    (and s (>= e s)
         (let ((cands (fast-capf-candidates (substring-bytes (buffer-text buf) s e))))
           (and (pair? cands) (list s e cands))))))

(category! 'fast-code)
(public! 'fast-eval "(fast-eval INTENT)")
(public! 'fast-plan "(fast-plan INTENT) — resolve to Scheme without running it")
(public! 'fast-chat-input? "(fast-chat-input? TEXT) — #t when a chat input opens with !")
(public! 'fast-chat-code "(fast-chat-code TEXT) — the Scheme a !-input resolves to")
(public! 'fast-chat-capf "(fast-chat-capf) — completion over every recipe for a !-input")
(public! 'fast-decompose "(fast-decompose STR)")
(public! 'fast-apropos-parallel "(fast-apropos-parallel QUERIES)")
(public! 'fast-palette-install! "(fast-palette-install!) — palette input falls through to fast-code")
(public! 'fast-palette-remove! "(fast-palette-remove!) — restore the plain palette")

;; on by default; safe to re-run after a reload
(fast-palette-install!)
