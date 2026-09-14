# Windows and buffer history

This is the intended behavior and acceptance specification, not a claim that
the current implementation satisfies it. The central requirement is:

**Each window unfolds through its own history. If anything covers a buffer in
the left window, closing that cover reveals the buffer that was in the left
window.** The same applies to every window, regardless of who opened the cover,
which window had focus, or which display action chose the destination.

## Terms and scope

- A **buffer** is a document or application surface. Its lifetime is independent
  of the windows displaying it. Creating or loading it need not display it.
- A **window** is a pane displaying a buffer and holding its own view state.
  A frame contains windows; a popup is a separately managed display surface.
- A **cover** is a successful replacement of a window's displayed buffer.
- **Unwind/dismiss** removes the current display layer and restores its predecessor.
  This is local to a window and need not destroy the buffer.
- **Kill buffer** destroys a buffer globally. Every affected window must repair
  itself independently. It is different from dismissing one display.
- **Delete window** removes a pane, not its buffer.
- **Global buffer recency** helps a switcher find buffers. It does not determine
  what was underneath a cover in a particular window.

In examples, `L: A → B → C` means the left window showed A, then B, and now C.
Its next two unwinds reveal B and A. `R: X` means the right window shows X.
Letters denote distinct buffer identities unless repeated explicitly.

## Required invariants

1. Record the destination window's previous buffer and view before replacing it.
   Do this for keyboard commands, links, mouse actions, modes, tools, agents,
   passive displays, explicit window setters, and layout-driven replacements.
2. Keep every outstanding return layer. A single previous-buffer field cannot
   represent nested covers. Ordinary buffer MRU deduplication cannot represent
   repeated visits such as `A → B → A` either.
3. Restoring a layer consumes it. Restoration must not create a new visit that
   pushes the dismissed cover back on top or makes repeated closes oscillate.
4. A window's history belongs to that window's logical lineage. Focus changes,
   global recency changes, and activity in another window must not rewrite it.
5. An exact, available predecessor wins over fallback preferences. In particular,
   restore it even if another window already displays it. Duplicate views are valid.
6. Restore the saved window view: point, scroll position, horizontal offset where
   supported, and follow/manual-scroll state. Use valid adjusted positions if the
   buffer changed while covered. Do not rewind document edits.
7. Redraws, reloads of the same displayed identity, focus-only changes, headless
   buffer work, failed displays, and canceled operations add no return layers.
8. Restore only the closing window's own history. If no predecessor remains,
   close that window and let the layout shrink. Do not borrow from group recency.
   The last window remains visible if it has no predecessor.
9. No live window may remain attached to a killed buffer. No stale return record
   may affect a different window that later reuses an identifier.

## Opening and destination selection

Destination selection and focus are separate from recording history. Resolve
the destination first, then record what is covered in that destination.

| Case | Action | Required result |
| --- | --- | --- |
| O1: Same window | `L: A`; open B in L | `L: A → B`; close B reveals A in L. |
| O2: Nested opens | `L: A`; open B, then C in L | Close C reveals B; close B reveals A. |
| O3: Other window, passive | Focus L; `L: A`, `R: X`; display B in R | `L: A`, `R: X → B`; focus stays L. Dismiss B restores X in R. |
| O4: Other window, selected | Same setup; open B in R and select it | Same histories as O3; focus moves to R. |
| O5: Open back into the source pane | `L: A → B`, `R: X`; an action in R opens C in L | `L: A → B → C`; closing C reveals B, then A. R keeps X. |
| O6: Independent nesting | `L: A → B`, `R: X → Y → Z` | Closing in either pane advances only that pane's return chain. |
| O7: Explicit destination | A caller supplies L's window ID while R is selected | Record L's predecessor, never R's selected buffer. |
| O8: Reuse a visible buffer | B already appears in R; display policy reuses R | No replacement, no new return layer, no history change in L. Select R only if requested. |
| O9: Force a second view | B appears in R; explicitly open B in L over A | `L: A → B`, `R: B`; dismiss B in L reveals A and leaves R alone. |
| O10: Already current | `L: A → B`; display B in L again | Preserve the existing return chain exactly. One close reveals A. |
| O11: Revisit an older buffer | `L: A → B`; deliberately open A in L | `L: A → B → A`; local dismiss reveals B, then the earlier A. |
| O12: No other pane | Open B with an other-window constraint | Create an eligible other pane if possible. If impossible, fail without covering the source or changing its history. |
| O13: Three or more panes | Display policy selects one of several other panes | Only the selected destination gains a cover; all other histories and views survive. |
| O14: Quiet work | Create/load/edit B without displaying it | No window or return-history change, even if global buffer recency changes. |
| O15: Failed or canceled open | Loading fails, destination disappears, or user cancels | No phantom entry or half-applied replacement; preserve the previous display. |

