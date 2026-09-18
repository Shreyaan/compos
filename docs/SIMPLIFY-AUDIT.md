# Simplification audit

Seven read-only audits of the tree on 2026-09-18. Each item names the file,
states the fault, and gives the simpler shape. Line numbers are from the tree
on that day. Nothing here is started.

Companion documents: `SIMPLIFY-SPEC.md` (ONE CHAT, 2026-08-08) and
`CLEANUP-QUEUE.md` (2026-08-22). Items from those that this audit re-confirmed
are marked (CQ #n).

## 0. The numbers

| Surface | Now | Target | How |
|---|---|---|---|
| Scheme in stock boot (no tests) | 81.7k | ~40k | 7k stays in scheme/packages/, out of boot; 30k is duplicate or dead |
| editor.scm | 15.3k | ~4k | 9.5k moves to packages; 2.8k deleted; 0.8k of comments to docs |
| Elixir | 49k | ~25k | 4.7k of JS/CSS to static files; two LiveViews to one; duplicate modules |
| Tests | 78k | ~40k | 43 wrapper files, 40 double-covered features, demo-app tests |
| Docs | 66 files, 13.7k | ~27 files, ~7k | stale and superseded out; the essays stay |
| Primitives | 582 | ~350 | 52 unreferenced, 25 dual spellings, families to one door |
| Commands | 986 | ~650 | 160 window commands to 55; 90 app commands out; 60 leftovers |
| Defcustoms | 253 | ~120 | 88 have one reader in their own file; 41 belong to apps |
| Chat buffer-locals | 74 + ~20 undeclared | ~40 | runtime state lives in the Agent process |
| Frame-local keys | 48 | ~15 | one window-configuration slot map |
| Recency stores | 7 | 1 | |
| Preview mechanisms | 7 | 1 | |
| "Put the frame back" mechanisms | 12 | 1 | |
| Ways to run Scheme | 11 | 3 | lane, task, rpc |
| Persistence mechanisms per buffer | 5 | 2 | Loro log + desktop |
| Hook mechanisms | 6 | 1 | |
| Prompt doors | 5 | 1 | |
| Mode definers | 6 | 1 | |
| JSON-RPC framers | 5 | 1 | |
| Markdown renderers | 3 | 1 | |
| Model catalogs | 3 | 1 | |
| PTY runners | 2 | 1 | |
| Observability surfaces | 6 | 2 | one event stream, one sample |

Roughly 210k lines including tests becomes roughly 105k.

## 1. The target shape

**Elixir: ten mechanisms.** Interpreter. Buffer (rope + Loro log, points,
locals, ranges). Editor (frame map, window tree ops, one render row model).
KeyDispatch (one lookup that asks Scheme). Lane (serial per key) + Task
(one-shot). Transport + JsonRpc (one framer; ACP, LSP, MCP, Codex are
vocabularies). Backend base + ReqLLM + ACP. Hotload. Desktop. Telemetry
stream. Each connector module exports its own primitives with docs in one
`prim` macro.

**Scheme kernel: ~4k lines in editor.scm.** Catalog (one table). One
`define-mode` with keyword args. `define-command`. Hooks, including keyed
hooks. Keymaps as data with the ladder in Scheme. Files and the write door.
The display-buffer chain. One `window-configuration` value. Minibuffer as a
buffer with a mode. Tabulated list with a `'surface` option.

**Packages: one per domain, no private helpers.** chat, agent connectors,
groups, layouts, dashboard, look (peek), lists, terminal, remote, isearch,
dired, notmuch, web, morg, lsp, treesit, jj, worktrees.

**User config: providers and personal apps.** A seam in core is one custom
that holds a function. The config supplies the function:

```scheme
(set-custom 'secret-provider
  (lambda (name) (shell-out "doppler" "secrets" "get" name "--plain")))
```

No registry, no wrapper package.

**Layout.** `apps/compos_core/priv/*.scm` holds the kernel only: editor.scm
and the boot files. Every package lives at the project root in
`scheme/packages/`. init.scm lists the stock packages; amazon, linkedin,
substack, spotify, movie, doom, doom-lite, spreadsheet, graphql, calendar,
px0, title, training, recording, peers are in `scheme/packages/` too, out of
init.scm, and load only when the user init names them.

The door is Emacs's: a `load-path` list, and `load` of a relative name
searches it. The kernel sets the default, so init.scm and the user init
load by bare name and add a directory only for something outside the tree.

```scheme
;; editor.scm
(defvar 'load-path
  (list (compos-priv-dir)
        (string-append (compos-project-dir) "/scheme/packages")
        (compos-home)
        (string-append (compos-home) "/packages")))

;; init.scm and ~/.compos/init.scm
(load "notmuch.scm")
```

Today `load` (session.ex:2550) takes one expanded path and searches nothing;
init.scm and package.scm hardcode `(compos-priv-dir)`; Hotload names its
roots in Elixir (hotload.ex:137-147); the Scheme write roots are a third
list (editor.scm:6371). All four become readers of `load-path`: `load`
searches it in Scheme over the one-path builtin, Hotload asks Scheme for it
at boot and on change, the write roots derive from it, and the release
copies every entry. `load-bundled-package` and its five hand-expanded
copies in init.scm go away.

## 2. What to look for (the patterns every audit found)

These are the tests to run against any file. Each one names the audits that
hit it.

1. **One fact, N stores, plus sync code.** 7 recency rings; current group in
   3 places; attribution in 3 (Loro commit, authors spans, edit_log); text in
   2 (rope + Loro) with a cross-check on every checkpoint; commands in 3
   registries; messages in ETS and a buffer; faces in 4 places.
2. **One mechanism, N names.** 7 previews (peek, listing-preview, candidate,
   collect, switch, ibuffer, group); 12 frame restores (winner, transient
   frames, popup-return x3, overview-return, group layouts, hidden windows,
   switch/ibuffer restore-home, quit-restore, layout-focus-token); 6 hook
   mechanisms; 5 prompt doors and 5 question readers; 6 mode definers; 9
   "special buffer" predicates.
3. **A special case beside a generic that covers it.** 62 curl call sites
   beside `http-request`; popup identity parsed from a CSS class string
   beside a window leaf; an "agent" render mode beside "blocks"; Google's
   private Bandit listener beside web_server.ex; two PTY runners; five
   JSON-RPC framers beside Endpoint.Conn, which already has every framing.
4. **Policy that leaked into mechanism.** The keymap ladder (360 lines of
   editor.ex); minibuffer and completion rules across 4 Elixir modules; word
   syntax and kill-line in buffer.ex; the kill fallback picked in Elixir and
   then re-picked in Scheme; prompt strings, model defaults, retry budgets
   and buffer names in agent.ex, llm.ex, and the backends; key policy in the
   JS of layouts.ex.
5. **Dependency arrows pointing the wrong way.** editor.scm calls 129
   symbols that 28 packages define, through 79 `boundp` guards. The kernel
   creates package keymaps (spotify-map, annotate-map). dired wraps all 15
   of its commands for google.scm. This is why chat, lists, dashboard and
   layouts never moved out.
6. **Migrations that run forever.** `Desktop.upgrade` and `Buffer.upgrade`
   on every message; chat-input-migrate!, chat-record-migrate!, the
   companion-of upgrade, llm-bundles-assign-keys, the llm-responses mirror;
   every buffer change broadcast twice for a "compatibility alias".
7. **Registered but never read.** 52 primitives with no production caller;
   88 defcustoms with one reader in their own file; 103 commands reachable
   only by M-x, 60 of them leftovers; 22 of 37 face aliases; 10 commands
   that exist for their test.
8. **Metadata that does not pull its weight.** 1,150 lines of catalog stamps
   across 231 files with 4 runtime readers; the apropos engine (850 Scheme +
   368 Elixir + OpenAI embeddings) to search docstrings; 248 public! entries
   that restate a signature the define already states.
9. **A builtin gap that N files patch.** `plist-get` throws on `#f`, so 25
   wrappers exist; no `string-replace`, `html-escape`, `take`, `string-clip`,
   `alist-put!`, so 40 private helpers exist; `sh-quote` is public but 8
   packages copy it.
10. **Two-way registration.** Every primitive lives in an impl map and a
    parallel docs map (900 lines); one name is registered twice with the
    later merge winning.
11. **Tests that duplicate or preserve.** 43 wrapper files around one bridge
    that already runs every Scheme test; 40 features tested in both suites;
    7 FakeTransport copies; 144 private `eval!` helpers; 61 files assert
    production chords.
12. **Comments as changelog.** 23% of editor.scm is comment, much of it
    "the bug this line prevents" and dates.
13. **Name collisions.** chrome (extension, window overlays, a face);
    transient (menu, frame); backend/connector/lane/provider for one thing;
    setup/bundle/preset/combination/history entry/workspace defaults for one
    record; shell/term/comint crossed against Emacs.

Lenses this audit did not run: usage telemetry (which commands anyone runs,
so deletion is data-driven); the 4.7k of CSS and JS in layouts.ex against
docs/COMPONENTS.md; the ~45 files Scheme and Elixir write under `~/.compos`
with no manifest; a latency benchmark for the one-serial-world execution
model (item 8.4).

## 3. Kernel: editor.scm

Verdict per section (line ranges of 2026-09-18):

| Section | Lines | Verdict |
|---|---|---|
| catalog, package stamps | 1-200 | kernel; `catalog-meta!` merge duplicates `catalog-register!` |
| define-command, interactive spec | 201-314 | kernel; string codes and 'b 'd 'm unused |
| public! registry | 315-395 | delete: second copy of the catalog |
| tabulated lists | 396-2656 | package `tabulated-list.scm` (2,261 lines, 48 callers all outside) |
| minibuffer | 2907-3472 | kernel ~300 after one door; rail to groups; shape cycling has no caller |
| hooks | 3473-3576 | kernel |
| defvar-local family | 3577-3647 | delete (0 production callers) |
| marginalia, chrome | 3648-3801 | package |
| modes | 3904-4161 | kernel ~120; icons, link syntax out |
| visual lines | 4604-4840 | package |
| isearch, hl-line, font-lock, replace | 5834-6145 | package; font-lock keywords has no setter |
| remote files | 6781-7020 | package |
| popper | 7513-7886 | package, one `popup-show!` |
| peek | 8379-8776 | package `look.scm`; peek.scm is a second peek |
| tiling, window-layout commands | 9061-9440 | layouts.scm |
| collect | 9441-9718 | package |
| terminal, comint, tail | 9719-9885 | package |
| LLM pipes, llm-mode, chat-mode, bundles, transcript | 9886-12092 | packages (2,207 lines) |
| modeline dashboard | 12209-13320 | package `dashboard.scm` (~960) |
| command palette | 13574-13736 | package |
| direction families, arrow installers | 14033-14248 | layouts.scm; 0-caller tables deleted |
| public API | 14876-15276 | shrink to ~100 |

Findings:

1. Four registrations per command (Elixir ETS, `*command-fns*`,
   `*command-names*`, catalog) and two per public function. Three copies of
   "replace, touch generation, notify apropos" at E:126, 186, 303. One
   catalog keyed "kind:name"; `public!` = `catalog-register!`.
2. Six mode definers, seven per-mode side tables (`*mode-parents*`,
   `*mode-docs*`, `*mode-icons*`, `*mode-link-syntaxes*`,
   `*dismissible-modes*`, `*mode-layouts*`, `*mode-headlines*`), nine
   hand-written minor-mode toggles, four ways to re-run setup by name, three
   ways to rebuild. One `(define-mode NAME 'parent 'minor 'keys 'doc 'icon
   'setup 'teardown)` and `(mode-get MODE KEY)` with the parent walk.
3. The alist upsert idiom appears 34 times in editor.scm and 121 in priv;
   `hook--alist-put` is that function. `alist-put!`, `alist-get`,
   `alist-delete` become builtins beside `assoc`.
4. Six hook mechanisms: add-hook!, on-X! wrappers, keyed registries
   (`*preview-link-verbs*`, `*marginalia*`, `*context-providers*`,
   `*embark-actions*`, `*paste-hooks*`), the Elixir single handler fanned
   out, re-`set!` seam lambdas (buffer-project-label, switch-buffer-source,
   display-foreign?, buffer-kill-repair, candidate-face-for), and
   frame-attached!. Keyed hooks `(add-hook! '(preview-link "def") fn)`
   replace all of them and the 79 boundp guards.
5. Five prompt doors (minibuffer-read*, minibuffer-read, completing-read,
   minibuffer-read-preview, read-string) and five question readers (read-char
   = read-char-choice; y-or-n, y-or-n-p, yes-or-no-p). The M-a..M-z shortcut
   generator registers 35 commands, 23 of which do nothing.
6. Six variable mechanisms (define, defvar, defvar-local family, defcustom,
   persist-global!, buffer-set-local!). `(defvar 'x default 'persist #t)`
   replaces persist-global! and its 15 get/put closure pairs.
7. Shadowed definitions: E:2790-2851 (preview-goto-pos! and friends) is
   overwritten by preview.scm:330-436; the editor copy lacks url-decode.
   scheme-mode, html-mode, elixir-mode, json-mode are redefined by
   treesit.scm:57-74 and file-view.scm:39. Eight layout variables are
   defined here and defcustom'd again in layouts.scm.
8. Dead: dash--seg-gap, list-filters-label, list-stamp!,
   llm-mode--stream-range!, reload-refresh-modes!, scroll-other-window-by!,
   `*minibuffer-shapes*`, list-filter-clear, list-more,
   toggle-window-animations, scroll-popup(-down), and 24 define-commands with
   no key and no caller. Test-only: buffer-unselect(-all),
   desktop-apply-mode!, display-action-for, chat-set-backend, popup-move-*,
   window-prefers-buffer?, run-hook-with-args-until-*, the magic and
   interpreter mode alists, kill-all-local-variables!.
9. Copy-pasted bodies: the save epilogue 6x (E:6446-6547); the visit body 4x
   (E:7005-7152); the remote-sh! wrapper 9x (E:6910-6983); the mb-list
   prompt door 3x (E:1945, ibuffer.scm:1761, agent-fleet.scm:1306); "another
   window that is not the popup" 7 finders with 3 exclusion sets.
10. Emacs parity nobody uses (~450 lines): mark ring + global mark ring;
    font-lock keywords; command-call/call-interactively; read-number,
    read-buffer, current-kill; define-globalized-minor-mode! (evil only).
11. Nine special-buffer predicates. `buffer-special?` = derived from
    special-mode; `chat-buffer?` = the 7-site inline guard.
12. Chat locals: three lists, 77 names, ~40 belong to packages;
    'agent-mode-wanted is in no list; llm-mode keeps an undeclared fourth
    set. `(local-class! 'name 'identity|'conversation|'runtime)` declared
    where the local is defined.
13. Reimplemented builtins: nth (unsafe list-ref) x4, list-tail-n,
    name--trim-left/right, name--index, sort-by-car, catalog--get,
    chrome--get, transient--put, abbreviate-home, move-lines.
14. One-shot migrations on every boot: shell-mode alias, companion-of
    upgrade, chat-input-migrate!, chat-record-migrate!, llm-bundles-assign-keys,
    the llm-responses mirror. One desktop migration pass with a cut-off.
15. Keys bound from six sections; C-c b bound 3x; C-c m 3x to two commands;
    the dashboard hardcodes chord names in rows.
16. Small bootstrap files: transient.scm and chrome.scm are packages;
    themes.scm restates ~60 faces per palette 4x, 15 ts-* faces have no
    producer, 22 of 37 Emacs face aliases have 0 references; three settings
    files (transient-values.scm, theme.scm, custom.scm) for one thing.
17. Blocks: four fence finders under five vocabularies; five block files
    hand-write the package prologue; init.scm hand-expands
    load-bundled-package three times.

## 4. Windows, groups, layouts, lists

Inventory: frame (Elixir map + a Scheme `*frame-locals*` shadow with 48
keys), window, popup (a window whose buffer carries a CSS class string that
Elixir parses at editor.ex:2936), display-buffer chain, target layout, peek,
listing-preview, candidate preview, collect, switch-preview, ibuffer-preview,
group-preview, detail, group (groups.scm 4,372 = five packages), current
group (3 copies), sealed groups, group MRU (7 recency stores), graveyard,
group layouts per frame, transient frames, overview, autolayout, hidden
windows, mode layouts, scenes, tile algorithms, winner, quit-restore, kill
fallback (two pickers), fill seams, list-mode (2,260), ibuffer (2,621),
switch (1,077; both files claim to be THE switcher), minibuffer with three
geometries.

The minimal set is eight concepts:

1. **frame**: one store. Fold `*frame-locals*` into the Elixir frame map or
   the reverse; delete set_frame_group_label/style.
2. **window**: leaf with `buffer, history, top, side, owner`. `side` replaces
   the class-string popup detection; `owner` replaces peek-window,
   listing-preview-target, detail window, collect window, group-preview.
3. **buffer**: `'group-ids` only; drop the chat-only `'group-id` split and the
   migration paths; `special?` derived from mode.
4. **group**: record + `'group-ids`. One MRU (Elixir state.mru already holds
   `{:group, g}`); delete `*group-mru*`, `group-mru-history-ids`, both cycle
   rings, tab-order. Graveyard = record with `killed-at`.
5. **window-configuration**: one value `(tree buffers points group)` with
   Emacs names. Replaces 12 restore mechanisms (~650 lines to ~120).
6. **one display rule table**: keep the chain. Peek, listing-preview,
   candidate, collect, switch, ibuffer, group previews and detail memory
   become one `display-preview` action: show NAME in the owner window of the
   asking list, never bump MRU, never take focus (~1,100 to ~250). Target
   layout and group pane choice become display actions (~350 to ~80).
7. **one arrange function**: `(window-arrange! SPEC)` over the mode-layout
   grammar; tile algorithms, autolayout, scenes, overview, target and
   adaptive layouts are spec producers (~1,000 to ~350).
8. **one list renderer**: list-mode with `'surface` (window, popup,
   minibuffer, modal). switch.scm, ibuffer.scm, the groups board, chat-list,
   collect, mb-rail, the group prompt rail and ibuffer-prompt! become a rows
   function each. Group rows are built four ways today. Elixir renders one
   row model for minibuffer, completion, transient, rail and list windows
   (~1,600 lines).

Commands: 160 in this domain to ~55. Families: 19 window-layout-*/
autolayout-* to `window-layout ALGO`; 7 overview-* to 0; 9 popup-* to
display-buffer + quit-window + scroll-other-window; 10 ibuffer sort/group
toggles to the list-mode verbs that exist; 12 switcher entry commands to
`switch-to-buffer` with 'scope and 'surface; 9 group-add variants to three.

State duplication: current group (3), membership (`'group-ids`, `'group-id`,
legacy `'group`/`'companion-of`, `group-members-index`, frame owner slot),
recency (7), window->buffer (Elixir tree + 8 Scheme parallel trees each with
its own dead-buffer sanitizer), popup identity (4 ways).

Elixir editor.ex duplicates Scheme: kill fallback then group repair;
other_window cyclic then Scheme focusable filter; preview_buffer as a second
entry point; group_label/group_color as a second store; restore_tree history
rules beside layout--restore-histories!.

Totals: ~15,400 to ~7,000 lines; docs/groups.md, WINDOWS.md,
DISPLAY-BUFFER.md, POPUPS.md, PEEK.md, GROUP-MODES.md, CHAT-LIST.md become one
WINDOWS.md.

### 4a. Rearranging windows takes seconds (first-class, ruled 2026-09-18)

A window change is a tree edit plus one hook. The Scheme suite marks 49
window-rearranging tests with 120-300s timeouts, and the bridge gives each
test 30s. Nothing in a rearrangement justifies more than milliseconds: the
silent-buffer rule already holds (per-command work only for the manipulated
buffer; the per-window dashboard sync was fixed).

Measured 2026-09-18 in the test VM (`SCHEME_TIMES=1 SCHEME_TESTS=...`,
then one call at a time):

| Operation | Time |
|---|---|
| split-window!, delete-other-windows!, switch-to-buffer! | 0ms |
| buffer-create, buffer-kill! | 0-2ms |
| every layout-policy, window, group-switch test | under 0.4s |
| ibuffer draw, 4 rows | 12-14ms |
| ibuffer draw, 24 rows | 43-47ms |
| ibuffer test fixture (open, set filter, refresh) | 135-141ms |
| one ibuffer test | 0.4-0.7s |
| tile-all-uses-only-the-current-project | 3.05s = its `wait-until` cap; the test fails in the dirty tree |

Rearranging windows costs nothing. The seconds in the suite are `wait-until`
caps on failing tests and the 30s bridge timeout on hanging ones. The real
cost is the table draw, and the interpreter is not the reason: a lambda
call, a buffer-local read, and an assoc over 100 entries each cost 1-2us.
The reason is per-draw facts recomputed per row. `ibuffer-fields` depends
on the buffer's grouping only, yet every row's cells asked it, at 0.28ms
a call: 7ms of a 49ms draw. Memoized per draw, the draw is 39ms and the
ibuffer tests run in 80-170ms instead of 400-700ms (the fixture also
draws twice per test now, not four times).

What is left in the 39ms for 25 rows: row fetch 3, column fit 5 (each
field measures every row once), prepare 8 (cells 3, lay-out 3, lines 2),
composml-text 9 (record fn 3, the loop 6), write and overlays 3, the rest
under 2ms each. Under 1ms per row needs one pass per row that builds
cells, lines, fields and record together instead of four passes; that is
the "one list renderer" item in section 4, not a micro-fix.

## 5. Agent, chat, LLM, tools, permissions

Scope: Elixir 6,534 (agent.ex, 5 backends, llm.ex, llm_session.ex, llmdb.ex,
model_catalog.ex, mcp, reactor, candidates, embedding_index); Scheme 12,853
in 19 packages + ~2,100 in editor.scm.

1. **Two conversation lanes still exist.** llm-mode (E:9926-10760, ~800) is a
   second runtime with its own session open, context fn, dispatcher, and a
   permission stub that answers 'allow. M-o becomes "send region to the
   group's chat".
2. **Four backends, one contract not enforced.** close/1, emit/2,
   adapter_exit, json_text, Port handle_info quads are byte-identical across
   acp.ex and codex_app_server.ex; 27 GenServer.call shims; 5 capability
   lists. `use Backend` defines the shims; a backend supplies
   start/prompt/translate.
3. **JSON-RPC framing written five times** (acp, codex, mcp/conn, lsp/conn,
   transport.ex) while endpoint/conn.ex already has exec+tcp transports with
   every framing. One JsonRpc over Endpoint.Conn (~450 lines).
4. **codex_app_server.ex is an ACP clone** (903 lines) with an English regex
   on a vendor message. Delete if codex-acp works.
5. **llm.ex + req_llm.ex + llm_session.ex are three modules for one lane.**
   `llm-with-tools` has zero callers; LLM.request is test-only;
   llm_session.ex is 20 pass-throughs; llm-session-* and agent-* primitive
   families (30) write the same escaped slot. One `agent-*` family (~12).
6. **The tool zoo grew back** (CQ W1): 25 define-tool! in 6 files, 22 of them
   restate a public! function one line above; model-facing tool lists are
   built five ways. eval-scheme + ask; apropos is a function the model calls
   through eval.
7. **Catalog metadata**: public! 1,042, effects! 545, domain! 327,
   catalog-meta! 258, category! 94 across 231 files; four runtime readers of
   effects; CQ #1 (strings vs symbols, so 258 entries never match) still
   stands. One docstring + one optional 'effects tag on the ~50 destructive
   functions.
8. **Apropos**: 850 Scheme + 368 Elixir + OpenAI embeddings to search
   docstrings. ~60-line grep over the catalog; keep BM25 if measured better.
9. **Permissions**: 14 concepts, an 8-arm policy, five Elixir
   implementations, one reachable decision. Default stance is auto; arm 5
   returns allow-always for `execute`; eval-scheme is '(write execute) so
   the effects verdict never fires for the one tool that matters; arm 1
   greps raw text for verbs. One `(permit? buf text) -> allow|ask|deny` over
   stance + deny-list; Elixir keeps resolve_permission and the ask UI.
   (CQ #6: raw text differs per lane, req_llm.ex:378, still open.)
10. **The config record exists six times**: connector, MCP server, preset,
    bundle, setup's program registry, workspace LLM defaults. `compos` is
    registered as an MCP server pointing at itself and special-cased out five
    times. One record `(name connector cmd model effort servers stance)` +
    one picker; llm-config.scm 951, setup.scm 713, mcp-hub.scm 419 mostly go.
11. **Twelve surfaces show one conversation**: chat-mode, *chat-list*,
    " *chats*", chat-switch-prompt (0 callers), chat-list preview (a fourth
    block renderer), *subagents* (0 non-test callers), *Chat Performance*,
    three sentry modes, llm-mode, scratch outputs. chat-mode + one ibuffer
    kind.
12. **Transcript primitives written twice, byte for byte**: chat-blocks-push!
    = agent-block-push!, chat-blocks-drop! = agent-block-drop-kind!,
    chat-render! = agent-render!, chat-clear-waiting! = agent-clear-waiting!
    over two locals, and chat-abort calls both. Turn->text in 3 places,
    flatten in 3, clip in 5, "find this chat's buffer" in 4.
13. **Elixir holds policy**: `<system>` wrapper (acp.ex:222), an English
    instruction sentence (codex:483), denial strings the model reads,
    "claude-sonnet-5" default, per-model context hacks, 40 retries on a
    string match, "*agent: slug*" buffer names, CLAUDECODE deletion.
14. **Dead and broken**: chat-dismiss defined twice, the winner calls
    `chat-dismiss--finish!` which exists nowhere; chat-list--preview-now! is
    a `#f` stub; ~25 zero-caller defs listed in the audit.
15. **sentry.scm** (954) is an HTTP client dressed as a subsystem; its API
    fns have zero external callers. ~120 lines the model calls via eval.
16. **worktrees.scm + jj.scm**: 75% agent ceremony, little reachable;
    jj-push exists to justify a deny-list carve-out.
17. **Prompt composition**: 330 lines + 111 of doc for 8.4KB of text; three
    lanes still splice differently. One `(chat-system-prompt buf)`.
18. **Title/summary/compaction** (~700): the file's own comment says
    compaction no longer pays for itself.

Target: Elixir ~1,600 of 6,534; Scheme ~4,500 of ~14,950. Order: config
record, permit?, tools + catalog, backend base + JsonRpc, one chat.scm,
llm-mode removal, sentry/worktrees/jj trims.

## 6. Packages

1. **Out of boot**: 15 personal apps, 6,634 lines, ~75 commands, 41
   defcustoms, 0 inbound users. They stay in `scheme/packages/` and leave
   init.scm; the user init opts in. calendar/ is
   not even loaded. org.scm (646) is superseded by morg. 1-commit imports
   untouched since 2026-08-29: db, endpoint, graphql, package, peers,
   training, web-server. ~7,300 lines and ~250ms of boot.
2. **Core depends on packages**: editor.scm calls 129 symbols from 28
   packages; 66 of ~100 files forward-reference later loads; init.scm
   ordering is enforced by comments; 28 packages re-stamp `package!` at top
   level; `message` is shadowed by messages.scm at boot slot 66 so two
   `message`s exist during boot. Declared `requires` derive the order.
3. **Builtin gap**: safe plist-get reimplemented 25 times; make the builtin
   return `#f` for a non-list. sh-quote copied 8 times. `--replace-buffer!`
   copied 5 times; add `buffer-set-text!`. String helpers (replace,
   html-escape, text, take, clip, first-line, basename) ~40 defines. Time
   formatting 7 ways. Exact duplicate bodies: 19 groups, 79 lines.
4. **App skeleton**: home-group!/enter-group!/join-group!/log! copied per app
   with 3 divergent behaviours (sentry sets a `'group` local instead of
   buffer-add-group!). Each app writes --rows, --cells, --meta, --columns,
   --narrow-cells, a refresh command, a detail buffer, a log buffer, 2-12
   registration forms. A `define-app` form removes ~150 lines per app.
   Browser-scrape apps share an unextracted page-poll loop.
5. **HTTP**: http.scm exists; 8 packages hand-build curl through
   shell-command->string (62 sites).
6. **Defcustoms**: 253; 24 have a non-default value; 88 are read at one site
   in their own file. Rule: a defcustom needs a second reader or a user
   story.
7. **Commands**: 264 unbound; 103 reachable only by M-x; ~60 look like
   leftovers (bookmark-* parity stubs x12, ibuffer-do-sort-by-* x3,
   agent-verbosity-* x3, chat-heal/unstick/derive-names, ...).
8. **Load-time side effects**: editor.scm 115, themes 64, groups 42, irc 36;
   perf.scm arms a timer at boot for a mode that is off by default. A package
   registers data and does nothing until its mode runs.

## 7. Primitive surface and Elixir modules

1. layouts.ex is 2,903 lines of JS + 1,780 of CSS in ~S strings; the Keys
   hook `mounted()` is one 1,326-line closure; key policy (CMD_KEYS,
   editingAfterKey, nativeTextKey) lives in JS. Static files; Scheme
   publishes the key tables as frame data.
2. Two LiveViews for one editor: mobile_live.ex + mobile_layouts.ex repeat
   mount/refresh/drain, 9 handle_event clauses verbatim, the modeline, the
   AgentScroll hook, 295 lines of CSS; the keys panel synthesizes C-n/C-p/RET
   presses. One EditorLive; Scheme picks the 'handheld layout profile.
3. Three Markdown renderers (markdown/html.ex, editor_live.ex:3112-4300 with
   an Earmark fallback, embed cards + oembed.ex). Markdown.Html owns the
   document; drop Earmark.
4. The view runs the text display engine (viewport_lines, build_static,
   display_spans, which calls Buffer.request_fontification; line_cache per
   LiveView process). Core Display returns rows per window memoized by
   version; both clients and /raw consume it (CQ: whole-buffer build_static).
5. "agent" is a special render mode across four layers (editor.ex agent_leaf
   reads 12 named locals; ag_block clauses; agent_transcript.ex; AgentScroll;
   122 .ag-* CSS rules) beside the generic "blocks" mode that renders any
   Scheme block tree.
6. Every primitive is registered twice (impl map + docs map: 900 lines);
   window-list-all is registered twice. One `prim("name", "doc", fn)` macro.
7. Google: 5 prims, a private Req wrapper, a private Bandit listener for the
   OAuth callback beside web_server.ex, a token refresh that is one POST.
   One `oauth2` prim; the callback page is a Scheme web-server handler.
8. Minibuffer and completion policy in Elixir: vertico-directory rule in
   minibuffer-del!, "fill input with the selected label", 5 completion
   styles, a window of 8, "SPC ends completion". The prompt is a buffer with
   a keymap; Candidates.matches?/rank stays as one pure prim (~400 lines,
   ~12 prims).
9. Landing policy in the Editor GenServer, then wrapped again in Scheme
   under builtin-* raw names (22 aliases): delete_window lands on first_leaf,
   other_window cyclic, set_window_buffer bumps MRU, kill_buffer recreates
   *scratch* and closes an llm session by reading a local.
10. The Editor GenServer builds the render payload (render_walk 205 lines,
    modeline_group formats "N groups" strings) and editor_live.ex adds its
    own header with hardcoded chords ("C-x C-f", "C-c a", "C-x w").
11. Per-subsystem list/detail/log/on-event families seven times
    (mcp-, lsp-, endpoint-, web-server-, db-, agent-, socket-) with three
    copies of strftime; nine single-slot handler registries. `(conn-list
    KIND)`, `(conn-detail KIND NAME)`, `(conn-log KIND NAME)`, `(on-event!
    KIND fn)`: 22 prims to 4.
12. Motion and word syntax in Elixir (12 prims, fixed word class). Keep a
    fast char/line primitive; forward-word etc. are Scheme with a
    mode-settable syntax.
13. Dual spellings: point/buffer-point, goto-char!/buffer-goto!,
    keymap-set!/define-key, buffer-set-hidden!/fold-set!,
    local-set-key/local-set-key*, minibuffer-read/minibuffer-read*,
    delete-window!/delete-window-id!, window-list/window-list-all,
    split-window!/split-root!. ~25 prims.
14. 52 registered names with no production caller (43 test-only, 9 none).
    SchemeActor (283 lines, 9 prims, a supervisor) has zero production users.
15. Three model catalogs (llmdb.ex downloads models.dev; model_catalog.ex
    reads the llm_db hex package which IS that snapshot; llm.ex receives
    total_cost from req_llm). The LLMDb vs LLMDB name collision is the open
    llmdb-max-tokens bug. ModelCatalog over LLMDB; keep a ~60-line usage
    ledger.
16. Two PTY runners over /usr/bin/script (proc.ex, terminal.ex); prims
    dispatch on Terminal.running? for every call. One Terminal; comint is
    Terminal with raw: false.
17. Dired presentation in Elixir: file-stat returns "17.3M" and "Jan  5
    14:02"; file-mtime and file-size exist because file-stat cannot be
    sorted. One file-stat returning numbers.
18. Small twins: four telemetry collectors with four stores; two FileSystem
    watchers (watch.ex, hotload.ex) each with debounce; three shell spawners;
    remote-* prims are shell-command->string with an ssh prefix; irc.ex +
    2 prims for one package; embedding_index.ex posts raw Req to OpenAI
    while req_llm ships embed/3; MCP-over-HTTP hand-rolls SSE beside an
    Endpoint {:http, url} transport.
19. homepage_live.ex (1,355) is a marketing site for three brands with no
    core calls. Static HTML or out of the repo.
20. Fourteen primitives each re-implement the sync/async fork with their own
    timeout constant. Every blocking prim is sync; Scheme wraps it in
    task-run! when it wants a callback.

## 8. Runtime: buffer, session, editor, execution model

1. 32 GenServer modules, 12 Registries, 11 DynamicSupervisors; ten
   Registry+DynamicSupervisor pairs are the same pattern. One
   `Compos.Core.Children`.
2. `:compos_escaped_closures` (95 references) holds six unrelated things:
   command GC roots, reactor callbacks, debounce timers, eval-defer tokens,
   task callbacks, the last 32 eval results. It is the Scheme heap roots
   table; name and type it as one.
3. ~14 files under ~/.compos from Elixir and ~30 more from Scheme, no owner
   or manifest.
4. **Eleven ways to run Scheme**: lanes, :single_actor (one test + a config
   line), SchemeActor (copied env), SchemeTask, task-run!, eval-defer!/
   eval-resolve!, with-scheme-lock, wait-until polling, debounce!, Reactor
   Tasks, SchemeReadLimiter. The two-tier Env with escape/promote/flush, the
   Session frame GC walking every buffer's locals, SchemeHeap,
   SchemeRawNames, and the stale-frame retry loops exist because many BEAM
   processes mutate one Scheme world. Minimal: one serial process per lane +
   SchemeTask for pure reads. If one serial world is adopted, env.ex (546) +
   gc.ex + roots + flush + heir dance collapse (~900 lines). Largest and
   riskiest item; needs a `:ui` latency benchmark under an agent turn first.
5. **Attribution recorded three times** (Loro commit actor, authors spans +
   origins, edit_log capped at 500 and not persisted); pending_ops batch
   fields for a SQLite store that no longer exists; the moduledoc still
   promises it. Loro is the only author record (~650 lines).
6. **Text held twice**: rope + Loro doc mirror every edit, `verify_history`
   compares them at every checkpoint, the checkpoint stores the text again
   beside the Loro snapshot. Either the doc is the text or the doc waits for
   multiplayer.
7. **Five persistence mechanisms per buffer**: checkpoint etf, catalog.etf
   (with a copy of every local under 1KB), Loro log, desktop.etf, BufferView
   ETS row rebuilt at boot. The catalog is rebuilt by scanning checkpoints,
   so it is a cache pretending to be a store. One file per buffer = Loro log;
   catalog derived at boot; desktop = window trees + Scheme globals.
8. **Four read paths for one field** (ETS row, GenServer call, dormant
   checkpoint read, BufferStore fact/local); `Buffer.point/1` tries three.
   The row is the only read model for live and dormant buffers.
9. Display and command-loop state in the model struct: fontify task/cache,
   ts, goal_col, insert_run, undo_run; hidden, narrow_range, overlays are
   three tagged-range maps adjusted by the same function. One `ranges` map.
10. **Session.ex is a second primitive table**: 2,300 of 3,341 lines are
    primitives and connector glue; hot-reload logic (250 lines) lives here
    while Hotload only watches. Each connector exports its own primitives;
    Hotload.Scheme owns reload; Session keeps eval/exec/GC (~700 lines).
    Registering primitives by module+name makes a code swap self-healing and
    deletes SchemeRawNames.
11. Messages stored twice (ETS ring + *Messages* buffer). The buffer is the
    log.
12. **Keymaps**: 14 prims, ~30 handle_calls, 360 lines of ladder resolution
    in editor.ex while key_dispatch.ex says "what keys mean is Scheme's
    business". Keymaps are Scheme data; Elixir keeps one lookup.
13. MRU three ways; clips/navigations/selects are three identical take-once
    slots; faces in four places; undo_exempt is a per-command property that
    belongs in catalog meta.
14. **Observability**: Telemetry + telemetry.scm, SysMon + perf.scm (500
    lines of hand-rolled SVG), Profiler + profile.scm (VM-wide counters),
    live_dashboard, Lane slow-job Logger beside the telemetry row, ChatPerf
    jsonl, llm-usage.jsonl, KeyDispatch trace. One bounded event stream +
    one sample + one Scheme buffer (~2,000 lines).
15. **Seven code paths wake a buffer** with a 3-way branch on the caller's
    process kind and a pdict flag; the four-condition eviction guard is
    written twice. `wake(name)` = start from Loro log + one Scheme
    `buffer-woken!` on the buffer's lane, always async.
16. `Desktop.upgrade` and `Buffer.upgrade` run on every message; desktop v1
    beside v2/v3; use code_change/3 once.
17. compos_scheme is clean: no editor knowledge; stale moduledoc only.
18. Named leftovers: events broadcast twice for a "compatibility alias";
    "legacy" actor kind; read_many_fallback; the Buffer moduledoc describes
    list-of-ropes undo and a SQLite store.

## 9. Tests, docs, skills, cruft

1. 43 `*_scheme_test.exs` wrappers (1,961 lines) duplicate
   `scheme_suite_test.exs`, which already runs every priv/tests file; two
   name Scheme files that do not exist.
2. 40 features tested in both suites (~7,800 ExUnit lines); 104 ExUnit files
   only call Session.eval (11,205 lines): Scheme policy in Elixir clothing.
   editor_test.exs (4,643): dired, switcher, display-buffer, tiling describes
   are Scheme policy with Scheme suites.
3. 7 FakeTransport copies; `eval!` in 144 files; `press` in 66; `wait_until`
   in 20. Three ways to fake an LLM turn; four ways to get a second daemon.
4. 61 files assert production chords; 28 press C-x/C-h/M-x; 14 of the 24
   always-red tests are named after a chord.
5. ~3,500 lines of tests for demo apps (doom, spreadsheet, pdf, google scene,
   chrome, evil, whatsapp, amazon, irc).
6. KNOWN-FAILURES.md lists 64 names from 2026-08-23; nobody re-measured.
7. Docs: 19 current specs; stale: HANDOFF.html (2026-08-14, wrong repo path,
   still the CLAUDE.md entry point), ROADMAP, KNOWN-FAILURES,
   PERFORMANCE-REVIEW; superseded: doc/WINDOWS.md, training.md vs LEARN
   COMPOS.md, COMPONENTS-SPEC, CONTROL-SPEC, PROVENANCE + BUFFER, four
   COMPOSML docs; never built: ANNOTATIONS, PDF-ANNOTATIONS,
   EDITING-SURFACE-SPEC, ORG-MODE-PLAN, SIMPLIFY-SPEC (has `pkill`),
   CLEANUP-QUEUE, SCHEME-TEST-MIGRATION, SWITCHER-PERF-HANDOFF. The essays
   (BEYOND-TOOLS, CORDIS-VS-EMACS, EMACS-AS-AGENT-HARNESS, INTRODUCTION,
   COMPOS-HOMEPAGE-BRIEF) stay in docs/ (ruled 2026-09-19). Dangling: AI-NATIVE-SPEC, INTERFACE, SCOPE, LISP,
   ACP, calendar. Non-doc files: 7 png, a patch, a saved chat transcript.
8. Skills: 12 to 5. code-change says "do not read CLAUDE.md as a ritual"
   while CLAUDE.md says load code-change before every change. compos-boot
   and compos-restart both carry the COMPOS_VERIFY recipe; compos-debug and
   bin/compos default to `~/.compos-web`.
9. Root cruft: `-`, `touched`, editing.png (3MB), image.png, demo.org,
   budget.sheet.json, boards/*.tldr, doc/WINDOWS.md (kept by an explicit
   .gitignore line), three mix-generated READMEs, two erl_crash.dump,
   burrito_out/aimax_macos_arm, 7 stale worktrees (1.8GB, still registered),
   the ai-max.el symlink and worktree.
10. Naming: source is clean; aimax/ai-max/cordis survive in
    .claude/settings.local.json, skills.scm:291 (`cordis.patch.yml`),
    docs, and build dirs.

## 10. Order of work

Each step lands alone and leaves the tree green.

**Done 2026-09-18:** load-path (9a1ca5bb), the 40 test wrappers (316ab4a5),
plist-get and its nine wrappers (9e74f0e8), the secrets seam (7640482e),
SchemeActor + single_actor + six unused primitives (7ac0c748). A recount
with Elixir eval strings, user config, skills and prompts in the corpus
found 20 unreferenced primitives, not 52; introspection reads that tests
use to assert state (face-list, keymap-parent, buffer-local-map, lsp-log,
task-alive?, unbind-global!) stay. One test support module (b59e22e6):
96 files use Compos.Case, one FakeTransport; 31 files keep a custom helper.
The package move (0e96750d): 92 packages in scheme/packages; agenda,
agent-transcript, annotate, appearance, diff-mode, paredit wait in
priv/packages for another session's commit, then one rename and the
priv/packages entry leaves load-path. Then: the last six moved (19ba0452);
fourteen apps left the stock boot (8024a266); one primitive registration
with the doc in the key (item 7.6, the fix for CQ's double registration).

**Also done 2026-09-19:** docs sweep (cd4575aa), eight shared builtins +
buffer-set-text! (a1c82b9c), eight more wrapper tests (next commit), one
JSON-RPC framer for ACP, Codex and MCP stdio.

**Also done 2026-09-19, later:** 45 single-reader defcustoms demoted
(d9c3365b); one model catalog, LLMDb gone, ledger = LLMUsage (43b02bb9;
the provider-blind max_tokens bug went with it); `use Backend` supplies
the six required client shims. Not done, with reasons: the two
FileSystem watchers are not one thing (Watch is content-free by contract,
Hotload needs paths); the two PTY runners wait for a measured reason;
the double-covered Elixir tests stay where they hold key-dispatch or
Elixir-API assertions the Scheme twin lacks.

**And later still:** the twelve restatement tools are gone, the toolbox is
the ten llm_tools_test names (item 5.6 W1); the MCP, LSP, DB, endpoint,
web-server, browser and LLM-session primitives register from their own
modules and the reload logic is Hotload.Scheme, so session.ex is 2,100
lines from 3,341 (item 8.10, 8.12); one JSON-RPC framer; docs/KNOWN-FAILURES.md
is rewritten from measurement. Landmine met on the way: the colocated jj
working copy rewrote the git index and 26 package files fell out of HEAD
for six commits; repaired in d867255d, recorded in memory.

**Red before today, measured by running the pre-change file** (for the
KNOWN-FAILURES rewrite): agent_test 36 of 52; ChatResetTest, SwitchTest,
PresetTest 17; MovieTest, ChosenPaneTest, SpotifyTest 1 each; TransientTest
2; WriteFileTest "C-n then RET"; ProjectSearchTest 4; LLMToolsTest 3;
ChromeTest "returning from a page"; LoadTest was red on calendar. Scheme:
the keymap ladder tests, the block and theme tests, a-page-opens when feeds
runs first, and the four apropos tests.

**State after Phase 1 (2026-09-19, second autonomous run).** editor.scm
is 5.6k lines, from 15.3k. Thirteen sections are packages (tabulated-list,
window, tramp, chat-mode, modeline, isearch, capf, visual-line, collect,
comint, transient, chrome, and dired stays in priv but loads from
init.scm). One catalog, one mode table, keyed hooks for every registry
and seam, defvar with persist, the alist and plist builtins, sh-quote as
a builtin, the block files without their prologue dance. Every failure
seen on the way is in docs/KNOWN-FAILURES.md with the HEAD it was
measured at. What remains, and why it waits:

- Rulings: the five keys bound in two files (C-x b, C-_, C-t, C-c RET,
  RET); merging y-or-n into y-or-n-p (23 sites); the sentry.scm cut and
  one PTY runner (something a person runs today).
- Phase 2 (section 4 and 5 designs: the window domain, the chat and
  llm-mode merge, the agent config record) touches files another session
  holds and changes behaviour; it needs its own plan and a green baseline
  for the layout tests, which are red at HEAD today.
- One-shot boot migrations (llm-bundles-assign-keys at load, the chat
  record and input migrations on restore) want one desktop migration
  pass with a cut-off; themes.scm's face restatements and the 22
  unreferenced face aliases want a measurement of the CSS side first.
- Phase 3 (runtime) and Phase 4 (the execution model benchmark).

**Later on 2026-09-19:** the LSP client speaks through the shared JSON-RPC
framer (four of the five framers are one now); ChatPerf is gone;
chat-dismiss works again and nine dead definitions went; 25 redundant
package! stamps went; one clock for the connection logs. Checked and left
in place, with the reason: the buffer batch fields serve the public
buffer-provenance-start! primitive (item 8.5 was wrong about that); the
bookmark commands are two-line delegations, not stubs (6.7 was wrong);
display-memory-mode is on by default, so its boot timer is right (6.8 was
wrong).

**Phase 1, started 2026-09-19.** One catalog (b39191ca): define-command
and public! write one table, `*command-fns*`, `*command-names*`,
`*public-api*` and `*public-keys*` are gone, and `public-api` is a view.
Twenty dead definitions and the shadowed preview block went (b5302dd4).
One mode table: `*modes*` holds every fact about a mode as a plist under
its name, `mode-put!` and `mode-get` read and write one fact,
`mode-inherited` walks the parents, and `(define-mode NAME SETUP 'parent P
'doc D 'icon I 'minor #t 'teardown T 'keymap K)` takes every fact in one
form. The seven side tables (`*mode-setups*`, `*mode-parents*`,
`*mode-docs*`, `*mode-icons*`, `*mode-link-syntaxes*`, `*mode-layouts*`,
`*mode-headlines*`), `*dismissible-modes*` and `*minor-mode-setups*` are
gone; the old setter names stay as one-line doors, so the 160 callers did
not change. `plist-put` is a builtin beside `plist-get`, and the 49
copies of the alist upsert idiom are `(alist-put TABLE KEY VALUE)`; the
alist builtins step over an empty entry. Landmine met: a Nerd Font glyph
is invisible in a terminal, and a rewrite typed from the screen replaced
twelve mode icons with empty strings; the fix was a script that copied
them back from HEAD. Read a glyph line with `unicode_escape` before you
retype it.
Keyed hooks: `(add-hook! '(block-click diff) FN)` holds one function per
key and the same key replaces, so the six keyed registries
(`*preview-link-verbs*`, `*lsp-event-handlers*`,
`*input-intent-handlers*`, `*endpoint-event-handlers*`,
`*block-click-handlers*`, `*agent-turn-end-handlers*`) and their on-X!
setters are gone, the five older spellings (on-fs-change!,
on-buffer-created!, on-buffer-woken!, on-buffer-renamed!,
on-buffer-shown!) are gone, and the `boundp` guards in front of them went
with them. The four one-function-per-key registries (`*marginalia*`,
`*context-providers*`, `*target-providers*`, `*display-buffer-actions*`)
are keyed hooks too, behind their old setter names. docs/HOOKS.md lists
the keyed hooks. Left as they are, with the reason: `*embark-actions*`
holds a list of actions per type, not a function; `*paste-hooks*` keeps
registration order and replaces in place, which a keyed hook does not.
Still to do in this item: the re-`set!` seams and the remaining boundp
guards.
Sections out of editor.scm, first move: the tabulated list (2,014 lines)
is `scheme/packages/tabulated-list.scm`, the first load in init.scm;
dired.scm reads the list registry at load, so it left the Elixir
bootstrap list and loads second from init.scm. editor.scm is 13,147
lines. The move is a cut: no definition changed. Rule for the next
moves: cut on a section header, check that nothing outside the block
names a block definition at load time (a top-level call, or the value of
a `define`), and put the new file in init.scm ahead of its first caller.
Second move: the chat buffer, the LLM pipes, the chat locals lists, the
.chat format, the backends and the C-c b setup (2,185 lines) are
`scheme/packages/chat-mode.scm`, loaded third from init.scm; the block
had inherited the terminal section's catalog scope (domain processes),
so the file now declares domain chat. editor.scm is 10,962 lines.
Third move: the modeline dashboard and the buffer-name grammar (1,219
lines) are `scheme/packages/modeline.scm`, loaded fourth; desktop-skip!
stayed in the kernel beside its callers in the buffer cache. editor.scm
is 9,744 lines.
Then: the list-mode definers (define-list-mode!, list-mode-init!,
list-mode-show!) joined tabulated-list.scm, the cost commands joined
chat-mode.scm, and the public! and catalog-meta! lines of every moved
definition moved into its file under the catalog scope they had; three
global bindings that rode along came back. editor.scm is 9,482 lines.
Fourth move, four files at once: collect.scm (embark-collect), comint.scm
(term-mode, comint-shell-mode, tail-mode), isearch.scm (isearch, lazy
highlight, hl-line, replace) and capf.scm (completion at point). The cut
script keeps each block's ambient catalog scope: it writes the scope in
force at the block's start into the new file and restores the scope the
block left behind at the cut point. editor.scm is 8,707 lines. The mark
ring and font-lock keywords stay: the first is an Emacs mechanism, the
second is called from set-mode!.
Fifth move: the window domain (display-buffer, popups, the look, peek,
mode layouts, the pool, special-mode, winner, the window questions,
tiling: 2,540 lines) is `scheme/packages/window.scm`, loaded second
because a list mode derives from special-mode at load; visual lines are
`visual-line.scm`. editor.scm is 5,964 lines. What stays and why: the
catalog, define-command, the buffer cache, editing and the kill ring,
the minibuffer and completing-read, hooks, variables, marginalia, hot
reload, modes and minor modes, savehist, buffer waking, renaming and
detaching, the name at point, providers and embark, motion, capf's
callers, scrolling, the mark ring, font-lock (set-mode! calls it),
files and write policy, load-path, delete-file, the remote and visit
block (visit and find-file live in it), M-x and eval, the prefix maps,
self-insert, the movement state, input intents, buffer links, daemon
control and the default keymap.
Sixth move: the remote half of the file block (remote-ls, remote-sh!,
the file operations that branch on /ssh:, remote-visit) is
`scheme/packages/tramp.scm`, loaded before dired; visit and find-file
stay in the kernel under their own header. editor.scm is 5,685 lines.
Landmine met: the test home keeps files between runs, and a note.txt a
run left on 2026-09-15 turned a plain write-file test into an overwrite
question; the fresh-dir helper now empties its directory first.
One defvar with persist (item 7, second half): `(defvar '*x* DEFAULT
'persist #t)` registers the desktop global itself, keyed by the name
without its stars, and a restore puts the saved value back or the
default. Seven of the fourteen persist-global! pairs are one line now;
the seven that normalise or rebuild on restore (llm-config-history,
llm-bundles, group-mru, groups-v2, hidden-windows, layout-targets,
and the composite ones) keep persist-global! as the door.
The re-set! seams are gone (item 8, the rest): candidate-face-for,
find-file-group-reader, buffer-project-label, buffer-workspace-label,
buffer-project-root, buffer-kill-repair and switch-buffer-source are
functions that ask a keyed hook and fall back to their old default, and
window-state-changed! runs window-state-change-hook; the packages that
used to set! them add a hook under their own key. docs/HOOKS.md lists
them. Item 8 of section 3 (24 commands with no key and no caller):
recounted after the moves, editor.scm has 6 commands nothing names
(desktop-clear, buffer-rename, display-line-numbers-mode, write-rules,
delete-file, load-file); they are M-x vocabulary with Emacs names and
stay. Left in the item: the seven boundp guards in editor.scm, all
call-time guards for optional packages.
Item 8 of section 3, the guards: 84 boundp guards on names that a stock
package always defines went from function bodies (an sexp-aware script
in the scratchpad: `(when (boundp 'x) BODY)` is BODY, `(if (boundp 'x) A
B)` is A, `(and (boundp 'x) REST)` is REST). 61 remain: guards on
opt-in packages, on names nothing defines (dead branches), the
reload aliases (raw-write-file!, raw-buffer-save!, buffer-kill-raw!),
and top-level `unless` forms that define when missing. The dead C-x b
line in editor.scm went; switch.scm's binding was the live one. The
C-_ and C-t overrides are deliberate per their comments (undo keeps C-/
and C-x u), so they stand.
Item 16 of section 3, second half, checked and left: the 37 Emacs face
names in themes.scm are `defface!` forms that inherit a compos face, and
the section's own comment says they exist so a package written for
Emacs finds font-lock-keyword-face; a reference count does not decide
an API surface. The four palettes restate the ts faces because
load-theme writes only the faces a theme names, as the paper palette's
comment says; a base palette with overrides changes that contract and
waits.
Section 5 item 15, sentry.scm: the list, detail and events buffers,
their verbs and their three modes are gone; the file is its credentials,
the wire, the five API calls a model reaches through eval, and the one
text rendering of an issue (361 lines from 915). Nothing outside the
file named any of the 73 definitions; the test covers the API and the
text.
Item 16 of section 3, first half: transient.scm and chrome.scm are
packages in scheme/packages, loaded from init.scm (transient first, a
package defines its prefixes at load; chrome after dired, sentry and
code read it at load). The Elixir bootstrap list is editor.scm,
themes.scm, init.scm.
Item 13 of section 7 (dual spellings), checked: of the nine pairs only
two were the same function under two names. keymap-set! (define-key)
and buffer-set-hidden! (fold-set! without a tag) are gone. The other
seven differ in what they take: the current buffer against a named one
(point, goto-char!, local-set-key), the selected frame against every
frame (window-list), the active window against one by id
(delete-window!), the window against the frame root (split-window!),
and minibuffer-read against its handler-alist form; they stay.
Item 13 of section 3 (reimplemented builtins): take-n is the take
builtin (36 sites), transient--put is plist-put, list-tail-n is
list-tail, abbreviate-home is abbreviate-file-name; nth stays as the one
Emacs-named line over list-ref. name--trim-left and name--trim-right
looked unreferenced but are passed as values, so they stay. Item 15
(keys bound from several sections): the duplicate M-< and M-> lines
went. Five keys are bound in two files and the later file wins; these
are policy and wait for a ruling: C-x b (switch.scm ibuffer-prompt over
switch-to-buffer-prompt), C-_ (appearance.scm text-scale-decrease over
undo, the Emacs binding), C-t (telemetry.scm telemetry-toggle over
transpose-chars, the Emacs binding), C-c RET (chat-companion-ask and
goto-address-at-point), RET (preview.scm preview-newline over
newline-or-send). Item 5 (prompt doors), checked: read-char takes any
key and read-char-choice a key from a set; y-or-n takes two thunks and
y-or-n-p one continuation; yes-or-no-p takes a word. They are four
readers, not five copies. Merging y-or-n into y-or-n-p means rewriting
23 call sites; it waits.

**Phase 2, item 5.9, first cut (2026-09-19):** the one permission
decision is a function, `(permit? BUF TITLE KIND RAW)`, and the ACP
lane, the direct lane, the MCP proxy and the restart-daemon command call
it by name; the variable that held a lambda and the boundp guards around
it are gone. The nine Scheme tests that specify the policy pass. The
rest of 5.9 (fewer inputs to the decision) drops tested behaviours
(profiles, the effects verdict, Always rules) and is a ruling.

**Phase 2, item 5.10, measured (2026-09-19):** the config record does
not exist six times. The bundle in chat-mode.scm (connector, model,
effort, presets, permission, agent-mode, prompt-disabled, setup) is the
record, with 30 accessors and a normaliser for older desktops; the
connector "record" is six read accessors over the connector table; the
MCP server list is one plist; setup.scm asks one predicate; the
workspace defaults are four lines that read a bundle. What the item
really names is mcp-hub.scm, a 382-line list view with 13 commands over
the MCP servers, and llm-config.scm's 951 lines of pickers over the
bundle. Both are surfaces a person uses; folding them into one picker
is a design and a ruling, not a cut.

**Phase 2, item 5.1, measured (2026-09-19):** llm-mode is not a stray
second lane. code-agent-mode turns it on in a code buffer, writing-mode
turns it on in the document's scratch, scratch.scm copies it to a
scratch, the MCP proxy targets the buffer that wears it, prompts.scm and
the buffer lifecycle reset its runtime, and M-o, M-|, C-c m and C-c b
are its keys; ten test files specify it. Removing it means redesigning
code-agent-mode, the writing scratch and the proxy's target rule, and
deciding where an inline answer goes. That is the chat merge (5.1, 5.11,
5.12) as one project, and it is last in the Phase 2 order for that
reason.

**Phase 4, measured (2026-09-19).** The benchmark is
apps/compos_core/test/bench/ui_latency_bench.exs. A stub agent streams
1,500 chunks into its chat in one turn; 300 evals of `(+ 1 1)` run on
the :ui lane during the turn, 60 more queued on the chat's own buffer
lane, and 300 on :ui with nothing running. Three runs, microseconds:

| series | p50 | p95 | p99 | max |
|---|---|---|---|---|
| :ui, idle | 10-11 | 22-26 | 49-119 | 256-479 |
| :ui, under the turn | 11-12 | 25-36 | 35-88 | 53-1,393 |
| the chat's buffer lane, under the turn | 10-13 | 38-43 | 9,243-10,282 | 979,167-986,663 |

The lanes do their job: a :ui eval under a streaming turn costs what it
costs idle. The 0.99 s on the buffer lane was one job, and timing the
turn-end handler step by step found it: the first `chat-should-compact?`
of the VM decodes the bundled LLMDB snapshot (942 ms) inside
`llm-context-limit`, on the chat's own lane, in front of every keystroke
queued there. The boot warmup task decodes the catalog now
(ModelCatalog.warm), and a batch is bounded to 200 events as well as to
the 25 ms frame. After the fix, the same runs:

| series | p50 | p95 | p99 | max |
|---|---|---|---|---|
| the chat's buffer lane, under the turn | 13-15 | 49-59 | 3,448-3,730 | 9,673-11,910 |

A keystroke queued behind a streaming render now waits at most ~10 ms,
and the turn-end costs 3 ms. On this evidence one serial Scheme world is
within reach: the worst wait behind a burst is a frame, not a second.
The collapse of env.ex, gc, roots, flush, the heir dance and the retry
loops is Phase 3 proper, and this benchmark is the gate it runs against
before and after.

**Phase 3, checked (2026-09-19):** item 16 (the per-message
Desktop.upgrade and Buffer.upgrade) stays: Hotload swaps a module without
code_change/3, and the upgrade is what lets a running process read its
old state under the new module (editor.ex says the same beside its
take-once slots). The Buffer moduledoc and two comments that still
described a SQLite store now describe the Loro log. read_many_fallback
is the miss path of the row cache and stays. What is left of Phase 3 is
the four rewrites (one store, one read model, one wake path; Scheme
keymaps; one Display row model and one LiveView; one event stream) and
the world collapse behind the Phase 4 gate.

**Ruling 2026-09-19 (the owner): mcp-hub stays.** The hub is the inventory
of the MCP servers the system can run; a bundle is a selection from it.
Two roles, two surfaces. Item 5.10 keeps both and collapses the record:
one server table that the hub, the bundle picker, setup's program
registry and the workspace defaults all read, and a bundle names its
servers by name instead of carrying a copy of each.

**Item 5.10 closed by measurement (2026-09-19).** Under the ruling above
the code already has the shape it asks for: `*mcp-registry*` in mcp.scm
is the one server table; mcp-hub reads it directly (mcp-hub-names,
mcp-hub-spec); a preset is a named set of server names; a bundle names
presets; the workspace defaults hold a bundle plist; setup.scm asks one
predicate. No copy of a server record exists to collapse. The two
"compos" special cases are the editor bridge, whose tools are not an
MCP server on the wire, and they stay. Nothing to do.

**Ruling 2026-09-19 (the owner): llm-mode stays and is the lane.** The
gptel model: you talk in the buffer you are in, and the reply lands
there. A chat is a buffer in llm-mode. Item 5.1 inverts: the merge folds
chat-mode onto llm-mode (the transcript blocks, the tools, the ACP
backends and the permission ask become what llm-mode does in a chat
buffer), and llm-mode handles both chats and documents. Wanted later: a
gptel-like `C-u M-o` that directs the output (at point, to the group's
chat, to a new buffer, over the region). Nothing in-buffer goes.

**The chat merge, the plan (2026-09-19, agreed in outline):** the
transport is the chat runtime, one session, one backend, `permit?`, the
tools, the record. A document that talks gets a companion chat, one per
buffer, made on the first M-o and hidden until opened; it is the
conversation of record for that document, and the group chat is not
touched. Where the reply lands is a render target: plain M-o renders the
turn into the document at the mark, gptel style, and `C-u M-o` picks the
target (at point, the companion pane, a new buffer, over the region).
llm-mode keeps its prompt and response faces, the mark that chases
edits, C-g abort and M-| for a region; it loses its own dispatcher,
context function and permission stub. Steps: (1) llm-mode sends through
the companion, rendering unchanged; (2) the companion's turn-end feeds
the in-buffer render from the record; (3) `C-u M-o` targets; (4) the
llm-mode dispatcher, context fn and permission stub go; (5) 5.12's twin
transcript primitives collapse onto one set.

**The layout tests, bisected (2026-09-19).** The same six files at three
commits: fc980588 (the other session's last commit, before Phase 1) 27
red, 015d9a50 (the catalog, the mode table, the keyed hooks) 25 red,
9b0e7411 (the tabulated-list move) 24 red. The one name red later and
green at fc980588 is a-target-layout-does-not-give-one-mode-two-panes,
which passes alone and flips with order. Phase 1 did not turn the layout
tests red; they were red before it, from the listing-preview and target
layout work in flight. The editor's layout works after a restart; the
owner reports it slow, which is section 4a's first-class defect and is
measured before it is named.

**Wanted later (owner, 2026-09-19):** a hot refresh that unloads and
loads all Scheme, so a registry migration does not need a restart.

**4a, the slow layout prompt, found (2026-09-19).** The rows named it:
every arrow in the layout prompt cost 100-140 ms per chat pane in
EditorLive's decorate, with `hit false` on the agent block cache and
575 blocks re-rendered. The cache was keyed by window id, and the tiler
hands window ids out by leaf order, so after one move the window held a
different chat than the entry and every block re-rendered, markdown and
all. The agent and block caches are keyed by buffer now and die when the
buffer leaves the tree. On the way: the prompt applies a candidate to
the visible panes without restoring first, the refresh row names the
slowest leaf, and the slow-job log names the callback.

**Ruling 2026-09-19 (the owner): unify the transport; a document's chat is
a hidden chat you can ask to see.** Step 1 of the chat merge is in: an
M-o session answers a permission through `permit?` under the document's
stance, on both lanes (the direct lane's permission function and the
ACP-lane permission event). An `ask` is a y-or-n question in the
minibuffer, because the hidden chat has no pane for a card; a refusal is
silent. The allow-everything stub is gone. Step 2 is in: the first M-o
in a document makes `*chat:<document>*`, a real chat buffer attached
through chat-attach-agent! with the document's connector, model,
presets, directory and stance, hidden until `M-x llm-companion-show`.
The document's session is that chat's; the document still builds the
wire from its own text and the chat records the turn; the chat's event
handler forwards every event but the permission to the inline render,
and an ask in a hidden chat is a y-or-n question in the minibuffer.
The `inline-N` sessions, the inline event handler's own session open
and the permission stub are gone. Next: `C-u M-o` targets, then the
inline dispatcher and context function fold into the chat's.

**Phase 2 entry conditions (2026-09-19).** Phase 2 rewrites behaviour in
groups.scm, layouts.scm, ibuffer.scm, editor.ex and the chat lane. It
starts when all four hold, and not before:

1. The layout tests are green at HEAD: layout-policy, group-switch,
   autolayout, window-config, detail and the ibuffer prompt tests (26
   names in docs/KNOWN-FAILURES.md, red today from the listing-preview
   work in the other session). A redesign with a red baseline cannot
   tell its own breakage from the inherited one.
2. The other session has landed its groups, layouts and ibuffer work;
   git status shows none of those files dirty for a day.
3. A one-page design for each item, agreed first: the window leaf with
   `side` and `owner` (4.2), the `display-preview` action (4.6), the
   config record (5.10), and what M-o does once llm-mode is gone (5.1).
4. The measurements in 4a repeated on the design branch before and
   after, since window rearrangement time is first class.

Order inside Phase 2 once open: the config record (5.10, tests in
transient-test and llm-setup-test), permit? (5.9), the display-preview
action (4.6, tests in display-buffer, peek and detail), then the chat
merge (5.1, 5.11, 5.12) last because every chat test that could guard
it is red on the fake transport today.

**Next three steps, in order.**

1. `load-path`: the defvar in editor.scm, `load` searching it in Scheme over
   the one-path builtin, Hotload and the write roots reading it,
   `load-bundled-package` deleted. One commit; tests in
   `priv/tests/load-path-test.scm`. No file moves, so it does not collide
   with other sessions.
2. The move: `git mv apps/compos_core/priv/packages scheme/packages` once the
   tree has no uncommitted package edits, plus the release step. One
   commit, no code change.
3. In parallel with either: the Phase 0 deletions that touch nothing anyone
   is editing. The 52 unreferenced primitives, SchemeActor, the 43 test
   wrappers, the `plist-get` builtin fix and its 25 wrappers, the secrets
   seam.

**Phase 0, mechanical and safe.**
1. Delete: 52 unreferenced prims, 25 dual spellings, SchemeActor, the 43
   test wrappers, the Elixir half of the 40 double-covered features, demo-app
   tests, dead commands and functions from sections 3.8 and 5.14, root cruft,
   stale worktrees, 44 docs.
2. Move every package to `scheme/packages/` at the project root; priv keeps
   the kernel. Drop the 15 personal apps, calendar, and org.scm from
   init.scm. homepage_live.ex becomes static HTML in the repo.
3. Secrets seam: `secret-provider` custom in keys.scm; delete
   `key--from-doppler`, the `*-doppler-project` customs in sentry and
   google, doppler.scm; the provider is one lambda in user config.
4. Builtins: plist-get returns #f on non-list; alist-put!/get/delete;
   string-replace, html-escape, take, string-clip, first-line, basename;
   buffer-set-text!; time-label. Delete the ~110 private copies.
5. One test support module: eval!, press, wait_until, one FakeTransport.

**Phase 1, registries.**
6. One catalog; public! = catalog-register!; one `prim` macro with docs;
   each connector exports its primitives; drop domain!/category!/
   namespace!/catalog-meta!, keep one 'effects tag.
7. One define-mode with keyword args and mode-get; one defvar with 'persist.
8. Keyed hooks replace the on-X! wrappers, keyed registries, re-set! seams
   and the 79 boundp guards. Declared `requires` order init.scm.
9. Move whole sections out of editor.scm: lists, chat/LLM, dashboard,
   layouts, peek, popper, isearch, remote, terminal, collect, palette,
   visual lines. editor.scm lands at ~4k.

**Phase 2, domains.**
10. Windows: window-configuration value; leaf side/owner; one
    display-preview action; one MRU; one arrange!; list-mode 'surface;
    fold *frame-locals* into the frame; split chat naming out of groups.scm.
11. Agent: config record; permit?; eval + ask + apropos-as-function; Backend
    base + JsonRpc over Endpoint.Conn; delete codex_app_server if codex-acp
    works; one chat.scm with one transcript module; delete llm-mode; trim
    sentry, worktrees, jj, prompts, title/summary.

**Phase 3, runtime.**
12. Loro log is the text and the author record; catalog derived; one read
    model; one wake path; code_change instead of per-message upgrade.
13. Minibuffer is a buffer with a mode; keymaps are Scheme data; motion and
    kill policy in Scheme; landing policy out of the Editor GenServer.
14. One Display row model in core; one LiveView; static app.js/editor.css;
    Markdown.Html owns the document; "agent" render mode folds into
    "blocks"; Scheme composes modeline and header blocks.
15. One event stream + one sample; drop Profiler, live_dashboard, ChatPerf,
    the SVG builders.

**Phase 4, decision.** Benchmark `:ui` latency under an agent turn with one
serial Scheme world. If it holds, collapse env.ex, gc, roots, flush, the
heir dance and the retry loops.

## 11. Rules so it does not grow back

- A seam in core is one custom that holds a function. The provider lives in
  user config. No wrapper package.
- Scheme that is not the kernel lives in `scheme/packages/` at the project
  root. An app that the editor does not need is out of init.scm; the user
  init loads it by name.
- A package registers data at load and does nothing until its mode runs.
- A defcustom needs a second reader or a user story. Otherwise `define`.
- A command needs a key, a menu, a hook, or a caller. Otherwise it is a
  function.
- A primitive needs a production caller. A test is not a caller.
- One fact, one store. A second store is a cache and must be derivable in
  one call.
- A new mechanism must name the existing one it could not use.
- The kernel calls no package name. Packages add hooks; the kernel runs them.
- Comments state the contract. History goes in git.
- Tests: Scheme tests policy through the function; Elixir tests mechanism;
  no test presses a production chord.
