;;; init.scm --- explicit bundled package boot order.
;;;
;;; The Elixir bootstrap loads editor.scm and the small stdlib first, then
;;; evaluates this file. Keep top-level package dependencies visible here. A
;;; compound package entry point loads its focused internal modules.
;;;
;;; (load NAME) searches load-path: priv, the project's scheme/packages, the
;;; config home, and its packages. The loader stamps each file's package and
;;; origin from the file, so a load needs no stamp around it.
;;;
;;; After this file, Session evaluates ~/.compos/ai-config.scm,
;;; ~/.compos/init.scm, and ~/.compos/custom.scm. User packages therefore belong
;;; in ~/.compos/init.scm, for example:
;;;
;;;   (load "my-package.scm")
;;;
;;; The stock boot is the editor. An app the editor does not need ships in
;;; scheme/packages but loads only when the user init names it: amazon,
;;; doom, doom-lite, graphql, linkedin, movie, peers, px0, recording,
;;; spotify, spreadsheet, substack, title, training. The test suite loads
;;; them all (test/test_helper.exs).

(load "advice.scm")
(load "custom.scm")
(load "tools.scm")
(load "recipes.scm")
(load "components.scm")
; the detail window: an app registers how it names a kept detail at load,
; so this comes before every app that opens rows into one
(load "detail.scm")
(load "preview.scm")
(load "file-view.scm")

(load "agenda.scm")
(load "agent.scm")
(load "annotate.scm")
(load "appearance.scm")
(load "autorevert.scm")
(load "bookmark.scm")
(load "register.scm")
(load "chat.scm")
(load "code.scm")
(load "completion.scm")
(load "daemons.scm")
(load "db.scm")
(load "diff-mode.scm")
(load "doppler.scm")
(load "endpoint.scm")
(load "irc.scm")
(load "evil.scm")
(load "feeds.scm")
(load "git.scm")
(load "google.scm")
(load "groups.scm")
(load "help.scm")
(load "http.scm")
(load "ibuffer.scm")
;; the chats table is the ibuffer template over the chats: it loads after it
(load "agent-fleet.scm")
;; the spawn edges are the chats table's other view: it loads after it
(load "subagents.scm")
(load "jj.scm")
(load "keys.scm")
(load "keymaps.scm")
(load "layouts.scm")
(load "lsp.scm")
(load "mcp-hub.scm")
(load "mcp.scm")
(load "models.scm")
(load "whatsapp.scm")
(load "morg/morg-kinds.scm")
(load "morg.scm")
(load "markdown-mode.scm")
(load "cua.scm")
(load "notmuch.scm")
(load "occur.scm")
(load "org.scm")
(load "package.scm")
(load "paredit.scm")
(load "pdf.scm")
(load "project.scm")
(load "messages.scm")
(load "provenance.scm")
(load "scheme-ide.scm")
(load "peek.scm")
(load "scratch.scm")
(load "sentry.scm")
(load "setup.scm")
(load "skills.scm")
(load "prompts.scm")
(load "llm-config.scm")
(load "sockets.scm")
(load "switch.scm")
(load "handheld.scm")
(load "telemetry.scm")
(load "chat-perf.scm")
(load "perf.scm")
(load "profile.scm")
(load "test.scm")
(load "treesit.scm")
(load "web.scm")
(load "web-server.scm")
(load "worktrees.scm")
(load "writing.scm")
(load "dismiss.scm")

;; the run and result blocks live with the other blocks and lean on
;; block.scm; they load here because their kind registrations need the
;; registry, which boots with the packages
(load "editor/blocks/result-block.scm")
(load "editor/blocks/run-block.scm")
(load "editor/blocks/csv-block.scm")
(load "morg/morg-tangle.scm")
(load "morg/morg-show-source.scm")
;; core editor behaviour, not a package: every URL and file path is a
;; link. It reads a buffer's directory (dired.scm), so it loads once the
;; stdlib is in, and it sweeps the buffers that exist by then.
(load "editor/goto-address.scm")
