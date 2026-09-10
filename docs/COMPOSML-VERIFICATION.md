# ComposML verification — 2026-09-10

Worktree: `/private/tmp/compos-composml`, branch `codex/composml`.

## Browser and RPC

The browser was inspected after RPC actions, using the specific attached frame.

- Port 4024: navigating mail changed the previewed thread. A read-tag write
  failure exposed focus leaking into the preview; the production code now
  restores list focus before attempting that write. Rechecked via RPC.
- Port 4024: marking displayed `1 thread selected` and the visible mark glyph.
- Port 4024: ibuffer, ichat and Dired rebuilt semantic records after restart.
  Dired retained its compact table. RPC `n`, `m` marked alpha.txt and moved to
  beta.txt in a temporary two-file directory.
- Port 4034: separate daemon and temporary Notmuch database under
  `/private/tmp/composml-mail-rpc-check`; no user mail used for write tests.
  Three fixture messages rendered in the browser with a matching preview.
  Mark + archive + confirmation reduced inbox count from 3 to 2.
  Limiting the search to one visible thread and invoking `notmuch-mark-all`
  displayed `All 2 matching messages selected`. Archive + confirmation reduced
  inbox count to 0. Total database message count remained 3.

## Automated checks

- Focused core: 26 tests passed (mail scenes, read-write failure focus, agenda).
- Focused UI: 16 tests passed (compiler/format, semantic lists, compact lists).
- Additional ibuffer and imenu checks passed.
- Tree-sitter: all 63 corpus cases passed.
- Final UI suite: 275 tests, four previously established baseline failures:
  preview caret CSS, clipboard delivery, agent text-scale CSS, and modeline-info.
- Full umbrella run: core 1543 tests, 438 failures, 2 skipped; the core suite is
  not green. It includes extensive existing environment/shared-state failures;
  this run does not establish that every core failure is unrelated. A focused
  run initially overlapped its shared test home; subsequent focused checks used
  a separate test partition. The final UI rerun was separate and clean apart
  from the four known baseline failures.
- `git diff --check` passed.

## Limits

The main port-4024 preview runs sandboxed. Automatic approval review rejected
an unrestricted launch because it would access private mail and other local
resources. Its Notmuch database writes are therefore blocked; the isolated
fixture preview verified the write path safely.

## Domain-field migration follow-up

Dired, ibuffer and ichat now emit typed column fields using byte ranges from
the existing column layout. Dired retains raw file metadata even when compact
layouts omit a field. Agenda emits typed title, planning, state and source
segments. Imenu emits symbol records and name/kind/location fields. Chat emits
c-user, c-agent, c-toolcall, c-info, c-summary, c-permission and c-plan, alongside
the existing input, argument and result elements. Preview carries source and
format metadata. See COMPOSML-COMPONENTS.md for the component inventory.

The follow-up UI run completed 276 tests with the same four baseline failures
listed above; new semantic renderer tests passed. Focused agenda, ibuffer and
imenu checks passed, as did all 63 Tree-sitter corpus cases. The restarted
port-4024 browser displayed compact Dired columns and the chat pane successfully.
Specialized internals still using generic text are not claimed as fully modeled.

## Parser simplification

The duplicate ComposML parser and its corpus were removed. Earlier 63-case
results above describe the superseded parser. Current checks exercise the
built-in HTML parser, semantic queries, ComposML mode, and Phoenix compiler.