Display rules may choose same-window, reuse-window, another existing window,
a new split, or a popup. They cannot bypass the return contract. Passive display
preserves focus; an explicit visit may select the resulting window.

## Closing, killing, and fallback

The examples below distinguish local dismissal from global destruction even
when a user-facing command currently combines them. A combined quit-and-kill
must preserve both contracts: unwind the target display and independently repair
any other displays of the killed buffer.

| Case | Action | Required result |
| --- | --- | --- |
| C1: Local dismiss | `L: A → B`, `R: X`; dismiss B in L | L shows A with its saved view; R is unchanged; B may remain alive. |
| C2: Close background display | Same setup, with R selected; dismiss B by window ID | L restores A; R retains focus. |
| C3: Kill current buffer | `L: A → B`; kill B | Keep L, restore A, remove references to the killed B. |
| C4: Kill shared buffer | `L: A → B`, `R: X → B`; kill B | L restores A and R restores X, preserving both work panes. |
| C5: Kill a hidden predecessor | `L: A → B → C`; kill hidden B | C remains visible; closing C reveals A. Killing B must not pop C. |
| C6: Kill unrelated buffer | Kill a buffer absent from all current displays and return chains | No window, focus, geometry, or return-history change. |
| C7: Predecessor visible elsewhere | `L: A → B`, `R: A`; close B | L restores A as well. Do not choose an unrelated buffer just to avoid duplication. |
| C8: Multiple dead predecessors | `L: A → B → C → D`; B and C have been killed | Closing D skips both and reveals A. |
| C9: No usable predecessor | Close the current buffer with an exhausted return chain | Remove the exhausted window and shrink the layout. Do not borrow another buffer. If this is the last window, keep its current buffer and report that no predecessor exists. |
| C10: Last window | Close/kill its current buffer | Leave one valid work window; restore its predecessor or fallback. |
| C11: Refused kill | Modified-buffer handling refuses or cancels the close | Preserve buffer, view, history, quit ownership, layout, and focus. |
| C12: Buffer renamed | A is renamed while underneath B | Closing B restores the same buffer under its new name and saved view. |
| C13: Name reused after kill | Kill hidden A; create a different buffer named A | An old layer must not silently attach to the new buffer merely because its name matches. |
| C14: Repeated visit plus kill | `L: A → B → A`; kill A globally | Restore B and invalidate both occurrences of A; later closes cannot resurrect it. |
| C15: Repeated cleanup | A dismiss/kill callback arrives twice | Consume the intended layer once; the duplicate must not close the revealed predecessor. |

Fallback is used only after the window's valid return chain is exhausted. Prefer
eligible buffers in the window's current group/context, then its normal safe
empty-buffer fallback. Avoiding duplicates is a fallback preference only.
An unloaded but restorable buffer is different from an explicitly killed one:
restore its runtime before revealing it; never resurrect an explicitly killed
buffer merely to satisfy a historical reference.

## Splits, temporary windows, and layout changes

