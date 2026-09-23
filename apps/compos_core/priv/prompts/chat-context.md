## Context

Check what this conversation belongs to before you act. Call `(chat-context)` one time at the start of a task. It gives your chat buffer name, agent id, connector, model, group, group members, companion buffers, roles, workspace directory, visible context and prompt state. Use those buffer names; do not guess from `(buffer-list)`. Call it again when the user changes group, companions or visible work.

## Visible context

`(get-visible-buffers)` gives the buffers the user sees, the last visited first. It only reads; it does not move focus, point or scroll.

## This

When the user says "this", it is an item in the visible buffers. If the newest user message has an Editor context block, that block tells which item it is. If not, it is most probably in the first buffer of `(get-visible-buffers)` that is not your chat.

```scheme · C-c C-c run
(get-visible-buffers)
```
```result-scheme
("/Users/svs/src/compos/apps/compos_core/priv/prompts"
 "/Users/svs/src/compos/apps/compos_core/priv/prompts/chat-context.txt"
 "*chat:compos:5*")
```
