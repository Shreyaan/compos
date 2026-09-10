# ComposML migration queue

## Presentation contract

Translate one component at a time. Preserve existing layout, density, fonts,
faces, line numbers, alignment, wrapping, selection, scrolling, and key behavior.
Dired and other compact buffers must remain minimalist text/table views. Do not
apply the Notmuch grid/card appearance to them. Notmuch's new appearance was
explicitly accepted; that is not authorization to redesign other buffers.

Cursor/current item, previewed item, and bulk marks are distinct states. Clicking
Notmuch focuses and previews the clicked thread, like Up/Down; m changes bulk
marks. Keep this distinction in every subsequent migration.

## Current foundation

- First-party LiveViews, LiveComponents and layouts author ~M templates and use
  the named ComposML renderer interface. This does not mean all their children
  already carry useful domain semantics: generic c-group/c-text remain.
- Shared optional list collection/composml/on-click callbacks exist. Notmuch is
  the first consumer. Compact lists now use a separate text projection with
  domain record wrappers: Dired, ibuffer and ichat retain their text geometry.
  All other shared text lists default to c-list/c-item with mode and record
  identity. Individual column semantics and specialized domain names remain pending.
- Existing HTML parsing, semantic queries, ComposML mode, CSS defaults, and face selectors are used. No separate parser is shipped.
- Agent transcript outer messages/tool calls/status already have semantic names.

## Ordered passes

1. Shared primitives: ui/badge, ui/empty, ui/row, ui/fold-head, ui/card, ui/kv.
   ui/section and ui/actions already have semantic outer elements; review their
   children and accessibility. Preserve their class styles and display geometry.
2. Compact list rendering: add semantic item/field boundaries while preserving
   existing text layout, face spans, row offsets, line numbers, and marks.
   Prove this with Dired before migrating other compact modes. Do not opt all
   lists into the Notmuch block/grid renderer.
3. Dired: directory/entry identity, name, kind, permissions, size, modification
   time, flags; retain provider behavior, remote directories and every operation.
4. Buffer/navigation lists: ibuffer, switch, groups, workspaces, worktrees,
   bookmarks, browsing history, buffer log, messages, annotations, occur.
5. Service/status lists: daemons, sockets, MCP, telemetry, performance, Sentry,
   Doppler, Google/Drive, feeds, LSP diagnostics/references, IRC servers/channels,
   movie streams, agent fleet. Reuse the compact renderer unless the mode already
   has a different intentional presentation.
6. Existing structured views: diffs/hunks, agenda/TODOs, annotation cards,
   telemetry/performance charts, Sentry details, Doppler details, WhatsApp views.
   Preserve existing folds, actions, graph geometry, and navigation anchors.
7. Editor chrome detail pass: headerlines/modelines, dashboard fields, tabs,
   completions, which-key, prompts, echo, search controls and mobile equivalents.
8. Chat/agent detail pass: transcript, authors, queued messages, thoughts, tool
   calls/arguments/results, plans, permissions, questions/answers, summaries,
   streaming text, input cursor and completion. Preserve incremental rendering,
   scroll anchors, verbosity, folds, native details controls, focus and approvals.
9. Embedded document boundaries: Markdown/HTML previews, PDFs, spreadsheets,
   terminal and game/app buffers. Wrap the host surface semantically; do not
   rewrite third-party documents or canvas/terminal internals into fake records.

## Chat assessment

Chat is a larger pass, but not a renderer rewrite. The tracked Phoenix pipeline
and semantic message/tool-call wrappers are already in place. The difficult work
is preserving streaming, scrolling, cursor/input behavior, permissions and fold
state while enriching the remaining structures. Migrate one message type at a
time, using interaction tests; do not flatten the transcript to static XML or
introduce a new chat UI as part of this work.

## Source inventory: explicit list modes

This inventory is from the current worktree source. Runtime-generated modes and
external/user packages need separate discovery when their pass begins.

