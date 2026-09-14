# Chat list

The chat list is an application, not a prompt and not a management table.

## The use case

You want to switch to a chat. You half remember its name. It is one of
the chats you used recently.

## One application, one state

There is one chat list. It has one state and one buffer, `*chat-list*`.
It is always in its own group. It never joins the group you came from,
and no other group adopts it.

`M-x chat-list` always arrives at that group and that layout. There are
no exceptions and no second copy.

## The layout

Two panes:

- the list, 2/3
- the preview, 1/3

## Behaviour

- The application takes the focus when you invoke it.
- The rows are the recent chats, most recently used first.
- You type to filter. The filter reads the title first and the state
  second.
- The filter searches every chat, not only the recent ones. The recent
  limit bounds the resting list, not the search.
- The row under the cursor shows its chat in the preview pane.
- Looking costs nothing. The preview shows the text of a sleeping chat
  and never starts its runtime. Only the chat that you pick wakes.
- RET switches to the chat. The application gives the focus back and
  leaves.
- C-g leaves and changes nothing.
- Leaving hands the whole frame back: the panes the application made go,
  and the window it stood in shows what it showed before.

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
