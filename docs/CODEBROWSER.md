# Code browser

The code browser is how a person reads a codebase an agent wrote. The
reader sees a summary at every level: the project, a directory, a file, a
definition, a change. Every summary stays true to the code, and every name
in a summary is one key from the code it names.

This document is the user experience. `docs/CODE-BROWSER-PLAN.md` is the
mechanism and the build order. This document is in this order:

1. The model.
2. The user stories.
3. The screens.
4. The rules: levels, keys, the peek, summaries, freshness, changes, links, presets, agents, persistence.
5. The acceptance list.

## Model

### Objects

- A **project** is a git checkout. Its root is the top level.
- A **node** is one thing the reader can stand on: the project, a directory, a file, or a definition. A node has a path and, for a definition, a line.
- A **summary** is one morg file about one node, in `<root>/.compos/scope/`. A file summary says what the file does, why it exists, who calls it, and what to watch. A directory summary says what lives here, one card per entry. The project summary says what the project is, what to know, and how to run it. `recent.md` says what changed lately.
- A **level** is one list buffer that shows the children of one node. The project level shows the root's entries. A directory level shows its entries. A file level shows its definitions (the outline).
- A **flight** is the reader moving between levels with four keys and reading the peek as they go.

### The three rules

1. Every node has a summary, or a row that says it has none. The reader never meets an empty page.
2. A summary is fresh or it says `stale`. The reader never reads a lie without a badge on it.
3. Every name in a summary reaches the code with `M-.`: a path, a module, a function, a Scheme name. A name that reaches nothing says so and opens nothing.

## User stories

Read each story as a path:

> As a reader -> in this situation -> I want this outcome -> the editor behaves this way -> I use this command.

Some outcomes are automatic. Then the solution is a rule, not a command.

### As a reader who comes back to a project

#### I want to know what the agent did while I was away

- `M-x scope` opens the project level. The header is the project in one paragraph. Rows with `M` are the files the working tree changed; rows with `stale` are the files whose summary is behind the code.
- `r` opens `recent.md`: what the last commits did, what is in flight.
- **Commands:** `scope`, `scope-recent`.

#### I want to see the changes themselves, with the reasons

- `c` at the project level opens the diff: one card per file, hunks folded.
- `e` on a card explains it: intent, mechanism, risk. The same call brings the file's summary up to date.
- `j` and `k` in the diff walk the cards; `RET` on a hunk visits the line.
- **Commands:** `scope-changes`, `diff-explain`, `diff-visit`.

#### I want to check that a change did what the explanation says

- In the explanation, `M-.` on a name peeks the definition as it is now. `M-.` again goes there. `M-,` comes back to the explanation.
- **Command:** `definition-peek`.

#### I want to catch up on one directory, not the whole tree

- `l` into the directory. Its header says what lives here. Rows with `M` or `stale` are where the work happened.
- `c` there opens the diff for that directory only.
- **Commands:** `scope-descend`, `scope-changes`.

### As a reader new to a codebase

#### I want the shape of the project before any file

- `M-x scope`. The header is one paragraph; the rows are the top-level entries, each with one line.
- `j` and `k` show each entry's full summary in the peek as point moves. No file opens.
- **Commands:** `scope`, list motion.

#### I want to walk down to the code without losing my place

- `l` into a directory, `l` into a file, `l` onto a definition: the code shows with `code-browse` on. `h` returns one level, with point on the row I came from, every time.
- **Commands:** `scope-descend`, `scope-ascend`.

#### I want to read a file's summary before its code

- On a file row, the peek shows the summary. `d` opens it and selects it. `q` returns to the list.
- **Command:** `scope-doc`.

#### I want to see a file's definitions with what each one does

- `l` on a file row opens its outline: line, kind, name, and doc for every definition. The peek is the file, and the row's definition carries the tint.
- **Command:** `scope-descend`.

#### I want to find the code behind a name I just read

- In any summary, `M-.` on the name peeks the definition. A path peeks the file, `path:42` peeks the line, `Mod.fun` peeks the function.
- A name that reaches nothing says "No definition of NAME" and opens nothing.
- **Command:** `definition-peek`.

