
>>> you: C-u. the most important key. write a doc.

later you understand that there's always two equally correct ways to do something. Buffer left or window left? open in this group or new group? you see. that's where C-u comes in. it flips the toggle.


▸ other · ToolSearch
select:mcp__compos__eval-scheme,mcp__compos__apropos,mcp__compos__describe-function,mcp__compos__read-file

Tool: mcp__compos__eval-schemeTool: mcp__compos__aproposTool: mcp__compos__describe-functionTool: mcp__compos__read-file
▸ other · compos:eval-scheme
(chat-context)


▸ other · compos:apropos
universal argument prefix arg C-u

(chat "Using C-u to toggle document visibility" agent "chat-1789421975-291" connector "claude-code" model "opus[1m]" group "grp:1789069461:189" group-name "WINDOWS" group-members ("*chat:WINDOWS*" "Using C-u to toggle document visibility") companions () roles () directory "/Users/svs/" visible-context "" prompt prospective)((kind "command" name "universal-argument" doc "Start or multiply the next command's prefix argument" key "C-u" package "editor" namespace "core" domain "interaction" effects ("write") use "(run-command \"universal-argument\")"))
▸ other · compos:eval-scheme
(let ((root (git-root (default-directory)))) (list root (length (project-search-matches root "prefix-arg"))))


▸ other · compos:describe-function
universal-argument

error: no project: #fM-x command:
(lambda () (run-hooks (quote universal-argument-hook)) (let ((raw (current-prefix-arg))) (set-prefix-arg! (cond ((number? raw) (list (* raw 4))) ((and (pair? raw) (number? (car raw))) (list (* (car raw) 4))) ((equal? raw (quote -)) (list -4)) (else (list 4))))))
▸ other · compos:apropos
prefix argument current-prefix-arg


▸ other · compos:eval-scheme
(list (compos-root) (default-directory))

