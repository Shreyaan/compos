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
| cache_economics_test.exs | 4 of 8 | the system prompt no longer names the other group buffers, the frozen tool list, the cancelled-turn ledger row; red at HEAD ba6d2c45 |
| permission_test.exs | 6 of 8 | same root: the `a1` chat never gets its agent, so every lane test stops at agent-prompt!; red at HEAD e08f34d4 |
| chat_agent_test.exs | 2 | same root |
| transient_test.exs | 2 | the LLM menu no longer applies a saved combination |
| project_search_test.exs | 4 | group membership after project-switch and dired-in-group; the ripgrep hint carries an `M-1` prefix |
| llm_tools_test.exs | 3 | apropos output format; describe-function source; 22 tools where the test expects 10 (the tool zoo regrew, audit item 5.6) |
| write_file_test.exs | 1 | `C-n then RET` in the write prompt leaves the minibuffer |
| movie_test.exs, chosen_pane_test.exs, spotify_test.exs | 1 each | opt-in apps |
| chrome_test.exs | 1 | "returning from a page a buffer already on screen is selected" |
| load_test.exs | 0 | was red on calendar.scm, which init.scm never loaded; now expected |
| compos_ui, 15 of 300 (preview_cursor 1, peek_card 2, app_server 1 (spreadsheet-open! unbound), agent_view 3, dismiss 2, composml_list 1, island 1, buffer_link 1, composml_text_list 1, editor_live 2 (the modeline name and minor-mode clicks)) | 15 | the same 15 names at 47735078 in a worktree with its own build, before the live-dashboard removal of 2026-09-19; sentry--apply-detail! unbound in two of them |
| compos_ui agent_view_test.exs | 3 of 13 | the verbosity control, the text-scale rule and the modeline name markup; red at HEAD 53f4b07b |
| desktop_restore_test.exs | 2 | "every literal mode-name write names a registered mode": ibuffer-test.scm writes `aa-other-mode` (d293b2d9) and no define-mode registers it; "LLM configuration history survives desktop restore": the history rows are plists now, the test expects bare lists |

## Scheme (priv/tests)

Run one file with `SCHEME_TESTS=name mix test apps/compos_core/test/compos/scheme_suite_test.exs`.