| Case | Action | Required result |
| --- | --- | --- |
| W1: User-created split | Split L while it shows A | Original history is unchanged. The new pane starts with A and an independent copy of the view/history; later changes do not mutate its sibling. |
| W2: Cover in a manual split | New manual pane shows A, then B | Closing B restores A and keeps the user's split. |
| W3: Display-created temporary split | Opening B creates a temporary pane beside L | Dismissing B removes that temporary pane and reveals the previous arrangement; L's history is unchanged. |
| W4: Nested cover in temporary split | Temporary pane was created for B; then C covers B | Close C to reveal B in the same pane. Only dismissal of the original temporary display removes the pane. |
| W5: Kill versus dismiss | Kill B in a display-created work split | Killing alone preserves the work pane and repairs its buffer. Explicit temporary-display dismissal may remove it. |
| W6: Delete a window | Explicitly delete R | Keep its buffers alive; do not append R's history to L. Remove records owned by the deleted window. |
| W7: Delete other windows | Keep L and remove its siblings | L retains its complete history and view; a later close uses L's predecessor. |
| W8: Resize or rotate geometry | Resize panes or rearrange their positions | Each logical pane carries its current buffer, view, history, and nested return ownership with it. |
| W9: Retile existing panes | Retile panes showing B and Y after `A → B` and `X → Y` | B's pane still unwinds to A; Y's pane still unwinds to X. Do not copy one survivor's history into all panes. |
| W10: Retile with a replacement | Replace the pane on Y with Z during a tile | The replacement pane records Y over its previous X; close Z reveals Y, then X. |
| W11: Duplicate buffers during retile | Two panes show B with different histories/views | Match by logical pane identity/lineage, not buffer name alone; retain both distinct return chains. |
| W12: Layout undo/redo | Restore a saved arrangement | Restore histories, views, and return ownership with the layout. Do not record intermediate reconstruction steps as visits. |
| W13: Fixed layout capacity | Open while a two-pane target is full | The chosen replacement pane records its displaced buffer; closing does not refill from arbitrary group recency. |
| W14: Layout reduces pane count | Explicitly hide/remove surplus panes | Preserve their state in the restorable layout snapshot, without grafting it onto surviving panes. |

Temporary-window ownership belongs to the layer that created the window, not
just to its most recent buffer. A return record must not delete a repurposed pane
after its owning display has already ended. Explicitly keeping/adopting a
temporary pane makes it a work pane; subsequent closes preserve it.

## Previews, popups, and application buffers

| Case | Action | Required result |
| --- | --- | --- |
| P1: Preview borrows R | `L: listing`, `R: X`; preview P in R | Dismissing the preview restores X with its original view. L stays on the listing. |
| P2: Replace a preview | In P1, preview P1, P2, then P3 | This is one replaceable preview layer over X. Dismiss reveals X, not P2 or P1. |
| P3: Preview creates a pane | No other pane; preview creates one | Replacement previews retain that pane's creation ownership; final dismiss removes it. |
| P4: Preview existing buffer | Preview a buffer that existed before the preview | Dismiss removes its display only; do not kill the pre-existing buffer. |
| P5: Keep preview | Keep P in a borrowed pane over X | P becomes an ordinary visit with X underneath; close P restores X. In a newly created pane, keep also adopts the pane. |
| P6: Open preview in source | Move/adopt preview P into the listing's pane | First restore the borrowed pane's X (or remove the preview-created pane); source becomes `listing → P`. |
| P7: Popup opens | Open a popup over a work layout | Work-pane histories and views are unchanged; dismissal restores the covered arrangement and appropriate focus. |
| P8: Nested popup content | Popup shows P, then an ordinary cover Q | Close Q reveals P; close P dismisses the popup. A replace-preview action remains the explicit P2 exception. |
| P9: Listing opens a detail | A listing or app buffer opens a message, file, help page, or result in either pane | Use the actual destination's predecessor. Closing detail restores that predecessor, regardless of the detail's semantic parent. |
| P10: Close listing with active preview | The listing's quit command dismisses its preview first | First quit restores the preview destination; a subsequent quit unwinds the listing's own pane. |
| P11: Async completion | A delayed preview/open/cleanup finishes after another visit | Commit only against the intended live destination/layer. Stale cleanup cannot restore over or delete newer user work. |

## Focus, navigation, groups, and persistence

- Selecting another window, clicking a modeline, or cycling focus changes no
  return history. Closing a layer in an existing selected pane keeps that pane
  selected. Removing a selected temporary pane returns focus to its surviving
  origin, or a deterministic surviving work pane if the origin no longer exists.
