# Code browser: fly through the codespace

Branch `worktree-codebrowser`, 2026-08-30. Reference: `/Users/svs/src/codescope`
(the first vision) and Linear "Code browser" CB1-CB10.

The product is the understanding of a codebase, not a file tree. The reader
sees a summary at every level: the project, a directory, a file, a
definition, a change. Every summary stays true to the code, and every name
in a summary is one key away from the code it names.

## 1. What codescope did, and what of it exists here

| codescope piece | what it is | compos today |
|---|---|---|
| `Target` + `Git.Watcher` | one target dir, a debounced fs event on PubSub | `project-current`, `watch-path!`, `on-fs-change!` (editor.scm:2170) |
| `/diff` + explain button | live `git diff HEAD`, LLM explanation streamed into a pane | `diff-mode` cards + `define-diff-backend` + fs watch (diff-mode.scm); no explanation |
| `/browse` file view | Monaco, fold bodies, sexp nav, scope tint | `code-browse` (code.scm), tree-sitter or indentation, tint, folds |
| `Docs` `.codescope/*.md` | hand-editable overview, files sorted by `NN-` prefix | nothing; morg-mode is the renderer to use |
| `Docs.autolink/1` | every `path/to/file.ext` in prose is a link, verified on disk | nothing (CB8 still open) |
| `FileDocs` | per-file synopsis cached at `.codescope/files/<rel>.md` | nothing |
| `DirDocs` | per-directory card grid cached at `.codescope/dirs/<rel>.html` | nothing |
| `ChangeExplainer` | one prompt: explain the diff and rewrite the file doc | nothing |
| `Bootstrap` | first run: the agent reads the repo and writes the overview set | nothing |
| LSP jump (planned) | never built | `lsp.scm` M-. through the code.scm seam; `scheme-ide.scm`; `definition-peek` in morg |

codescope kept every summary as a file in the target repo. It regenerated a
summary only on a button. The roadmap wanted hash-keyed auto-regeneration
and never got it. This plan builds the freshness first, because a stale
summary is worse than none.

## 2. What M-. does in a document today

`morg-mode` binds `M-.` to `definition-peek` (morg.scm:691). The command
reads the name at point, calls `(definition-locate NAME)`, and shows the hit
in the other window. `M-.` again goes there. Any other key closes the peek.

`definition-locate` (peek.scm:36) asks one provider: `scheme-ide--find-def`.
So in a document `M-.` works on a Scheme name and on nothing else. An
Elixir function, a Rust struct, a module name, a file path: "No definition
of X".

Source buffers are different. There `M-.` is `code-goto-definition`
(lsp.scm:560): LSP when the buffer has an `lsp-server` local, else a scan of
the same buffer for a defining word. Neither answers for a document.

So the mechanism the user remembers is real and it is the right shape. It
needs providers.

## 3. Design

### 3.1 The scope store

One directory per project holds the summaries: `<root>/.compos/scope/`.

```
.compos/scope/
  project.md            what the project is; worth knowing; how to run
  recent.md             what changed lately (from git log + the working diff)
  dirs/<rel>.md         one per directory: what lives here, one card per entry
  files/<rel>.md        one per file: what it does, why, who calls it, gotchas
  changes/<rel>.md      the explanation of the current working-tree diff of a file
```

Every file is morg. Every file starts with directives:

```
#+scope: file
#+path: apps/compos_core/priv/packages/code.scm
#+source: 9f1c2a...      the git blob sha of the input when the summary was written
#+inputs: a1b2 c3d4      for a dir: the shas of the child summaries it read
#+model: claude-sonnet-5
#+written: 2026-08-30T12:00:00Z
```

`morg-scan` already parses `#+name: value` lines as directives
(morg.scm:48). No new parser.

Why in the repo and not in `~/.compos`: the summaries are documentation.
The user hand-edits them, commits them, and an agent reads them as
context. codescope made the same call. Whether `.compos/scope` is committed
or ignored is the project's choice; the store works either way.

### 3.2 Freshness: content-addressed, lazy, and queued

The input key of a file summary is the git blob sha of the file
(`git ls-files -s` gives every sha in one call; `git hash-object` for an
untracked or modified file). The key of a directory summary is the sorted
list of its children's summary shas plus the entry list. The key of
`project.md` is the root directory summary sha plus `HEAD`. The key of
`changes/<rel>.md` is the sha of the file's working-tree diff text.

A summary is fresh when its `#+source` equals the current key. That is one
comparison, no clock, no mtime.

Three ways a summary refreshes:

