;;; treesit.scm --- install tree-sitter grammars from inside the editor.
;;;
;;; M-x ts-install-grammar clones a grammar repo, compiles its generated
;;; parser with cc, and loads it into the running NIF — no rebuild, no
;;; restart. Installed grammars live in ~/.compos/grammars/ and reload at
;;; boot. Wire a grammar to a mode with (ts-mode "<lang>") — see the
;;; scheme-mode registration below.

(define *ts-known-grammars*
  '(("scheme" "https://github.com/6cdh/tree-sitter-scheme")
    ("python" "https://github.com/tree-sitter/tree-sitter-python")
    ("javascript" "https://github.com/tree-sitter/tree-sitter-javascript")
    ("css" "https://github.com/tree-sitter/tree-sitter-css")
    ("html" "https://github.com/tree-sitter/tree-sitter-html")
    ("elixir" "https://github.com/elixir-lang/tree-sitter-elixir")
    ("heex" "https://github.com/phoenixframework/tree-sitter-heex")
    ("bash" "https://github.com/tree-sitter/tree-sitter-bash")
    ("ruby" "https://github.com/tree-sitter/tree-sitter-ruby")
    ("go" "https://github.com/tree-sitter/tree-sitter-go")
    ("markdown" "https://github.com/tree-sitter-grammars/tree-sitter-markdown")
    ("c" "https://github.com/tree-sitter/tree-sitter-c")))

(define (ts-known-url name)
  (let ((e (assoc name *ts-known-grammars*)))
    (if e
        (car (cdr e))
        (string-append "https://github.com/tree-sitter/tree-sitter-" name))))

(define-command "ts-install-grammar" "Clone, compile, and load a tree-sitter grammar"
  (lambda ()
    (minibuffer-read "Grammar (language name): "
      (map (lambda (e) (list (car e) (car (cdr e)))) *ts-known-grammars*)
      (lambda (name)
        (unless (equal? name "")
          (minibuffer-read
            (string-append "Repo URL (default " (ts-known-url name) "): ") '()
            (lambda (url)
              (ts-install-grammar! name
                (if (equal? url "") (ts-known-url name) url))
              (message (string-append "grammar " name
                                      ": cloning and compiling…")))))))))

(define-command "ts-grammars" "Show loadable tree-sitter languages"
  (lambda ()
    (message (string-append
               "languages: " (string-join (ts-langs) " ")
               "  ·  installed: " (string-join (ts-installed-grammars) " ")))))

;; .scm/.el buffers highlight through the dynamic scheme grammar once
;; installed (M-x ts-install-grammar scheme); until then ts-lang is set
;; but the NIF just returns no spans
(define-mode "scheme-mode" (ts-mode "scheme"))

;; ruby and javascript ride the same dynamic-grammar path; without the
;; grammar the mode still works (and an LSP server still attaches)
(define-mode "ruby-mode" (ts-mode "ruby"))
(define-mode "js-mode" (ts-mode "javascript"))

;; The editor's own surfaces are Elixir, HEEx, HTML and CSS, so those
;; four read structurally too. Two of the names already existed without
;; a mode behind them: lsp.scm registers elixir-ls for "elixir-mode",
;; and browse sets "html-mode" on a page it renders.
(define-mode "css-mode" (ts-mode "css"))
(define-mode "html-mode" (ts-mode "html"))
(define-mode "elixir-mode" (ts-mode "elixir"))
(define-mode "heex-mode" (ts-mode "heex"))

(mode-doc! "ruby-mode"
  "Ruby. Run `M-x ts-install-grammar ruby` to get the colours.")
(mode-doc! "js-mode"
  "JavaScript. Run `M-x ts-install-grammar javascript` to get the colours.")
(mode-doc! "css-mode"
  "CSS. Run `M-x ts-install-grammar css` to get the colours.")
(mode-doc! "html-mode"
  "HTML. Run `M-x ts-install-grammar html` to get the colours.")
(mode-doc! "elixir-mode"
  "Elixir. Run `M-x ts-install-grammar elixir` to get the colours.")
(mode-doc! "heex-mode"
  "HEEx: the Phoenix template language. Run `M-x ts-install-grammar heex` to get the colours.")

(set! *auto-mode-alist*
  (append *auto-mode-alist*
          '((".rb" "ruby-mode")
            (".js" "js-mode") (".mjs" "js-mode") (".jsx" "js-mode")
            (".css" "css-mode")
            (".html" "html-mode") (".htm" "html-mode")
            (".ex" "elixir-mode") (".exs" "elixir-mode")
            (".heex" "heex-mode"))))

(mode-doc! "scheme-mode"
  "Scheme: the language the editor is written in. `C-M-f` and `C-M-b` step over forms, and `M-g i` lists the definitions. Run `M-x ts-install-grammar scheme` to get the colours.")

(category! 'syntax)
(public! 'ts-install-grammar! "(ts-install-grammar! NAME URL) — async grammar install")

;; ComposML ships its parser through the bundled-grammar loader.
(domain! 'syntax)
(effects! '(write display))
(define-mode "composml-mode" (ts-mode "composml"))
(mode-doc! "composml-mode"
  "Edit semantic ComposML documents with the bundled grammar. Structural navigation and queries use semantic element names.")
(set! *auto-mode-alist*
  (cons '(".composml" "composml-mode")
        (remove (lambda (entry) (equal? (car entry) ".composml")) *auto-mode-alist*)))
