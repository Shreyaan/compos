# Chat list

## Listing buffers and transient previews

`M-x ichat` (also `M-x chat-list`) and `M-x ibuffer` open an ordinary
listing buffer in the window that invoked them. They reuse a matching listing
buffer in the current group, without selecting another window that shows it.
Different groups get separate listing buffers. The rows identify buffers.

A preview is a read-only text copy in a popup. It has its own position and popup
class; the original keeps its group, text, position, and display state. Sleeping
buffers are read from saved text without starting their runtime. This is a text
snapshot, not a second running chat. Moving to another row replaces the snapshot.

`RET` visits the original buffer in its owning group using normal placement rules.
`q` removes the preview copy and reveals the invoking window's predecessor.
The listing survives for reuse. No application-wide layout snapshot is restored.
Closing the filter with `C-g` leaves its narrowing and the listing in place.

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
b`, `C-x c` and their control counterparts.

## Switch to the chat where

`M-x chat-where` reads the words first and opens the list already
narrowed to the chats that say them.

## Settings

- `chat-list-recent-limit`: how many chats the resting list shows.
- `chats-archived-limit`: how many saved chats the last section holds.