| Mode | Source |
| --- | --- |
| `Dired` | `apps/compos_core/priv/dired.scm` |
| `morg-todos-mode` | `apps/compos_core/priv/packages/agenda.scm` |
| `ichat-mode` | `apps/compos_core/priv/packages/agent-fleet.scm` |
| `annotations-mode` | `apps/compos_core/priv/packages/annotate.scm` |
| `bookmark-bmenu-mode` | `apps/compos_core/priv/packages/bookmark.scm` |
| `daemons-mode` | `apps/compos_core/priv/packages/daemons.scm` |
| `workspaces-mode` | `apps/compos_core/priv/packages/daemons.scm` |
| `doppler-mode` | `apps/compos_core/priv/packages/doppler.scm` |
| `feeds-mode` | `apps/compos_core/priv/packages/feeds.scm` |
| `google-mode` | `apps/compos_core/priv/packages/google.scm` |
| `google-service-mode` | `apps/compos_core/priv/packages/google.scm` |
| `google-drive-mode` | `apps/compos_core/priv/packages/google.scm` |
| `groups-mode` | `apps/compos_core/priv/packages/groups.scm` |
| `ibuffer-mode` | `apps/compos_core/priv/packages/ibuffer.scm` |
| `irc-channels-mode` | `apps/compos_core/priv/packages/irc.scm` |
| `irc-servers-mode` | `apps/compos_core/priv/packages/irc.scm` |
| `lsp-diagnostics-mode` | `apps/compos_core/priv/packages/lsp.scm` |
| `lsp-references-mode` | `apps/compos_core/priv/packages/lsp.scm` |
| `mcp-hub-mode` | `apps/compos_core/priv/packages/mcp-hub.scm` |
| `messages-mode` | `apps/compos_core/priv/packages/messages.scm` |
| `movie-stream-mode` | `apps/compos_core/priv/packages/movie.scm` |
| `notmuch-mode` | `apps/compos_core/priv/packages/notmuch.scm` |
| `notmuch-hello-mode` | `apps/compos_core/priv/packages/notmuch.scm` |
| `occur-ts-mode` | `apps/compos_core/priv/packages/occur.scm` |
| `buffer-log-mode` | `apps/compos_core/priv/packages/provenance.scm` |
| `sentry-mode` | `apps/compos_core/priv/packages/sentry.scm` |
| `sockets-mode` | `apps/compos_core/priv/packages/sockets.scm` |
| `switch-mode` | `apps/compos_core/priv/packages/switch.scm` |
| `telemetry-mode` | `apps/compos_core/priv/packages/telemetry.scm` |
| `browse-history-mode` | `apps/compos_core/priv/packages/web.scm` |
| `whatsapp-mode` | `apps/compos_core/priv/packages/whatsapp.scm` |
| `worktrees-mode` | `apps/compos_core/priv/packages/worktrees.scm` |

## Gate for each item

Use the live catalog before choosing components. Establish its present geometry
and interaction contract, then implement semantic structure in the owning Scheme
component/mode. Check the resulting render state, keyboard and click behavior,
refresh and mode re-entry. Keep identity independent of position. Run focused and
relevant broad tests; distinguish existing failures. Record completed items here.

No additional component migration is marked complete by this inventory.

## Latest verified pass

- Mailbox root comes from Scheme; shared LiveView no longer dictates c-group.
- Chat bodies/questions/answers and iframe preview boundaries are semantic.
- Morg agenda has agenda/day/entry identity with the existing card layout.
- Shared rows/cards accept domain tags; badges, empty notices, fold headings,
  and property collections have semantic defaults.
- Dired, ibuffer and ichat retain text lines inside domain record wrappers.
  Browser byte-to-DOM lookup and wrap measurement understand those wrappers.
- Imenu shares the semantic completion collection and candidate renderer.
- Preview read-tag errors no longer steal focus from the mail index.
- RPC/browser checks confirmed mail preview changes, local selection count and
  visible mark glyph. Sandbox prevents database writes on the current preview.
