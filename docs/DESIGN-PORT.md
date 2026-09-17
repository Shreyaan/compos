# Design port: Compos v2 into the app

The design system lives in the Claude Design project `efed2c88` (readme.md,
styles.css, elements/*.css, elements/compos.js, Compos v2.html, Ibuffer
v2.html). The brief: four concepts (group, window, focus/cua, narrow), one
theme, no modals, no drag, no toolbars. This file tracks the port, stage by
stage. Each stage is one commit, verified live and by a screenshot.

## Already in the app before this port

- The token layer in `layouts.ex` (surfaces, text, edge, accent, scale,
  space) resolves through the faces a theme owns. Radii are 0.
- Fonts: IBM Plex Mono for chrome, Spectral for prose, Plex Sans outside.
- `paper` (light) and `paper-night` (dark) themes exist in `themes.scm`.
- The frame has a header line (wordmark, group tabs, facts) and an echo
  area. A window has a header line (dashboard line, built in Scheme) and a
  mode line.
- The minibuffer reads prompts as tables (`ibuffer-prompt!`).

## Stages

1. **Palette and frame chrome.** `paper-night` carries the design's exact
   dark tokens and boots by default. The header line is wordmark, divider,
   group tabs (tracked uppercase), rule, facts. The theme word and the
   file path leave the header line. The key hints move to the echo area
   after the message and a rule. DONE.
2. **Window bars.** Header line = identity: pin only when the group differs
   from the frame's (`modeline_pin` in editor.ex sets `data-pin`), title,
   the open change, the cua/focus tag, one switcher (`ⓘ`, M-x
   `buffer-switcher`: a narrow over buffer info, summary log, transcript
   verbosity). Mode line = state: dot, name, context, mode/llm/lane facts
   (`dash--modeline-facts`, the `modeline-facts` local, ranked so the lane
   sheds first), position. A window at rest keeps both bars whole and
   steps its ink down. DONE.
3. **Three window states.** At rest: kept down (`.window.inactive` remaps
   the text and surface tokens). Current cua: sits (paper, hairline, the
   theme's `chrome shadow`). Current focus: floats (lifted ground, nearer
   hairline, `chrome shadow-deep`). The inset group-colour ring is gone.
   A window is now a container, so its bars shed facts by its own width.
   DONE.
4. **Keys bar.** Every list-mode buffer carries `c-keys-bar` at its bottom
   corner: facts, the main keys, `? all N`. `?` grows it into the full
   `c-keys` grids. Scheme derives it from the mode keymap.
5. **Narrow at full size.** Ibuffer is the minibuffer grown to full, with
   the selected buffer previewed beside the list as a window at rest. No
   centred modal.
6. **Focus/cua move.** A focus window trades places with its neighbour by
   direction; a cua window refuses through the echo area.

## Open questions

- Mode glyphs come from a Nerd Font (`mode-icons`). The brief says Unicode
  glyphs only, derived from the mode: `λ` code, `◍` chat, `✉` mail. A
  later stage swaps the registry.
- Two `editor_live_test.exs` tests assert the old `phx-value-cmd="mode:..."`
  click on the expanded panel; the panel moved to `block_click` with
  `dash-mode:` before this port. They fail at HEAD too.

- The echo area's key hints are a static list in `editor_live.ex`. They
  should come from Scheme (which-key is the model). Stage 2 or later.
- `load-theme` stays as an M-x command. The brief says one theme; the other
  themes remain loadable by name.
