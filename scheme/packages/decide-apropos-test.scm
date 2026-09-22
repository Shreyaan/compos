;;; decide-apropos-test.scm --- gather the state, then write the call.
;;;
;;; The catalog holds verbs. An argument is a live value no catalog entry
;;; names — a theme, an open buffer, a path, a setting — so resolving a
;;; directive runs in two stages: settle what state it names, then choose
;;; the verb that can take it, then write the call. Nothing here reaches a
;;; backend; every case below is decided by the catalog alone.

(domain! 'testing)
(effects! '(read))

(deftest 'a-space-name-is-not-a-value-in-that-space
  "the word buffer named the space and matched 6,676 files that carry it"
  (lambda ()
    (check-false! (pair? (decide-apropos--state-hits "move this buffer right"))
                  "buffer-right takes no argument and none was found")
    (check-false! (pair? (decide-apropos--state-hits "split the window"))
                  "window is a space word too")))

(deftest 'the-longest-word-that-lands-wins-across-every-space
  "switch matched a hundred commands and theme matched a dozen files"
  (lambda ()
    (check-equal! (decide-apropos--state-hits "switch to the paperized theme")
                  '((theme ("paperized")))
                  "paperized is longer than switch, so only the theme space survives")
    (check-equal! (decide-apropos--state-hits "load theme brut")
                  '((theme ("brut")))
                  "and a short name still wins when nothing longer lands")))

(deftest 'a-word-spent-on-state-is-not-evidence-for-the-verb
  "dark named compos-dark and then scored theme-dark? as the operation"
  (lambda ()
    (let ((top (car (decide-apropos--shortlist "switch to a dark theme"))))
      (check-equal! (plist-get top 'name) "load-theme"
                    "the verb takes an argument because the directive named one"))))

(deftest 'an-argument-settles-without-a-model-when-one-space-answers
  "one space, one name: there is nothing left to decide"
  (lambda ()
    (let ((e (car (decide-apropos--shortlist "switch to a dark theme"))))
      (check-equal! (decide-apropos--fill (decide-apropos--params e)
                                          "switch to a dark theme" e)
                    '("compos-dark")
                    "the state was gathered before the call was written"))))

(deftest 'generated-source-is-read-before-it-is-run
  "scheme-read costs nothing and rejects what will not parse"
  (lambda ()
    (check-true! (and (scheme-read "(load-theme \"paper\")") #t)
                 "a well-formed call reads")
    (check-false! (scheme-read "(load-theme \"paper\"")
                  "an unbalanced one does not")))

(deftest 'a-whole-file-name-is-looked-up-not-scanned-for
  "33,000 paths cost 400ms to scan and 0ms to look up"
  (lambda ()
    (let ((hits (decide-apropos--state-hits "open fast-code.scm")))
      (check-true! (pair? hits) "a named token finds its file")
      (check-true! (let loop ((rs hits))
                     (cond ((null? rs) #f)
                           ((equal? (car (car rs)) 'file) #t)
                           (else (loop (cdr rs)))))
                   "and the file space is one of the spaces that answered"))))

(deftest 'the-best-entry-per-name-survives-the-ballot
  "load-theme is both a command and a function, and only one carries NAME"
  (lambda ()
    (let* ((cands (decide-apropos--shortlist "switch to a dark theme"))
           (names (map (lambda (e) (plist-get e 'name)) cands)))
      (check-equal! (length names) (length (decide-apropos--distinct names))
                    "a name appears once on the ballot")
      (check-true! (pair? (decide-apropos--params (car cands)))
                   "and the entry kept is the one that takes the argument"))))

(deftest 'a-name-the-caller-typed-is-never-ambiguous
  "tokyo-night and paper-night both hold night; only one holds tokyo too"
  (lambda ()
    (check-equal! (decide-apropos--state-hits "tokyo night theme")
                  '((theme ("tokyo-night")))
                  "the name accounting for more of the intent wins the tie")
    (check-equal! (decide-apropos--state-hits "paper night theme")
                  '((theme ("paper-night")))
                  "and the same rule answers the other way round")
    (check-equal! (fast-chat-code "!tokyo night theme")
                  "(load-theme \"tokyo-night\")"
                  "so the chat prompt resolves it instead of asking")))

(deftest 'a-call-that-moves-what-you-see-runs-against-the-frame
  "eval from a chat has the chat as its current buffer, not the frame's"
  (lambda ()
    (check-true! (string-prefix? "(with-frame-windows"
                                 (decide-apropos "split the window side by side"))
                 "a display recipe is wrapped")
    (check-true! (string-prefix? "(with-frame-windows"
                                 (decide-apropos "move this buffer right"))
                 "and so is a display command")
    (check-false! (string-prefix? "(with-frame-windows"
                                  (decide-apropos "load theme crt"))
                  "an operation that moves no window is left alone")))

(deftest 'the-ballot-holds-only-what-can-take-the-argument
  "the picker takes nothing, so it cannot be what naming a buffer meant"
  (lambda ()
    (let* ((d "switch to the Browser Selection and JEV Filtering buffer")
           (cands (decide-apropos--shortlist d))
           (ballot (decide-apropos--ballot cands (decide-apropos--state-hits d))))
      (check-true! (pair? ballot) "something can take it")
      (check-false! (pair? (filter (lambda (e)
                                     (and (not (equal? (plist-get e 'kind) "recipe"))
                                          (null? (decide-apropos--params e))))
                                   ballot))
                    "and nothing on the ballot takes no argument"))
    ;; the ranking is not narrowed: a destructive operation is reachable
    ;; only through its command, which takes nothing
    (check-equal! (decide-apropos "kill the scratch buffer")
                  "(buffer-kill! \"*scratch*\")"
                  "and the buffer the directive named is what gets killed")))

(deftest 'an-answer-has-to-account-for-what-was-said
  "nonsense still lands somewhere; a floor is what keeps it from answering"
  (lambda ()
    (check-false! (decide-apropos--by-name "xyzzy weird thing")
                  "goto-thing-at-point is not what that meant")
    (check-equal! (decide-apropos "xyzzy weird thing")
                  "(decide-llm-run! \"xyzzy weird thing\")"
                  "the catalog refusing hands off rather than ending it")
    (check-false! (decide-apropos "asdf qwerty")
                  "but with no vocabulary to offer there is nothing to hand off")
    (check-equal! (decide-apropos "switch to a dark theme")
                  "(load-theme \"compos-dark\")"
                  "while a directive that means something clears the floor")))

(deftest 'an-exact-name-wins-but-does-not-outrank-coverage
  "paper is a theme, and so is paper-night"
  (lambda ()
    (check-equal! (decide-apropos--state-hits "switch to paper")
                  '((theme ("paper")))
                  "the word that is the name beats the names containing it")
    (check-equal! (decide-apropos--state-hits "paper night theme")
                  '((theme ("paper-night")))
                  "but a name covering more of the intent still wins")))

(deftest 'nothing-the-model-invented-is-ever-run
  "checking the outermost head alone let an invented call through"
  (lambda ()
    (check-equal! (decide-apropos--llm-accept
                    "(begin (split-window! 'h 0.5) (display-buffer-other-window! \"x\"))" '())
                  "(begin (split-window! (quote h) 0.5) (display-buffer-other-window! \"x\"))"
                  "a form whose every call is real is kept")
    (check-equal! (decide-apropos--llm-accept
                    "(begin (split-window-right) (window-preview-buffer! \"x\"))" '())
                  '(unknown (split-window-right))
                  "and one invented name inside a real begin is named back")
    (check-false! (decide-apropos--llm-accept "NONE" '())
                  "the model saying it cannot is not a form")
    (check-false! (decide-apropos--llm-accept "(load-theme \"paper\"" '())
                  "and neither is source that will not read")))

(deftest 'an-operation-that-takes-nothing-is-not-taxed-for-it
  "target-tokens answers every word when no path is named"
  (lambda ()
    (check-equal! (decide-apropos "layout columns")
                  "(with-frame-windows (lambda () (run-command \"window-layout-columns\")))"
                  "a command whose doc is the directive wins, arity zero and all")))

(deftest 'a-recipe-is-what-apropos-ranked-first
  "the catalog's own ranking decides, so a wrong answer is an entry to fix"
  (lambda ()
    (check-equal! (plist-get (decide-apropos--recipe "maximize buffer") 'name)
                  "one window again"
                  "maximize is in no recipe name — the aliases are what carry it")
    (check-equal! (plist-get (decide-apropos--recipe "one window") 'name)
                  "one window again"
                  "and a word the scorer would call filler needs no special rule")
    (check-equal! (plist-get (decide-apropos--recipe "kill the scratch buffer") 'name)
                  "kill a buffer"
                  "and the recipe the catalog gained is what answers for kill")))
