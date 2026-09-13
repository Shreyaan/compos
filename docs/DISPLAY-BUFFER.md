# Display buffer

Where a buffer goes when a command shows it. The mechanism is Emacs' `display-buffer`, in Scheme, in the display-buffer section of `priv/editor.scm`.

## Which window

Where a buffer lands follows from what you did, not from what the buffer is.

- You found a file, or ran a command that opens one thing: it takes the
  **selected window**. That is `switch-to-buffer!`, verb 1 below.
- You opened a row from a list — dired, ibuffer, a table, a search result:
  it takes the **other window**, the one the list was previewing it in. The
  list keeps its own window until it closes. That is the peek chain
  (docs/PEEK.md) and `show-in-other-work-window!`.
- You opened a row whose detail is its own buffer — a Sentry issue, a
  WhatsApp chat: it takes the list's **detail window**, and every later row
  takes that same window. `display-buffer-detail!`, below.
- A preview lands in the window the pick will land in. Look and open are
  the same window, always.

## The three verbs

1. `switch-to-buffer!` visits a buffer. With a target layout it reuses an existing view, fills spare capacity, then replaces the selected pane. Without a target it takes the selected window. Foreign buffers use the popup.
2. `display-buffer` shows a buffer somewhere else and selects nothing. A result, a listing, a help page, a shell take their window through it. It returns the window.
3. `pop-to-buffer` is `display-buffer` and then a `select-window!`. A listing you open to work in uses it (`list-mode-show!`).

## The chain

`display-buffer` tries a list of actions in order and stops at the first that answers with a window:

1. the rule for the name in `*display-buffer-alist*`;
2. `*display-buffer-base-action*`, the user's list, empty by default;
3. `*display-buffer-fallback-action*`: `reuse-window`, `pop-up-window`, `use-some-window`, `same-window`.

The actions:

| action | what it does |
| --- | --- |
| `reuse-window` | a window that shows the buffer already |
| `pop-up-window` | split the largest work window when it is big enough (`split-window-sensibly`), else the selected one |
| `use-some-window` | the least recently used other work window; excludes the popup and peeks |
| `same-window` | the selected window (`same` is the same action) |
| `popup` | the side window (`popup-show`, docs/POPUPS.md) |

`define-display-action!` adds one. An action is a function of the name and the alist that returns a window or `#f`.

## Splitting

`split-window-sensibly` is Emacs' rule: a window with `split-height-threshold` rows (80) splits below; else a window with `split-width-threshold` columns (160) splits beside; else the sole work window splits below whatever its size. Two windows side by side on a laptop meet neither threshold, so the next display takes the other window instead of making a third. Both thresholds are `defcustom`s in the `windows` group.

## Layout presets

An explicitly chosen layout is a **target**. It remains selected as buffers
open and panes close. Choosing it with one buffer works: that buffer occupies
the whole frame until there is another buffer to show.

| Target | Capacity | Arrangement |
| --- | --- | --- |
| `two-pane` | 2 | first pane 2/3, companion 1/3 |
| `columns` | 3 | equal columns |
| `rows`, `grid`, `main-*` | occupied panes | apply the chosen tiler as work opens |
| `adaptive` | occupied panes | choose the tiler for the current frame width |
| `free` | sensible splitting | no target |

Pane order is stable across focus changes. Main layouts retain their logical
main pane even when it is physically on the right or bottom. Changing to a
smaller target keeps the first slots and ensures the focused buffer remains
visible; surplus buffers remain open in the group.

Explicit layout selection and preview use one order: existing pane buffers
first, then the group's other eligible buffers in MRU order, with ordinary
work before companions. The picker captures this order once; highlighting
another layout or accepting it distributes the same sequence over its slots.
Existing panes keep their buffers, including Dired, other special lists,
visible non-members and deliberate duplicate views. A layout change never
substitutes hidden work for an already occupied slot. Floating popup windows
are excluded from the base arrangement.

Only hidden fillers are subject to eligibility: no peeks, floating popups,
special buffers, context-only buffers or foreign group members. Existing
group chats and scratch buffers are eligible fillers. Fixed targets cap the
sequence at their capacity. With no group, flexible layouts use visible panes
and fixed layouts fill from the eligible global MRU. Missing capacity creates
no placeholder buffer. Preserving an already displayed non-member does not
change its membership or import other foreign buffers.

`C-x 2` and `C-x 3` put an eligible buffer not already visible into the new
pane, using the same sealed group pool. Focus stays in the original pane.
Only when there is no other candidate does the split show the same buffer.
Low-level `split-window!` retains its duplicate-view mechanism for callers
that deliberately construct a layout.

| Action under a target | Result |
| --- | --- |
| New chat (`C-c n`) | replace the selected pane in place; keep geometry and its previous buffer in pane history |
| Visit an already visible buffer | select its existing pane |
| Open a new member below capacity | append a slot, reflow, select it |
| Open a member at capacity | replace the selected slot |
| Display an ordinary result | fill capacity, else replace the least recently used other pane; preserve focus |
| Close a pane | reflow surviving slots; do not pull hidden work back in |
| Kill a buffer | refill from eligible pane history, then hidden group work, then existing group companions |
| Quit a displayed result | restore the borrowed pane or remove the pane created for it |
| Cancel a layout preview | restore the original tree, focus, and ordering cache |
| Switch groups | save and restore that group's target and tree on this frame |