#### I want to jump to any definition in the project by name

- `M-x scope-find` reads a name with completion over every definition in the project. `RET` opens the file level with point on it; the peek shows the code.
- **Command:** `scope-find`.

#### I want to narrow a big directory to what I am looking for

- `/` narrows the rows on every keystroke, over the name and the one-liner. `\` widens.
- **Rule:** list narrowing, as in every table.

### As a reader who opens a file first

#### I want the summary of the file I am in

- `M-x scope-here` opens the file's level with point on the definition at point. `h` goes to its directory.
- **Command:** `scope-here`.

#### I want the summary of the definition I am in

- `M-x scope-here` in a file level shows the doc column for the definition at point; `d` opens the file summary at its paragraph about that definition when one exists.
- **Command:** `scope-here`.

### As a reader whose summaries do not exist yet

#### I want summaries for a project that has none

- Every row shows `?`. `G` at the project level bootstraps: files first, then directories, then the project page. The footer counts what landed. Rows fill in as they land; the budget bounds the run and the footer says when it stops.
- **Command:** `scope-bootstrap`.

#### I want one summary now

- `g` on the row queues it. The row shows `~` while the job runs, then its one-liner.
- **Command:** `scope-refresh`.

#### I want the summaries without spending on a large tree

- `scope-auto-refresh` off keeps the queue quiet; badges still show. `G` on one subdirectory bootstraps only that subtree. The `summarize` preset's tier is `fast`; `.project.scm` can set a cheaper model.
- **Rules:** freshness, presets.

### As a reader who edits

#### I want to correct a summary

- `d` opens it as a morg buffer. I edit and save. The summary keeps its key, so it stays fresh until the code changes. The next refresh carries my text as the existing doc and asks the model to keep what still holds.
- **Command:** `scope-doc`.

#### I want the summary to follow my edit to the code

- Saving the file marks its row `stale`. With auto-refresh on and budget left, the queue refreshes it; the directory and the project follow after their children settle.
- **Rule:** freshness.

#### I want a summary kept as I wrote it

- `#+pin: yes` at the top of a summary keeps the queue off it. The row shows `pinned` instead of `stale` when the code moves.
- **Rule:** summaries.

### As a reader who watches an agent work

#### I want to see what the agent touches as it works

- The scope level and the diff both follow the filesystem. A file the agent saves shows `M` and `stale` on the next draw; the diff card appears.
- **Rule:** the watch.

#### I want the explanation of the agent's change before I read the diff

- `e` on the card. The explanation folds open under the card, above the hunks.
- **Command:** `diff-explain`.

#### I want a chat about this file with the summary in it

- In a chat, `@explain` with a question sends the turn with the explain preset's tools, so the model reads the summary through `scope-read` before it answers.
- **Rule:** presets.

### As an agent

#### I want to read the codebase by its summaries before I read its files

- `(scope-outline ROOT)` returns every node with its one-liner and its freshness. `(scope-read REL)` returns one summary. Both are tools in the `explain` and `coding` presets.
- **Tools:** `scope-outline`, `scope-read`.

#### I want my edits to leave the summaries true

- An agent's save makes the file stale like any writer. The queue refreshes it on the same rules. An agent that wants the summary now calls `(scope-refresh! REL)`.
- **Tool:** `scope-refresh!`.

## The screens

### The project level

`M-x scope` opens the project level in the project's group. The list is on the left, the peek is on the right.

```
+-- *scope: compos --------------------------------+-- files/apps/compos_core/priv/packages/code.scm.md --+
| compos                                             | code.scm reads a source file with structural keys.  |
| Emacs rebuilt on the BEAM, scripted in Scheme,     | It is a minor mode: the buffer keeps its major mode |
| rendered by Phoenix LiveView. 4 apps, 312 files.   | and its file. h/l walk the tree, j/k the siblings.  |
|                                                    |                                                     |
|   apps/            the four umbrella apps          | It exists because an agent writes code faster than  |
|   docs/            specs, plans, the handoff       | a person reads it. Called from code-browse and by   |
|   bin/             test-fast, the release script   | imenu, which reads its outline (imenu-rows).        |
|   config/          runtime.exs and the ports       |                                                     |
|   CLAUDE.md        the working instructions        | Watch: nested tree-sitter nodes can share one byte  |
|   README.md        what the project is             | range, so a node is (kind start end), never the     |
|   mix.exs          the umbrella manifest       M   | range alone.                                        |
|                                                    |                                                     |
| 7 of 7 . 2 stale . budget 58/60 . r recent . c changes                                                 |
+----------------------------------------------------+-----------------------------------------------------+
```