- Previous/next-buffer navigation must have a stated navigation scope and must
  not corrupt outstanding display returns. Traversing history is not a fresh
  cover. A new ordinary open after navigating establishes a new branch; discarded
  forward navigation must not later reappear as a close target.
- An explicit buffer swap/move carries the associated view and return lineage
  with the moved display. A command that merely opens two replacement buffers
  instead creates two covers. These operations must not be conflated.
- Group switching saves and restores the group's window configuration, including
  histories. A temporary foreign buffer or board covering a group pane must not
  erase its predecessor. Group filtering of fallback candidates must not reject
  an exact predecessor just because the cover changed the apparent context.
- Different frames own independent window histories, even when they display the
  same buffers. Local dismissal affects one window; a global buffer kill repairs
  every affected frame from each window's own chain.
- Session/desktop restore must round-trip window lineage, saved views, history,
  and outstanding temporary-display ownership. Restoring a session adds no
  synthetic visits. Invalid buffer references are skipped without losing older
  valid predecessors. Older snapshots without history start with empty history.

## Current implementation seams and conflicts

The following are inspection findings, not runtime verification of the reported
bug. They identify where implementation and regression tests need attention:

- `apps/compos_core/priv/editor.scm`: `window-display!` records the destination's
  previous buffer, but `window-quit-restore-note!` replaces the one record for that
  window. `window-quit-restore!` consumes that record. This representation does
  not retain a nested sequence or its original temporary-window ownership.
- `apps/compos_core/lib/compos/core/editor.ex`: `visit_buffer` keeps deduplicated
  per-window buffer names. `release_buffer_from_tree` skips history entries shown
  elsewhere and resets view fields during refill. These policies need review
  against exact restoration, repeated visits, and saved-view requirements.
- `apps/compos_core/priv/tests/window-history-test.scm` explicitly asserts that
  refill never duplicates another window's buffer. **That assertion conflicts
  with C7 and must change:** the original buffer must reappear in its own pane.
- `apps/compos_core/priv/tests/display-buffer-test.scm` covers single-step borrowed
  window restoration, creation, reuse, and previews. Extend coverage to nested
  returns, temporary-window ownership, duplicate displays, and stale cleanup.
- `apps/compos_core/test/compos/window_heal_test.exs` covers killed-buffer repair
  and keeping work panes. Preserve those guarantees while strengthening the
  predecessor choice and view-restoration assertions.

For each case above, regression tests should assert the displayed buffer in
every pane, remaining return order, buffer liveness, selected window, pane count
and geometry, and restored view where relevant. Exercise both selected-window
and explicit destination APIs, and user-facing open/quit paths. After each
nested scenario, unwind all layers to prove the original workspace survives.

This document changes the contract only. It does not fix the implementation or
claim these acceptance cases currently pass.

## Current behavior audit — 2026-09-09

The current editor has several partially overlapping return mechanisms, rather
than one window-local unfolding contract. Single-step cases often work. Nested
local restoration, temporary-window ownership, and exact predecessor selection
are inconsistent between close paths.

Evidence labels below:

- **Tested:** the existing test assertions passed in this audit. This establishes
  those assertions, not every requirement in the corresponding spec case.
- **Probed:** a short isolated runtime sequence directly demonstrated the result.
- **Source:** inferred from the implementation; the complete scenario was not run.
- **Unverified:** no sufficient assertion or probe was found in this audit.

### Existing coverage versus the contract