(public ((kind "command" name "negative-argument" doc "Negate the next command's prefix argument" key "M--" package "editor" namespace "core" domain "interaction" effects ("write") use "(run-command \"negative-argument\")") (kind "command" name "universal-argument" doc "Start or multiply the next command's prefix argument" key "C-u" package "editor" namespace "core" domain "interaction" effects ("write") use "(run-command \"universal-argument\")") (kind "function" name "define-prefix-command" sig "(define-prefix-command NAME)" doc "a keymap a prefix key leads to" domain "commands" package "editor" namespace "core" effects ("unknown")) (kind "command" name "digit-argument" doc "Add a digit to the next command's prefix argument" key "M-0" package "editor" namespace "core" domain "interaction" effects ("write") use "(run-command \"digit-argument\")") (kind "function" name "bind-prefix!" sig "(bind-prefix! MAP KEYS NAME)" doc "in MAP (\"global\" for the global map), KEYS leads to the keymap NAME" domain "commands" package "editor" namespace "core" effects ("unknown")) (kind "function" name "ibuffer-scope!" sig "(ibuffer-scope! NAME THUNK)" doc "register a named scope; a view's 'ibuffer-scope local names it" domain "buffers" package "ibuffer" effects ("read")) (kind "function" name "project-current" sig "(project-current)" doc "Root of the current project, #f when outside one" domain "project" package "project" effects ("write" "execute")) (kind "variable" name "graphql-apropos-limit" doc "The most schema lines one graphql-apropos prints." package "graphql" domain "graphql" effects ("write") use "(customize-save! 'graphql-apropos-limit VALUE)") (kind "function" name "graphql-schema-detail" sig "(graphql-schema-detail 'NAME)" doc "how much of the schema the server allowed: full, no-args, shallow or names" domain "graphql" package "graphql" effects ("read" "external")) (kind "command" name "buffer-log" doc "Show the provenance of this buffer: every accepted revision" key "C-x v l" package "provenance" domain "buffers" effects ("read") use "(run-command \"buffer-log\")") (kind "function" name "buffer-provenance-stop!" sig "(buffer-provenance-stop! NAME [ACTOR REASON POLICY])" doc "stop without deleting history" domain "buffers" package "editor" namespace "core" effects ("write")) (kind "function" name "overview-buffers" sig "(overview-buffers)" doc "current group members, else current project buffers" domain "windows" package "layouts" effects ("read")) (kind "function" name "notmuch" sig "(notmuch ARGS)" doc "the raw notmuch CLI, ARGS is everything after `notmuch` as one string, e.g. \"tag -inbox -- from:luma.com\" or \"count -- tag:inbox from:luma.com\"; prefer this for bulk ops by query (archive/tag many at once) and for verifying a change actually happened, instead of enumerating thread ids one at a time" domain "mail" package "notmuch" effects ("unknown")) (kind "function" name "project-buffers" sig "(project-buffers ROOT)" doc "names of every buffer whose directory is inside ROOT" domain "project" package "project" effects ("read")) (kind "function" name "apropos" sig "(apropos QUERY &rest FILTERS)" doc "hybrid literal/semantic catalog search; accepts kind/package/namespace/domain/effect filters, and 'lexical #t for the catalog alone (no embedding call). The public call shape is unchanged." domain "discovery" package "tools" effects ("read" "external" "spend")) (kind "command" name "transient-history-prev" doc "Use the previous infix value set" key #f package "transient" domain "interaction" effects ("write") use "(run-command \"transient-history-prev\")") (kind "function" name "project-scratch-name" sig "(project-scratch-name ROOT)" doc "the name of that project's scratch buffer" domain "buffers" package "scratch" effects ("pure")) (kind "command" name "org-promote-subtree" doc "Promote the entire subtree at point" key #f package "org" domain "unknown" effects ("unknown") use "(run-command \"org-promote-subtree\")") (kind "function" name "project-group-target" sig "(project-group-target ROOT)" doc "the first rule's group name, group ID, or #f" domain "project" package "project" effects ("read")) (kind "function" name "buffer-substring" sig "(buffer-substring START END)" doc "of the current buffer" domain "editing" package "editor" namespace "core" effects ("unknown")) (kind "function" name "buffer-log-target" sig "(buffer-log-target)" doc "the buffer *buffer-log* shows, or #f" domain "buffers" package "provenance" effects ("read")) (kind "function" name "buffer-context-only?" sig "(buffer-context-only? NAME)" doc "#t when NAME belongs to context but stays out of user buffer lists" domain "chat" package "groups" effects ("read")) (kind "command" name "previous-history-element" doc "Put the previous history item in the minibuffer" key #f package "editor" namespace "core" domain "unknown" effects ("unknown") use "(run-command \"previous-history-element\")") (kind "function" name "minibuffer-active?" sig "(minibuffer-active?)" doc "#t while a prompt is up" domain "commands" package "editor" namespace "core" effects ("unknown"))) globals ((kind "internal" name "current-prefix-arg" doc "(current-prefix-arg) — return this frame's raw one-shot prefix argument, or #f." catalog-status "uncatalogued" note "This global has no catalog declaration. Inspect its defining source. If you use it, add a durable declaration with explicit domain and effects.")))error: unbound variable: compos-root
No close public-api match — search with (apropos "words") before retrying.
▸ other · compos:eval-scheme
(list (buffer-list) (getenv "COMPOS_ROOT"))

((" *minibuf-f-tgfe72q*" "Chat-list behavior and transient presence" "*amazon:B0GJLXNPZS*" "*amazon:B08WJ89RGD*" "*linkedin:msg:YzZjYzk0YWUt*" "/Users/svs/src/compos/docs" "*linkedin:msg:ZThkMDNlY2Mt*" "/Users/svs/src/compos/apps/compos_core/priv/editor/blocks/diff-block.scm" "/Users/svs/src/compos/apps/compos_ui/lib/compos/ui/editor_live.ex" "Requirements for Diff mode" "*amazon:B097Q8T2FD*" "*amazon:B0GX5BTKWB*" "/Users/svs/src/compos/apps/compos_core/priv/tests/ibuffer-test.scm" "*git show: d8dc388*" "/Users/svs/src/compos/docs/LISTS.md" "*git show: beb4b61*" "*amazon:B0GJLXRPK4*" "*amazon:B0BSN1QFXX*" "*amazon:B00AXHBBXU*" "*amazon:B00DZYEXPQ*" "*amazon:B0DKPGQT97*" "/Users/svs/src/compos/apps/compos_core/priv/editor.scm" "/Users/svs/src/compos/apps/compos_core/lib/compos/core/git.ex" "Using C-u to toggle document visibility" "/Users/svs/src/compos/apps/compos_core/priv/tests/linkedin-test.scm" "*Messages*" "/Users/svs/src/compos/apps/compos_core/priv/packages/morg-kinds.scm" "*amazon:B01L21ICV4*" "/Users/svs/src/compos/apps/compos_core/lib/compos/core/ts.ex" "*amazon-log*" "*amazon:B0CR3NWXW7*" "Need for a base component for" "*linkedin*" "/Users/svs/src/compos/apps/compos_core/native/compos_ts/src/lib.rs" "*chat-list*" "*Google svs@svsrecruiting.com [115927348091722650529] / docs*" "*amazon:B0H51WVNKX*" "*linkedin:1411635218*" "/Users/svs/src/compos/apps/compos_core/priv/packages/notmuch.scm" "*linkedin:1658444122*" "/Users/svs/src/compos/apps/compos_core/priv/packages/diff-mode.scm" "LinkedIn app creator skill tutorial" "*amazon:B0H9R6RLT4*" "*zz-probe*" "/Users/svs/src/compos/apps/compos_core/priv/packages/amazon.scm" "*amazon:B0C1GY4Q2N*" "/Users/svs/src/compos/apps/compos_core/priv/packages/groups.scm" "*linkedin:1687189266*" "*amazon:B07QNPBJ74*" "/Users/svs/src/compos/apps/compos_core/priv/prompts/quiet-editor.txt" "*amazon:B082QMPCW5*" "Using Design to implement UI groupings" "/Users/svs/src/compos/apps/compos_core/priv/packages/agent-fleet.scm" "chat dismiss" "*amazon:B082P6TTMP*" "/Users/svs/src/compos" "/Users/svs/src/compos/apps/compos_core/test/compos/git_diff_test.exs" "*amazon:B0FLB2HD92*" "*amazon:B0FL26LZ74*" "*amazon*" "Implementing autocomplete in code editing buffers" "Opening Amazon window config" "*amazon:B08ZL1G72C*" "*amazon:B08WHJFYM8*" "*amazon:B0D4XZXLL7*" "/Users/svs/src/compos/apps/compos_core/priv/packages/ibuffer.scm" "/Users/svs/src/compos/apps/compos_core/priv/packages/git.scm" "/Users/svs/src/compos/apps/compos_core/lib/compos/core/scheme_api.ex" " *minibuf-f-bn42rxy*" "*amazon:B0B8ZMCYYB*" "*switch*" "*amazon:B01IBRHE3E*" "*linkedin:msg:NzZjZDg3OTYt*" "Frame local groups" "/Users/svs/src/compos/docs/PROMPTS.md" "*amazon:B00004YRPE*" "/Users/svs/src/compos/apps/compos_core/native/compos_ts/Cargo.toml" "Buffer window placement and group settings" "/Users/svs/src/compos/apps/compos_core/priv/packages/layouts.scm" "/Users/svs/src/compos/apps/compos_core/test/compos/ibuffer_test.exs" "/Users/svs/src/compos/apps/compos_core/priv/packages/morg/morg-kinds.scm" "/Users/svs/src/compos/apps/compos_core/priv/packages/treesit.scm" "Chat ibuffer updates and mru visibility" "/Users/svs/src/compos/apps/compos_core/priv/packages/diff-block.scm" "*chat:compos*" "*amazon:B07P96DJR3*" "*scratch:*amazon**" "/Users/svs/src/compos/.gitignore" "*ibuffer*" "*amazon:B0BLVCFK8D*" "*linkedin:1923656034*" "*annotations*" "*amazon:B0CVCG2VPK*" "*scratch:CONFIG*" "*scratch:compos*" "*amazon:B0CTH43FNC*" "/Users/svs/src/compos/apps/compos_core/priv/tests/morg-kinds-test.scm" "*zz-annotate*" "*chat:GROUPS:2*" "/Users/svs/src/compos/apps/compos_core/priv/packages/linkedin.scm" "*scratch*" "/Users/svs/src/compos/CLAUDE.md") #f)
▸ other · compos:eval-scheme
(let ((root "/Users/svs/src/compos")) (project-search-matches root "current-prefix-arg"))


▸ other · compos:eval-scheme
(shell-command->string "ls docs" "/Users/svs/src/compos")

(("apps/compos_core/lib/compos/core/scheme_api.ex:800" "apps/compos_core/lib/compos/core/scheme_api.ex" 800 "\"current-prefix-arg\" =>") ("apps/compos_core/lib/compos/core/scheme_api.ex:801" "apps/compos_core/lib/compos/core/scheme_api.ex" 801 "\"(current-prefix-arg) — return this frame's raw one-shot prefix argument, or #f.\",") ("apps/compos_core/lib/compos/core/scheme_api.ex:2389" "apps/compos_core/lib/compos/core/scheme_api.ex" 2389 "\"current-prefix-arg\" => fn [] -> Editor.prefix_arg() || false end,") ("apps/compos_core/priv/editor.scm:219" "apps/compos_core/priv/editor.scm" 219 "(cond ((equal? code 'p) (k (prefix-numeric-value (current-prefix-arg))))") ("apps/compos_core/priv/editor.scm:220" "apps/compos_core/priv/editor.scm" 220 "((equal? code 'P) (k (current-prefix-arg)))") ("apps/compos_core/priv/editor.scm:6755" "apps/compos_core/priv/editor.scm" 6755 "(if (current-prefix-arg)") ("apps/compos_core/priv/editor.scm:9306" "apps/compos_core/priv/editor.scm" 9306 "(if (current-prefix-arg)") ("apps/compos_core/priv/editor.scm:12827" "apps/compos_core/priv/editor.scm" 12827 "(let ((prefix (current-prefix-arg)))") ("apps/compos_core/priv/editor.scm:13039" "apps/compos_core/priv/editor.scm" 13039 "(let ((raw (current-prefix-arg)))") ("apps/compos_core/priv/editor.scm:13049" "apps/compos_core/priv/editor.scm" 13049 "(let* ((raw (current-prefix-arg))") ("apps/compos_core/priv/editor.scm:13061" "apps/compos_core/priv/editor.scm" 13061 "(let ((raw (current-prefix-arg)))") ("apps/compos_core/priv/packages/agent-fleet.scm:530" "apps/compos_core/priv/packages/agent-fleet.scm" 530 "(let* ((other-window? (and (current-prefix-arg) #t))") ("apps/compos_core/priv/packages/project.scm:589" "apps/compos_core/priv/packages/project.scm" 589 "(lambda () (project-switch-project-read (current-prefix-arg))))") ("apps/compos_core/priv/packages/switch.scm:887" "apps/compos_core/priv/packages/switch.scm" 887 "(other-window? (and (current-prefix-arg) #t))") ("apps/compos_core/test/compos/universal_argument_test.exs:26" "apps/compos_core/test/compos/universal_argument_test.exs" 26 "(lambda () (set! *zz-prefix-seen* (current-prefix-arg))))") ("apps/compos_core/test/compos/universal_argument_test.exs:42" "apps/compos_core/test/compos/universal_argument_test.exs" 42 "assert eval!(\"(current-prefix-arg)\") == \"#f\"") ("apps/compos_core/test/compos/universal_argument_test.exs:51" "apps/compos_core/test/compos/universal_argument_test.exs" 51 "assert eval!(\"(current-prefix-arg)\") == \"#f\"") ("apps/compos_core/test/compos/universal_argument_test.exs:72" "apps/compos_core/test/compos/universal_argument_test.exs" 72 "assert eval!(\"(current-prefix-arg)\") == \"#f\""))"ADVICE.md\nANNOTATIONS.md\nARCHITECTURE.md\nBEAM-POWER.md\nBEYOND-TOOLS.md\nBLOCKS.md\nBROWSE.md\nBUFFER.md\nBUG-escaped-closure-handlers.md\nCHAT-LIST.md\nCLEANUP-QUEUE.md\nCOMMANDS.md\nCOMPLETION.md\nCOMPONENTS-SPEC.md\nCOMPONENTS.md\nCOMPOS-HOMEPAGE-BRIEF.md\nCOMPOSML-COMPONENTS.md\nCOMPOSML-MIGRATION.md\nCOMPOSML-VERIFICATION.md\nCOMPOSML.md\nCONTROL-SPEC.md\nCORDIS-VS-EMACS.md\nDISPLAY-BUFFER.md\nDOGFOOD-BENCH.md\nEDITING-SURFACE-SPEC.md\nEMACS-AS-AGENT-HARNESS.md\nFACES.md\nFILE-VIEW.md\nGROUP-MODES.md\nHANDHELD.md\nHANDOFF.html\nHOOKS.md\nINTRODUCTION.md\nKEYMAPS.md\nKILL.md\nKNOWN-FAILURES.md\nLEARN COMPOS.md\nLISTS.md\nMARKDOWN.md\nMODES.md\nMORG-DEMO.md\nORG-MODE-PLAN.md\nPDF-ANNOTATIONS.md\nPEEK.md\nPOPUPS.md\nPROMPTS.md\nPROVENANCE-CRDT.md\nPROVENANCE.md\nREADME.md\nROADMAP.md\nSCHEME-ACTORS.md\nSCHEME-TEST-MIGRATION.md\nSCHEME-THREADING.md\nSIMPLIFY-SPEC.md\nVARIABLES.md\nVISUAL-LINE-WRAP-MAP.md\nWORKTREES.md\nchat:GROUPS.chat\ncode-browse.html\ncodex.png\ncraft_Agents.png\ncua-mode.md\ndsh-acp-steering.patch\neditor\nexamples\nfeatures\ngroups.md\nimage_1.png\nimage_2.png\nimage_3.png\nimage_4.png\nimage_5.png\nmcp-proxy.html\nscheme-threading-lost-update.svg\nsentry.png\nslack.png\ntraining.md\n"
▸ other · compos:eval-scheme
(let ((root "/Users/svs/src/compos")) (list (project-search-matches root "prefix-numeric-value") (project-search-matches root "set-prefix-arg!") (project-search-matches root "prefix_arg")))


▸ other · compos:read-file
/Users/svs/src/compos/apps/compos_core/test/compos/universal_argument_test.exs

((("apps/compos_core/priv/editor.scm:219" "apps/compos_core/priv/editor.scm" 219 "(cond ((equal? code 'p) (k (prefix-numeric-value (current-prefix-arg))))") ("apps/compos_core/priv/editor.scm:5194" "apps/compos_core/priv/editor.scm" 5194 "(scroll-window! (active-window) (prefix-numeric-value arg))") ("apps/compos_core/priv/editor.scm:5201" "apps/compos_core/priv/editor.scm" 5201 "(scroll-window! (active-window) (- (prefix-numeric-value arg)))") ("apps/compos_core/priv/editor.scm:13030" "apps/compos_core/priv/editor.scm" 13030 "(define (prefix-numeric-value raw)") ("apps/compos_core/priv/editor.scm:13161" "apps/compos_core/priv/editor.scm" 13161 "(public! 'prefix-numeric-value") ("apps/compos_core/priv/editor.scm:13162" "apps/compos_core/priv/editor.scm" 13162 "\"(prefix-numeric-value RAW) -> RAW as an integer; #f becomes 1\")") ("docs/COMMANDS.md:35" "docs/COMMANDS.md" 35 "undo commands take it as a count. `prefix-numeric-value` turns the raw value into a number.")) (("apps/compos_core/lib/compos/core/scheme_api.ex:802" "apps/compos_core/lib/compos/core/scheme_api.ex" 802 "\"set-prefix-arg!\" =>") ("apps/compos_core/lib/compos/core/scheme_api.ex:803" "apps/compos_core/lib/compos/core/scheme_api.ex" 803 "\"(set-prefix-arg! VALUE) — set this frame's raw one-shot prefix argument; #f clears it.\",") ("apps/compos_core/lib/compos/core/scheme_api.ex:2390" "apps/compos_core/lib/compos/core/scheme_api.ex" 2390 "\"set-prefix-arg!\" => fn [arg] ->") ("apps/compos_core/priv/editor.scm:12832" "apps/compos_core/priv/editor.scm" 12832 "(when prefix (set-prefix-arg! prefix))") ("apps/compos_core/priv/editor.scm:12834" "apps/compos_core/priv/editor.scm" 12834 "(when prefix (set-prefix-arg! #f)))))))") ("apps/compos_core/priv/editor.scm:13040" "apps/compos_core/priv/editor.scm" 13040 "(set-prefix-arg!") ("apps/compos_core/priv/editor.scm:13056" "apps/compos_core/priv/editor.scm" 13056 "(set-prefix-arg! (if negative? (- value) value)))))") ("apps/compos_core/priv/editor.scm:13062" "apps/compos_core/priv/editor.scm" 13062 "(set-prefix-arg!") ("apps/compos_core/priv/tests/command-test.scm:31" "apps/compos_core/priv/tests/command-test.scm" 31 "(set-prefix-arg! 3)") ("apps/compos_core/priv/tests/command-test.scm:34" "apps/compos_core/priv/tests/command-test.scm" 34 "(set-prefix-arg! #f)")) (("apps/compos_core/lib/compos/core/editor.ex:208" "apps/compos_core/lib/compos/core/editor.ex" 208 "def prefix_arg(fid \\\\ nil), do: GenServer.call(__MODULE__, {:prefix_arg, fid(fid)})") ("apps/compos_core/lib/compos/core/editor.ex:210" "apps/compos_core/lib/compos/core/editor.ex" 210 "def set_prefix_arg(arg, fid \\\\ nil),") ("apps/compos_core/lib/compos/core/editor.ex:211" "apps/compos_core/lib/compos/core/editor.ex" 211 "do: GenServer.call(__MODULE__, {:set_prefix_arg, arg, fid(fid)})") ("apps/compos_core/lib/compos/core/editor.ex:608" "apps/compos_core/lib/compos/core/editor.ex" 608 "prefix_arg: nil,") ("apps/compos_core/lib/compos/core/editor.ex:691" "apps/compos_core/lib/compos/core/editor.ex" 691 "prefix_arg: nil,") ("apps/compos_core/lib/compos/core/editor.ex:844" "apps/compos_core/lib/compos/core/editor.ex" 844 "|> Map.put(:prefix_arg, Map.get(f, :prefix_arg))") ("apps/compos_core/lib/compos/core/editor.ex:1454" "apps/compos_core/lib/compos/core/editor.ex" 1454 "def handle_call({:prefix_arg, fid}, _from, state),") ("apps/compos_core/lib/compos/core/editor.ex:1455" "apps/compos_core/lib/compos/core/editor.ex" 1455 "do: {:reply, Map.get(frame(state, fid), :prefix_arg), state}") ("apps/compos_core/lib/compos/core/editor.ex:1457" "apps/compos_core/lib/compos/core/editor.ex" 1457 "def handle_call({:set_prefix_arg, arg, fid}, _from, state) do") ("apps/compos_core/lib/compos/core/editor.ex:1460" "apps/compos_core/lib/compos/core/editor.ex" 1460 "{:reply, :ok, put_frame(state, Map.put(f, :prefix_arg, arg))}") ("apps/compos_core/lib/compos/core/editor.ex:1465" "apps/compos_core/lib/compos/core/editor.ex" 1465 "f = if keep_prefix, do: f, else: Map.put(f, :prefix_arg, nil)") ("apps/compos_core/lib/compos/core/key_dispatch.ex:49" "apps/compos_core/lib/compos/core/key_dispatch.ex" 49 "true -> buffer_key(key, pending, Map.get(snapshot, :prefix_arg))") ("apps/compos_core/lib/compos/core/key_dispatch.ex:266" "apps/compos_core/lib/compos/core/key_dispatch.ex" 266 "defp buffer_key(key, pending), do: buffer_key(key, pending, Editor.prefix_arg())") ("apps/compos_core/lib/compos/core/key_dispatch.ex:268" "apps/compos_core/lib/compos/core/key_dispatch.ex" 268 "defp buffer_key(key, pending, prefix_arg) do") ("apps/compos_core/lib/compos/core/key_dispatch.ex:279" "apps/compos_core/lib/compos/core/key_dispatch.ex" 279 "Editor.set_prefix_arg(nil)") ("apps/compos_core/lib/compos/core/key_dispatch.ex:282" "apps/compos_core/lib/compos/core/key_dispatch.ex" 282 "prefix_arg") ("apps/compos_core/lib/compos/core/key_dispatch.ex:292" "apps/compos_core/lib/compos/core/key_dispatch.ex" 292 "defp resolve_and_run(key, pending, undefined, prefix_arg \\\\ nil, insert? \\\\ true) do") ("apps/compos_core/lib/compos/core/key_dispatch.ex:302" "apps/compos_core/lib/compos/core/key_dispatch.ex" 302 "self_insert(if(key == \"SPC\", do: \" \", else: key), prefix_arg)") ("apps/compos_core/lib/compos/core/key_dispatch.ex:325" "apps/compos_core/lib/compos/core/key_dispatch.ex" 325 "insert? and pending == [] and key == \"SPC\" -> self_insert(\" \", prefix_arg)") ("apps/compos_core/lib/compos/core/key_dispatch.ex:326" "apps/compos_core/lib/compos/core/key_dispatch.ex" 326 "insert? and pending == [] and printable?(key) -> self_insert(key, prefix_arg)") ("apps/compos_core/lib/compos/core/key_dispatch.ex:369" "apps/compos_core/lib/compos/core/key_dispatch.ex" 369 "defp self_insert(text, prefix_arg \\\\ nil) do") ("apps/compos_core/lib/compos/core/key_dispatch.ex:370" "apps/compos_core/lib/compos/core/key_dispatch.ex" 370 "count = prefix_numeric_value(prefix_arg)") ("apps/compos_core/lib/compos/core/key_dispatch.ex:433" "apps/compos_core/lib/compos/core/key_dispatch.ex" 433 "if keep_prefix, do: show_prefix_arg()") ("apps/compos_core/lib/compos/core/key_dispatch.ex:452" "apps/compos_core/lib/compos/core/key_dispatch.ex" 452 "defp show_prefix_arg do") ("apps/compos_core/lib/compos/core/key_dispatch.ex:454" "apps/compos_core/lib/compos/core/key_dispatch.ex" 454 "case Editor.prefix_arg() do") ("apps/compos_core/lib/compos/core/scheme_api.ex:2389" "apps/compos_core/lib/compos/core/scheme_api.ex" 2389 "\"current-prefix-arg\" => fn [] -> Editor.prefix_arg() || false end,") ("apps/compos_core/lib/compos/core/scheme_api.ex:2391" "apps/compos_core/lib/compos/core/scheme_api.ex" 2391 "Editor.set_prefix_arg(arg)") ("apps/compos_core/test/compos/universal_argument_test.exs:19" "apps/compos_core/test/compos/universal_argument_test.exs" 19 "Editor.set_prefix_arg(nil)") ("apps/compos_core/test/compos/universal_argument_test.exs:31" "apps/compos_core/test/compos/universal_argument_test.exs" 31 "Editor.set_prefix_arg(nil)")))1	defmodule Compos.UniversalArgumentTest do
2	  use ExUnit.Case
3	
4	  alias Compos.Core.{Buffer, Editor, KeyDispatch, Session}
5	
6	  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
7	  defp type(text), do: text |> String.graphemes() |> press()
8	
9	  defp eval!(source) do
10	    {:ok, value} = Session.eval(source)
11	    value
12	  end
13	
14	  setup do
15	    name = "*zz-prefix-#{System.unique_integer([:positive])}*"
16	    Compos.Core.create_buffer(name)
17	    Editor.minibuffer_close()
18	    Editor.set_pending([])
19	    Editor.set_prefix_arg(nil)
20	
21	    eval!(~s{
22	      (begin
23	        (switch-to-buffer! "#{name}")
24	        (define *zz-prefix-seen* #f)
25	        (define-command "zz-prefix-capture"
26	          (lambda () (set! *zz-prefix-seen* (current-prefix-arg))))
27	        (global-set-key "<f9> u" "universal-argument")
28	        (global-set-key "<f9> c" "zz-prefix-capture"))})
29	
30	    on_exit(fn ->
31	      Editor.set_prefix_arg(nil)
32	      Compos.Core.kill_buffer(name)
33	    end)
34	
35	    {:ok, name: name}
36	  end
37	
38	  test "universal-argument supplies one raw argument to the next command" do
39	    press(["<f9>", "u", "<f9>", "c"])
40	
41	    assert eval!("*zz-prefix-seen*") == "(4)"
42	    assert eval!("(current-prefix-arg)") == "#f"
43	  end
44	
45	  test "M-x forwards and consumes the raw prefix argument" do
46	    press(["<f9>", "u", "M-x"])
47	    type("zz-prefix-capture")
48	    press("RET")
49	
50	    assert eval!("*zz-prefix-seen*") == "(4)"
51	    assert eval!("(current-prefix-arg)") == "#f"
52	  end
53	
54	  test "repeated universal-argument multiplies by four" do
55	    press(["<f9>", "u", "<f9>", "u", "<f9>", "c"])
56	
57	    assert eval!("*zz-prefix-seen*") == "(16)"
58	  end
59	
60	  test "digits and minus build a numeric argument" do
61	    press(["<f9>", "u", "3", "<f9>", "c"])
62	    assert eval!("*zz-prefix-seen*") == "3"
63	
64	    press(["<f9>", "u", "-", "2", "<f9>", "c"])
65	    assert eval!("*zz-prefix-seen*") == "-2"
66	  end
67	
68	  test "self insertion uses the numeric prefix and clears it", %{name: name} do
69	    press(["<f9>", "u", "x"])
70	
71	    assert Buffer.text(name) == "xxxx"
72	    assert eval!("(current-prefix-arg)") == "#f"
73	  end
74	end
75	
▸ other · compos:code-read
/Users/svs/src/compos/apps/compos_core/priv/editor.scm


▸ other · compos:code-read
/Users/svs/src/compos/apps/compos_core/priv/editor.scm

no such buffer: falseno such buffer: false
▸ other · ToolSearch
select:mcp__compos__code-read,mcp__compos__code-outline,mcp__compos__markdown-read

Tool: mcp__compos__code-readTool: mcp__compos__code-outlineTool: mcp__compos__markdown-read
▸ other · compos:code-read
/Users/svs/src/compos/apps/compos_core/priv/editor.scm


▸ other · compos:code-read
/Users/svs/src/compos/apps/compos_core/priv/editor.scm

(define (prefix-numeric-value raw)
  (cond ((number? raw) raw)
        ((and (pair? raw) (number? (car raw))) (car raw))
        ((equal? raw '-) -1)
        (else 1)))(bind-prefix! "mode-specific-map" "a" "agent-map")
▸ other · compos:describe-function
digit-argument


▸ other · compos:describe-function
negative-argument


▸ other · compos:code-read
/Users/svs/src/compos/apps/compos_core/priv/editor.scm


▸ other · compos:code-read
M-x command:
(lambda () (run-hooks (quote universal-argument-hook)) (let* ((raw (current-prefix-arg)) (key (car (reverse (last-keys)))) (digit (string->number (substring key (- (string-length key) 1) (string-length key)))) (negative? (or (equal? raw (quote -)) (and (number? raw) (< raw 0)))) (base (if (number? raw) (abs raw) 0)) (value (+ (* base 10) digit))) (set-prefix-arg! (if negative? (- value) value))))/Users/svs/src/compos/apps/compos_core/priv/editor.scm

M-x command:
(lambda () (run-hooks (quote universal-argument-hook)) (let ((raw (current-prefix-arg))) (set-prefix-arg! (cond ((number? raw) (- raw)) ((equal? raw (quote -)) 1) (else (quote -))))))(define-command "find-file" "Visit a file, prompting with filename completion"
  (lambda ()
    (if (current-prefix-arg)
        (find-file-group-reader find-file-read)
        (find-file-read (frame-group)))))(mode-keys! "tail-mode" '(("q" "quit-window")))
▸ other · compos:eval-scheme
(define (lines-of buf from to)
  (let loop ((ls (string-split (buffer-text buf) "\n")) (n 1) (acc '()))
    (cond ((null? ls) (string-join (reverse acc) "\n"))
          ((> n to) (string-join (reverse acc) "\n"))
          ((>= n from) (loop (cdr ls) (+ n 1) (cons (string-append (number->string n) ": " (car ls)) acc)))
          (else (loop (cdr ls) (+ n 1) acc)))))
(lines-of "/Users/svs/src/compos/apps/compos_core/priv/editor.scm" 9296 9312)


▸ other · compos:eval-scheme
(let ((r "/Users/svs/src/compos")) (list (project-search-matches r "universal-argument-hook") (project-search-matches r "keep_prefix")))

"9296: \n9297: ;; groups.scm replaces this seam with its native reader.  Keeping the reader\n9298: ;; out of terminal code also lets compos boot without the optional workspace\n9299: ;; package loaded.\n9300: (define opencode-group-reader\n9301:   (lambda (receive) (receive (frame-group))))\n9302: \n9303: (define-command \"opencode\"\n9304:   \"Open OpenCode for this group; with C-u, choose a group\"\n9305:   (lambda ()\n9306:     (if (current-prefix-arg)\n9307:         (opencode-group-reader opencode-open!)\n9308:         (opencode-open! (frame-group)))))\n9309: \n9310: ;;; RET in a comint process sends the current line to the process. RET\n9311: ;;; elsewhere inserts a newline.\n9312: "((("apps/compos_core/priv/editor.scm:13038" "apps/compos_core/priv/editor.scm" 13038 "(run-hooks 'universal-argument-hook)") ("apps/compos_core/priv/editor.scm:13048" "apps/compos_core/priv/editor.scm" 13048 "(run-hooks 'universal-argument-hook)") ("apps/compos_core/priv/editor.scm:13060" "apps/compos_core/priv/editor.scm" 13060 "(run-hooks 'universal-argument-hook)") ("apps/compos_core/priv/editor.scm:13083" "apps/compos_core/priv/editor.scm" 13083 "(add-hook! 'universal-argument-hook 'universal-argument--arm!)")) (("apps/compos_core/lib/compos/core/editor.ex:213" "apps/compos_core/lib/compos/core/editor.ex" 213 "@doc \"Record the command and clear its one-shot prefix unless KEEP_PREFIX is true.\"") ("apps/compos_core/lib/compos/core/editor.ex:214" "apps/compos_core/lib/compos/core/editor.ex" 214 "def finish_command(name, keep_prefix, fid \\\\ nil),") ("apps/compos_core/lib/compos/core/editor.ex:215" "apps/compos_core/lib/compos/core/editor.ex" 215 "do: GenServer.call(__MODULE__, {:finish_command, name, keep_prefix, fid(fid)})") ("apps/compos_core/lib/compos/core/editor.ex:1463" "apps/compos_core/lib/compos/core/editor.ex" 1463 "def handle_call({:finish_command, name, keep_prefix, fid}, _from, state) do") ("apps/compos_core/lib/compos/core/editor.ex:1465" "apps/compos_core/lib/compos/core/editor.ex" 1465 "f = if keep_prefix, do: f, else: Map.put(f, :prefix_arg, nil)") ("apps/compos_core/lib/compos/core/editor.ex:1470" "apps/compos_core/lib/compos/core/editor.ex" 1470 "%{until_command: true} when not keep_prefix -> Map.put(f, :overriding, nil)") ("apps/compos_core/lib/compos/core/key_dispatch.ex:431" "apps/compos_core/lib/compos/core/key_dispatch.ex" 431 "keep_prefix = name in @prefix_commands") ("apps/compos_core/lib/compos/core/key_dispatch.ex:432" "apps/compos_core/lib/compos/core/key_dispatch.ex" 432 "Editor.finish_command(name, keep_prefix)") ("apps/compos_core/lib/compos/core/key_dispatch.ex:433" "apps/compos_core/lib/compos/core/key_dispatch.ex" 433 "if keep_prefix, do: show_prefix_arg()")))
▸ other · compos:eval-scheme
(list (lines-of "/Users/svs/src/compos/apps/compos_core/priv/editor.scm" 13070 13100)
      (lines-of "/Users/svs/src/compos/apps/compos_core/priv/editor.scm" 12820 12840)
      (lines-of "/Users/svs/src/compos/apps/compos_core/priv/editor.scm" 210 228))


▸ other · compos:eval-scheme
(let ((r "/Users/svs/src/compos")) (list (project-search-matches r "prefix_commands") (project-search-matches r "C-u")))

("13070: \n13071: ;; Emacs's universal-argument-map: while a prefix argument is pending, the\n13072: ;; digits, - and C-u come from this map, the frame's overriding map until\n13073: ;; the next command. Every prefix command arms it.\n13074: (define-keymap! \"universal-argument-map\")\n13075: (for-each (lambda (d) (define-key \"universal-argument-map\" d \"digit-argument\"))\n13076:           '(\"0\" \"1\" \"2\" \"3\" \"4\" \"5\" \"6\" \"7\" \"8\" \"9\"))\n13077: (define-key \"universal-argument-map\" \"-\" \"negative-argument\")\n13078: (define-key \"universal-argument-map\" \"C-u\" \"universal-argument\")\n13079: \n13080: (define (universal-argument--arm!)\n13081:   (overriding-map! \"universal-argument-map\" #f #t))\n13082: \n13083: (add-hook! 'universal-argument-hook 'universal-argument--arm!)\n13084: \n13085: ;; M-1 .. M-9, M-0 and M-- are the digit arguments, as in Emacs\n13086: (for-each (lambda (d) (global-set-key (string-append \"M-\" d) \"digit-argument\"))\n13087:           '(\"0\" \"1\" \"2\" \"3\" \"4\" \"5\" \"6\" \"7\" \"8\" \"9\"))\n13088: (global-set-key \"M--\" \"negative-argument\")\n13089: \n13090: ;;; --- the prefix keymaps -------------------------------------------------------\n13091: ;;; A prefix key leads to a keymap, as C-x leads to ctl-x-map in Emacs: the\n13092: ;;; binding's value is (keymap NAME), and the rest of the sequence resolves\n13093: ;;; in that keymap. A package binds into the map its keys belong to and\n13094: ;;; never writes the global map; the global map belongs to the user's\n13095: ;;; init. The names are Emacs's where Emacs has them.\n13096: \n13097: (define (define-prefix-command name)\n13098:   (define-keymap! name)\n13099:   name)\n13100: " "12820: \n12821: (define-command \"execute-extended-command\"\n12822:   \"Run a command by name, with its keybinding and doc alongside\"\n12823:   (lambda ()\n12824:     ;; M-x itself finishes before its minibuffer callback runs. Preserve the\n12825:     ;; raw prefix across that boundary, then consume it after the selected\n12826:     ;; command has had the same view it would get from a direct keybinding.\n12827:     (let ((prefix (current-prefix-arg)))\n12828:       (minibuffer-read \"M-x \"\n12829:         (annotate 'command (history-order 'M-x (command-names)))\n12830:         (lambda (cmd)\n12831:           (history-push! 'M-x cmd)\n12832:           (when prefix (set-prefix-arg! prefix))\n12833:           (run-command cmd)\n12834:           (when prefix (set-prefix-arg! #f)))))))\n12835: \n12836: ;;; Cmd-p answers \"how do I do this?\" while M-x answers \"what is the\n12837: ;;; command called?\". Apropos supplies task-language matches from command\n12838: ;;; docs and recipes; the palette projects that broad catalog down to things\n12839: ;;; a reader can act on here.\n12840: (define (command-palette--candidate hit)" "210: ;;;     (lambda (n) ...))\n211: \n212: (define (interactive &rest codes) (cons 'interactive codes))\n213: \n214: (define (interactive-spec? x) (and (pair? x) (equal? (car x) 'interactive)))\n215: \n216: (define *command-fns* '())              ; ((name spec fn) ...)\n217: \n218: (define (interactive--arg code k)\n219:   (cond ((equal? code 'p) (k (prefix-numeric-value (current-prefix-arg))))\n220:         ((equal? code 'P) (k (current-prefix-arg)))\n221:         ((equal? code 'r) (k (list (region-beginning) (region-end))))\n222:         ((equal? code 'b) (k (current-buffer)))\n223:         ((equal? code 'd) (k (point)))\n224:         ((equal? code 'm) (k (or (mark) (point))))\n225:         ((string? code)\n226:          (let ((kind (substring code 0 1))\n227:                (prompt (substring code 1 (string-length code))))\n228:            (cond ((equal? kind \"n\")")((("apps/compos_core/lib/compos/core/key_dispatch.ex:17" "apps/compos_core/lib/compos/core/key_dispatch.ex" 17 "@prefix_commands ~w(universal-argument digit-argument negative-argument)") ("apps/compos_core/lib/compos/core/key_dispatch.ex:431" "apps/compos_core/lib/compos/core/key_dispatch.ex" 431 "keep_prefix = name in @prefix_commands")) (("apps/compos_core/lib/compos/core/key_dispatch.ex:273" "apps/compos_core/lib/compos/core/key_dispatch.ex" 273 "# after C-u the digits and - come from universal-argument-map, the") ("apps/compos_core/lib/compos/core/key_dispatch.ex:455" "apps/compos_core/lib/compos/core/key_dispatch.ex" 455 "[n] -> \"C-u \#{n}\"") ("apps/compos_core/lib/compos/core/key_dispatch.ex:458" "apps/compos_core/lib/compos/core/key_dispatch.ex" 458 "_ -> \"C-u\"") ("apps/compos_core/priv/editor.scm:5259" "apps/compos_core/priv/editor.scm" 5259 ";;; buffer's ring and sets a new one, and C-u C-SPC goes back to the mark") ("apps/compos_core/priv/editor.scm:9304" "apps/compos_core/priv/editor.scm" 9304 "\"Open OpenCode for this group; with C-u, choose a group\"") ("apps/compos_core/priv/editor.scm:13051" "apps/compos_core/priv/editor.scm" 13051 ";; \"1\" after C-u, or \"M-1\" on its own: the digit is the last character") ("apps/compos_core/priv/editor.scm:13072" "apps/compos_core/priv/editor.scm" 13072 ";; digits, - and C-u come from this map, the frame's overriding map until") ("apps/compos_core/priv/editor.scm:13078" "apps/compos_core/priv/editor.scm" 13078 "(define-key \"universal-argument-map\" \"C-u\" \"universal-argument\")") ("apps/compos_core/priv/editor.scm:13985" "apps/compos_core/priv/editor.scm" 13985 "(global-set-key \"C-u\" \"universal-argument\")") ("apps/compos_core/priv/packages/groups.scm:3375" "apps/compos_core/priv/packages/groups.scm" 3375 ";; C-u M-x opencode and the group-prefix command use the same destination") ("apps/compos_core/priv/packages/switch.scm:1" "apps/compos_core/priv/packages/switch.scm" 1 ";;; switch.scm --- ONE buffer switcher: C-x b, C-u C-x b, C-x C-b, and ibuffer merged.") ("apps/compos_core/priv/tests/command-test.scm:33" "apps/compos_core/priv/tests/command-test.scm" 33 "(check-equal! *command-test-got* 3 \"C-u 3 reaches the command as 3\")") ("apps/compos_core/priv/tests/group-switch-test.scm:1147" "apps/compos_core/priv/tests/group-switch-test.scm" 1147 "\"C-u lists the group's own first, then the other groups by name\"") ("apps/compos_core/priv/tests/keys-sweep-test.scm:98" "apps/compos_core/priv/tests/keys-sweep-test.scm" 98 "\"a printable, the digits after C-u, the popup's keys and Transient's all come from a map\"") ("apps/compos_core/priv/tests/keys-sweep-test.scm:102" "apps/compos_core/priv/tests/keys-sweep-test.scm" 102 "(check-equal! (keymap-lookup \"universal-argument-map\" \"3\") \"digit-argument\" \"a digit after C-u\")") ("apps/compos_core/priv/tests/register-test.scm:59" "apps/compos_core/priv/tests/register-test.scm" 59 "(check-equal! (point) 5 \"C-u C-SPC went to the mark\")") ("apps/compos_core/test/compos/editor_test.exs:2141" "apps/compos_core/test/compos/editor_test.exs" 2141 "test \"C-u M-x opencode chooses a group and opens its persistent terminal\", %{buf: buf} do") ("apps/compos_core/test/compos/editor_test.exs:2170" "apps/compos_core/test/compos/editor_test.exs" 2170 "press([\"C-u\", \"M-x\"])") ("apps/compos_core/test/compos/group_switch_preview_test.exs:58" "apps/compos_core/test/compos/group_switch_preview_test.exs" 58 "test \"C-u C-x b opens the picked buffer in another window\", context do") ("apps/compos_core/test/compos/group_switch_preview_test.exs:61" "apps/compos_core/test/compos/group_switch_preview_test.exs" 61 "press([\"C-u\", \"C-x\", \"b\"])") ("apps/compos_core/test/compos/project_search_test.exs:214" "apps/compos_core/test/compos/project_search_test.exs" 214 "press([\"C-u\", \"C-x\", \"p\", \"p\"])") ("apps/compos_core/test/compos/project_search_test.exs:260" "apps/compos_core/test/compos/project_search_test.exs" 260 "press([\"C-u\", \"C-x\", \"p\", \"p\"])") ("apps/compos_core/test/compos/project_search_test.exs:356" "apps/compos_core/test/compos/project_search_test.exs" 356 "press([\"C-u\", \"C-x\", \"C-f\"])") ("docs/COMMANDS.md:19" "docs/COMMANDS.md" 19 "| `'P` | the raw prefix argument: `(4)` for `C-u`, a number, `-`, or `#f` |") ("docs/COMMANDS.md:33" "docs/COMMANDS.md" 33 "`C-u` starts it, digits and `-` extend it, `M-1` .. `M-9`, `M-0` and") ("docs/COMMANDS.md:54" "docs/COMMANDS.md" 54 "`C-u C-SPC` goes back to the mark and pops the ring; a set mark is an active region here, so the pop leaves no region behind.") ("docs/GROUP-MODES.md:77" "docs/GROUP-MODES.md" 77 "only when the user asks (`C-u` prefix, or the `group-mode` chooser's") ("docs/groups.md:110" "docs/groups.md" 110 "- `C-u C-x b` shows the chosen buffer in another window and selects it.")))
▸ other · compos:eval-scheme
(list (lines-of "/Users/svs/src/compos/apps/compos_core/priv/packages/switch.scm" 875 905)
      (lines-of "/Users/svs/src/compos/apps/compos_core/priv/packages/agent-fleet.scm" 520 545)
      (lines-of "/Users/svs/src/compos/apps/compos_core/priv/packages/project.scm" 578 600))


▸ other · compos:eval-scheme
(lines-of "/Users/svs/src/compos/docs/COMMANDS.md" 1 70)

("875:                 (group-current-recalculate!)))))\n876:       (set! *ibuffer-prompt-last-ms* (- (monotonic-ms) t0)))))\n877: \n878: (define (ibuffer-prompt-last-ms) *ibuffer-prompt-last-ms*)\n879: \n880: (global-set-key \"C-x b\" \"ibuffer-prompt\")\n881: \n882: (define-command \"switch-to-buffer-prompt\"\n883:   \"Switch to a buffer; with a prefix, show it in another window\"\n884:   (lambda ()\n885:     (set! *mb-confirm-context* #f)\n886:     (let* ((here (or (window-buffer (active-window)) (current-buffer)))\n887:            (other-window? (and (current-prefix-arg) #t))\n888:            (my-group (or (buffer-group here) (frame-local 'current-group)))\n889:            ;; opening the switcher snapshots this group's arrangement:\n890:            ;; wherever you go next, the way back is exact\n891:            (_ (group-layout-save-if-shown! my-group))\n892:            (rows (switch-buffer-only-rows\n893:                    (switch-sectioned-rows here my-group (active-window))))\n894:            (view 'buffers)\n895:            (fallback (switch-first-choice rows here))\n896:            (row-of (lambda (name) (or (assoc name rows) (list name))))\n897:            (restore-here! (lambda ()\n898:                             (when (buffer-known? here) (window-preview-buffer! here))))\n899:            ;; buffers the preview wakes; the close puts every one nobody\n900:            ;; picked back to sleep (the consult contract)\n901:            (woken '())\n902:            (sleep-woken! (lambda (keep)\n903:                            (for-each (lambda (b)\n904:                                        (unless (equal? b keep) (buffer-sleep! b)))\n905:                                      woken)" "520:                 (append (map chat-prompt-live-row (chat-prompt-live-bufs))\n521:                         (map chat-prompt-saved-row (chats-archived-rows))))))\n522:     (chat-prompt-sectioned-rows\n523:       (filter (lambda (r) (equal? (nth 2 r) \"chat\")) rows)\n524:       (filter (lambda (r) (equal? (nth 2 r) \"saved\")) rows)\n525:       current)))\n526: \n527: (define-command \"chat-switch-prompt\"\n528:   \"Switch to a chat by its title; with a prefix, show it in another window\"\n529:   (lambda ()\n530:     (let* ((other-window? (and (current-prefix-arg) #t))\n531:            (here (or (window-buffer (active-window)) (current-buffer)))\n532:            (rows (chat-prompt-rows\n533:                    (or (buffer-group here)\n534:                        (and (boundp 'frame-group) (frame-group)))))\n535:            ;; a heading is not a chat: typing its label names nothing\n536:            (row-of (lambda (label)\n537:                      (let ((r (assoc label rows)))\n538:                        (and r (not (chat-prompt-separator? r)) r))))\n539:            (restore-here! (lambda ()\n540:                             (when (buffer-known? here) (window-preview-buffer! here))))\n541:            ;; the preview wakes a sleeping chat; every one nobody picked\n542:            ;; goes back to sleep (the switcher's contract)\n543:            (woken '())\n544:            (sleep-woken! (lambda (keep)\n545:                            (for-each (lambda (b)" "578: \n579: (define-command \"project-switch-project\"\n580:   \"Enter a known project's group, then find a file in it\"\n581:   (lambda () (project-switch-project-read (current-prefix-arg))))\n582: \n583: (define-command \"project-switch-project-in-group\"\n584:   \"Choose a project, then choose or create its destination group\"\n585:   (lambda () (project-switch-project-read #t)))\n586: \n587: (define-command \"find-file-in-new-group\"\n588:   \"Choose a file, create a group with it, and enter the group\"\n589:   (lambda ()\n590:     (read-file-name \"Find file in new group: \"\n591:       (lambda (path)\n592:         (group-read-new-name \"New group: \"\n593:           (lambda (name)\n594:             (let ((id (group-record-create! name)))\n595:               (if (not id)\n596:                   (message (string-append \"Could not create group \" name))\n597:                   (begin\n598:                     (set! *group-current-inhibit* #t)\n599:                     (let ((buf (visit-in-group (normalize-file-input path) id)))\n600:                       (if (not buf)")"1: "
▸ other · compos:read-file
/Users/svs/src/compos/docs/COMMANDS.md

1	# Commands
2	
3	A command is a name, a docstring, and a function. `M-x`, a key, an agent
4	and a test all run a command by name. `define-command` registers it.
5	
6	## Arguments
7	
8	A command may take arguments. The spec says where they come from when a
9	key runs the command, as `(interactive "p")` does in Emacs.
10	
11	```scheme
12	(define-command "next-line" "Move point down one line" (interactive 'p)
13	  (lambda (n) ...))
14	```
15	
16	| code | argument |
17	|------|----------|
18	| `'p` | the numeric prefix argument, 1 without one |
19	| `'P` | the raw prefix argument: `(4)` for `C-u`, a number, `-`, or `#f` |
20	| `'r` | the region start and end, two arguments |
21	| `'b` | the current buffer |
22	| `'d` | point |
23	| `'m` | the mark, or point |
24	| `"sPrompt: "` | a string from the minibuffer |
25	| `"nPrompt: "` | a number from the minibuffer |
26	| `"fPrompt: "` | a file name from the file prompt |
27	| `"bPrompt: "` | a buffer name |
28	
29	A prompt is asynchronous, so the rest of the collection runs when the answer arrives. `(command-call NAME ARG ...)` runs the function with explicit arguments. `(command-function NAME)` is the function.
30	
31	## The prefix argument
32	
33	`C-u` starts it, digits and `-` extend it, `M-1` .. `M-9`, `M-0` and
34	`M--` set it in one key. The motion, deletion, kill, scroll, newline and
35	undo commands take it as a count. `prefix-numeric-value` turns the raw value into a number.
36	
37	## this-command and last-command
38	
39	The dispatcher sets `this-command` as a command starts and makes it the next `last-command` when it ends. A command may change what the next one sees with `set-this-command!`. Both are per frame: two clients are two users. `yank-pop` reads `last-command`, and so does the kill ring.
40	
41	## The kill ring
42	
43	A kill command that follows a kill command grows the newest entry: `C-k C-k C-k` yanks back as one piece. `kill-text!` applies the rule; `kill-new`, `current-kill`, `kill-append!` are the Emacs names.
44	`*kill-commands*` lists the commands that count as a kill.
45	
46	## Undo
47	
48	One command is one undo step. `undo-boundary!` splits the step in progress, so the edits before it undo apart from the edits after it.
49	`break-undo-chain!` does not make a boundary: it ends a run of undos, so the next undo reverses them, which is redo.
50	
51	## The mark ring
52	
53	`C-SPC` pushes the old mark onto the buffer's ring and sets a new one. 
54	`C-u C-SPC` goes back to the mark and pops the ring; a set mark is an active region here, so the pop leaves no region behind. 
55	`C-x C-SPC` walks the global mark ring back across buffers. `push-mark!` and `pop-to-mark!` are the functions.
56	
57	## Registers
58	
59	A register is one character. 
60	`C-x r SPC` saves point and the buffer, 
61	`C-x r j` jumps back to it or restores saved windows, 
62	`C-x r s` saves the region's text, 
63	`C-x r +` appends to it, 
64	`C-x r i` inserts it, 
65	`C-x r w` saves the frame's windows, 
66	`C-x r v` says what a register holds. 
67	The registers persist with the desktop. packages/register.scm.
68	
▸ other · compos:eval-scheme
(let ((r "/Users/svs/src/compos")) (list (project-search-matches r "with a prefix") (project-search-matches r "with C-u")))

((("apps/compos_core/priv/editor.scm:5303" "apps/compos_core/priv/editor.scm" 5303 "(define-command \"set-mark-command\" \"Set the mark where point is; with a prefix, go back to the previous mark\"") ("apps/compos_core/priv/editor.scm:6192" "apps/compos_core/priv/editor.scm" 6192 "\"Delete a file, this buffer's by default: to the trash, or for good with a prefix argument\"") ("apps/compos_core/priv/editor.scm:12739" "apps/compos_core/priv/editor.scm" 12739 "(define-command \"chat-new\" \"Start a new chat buffer; with a prefix, choose or create its group\"") ("apps/compos_core/priv/packages/agent-fleet.scm:528" "apps/compos_core/priv/packages/agent-fleet.scm" 528 "\"Switch to a chat by its title; with a prefix, show it in another window\"") ("apps/compos_core/priv/packages/switch.scm:883" "apps/compos_core/priv/packages/switch.scm" 883 "\"Switch to a buffer; with a prefix, show it in another window\"") ("apps/compos_core/test/compos/project_search_test.exs:189" "apps/compos_core/test/compos/project_search_test.exs" 189 "test \"project-switch-project with a prefix can create an explicit destination\", %{root: root} do")) (("apps/compos_core/priv/editor.scm:9304" "apps/compos_core/priv/editor.scm" 9304 "\"Open OpenCode for this group; with C-u, choose a group\"")))
▸ other · compos:eval-scheme
(visit "/Users/svs/src/compos/apps/compos_core/lib/compos/core/key_dispatch.ex" (buffer-group (current-buffer)))

"/Users/svs/src/compos/apps/compos_core/lib/compos/core/key_dispatch.ex"
▸ other · compos:eval-scheme
(list (lines-of "/Users/svs/src/compos/apps/compos_core/lib/compos/core/key_dispatch.ex" 264 300)
      (lines-of "/Users/svs/src/compos/apps/compos_core/lib/compos/core/key_dispatch.ex" 425 462))

("264:   end\n265: \n266:   defp buffer_key(key, pending), do: buffer_key(key, pending, Editor.prefix_arg())\n267: \n268:   defp buffer_key(key, pending, prefix_arg) do\n269:     # a key ends any manual-scroll override: the view follows point again\n270:     Editor.user_acted()\n271:     Editor.set_echo(\"\")\n272: \n273:     # after C-u the digits and - come from universal-argument-map, the\n274:     # frame's overriding map until the next command\n275:     resolve_and_run(\n276:       key,\n277:       pending,\n278:       fn seq ->\n279:         Editor.set_prefix_arg(nil)\n280:         Editor.set_echo(Enum.join(seq, \" \") <> \" is undefined\")\n281:       end,\n282:       prefix_arg\n283:     )\n284:   end\n285: \n286:   # THE lookup ladder (dup #21) — every surface resolves a key the same\n287:   # way: append it to the pending prefix, look the sequence up, and fall\n288:   # through. A command runs; a prefix accumulates and echoes; anything\n289:   # else clears the prefix, self-inserts a printable, and otherwise defers\n290:   # to UNDEFINED — the one point where the surfaces differ.\n291:   # INSERT? false (Transient) keeps an unbound printable from inserting.\n292:   defp resolve_and_run(key, pending, undefined, prefix_arg \\\\ nil, insert? \\\\ true) do\n293:     seq = pending ++ [key]\n294: \n295:     case lookup_esc_meta(seq) do\n296:       # the global map binds every printable to self-insert-command, as\n297:       # Emacs does; the fast path inserts the key itself, with the count\n298:       # and the region rule\n299:       {:command, \"self-insert-command\"} ->\n300:         Editor.set_pending([])" "425:     try do\n426:       note(\"command\", name)\n427:       Editor.set_this_command(name)\n428: \n429:       case Session.run_command(name) do\n430:         :ok ->\n431:           keep_prefix = name in @prefix_commands\n432:           Editor.finish_command(name, keep_prefix)\n433:           if keep_prefix, do: show_prefix_arg()\n434: \n435:         {:error, msg} ->\n436:           Editor.finish_command(name, false)\n437:           Editor.set_echo(\"\#{name}: \#{msg}\")\n438:       end\n439: \n440:       note(\"after-command\", name)\n441:     after\n442:       if grouped? and Buffer.exists?(buffer), do: Buffer.undo_group(buffer, false)\n443:     end\n444:   end\n445: \n446:   defp prefix_numeric_value(nil), do: 1\n447:   defp prefix_numeric_value([n]) when is_integer(n), do: n\n448:   defp prefix_numeric_value(n) when is_integer(n), do: n\n449:   defp prefix_numeric_value({:sym, \"-\"}), do: -1\n450:   defp prefix_numeric_value(_), do: 1\n451: \n452:   defp show_prefix_arg do\n453:     text =\n454:       case Editor.prefix_arg() do\n455:         [n] -> \"C-u \#{n}\"\n456:         n when is_integer(n) -> Integer.to_string(n)\n457:         {:sym, \"-\"} -> \"-\"\n458:         _ -> \"C-u\"\n459:       end\n460: \n461:     Editor.set_echo(text)\n462:   end")
▸ other · compos:eval-scheme
(map (lambda (c) (list c (where-is c)))
     '("switch-to-buffer-prompt" "ibuffer-prompt" "chat-switch-prompt" "find-file" "chat-new" "opencode" "project-switch-project" "delete-file" "set-mark-command"))

error: unbound variable: where-is
No close public-api match — search with (apropos "words") before retrying.
▸ other · compos:apropos
which key runs this command

((kind "function" name "key-for-command" sig "(key-for-command NAME [BUF])" doc "the tersest key bound to NAME, in BUF's keymap and the global one (\"\" if none)" domain "commands" package "editor" namespace "core" effects ("unknown")) (kind "function" name "minor-mode-keys!" sig "(minor-mode-keys! NAME ((KEYS COMMAND) ...))" doc "the minor mode's map, in force while the mode is on" domain "commands" package "editor" namespace "core" effects ("unknown")) (kind "function" name "run-command" sig "(run-command NAME)" doc "invoke any M-x command" domain "commands" package "editor" namespace "core" effects ("unknown")) (kind "function" name "overriding-map!" sig "(overriding-map! KEYMAP [LOCK?] [UNTIL-COMMAND?])" doc "the frame's overriding keymap; #f clears it" domain "commands" package "editor" namespace "core" effects ("unknown")) (kind "function" name "global-set-key" sig "(global-set-key KEYS COMMAND-NAME)" doc ", e.g. \"C-c x\"" domain "commands" package "editor" namespace "core" effects ("unknown")) (kind "function" name "local-keys" sig "(local-keys BUF)" doc "((KEYS COMMAND) ...) for BUF's own bindings" domain "help" package "help" effects ("write")) (kind "function" name "db-command" sig "(db-command RESULT)" doc "the SQL command that ran: select, insert, update" domain "system" package "db" effects ("write" "external")) (kind "function" name "local-set-key" sig "(local-set-key KEYS COMMAND-NAME)" doc "in the current buffer's own map" domain "commands" package "editor" namespace "core" effects ("unknown")) (kind "function" name "key-resolve-plist" sig "(key-resolve-plist PL)" doc "resolve every value of a plist, keys untouched" domain "secrets" package "keys" effects ("unknown")) (kind "function" name "minor-mode-keymap" sig "(minor-mode-keymap NAME)" doc "the keymap a minor mode registered, or #f" domain "commands" package "editor" namespace "core" effects ("unknown")) (kind "function" name "minor-mode-keymap!" sig "(minor-mode-keymap! NAME KEYMAP)" doc "give a registered minor mode its keymap" domain "commands" package "editor" namespace "core" effects ("unknown")) (kind "function" name "handheld-run-command!" sig "(handheld-run-command! NAME)" doc "run the command NAME and remember it; #f when no such command" domain "interaction" package "handheld" effects ("write")) (kind "function" name "font-lock-set-keywords!" sig "(font-lock-set-keywords! MODE KEYWORDS)" doc "replace MODE's keywords" domain "commands" package "editor" namespace "core" effects ("unknown")) (kind "function" name "local-remap!" sig "(local-remap! FROM-COMMAND TO-COMMAND)" doc "Emacs [remap]: every key bound to FROM runs TO in this buffer (arrows, C-n/C-p, user bindings alike)" domain "commands" package "editor" namespace "core" effects ("unknown")) (kind "function" name "define-prefix-command" sig "(define-prefix-command NAME)" doc "a keymap a prefix key leads to" domain "commands" package "editor" namespace "core" effects ("unknown")) (kind "function" name "key-resolve" sig "(key-resolve V)" doc "\"@VAR\" becomes the secret; a list of parts joins after each resolves; anything else passes through" domain "secrets" package "keys" effects ("unknown")) (kind "function" name "editing-quit!" sig "(editing-quit!)" doc "mark the running command as a quit: after it the buffer is in the movement state; keyboard-quit calls this, and a command that aborts something calls it too" domain "commands" package "editor" namespace "core" effects ("unknown")) (kind "function" name "global-unset-key" sig "(global-unset-key KEYS)" doc "remove one global binding" domain "commands" package "editor" namespace "core" effects ("unknown")) (kind "function" name "arrow-chord" sig "(arrow-chord MODIFIERS KEY)" doc "the key spec for KEY under MODIFIERS, e.g. (arrow-chord '(meta shift) \"<left>\") is \"M-S-<left>\"" domain "commands" package "editor" namespace "core" effects ("unknown")) (kind "function" name "focus-default-keybindings" sig "(focus-default-keybindings &optional MODIFIERS)" doc "bind the arrows with MODIFIERS (shift control meta super; default shift) to focus-left/right/up/down" domain "commands" package "editor" namespace "core" effects ("unknown")) (kind "function" name "window-default-keybindings" sig "(window-default-keybindings &optional MODIFIERS)" doc "bind the arrows with MODIFIERS (default shift super) to window-left/right/up/down; the two panes' buffers swap and the focus follows" domain "commands" package "editor" namespace "core" effects ("unknown")) (kind "function" name "define-globalized-minor-mode!" sig "(define-globalized-minor-mode! GLOBAL LOCAL ELIGIBLE? [DOC])" doc "the command GLOBAL turns LOCAL on in every buffer ELIGIBLE? accepts, now and as buffers appear" domain "commands" package "editor" namespace "core" effects ("unknown")) (kind "function" name "local-remap*!" sig "(local-remap*! BUF FROM-COMMAND TO-COMMAND)" doc "remap in an explicit buffer" domain "commands" package "editor" namespace "core" effects ("unknown")) (kind "function" name "switch-open!" sig "(switch-open! VIEW)" doc "open the switcher on 'buffers, 'groups, or (locked GROUP)" domain "buffers" package "switch" effects ("read")))
▸ other · compos:eval-scheme
(map (lambda (c) (list c (key-for-command c)))
     '("switch-to-buffer-prompt" "ibuffer-prompt" "chat-switch-prompt" "find-file" "chat-new" "opencode" "project-switch-project" "delete-file" "set-mark-command" "universal-argument"))

(("switch-to-buffer-prompt" "") ("ibuffer-prompt" "C-x b") ("chat-switch-prompt" "") ("find-file" "C-x C-f") ("chat-new" "C-c n") ("opencode" "") ("project-switch-project" "C-x p p") ("delete-file" "") ("set-mark-command" "C-SPC") ("universal-argument" "C-u"))
▸ other · compos:eval-scheme
(let ((r "/Users/svs/src/compos")) (project-search-matches r "prefix"))

Error: result (78,005 characters across 1 line) exceeds maximum allowed tokens. Output has been saved to /Users/svs/.claude/projects/-Users-svs/bae5a4b0-dbb3-4dbb-a09d-a5ed98de380c/tool-results/mcp-compos-eval-scheme-1789422257974.txt.
Format: Plain text
Use offset and limit parameters to read specific portions of the file, search within it for specific content, and jq to make structured queries.
REQUIREMENTS FOR SUMMARIZATION/ANALYSIS/REVIEW:
- You MUST read the content from the file at /Users/svs/.claude/projects/-Users-svs/bae5a4b0-dbb3-4dbb-a09d-a5ed98de380c/tool-results/mcp-compos-eval-scheme-1789422257974.txt in sequential chunks until 100% of the content has been read.
- Note: this file's lines are too long for Read's offset/limit chunking. If a shell tool is available, slice by character range (e.g. python read()[A:B], dd, or cut -c) instead.
- If you receive truncation warnings when reading the file, reduce the chunk size until you have read 100% of the content without truncation.
- Before producing ANY summary or analysis, you MUST explicitly describe what portion of the content you have read. ***If you did not read the entire content, you MUST explicitly state this.***
- If after a few attempts you cannot read the file (file not found, lines too long for Read's offset/limit, no shell access), STOP retrying. Summarize what you were able to read, explicitly state which portion you could not read and why, and proceed.

▸ other · compos:eval-scheme
(let ((txt (buffer-text "/Users/svs/src/compos/apps/compos_core/priv/packages/switch.scm")))
  (let loop ((ls (string-split txt "\n")) (n 1) (acc '()))
    (if (null? ls) (reverse acc)
        (loop (cdr ls) (+ n 1)
              (if (string-contains? (car ls) "prefix") (cons (list n (car ls)) acc) acc)))))

((219 "      (filter (lambda (b) (not (string-prefix? \" \" b)))") (304 "                       (if (string-prefix? \"*\" name) \"accent\" #f)))") (844 "                         (and (not (string-prefix? \" \" b))") (883 "  \"Switch to a buffer; with a prefix, show it in another window\"") (887 "           (other-window? (and (current-prefix-arg) #t))"))
▸ other · compos:eval-scheme
(begin (visit "/Users/svs/src/compos/apps/compos_core/test/compos/group_switch_preview_test.exs" (buffer-group (current-buffer)))
       (lines-of "/Users/svs/src/compos/apps/compos_core/test/compos/group_switch_preview_test.exs" 45 80))

"45: \n46:     press([\"C-x\", \"b\"])\n47:     type(target)\n48: \n49:     assert eval!(\"(window-buffer \#{home})\") == Jason.encode!(target)\n50:     assert Editor.render_state().minibuffer != nil\n51: \n52:     press(\"C-g\")\n53: \n54:     assert eval!(\"(window-buffer \#{home})\") == Jason.encode!(source)\n55:     assert Editor.render_state().minibuffer == nil\n56:   end\n57: \n58:   test \"C-u C-x b opens the picked buffer in another window\", context do\n59:     home = eval!(\"(active-window)\") |> String.to_integer()\n60: \n61:     press([\"C-u\", \"C-x\", \"b\"])\n62:     type(context.target)\n63:     assert eval!(\"(window-buffer \#{home})\") == Jason.encode!(context.target)\n64: \n65:     press(\"RET\")\n66: \n67:     assert eval!(\"(window-buffer \#{home})\") == Jason.encode!(context.source)\n68:     assert length(Editor.list_windows()) == 2\n69:     refute eval!(\"(active-window)\") |> String.to_integer() == home\n70:     assert Editor.current_buffer() == context.target\n71:   end\n72: end\n73: "
▸ other · compos:eval-scheme
(let ((txt (buffer-text "/Users/svs/src/compos/apps/compos_core/priv/packages/switch.scm")))
  (let loop ((ls (string-split txt "\n")) (n 1) (acc '()))
    (if (null? ls) (reverse acc)
        (loop (cdr ls) (+ n 1)
              (if (or (string-contains? (car ls) "other-window")
                      (string-contains? (car ls) "define-command \"ibuffer-prompt"))
                  (cons (list n (car ls)) acc) acc)))))

((862 "(define-command \"ibuffer-prompt\"") (887 "           (other-window? (and (current-prefix-arg) #t))") (912 "                  (if other-window? \"Other window buffer\" \"Switch to\")") (914 "                (if other-window? \"Other window buffer: \" \"Switch to: \"))") (939 "                   (if (and other-window? (not context?))") (943 "                         (let ((win (display-buffer-other-window! picked)))"))
▸ other · compos:eval-scheme
(lines-of "/Users/svs/src/compos/apps/compos_core/priv/packages/switch.scm" 855 882)

"855: \n856: ;; the wall time of the last C-x b, key dispatch to a usable minibuffer:\n857: ;; (ibuffer-prompt-last-ms) reads it back for a measurement outside eval\n858: (define *ibuffer-prompt-last-ms* #f)\n859: \n860: ;; C-x b in the editor: the ibuffer table in the minibuffer form. The\n861: ;; candidate prompt below stays for the surfaces that draw only a prompt.\n862: (define-command \"ibuffer-prompt\"\n863:   \"Switch to a buffer from the table\"\n864:   (lambda ()\n865:     (let ((t0 (monotonic-ms)))\n866:       (let* ((here (or (window-buffer (active-window)) (current-buffer)))\n867:              (my-group (or (buffer-group here) (frame-local 'current-group)))\n868:              (_ (group-layout-save-if-shown! my-group))\n869:              (rows (switch-prompt-buffers here my-group (active-window))))\n870:         (if (null? (filter (lambda (b) (not (equal? b here))) rows))\n871:             (message \"No other buffer available\")\n872:             (ibuffer-prompt! rows *ibuffer-prompt-buffer* \"ibuffer-mode\" \"Switch to: \"\n873:               (lambda (row close!)\n874:                 (ibuffer-pick! row close!)\n875:                 (group-current-recalculate!)))))\n876:       (set! *ibuffer-prompt-last-ms* (- (monotonic-ms) t0)))))\n877: \n878: (define (ibuffer-prompt-last-ms) *ibuffer-prompt-last-ms*)\n879: \n880: (global-set-key \"C-x b\" \"ibuffer-prompt\")\n881: \n882: (define-command \"switch-to-buffer-prompt\""
▸ other · compos:describe-function
ibuffer-pick!

(lambda (row close! &optional where) (cond ((not (string? row)) (message "no buffer here")) ((and (equal? where (quote other)) (buffer-known? row)) (let ((w (window-showing row))) (when (peek-buffer? row) (peek-keep! row)) (set-frame-local! (quote peek-shown) #f) (set-frame-local! (quote peek-window) #f) (close!) (if (and w (window-exists? w) (equal? (window-buffer w) row)) (select-window! w) (show-in-other-work-window! row)) (group-current-recalculate!))) ((and (equal? where (quote other)) (file-exists? row)) (peek-dismiss!) (close!) (let ((w (other-work-window-id (active-window)))) (when w (select-window! w))) (visit-in-group row (and (boundp (quote group-here)) (group-here)))) ((buffer-known? row) (peek-dismiss!) (close!) (switch-to-buffer-in-group! row)) ((file-exists? row) (peek-dismiss!) (close!) (visit-in-group row (and (boundp (quote group-here)) (group-here)))) (else (message "no buffer here"))))
▸ other · compos:eval-scheme
(let ((txt (http-text "file:///dev/null"))) txt)


▸ other · compos:read-file
/Users/svs/src/compos/docs/KNOWN-FAILURES.md

#f# Known failing tests

`bin/test-fast` on a clean worktree does not come back green. This is the
record of what was already red, so the next person can tell a regression
from the weather.

Measured over **10 full runs** of `bin/test-fast` in clean worktrees at
HEAD, 2026-08-23/24, during the Scheme test migration. Counts are how many
of those 10 runs each test failed in.

**This is evidence, not permission.** A test listed here is not "allowed to
fail" — most of these are real defects nobody has looked at. Two were
confirmed this week by porting them to Scheme and watching them fail the
same way:

- `marked switcher buffers pull as one operation` — marks two rows, runs
  the pull, and neither buffer joins the group.
- `the switcher narrows by the annotation the marginalia supplies` — the
  modal switcher does not narrow.

## Faster ways to ask

`mix test` has the flags for this; reach for them before a four-minute
partition run.

**`--failed`** runs only the tests that failed the last time they ran —
RSpec's `--only-failures`. The manifest is
`_build/test/lib/<app>/.mix/.mix_test_failures`, one per umbrella app, and
it accumulates across invocations rather than holding only the last run.
Use it for the re-check loop after a fix:

```sh
cd apps/compos_core && mix test --failed
```

It answers "what failed when I last ran it". It cannot answer "was this
already red before my change" — by the time you ask, your change is in.
That question is what this file is for.

**`--stale`** runs only the tests referencing modules that changed. The
inner loop while editing.

**`--repeat-until-failure N`** is the one for the 21 names below that fail
in one run out of ten. Characterising a flake by re-running the whole
suite and waiting to see if a name comes back costs four minutes a
sample; this costs one test:

```sh
cd apps/compos_core && mix test --repeat-until-failure 50 test/compos/switcher_sleep_test.exs
```

## How to use it

Run `bin/test-fast` in a worktree at HEAD, not in the shared checkout —
another session's uncommitted work adds failures that are not yours:

```sh
git worktree add /tmp/verify HEAD && cd /tmp/verify
bin/test-fast 2>&1 | tee /tmp/run.log
grep -E "^\s+[0-9]+\) test" /tmp/run.log | sed 's/^ *[0-9]*) //' | sort > /tmp/now.txt
comm -13 <(grep -oE '^\| `[^`]+`' docs/KNOWN-FAILURES.md | tr -d '|` ') /tmp/now.txt
```

A name that is NOT in this list is the one to look at. Then, before
blaming your change: run that file alone across three seeds, and run the
same file at the commit before your change. Three of the four scares
during the migration were pre-existing, and one — `pull adds the current
group` — failed twice at HEAD and looked conclusive until it failed at the
parent commit too.

## The shape of it

The 64 names split cleanly in two, and the split is the useful part:

- **24 fail in all 10 runs.** These are not flake. They are defects with a
  reproducer already written, sitting untouched — fourteen of them in the
  switcher and the buffer list alone (`EditorTest`, `SwitcherSleepTest`,
  `SwitchModalTest`, `MarginaliaProjectTest`). If anything here is worth a
  morning, it is that cluster: one cause probably accounts for most of it.
- **21 fail in exactly 1 of 10.** Timing, ordering, frame geometry. These
  are the ones that make a green run impossible and make attribution cost
  a baseline run every time.

The rest sit in between and are worth suspecting individually.

## The count band

Whole-suite failures ranged **30-42** across the 10 runs. The count
moves on its own; so do the names. Roughly a third of this list appears in
one run and not the next. Diff the NAMES, never the number.

## The list

| count | test |
|---|---|
| 10/10 | `test C-h b lists local bindings before global ones (Compos.HelpTest)` |
| 10/10 | `test C-k kills the dormant buffer the row names (Compos.SwitcherSleepTest)` |
| 10/10 | `test C-x b is history first: previous buffer defaults, containers ride under it (Compos.EditorTest)` |
| 10/10 | `test C-x p s opens the project's scratch, tags the project's buffers, and toggles back (Compos.ProjectScratchTest)` |
| 10/10 | `test RET copies only the current secret value (Compos.DopplerTest)` |
| 10/10 | `test RET on a name that matches nothing founds a group from the windows (Compos.EditorTest)` |
| 10/10 | `test a group you switched to is a history row; its name finds it and its members (Compos.EditorTest)` |
| 10/10 | `test a killed file member comes back with content, not an empty shell (Compos.EditorTest)` |
| 10/10 | `test a project-rooted group offers its files, and the card defaults to dired (Compos.SwitchModalTest)` |
| 10/10 | `test a row for a buffer killed elsewhere leaves the list on the next command (Compos.SwitcherSleepTest)` |
| 10/10 | `test a stale off-screen buffer catches up when the switcher shows it (Compos.EditorTest)` |
| 10/10 | `test a verb acts on the nearest row when point sits in the chrome (Compos.SwitcherSleepTest)` |
| 10/10 | `test api -> codex -> claude-code -> api on ONE chat: everything survives (Compos.SwitchTest)` |
| 10/10 | `test buffer groups: C-c g tags members, C-c q talks to the group's one chat (Compos.EditorTest)` |
| 10/10 | `test dired (pure Scheme userland) / matches the marginalia too, and C-g puts the listing back (Compos.EditorTest)` |
| 10/10 | `test marginalia the switcher narrows by the annotation the marginalia supplies (Compos.MarginaliaProjectTest)` |
| 10/10 | `test mouse rows select and action controls run the keyboard commands (Compos.DopplerTest)` |
| 10/10 | `test narrowing to a dormant candidate wakes it; ESC puts it back to sleep (Compos.SwitcherSleepTest)` |
| 10/10 | `test opens as a grouped primary buffer, never a popup (Compos.DopplerTest)` |
| 10/10 | `test returning from a page C-x b is the editor's own command, redefined rather than rebound (Compos.ChromeTest)` |
| 10/10 | `test the modal switcher C-t puts the marked buffers in a group, and an empty answer removes it (Compos.EditorTest)` |
| 10/10 | `test the modal switcher lists with the buffer annotation, narrows by mode, C-k kills, RET visits (Compos.EditorTest)` |
| 10/10 | `test the modal switcher typing and the arrows preview the highlighted buffer in the home window (Compos.EditorTest)` |
| 10/10 | `test which-key panel appears for pending prefix (Compos.EditorTest)` |
| 9/10 | `test C-c s opens a plain scratch beside any ordinary buffer and toggles back (Compos.ScratchTest)` |
| 9/10 | `test RET opens distinct grouped detail buffers through the real key path (Compos.SentryTest)` |
| 9/10 | `test a save reloads every running app (Compos.AppPreviewTest)` |
| 8/10 | `test C-c s opens a scratch chat that carries the coding presets (Compos.CodeModeTest)` |
| 8/10 | `test M-x code-mode joins a group, loads the coding presets, and turns on llm-mode (Compos.CodeModeTest)` |
| 8/10 | `test marked switcher buffers pull as one operation (Compos.GroupSwitchCommandTest)` |
| 8/10 | `test restore-minor-modes! re-runs setup idempotently (reload path) (Compos.CodeModeTest)` |
| 7/10 | `test C-c RET talks to the companion without leaving the document (Compos.EditorTest)` |
| 7/10 | `test C-c w opens the optional companion for the writing workspace (Compos.WritingTest)` |
| 7/10 | `test code-mode asks before it assigns this frame a worktree, group, and chat (Compos.CodeModeTest)` |
| 7/10 | `test enabling writing mode opens its grouped plain scratch beside the preview (Compos.WritingTest)` |
| 5/10 | `test M-. in a help page opens the source of the name at point (Compos.HelpTest)` |
| 5/10 | `test a name in a help page is a link to its source, and the link opens it (Compos.HelpTest)` |
| 5/10 | `test pull adds the current group without switching context (Compos.GroupSwitchCommandTest)` |
| 4/10 | `test C-c q founds a group and asks its one chat from the minibuffer (Compos.EditorTest)` |
| 4/10 | `test openai models run the tool loop like every other model (Compos.EditorTest)` |
| 3/10 | `test chat opens the group companion; RET sends, reply appends (Compos.EditorTest)` |
| 3/10 | `test the scroll keys move an html preview page instead of point (Compos.HelpTest)` |
| 2/10 | `test M-? with no name at point still shows the buffer, its mode and its keys (Compos.HelpTest)` |
| 1/10 | `test *agents* fleet: sorted by attention, y answers the current line's thread (Compos.AgentTest)` |
| 1/10 | `test C-c C-v toggles the source of a generated page, C-h m describes a plain buffer (Compos.HelpTest)` |
| 1/10 | `test C-g cancels every queued turn and finalizes running tool cards (Compos.AgentTest)` |
| 1/10 | `test C-h a searches the editor and renders the hits as a page (Compos.HelpTest)` |
| 1/10 | `test C-h k over an unbound key says so, and the capture ends (Compos.HelpTest)` |
| 1/10 | `test M-? describes a public function at point by its signature (Compos.HelpTest)` |
| 1/10 | `test M-? over a name the editor does not know falls back to the apropos hits (Compos.HelpTest)` |
| 1/10 | `test M-? over prose says nothing about it and describes the buffer instead (Compos.HelpTest)` |
| 1/10 | `test a heading takes no selection and no count (Compos.GroupSwitchCommandTest)` |
| 1/10 | `test cancelled group creation changes no group state (Compos.GroupSwitchCommandTest)` |
| 1/10 | `test m marks; a verb acts on every marked chat, not the line at point (Compos.AgentTest)` |
| 1/10 | `test outbound — Scheme addresses a tab a message to a tab goes out as an overlay op (Compos.ChromeTest)` |
| 1/10 | `test pop removes only the current group and replaces a visible buffer (Compos.GroupSwitchCommandTest)` |
| 1/10 | `test project-ripgrep RET on the first match opens that file at that line (Compos.ProjectSearchTest)` |
| 1/10 | `test returning from a page a buffer already on screen is selected, not pulled somewhere else (Compos.ChromeTest)` |
| 1/10 | `test session/new carries our mcpServers and _meta; the adapter loads no user config (Compos.AgentTest)` |
| 1/10 | `test the activity row shows work in progress and clears at turn end (Compos.Ui.EditorLiveTest)` |
| 1/10 | `test the catalog new bundled declarations cannot silently expand the Luna backfill (Compos.AproposTest)` |
| 1/10 | `test the catalog the bundled backfill leaves no unknown metadata (Compos.AproposTest)` |
| 1/10 | `test the locals partition (W8) a restored chat sheds its dead runtime state; a live one keeps it (Compos.ChatResetTest)` |
| 1/10 | `test the mode setup rebuilds the buffer from its locals (Compos.GitDiffTest)` |

▸ other · compos:eval-scheme
(let* ((p "/Users/svs/src/compos/apps/compos_core/priv/packages/ibuffer.scm")
       (_ (visit p (buffer-group (current-buffer))))
       (txt (buffer-text p)))
  (let loop ((ls (string-split txt "\n")) (n 1) (acc '()))
    (if (null? ls) (reverse acc)
        (loop (cdr ls) (+ n 1)
              (if (or (string-contains? (car ls) "prefix-arg") (string-contains? (car ls) "'other"))
                  (cons (list n (car ls)) acc) acc)))))

((1200 "        ((and (equal? where 'other) (buffer-known? row))") (1210 "        ((and (equal? where 'other) (file-exists? row))") (1242 "          (ibuffer-pick! b (lambda () (run-command \"quit-window\")) 'other)))))") (1351 "            (ibuffer-pick! id (lambda () (run-command \"quit-window\")) 'other)))") (1626 "(public! 'ibuffer-pick! \"(ibuffer-pick! ROW CLOSE! [WHERE]) — open a row: WHERE 'other keeps it in the window that previewed it, else the window the table leaves; CLOSE! closes the table\")"))
▸ other · compos:eval-scheme
(lines-of "/Users/svs/src/compos/apps/compos_core/test/compos/group_switch_preview_test.exs" 1 45)

"1: defmodule Compos.GroupSwitchPreviewTest do\n2:   @moduledoc \"C-x b previews the selected buffer in the invoking window.\"\n3: \n4:   use ExUnit.Case\n5: \n6:   alias Compos.Core.{Editor, KeyDispatch, Session}\n7: \n8:   defp eval!(code) do\n9:     {:ok, value} = Session.eval(code)\n10:     value\n11:   end\n12: \n13:   defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)\n14:   defp type(text), do: text |> String.graphemes() |> press()\n15: \n16:   setup do\n17:     Editor.minibuffer_close()\n18:     Editor.completion_dismiss()\n19:     Editor.set_pending([])\n20:     Editor.delete_other_windows()\n21:     eval!(\"(layout-target-set! #f)\")\n22: \n23:     suffix = System.unique_integer([:positive])\n24:     source = \"group-preview-source-\#{suffix}\"\n25:     target = \"group-preview-target-\#{suffix}\"\n26: \n27:     eval!(~s{(begin\n28:       (buffer-create \"\#{target}\")\n29:       (buffer-create \"\#{source}\")\n30:       (switch-to-buffer! \"\#{source}\"))})\n31: \n32:     on_exit(fn ->\n33:       Editor.minibuffer_close()\n34:       Compos.Core.kill_buffer(source)\n35:       Compos.Core.kill_buffer(target)\n36:       Editor.delete_other_windows()\n37:     end)\n38: \n39:     {:ok, source: source, target: target}\n40:   end\n41: \n42:   test \"typing a candidate previews it and C-g restores the source\", context do\n43:     %{source: source, target: target} = context\n44:     home = eval!(\"(active-window)\") |> String.to_integer()\n45: "
▸ other · compos:read-file
/Users/svs/src/compos/docs/README.md

# Documentation

- [Advice](ADVICE.md) — named function advice, inspection, and enable/disable controls.
- [Architecture](ARCHITECTURE.md) — system boundary and design rules.
- [The New Browser Was Emacs All Along](EMACS-AS-AGENT-HARNESS.md) — why the
  Emacs model fits agent harnesses and rich rendered applications.
- [Cordis, Lisp, and JavaScript](CORDIS-VS-EMACS.md) — why Lisp runtimes need
  less plugin lifecycle machinery.
- [Handoff](HANDOFF.html) — current implementation guide.
- [Roadmap](ROADMAP.md) — editor build order.
- [AI-native plan](AI-NATIVE-SPEC.md) — discovery and code-browser work.
- [Simplification plan](SIMPLIFY-SPEC.md) — agent and RPC architecture.
- [UI components](COMPONENTS.md) — agent-facing component contract.
- [UI component specification](COMPONENTS-SPEC.md) — component-system design.
- [Control specification](CONTROL-SPEC.md) — groups, presets, and permissions.
- [Org-mode plan](ORG-MODE-PLAN.md) — Org implementation status and design.
- [Code browser](code-browse.html) — rendered code-browser documentation.
- [MCP proxy](mcp-proxy.html) — rendered MCP proxy documentation.
Now I have the evidence. Writing the doc.
▸ other · compos:eval-scheme
(buffer-known? "/Users/svs/src/compos/docs/C-U.md")

#f
▸ other · compos:eval-scheme
(begin
 (buffer-create "/Users/svs/src/compos/docs/C-U.md")
 (buffer-append! "/Users/svs/src/compos/docs/C-U.md"
"# C-u

`C-u` is the flip.

Every command worth writing has two right answers, not one. Open the file
in this group or a new one? Show the buffer here or in the other window?
Trash the file or delete it for good? Both are correct; they differ in how
often you mean them. Without `C-u` each pair costs two command names and
two keys, and the second name is the one nobody remembers. `C-u` says *the
other one*, so a pair costs one binding and one sentence of docstring.

The plain key is the answer you want all day. The flip is the answer you
want on purpose.

## What it is

`C-u` sets the frame's prefix argument: one value, for the next command
only. The command reads it; the dispatcher clears it when the command
ends.

| keys | raw value |
|------|-----------|
| `C-u` | `(4)` |
| `C-u C-u` | `(16)` |
| `C-u 3`, `M-3` | `3` |
| `C-u - 2` | `-2` |
| `M--` | `-` |
| nothing | `#f` |

`(current-prefix-arg)` returns the raw value. `(prefix-numeric-value RAW)`
turns it into an integer, `#f` into 1. A command declared
`(interactive 'P)` receives the raw value, `(interactive 'p)` the number.
editor.scm.

## Two ways to read it, never both

**A count multiplies.** `C-u 8 C-n` moves eight lines; `C-u 4 x` inserts
`xxxx`. The motion, deletion, kill, scroll, newline and undo commands take
a count. Read it with `'p`.

**A flip is a boolean.** `(and (current-prefix-arg) #t)`. The value is
discarded: `C-u` and `C-u 17` mean the same thing. Read it with `'P`, or
call `current-prefix-arg` directly.

A command that has a natural count has a count. Its flip, if it wants one,
needs its own command name. `C-u C-n` cannot both move four lines and move
the other way.

## Choosing which answer is the default

The two answers are equally correct. They are not equally frequent. In
order:

1. **Frequency decides the default.** The bare key is the common case.
2. **The flip is the deliberate one.** Reaching for `C-u` is a sentence you
   said on purpose, so it is where the wider blast radius goes. `C-x C-f`
   visits a file in the group you are in; `C-u C-x C-f` asks which group.
3. **Reversible by default, irreversible behind the prefix.**
   `delete-file` moves the file to the trash. `C-u` deletes it for good.
4. **The flip is still the same command.** `C-u C-x b` switches buffers —
   it only changes where the buffer lands. If `C-u` would do something you
   cannot describe as \"the same thing, the other way\", it is a second
   command, not a flip.
5. **The docstring says it.** `\"Switch to a buffer; with a prefix, show it
   in another window\"`. That sentence is the entire discovery surface:
   `M-x`, `C-h k`, apropos and an agent all read it and nothing else.

## The flips compos has

| command | plain | with `C-u` |
|---------|-------|-----------|
| `find-file` (`C-x C-f`) | visit in this group | choose the group |
| `project-switch-project` (`C-x p p`) | enter the project's group | choose the destination group |
| `chat-new` (`C-c n`) | new chat in this group | choose or create its group |
| `opencode` | this group's terminal | choose a group |
| `switch-to-buffer-prompt` | switch here | show it in another window |
| `chat-switch-prompt` | switch here | show it in another window |
| `delete-file` | to the trash | delete for good |
| `set-mark-command` (`C-SPC`) | set the mark | go back to the previous mark, pop the ring |

Three axes recur, and they are the ones to reach for first: **here or the
other window**, **this group or a chosen group**, **reversible or final**.

## Mechanics

**The value is frame-local.** Two clients are two users; a `C-u` pending in
one frame is invisible to the other. `Editor.prefix_arg/1`.

**One command consumes it.** `finish_command` clears the prefix unless the
command that just ran is itself `universal-argument`, `digit-argument` or
`negative-argument` — those three keep it and echo it. key_dispatch.ex.

**While it is pending, the digits are rebound.** `universal-argument-hook`
arms `universal-argument-map` as the frame's overriding map until the next
command, so `3`, `-` and a second `C-u` extend the argument instead of
inserting themselves. `M-0` .. `M-9` and `M--` reach the same commands
without a `C-u` first.

**`M-x` carries it across the minibuffer.** `execute-extended-command`
finishes before its callback runs, so it saves the raw value, restores it
around `run-command`, and clears it after. `C-u M-x foo` gives `foo`
exactly the view a key binding would.

**The echo area shows what is pending**: `C-u`, `C-u 4`, `3`, `-`.

## Writing one

```scheme
(define-command \"switch-to-buffer-prompt\"
  \"Switch to a buffer; with a prefix, show it in another window\"
  (lambda ()
    (let ((other-window? (and (current-prefix-arg) #t)))
      ...)))
```

Both sides need a test. universal_argument_test.exs covers the machinery
once, for everyone: the raw values, the multiply, `M-x` forwarding, the
clear. A command's own test presses `[\"C-u\", ...]` and asserts the other
answer — group_switch_preview_test.exs, project_search_test.exs.

## When it is not a flip

- **Three answers is not a flip.** Prompt, or write a transient.
- **A flip nobody can guess is a hidden feature.** If the docstring cannot
  say it in six words, split the command.
- **`C-u` is not a confirmation.** Destructive-behind-the-prefix is fine;
  destructive-behind-the-prefix without the docstring saying so is a trap.

## Known gap

`C-x b` is bound to `ibuffer-prompt`, whose body reads no prefix argument
and passes no `WHERE` to `ibuffer-pick!`. `switch-to-buffer-prompt`, the
command that does flip to the other window, has no key. switch.scm's own
header line and docs/groups.md both describe `C-u C-x b` as the
other-window flip, and group_switch_preview_test.exs asserts it. Either the
binding or the docs are wrong.

## See also

docs/COMMANDS.md — the interactive spec, `this-command`, the mark ring.
docs/KEYMAPS.md — prefix *keys*, which are a different thing with the same
word in them.
")
 (buffer-save! "/Users/svs/src/compos/docs/C-U.md"))

"/Users/svs/src/compos/docs/C-U.md"
▸ other · compos:eval-scheme
(begin (visit "/Users/svs/src/compos/docs/COMMANDS.md" (buffer-group (current-buffer)))
       (buffer-replace! "/Users/svs/src/compos/docs/COMMANDS.md"
         "undo commands take it as a count. `prefix-numeric-value` turns the raw value into a number."
         "undo commands take it as a count. `prefix-numeric-value` turns the raw value into a number.\nEverything else reads it as a flip: see [C-u](C-U.md).")
       (buffer-save! "/Users/svs/src/compos/docs/COMMANDS.md"))

"/Users/svs/src/compos/docs/COMMANDS.md"
▸ other · compos:eval-scheme
(list (lines-of "/Users/svs/src/compos/docs/COMMANDS.md" 31 38)
      (string-length (buffer-text "/Users/svs/src/compos/docs/C-U.md"))
      (buffer-modified? "/Users/svs/src/compos/docs/C-U.md"))

("31: ## The prefix argument\n32: \n33: `C-u` starts it, digits and `-` extend it, `M-1` .. `M-9`, `M-0` and\n34: `M--` set it in one key. The motion, deletion, kill, scroll, newline and\n35: undo commands take it as a count. `prefix-numeric-value` turns the raw value into a number.\n36: Everything else reads it as a flip: see [C-u](C-U.md).\n37: \n38: ## this-command and last-command" 5960 #t)
▸ other · compos:eval-scheme
(list (file-exists? "/Users/svs/src/compos/docs/C-U.md") (buffer-file-name "/Users/svs/src/compos/docs/C-U.md"))

error: unbound variable: buffer-file-name
No close public-api match — search with (apropos "words") before retrying.
▸ other · compos:eval-scheme
(file-exists? "/Users/svs/src/compos/docs/C-U.md")

#t
▸ other · compos:read-file
/Users/svs/src/compos/docs/C-U.md

Error: result (87,211 characters across 733 lines) exceeds maximum allowed tokens. Output has been saved to /Users/svs/.claude/projects/-Users-svs/bae5a4b0-dbb3-4dbb-a09d-a5ed98de380c/tool-results/mcp-compos-read-file-1789422378537.txt.
Format: Plain text
Use offset and limit parameters to read specific portions of the file, search within it for specific content, and jq to make structured queries.
REQUIREMENTS FOR SUMMARIZATION/ANALYSIS/REVIEW:
- You MUST read the content from the file at /Users/svs/.claude/projects/-Users-svs/bae5a4b0-dbb3-4dbb-a09d-a5ed98de380c/tool-results/mcp-compos-read-file-1789422378537.txt in sequential chunks until 100% of the content has been read.
- If you receive truncation warnings when reading the file, reduce the chunk size until you have read 100% of the content without truncation.
- Before producing ANY summary or analysis, you MUST explicitly describe what portion of the content you have read. ***If you did not read the entire content, you MUST explicitly state this.***
- If after a few attempts you cannot read the file (file not found, lines too long for Read's offset/limit, no shell access), STOP retrying. Summarize what you were able to read, explicitly state which portion you could not read and why, and proceed.

▸ other · compos:eval-scheme
(substring (http-text "x") 0 1)


▸ other · compos:eval-scheme
(let ((t (shell-command->string "wc -c docs/C-U.md; head -c 300 docs/C-U.md" "/Users/svs/src/compos"))) t)

error: substring: no function clause matching in String.slice/3"   88986 docs/C-U.md\n\n>>> you: C-u. the most important key. write a doc.\n\nlater you understand that there's always two equally correct ways to do something. Buffer left or window left? open in this group or new group? you see. that's where C-u comes in. it flips the toggle.\n\n\n▸ other · ToolSearch\nselect:mcp__compos__"
▸ other · compos:eval-scheme
(shell-command->string "wc -c docs/COMMANDS.md; sed -n '31,37p' docs/COMMANDS.md" "/Users/svs/src/compos")


▸ other · compos:apropos
write text to a file on disk

"    2963 docs/COMMANDS.md\n## The prefix argument\n\n`C-u` starts it, digits and `-` extend it, `M-1` .. `M-9`, `M-0` and\n`M--` set it in one key. The motion, deletion, kill, scroll, newline and\nundo commands take it as a count. `prefix-numeric-value` turns the raw value into a number.\nEverything else reads it as a flip: see [C-u](C-U.md).\n\n"((kind "function" name "allow-one-write!" sig "(allow-one-write! PATH)" doc "let the next write to PATH set the confirmable rules aside; a person's answer buys this, and it is spent once" domain "buffers" package "editor" namespace "core" effects ("unknown")) (kind "function" name "annotate-store-file" sig "(annotate-store-file BUF)" doc "the on-disk annotations file for a file buffer, or #f" domain "chat" package "annotate" effects ("write")) (kind "function" name "file-shown-from-disk?" sig "(file-shown-from-disk? PATH)" doc "#t when PATH opens in a viewer that reads the file from disk: the buffer holds no bytes, and no size cap applies" domain "targets" package "editor" namespace "core" effects ("read")) (kind "function" name "block-text" sig "(block-text BUF LINE)" doc "the whole text of the fenced block on LINE, or #f" domain "targets" package "block" namespace "editor" effects ("write")) (kind "function" name "kill-text!" sig "(kill-text! TEXT [BEFORE?])" doc "TEXT onto the kill ring: appended to the newest entry after a kill command, else as a new entry" domain "targets" package "editor" namespace "core" effects ("write")) (kind "function" name "buffer-append!" sig "(buffer-append! NAME TEXT)" doc "append; the usual way to add text" domain "buffers" package "editor" namespace "core" effects ("write")) (kind "function" name "pdf-insert-text" sig "(pdf-insert-text PATH PAGE X BASELINE-Y TEXT [FONT] [SIZE])" doc "one working-copy path; the first edit creates it and later edits update it" domain "edit" package "pdf" effects ("read" "write" "execute")) (kind "function" name "read-file" sig "(read-file PATH [LINE-NUMBERS])" doc "read a text file; add stable line numbers when LINE-NUMBERS is true" domain "discovery" package "tools" effects ("read")) (kind "function" name "spreadsheet-write!" sig "(spreadsheet-write! BUFFER WORKBOOK)" doc "replace a workbook by buffer name and refresh its grid" domain "ui" package "spreadsheet" effects ("write")) (kind "function" name "buffer-delete-text!" sig "(buffer-delete-text! NAME TEXT)" doc "delete exact, unique TEXT from a live buffer" domain "editing" package "tools" effects ("write")) (kind "function" name "chat-log-save!" sig "(chat-log-save! BUF)" doc "write this conversation to its group's home, else <compos-home>/chats, as a .chat file" domain "chat" package "chat" effects ("read")) (kind "function" name "endpoint-send!" sig "(endpoint-send! NAME TEXT)" doc "write one frame to the connection and do not wait" domain "system" package "endpoint" effects ("write" "external" "execute")) (kind "function" name "messages-text" sig "(messages-text)" doc "the log as text, one line per message, oldest first; read this, not the paged *Messages* list" domain "project" package "messages" effects ("read")) (kind "function" name "buffer-text" sig "(buffer-text NAME)" doc "the buffer's full text" domain "buffers" package "editor" namespace "core" effects ("read")) (kind "function" name "line-text" sig "(line-text)" doc "Text of the current line" domain "editing" package "editor" namespace "core" effects ("unknown")) (kind "function" name "count-words" sig "(count-words BUF)" doc "how many words a buffer holds" domain "writing" package "writing" effects ("read")) (kind "function" name "spreadsheet-open!" sig "(spreadsheet-open! PATH)" doc "open or create a JSON text workbook" domain "ui" package "spreadsheet" effects ("read" "write")) (kind "function" name "spreadsheet-set-cell!" sig "(spreadsheet-set-cell! BUFFER SHEET CELL VALUE)" doc "set one A1 cell and refresh the open grid" domain "ui" package "spreadsheet" effects ("write")) (kind "function" name "tab-say" sig "(tab-say TAB TEXT)" doc "put a line on that tab's screen" domain "chrome" package "chrome" effects ("unknown")) (kind "function" name "test-buffer!" sig "(test-buffer! NAME TEXT)" doc "make or empty a buffer and give it TEXT; answers NAME" domain "diagnostics" package "test" effects ("read")) (kind "function" name "delete-file-path!" sig "(delete-file-path! PATH PERMANENT?)" doc "move PATH to the trash, or delete it when PERMANENT?; the path, or #f when nothing is there" domain "targets" package "editor" namespace "core" effects ("read")) (kind "function" name "http-download!" sig "(http-download! URL PATH [OPTS])" doc "write the body of URL to PATH; #t when it arrived" domain "web" package "http" effects ("write" "external")) (kind "function" name "visual-next-line!" sig "(visual-next-line! [EXTEND])" doc "move point one visual row down when the wrap map can say, else one source line" domain "unknown" package "editor" namespace "core" effects ("write")) (kind "function" name "visual-beginning-of-line!" sig "(visual-beginning-of-line! [EXTEND])" doc "move point to the start of its visual row when the wrap map can say, else of its line" domain "unknown" package "editor" namespace "core" effects ("write")))
▸ other · compos:eval-scheme
(begin (define *doc* (buffer-text "/Users/svs/src/compos/docs/C-U.md"))
       (list (string-length *doc*) (substring *doc* 0 40)))

(5960 "# C-u\n\n`C-u` is the flip.\n\nEvery command")
▸ other · compos:eval-scheme
(begin (buffer-kill! "/Users/svs/src/compos/docs/C-U.md")
       (delete-file-path! "/Users/svs/src/compos/docs/C-U.md" #t)
       (list (file-exists? "/Users/svs/src/compos/docs/C-U.md")
             (buffer-known? "/Users/svs/src/compos/docs/C-U.md")))

# C-u

`C-u` is the flip.

Every command worth writing has two right answers, not one. Open the file
in this group or a new one? Show the buffer here or in the other window?
Trash the file or delete it for good? Both are correct; they differ in how
often you mean them. Without `C-u` each pair costs two command names and
two keys, and the second name is the one nobody remembers. `C-u` says *the
other one*, so a pair costs one binding and one sentence of docstring.

The plain key is the answer you want all day. The flip is the answer you
want on purpose.

## What it is

`C-u` sets the frame's prefix argument: one value, for the next command
only. The command reads it; the dispatcher clears it when the command
ends.

| keys | raw value |
|------|-----------|
| `C-u` | `(4)` |
| `C-u C-u` | `(16)` |
| `C-u 3`, `M-3` | `3` |
| `C-u - 2` | `-2` |
| `M--` | `-` |
| nothing | `#f` |

`(current-prefix-arg)` returns the raw value. `(prefix-numeric-value RAW)`
turns it into an integer, `#f` into 1. A command declared
`(interactive 'P)` receives the raw value, `(interactive 'p)` the number.
editor.scm.

## Two ways to read it, never both

**A count multiplies.** `C-u 8 C-n` moves eight lines; `C-u 4 x` inserts
`xxxx`. The motion, deletion, kill, scroll, newline and undo commands take
a count. Read it with `'p`.

**A flip is a boolean.** `(and (current-prefix-arg) #t)`. The value is
discarded: `C-u` and `C-u 17` mean the same thing. Read it with `'P`, or
call `current-prefix-arg` directly.

A command that has a natural count has a count. Its flip, if it wants one,
needs its own command name. `C-u C-n` cannot both move four lines and move
the other way.

## Choosing which answer is the default

The two answers are equally correct. They are not equally frequent. In
order:

1. **Frequency decides the default.** The bare key is the common case.
2. **The flip is the deliberate one.** Reaching for `C-u` is a sentence you
   said on purpose, so it is where the wider blast radius goes. `C-x C-f`
   visits a file in the group you are in; `C-u C-x C-f` asks which group.
3. **Reversible by default, irreversible behind the prefix.**
   `delete-file` moves the file to the trash. `C-u` deletes it for good.
4. **The flip is still the same command.** `C-u C-x b` switches buffers —
   it only changes where the buffer lands. If `C-u` would do something you
   cannot describe as "the same thing, the other way", it is a second
   command, not a flip.
5. **The docstring says it.** `"Switch to a buffer; with a prefix, show it
   in another window"`. That sentence is the entire discovery surface:
   `M-x`, `C-h k`, apropos and an agent all read it and nothing else.

## The flips compos has

| command | plain | with `C-u` |
|---------|-------|-----------|
| `find-file` (`C-x C-f`) | visit in this group | choose the group |
| `project-switch-project` (`C-x p p`) | enter the project's group | choose the destination group |
| `chat-new` (`C-c n`) | new chat in this group | choose or create its group |
| `opencode` | this group's terminal | choose a group |
| `switch-to-buffer-prompt` | switch here | show it in another window |
| `chat-switch-prompt` | switch here | show it in another window |
| `delete-file` | to the trash | delete for good |
| `set-mark-command` (`C-SPC`) | set the mark | go back to the previous mark, pop the ring |

Three axes recur, and they are the ones to reach for first: **here or the
other window**, **this group or a chosen group**, **reversible or final**.

## Mechanics

**The value is frame-local.** Two clients are two users; a `C-u` pending in
one frame is invisible to the other. `Editor.prefix_arg/1`.

**One command consumes it.** `finish_command` clears the prefix unless the
command that just ran is itself `universal-argument`, `digit-argument` or
`negative-argument` — those three keep it and echo it. key_dispatch.ex.

**While it is pending, the digits are rebound.** `universal-argument-hook`
arms `universal-argument-map` as the frame's overriding map until the next
command, so `3`, `-` and a second `C-u` extend the argument instead of
inserting themselves. `M-0` .. `M-9` and `M--` reach the same commands
without a `C-u` first.

**`M-x` carries it across the minibuffer.** `execute-extended-command`
finishes before its callback runs, so it saves the raw value, restores it
around `run-command`, and clears it after. `C-u M-x foo` gives `foo`
exactly the view a key binding would.

**The echo area shows what is pending**: `C-u`, `C-u 4`, `3`, `-`.

## Writing one

```scheme
(define-command "switch-to-buffer-prompt"
  "Switch to a buffer; with a prefix, show it in another window"
  (lambda ()
    (let ((other-window? (and (current-prefix-arg) #t)))
      ...)))
```

Both sides need a test. universal_argument_test.exs covers the machinery
once, for everyone: the raw values, the multiply, `M-x` forwarding, the
clear. A command's own test presses `["C-u", ...]` and asserts the other
answer — group_switch_preview_test.exs, project_search_test.exs.

## When it is not a flip

- **Three answers is not a flip.** Prompt, or write a transient.
- **A flip nobody can guess is a hidden feature.** If the docstring cannot
  say it in six words, split the command.
- **`C-u` is not a confirmation.** Destructive-behind-the-prefix is fine;
  destructive-behind-the-prefix without the docstring saying so is a trap.

## Known gap

`C-x b` is bound to `ibuffer-prompt`, whose body reads no prefix argument
and passes no `WHERE` to `ibuffer-pick!`. `switch-to-buffer-prompt`, the
command that does flip to the other window, has no key. switch.scm's own
header line and docs/groups.md both describe `C-u C-x b` as the
other-window flip, and group_switch_preview_test.exs asserts it. Either the
binding or the docs are wrong.

## See also

docs/COMMANDS.md — the interactive spec, `this-command`, the mark ring.
docs/KEYMAPS.md — prefix *keys*, which are a different thing with the same
word in them.