The header is the project summary's opening paragraph. Each row is one entry with the first line of its summary. The footer counts the rows, the stale summaries, the refresh budget left this hour, and the keys that change the view.

### A directory level

`l` on `apps/` opens `*scope: apps*` in the same window. `l` again on `compos_core/`, and again on `priv/packages/`:

```
+-- *scope: apps/compos_core/priv/packages ----------------------------------------+
| The bundled packages: every mode, command, and list the editor ships.            |
| init.scm loads them in dependency order.                                         |
|                                                                                  |
|   agent.scm          the chat's turn loop and its tool calls                     |
|   annotate.scm       margin notes on any buffer                     stale        |
|   chat.scm           the conversation of record and the tool surface            |
|   code.scm           read a source file with structural keys        M           |
|   components.scm     the ui/* block components                                   |
|   diff-mode.scm      the git diff as cards, following the filesystem            |
|   lsp.scm            diagnostics, definition, references, hover                  |
|   morg/              babel blocks and tangling for morg documents                |
|   peek.scm           look at a definition without going there                    |
|   scope.scm          this browser                                    ?          |
|                                                                                  |
| 61 of 61 . 3 stale . 1 without                                                   |
+----------------------------------------------------------------------------------+
```

Badges on the right: `stale` when the code moved since the summary, `?` when there is no summary, `~` while a refresh runs, `M` when git says the file is modified, `!` when it is in conflict. The peek on the right shows the row's full summary and follows `j` and `k`.

### A file level

`l` on `code.scm` opens its outline: one row per definition, from `imenu-rows`. The peek on the right is now the file itself, and the row's definition carries the code-browse tint.

```
+-- *scope: apps/compos_core/priv/packages/code.scm ---------------------------+
| code.scm reads a source file with structural keys. It is a minor mode.       |
|                                                                              |
|    23  defcustom  code-browse-fold-lines   fold definitions past this many   |
|    44  define     code--pick-backend!      ts when a grammar parses, else    |
|    92  define     code--anchor             point at the start of the code   |
|   399  section    go to definition         the seam for LSP                 |
|   423  define     code--goto-definition    LSP when attached, else the same |
|   554  command    code-browse              toggle structural browsing       |
|   759  define     code-outline             (LINE KIND NAME DOC) rows        |
|  1463  command    imenu                    jump to a definition             |
|                                                                              |
| 41 of 41 . tree-sitter                                                       |
+------------------------------------------------------------------------------+
```

`l` on a definition selects the right window at that definition with `code-browse` on. `h` there comes back to the outline. `h` on the outline goes to the directory, with point on `code.scm`.

### The summary page

`d` on any row opens the node's morg summary in the right window and selects it. It is a plain morg buffer: fold it, edit it, save it. `M-.` on a name in it peeks the definition; `M-.` again goes there; `M-,` comes back. `q` returns to the list.

```
#+scope: file
#+path: apps/compos_core/priv/packages/code.scm
#+source: 9f1c2a7
#+written: 2026-08-30T12:04:11Z

code.scm reads a source file with structural keys. It is a minor mode:
the buffer keeps its major mode and its file. `h` and `l` walk the tree,
`j` and `k` walk the siblings, `TAB` folds a body.

It exists because an agent writes code faster than a person reads it.
`code-browse` is the reader's verb set. `imenu` and the `scope` file
level read its outline through `imenu-rows`, and an agent reads the
same outline through `code-outline`.

Watch: nested tree-sitter nodes can share one byte range (an Elixir
`arguments` node and the call inside it), so a node is
`(KIND START END)`, never the range alone. See `docs/code-browse.html`.
```

