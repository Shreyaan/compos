;;; transient-test.scm --- transient menu policy.

(domain! 'testing)
(effects! '(write))

(deftest 'llm-config-history-keeps-recent-distinct-setups
  "The LLM selector history is newest-first, distinct, and bounded"
  (lambda ()
    (let ((saved *llm-config-history*))
      (set! *llm-config-history* '())
      (llm-config-remember! '(connector "api" model "default" effort "default"))
      (llm-config-remember!
        '(connector "codex-app-server" model "gpt-5.6-terra" effort "high"))
      (llm-config-remember! '(connector "api" model "default" effort "default"))
      (check-equal!
        (map llm-bundle-connector *llm-config-history*)
        '("api" "codex-app-server")
        "a repeated setup moves to the front without a duplicate")
      (set! *llm-config-history*
        (map (lambda (c) (list 'connector c 'model "m" 'effort "e"))
             '("c1" "c2" "c3" "c4" "c5" "c6" "c7" "c8" "c9" "c10")))
      (llm-config-remember! '(connector "c11" model "m" effort "e"))
      (check-equal! (length *llm-config-history*) llm-config-history-limit
                    "a new setup drops the oldest entry")
      (check-false! (member "c10" (map llm-bundle-connector *llm-config-history*))
                    "the history removes its oldest entry")
      (set! *llm-config-history* saved))))

(deftest 'llm-config-history-separates-setups-by-their-tools
  "Two setups that differ only in their presets are two recent choices"
  (lambda ()
    (let ((saved *llm-config-history*))
      (set! *llm-config-history* '())
      (llm-config-remember!
        '(connector "api" model "default" effort "default" presets (compos)))
      (llm-config-remember!
        '(connector "api" model "default" effort "default" presets (compos web)))
      (check-equal! (length *llm-config-history*) 2
                    "the tool surface is part of what a choice IS")
      (set! *llm-config-history* saved))))

(deftest 'llm-config-history-reads-its-old-three-part-entries
  "A history saved before presets still recalls what it did record"
  (lambda ()
    (let ((b (llm-bundle-normalize '("api" "gpt-5.5" "high"))))
      (check-equal! (llm-bundle-connector b) "api" "the backend survives")
      (check-equal! (llm-bundle-model b) "gpt-5.5" "the model survives")
      (check-equal! (llm-bundle-effort b) "high" "the effort survives")
      (check-false! (llm-bundle-presets b)
                    "an entry that named no presets changes none"))))

(deftest 'llm-bundle-label-says-what-is-unusual
  "A bundle label leaves out every part that is already the default"
  (lambda ()
    (check-equal!
      (llm-bundle-label '(connector "claude-code" model "default"
                          effort "default" presets (compos)
                          permission "approve" agent-mode "default"))
      "claude-code"
      "the defaults and the always-on editor bridge stay quiet")
    (check-equal!
      (llm-bundle-label '(name "review" connector "claude-code"
                          model "opus[1m]" effort "high"
                          presets (compos web) permission "ask"
                          agent-mode "plan"))
      "claude-code · opus[1m] · high · web · ask · plan"
      "everything chosen is named, in the order the menu sets it")))

(deftest 'llm-bundles-are-named-and-replaceable
  "A named bundle is saved by name, replaced by name, and forgotten by name"
  (lambda ()
    (let ((saved *llm-bundles*))
      (set! *llm-bundles* '())
      (llm-bundle-save! "zz-work" '(connector "api" model "m1" effort "high"))
      (llm-bundle-save! "zz-read" '(connector "claude-code" model "haiku"))
      (check-equal! (llm-bundle-key (llm-bundle-named "zz-work")) "a"
                    "the first bundle gets the first free key")
      (check-equal! (llm-bundle-key (llm-bundle-named "zz-read")) "b"
                    "the next bundle gets a different key")
      (set! *llm-bundles* (llm-bundles-assign-keys (reverse *llm-bundles*)))
      (check-equal! (llm-bundle-key (llm-bundle-named "zz-work")) "a"
                    "loading persisted bundles preserves their keys")
      (check-equal! (llm-bundle-key (llm-bundle-named "zz-read")) "b"
                    "persisted keys do not depend on list order")
      (set! *llm-bundles*
        (llm-bundles-assign-keys
          (map (lambda (b) (llm-bundle-put b 'key "A")) *llm-bundles*)))
      (check-equal! (llm-bundle-key (llm-bundle-named "zz-work")) "a"
                    "an upper-case key from the first menu is reassigned")
      (check-equal! (llm-bundle-key (llm-bundle-named "zz-read")) "b"
                    "in list order")
      (check-equal! (llm-bundle-model (llm-bundle-named "zz-work")) "m1"
                    "a bundle answers to its name")
      (llm-bundle-save! "zz-work" '(connector "api" model "m2" effort "high"))
      (check-equal! (length *llm-bundles*) 2
                    "saving over a name replaces that bundle")
      (check-equal! (llm-bundle-model (llm-bundle-named "zz-work")) "m2"
                    "the newer setup is the one kept")
      (check-equal! (llm-bundle-key (llm-bundle-named "zz-work")) "a"
                    "updating and moving a bundle never changes its key")
      (check-equal! (llm-bundle-key (llm-bundle-named "zz-read")) "b"
                    "reordering another bundle never changes this key")
      (llm-bundle-forget! "zz-work")
      (check-false! (llm-bundle-named "zz-work") "a forgotten bundle is gone")
      (check-true! (and (llm-bundle-named "zz-read") #t)
                   "and the others are not")
      (check-equal! (llm-bundle-key (llm-bundle-named "zz-read")) "b"
                    "forgetting another bundle does not compact this key")
      (set! *llm-bundles* saved))))

(deftest 'llm-config-history-offers-ten-numbered-choices
  "The LLM selector offers ten recent setups with numeric keys"
  (lambda ()
    (let ((saved *llm-config-history*)
          (buf (test-buffer! "zz-llm-config-history" "")))
      (buffer-set-local! buf 'llm-connector "codex-app-server")
      (buffer-set-local! buf 'llm-model "gpt-5.6-luna")
      (buffer-set-local! buf 'llm-effort "medium")
      (set! *llm-config-history*
        (map (lambda (c) (list 'connector c 'model "m" 'effort "e"))
             '("c1" "c2" "c3" "c4" "c5" "c6" "c7" "c8" "c9" "c10")))
      (check-equal!
        (map (lambda (item) (plist-get item 'key))
             (llm-config--history-items buf))
        '("1" "2" "3" "4" "5" "6" "7" "8" "9" "0")
        "the tenth setup uses zero")
      (set! *llm-config-history* saved)
      (buffer-kill! buf))))

(deftest 'llm-config-menu-has-two-levels
  "C-c b: bundles and recents on one level, the fields one level down"
  (lambda ()
    (let ((saved *llm-bundles*)
          (buf (test-buffer! "zz-llm-config-groups" "")))
      (set! *llm-bundles* '())
      (llm-bundle-save! "zz-review" '(connector "api" model "m" effort "high"))
      (let* ((groups (llm-config--groups buf))
             (titles (map car groups))
             (bundles (assoc "Bundles" groups))
             (setup (assoc "Setup" groups))
             (keys (map (lambda (i) (plist-get i 'key)) (cdr bundles)))
             (actions (map (lambda (i) (plist-get i 'key)) (cdr setup))))
        (check-true! (and (member "Bundles" titles) (member "Setup" titles) #t)
                     "level one holds the bundles and the setup actions")
        (check-false! (member "Model" titles)
                      "and none of the fields")
        (check-equal! keys '("a") "a saved bundle is one key away")
        (check-equal! (plist-get (car (cdr bundles)) 'description) "zz-review"
                      "the row is the name; the rail says the rest")
        (check-true! (and (member "." actions) (member "s" actions)
                          (member "x" actions) #t)
                     "fine-tune, save, and forget are the setup actions"))
      (let* ((groups (llm-fine-tune--groups buf))
             (titles (map car groups)))
        (check-equal! (take titles 4)
                      '("Model" "Tools" "Prompt" "Permissions")
                      "level two holds every field of the setup")
        (check-true! (and (assoc "Setup" groups) #t)
                     "with revert and save at the end"))
      (set! *llm-bundles* saved)
      (buffer-kill! buf))))

(deftest 'llm-config-rail-marks-what-a-bundle-would-change
  "The rail follows the highlighted bundle and colours the fields that differ"
  (lambda ()
    (let ((saved *llm-bundles*)
          (buf (test-buffer! "zz-llm-config-rail" "")))
      (set! *llm-bundles* '())
      (buffer-set-local! buf 'llm-connector "api")
      (buffer-set-local! buf 'llm-model "m1")
      (llm-bundle-save! "zz-other" '(connector "api" model "m2" effort "default"))
      (let* ((items (llm-config--bundle-items buf))
             (detail (llm-config--detail buf (car items)))
             (rows (cadr detail))
             (model (assoc "model" rows))
             (backend (assoc "backend" rows)))
        (check-equal! (car detail) "zz-other" "the rail is titled by the bundle")
        (check-equal! (cadr model) "m2" "and shows the bundle's value")
        (check-equal! (caddr model) "drift" "a field that would change is marked")
        (check-equal! (caddr backend) "" "a field that stays is not")
        (check-equal! (assoc "tools" rows) '("tools" "editor only" "dim")
                      "a field the bundle never recorded shows the live value, dimmed")
        (check-contains! (caddr detail) "1 field changes"
                         "the note counts the change")
        (check-equal! (plist-get (car items) 'description) "zz-other"
                      "the row is the bare name"))
      (let ((detail (llm-config--detail buf #f)))
        (check-equal! (car detail) "live setup"
                      "with no bundle highlighted the rail shows the live setup")
        (check-contains! (llm-config--subtitle buf) "off-bundle"
                         "and the subtitle says no bundle equals it"))
      (llm-bundle-save! "zz-same" (llm-config-combination buf))
      (check-contains! (llm-config--subtitle buf) "on bundle zz-same"
                       "a bundle equal to the live setup names itself")
      (check-equal! (llm-config--bundle-active? buf (llm-bundle-named "zz-same")) #t
                    "and its row reads active")
      (set! *llm-bundles* saved)
      (buffer-kill! buf))))

(deftest 'llm-config-bundle-row-selects-and-close-applies
  "A bundle row parks a choice; the setup lands when level one closes"
  (lambda ()
    (let ((saved *llm-bundles*)
          (history *llm-config-history*)
          (buf (test-buffer! "zz-llm-config-pending" "")))
      (set! *llm-bundles* '())
      (set-frame-local! 'llm-config-pending #f)
      (buffer-set-local! buf 'llm-connector "api")
      (buffer-set-local! buf 'llm-model "m1")
      (llm-bundle-save! "zz-pick" '(connector "api" model "m2" effort "default"))
      (let ((row (car (llm-config--bundle-items buf))))
        ((plist-get row 'command))
        (check-equal! (llm-config--model buf) "m1"
                      "choosing a bundle changes nothing yet")
        (check-equal! (llm-bundle-name (llm-config--pending-bundle)) "zz-pick"
                      "the choice waits as the pending one")
        (check-equal! ((plist-get row 'value-fn) buf) "selected"
                      "and the row says so")
        (check-contains! (llm-config--subtitle buf) "applies on close"
                         "the subtitle says when it lands")
        (llm-config--quit-top! buf)
        (check-equal! (llm-config--model buf) "m2"
                      "closing level one applies the choice")
        (check-equal! (llm-config--pending) #f
                      "and nothing stays pending"))
      (set! *llm-bundles* saved)
      (set! *llm-config-history* history)
      (set-frame-local! 'llm-config-base #f)
      (buffer-kill! buf))))

(deftest 'llm-default-bundle-seeds-a-new-chat
  "The bundle named in custom.scm lands on a chat that has no session yet"
  (lambda ()
    (let ((saved *llm-bundles*)
          (default llm-default-bundle)
          (buf (test-buffer! "zz-llm-default" "")))
      (set! *llm-bundles* '())
      (llm-bundle-save! "zz-coding" '(connector "api" model "m9" effort "high"))
      (set! llm-default-bundle "zz-coding")
      (check-true! (and (llm-default-bundle-apply! buf) #t)
                   "the named default applies")
      (check-equal! (buffer-local buf 'agent-connector) "api"
                    "the connector comes from the bundle")
      (check-equal! (buffer-local buf 'agent-model) "m9"
                    "the model comes from the bundle")
      (check-equal! (buffer-local buf 'agent-effort) "high"
                    "the effort comes from the bundle")
      (check-equal! ((plist-get (car (llm-config--bundle-items buf)) 'value-fn) buf)
                    "default"
                    "and the menu row says which bundle new chats start with")
      (set! llm-default-bundle "")
      (check-false! (llm-default-bundle-apply! buf)
                    "no name, nothing to apply")
      (set! llm-default-bundle default)
      (set! *llm-bundles* saved)
      (buffer-kill! buf))))

(deftest 'llm-fine-tune-measures-drift-against-the-base
  "Level two compares the live setup with the base bundle; u puts it back"
  (lambda ()
    (let ((saved *llm-bundles*)
          (buf (test-buffer! "zz-llm-fine-tune" "")))
      (set! *llm-bundles* '())
      (buffer-set-local! buf 'llm-connector "api")
      (buffer-set-local! buf 'llm-model "m1")
      (llm-bundle-save! "zz-base" (llm-config-combination buf))
      (set-frame-local! 'llm-config-base #f)
      (llm-fine-tune--setup! buf)
      (check-equal! (frame-local 'llm-config-base) "zz-base"
                    "the base is the bundle the live setup equals")
      (check-contains! (caddr (llm-fine-tune--detail buf #f)) "identical"
                       "no drift yet")
      (buffer-set-local! buf 'llm-model "m9")
      (let ((detail (llm-fine-tune--detail buf #f)))
        (check-equal! (caddr (assoc "model" (cadr detail))) "drift"
                      "a changed field is marked")
        (check-contains! (caddr detail) "1 field differs" "and counted"))
      (with-current-buffer buf
        (lambda ()
          (transient-setup "llm-fine-tune" buf)
          (run-command "llm-config-revert")
          (run-command "transient-quit-all")))
      (check-equal! (buffer-local buf 'llm-model) "m1"
                    "revert puts the base bundle's model back")
      (set-frame-local! 'llm-config-base #f)
      (set! *llm-bundles* saved)
      (buffer-kill! buf))))

(deftest 'transient-menu-carries-header-rail-and-legend
  "A prefix's header, rail, and legend options reach the menu as one alist"
  (lambda ()
    (transient-define-prefix "zz-meta-menu" "Meta"
      (list (list "Rows" (transient-suffix "q" "one" "transient-quit-all")))
      'subtitle-fn (lambda (_s) "sub")
      'context-fn (lambda (_s) "ctx")
      'detail-fn (lambda (_s item)
                   (list "rail" (list (list "k" (plist-get item 'description) "drift")) "note"))
      'legend-fn (lambda (_s) '(("q" "quit"))))
    (let* ((prefix (transient-prefix "zz-meta-menu"))
           (state (list 'prefix "zz-meta-menu" 'scope "x" 'selected 0 'values '()))
           (items (transient--visible-items (transient--visible-groups prefix state)))
           (meta (transient--menu-meta prefix state items)))
      (check-equal! (cadr (assoc "subtitle" meta)) "sub" "the subtitle")
      (check-equal! (cadr (assoc "context" meta)) "ctx" "the context")
      (check-equal! (car (cadr (assoc "detail" meta))) "rail" "the rail title")
      (check-equal! (cadr (assoc "detail" meta))
                    (list "rail" (list (list "k" "one" "drift")) "note")
                    "the rail rows come from the selected item")
      (check-equal! (cadr (assoc "legend" meta)) '(("q" "quit")) "the legend"))
    (let* ((plain (transient-define-prefix "zz-plain-menu" "Plain"
                    (list (list "Rows" (transient-suffix "q" "one" "transient-quit-all")))))
           (prefix (transient-prefix "zz-plain-menu"))
           (state (list 'prefix "zz-plain-menu" 'scope "x" 'selected 0 'values '()))
           (meta (transient--menu-meta prefix state '())))
      (check-equal! (cadr (assoc "subtitle" meta)) "" "a menu with no options has an empty header")
      (check-equal! (cadr (assoc "detail" meta)) #f "no rail")
      (check-equal! (cadr (assoc "legend" meta)) transient-default-legend "and the default legend"))))

(deftest 'the-tools-key-opens-a-menu-not-a-buffer
  "t stays in the transient world: a child prefix over the same scope.
The full text list is still one key deeper (l), for actual reading."
  (lambda ()
    (let ((buf (test-buffer! "zz-llm-tools-menu" "")))
      ;; the t row names a PREFIX — transient--invoke-command opens a
      ;; child menu for a prefix name, and runs a command otherwise
      (let* ((groups (llm-fine-tune--groups buf))
             (tools (assoc "Tools" groups))
             (t-row (let loop ((is (cdr tools)))
                      (cond ((null? is) #f)
                            ((equal? (plist-get (car is) 'key) "t") (car is))
                            (else (loop (cdr is)))))))
        (check-equal! (plist-get t-row 'command) "chat-tools"
                      "t names the child prefix")
        (check-true! (and (transient-prefix "chat-tools") #t)
                     "and that prefix is defined"))
      ;; the child builds real rows: a frozen chat shows its servers
      (buffer-set-local! buf 'chat-presets '(compos))
      (buffer-set-local! buf 'chat-tool-specs
        '(("eval-scheme" "Run Scheme." ())
          ("mcp__zzt__echo" "Echo." "{}")))
      (let* ((groups (llm-config--tools-groups buf))
             (servers (car groups))
             (change (assoc "Change" groups)))
        (check-contains! (car servers) "Servers" "the server group heads the menu")
        (check-equal! (length (cdr servers)) 2 "one row per server")
        (check-equal! (plist-get (car (cdr servers)) 'description) "compos"
                      "named after the server")
        (check-true! (and change #t) "and the actions keep their group")
        (let ((keys (map (lambda (i) (plist-get i 'key)) (cdr change))))
          (check-true! (and (member "p" keys) (member "r" keys) (member "l" keys) #t)
                       "presets, adopt, and the full list stay reachable")))
      (buffer-kill! buf))))

(deftest 'prompt-sections-are-one-multi-select-transaction
  "Prompt section switches stay in a draft until one apply commits all of them"
  (lambda ()
    (let ((buf (test-buffer! "zz-prompt-multi-select" "")))
      (buffer-set-local! buf 'prompt-disabled-parts '("reading"))
      (let* ((items (llm-config--prompt-items buf))
             (repository
               (let loop ((rest items))
                 (cond ((null? rest) #f)
                       ((equal? (plist-get (car rest) 'description) "reading")
                        (car rest))
                       (else (loop (cdr rest))))))
             (identity (car items)))
        (check-false! (plist-get repository 'default)
                      "a disabled section starts off")
        (check-true! (plist-get identity 'default)
                     "an enabled section starts on"))
      (transient-setup "llm-prompt-sections" buf)
      (transient--set-value! "--prompt-identity" #f)
      (transient--set-value! "--prompt-general" #f)
      (check-equal! (prompt-disabled-parts buf) '("reading")
                    "editing the draft does not change the buffer")
      (run-command "llm-config-apply-prompt-sections")
      (check-equal! (take (prompt-disabled-parts buf) 2)
                    '("identity" "general")
                    "one apply commits every changed switch")
      (buffer-kill! buf))))

(deftest 'transient-columns-and-left-right
  "A prefix names the groups that share a column; left and right move
between columns on the same row, and the edges do not wrap"
  (lambda ()
    (transient-define-prefix "zz-col-menu" "Cols"
      (list (list "A" (transient-suffix "1" "a1" "transient-quit-all")
                      (transient-suffix "2" "a2" "transient-quit-all"))
            (list "B" (transient-suffix "3" "b1" "transient-quit-all"))
            (list "C" (transient-suffix "4" "c1" "transient-quit-all")
                      (transient-suffix "5" "c2" "transient-quit-all")
                      (transient-suffix "6" "c3" "transient-quit-all"))
            (list "D" (transient-suffix "7" "d1" "transient-quit-all")))
      'columns '(("A" "B") ("C")))
    (let* ((prefix (transient-prefix "zz-col-menu"))
           (state (list 'prefix "zz-col-menu" 'scope "x" 'selected 0 'values '()))
           (groups (transient--visible-groups prefix state))
           (columns (transient--columns prefix state groups)))
      (check-equal! columns '(("A" "B") ("C") ("D"))
                    "declared columns first, an unnamed group stands alone")
      ;; items: a1=0 a2=1 b1=2 | c1=3 c2=4 c3=5 | d1=6
      (check-equal! (transient--column-target groups columns 0 1) 3
                    "right from the first row lands on the first row")
      (check-equal! (transient--column-target groups columns 2 1) 5
                    "the third row of the column, across group borders")
      (check-equal! (transient--column-target groups columns 5 1) 6
                    "a shorter column takes its last row")
      (check-equal! (transient--column-target groups columns 6 1) 6
                    "the last column does not wrap")
      (check-equal! (transient--column-target groups columns 4 -1) 1
                    "left goes back on the same row")
      (check-equal! (transient--column-target groups columns 0 -1) 0
                    "the first column does not wrap"))
    (let* ((prefix (transient-prefix "zz-plain-menu"))
           (state (list 'prefix "zz-plain-menu" 'scope "x" 'selected 0 'values '()))
           (groups (transient--visible-groups prefix state)))
      (check-equal! (transient--columns prefix state groups) '(("Rows"))
                    "a menu with no columns option: one column per group"))))

