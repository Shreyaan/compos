# Editor performance review — September 15, 2026

## Changes

- List draws prepare each displayed row's cells and text once. Semantic fields and records reuse those values. Building the line list no longer repeatedly appends to a growing prefix.
- Selection reads the saved byte offsets instead of rendering the selected row again. Moving the cursor does no cell work.
- Filter matching resolves its callbacks once per draw rather than resolving the responsive layout for every candidate.
- Repeating the same query does no work. A scope-changing query can fetch and draw in one operation.
- Ibuffer and chat-list table filtering coalesce over 300 ms, outside key handling. Crossing between an empty query and a nonempty query changes the source scope; subsequent queries filter the cached source. Transcript search is debounced by 400 ms and runs in a cancellable task; stale results check the current minibuffer input. Titles rank first during search.
- Ibuffer and chat filtering reuse candidates and prepared cells across growing queries. Backspace and refresh widen from the source; asynchronous transcript results invalidate the candidate cache.
- Repeating a preview of the buffer already displayed does not reset its scroll or send another window change.
- Closing the disposable C-x b table clears its filter without rendering the full list immediately before deleting it.
- Group membership writes use one batch. Intermediate moves defer dashboard rendering; hidden buffers refresh when shown. Membership hooks skip hidden switcher rendering.
- Group migration skips its quadratic membership walk when the buffer catalog is unchanged. Layout repair does not create a scratch buffer when a replacement member is available.
- Folded/narrowed geometry is cached in each window. Text replacement, point movement, fold changes and narrowing invalidate it; unrelated modeline updates and activity in another pane do not. The cache does not enter the render payload.

## Measurements

Disposable test VMs; medians on this machine, comparing original source with the changed functions under the same workload. These are server measurements, not end-to-end browser latency.

| Workload | Before | After |
| --- | ---: | ---: |
| Semantic table redraw: 400 entries, 60 displayed, three columns, nine samples | 26.993 ms | 19.976 ms |
| Row cell evaluations per draw for that table | 182 | 60 |
| Unchanged folded pane: 10,000 lines, 100 folds, seven samples | 4.002 ms | 0.166 ms |
| Three growing filters, 400 rows / 60 displayed, current renderer with reuse disabled vs enabled | 88.466 ms | 67.995 ms |

## Verification

`list_performance_test.exs` and `switcher_performance_test.exs` check source/draw counts, cell counts, unchanged queries, chat search, hidden refreshes, and preservation of preview scroll. `folding_test.exs` checks cache invalidation and counts calls to the geometry scanner. The group-move integration test checks immediate visible headlines and deferred hidden headlines.

The focused list, chat, folding, group and window-point checks pass. The broader core/UI run is not green: it includes group and switcher contract failures and additional failures that appear only in combined runs. The old buffer-prompt and group-switch failures were reproduced with original source. A separate selected UI run passed 62 of 63 tests; its failure was the whole-HTML `"xy"` absence assertion in the undo test. The remaining broad-suite failures have not all been classified. No clean full-suite result or comprehensive browser-latency claim is made.

Concurrent changes to chat return behavior, group-new bindings/tests, and window documentation are separate from these performance changes and were preserved.

## Filter lifecycle and folding follow-up

Closing a list filter entry keeps its query. Chat-list navigation flushes pending table filtering before moving, so a delayed draw cannot reset the chosen row. Transcript tasks may finish after the entry closes, but only while the retained query still matches. Backslash removes the filter.

Group folding now transforms the cached section source and reuses unchanged row cells, avoiding a source refresh, resort, and recomputation of heading statistics. Regression tests cover arrows with the entry open, C-g followed by row motion, explicit filter removal, and fold/unfold without source fetches.

## Live reload gap behind persistent typing latency

The live ibuffer registration still held the old options after the options variable was hot-reloaded: `filter-delay-ms` and `incremental-filter` were absent from the registered mode, while the new options variable contained `60` and `#t`. Incremental reload had skipped the unchanged `(define-list-mode! ... options)` form. Session now replays list registrations in source order when their package changes, preserving unchanged state definitions. A reload regression checks updated settings, retained package state, and a no-op second reload.

After correcting the live registration and reopening the filter, callback telemetry dropped from 300–450 ms per character to 0–1 ms for a sequence of four characters and four deletions. These are callback durations in the user's running daemon, not browser paint measurements. The live prompt was restored to its original empty input after the check.

The 60 ms delay still fired during normal typing pauses. Live telemetry showed individual deferred redraws taking 300–420 ms and blocking subsequent input on the UI lane. The default idle delay is now 300 ms, shared by ibuffer and chat-list; transcript search waits another 100 ms. A paced live check at 100 ms between characters showed each input update immediately, no query change during the burst, and the final query applied after idle. This reduces redraw frequency; it does not make a redraw already running interruptible.

Debounce cancellation now also covers callbacks whose timers fired while the UI lane was busy. Previously Session removed the cancellation token before queuing the callback, so cancelling or replacing that key could not stop the queued work. The callback now validates and atomically claims its generation when execution begins. Tests hold the UI lane, queue a fired timer, cancel or replace it, and assert the stale callback never runs. An input-queue regression verifies four rapid deletions produce exactly one final list render. A live instrumented burst also produced one render; the user's report of several redraws was not reproduced in that check.

## Repaint stability

List rendering and filter selection changes now run inside `with-buffer-display-update`; peek-copy preparation uses the same boundary. LiveView retains the previous decorated window during the update, including its styling, selection and scroll position. Completion publishes the finished presentation. Other windows and the minibuffer continue updating. Editor geometry reads during the update do not commit intermediate recentering. The boundary nests and releases on Scheme errors; Registry ownership removes stale guards when an owner process exits.

A LiveView test pauses a write halfway through and checks that the displayed window remains identical, then shows the final content after release. A separate test covers nested boundaries and error cleanup. This verifies server-rendered presentation stability; no browser animation or paint measurement is claimed.