### Changes

`c` at any level opens the diff for that node: the whole tree at the project level, one directory, or one file. It is the existing diff-mode: cards per file, hunks folded, following the filesystem. `e` on a card explains it:

```
+-- *git: compos ----------------------------------------------------------------+
| v apps/compos_core/priv/packages/code.scm                    +41 -6   explained |
|   v what changed                                                                |
|     Adds a `code--doc-inside` reader so the outline's DOC column takes the      |
|     docstring inside a definition when nothing sits above it. The heredoc      |
|     branch trims the closing quotes. Risk: a Python file with a bare string    |
|     as its first statement reads as a docstring; that matches Python's rule.   |
|   > @@ -637,6 +637,24 @@                                                        |
|   > @@ -683,4 +701,9 @@                                                         |
| > apps/compos_core/priv/tests/code-test.scm                  +18 -0             |
+--------------------------------------------------------------------------------+
```

The same call rewrites the file's summary, so after `e` the file row is fresh again. `r` at the project level opens `recent.md`: the last twenty commits and the working tree, in two paragraphs.

## Rules

### Levels

1. A level is one list buffer named `*scope: REL*`; the project level is `*scope: NAME*`. A level opened twice is the same buffer.
2. `l` opens the child level in the same window. `h` opens the parent level in the same window and puts point on the row the reader came from.
3. The file level's rows are `imenu-rows`: tree-sitter where a grammar parses the file, indentation elsewhere, headings for a morg file. Every file has a file level.
4. `l` on a definition row selects the right window at the definition with `code-browse` on. `h` in that window returns to the file level. This is the bottom of the flight.
5. Every level enters the project's group (docs/groups.md). A peek says nothing about the group.
6. `M-x scope-here` opens the level of the current buffer's file with point on the definition at point. `M-x scope-find` reads a definition name with completion over the project's outline index and opens its file level on it.

### Keys

The alphabet is code-browse's, so the reader learns one set. No global binding claims a key; `M-x scope` opens the first level.

| key | command | does |
|---|---|---|
| `l`, `RET` | `scope-descend` | into the row: a directory's level, a file's outline, a definition's code |
| `h` | `scope-ascend` | the parent level, point on where the reader came from |
| `j`, `k` | list motion | with the peek following |
| `d` | `scope-doc` | the row's summary, selected, in the right window |
| `c` | `scope-changes` | the diff for the row, or the level's node |
| `r` | `scope-recent` | `recent.md` (project level) |
| `g` | `scope-refresh` | queue the row's summary |
| `G` | `scope-bootstrap` | queue the row's subtree, or the whole store at the project level |
| `/`, `\` | list narrowing | narrow by text; widen |
| `q` | `quit-window` | leave the level |

A test binds its own keys under `<f9>` and names the command. No test names a production key.

### The peek

1. The right window is the peek. It shows the summary of the row at point, and it follows `j` and `k` after a short debounce, the way the switcher's peek does.
2. On a file level the peek is the file itself, and the row's definition carries the code-browse tint. The reader sees the code move as they walk the outline.
3. `d` selects the peek window and keeps it. `l` on a definition selects it and keeps it. Any other command that leaves the level lets the peek go.
4. A level opened in a frame with one window splits it. A level opened beside a window uses that window for the peek.

### Summaries

1. A summary is a morg file. Directives at the top say what it is about (`#+scope`, `#+path`), what it read (`#+source`, `#+inputs`), who wrote it (`#+model`, `#+written`). `morg-scan` reads them; nothing else parses them.
2. A file summary is two to four short paragraphs, no headings: what, why, who calls it, what to watch. Paths are inline as `path/to/file.ext`. Names are inline as `name`.
3. A directory summary is one paragraph and one card per entry; noise entries (`_build`, `deps`, `node_modules`) have no card.
4. The project summary is one paragraph, a "Worth knowing" list, and "Running".
5. `recent.md` is two paragraphs: what the last commits did, what is in flight.
6. A row's one-liner is the first sentence of its summary.
7. `#+pin: yes` keeps the queue off a summary. Its row shows `pinned` instead of `stale` when the code moves.

### Freshness

