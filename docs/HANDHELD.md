# The handheld client

The handheld client is the editor on a phone. Open `/m` on the daemon. A
buffer link for a phone is `/m/b/NAME`, with the same `?line=N` query as a
desktop link.

The client is a second client of the same frame payload the desktop draws.
It attaches a frame, reads `Compos.Core.Editor.render_state/1`, and sends
every gesture as the same `key` event the desktop sends. No editor logic
lives in the client. The policy lives in
`apps/compos_core/priv/packages/handheld.scm`.

## The screen

- **The modeline.** One line: the flags, the buffer name, the mode, the
  buffer's modeline info, and the pending prefix as a badge. A tap runs
  `modeline-expand`.
- **The window.** The frame's selected window. A chat buffer shows the
  agent transcript. A file buffer shows its lines, read-only. A rendered
  document shows its preview.
- **The rail.** A drag along the left edge moves point by line. Scheme
  moves point with `handheld-scrub!`. The rail is not shown for a chat.
- **The composer.** One field with three registers. A literal chord, such
  as `C-x b`, dispatches its keys. `M-x NAME` runs the command. Any other
  text goes to the group's chat as a message. `handheld-compose!` decides.
  While a prompt is open, the field feeds the prompt one key at a time.
- **The chips.** Three commands above the field. Each chip shows the key
  bound to its command, or `M-x NAME` when nothing binds it. A tap sends
  the chord through the composer. `handheld-chips` names them.
- **The tab rail.** The current group's buffers in MRU order. A tap
  switches the window to that buffer. `handheld-tabs` builds the rows.
- **The chord key.** Hold it and the fan opens on the prefixes in
  `handheld-prefixes`. Slide onto a prefix and its bindings appear: they
  are the frame's own which-key rows. Release over a row to run it.
  A tap latches, so hold-and-slide and tap-tap-tap reach the same command.
  The fan shows `handheld-fan-limit` rows and a "more" row for the rest.
- **The sheets.** An active minibuffer renders as a sheet of rows. A tap
  on a row selects it and accepts. An active transient renders as a sheet
  of key boxes; a tap sends the key. Every prompt and every transient
  gets this for free.

## Files

- `apps/compos_ui/lib/compos/ui/mobile_live.ex` — the LiveView.
- `apps/compos_ui/lib/compos/ui/mobile_layouts.ex` — the root layout: the
  stylesheet and the `Handheld` hook.
- `apps/compos_core/priv/packages/handheld.scm` — the policy.
- `apps/compos_core/priv/tests/handheld-test.scm` — the policy tests.
- `apps/compos_ui/test/compos/ui/mobile_live_test.exs` — the view tests.

## Customs

- `handheld-prefixes` — the `(KEY LABEL)` rows on the fan's first level.
- `handheld-fan-limit` — how many rows the fan shows under a prefix.

## Not built yet

- Answers do not report the chord they ran. The design's "pin to fan"
  receipt needs the agent to name the command it used.
- A left-handed placement of the chord key.
- Editing text in a file buffer. The handheld client reads files and
  talks to the chat; it does not edit prose.
