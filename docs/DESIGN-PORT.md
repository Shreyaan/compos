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
   from the frame's, title, state dot, rule, cua/focus tag, one switcher.
   Mode line = state: dot, name, mode/llm/lane facts ranked, rule, position.
   The three verbosity icons become one switcher that opens a narrow.
   A window at rest keeps both bars and steps its ink down; it does not
   hide its facts.
3. **Three window states.** At rest: kept down. Current cua: sits (paper,
   hairline, shallow shadow). Current focus: floats (lifted ground, deep
   shadow). The inset group-colour ring goes.
4. **Keys bar.** Every list-mode buffer carries `c-keys-bar` at its bottom
   corner: facts, the main keys, `? all N`. `?` grows it into the full
   `c-keys` grids. Scheme derives it from the mode keymap.
5. **Narrow at full size.** Ibuffer is the minibuffer grown to full, with
   the selected buffer previewed beside the list as a window at rest. No
   centred modal.
6. **Focus/cua move.** A focus window trades places with its neighbour by
   direction; a cua window refuses through the echo area.

## Open questions

- The echo area's key hints are a static list in `editor_live.ex`. They
  should come from Scheme (which-key is the model). Stage 2 or later.
- `load-theme` stays as an M-x command. The brief says one theme; the other
  themes remain loadable by name.