| Spec cases | Current behavior and evidence |
| --- | --- |
| O1, C1 | **Tested, partial:** selected-result `quit-window` restores the displaced buffer. It then kills the result globally; it is not local-only dismissal. `layout-policy-test.scm`: `selected-result-quit-restores-the-buffer-under-it`. |
| O2 | **Probed, mixed:** ordinary `A → B → C`, followed by two `quit-window` commands, returns to A. Two calls to `window-quit-restore!` return `#t`, then `#f`, and leave B visible. Kill repair makes the first path work despite the missing nested quit records. |
| O3, O4, O13 | **Tested:** passive display preserves selection, pop-to-buffer selects its destination, and a full three-pane target borrows the oldest other pane and restores it on quit. `display-buffer-test.scm` and `layout-policy-test.scm`. Closing a background pane without selecting it has less coverage. |
| O5, O6, O7 | **Source/partial:** explicit window setters record destination-local history; there is no full cross-pane, multi-level unwind assertion in the inspected suites. The history test establishes distinct pane histories through tiling. |
| O8, O10 | **Tested/source:** reuse returns the existing destination without creating another pane. `window-display!` does not replace its quit record if the buffer did not change. Complete history equality is not asserted by the reuse test. |
| O9, C4 | **Tested, partial:** duplicate displays are supported, and killing a buffer shown everywhere leaves both work panes alive. Distinct predecessors for each affected pane are not asserted by that kill test. |
| O11 | **Probed conflict:** `A → B → A`, then two local restores, yields B, then B again. The local return chain is lost; buffer history also deduplicates repeated buffer names. |
| O12 | **Tested, partial:** a sole pane splits for display; other-window display avoids the selected pane; same-window inhibition can make a display fail. The exact unsplittable other-window failure sequence is unverified. |
| O14 | **Tested:** buffer-context switches leave windows unchanged, including under a target layout. `frame-windows-test.scm` and `background-buffer-context-does-not-grow-a-target-layout`. |
| O15 | **Unverified:** destination loss, loading failures, and rollback of partially applied opens are not established by the display tests. Layout-picker cancellation is covered separately. |
| C2 | **Source/partial:** `window-quit-restore!` accepts an explicit window ID, but background-close focus preservation is not directly asserted in the inspected tests. |
| C3, C6, C9, C10 | **Tested, partial:** killing a displayed buffer heals the tree, keeps ordinary work panes, and killing an unrelated hidden buffer preserves the layout. The test named “no history” does not clear the inherited history or assert a particular fallback, so it does not prove deterministic empty-history fallback. |
| C5, C8 | **Source/partial:** kill repair filters killed names while repairing affected leaves, and history reads filter unknown buffers. This does not establish complete stale-reference removal; the quit record is separate. |
| C7 | **Tested/probed conflict:** kill repair skips A when another pane shows A and an older X is available. The existing history test explicitly requires this. In the same ungrouped arrangement, `quit-window` restores A first and therefore leaves A in both panes. The close command changes the answer. |
| C11 | **Source/partial:** ordinary `quit-window` checks for an unsaved file before restoring/killing it. Its earlier preview-dismiss branch can still dismiss a preview. Full state preservation on refused quit is unverified. Desktop-clear cancel/refusal tests are different operations. |
| C12 | **Tested/source:** lifecycle tests establish rename preserving stable buffer identity, the visible window, and global MRU. Core rename rewrites leaf histories. Hidden predecessors stored in Scheme quit records are not covered by that test. |
| C13 | **Probed conflict:** cover A with B, kill hidden A, create a new A, then quit B: the stale quit record restores the new A by name. |
| C14, C15 | **Unverified:** global kill during repeated visits and duplicate asynchronous cleanup need dedicated assertions. The single-use quit record alone does not prove idempotence of complete quit/kill commands. |
| W1, W2, W5 | **Tested/source:** splits copy leaf history and buffer kill preserves manual work splits. These are independent leaf values. This does not prove copying/restoring every saved view field or temporary ownership. |
| W3 | **Tested:** quitting a result in a display-created pane removes that pane. `quit-window-deletes-the-window-the-display-made`. |
| W4 | **Probed conflict:** create a temporary pane for B over a one-pane A layout; open C over B; quit twice. Two panes showing A remain, instead of returning to the original one-pane layout. C overwrites the record that said B created the pane. |
| W6, W7, W14 | **Tested/source, partial:** pane deletion reduces target occupancy without reopening hidden work; smaller layouts preserve the focused slot. Complete history cleanup, surviving history equality, and restoration of removed pane histories are not all asserted. |
| W8, W9, W10 | **Tested, partial:** retile preserves each distinct buffer pane's prior buffer history; a replacement pane inherits the displaced pane's current buffer and history. Layout tests preserve pane order, focus, geometry, and duplicate-view point positions. Full scroll/return-layer preservation is not established. |
| W11 | **Tested/source, partial:** duplicate panes retain distinct points in the tested traversal order. History transfer still matches by buffer name and consumes records in order, not by stable pane lineage. Reordering indistinguishable buffer views with distinct histories is unverified. |
| W12 | **Source/partial:** tree snapshots carry leaf history and view fields, and the inspected editor tests cover layout undo/cancel. Those editor tests were not run in this audit; no full nested-quit ownership round trip was established. |
| W13 | **Tested:** fixed targets grow before replacing and restore a single selected/passive result to the displaced buffer. Repeated nested results remain subject to O2/W4. |
| P1, P2, P3 | **Tested, partial:** previews reuse one slot, preserve source focus, drop preview-created buffers when replaced, and remove a preview-created pane on dismissal. The main preview fixtures begin with one work pane; borrowed-pane restoration with a saved view is not fully covered. |
| P4 | **Tested:** dismissing a preview of a pre-existing buffer hides it without killing it. `q-takes-a-shown-buffer-that-existed-before-the-peek`. |
| P5 | **Tested, partial:** keep makes a peek writable and removes its peek status. Adopting temporary-pane ownership and subsequently closing it without removing the pane are unverified. |
| P6 | **Tested, partial:** opening a peek into the source pane removes the preview-created pane. Returning a borrowed destination to its original view needs a separate assertion. |
| P7, P8 | **Tested, partial:** popups have a separate stack, and dismissing the top popup reveals the previous popup. This is stronger than the ordinary window's single quit record, but the popup stack also deduplicates names. Full view restoration is not asserted. |
| P9 | **Tested, partial:** result, Dired, and browse paths have integration coverage. This does not establish the contract for every app mode or agent display path. |
| P10 | **Tested:** Dired quit dismisses the shown preview first; the source listing and its current row remain. The test named “closing-a-peek-restores-nothing” refers to preserving the listing's newer position, not permission to lose the borrowed pane's predecessor. |
| P11 | **Tested, narrow:** a delayed peek only fires where it was scheduled. This does not prove general stale-open or stale-cleanup protection for all displays. |

