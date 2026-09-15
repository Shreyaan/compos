# Editor performance review — September 15, 2026

## Changes

- List draws prepare each displayed row's cells and text once. Semantic fields and records reuse those values. Building the line list no longer repeatedly appends to a growing prefix.
- Selection reads the saved byte offsets instead of rendering the selected row again. Moving the cursor does no cell work.
- Filter matching resolves its callbacks once per draw rather than resolving the responsive layout for every candidate.
- Repeating the same query does no work. A scope-changing query can fetch and draw in one operation.
- C-x c draws once per filter key. Crossing between an empty query and a nonempty query changes the source scope; subsequent keys filter the cached source. Transcript search correctly starts when typing reaches three characters and expands again on backspace.
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
| C-x c filter draws per key | 2 | 1 |

## Verification

`list_performance_test.exs` and `switcher_performance_test.exs` check source/draw counts, cell counts, unchanged queries, chat search, hidden refreshes, and preservation of preview scroll. `folding_test.exs` checks cache invalidation and counts calls to the geometry scanner. The group-move integration test checks immediate visible headlines and deferred hidden headlines.

The focused list, chat, folding, group and window-point checks pass. The broader core/UI run is not green: it includes group and switcher contract failures and additional failures that appear only in combined runs. The old buffer-prompt and group-switch failures were reproduced with original source. A separate selected UI run passed 62 of 63 tests; its failure was the whole-HTML `"xy"` absence assertion in the undo test. The remaining broad-suite failures have not all been classified. No clean full-suite result or comprehensive browser-latency claim is made.

Concurrent changes to chat return behavior, group-new bindings/tests, and window documentation are separate from these performance changes and were preserved.
