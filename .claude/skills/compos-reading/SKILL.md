---
name: compos-reading
description: Read source in this repo the fast way — find structure before reading whole files, pull only the lines that answer the question, and check a live Scheme name against the daemon's own catalog before trusting a grep. Use before diving into an unfamiliar file, function, or Scheme API in compos.
---

# Reading compos

Treat every file as structured content, not a wall of text. Find the
boundary of what answers the question before reading past it.

## Elixir and everything else

Grep for the definition, then read a tight range around it — not the whole
file:

```sh
grep -n "def create_buffer" apps/compos_core/lib/compos/core.ex
sed -n '24,50p' apps/compos_core/lib/compos/core.ex
```

For history, use plumbing instead of walking `git log`:

```sh
git show HEAD:apps/compos_core/priv/editor.scm | sed -n '5000,5030p'
```

Batch independent reads — several unrelated `grep`/`sed` calls with no
dependency between them — in one message instead of one round trip each.

## Scheme is different: the file is not the only truth

A `.scm` file is `mix compile`-free — a save hot-reloads only the top-level
forms whose text changed, so a long-running daemon can hold a definition
that predates the file on disk, or a name that was wrapped after the fact
(`editor.scm` does this on purpose: `(define raw-buffer-create
buffer-create)` then a new `buffer-create` wraps it). grep answers what the
*file* says; it does not answer what the *daemon* is running.

When a live daemon is behaving differently from what the source implies,
ask it directly before building a theory on the file text:

```sh
bin/compos eval "(describe-function 'buffer-create)"   # the live source, verbatim
bin/compos eval "(apropos \"mark all\")"                # what already exists
bin/compos eval "(apropos-components \"list\")"         # UI components — read docs/COMPONENTS.md first
```

This is one command. Skipping it and reasoning from the file alone can burn
far more time chasing a mismatch that a single `describe-function` call
would have ruled out immediately.

Names carried over from Emacs Lisp habit — `get-buffer`, `set-buffer`,
`goto-char`, `point-max`, `insert`, `save-excursion`, `with-current-buffer`
— mostly do not exist here unless `apropos` lists them. Check before using
one; do not assume a name transfers.

## Search once

Run the most specific query first. Re-search only after a genuine miss — no
match, an unbound name, an arity error, the wrong file — never to
double-check a hit that already answered the question.

## Related

- `compos-research` — how much to look before acting, and when to stop.
- `compos-debug` — the full `bin/compos` toolkit (state, keys, log, bridge).
