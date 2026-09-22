# Hooks

A hook is a name and a list of functions. The editor runs a hook at a
seam, and a package puts a function on the hook to act there. Every
hook is Scheme, in `editor.scm`.

## The API

```scheme
(add-hook! 'find-file-hook 'my-package--on-visit)      ; once, first
(add-hook! 'find-file-hook 'my-package--on-visit #t)   ; once, last
(add-hook! 'find-file-hook 'my-package--on-visit #f #t) ; this buffer only
(remove-hook! 'find-file-hook 'my-package--on-visit)
(hook-functions 'find-file-hook)                       ; local, then global
(run-hooks 'find-file-hook 'other-hook)                ; no arguments
(run-hook-with-args 'buffer-renamed-hook old new)
(run-hook-with-args-until-success 'paste-hook kind data)
(run-hook-with-args-until-failure 'may-save-hook buf)
```

Give `add-hook!` the name of a function, quoted. The name is looked up
when the hook runs. A reload that redefines the function changes what
runs, and adding the name again is a no-op, so a package registers at
its top level with no guard. A closure works too, but a closure is a
fresh value after every reload, so it is added again each time the file
loads.

A local hook lives on the current buffer and runs before the global
list. The local table lives in Scheme, keyed by buffer name.

## The hooks the editor runs

| hook | arguments | when |
|------|-----------|------|
| `pre-command-hook` | | before every command and every self-insert |
| `post-command-hook` | | after every command and every self-insert |
| `find-file-hook` | | after the visit command opened a file |
| `before-save-hook`, `after-save-hook` | | around a save |
| `MODE-hook` | | after `set-mode!` ran the mode's setup |
| `frame-attach-hook` | | a client mounted a frame |
| `window-configuration-change-hook` | | a frame's windows or their buffers changed |
| `winner-restore-hook` | | winner-undo or winner-redo put an arrangement back; a package that keeps an arrangement of its own settles on it |
| `window-state-change-hook` | | `window-state-changed!` ran: a window command or a layout moved something; groups.scm recalculates the current group here |
| `theme-change-hook` | | after `load-theme` |
| `buffer-restore-hook` | BUF | a restored buffer, before its mode setup; migrations.scm runs the one-shot migrations here |
| `buffer-created-hook` | NAME | a new buffer has its text |
| `buffer-woken-hook` | NAME | a dormant buffer came back |
| `buffer-renamed-hook` | OLD NEW | `rename-buffer!` |
| `buffer-shown-hook` | BUFFER | the switcher filled a window |
| `fs-change-hook` | ROOT | the watcher saw a change under ROOT |
| `editing-state-hook` | BUF | the buffer entered or left the editing state |
| `llm-config-changed-hook` | BUF | llm-config exited and the buffer's setup changed |
| `group-membership-hook`, `group-kill-hook` | | see docs/groups.md |

### Keyed hooks

A keyed hook holds one function per key. `(add-hook! '(block-click diff)
FN)` puts FN under the key `diff`, and the same key replaces, so a package
reload does not stack a second copy. `(hook-functions 'block-click)` is
the plain list and then every keyed function, newest key first;
`(hook-functions '(block-click diff))` is that one function, so a
dispatcher runs one key or every key with the same `run-hook` call.
`(remove-hook! '(block-click diff))` takes the key away, and
`(hook-keys 'block-click)` names the keys.

| Keyed hook | Key | Args | Who runs it |
|---|---|---|---|
| `block-click` | a mode's name | BUF ID | the first key that answers #t owns the click (components.scm) |
| `preview-link` | the verb of a `compos:VERB/ARG` link | ARG | the verb's one function (preview.scm) |
| `input-intent` | the intent type, such as "formatBold" | FROM TO TEXT | the type's one function; #t means handled (editor.scm) |
| `endpoint-event` | a listener name | NAME KIND TEXT | every key (endpoint.scm) |
| `lsp-event` | a listener name | ID METHOD PARAMS | every key (lsp.scm) |
| `agent-turn-end` | a listener name | SLUG STOP-REASON OK? | every key, each one guarded (agent.scm) |
| `candidate-face` | a package name | CATEGORY NAME | the first face answered, none means no face (groups.scm) |
| `buffer-project-label`, `buffer-project-root`, `buffer-workspace-label` | a package name | BUFFER | the first label answered, none means "" (project.scm, worktrees.scm) |
| `find-file-group-reader` | a package name | RECEIVE | the first reader runs; none means RECEIVE gets the frame's group (project.scm) |
| `buffer-kill-repair` | a package name | NAME | the first thunk answered runs after the kill (groups.scm) |
| `switch-buffer-source` | a package name | CANDIDATES | the first source shapes the switcher's pool (chrome.scm) |
| `app-request` | a package name | BUF METHOD BODY | the first (STATUS BODY) answered owns an app page's `_compos/app` request; none is a 404 (preview.scm, spreadsheet.scm) |

`add-paste-hook!` is not a hook on purpose: it keys a handler by mode and
runs the first that answers.

### Dashboard presentation

`dashboard--sync!` rebuilds presentation only when a window in any frame shows the buffer.
Hidden updates set the transient `dashboard-dirty` local. Repeated updates keep one pending refresh.
The buffer-shown and window-configuration hooks consume that refresh when the buffer appears.
Restore requests a new sync; the dirty flag is not saved in the desktop.
