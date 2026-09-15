# Lists

The list mode in `priv/editor.scm` draws every table in the editor: ibuffer, dired, the switcher, feeds, sentry, the telemetry. A mode says what its columns are and what one row puts in them. The mechanism lays out, pads, colours, pages, narrows, and draws. This document holds the rules the mechanism keeps.

## One draw

1. A draw reads the mode once. The row context (`list-row-ctx`) carries the mark column, the column lines, the mode's `cells`, `row-cells`, `render`, and `key` fns, and the marks. Every row reads the context. No row calls `list-opt` or reads a buffer-local: a buffer-local read is a call into the buffer's process (0.16 ms), and a row that asked ten times cost 6 ms.
2. The header is computed once per draw and passed down with its line count. Each displayed row computes its cells and text lines once; semantic records reuse both. Selection overlays use the saved row offsets, so cursor movement never recomputes cells.
3. The chip (the narrowing and its count) is computed only while the list is narrowed. Counting asks the mode about every row.
   The key bar (the mode's `'footer` keys) is a header line under the counts, where the eye lands on an open; at the foot of the text it scrolled away with the rows.
4. A draw is few buffer changes: one `buffer-replace-range!` of the whole text, one `buffer-set-locals!` for the offsets, the head count, the row height, the width, and the stamp, one overlay set, one goto. Every change is a frame refresh and a render. A delete and then an append let a render between them see an empty buffer, reset the window's top, and write it back; the view jumped. `list_draw_test.exs` holds a redraw at eight changes or fewer.
5. Numbers that hold this: 400 rows draw in about 330 ms and 60 rows in about 150 ms, on a laptop, with faces on every cell.

## Pages

1. A mode with many rows declares `'page-size N`. The draw writes the first page. The entries keep every row, so the counts, the filters, and the marks see them all. The drawn rows are a prefix of the entries, so an index names the same row in both.
2. `n` on the last drawn row and PgDn (`scroll-up-command`, remapped in every table to `list-page-down`) draw the page they land on first, so a screen never ends in the key bar with rows to come. `list-more` draws the next page by name.
3. The meta line says "N of M shown, PgDn draws more" while rows remain.
4. An open shows the first page again. The pages you drew were for the last visit.
5. Wheel scroll does not draw pages: the server owns scrolling, and a scroll runs no command.

## Order

1. A list with `'local-filter` fetches its rows on an open and on `g`, and a mark, a flag, or a narrowing redraws the rows it has. A source in MRU order changes under a row's preview; a table that refetched on every mark moved the row under the cursor.
2. `ibuffer` sections its rows by group, by mode, or by directory (`ibuffer-toggle-grouping`). Under the group sectioning the frame's group comes first, then the other groups by name, then the ungrouped rows. Inside a section the rows sort by name, by recency (MRU), or by size (`ibuffer-toggle-sorting-mode`); the defaults are `ibuffer-default-grouping` and `ibuffer-default-sorting-mode`.
3. A folded section (`ibuffer-toggle-filter-group`) is one heading row that carries the member count, the modified count, and the bytes. It is not a separator: the narrowing keeps it while a member matches, the highlight can rest on it, and RET opens it. The meta line counts folded members.
4. A right-aligned last column pads on its left, so its text ends at the column's edge; its face span starts after the padding.
5. The key bar fits the window. A key that does not fit is dropped from the end, and a bar that dropped any ends in `? keys`, where `?` shows them all. A bar that wrapped took two lines and pushed the rows down.
6. A mode's `'meta` answers a string, or `(TEXT SPANS)` with its own faces. The ibuffer wide head says the grouping and the sort as chips this way, the current one lit.

## Point

1. The point belongs to the reader. No process moves it: a draw restores the row by its key, a peek popup opening or closing beside the listing moves nothing (docs/POPUPS.md rule 10), an open of a list you already have keeps the row you left it on. A narrowing lands on the first row because the old row may be gone; that is the reader's own act.
2. Remembering is enough. Dired: a listing opened for the first time starts on its first entry; opened again, it is where you left it. `^` and `RET` on `..` open the parent listing where it was — the row you left it on is the directory you went into, so nothing needs computing.

## Narrowing

1. `/` narrows on every keystroke; `\` widens by one. The filters stack and persist with the buffer; an open clears the typed query and keeps the mode's own kinds.
2. Repeating an unchanged query does nothing. `(list-set-query! BUF QUERY #t)` changes the query and fetches its source in one draw. C-x c uses this only when crossing between the recent and full chat scopes; later keys reuse the source. Closing a disposable prompt clears the query without redrawing a table that is about to be killed.
3. A mode's own filter kinds (`'filter (buf entry f)`) ride the same stack. The telemetry's `t`, `k`, and `s` are such kinds, and the same key again widens.

## The telemetry list

1. `C-t` shows `*Telemetry*` in the popup, on the right (docs/POPUPS.md). `C-t` on it dismisses it: a popup buffer under it comes back, else the popup closes.
2. Two views by measured width: under 100 columns the time, the layer, the job, the bar, and the number; from 100 columns the owner, the wait, and the trace too. RET shows every field in either.
3. A layer wears one colour. The bar beside a duration is on one scale: a full bar is the slow threshold. The meta line shows p50, p95, a sparkline of the newest 24 keystroke round trips (oldest on the left), and the last key with its time.
4. The list follows the work the user causes. The collector sends Scheme one notice per burst of rows, once a second at most, and never waits. Scheme redraws only while the list shows and only when a row the user caused arrived since the last draw: a keystroke or an intent (a traced row) or a Scheme job. The list's own refresh leaves live rows, browser rows, and a lane job named after the package; those are not causes, so a quiet editor draws nothing.
5. The editor's own untraced `refresh` and `render` rows are hidden by default. Every buffer change makes one pair, and they say nothing a traced row does not. `a` shows them; the meta line says "quiet" while they are hidden.
6. 60 rows a page; 400 events retained in the view.

## Chat previews

C-x C-c and C-x c share the chat list. Filtering and row navigation update the selection immediately; the preview waits for 150 ms of idle time (`chat-list-preview-delay-ms`). Both paths use the same per-frame debounce. Leaving cancels the pending request, and callbacks recheck the selected row and preview window before loading it. Timer bookkeeping stays outside display state.
