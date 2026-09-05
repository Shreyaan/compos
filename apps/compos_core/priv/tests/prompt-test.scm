;;; prompt-test.scm --- prompt ownership, composition, and inspection.

(domain! 'testing)
(effects! '(write display))

(define (t--prompt-chat name connector)
  (let ((buf (test-buffer! name "")))
    (buffer-set-local! buf 'mode-name "chat-mode")
    (buffer-set-local! buf 'agent-saved-mark 0)
    (buffer-set-local! buf 'agent-connector connector)
    (buffer-set-local! buf 'chat-presets '(compos))
    buf))

(define (t--prompt-cleanup &rest buffers)
  (for-each
    (lambda (buf) (when (buffer-known? buf) (buffer-kill! buf)))
    (cons "*Help*" buffers)))

(deftest 'direct-and-acp-agents-share-the-same-standing-guidance
  "both lanes compose the same named text files in the same order"
  (lambda ()
    (let ((direct (compos-direct-prompt-parts))
          (acp (compos-acp-prompt-parts)))
      (check-equal! direct acp "the lane guidance is identical")
      (check-equal! (map car direct)
                    '("compos-identity" "quiet-editor" "scope" "chat-context"
                      "scheme-api" "discovery" "reading" "repository"
                      "scheme-authoring" "browser" "catalog" "recipes")
                    "the checked-in fragment order is explicit")
      (for-each
        (lambda (part)
          (check-true! (> (string-length (cadr part)) 0)
                       (string-append (car part) " is not empty")))
        direct)
      (check-equal! (hello) (prompt-parts-text acp)
                    "hello is only the shared composition")
      (check-contains! (hello) "(chat-context)"
                       "every agent learns to inspect its context")
      (check-contains! (hello) "Batch up to four independent read-only calls"
                       "independent discovery can run concurrently")
      (check-contains! (hello) "Search each unknown once"
                       "discovery stops repeating answered questions")
      (check-contains! (hello) "Prefer `(code-outline BUF)`"
                       "agents prefer structural reads")
      (check-contains! (hello) "(code-sexp-replace! BUF ANCHOR NEW [LEVELS])"
                       "agents know surgical source editing is available")
      (check-contains! (hello) "Write Scheme unless the user explicitly specifies another language"
                       "Scheme remains the default implementation language")
      (check-true! (< (string-length (prompt-file-text "quiet-editor.txt")) 600)
                   "quiet-editor stays compact")
      (check-true! (< (string-length (prompt-file-text "discovery.txt")) 850)
                   "discovery stays compact")
      (check-true! (< (string-length (prompt-file-text "repository.txt")) 1000)
                   "repository guidance stays compact"))))

(deftest 'chat-context-names-the-conversation-and-its-companions
  "the structured context reports identity and full ambient membership"
  (lambda ()
    (let ((stale (group-resolve-id "prompt-context-group")))
      (when stale (group-record-delete! stale)))
    (let ((id (group-record-create! "prompt-context-group"))
          (chat (t--prompt-chat "*prompt-context*" "api"))
          (doc "prompt-context.md")
          (hidden "prompt-context-hidden.ex"))
      (test-buffer! doc "work")
      (test-buffer! hidden "def hidden, do: :context")
      (chat-set-group! chat id)
      (buffer-add-group! doc id)
      (buffer-add-group! hidden id)
      (buffer-set-local! doc 'mode-name "text-mode")
      (buffer-set-local! hidden 'mode-name "elixir-mode")
      (buffer-context-only! hidden)
      (buffer-set-local! chat 'agent-slug "prompt-agent")
      (buffer-set-local! chat 'default-directory "/tmp/prompt-context")
      (let ((ctx (with-current-buffer chat (lambda () (chat-context)))))
        (check-equal! (plist-get ctx 'chat) chat "the chat name")
        (check-equal! (plist-get ctx 'agent) "prompt-agent" "the agent name")
        (check-true! (member chat (plist-get ctx 'group-members))
                     "the chat belongs to the group")
        (check-true! (member hidden (plist-get ctx 'group-members))
                     "context-only buffers remain agent context")
        (check-true! (member hidden (group-buffers id))
                     "context-only buffers remain raw group members")
        (check-true! (member doc (plist-get ctx 'companions))
                     "the work buffer is a companion")
        (check-equal! (plist-get ctx 'directory) "/tmp/prompt-context"
                      "the workspace directory")
        (check-equal! (plist-get ctx 'prompt) 'prospective
                      "the prompt starts prospective"))
      (chat-prompt-freeze! chat)
      (check-equal! (plist-get (chat-context chat) 'prompt) 'frozen
                    "the context reports the frozen prompt")
      (t--prompt-cleanup chat doc hidden)
      (group-record-delete! id))))

(deftest 'group-members-come-from-chat-context-not-the-system-prompt
  "changing group membership leaves the cached prompt byte-identical"
  (lambda ()
    (let ((stale (group-resolve-id "prompt-ambient-group")))
      (when stale (group-record-delete! stale)))
    (let ((id (group-record-create! "prompt-ambient-group"))
          (chat (t--prompt-chat "*prompt-ambient*" "api"))
          (source "prompt-ambient.ex")
          (notes "prompt-ambient.md"))
      (test-buffer! source "def zz_ambient_secret, do: :hidden\n")
      (test-buffer! notes "# ZZ Ambient Heading\nprivate body text\n")
      (chat-set-group! chat id)
      (let ((before (chat-prompt-source-parts chat)))
        (buffer-add-group! source id)
        (buffer-add-group! notes id)
        (buffer-set-local! source 'mode-name "elixir-mode")
        (buffer-set-local! notes 'mode-name "morg-mode")
        (let* ((after (chat-prompt-source-parts chat))
               (context (cadr (assoc "context" after)))
               (live (chat-context chat)))
          (check-equal! after before
                        "group changes do not invalidate the prompt prefix")
          (check-contains! context "(chat-context)"
                           "the static section tells the agent how to pull context")
          (check-true! (member source (plist-get live 'group-members))
                       "chat-context returns the new source member")
          (check-true! (member notes (plist-get live 'group-members))
                       "chat-context returns the new notes member")
          (check-false! (string-contains? (prompt-parts-text after) source)
                        "the system prompt does not hardcode buffer names")
          (check-false! (string-contains? (prompt-parts-text after) "private body text")
                        "the system prompt does not attach member text")))
      (t--prompt-cleanup chat source notes)
      (group-record-delete! id))))

(deftest 'chat-show-prompt-shows-the-direct-prompt-and-its-composition
  "the help page names each section and includes the canonical join"
  (lambda ()
    (let ((chat (t--prompt-chat "*prompt-direct*" "api")))
      (chat-prompt-freeze! chat)
      (with-current-buffer chat (lambda () (run-command "chat-show-prompt")))
      (let ((page (buffer-text "*Help*"))
            (parts (chat-prompt-parts chat)))
        (check-contains! page "`*prompt-direct*` · direct API" "the page names the lane")
        (check-contains! page "## Composition" "the page explains the join")
        (check-contains! page "`general`" "the page names a fragment")
        (check-contains! page "## Final joined text" "the page includes the wire text")
        (check-contains! page "frozen section set" "the page states the lifecycle")
        (check-contains! page (prompt-parts-text parts) "the joined value is exact")
        (check-equal! (chat-prompt-report chat) (chat-prompt-report chat)
                      "recomposition is byte-identical without state changes"))
      (let ((meta (catalog-entry 'command "chat-show-prompt")))
        (check-equal! (plist-get meta 'package) "prompts" "the prompt package owns the command")
        (check-true! (member "display" (plist-get meta 'effects))
                     "the presentation effect is checked-in metadata"))
      (t--prompt-cleanup chat))))

(deftest 'chat-prompt-report-explains-the-acp-session-lifecycle
  "the ACP view distinguishes a prospective prompt from a frozen session"
  (lambda ()
    (let* ((chat (t--prompt-chat "*prompt-acp*" "codex-app-server"))
           (page (chat-prompt-report chat))
           (parts (chat-prompt-parts chat)))
      (check-contains! page "ACP session append" "the page names the ACP lane")
      (check-contains! page "prospective section set"
                       "the page says that the prompt is not frozen yet")
      (check-contains! page "first send freezes it"
                       "the page states the conversation lifecycle")
      (check-equal! (car (car parts)) "identity"
                    "ACP starts with the identity section")
      (check-true! (assoc "context" parts)
                   "ACP receives the context section")
      (t--prompt-cleanup chat))))

(deftest 'modes-compose-named-buffer-local-prompt-fragments
  "set replaces in place; remove leaves the other mode fragments intact"
  (lambda ()
    (let ((buf (test-buffer! "*prompt-modes*" "")))
      (prompt-part-set! buf "first-mode" "first text")
      (prompt-part-set! buf "second-mode" "second text")
      (prompt-part-set! buf "first-mode" "new first text")
      (check-equal! (prompt-buffer-parts buf)
                    '(("first-mode" "new first text")
                      ("second-mode" "second text"))
                    "replacement preserves composition order")
      (prompt-part-remove! buf "first-mode")
      (check-equal! (prompt-buffer-parts buf)
                    '(("second-mode" "second text"))
                    "one mode cannot remove another mode's fragment")
      (check-true! (member 'prompt-parts chat-runtime-locals)
                   "mode setup rebuilds the derived local after restore")
      (t--prompt-cleanup buf))))

(deftest 'a-direct-chat-keeps-its-first-prompt-until-refresh
  "source changes do not alter the wire prompt during a conversation"
  (lambda ()
    (let ((chat (t--prompt-chat "*prompt-frozen-direct*" "api")))
      (prompt-part-set! chat "mode-note" "first prompt")
      (let ((first (chat-system-prompt-parts chat #t)))
        (prompt-part-set! chat "mode-note" "changed prompt")
        (check-equal! (chat-system-prompt-parts chat #t) first
                      "later source changes do not alter the frozen prompt")
        (check-contains! (prompt-parts-text (chat-live-system-prompt-parts chat #t))
                         "changed prompt" "the live source still changes")
        (with-current-buffer chat (lambda () (run-command "chat-refresh-prompt")))
        (check-contains! (prompt-parts-text (chat-prompt-parts chat))
                         "changed prompt" "the command replaces the snapshot"))
      (check-true! (member 'chat-prompt-snapshot chat-conversation-locals)
                   "the snapshot survives restart with the conversation")
      (let ((snapshot (chat-prompt-snapshot chat)))
        (chat-clear-locals! chat chat-runtime-locals)
        (check-equal! (chat-prompt-snapshot chat) snapshot
                      "a runtime sweep preserves the frozen prompt"))
      (chat-clear-locals! chat chat-conversation-locals)
      (check-false! (chat-prompt-snapshot chat) "chat reset clears the snapshot")
      (t--prompt-cleanup chat))))

(deftest 'an-acp-chat-keeps-its-session-prompt-until-refresh
  "ACP and direct chats use the same conversation snapshot contract"
  (lambda ()
    (let* ((chat (t--prompt-chat "*prompt-frozen-acp*" "codex-app-server"))
           (conf (list 'buffer chat 'presets '(compos))))
      (prompt-part-set! chat "mode-note" "first ACP prompt")
      (let ((first (agent-system-prompt-parts conf)))
        (prompt-part-set! chat "mode-note" "changed ACP prompt")
        (check-equal! (agent-system-prompt-parts conf) first
                      "the running session keeps its frozen append")
        (check-contains! (prompt-parts-text (agent-live-system-prompt-parts conf))
                         "changed ACP prompt" "the current sources are inspectable")
        (chat-refresh-prompt! chat)
        (check-contains! (prompt-parts-text (chat-prompt-parts chat))
                         "changed ACP prompt" "refresh replaces the ACP snapshot"))
      (t--prompt-cleanup chat))))

(deftest 'prompt-sections-are-buffer-local-switches
  "both lanes omit disabled sections while inspection still lists them"
  (lambda ()
    (let ((direct (t--prompt-chat "*prompt-switch-direct*" "api"))
          (acp (t--prompt-chat "*prompt-switch-acp*" "codex-app-server")))
      (prompt-parts-set-disabled! direct '("reading"))
      (prompt-parts-set-disabled! acp '("reading"))
      (check-false! (assoc "reading" (chat-prompt-live-parts direct))
                    "the direct wire omits the section")
      (check-false! (assoc "reading" (chat-prompt-live-parts acp))
                    "the ACP wire omits the same section")
      (check-true! (and (assoc "reading" (chat-prompt-source-parts direct)) #t)
                   "inspection retains the available section")
      (check-contains! (chat-prompt-report direct) "○ `reading`"
                       "chat-show-prompt marks it off")
      (t--prompt-cleanup direct acp))))

(deftest 'semantic-sections-separate-reading-code-editing-and-scope
  "general reading stays general; code owns code reads, edits, and versioning"
  (lambda ()
    (let* ((chat (t--prompt-chat "*prompt-taxonomy*" "api"))
           (parts (chat-prompt-source-parts chat))
           (general (cadr (assoc "general" parts)))
           (reading (cadr (assoc "reading" parts)))
           (code (cadr (assoc "code" parts))))
      (check-contains! general "do only as much as the user asked"
                       "general owns task scope")
      (check-contains! general "does not require code changes"
                       "general avoids unnecessary code editing")
      (check-contains! reading "every file as structured content"
                       "reading applies to every file")
      (check-contains! reading "blocks, sections, definitions"
                       "reading names general structure")
      (check-contains! reading "(block-list BUF)"
                       "reading discovers generic fenced blocks")
      (check-contains! reading "(block-at-line BUF LINE)"
                       "reading locates a generic block")
      (check-contains! reading "(block-text BUF LINE)"
                       "reading reads a generic block")
      (check-contains! reading "(block-body BLOCK)"
                       "reading extracts generic block contents")
      (check-false! (string-contains? reading "(code-outline BUF)")
                    "reading does not prescribe the code API")
      (check-false! (string-contains? reading "(markdown-outline BUF)")
                    "reading does not prescribe the writing API")
      (check-contains! code "CODE READING"
                       "code-specific reading belongs to code")
      (check-contains! code "EDITING / VERSIONING"
                       "versioning is inside editing")
      (check-true! (< (string-length general) 2500)
                   "the composed general section stays compact")
      (check-true! (< (string-length code) 3200)
                   "the composed code section stays compact")
      (t--prompt-cleanup chat))))
