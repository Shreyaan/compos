---
name: app-creator
description: Build a compos app — a listing, one detail buffer per row, and actions on both. Use for requests to create an app-shaped mode (amazon, mail, sentry, whatsapp shaped), an app group, a list-plus-detail view, or app-wide keys. Read it before any define-list-mode! call: it owns the reserved list keys (/ is always the filter), the column-width budget, the responsive layout profiles, the home group, the detail window and its `` C-` `` walk.
---

# Build a compos app

An app is three things and nothing more:

- a LISTING — one selectable row per thing
- a DETAIL — one buffer per row, beside the listing
- ACTIONS — the same verbs on both, under the same keys

Name the app once and name everything after it. App `amazon` gives listing buffer `*amazon*`, modes `amazon-mode` and `amazon-detail-mode`, detail buffers `*amazon:KEY*`, commands `amazon-*`, settings `amazon-*`.

Read the `mode-create` skill first. It owns how a mode and its components are built. This skill owns what makes a mode an app.

## Discover before building

1. `(apropos "WORDS")` for every verb the app needs, `(apropos-components "WORDS")` for every part of the view.
2. Read `scheme/packages/detail.scm`. It is short and it is the whole detail contract.
3. Read one existing app end to end: `notmuch.scm` for the group, `sentry.scm` or `whatsapp.scm` for a listing whose rows are their own buffers.
4. Confirm every name you mean to call with `(boundp 'NAME)`. Do not write a call from memory.

## The four invariants

### 1. The app opens where you already are

An app does not take you anywhere. It opens in the group the frame is already in: no jump, no group of its own arriving in the switcher, nothing to find your way back from. Opening an app is not a reason to move the reader.

But every app buffer must JOIN that group. A pane holding a group member is a place, so the group saves the app's layout and restores it whole. An ungrouped pane reads as a cover: the group then refuses to save its layout on the way out, and coming back restores a tree from before the app was ever on screen.

So: no group of the app's own, and no ungrouped app buffers either.

```scheme
;; every buffer the app opens joins the group the reader is already in —
;; the listing and every detail
(define (amazon-join-group! buf)
  (when (buffer-exists? buf)
    (let ((id (frame-group)))
      (when (and id (not (buffer-in-group? buf id)))
        (buffer-add-group! buf id)))))
```

Every render joins. No exceptions: a detail opened by a preview timer with no frame group is exactly the case that loses the layout.

An app opened from an ungrouped frame has no group to join, and so has no saved layout. That is the reader's position to be in, not the app's to correct.

### 2. The listing is a list mode

`(define-list-mode! "amazon-mode" OPTS)` with `'transient #f` — an app buffer is persistent, not a derived view.

A list already knows how to be a list. Do not rebuild filtering, marking, row motion, sorting or grouping: declare the table and the verbs, and take the rest. Read `(apropos "define a list mode")` for the full option list before you start.

`'rows` `'columns` `'cells` `'key` are the table. `'preview` is what makes it an app: moving the point opens that row's detail. `'keys` are the actions. `'doc` is the mode's help and must name every key.

Rows are data, not text. Keep the parsed record in the row and let `'cells` render it, so an action on a row has the whole record and not a printed line.

#### Keys you do not get

Four keys are bound on your map AFTER your own, so a mode that declares one silently does not get it and the footer that advertises it is a lie:

| key | is | always |
|---|---|---|
| `/` | `list-filter` | narrows the rows to what you type. `/` is the search key everywhere in this editor, so it is the search key here |
| `<` | `list-cycle-grouping` | your optional regroup callback |
| `>` | `list-cycle-sorting` | your optional resort callback |
| `SPC` | your `'mark-command`, else `list-mark` | |

Nine more are inherited from `list-mode-map` and ARE yours to shadow: `f` also filters, `\\` pops the filter, `?` describes the mode, `n`/`p` walk, `m` marks, `u`/`U`/`*` unmark and mark-all, `x` executes the marks, `g` reverts. Most apps shadow `g` with their own refetch. That is fine.

Give your own verbs the letters none of these use. A server-side filter is not the same thing as `/` — `/` narrows the rows already drawn, so put "read a different query" on its own key (`t` for a tab, `s` for a scope) and say so in `'doc`.

After you define the mode, read the map back rather than trusting the declaration:

```scheme
(keymap-bindings (mode-keymap "amazon-mode"))
```

#### Columns have a budget

A column width of `#f` takes the rest of the line. Exactly one column should have it, and it should be the one holding the longest text. Everything else is a fixed number, and those numbers are a budget against the frame.

Declare responsive profiles instead of one wide table. They are ordered and the first match wins, so narrowest first:

```scheme
'layouts (list (list 'name 'narrow 'max-cols (lambda (buf) 84)
                     'columns amazon--narrow-columns 'cells amazon--narrow-cells)
               (list 'name 'mid 'max-cols (lambda (buf) 118)
                     'columns amazon--mid-columns 'cells amazon--mid-cells)
               (list 'name 'wide 'default #t))
```

Drop columns as the frame narrows; never let the `#f` column be squeezed to nothing. A column that is empty on almost every row has not earned its width — compute the columns from the rows and leave it out when no row fills it:

```scheme
(define (amazon--columns buf)
  (append (list (list "item" 28))
          (if (amazon--any-discount? buf) (list (list "was" 10)) '())
          (list (list "title" #f))))
```

Two things that will cost you an hour otherwise:

- The chosen profile is cached per width in the `list-layout-cache` buffer local. A profile you add after the buffer exists is not picked up until that local is cleared: `(buffer-set-local! buf 'list-layout-cache #f)`.
- A buffer with no window measures at a default width, so verify the layout in a real window, or check `(list-view-width buf)` before believing the draw.

#### Say what a column means

A column heading is a claim. If the value under it is a proposal, a draft or a request rather than the thing itself, the heading must say so, and two different kinds of fact never share one column. Test it by reading one row aloud as a sentence: if the sentence is false, the heading is wrong.

### 3. One detail buffer PER ROW, opened with display-buffer-detail!

This is the invariant that gets missed. A listing that rewrites one detail buffer works — but `` C-` `` then has a single buffer to walk and says so. Name the detail after the row's key:

```scheme
(define (amazon-detail-buffer row)
  (string-append "*amazon:" (plist-get row 'asin) "*"))

(define (amazon-show-detail! row)
  (when row
    (let ((buf (amazon-detail-buffer row)))
      (amazon-render-detail! buf row)
      (amazon-join-group! buf)
      (display-buffer-detail! buf *amazon-buffer*))))
```

`display-buffer-detail!` does four things you must not do by hand:

- picks a window through the display chain as category `detail`
- REMEMBERS that window per listing, so the next row retakes the same pane instead of growing one
- makes the detail the listing's child, so `q` on the listing takes it along
- enables `detail-mode` on it, which is where the walk comes from

Free, on every detail, once you have done the above:

| key | does |
|---|---|
| `` C-` `` | walk the details opened from this listing, most recent first |
| `` C-M-` `` | walk them the other way |
| `M-RET` | keep this detail: it takes a name of its own, and the next row opens a fresh one |

Give the kept name a rule, or it takes a number:

```scheme
(detail-name! "amazon-detail-mode"
  (lambda (buf) (string-append "*" (or (buffer-local buf 'amazon-title) buf) "*")))
```

Never move a detail with `switch-to-buffer!`, `pop-to-buffer` or a bare `display-buffer`. Each bypasses the remembered window, and the app grows a pane per row.

### 4. Three columns

Do not split by hand. Hand the app's panes to the tiler and the columns come out on their own:

```scheme
(define (amazon-layout!)
  (tile-default-windows!
    (filter buffer-exists?
            (list (group-chat (frame-group))
                  *amazon-buffer*
                  (amazon-current-detail)))))
```

`tile-default-windows!` uses the frame's chosen layout. A frame that never
chose gets the layout that fits the panes:

| panes | layout |
|---|---|
| 1 | `single` |
| 2 | `two-pane` |
| 3 or more | `columns` |

So the app's three panes — the group's chat, the listing, the current detail —
are three columns. A fourth pane does not make a fourth column: the layouts hold
at most three, and the extra buffers sit on the frame's strip, where Cmd-left and
Cmd-right reach them. That is the whole layout policy. Save the arrangement with
`(group-layout-save! id)` once the panes stand.

## Where the rows come from

A listing is only as good as what fills it, and this is where an app is most often built wrong.

### Fetch the rendered page, not a reading

`(browser-snapshot URL K &optional WAIT)` loads URL in a background tab and answers the rendered html. It carries the reader's cookies, so the prices and the delivery promises are the account's own, and nothing of their browser moves.

Do NOT use `browse` for an app's data. `browse` answers a *reading* — the page through pandoc, as markdown. One app was built that way and grew twenty-four helpers to slice a price out of prose, every one of them a guess about how a sentence is punctuated. The html is the data; markdown is a rendering of it.

`WAIT` names a CSS selector the content is finished by. A load event is not an answer: Amazon's cart replies `complete` with an empty basket and fills it afterwards, so a snapshot without a selector reads a cart with nothing in it.

The callback is not a reason to write a polling loop. There is already a way to wait:

```scheme
(task-await
  (task-spawn (lambda ()
    (let ((done #f) (val #f))
      (browser-snapshot url (lambda (h) (set! val h) (set! done #t)))
      (wait-until (lambda () done) 20000 50)
      val))))
  25000)
```

Every hand-rolled `debounce!` retry chain in an app is this, written again and worse.

### The sheet that extracts, not the sheet that deletes

There are two kinds of stylesheet and only one of them makes rows.

`xslt-learn` writes a SUBTRACTIVE sheet: copy the document, delete the furniture. That is how a page becomes a calm reading, and it is genuinely good at it — on a product page it found six sponsored slots by itself. It cannot make records, because nothing in it names a field.

A listing needs an EXTRACTIVE sheet, and you write that by hand: `method="text"`, one record per repeating unit, emitted as JSON. `json-parse` turns it into plists with symbol keys, which is what `'rows` wants — records, not text.

Find the anchor with `xslt-discover`, and raise `xslt-discover-depth` first. It defaults to 6, the record container is usually deeper, and `xslt-children` answers nothing below the depth you asked for, which reads exactly like a page with no rows in it.

### Four ways the anchor is wrong

- **Anchor on the record, not the slot it sits in.** Amazon marks its ad carousels `s-result-item` the same as its products: on one page, 24 `s-result-item` nodes were 16 products, 2 ad carousels, 3 labels, the facet rail, related searches and a help line. `puis-card-container` is products only.
- **A page often holds two lists.** A cart carries `sc-active-*` and `sc-saved-*` — 4 against 15 on a real one. Anything that searches the page as a whole calls saved-for-later "in the cart".
- **An element can carry the identifying attribute and not be a record.** A removal notice keeps its asin and its `sc-active-` id and holds no product. Test for a field only a real record has: a thing in a cart has a quantity.
- **Markup has generations.** Stable ids like `#*_feature_div` and `.udm-primary-delivery-message` outlive webpack-hashed classes like `._npack-asin-card_style_card__33l20`, which change without warning and fail silently. Anchor on the former and the sheet survives a redesign.

### Clean it for the column it lands in

The page writes for a page. A column is narrower and repeats every row, so cut what every row shares: `FREE delivery Today 4 pm - 8 pm on ₹399 of items` is a date wearing thirty characters of boilerplate, and the threshold is a condition on the order, not a time.

A listing thumbnail is sized for a listing. A detail page asking for the same URL gets a crop meant for a table cell; serve the page its own size where the site allows it.

### Ask the source, do not infer from a count

An action that changes something elsewhere is confirmed by asking what is there now, not by watching a number move. "The cart page names this ASIN" is an answer. "The badge went from 3 to 4" is a guess that a stale badge, another tab, or a second click can fake — and it cannot tell you *which* thing was added.

## The detail may be a rendered page

A detail buffer is not limited to text. Set the renderer and it is HTML:

```scheme
(buffer-set-local! buf 'preview-renderer "html")
(enable-minor-mode! buf "preview-mode")
(preview-heal! buf)
```

Two things follow from the sandbox (`allow-same-origin` only, no scripts):

- No JS runs in the page. All behaviour is Scheme.
- A link is not a navigation. The editor intercepts it on mousedown and hands the href to Scheme. Claim a verb and the page gets buttons:

```scheme
(add-hook! (list 'preview-link "cart") (lambda (arg) (amazon-cart-add! arg)))
;; then in the page: <a class='btn' href='compos:cart/B0BLVCFK8D'>Add to cart</a>
```

Size the page in `rem` off a `vw`-based root font. The preview lays out far wider than the pane and paints scaled, so fixed pixels come out at about half the size you meant.

## Actions

Same verb, same key, both places. The listing reads its row with `(list-current BUF)`; the detail keeps its record in a buffer-local. One function takes the record and does the work, and both keys call it.

Every action answers: a `message` on the way in, a `message` with the result, and the raw failure into the app's own log buffer. An action that fails silently is a bug report you will never receive.

Actions that leave the editor — a cart, a send, a purchase — are the user's click, never the agent's. Wire them; do not fire them to test.

## Entry command

One command named after the app, and it is the only way in:

```scheme
(define-command "amazon" "Open the Amazon app"
  (lambda ()
    (let ((buf (amazon-listing!)))   ;; creates, joins, sets the mode, renders
      (amazon-show-detail! (list-current buf))
      (amazon-layout!)
      (group-layout-save! (frame-group))
      (switch-to-buffer! buf))))
```

## Verify

1. `(boundp 'NAME)` for every new public name, then `(apropos ...)` for its metadata.
2. Open the app. `(window-list-all)` shows three panes in ONE frame, and `(buffer-group BUF)` is the group you opened it in, for the listing AND every detail.
3. Move down two rows, then `(buffer-list)`: one detail buffer per visited row, and `(detail-window "*amazon*")` is the same window id throughout.
4. Drive `` C-` `` through `KeyDispatch.handle_key/1` and confirm it walks those buffers rather than reporting one.
5. `q` on the listing takes the details with it. A detail kept with `M-RET` stays.
6. Narrow the frame below `window-layout-wide-cols`, run the layout again, confirm it stacks instead of columning.
7. Leave the group and come back: the layout is the one you left.