### View state, navigation, groups, and persistence

- **Probed:** covering a manually scrolled buffer and quitting back changes its
  saved `manual` flag from `true` to `false`. In the probe, `ctop` remained 480;
  the complete view tuple was nevertheless not restored. The raw returned leaf
  history also retained the killed cover's name, although history reads filter
  unknown names. Returning to the right buffer is not enough to prove the same view.
- **Tested:** desktop restore preserves a pinned scroll and saved client offset.
  A separate passing test explicitly expects the buffer's newer point to remain
  after restore, rather than restoring its old point. These desktop assertions
  must not be mistaken for cover/uncover view assertions.
- **Source:** previous/next-buffer walks a frozen global/group-filtered MRU ring
  and invokes ordinary `switch-to-buffer!`. It is not a window-local back/forward
  stack and can update the same return bookkeeping used by ordinary opens.
- **Tested conflict with the draft's move rule:** directional buffer move reveals
  the source's prior buffer and pushes the moved buffer over the destination's
  prior buffer; it carries point, not the source's entire return lineage. The
  keyboard test explicitly requires the destination history to start with the
  displaced destination buffer. Directional window swap likewise performs two
  buffer switches in source. The intended move/swap wording needs a deliberate
  policy decision before implementing it.
- **Source:** group kill repair filters predecessors by group, transient/preview
  status, and visibility elsewhere. In exhausted/dying groups it may remove a
  pane. Thus the core test “kill keeps windows” is not an unconditional guarantee
  for the higher-level Scheme kill path.
- **Tested/partial:** target layout settings and duplicate-view focus survive
  tested relayout/group restoration. Full per-frame nested return isolation and
  fresh-process restoration of quit ownership remain unverified. The Scheme
  quit records are separate from the leaf histories serialized in the tree.

### Runs and limitations

All runs used isolated test homes/sockets through `MIX_TEST_PARTITION`; no live
editor state or runtime implementation was changed.

