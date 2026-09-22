;;; fast-code-test.scm --- resolving prose to one precise call.
;;;
;;; The command palette and a ! at the chat prompt both arrive here. The
;;; catalog decides; a model is asked only when the ranking is genuinely
;;; tied, because laya answered buffer-vs-window wrong at 0.099 confidence
;;; and jev is a network round trip.

(domain! 'testing)
(effects! '(read))

(deftest 'the-catalog-decides-before-any-model
  "a buffer and a window are different things, and the catalog says so"
  (lambda ()
    (let ((code (plist-get (fast-plan "move this buffer right") 'code)))
      (check-equal! code
                    "(with-frame-windows (lambda () (run-command \"buffer-right\")))"
                    "the noun the user typed beats the one an alias added, and a
                     call that moves a window runs against the frame"))))

(deftest 'a-theme-resolves-by-name-or-by-its-own-background
  "light and dark are in the registry, not in any name"
  (lambda ()
    (check-equal! (plist-get (fast-plan "switch to paperized theme") 'code)
                  "(load-theme \"paperized\")"
                  "an exact name wins")
    (check-false! (fast-theme-for "move this buffer right")
                  "an intent about neither a theme nor a theme name is not a theme switch")
    (let ((light (fast-narrow "light theme")))
      (check-true! (pair? light) "light narrows to more than one theme")
      (check-false! (pair? (filter fast-theme-dark? light))
                    "and every theme it offers really is light")
      (check-true! (string-prefix? "(minibuffer-read"
                                   (fast-chat-code "!light theme"))
                   "so it asks, rather than printing four names to retype"))
    (let ((dark (fast-theme-for "dark theme")))
      (check-equal! (car dark) 'one "dark names one theme outright")
      (check-true! (fast-theme-dark? (cadr dark)) "and that theme really is dark"))))

(deftest 'generated-code-is-written-not-concatenated
  "a quote in the intent must not produce source that will not read"
  (lambda ()
    (let ((code (fast-chat-code "!xyzzy \"weird\" thing")))
      (check-true! (chat-scheme-well-formed? code)
                   "an intent carrying a quote still reads, quotes and all")
      (check-true! (or (string-prefix? "(error" code)
                       (string-prefix? "(decide-llm-run!" code))
                   "and a miss either says so or hands the intent on"))))