1. **On view.** Opening a scope buffer for a stale node queues that node.
   The buffer shows the stale summary with a `stale` badge until the new
   text lands.
2. **On change.** `on-fs-change!` marks the changed files stale and queues
   them if `scope-auto-refresh` is on (default on, with a per-project
   budget: `scope-refresh-budget` calls per hour, default 60). Directory
   and project summaries refresh only after their children settle, so one
   save costs one file call, not a chain.
3. **By hand.** `g` in any scope buffer, `M-x scope-refresh` for a node,
   `M-x scope-bootstrap` for the whole tree.

The queue is one Scheme list with one in-flight job (`scope--queue`,
`scope--running`). A job calls `(llm-for 'summarize PROMPT HANDLER)` for
a file and `(llm-for 'explain ...)` for a change. A directory or the
project uses `llm-with-tools` with the `explain` role, so the agent reads
the files itself, the way codescope's bootstrap did. The role, not the
model, is what the job names; the router (3.6) picks the model, and a
project changes it in `.project.scm`.
The handler writes the morg file, sets `#+source`, and redraws every
scope buffer that shows the node. The queue drops a job whose key changed
while it waited (the file changed again) and re-queues the newest key.

Prompts are the four codescope prompts, moved to `priv/prompts/scope-*.md`
and rewritten to ask for morg: no headings in a file synopsis, a card per
entry in a directory summary, paths inline as `path/to/file.ext`.

### 3.3 Every name is a link: the provider chain

`definition-locate` becomes a chain. A provider is `(NAME KIND) -> (SOURCE-KIND TARGET BYTE-POS)` or `#f`.

```scheme
(define-definition-provider! 'scheme-ide scheme-ide--find-def)   ; exists
(define-definition-provider! 'path      scope--path-locate)      ; new
(define-definition-provider! 'outline   scope--outline-locate)   ; new
(define-definition-provider! 'lsp       lsp--workspace-locate)   ; new
```

