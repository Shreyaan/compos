# Chat list

## Two surfaces, one table

`C-x c` is the minibuffer form — a popup under the work with its filter
line already open, its own view buffer ` *chats*`, and nothing kept
after the pick. It is the surface for "switch to that chat, the one
whose name I half remember". `C-x b` is the same form over the buffers.

`C-x C-c` (also `M-x chat-list`) opens the list in a window. It owns the
verbs, the grouping and the folds; the minibuffer form borrows none of
that state, so the sort and folds you set in one stay where you left them.

The window form is one list per group, the way `ibuffer` is: it opens in
the group you called it from and stays there, and different groups get
separate `*chat-list*` buffers. A single list in a group of its own was
tried and reverted — arriving had to cross groups, which dragged the
frame through that group's whole layout.

## One window, a floating card, and the frame comes back

The window form takes one window — the one you called it from — and
previews with the same floating card `ibuffer` floats. One preview
surface for both listings.

A two-pane form was tried and reverted. Covering the frame with a 2/3
list and a 1/3 chat pane meant a chat from one group and a buffer from
another stood side by side in one viewport, and a pane of the list's own
left no neighbour for a card to lie over. It also made previewing move
the frame: the frame derives its group from what it shows, so a pane
holding a chat from elsewhere walked the frame group to group, and one
list per group then answered with a different list than the one on
screen. A card is a copy, never the chat itself in a window, so it moves
no group and the list needs no pin.

Row movement floats the card. A heading is not a chat and an archived row
is a path rather than a buffer, so both leave the card showing what it
last held instead of blanking it. Arriving never lands on a heading:
grouping by group puts one first, so arrival falls through to the first
real row, which is what gives you a preview immediately.

Taking a window is only fair if the frame comes back. The arrangement the
list found is recorded on arrival and restored when the list leaves — by
`q`, and by `RET` too, so the chat you pick lands in the arrangement you
were working in.

The minibuffer form keeps its own preview: it reads the chat into the
window it was invoked from, the way `C-x b` does.

## Listing buffers and floating peek cards

`M-x ibuffer` opens an ordinary listing buffer in the window that invoked
it, reusing a matching one in the current group without selecting another
window that shows it. Different groups get separate listing buffers. The
rows identify buffers. Both window listings — ibuffer and the chat list —
preview with the card described below. Only the minibuffer forms do not:
they read the real buffer into the window they were invoked from, the way
`C-x b` does.

A card lies **over a neighbouring window**, and the list keeps its own
window whole. It used to split the list's own window to make room, which
with anything beside the list squeezed the list to a third and left the
card in a sliver between the two panes. The tree the card covered is
saved on the card buffer, so dismissing it puts the neighbour back
exactly. Alone in the frame the list has no neighbour to cover, and the
card takes a split of its own — the only way to show one at all.

Row navigation shows a **Preview** card after a short pause. The card is inset
from the window borders, raised with a soft shadow, and connected by a line
to the source row. It is a read-only presentation copy in the source mode, with rich chat and block
rendering. It does not copy the source's chat runtime. The card is nearly pane
sized and uses normal text size; changing groups in the list does not resize it.

The body starts at the bottom and scrolls with the mouse wheel or trackpad.
Its content cannot take focus, edit, or activate links. The card's control is
`q` to dismiss. Focus stays in the source list. The first `q` closes
the card; a second `q` leaves the list. Dismissing a card suppresses it for that
row until selection changes. `RET` in the source list opens the real buffer.
Closing a picker removes its card too. `C-x o` or `Cmd-RET` while peeking
opens the original buffer in another work window. Showing a peek never animates
the listing. `RET` opens in the selected pane, moving the mode's window there
when necessary; `q` returns to the same-group listing.
In both ibuffer and ichat, `C-x n n` narrows to the group heading at point
or the group containing the selected row. `C-x n w` shows all groups again,
keeping the `/` query. Group scope survives refresh and folding; changing
the grouping clears it. The header names the narrowed group.

## Keyword search

The name filter is not always enough. You remember a word that somebody
said in the chat, not the name of the chat.

A keyword search reads the text of every alive chat. Alive means every
chat that is not archived, awake or asleep. A sleeping chat answers from
its log file, so the search wakes nothing.

The rows narrow to the chats that hold the word, and each row shows the
line that matched.

## The verbs

The chat list is the only list of chats, so the things you do to a chat
are done here. A verb acts on the chat at point and leaves the list
standing. There are no marks and no flag-then-run: that is a table's
idea, not an application's.

- `s` steers it
- `y` and `d` answer the permission it waits on
- `r` gives it a title
- `k` stops its runtime and keeps the transcript
- `a` archives it: the runtime stops, the buffer goes, the file stays
- `g` draws the list again
- `+` starts a new chat

## The list is still

Nothing draws the list behind you. A streaming turn fires events many
times a second, and a list that redrew on them would re-sort its rows
and carry the cursor off the chat you were reading. So no event draws
it: the modeline carries the news of a chat that needs you, and `g`
draws the list again when you ask. The table's stamp is off here for
the same reason: a table redraws when the buffer count moves, so a file
opened by a chat you are not even reading rebuilt this list under the
cursor. A draw keeps the row you were on --
it finds that chat again wherever the new order puts it. Closing the
filter is not a move either: the rows widen back under the same cursor.

## The saved chats

The last section holds the newest saved conversations. A chat you
archived is still a chat you switch to, so RET on one reads its file back
and revives it, where you stood when you asked for it.
`chats-archived-limit` bounds that section.

## Grouping

`;` cycles what a section is. `none` is the flat list in most recently
used order, and it is the default.

- none (MRU)
- group
- state
- model

The grouping is part of the one state.

## A switch is a switch of group

A buffer switch changes the group. You go to where the buffer lives, and
the buffer does not come to where you are. This is the default for `C-x
b`, `C-x c` and their control counterparts. A pick from either chat
surface enters the chat's group. The list itself does not move: it opens
where you called it.

## Switch to the chat where

`M-x chat-where` reads the words first and opens the list already
narrowed to the chats that say them.

## Settings

- `chat-list-recent-limit`: how many chats the resting list shows.
- `chats-archived-limit`: how many saved chats the last section holds.