1. `MIX_TEST_PARTITION=windows_audit mix test` with these files under
   `apps/compos_core/test/compos/`, and `--seed 0`:
   `window_history_scheme_test.exs`, `display_buffer_test.exs`,
   `window_heal_test.exs`, `frame_windows_test.exs`, `layout_policy_test.exs`,
   `peek_test.exs`, `desktop_restore_test.exs`, `window_config_hook_test.exs`,
   `window_fill_test.exs`: **68 ExUnit tests, 4 failures**. Some ExUnit tests
   execute multiple Scheme cases; 68 is not the number of acceptance cases.
2. Follow-up with `MIX_TEST_PARTITION=windows_followup`, the same seed, and
   `window_config_hook_test.exs`, `popup_move_test.exs`,
   `buffer_lifecycle_test.exs`: **11 tests, 3 failures**. The two window-config
   failures reproduced; popup stacking and the rename/lifecycle assertions
   described above passed. The additional failure was binary-file save.
3. Temporary `MIX_ENV=test mix run` probes exercised the exact nested-close,
   repeated-name, duplicate-predecessor, stale-name, and scroll sequences above.
   They are observations, not newly installed regression tests.

Failures in the first run:

- `WindowConfigHookTest`: visiting an ungrouped buffer did not clear the frame's
  group as the test expected.
- `WindowConfigHookTest`: `ibuffer-promote-group` was unbound.
- `DesktopRestoreTest`: a literal `aa-other-mode` had no registered mode.
- `DesktopRestoreTest`: restored LLM configuration used a property list while
  the assertion expected positional triples.

The follow-up's additional `BufferLifecycleTest` failure was a buffer process
crash during binary-file save. These failures were present during this audit;
they were not fixed, and not all are explanations for window-history loss.

The highest-confidence gaps to turn into regression tests are nested local
unwind, nested temporary-pane dismissal, consistent `q` versus kill predecessor
selection, stale quit records after kill/rename, and complete view restoration.

## Child-first dismissal and reading surfaces

Buffer ownership and window history answer different questions. A parent owns
related, dismissible child buffers. A window remembers what those buffers cover.
Ownership chooses which child `q` dismisses. Window history chooses what appears
underneath. Dismissing a child must not invoke the parent's back/quit handler in
the same keypress.

- `buffer-child!` registers a parent and child. Relationships reject cycles and
  use reciprocal buffer locals. Rename updates both sides; kill removes links.
- `q` prefers a visible descendant in the current frame, deepest first. It then
  considers hidden dismissible descendants. Unrelated buffers do not participate.
- With no dismissible descendants, an owned reading buffer dismisses itself.
  Otherwise, `q` delegates to the buffer's original command, including remaps.
- Each affected window reveals its own previous buffer, including transient
  lists or buffers also visible elsewhere. Existing work panes remain present.
  A pane recorded as created for this display can be removed when it is dismissed.
- A child still displayed in another frame remains alive. That other frame's
  view does not block this frame's next `q` from reaching the parent handler.
- Writable buffers retain normal text entry, including typing `q`. Merely owning
  a dismissible child does not turn an editable document into a reading surface.
- Dismissible reading buffers have a distinct header with a prominent, clickable
  `q Back` control. Their text cursor is hidden by default. `M-x
  caret-browsing-mode` toggles the cursor without changing edit permissions.
- A mode that navigates by point keeps its cursor: `dismiss-keep-caret!` names
  such a mode, and its buffers get caret browsing when they become dismissible.
  `browse-mode` is one, because `RET` follows the link at point and `n`, `p` and
  `TAB` walk the links. The default is applied once per mode, so a later `M-x
  caret-browsing-mode` is still the reader's answer.

Notmuch thread views register as children of their search buffer during mode
setup, including reload/restore. From the search, the first `q` dismisses its
visible thread and preserves the selected search row. The next `q` invokes
notmuch's own back handler. From the thread, `q` dismisses the thread and keeps
the search alive. An explicit `notmuch-quit` still means to close mail.

Regression coverage lives in `Compos.DismissTest`, `Compos.NotmuchSceneTest`, and
`Compos.Ui.DismissTest`. This adds child-first routing and reading cues; it does
not claim to repair every Winner identity or nested temporary-window ownership
gap listed in the audit above.