- **path**: `apps/x/y.ex`, `y.ex:42`, `lib/foo.ex#L42`. Resolve against the
  document's `default-directory`, then the project root. A hit only when
  the file exists, so a link is never dead (codescope's rule). This is CB8
  done in Scheme, at the point of use, with no HTML pass.
- **outline**: a project-wide name index built from `code-outline` rows
  (LINE KIND NAME DOC) for every tracked source file, cached per blob sha
  in `.compos/scope/index.etf` (or a plain sexp file). Building it opens
  each file in a temporary buffer once; the cache makes the second run
  free. `Elixir.Module.fun`, `Mod.fun/2`, `fun` all resolve.
- **lsp**: `workspace/symbol` when a server is attached for the project.
  One new request wrapper in lsp.scm over `lsp-buffer-request`.

Order: path, scheme-ide, lsp, outline. The first hit wins.
`symbol-at-point` needs one change: a document reads a wider alphabet
(`/`, `.`, `:`, `#`) so a path and a qualified name are one symbol.

`definition-peek` already handles the rest: peek in the other window,
`M-.` again to go, `M-,` back via the marker stack.

### 3.4 The fly surface: `scope-mode`

One list-mode buffer per level, on the list mechanism (docs/LISTS.md):

```
*scope: apps/compos_core/priv/packages*      <- the directory
  code.scm       code-browse: read a source file with structural keys
  lsp.scm        LSP client: diagnostics, definition, references, hover
  peek.scm       look at a definition without going there
  morg/          babel blocks and tangling for morg documents
```

Rows are the entries. The second column is the first line of the entry's
summary (blank plus a `?` badge when none, `stale` badge when stale).

Keys, the code-browse alphabet, so the reader learns one set:

| key | command | does |
|---|---|---|
| `l` / `RET` | `scope-descend` | dir: open its list. file: open the file's outline list. definition: visit the code. |
| `h` | `scope-ascend` | the parent directory's list |
| `j` / `k` | list motion | with a debounced peek of the summary in the other window |
| `d` | `scope-doc` | open the summary morg buffer for the row (read, edit, `M-.` inside it) |
| `c` | `scope-changes` | the diff explanation for the row; a dir shows its changed files |
| `g` | `scope-refresh` | queue this node |
| `G` | `scope-bootstrap` | queue this subtree |
| `/` | list narrowing | exists |

A file's outline level reuses `imenu-rows` (code.scm:1418): rows are
(LINE KIND NAME DOC). `l` there visits the definition with `code-browse`
on. So the descent is: project, directory, file, definition, code. `h` all
the way back. That is the flight.

`M-x scope` opens the project root list. `M-x scope-here` opens the level
of the current buffer's file. Both enter the project's group.

The summary buffers are morg files, so the rendered view, folds, links,
and `M-.` are free. A scope buffer's `d` opens `files/<rel>.md`; a path in
it opens the code; a name in it peeks the definition.

### 3.5 Changes: the diff explains itself

diff-mode has the cards and the watch. Add:

- `e` on a file card: `diff-explain`. The job sends the file's diff, the
  file, and the current `files/<rel>.md` in one prompt (codescope's
  `ChangeExplainer` shape) and gets two sections back: what changed, and
  the updated file doc. The first shows under the card as a folded
  `explanation` block; the second lands in the store as the new synopsis
  and the store marks it fresh. One call updates both.
- `recent.md` regenerates from `git-log` (20) plus the working diff
  summary, keyed on `HEAD` plus the diff sha. This is the "what has the
  agent been doing" page.

### 3.6 The model router

Every LLM call in the editor names a ROLE, never a model id. A role
resolves to a TIER or a model; a tier resolves to a model. One table,
three layers of override.

```scheme
;; packages/models.scm — the global defaults
(define *model-tiers*
  '((fast   "claude-haiku-4-5-20251001")
    (medium "claude-sonnet-5")
    (strong "claude-opus-5")))

(define *model-roles*
  '((summarize fast)       ; a file synopsis, a directory card grid
    (explain   medium)     ; a diff, recent.md, project.md
    (code      strong)     ; code-mode and code-agent-mode edits
    (chat      medium)))   ; the default chat model, today (llm-model)
```

A role value is a tier name or a model id; a tier value is a model id. A
tier can carry an effort: `(strong "claude-opus-5" effort "high")`.

Resolution, `(model-for ROLE [BUF])`, first hit wins:

1. the buffer local `model-<role>` (set by `M-x set-model-role`)
2. the project: `.project.scm` in the root, through the existing
   `project-default!` mechanism (project.scm:64), keys `model-<role>`
   and `model-<tier>`
3. the global tables above (`defcustom`, group `models`)

Then the tier lookup on the same three layers, then
`llm-connector-for-model` (editor.scm:6269) picks the lane. So a project
overrides one role, one tier, or both:

```scheme
;; <root>/.project.scm
(project-models! 'summarize "gpt-5.4-mini"    ; a role to a model
                 'strong    "gpt-5.6-sol"     ; a tier to a model
                 'code      'medium)          ; a role to a tier
```

`project-models!` is sugar over `project-default!` with the `model-`
prefix. The defaults apply as buffer locals to the project's buffers
(`project-defaults-apply!`), so layer 1 and layer 2 are one read.

Callers:

- `(llm-for ROLE PROMPT HANDLER)` = `llm-with-model` (session.ex:1313)
  with the resolved model.
- `llm-with-tools` gains an optional ROLE; it passes the model as the
  seventh `llm-tools` argument (session.ex:1332), which exists.
- `code-model` and `code-agent-model` (code.scm:943, :1181) keep working
  as explicit ids; an empty value means "ask the router for `code`".
- `(llm-model)` stays the `chat` role's answer for the API lane.

`M-x models` is a list: role, tier, model, connector, and which layer
answered. `g` re-reads `.project.scm`. `RET` sets the buffer local.

Tests (`priv/tests/models-test.scm`): resolution order with a fake
project root; a role to a tier to a model; a role to a model directly;
an unknown role errors with the role name; `.project.scm` override wins
over global and loses to the buffer local.

### 3.7 Elixir

None expected. Every mechanism exists: `llm`, `llm-with-model`, `llm-with-tools`,
`git-*` primitives, `shell-command->string`, `watch-path!`, `on-fs-change!`,
`read-file`, `write-file!`, `list-dir`, `code-outline`, `imenu-rows`,
`lsp-buffer-request`, the list mode, morg. The one candidate is a content
hash primitive; `git hash-object --stdin` through the shell covers it.

## 4. Phases

Each phase lands on `worktree-codebrowser` with focused tests only
(`priv/tests/scope-test.scm` and one ExUnit file for the key dispatch
path). No suite runs until the merge.

### P0. The model router

Files: `packages/models.scm` (new), `packages/project.scm`
(`project-models!`), `packages/tools.scm` (ROLE on `llm-with-tools`),
`packages/code.scm` (empty `code-model` asks the router), `init.scm`
(load order: after project.scm, before code.scm).

Accept: `(model-for 'summarize)` answers the global tier; a
`.project.scm` with `(project-models! 'summarize "x")` answers "x" for a
buffer in that root and the global for a buffer outside it;
`M-x set-model-role` wins over both; `M-x models` shows the three layers
and the connector; `llm-for` sends the resolved model.

Tests: `priv/tests/models-test.scm`, pure resolution over fixture tables
and a temporary root with a `.project.scm`.

### P1. Providers: M-. in a document reaches the code

Files: `packages/peek.scm` (chain), `packages/scope.scm` (new: path and
outline providers), `packages/lsp.scm` (workspace/symbol), `editor.scm`
(document symbol alphabet).

Accept: in a morg buffer, `M-.` on `apps/compos_core/priv/packages/code.scm`
peeks the file; on `code.scm:423` peeks line 423; on `code--goto-definition`
peeks the Scheme definition; on `Compos.Core.Git.diff` peeks git.ex; on a
name only elixir-ls knows, the LSP answers when attached. A name that
resolves nowhere says so and opens nothing.

Tests: `definition-locate` per provider with fixture files; the chain
order; the no-hit case; the alphabet.

### P2. The store and freshness

Files: `packages/scope.scm` (store, keys, queue), `priv/prompts/scope-*.md`.

Accept: `(scope-key 'file REL)` equals the blob sha; `(scope-fresh? NODE)`
flips when the file changes; `(scope-refresh! NODE)` writes a morg file
with the directives; a change on disk re-queues the file, not the chain;
the budget stops the queue and says so in the echo area.

Tests: keys from a fixture repo; `#+source` round trip; queue drop and
re-queue; the LLM seam stubbed with a lambda (`*scope-llm*`), so no test
spends.

### P3. `scope-mode`, the fly surface

Files: `packages/scope.scm` (the list modes), `themes.scm` (badges).

Accept: `M-x scope` shows the root; `l`/`h` walk the tree; a file row
descends to its outline; an outline row visits the definition with
`code-browse` on; `j`/`k` peek the summary; `d` opens the morg summary;
`g` queues; everything survives a restart (the list rebuilds from
`'scope-node` local).

Tests: through `KeyDispatch.handle_key/1` with dummy bindings under `<f9>`
(never the production keys); the restore path.

### P4. Changes

Files: `packages/diff-mode.scm` (explain block, `e`), `packages/scope.scm`
(`recent.md`, `changes/`).

Accept: `e` on a card shows the explanation under it and updates the file
synopsis in one call; `recent.md` regenerates when `HEAD` moves.

### P5. Bootstrap and the project page

`M-x scope-bootstrap` on an empty store: files first (bounded by the
budget, largest directories last), then directories, then `project.md`.
Progress in the modeline of the scope buffer. `project.md` opens as the
front page of `M-x scope` above the root list.

### P6. Verify in the editor, then docs

Drive the running daemon over the socket (compos-debug skill), read buffer
text and locals, screenshot the three surfaces, write `docs/SCOPE.md`,
close CB8/CB9 in Linear or mark what this replaces.

## 5. Decisions for the user

1. `.compos/scope/` in the repo (recommended, hand-editable, committable)
   or `~/.compos/scope/<root>/`.
2. Auto-refresh on by default with a budget of 60 calls per hour per
   project, or off until `G`.
3. Decided 2026-08-30: a model router (3.6). Roles `summarize`, `explain`,
   `code`, `chat`; tiers `fast`, `medium`, `strong`; `.project.scm`
   overrides both. Open: the global tier defaults named above.
4. Should `M-.` in a document GO (pop-to-buffer) or PEEK (current
   `definition-peek`)? The plan keeps peek: a document names many things
   and the reader checks more than they follow.

## 6. Landmines

- A headless `(find-file)` applies no auto-mode, so `code-outline` on a
  file opened for indexing needs `code--pick-backend!` (memory:
  structural-code-tools). The outline provider must open files through a
  helper that sets the mode.
- `plist-get` throws on `#f`; `string->number` returns `:error`. Directive
  reads go through `morg-directive-info`, never a raw plist.
- Async callbacks from `llm` run on another lane; a handler that touches
  buffers must not close over local env frames (lsp_cb rule). Handlers
  call named top-level functions.
- One fs-change burst on a repository can name hundreds of files. The
  hook marks stale in one pass and queues nothing itself; the queue
  drains from a timer.
- Every list draw reads the mode once (docs/LISTS.md). The summary column
  reads the store once per draw, not per row.
- Never assert a production binding; bind dummy `<f9>` keys.