Group kill repair retains its final chat/scratch fallback and creates the surviving group’s chat when no companion remains. No foreign buffer
is eligible to refill a sealed group's pane. Background buffer contexts do
not open or rearrange visible panes. Mode-entry layouts and automatic
relayout hooks defer to an explicitly selected target.

Relayout preserves each view's point and buffer history, including separate
views of one buffer. The active target is saved with the desktop even without
switching groups. `window-layout-free` releases the target. `s-RET` (`autolayout`) deliberately promotes the selected pane to main, preserving the existing main-layout side. The default side applies only when the current target has no main pane.

The measured regression journeys are in `priv/tests/layout-policy-test.scm`,
with a disposable-frame runner and keyboard-path test in
`test/compos/layout_policy_test.exs`. Each journey records normalized
`(buffer x y width height)` rectangles after each transition. For example:

| Rows journey | Geometry `(y, height)` in slot order |
| --- | --- |
| A, choose rows | A `(0, 1)` |
| open B | A `(0, 1/2)`, B `(1/2, 1/2)` |
| open C | A `(0, 1/3)`, B `(1/3, 1/3)`, C `(2/3, 1/3)` |
| close B's pane | A `(0, 1/2)`, C `(1/2, 1/2)` |
| reopen B | A `(0, 1/3)`, C `(1/3, 1/3)`, B `(2/3, 1/3)` |

## Rules

`(add-display-rule! PATTERN ACTION [PARAMS])` puts a rule in front. PATTERN is a substring of the buffer name, or `(category KIND)` for a kind of display the caller names in the alist. ACTION is one action name or a list of them. A rule's actions come before the base action and the fallback, so a rule that names `popup` always lands in the popup, and a rule that names `same-window` never splits.

The callers pass an alist, a plist:

- `'category KIND`: the kind of display. A peek passes `preview`, a list's row detail passes `detail`. The stock rule `((category preview) (reuse-window use-some-window pop-up-window))` is last in the alist, so a rule for a name wins over it.
- A display of a buffer from outside the frame's group that names no category is a display of category `foreign` (`display-foreign?`, answered by groups.scm). The stock rule `((category foreign) popup)` sends it to the popup, so a group's panes stay sealed (docs/groups.md). `switch-to-buffer!` obeys this rule (Emacs `switch-to-buffer-obey-display-actions`); a mechanism that fills a window it chose calls `switch-to-buffer-here!`. To route foreign buffers through the window chain instead: `(add-display-rule! '(category foreign) 'pop-up-window)`.
- `'inhibit-same-window #t`: keep the selected window out of the chain. `display-buffer-other-window!` is `display-buffer` with this set.

## Previews are a rule

A peek (docs/PEEK.md) is a display of category `preview`. By the stock rule it goes through the window chain: dired and the browser show a file beside the listing without keeping it, in a window that is not the reader's. A popup moves the layout and hides the work under it, so no preview takes one. The next peek takes the same window, and dismissing the peek puts the window back. To preview in the popup instead, in `init.scm`:

```scheme
(add-display-rule! '(category preview) 'popup)
```

Point stays in the listing either way.

## Details are a rule and a memory

A table whose rows are each their own buffer — Sentry issues, WhatsApp
chats, MCP servers — opens them all into ONE window. `(display-buffer-detail!
NAME [OWNER])` (`packages/detail.scm`) is how: the first row picks a window
through the chain as category `detail`, and the window is remembered against
the list, so every row after it retakes that window. Without the memory each
row is a new buffer name, `reuse-window` never matches, and the layout grows
a pane per row.

This is the one place a window is remembered rather than chosen at display
time, and it lapses on its own: when the window goes, when it holds the list
itself, or when the list asks from it.

A detail is not a peek. It is kept, it is writable, and it stays when the
list goes. The list owns it (`buffer-child!`, `packages/dismiss.scm`), so `q` on the
list takes the detail with it, and the details of one list are siblings:
`C-\`` in the detail window walks them, most recent first, the way it walks
chats in a chat pane.

A list that rewrites ONE detail buffer per row (notmuch's `*mail*`, the
telemetry event) needs none of this — `reuse-window` already finds the name.

Tests: `priv/tests/detail-test.scm`, run by `test/compos/detail_test.exs`.

## quit-window

A display notes what it did to a window: `window` when it made the window, `other` when it took a window that showed another buffer. `q` (`quit-window`) undoes that first, then kills the listing: the window the display made goes, or the buffer the display replaced comes back. `window-quit-restore!` does the undo alone.

Tests: `priv/tests/display-buffer-test.scm`, run by `test/compos/display_buffer_test.exs` in the test daemon (they rearrange windows).

Cmd-Shift-arrows move the active view onto the neighboring pane's history,
revealing the source pane's previous group buffer. Focus and point follow the
view; split geometry stays fixed. With no neighbor or no eligible previous
buffer, nothing moves. The named `window-*` commands still swap.
List modes may specify `'special #f` for persistent app buffers such as
WhatsApp; generated lists otherwise keep the special default.