1. A summary's key is the git blob sha of its input. A directory's key is its children's summary shas and its entry list. The project's key is the root summary sha and `HEAD`. A change explanation's key is the sha of the file's diff text.
2. A summary is fresh when `#+source` equals the key. Else it is `stale`. No clock is read.
3. A stale summary still shows, with the badge. A missing summary shows `?`.
4. The queue holds one job in flight. A job that waited while its input changed again is dropped and re-queued with the newest key. Children settle before parents.
5. Auto-refresh has a budget of calls per hour per project (default 60). The footer shows it. A queue that meets the budget stops and says so; `g` still runs by hand.
6. A hand-edited summary keeps its key. The next refresh carries the edited text as the existing doc.

### Changes

1. `c` opens the existing diff-mode buffer for the node: `git-diff` scoped to the project, a directory, or a file.
2. `e` on a file card runs one `explain` call with the diff, the file, and the existing summary. It gets two sections: what changed, shown under the card; the updated summary, written to the store and marked fresh.
3. `recent.md` refreshes when `HEAD` moves or the working diff changes.

### Links

1. `M-.` in a summary, in `recent.md`, in a change explanation, and in any morg document, is `definition-peek`. Its providers, in order: a path (`code.scm`, `code.scm:423`, `lib/foo.ex#L42`), a Scheme name, an LSP `workspace/symbol` when a server is attached, the project outline index.
2. A path resolves against the document's directory and then the project root. It is a link only when the file exists.
3. A name with a module (`Compos.Core.Git.diff`, `Mod.fun/2`) resolves through the outline index and LSP. A bare name resolves in the same order and takes the first hit.
4. A name that resolves nowhere says "No definition of NAME" and opens nothing.

### Presets

1. A summary job names a preset, never a model: `summarize` for files and directories, `explain` for changes, `recent.md`, and the project page.
2. A project sets its own in `.project.scm`: `(project-preset! 'summarize 'model "gpt-5.4-mini")`, `(project-tier! 'strong "gpt-5.6-sol")`.
3. `@explain what does this hunk do` in a chat runs that turn with the `explain` preset's model, system, and tools.

### Agents

1. `scope-outline`, `scope-read`, and `scope-refresh!` are tools. A chat with the `coding` or `explain` preset holds them, so an agent reads the summaries before the files.
2. An agent that edits a file makes it stale like any other writer. Its summary refreshes on the same queue.

### Persistence

1. A level rebuilds from its locals after a restart: `'scope-node` names the node, and the mode setup redraws the rows. The peek is not restored; the next `j` or `k` brings it back.
2. The store is files. A restart loses nothing. The queue is not persisted; a stale summary is stale until viewed or changed again.

## Acceptance

1. `M-x scope` in a project opens `*scope: NAME*` with the project's entries and the header from `project.md`, or `?` rows and an empty header for a project without a store.
2. `l` on a directory row opens its level; `h` returns with point on that row.
3. `l` on a file row opens the outline; `l` on a definition row selects the code with `code-browse` on; `h` twice returns to the directory.
4. `j` and `k` move the peek to the row's summary; on a file level they move the tint in the file.
5. `d` opens the summary and `M-.` on a path in it peeks the file; `M-.` on `Compos.Core.Git.diff` peeks git.ex; `M-.` on a Scheme name peeks its definition; `M-.` again goes there; `M-,` returns.
6. Saving a file marks its row `stale` on the next draw; with auto-refresh on and budget left, the row shows `~` and then a fresh one-liner; the directory row refreshes after.
7. `g` on a row queues it; `G` at the project level bootstraps and the footer counts.
8. A hand edit to a summary survives the next refresh as the existing doc in the prompt.
9. `c` on a file row opens its diff; `e` on the card shows the explanation and marks the file's summary fresh.
10. `r` opens `recent.md`; it refreshes after a commit.
11. A `.project.scm` preset override changes the model the next job sends.
12. `scope-outline` and `scope-read` return the store to a chat that holds them.
13. Every level survives `M-x restart-daemon` with its rows and point.
14. Tests bind dummy `<f9>` keys to the commands; no test names a production key.
