---
name: app-creator
description: Build a compos app — a listing, one detail buffer per row, and actions on both. Use for requests to create an app-shaped mode (amazon, mail, sentry, whatsapp shaped), an app group, a list-plus-detail view, or app-wide keys. Owns the home group, the responsive three-column layout, the detail window and its `` C-` `` walk.
---

# Build a compos app

An app is three things and nothing more:

- a LISTING — one selectable row per thing
- a DETAIL — one buffer per row, beside the listing
- ACTIONS — the same verbs on both, under the same keys

Name the app once and name everything after it. App `amazon` gives group
`*amazon*`, listing buffer `*amazon*`, modes `amazon-mode` and
`amazon-detail-mode`, detail buffers `*amazon:KEY*`, commands `amazon-*`,
settings `amazon-*`.

Read the `mode-create` skill first. It owns how a mode and its components are
built. This skill owns what makes a mode an app.

## Discover before building

1. `(apropos "WORDS")` for every verb the app needs, `(apropos-components
   "WORDS")` for every part of the view.
2. Read `priv/packages/detail.scm`. It is short and it is the whole detail
   contract.
3. Read one existing app end to end: `notmuch.scm` for the group, `sentry.scm`
   or `whatsapp.scm` for a listing whose rows are their own buffers.
4. Confirm every name you mean to call with `(boundp 'NAME)`. Do not write a
   call from memory.

## The four invariants

### 1. The app opens in its own group, always

An app has ONE home group, not whichever group the frame stood in when a key
was pressed. A pane holding a group member is a place, so the group saves the
app's layout and restores it whole. An ungrouped pane reads as a cover: the
group then refuses to save its layout on the way out, and coming back restores
a tree from before the app was ever on screen.

```scheme
(defcustom 'amazon-group-name "*amazon*"
  "The group the Amazon app lives in. The listing and the product pages are one app, so they always open in this group and a layout holding them is saved and restored with it."
  'group 'amazon)

(define (amazon-home-group!)
  (and (boundp 'group-ensure-record!)
       (string? amazon-group-name)
       (not (equal? amazon-group-name ""))
       (group-ensure-record! amazon-group-name)))

;; opening the app enters the app's group, the way opening a project enters its own
(define (amazon-enter-group!)
  (let ((id (amazon-home-group!)))
    (when (and id (not (equal? (frame-group) id))) (switch-to-group! id))
    id))

;; every buffer the app opens joins it — the listing and every detail
(define (amazon-join-group! buf)
  (when (buffer-exists? buf)
    (let ((id (or (amazon-home-group!) (frame-group))))
      (when (and id (not (buffer-in-group? buf id)))
        (buffer-add-group! buf id)))))
```

The entry command enters. Every render joins. No exceptions: a detail opened by
a preview timer with no frame group is exactly the case that loses the layout.

### 2. The listing is a list mode

`(define-list-mode! "amazon-mode" OPTS)` with `'transient #f` — an app buffer
is persistent, not a derived view.

`'rows` `'columns` `'cells` `'key` are the table. `'preview` is what makes it an
app: moving the point opens that row's detail. `'keys` are the actions. `'doc`
is the mode's help and must name every key.

Rows are data, not text. Keep the parsed record in the row and let `'cells`
render it, so an action on a row has the whole record and not a printed line.

### 3. One detail buffer PER ROW, opened with display-buffer-detail!

This is the invariant that gets missed. A listing that rewrites one detail
buffer works — but `` C-` `` then has a single buffer to walk and says so.
Name the detail after the row's key:

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
- REMEMBERS that window per listing, so the next row retakes the same pane
  instead of growing one
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

Never move a detail with `switch-to-buffer!`, `pop-to-buffer` or a bare
`display-buffer`. Each bypasses the remembered window, and the app grows a pane
per row.

### 4. Three columns on a wide frame

Do not split by hand and do not hardcode a width. Hand the app's panes to the
responsive tiler and the columns come out on their own:

```scheme
(define (amazon-layout!)
  (tile-adaptive-windows!
    (filter buffer-exists?
            (list (group-chat-buffer (amazon-home-group!))
                  *amazon-buffer*
                  (amazon-current-detail)))))
```

`window-layout-for-width` is pure — inspect the choice before you change a
frame:

| frame width | panes | tiler |
|---|---|---|
| below `window-layout-compact-cols` | any | `main-bottom` |
| below `window-layout-wide-cols` | any | `main-right` |
| wide | 2 | `main-right` |
| wide | **3** | **`columns`** |
| wide | 4 or more | `grid` |

So the app's three panes — the group's chat, the listing, the current detail —
are three columns on a widescreen and stack sensibly when the frame is narrow.
That is the whole layout policy. Save the arrangement with
`(group-layout-save! id)` once the panes stand.

## The detail may be a rendered page

A detail buffer is not limited to text. Set the renderer and it is HTML:

```scheme
(buffer-set-local! buf 'preview-renderer "html")
(enable-minor-mode! buf "preview-mode")
(preview-heal! buf)
```

Two things follow from the sandbox (`allow-same-origin` only, no scripts):

- No JS runs in the page. All behaviour is Scheme.
- A link is not a navigation. The editor intercepts it on mousedown and hands
  the href to Scheme. Claim a verb and the page gets buttons:

```scheme
(on-preview-link! "cart" (lambda (arg) (amazon-cart-add! arg)))
;; then in the page: <a class='btn' href='compos:cart/B0BLVCFK8D'>Add to cart</a>
```

Size the page in `rem` off a `vw`-based root font. The preview lays out far
wider than the pane and paints scaled, so fixed pixels come out at about half
the size you meant.

## Actions

Same verb, same key, both places. The listing reads its row with
`(list-current BUF)`; the detail keeps its record in a buffer-local. One
function takes the record and does the work, and both keys call it.

Every action answers: a `message` on the way in, a `message` with the result,
and the raw failure into the app's own log buffer. An action that fails
silently is a bug report you will never receive.

Actions that leave the editor — a cart, a send, a purchase — are the user's
click, never the agent's. Wire them; do not fire them to test.

## Entry command

One command named after the app, and it is the only way in:

```scheme
(define-command "amazon" "Open the Amazon app"
  (lambda ()
    (amazon-enter-group!)
    (let ((buf (amazon-listing!)))   ;; creates, joins, sets the mode, renders
      (amazon-show-detail! (list-current buf))
      (amazon-layout!)
      (group-layout-save! (amazon-home-group!))
      (switch-to-buffer! buf))))
```

## Verify

1. `(boundp 'NAME)` for every new public name, then `(apropos ...)` for its
   metadata.
2. Open the app. `(window-list-all)` shows three panes in ONE frame, and
   `(buffer-group BUF)` is the app group for the listing AND every detail.
3. Move down two rows, then `(buffer-list)`: one detail buffer per visited row,
   and `(detail-window "*amazon*")` is the same window id throughout.
4. Drive `` C-` `` through `KeyDispatch.handle_key/1` and confirm it walks
   those buffers rather than reporting one.
5. `q` on the listing takes the details with it. A detail kept with `M-RET`
   stays.
6. Narrow the frame below `window-layout-wide-cols`, run the layout again,
   confirm it stacks instead of columning.
7. Leave the group and come back: the layout is the one you left.
