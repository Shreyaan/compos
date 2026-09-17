# Known failing tests

The tests that were red before the simplification work of 2026-09-18 and
2026-09-19, so a regression can be told from the weather. Each entry was
measured the same way: the test file as it stood before the change was run
against the code as it stood before the change, in the test env, and it
failed the same way after.

**This is evidence, not permission.** A test listed here is a defect nobody
has looked at, or a test that asserts a production key binding, which the
house rule forbids. Fix the defect or rewrite the test; do not extend the
list to make a run green.

## Elixir

| File | Red | Note |
|---|---|---|
| agent_test.exs | 36 of 52 | the `a1` slug and the fake-transport handshake; every ACP scenario after the first fails on `Agent.info("a1")` |
| chat_reset_test.exs, switch_test.exs, preset_test.exs | 17 | the transport never opens; same root as agent_test |
| backend_stub_test.exs | 2 | same root |
| chat_agent_test.exs | 2 | same root |
| transient_test.exs | 2 | the LLM menu no longer applies a saved combination |
| project_search_test.exs | 4 | group membership after project-switch and dired-in-group; the ripgrep hint carries an `M-1` prefix |
| llm_tools_test.exs | 3 | apropos output format; describe-function source; 22 tools where the test expects 10 (the tool zoo regrew, audit item 5.6) |
| write_file_test.exs | 1 | `C-n then RET` in the write prompt leaves the minibuffer |
| movie_test.exs, chosen_pane_test.exs, spotify_test.exs | 1 each | opt-in apps |
| chrome_test.exs | 1 | "returning from a page a buffer already on screen is selected" |
| load_test.exs | 0 | was red on calendar.scm, which init.scm never loaded; now expected |

## Scheme (priv/tests)

Run one file with `SCHEME_TESTS=name mix test apps/compos_core/test/compos/scheme_suite_test.exs`.

| Test | Note |
|---|---|
| a-mode-map-answers-for-the-buffer..., a-minor-mode-map-answers-ahead..., every-major-mode-key-leads-to-a-live-command, every-minor-mode-key-leads-to-a-live-command, a-list-mode-answers-to-its-own-map-under-list-mode-map, a-list-key-bar-defaults-to-the-keymap-component | the keymap ladder |
| fence-markers-step-back-with-other-preview-markup, a-link-keeps-its-text-and-hides-its-target, a-csv-block-draws-as-a-table | blocks |
| the-default-face-size-is-the-setting-and-survives-a-theme, a-dark-theme-shows-the-row-under-point | themes; red since the warm-dark theme commit |
| the-stance-is-set-in-one-place, the-modeline-names-the-tool-surface | llm-setup |
| unstamped-bundled-declarations-do-not-multiply, a-near-miss-on-a-name-lands-anyway, kind-package-namespace-domain-and-effect-filters-compose, components-use-the-main-catalog-and-expose-a-runnable-contract | apropos and the catalog |
| malformed-scheme-goes-nowhere, code-mode-asks-before-it-assigns-this-frame-a-worktree | code-mode |
| the-index-gives-each-thread-two-lines, every-tag-reads-in-full-until-the-column-narrows, notmuch-quit-kills-the-mail-views-and-lands-on-work, mark-all-then-archive-marked-asks-before-it-acts | notmuch |
| context-providers-explain-the-selection-to-chat-and-agents, subagents-table-draws-one-row-per-edge, overview-uses-only-the-current-group, tile-all-uses-only-the-current-project, telemetry-toggle-opens-the-popup-and-closes-it, telemetry-has-a-narrow-view-for-the-side-popup | one each |
| a-page-opens-in-the-frame-group-when-the-window-has-none-and-cycles-views | passes alone; fails when the feeds tests run first (test pollution) |
| membership-answers-the-id, modeline-memberships-follow-the-buffer, llm-config-session-is-the-groups-most-recent-chat, a-summary-is-always-a-string, applying-a-bundle-applies-all-of-it, a-bundle-remembers-disabled-prompt-sections | pass alone; fail after other files leave a group behind (test pollution) |

## Faster ways to ask

`mix test --failed` reruns what failed last time (`_build/test/lib/<app>/.mix/.mix_test_failures`).
`SCHEME_TIMES=1` on the Scheme bridge prints the slowest tests.
To attribute a failure: run the pre-change test file (`git show HEAD:path > test/compos/zz_old_x_test.exs`,
with the module renamed) against the pre-change code, and compare failure names, not counts.