| Test | Note |
|---|---|
| a-mode-map-answers-for-the-buffer..., a-minor-mode-map-answers-ahead..., every-major-mode-key-leads-to-a-live-command, every-minor-mode-key-leads-to-a-live-command, a-list-mode-answers-to-its-own-map-under-list-mode-map, a-list-key-bar-defaults-to-the-keymap-component | the keymap ladder |
| fence-markers-step-back-with-other-preview-markup, a-link-keeps-its-text-and-hides-its-target, a-csv-block-draws-as-a-table | blocks |
| the-default-face-size-is-the-setting-and-survives-a-theme, a-dark-theme-shows-the-row-under-point | themes; red since the warm-dark theme commit |
| the-stance-is-set-in-one-place, the-modeline-names-the-tool-surface | llm-setup |
| unstamped-bundled-declarations-do-not-multiply, a-near-miss-on-a-name-lands-anyway, kind-package-namespace-domain-and-effect-filters-compose, components-use-the-main-catalog-and-expose-a-runnable-contract, apropos-finds-the-endpoint-api-by-what-it-is-for, apropos-finds-the-database-api-by-what-it-is-for, searching-for-a-socket-reaches-the-client-api-not-the-listener-list | apropos and the catalog; the last three were red at HEAD b5302dd4 in a worktree run |
| malformed-scheme-goes-nowhere, code-mode-asks-before-it-assigns-this-frame-a-worktree | code-mode |
| the-index-gives-each-thread-two-lines, every-tag-reads-in-full-until-the-column-narrows, notmuch-quit-kills-the-mail-views-and-lands-on-work, mark-all-then-archive-marked-asks-before-it-acts | notmuch |
| context-providers-explain-the-selection-to-chat-and-agents, subagents-table-draws-one-row-per-edge, overview-uses-only-the-current-group, tile-all-uses-only-the-current-project, telemetry-toggle-opens-the-popup-and-closes-it, telemetry-has-a-narrow-view-for-the-side-popup | one each |
| every-mode-says-what-it-is-for | six modes call no mode-doc!: google-compose-mode, google-detail-mode, google-request-mode, irc-mode, special-mode, and the keymap-test-list-mode fixture; red at HEAD before the mode table (b5302dd4) |
| a-pasted-images-link-is-relative-to-the-document | the test home is not a git repository; the git rev-parse error list reaches string-append |
| the-editor-seams-are-named-hooks | buffer-created! on a name with no buffer process; red at HEAD b5302dd4 |
| training-points-at-the-real-curriculum, training-curriculum-has-working-tour-anchors | docs/training.md left in the docs sweep (cd4575aa); the opt-in app still points at it |
| ibuffer-act-add-here-keeps-the-old-membership, ibuffer-act-reads-the-marks, ibuffer-quit-takes-the-preview-then-the-table, ibuffer-sections-by-mode, ibuffer-toggle-mark-marks-then-unmarks, ibuffer-visit-enters-the-group-of-the-row, ibuffer-visit-keeps-the-row-in-the-window-that-previewed-it, ibuffer-visit-stays-put-for-a-buffer-of-this-group, ibuffer-window-form-previews-the-row-in-another-window, the-buffer-prompt-is-the-table-under-a-filter-line, the-prompt-cycles-what-a-section-is, the-prompt-folds-the-section-at-hand, the-prompt-jumps-section-to-section, the-prompt-popup-wears-no-chrome, typing-narrows-the-table-and-arrows-move-its-highlight | ibuffer and its prompt; red at HEAD b5302dd4 in a worktree run, while the listing preview (fc980588) is under work in another session |
| keeping-a-detail-frees-the-name-for-the-next-row, the-detail-destination-moves-with-its-window | detail; red at HEAD b5302dd4 |
| irc-slash-commands, chat-tool-list-groups-the-tools-under-the-server-that-serves-them, ts-lang-resolves-through-the-registry, a-blocks-presence-arms-its-keys, a-scheme-result-pretty-prints-nested-property-lists, document-links-resolve-beside-the-source-document | one each; red at HEAD b5302dd4 (the grammar ones: the test home has no grammars) |
| ibuffer-puts-the-frames-group-first | `ibuffer-promote-group` is unbound: the ibuffer sections rewrite (8a6877bd) removed it and window-config-test.scm still calls it |
| a-broadened-switcher-lists-every-buffer-under-two-headings, a-group-no-frame-owns-is-adopted-by-the-frame-that-enters-it, a-heading-takes-no-selection-and-no-count, a-refresh-keeps-a-non-selected-window-on-its-row, a-switch-to-a-foreign-buffer-takes-a-window-and-the-frame-stays-in-its-group, a-switch-to-a-member-takes-the-selected-window, active-target-persists-without-a-group-switch, an-agents-edit-keeps-a-peeked-file, another-frames-group-stays-out-of-this-frames-lists, autolayout-mode-re-arranges-when-a-window-comes, background-buffer-context-does-not-grow-a-target-layout, confirm-floats-a-buffer-of-another-group-and-the-frame-stays, explicit-main-selection-replaces-the-previous-target, fixed-target-underfills-and-grows-without-placeholder-panes, foreign-popup-does-not-enter-target-relayout, group-switch-restores-its-own-target, ibuffer-puts-the-frames-group-first, killing-a-visible-group-buffer-never-shows-a-foreign-buffer, overview-locks-the-frame-and-quit-restores, switching-context-removes-foreign-panes-from-a-saved-layout, switching-to-an-ungrouped-buffer-floats-it-and-keeps-the-frame-group, target-candidates-exclude-foreign-transient-and-background-only-buffers, target-reflows-after-pane-close-without-reopening-hidden-work, the-modal-switcher-lists-the-same-sections-as-the-prompt, three-columns-outside-a-group-fill-from-the-buffer-mru | layouts and target layouts, red at HEAD 73c34f57 in a worktree run while the other session works on layouts |
| agent-excision-repairs-every-transcript-offset, agent-excision-counts-bytes-after-multibyte-text | agent-excise-range! no longer moves 'agent-saved-mark by hand (the buffer keeps the marker); the test still expects the hand-moved value; red at HEAD 4f0a0be9 in a worktree run |
| a-target-layout-still-gives-the-detail-a-window, layout-target-starts-with-one-buffer-and-grows-in-order | layout targets; red at 4e14e5f2 in a worktree with its own build, before the winner and layout-prompt changes of 2026-09-19 (detail-test 3 red alone, layout-policy-test 9 red alone) |
| relayout-preserves-pane-order-and-focus, fixed-target-fills-vacancies-then-replaces-the-selected-slot, group-refill-uses-hidden-members-before-chat-and-keeps-geometry, smaller-target-keeps-focus-and-the-first-surviving-slots, passive-results-replace-the-oldest-other-pane-and-quit-restores-it, selected-result-quit-restores-the-buffer-under-it, main-left-target-keeps-its-main-and-stack-order-as-work-opens, a-group-chat-joins-the-frame-instead-of-collapsing-it, a-group-chat-arranges-by-the-frames-chosen-layout, a-floating-surface-does-not-change-the-frame-group | red only when the six layout files run in one lane (SCHEME_TESTS=layout-policy,group-switch,autolayout,window-config,detail,ibuffer); each passes with its file alone: order pollution |
| a-written-chat-keeps-the-written-directory | the chat-writes-chat-files rule refuses the .txt the test writes; red at HEAD a2bd2538 |
| the-chat-list-is-one-application | `list-key-lines` is unbound: the test came in fc980588 with no definition anywhere |
| the-companion-chat-opens-into-the-documents-group | red alone at HEAD 3ffe7c4a in a worktree run |
| disabling-writing-mode-restores-the-previous-look | passes with a clean test home; llm_tools_test.exs saves `(org-font-family "ToolFont")` into the test home custom.scm and leaves it, and org then opens in ToolFont |
| a-page-opens-in-the-frame-group-when-the-window-has-none-and-cycles-views | passes alone; fails when the feeds tests run first (test pollution) |
| membership-answers-the-id, modeline-memberships-follow-the-buffer, llm-config-session-is-the-groups-most-recent-chat, a-summary-is-always-a-string, applying-a-bundle-applies-all-of-it, a-bundle-remembers-disabled-prompt-sections | pass alone; fail after other files leave a group behind (test pollution) |

## Faster ways to ask

`mix test --failed` reruns what failed last time (`_build/test/lib/<app>/.mix/.mix_test_failures`).
`SCHEME_TIMES=1` on the Scheme bridge prints the slowest tests.
To attribute a failure: run the pre-change test file (`git show HEAD:path > test/compos/zz_old_x_test.exs`,
with the module renamed) against the pre-change code, and compare failure names, not counts.
