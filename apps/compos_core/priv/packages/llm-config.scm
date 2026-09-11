;;; llm-config.scm --- the C-c b menu: one LLM setup, whole.
;;;
;;; transient.scm is the mechanism: prefixes, keys, the frame's menu. This
;;; file is the policy for one menu, the language-model setup that chat-mode
;;; and llm-mode share. It loads after mcp.scm, skills.scm, and prompts.scm,
;;; because its rows read presets, the permission policy, and the prompt
;;; sections. The bundle record itself (llm-bundle-*) lives in editor.scm,
;;; because the chat applies bundles at boot, before any menu exists.

(domain! 'llm)
(effects! '(write))


(define (llm-config--connector buf)
  (llm-bundle-connector (llm-config-core buf)))

(define (llm-config--model buf)
  (llm-bundle-model (llm-config-core buf)))

(define (llm-config--effort buf)
  (llm-bundle-effort (llm-config-core buf)))

(define (llm-config--refresh!)
  (when (transient--active) (transient--render!)))

(define (llm-config--setup! _buf)
  (set-frame-local! 'llm-config-selected #f)
  (set-frame-local! 'llm-config-pending #f))

(define (llm-config--mark-selected!)
  (set-frame-local! 'llm-config-selected #t))

;;; Choosing a bundle does not apply it: it parks it as the frame's pending
;;; choice and the menu stays open, so a wrong letter costs one more letter
;;; and not a whole re-open. The choice applies once, when level one closes.
;;; It carries its own target buffer, because the menu can close from a
;;; child level whose scope is the same buffer but need not be read again.
(define (llm-config--pending) (frame-local 'llm-config-pending))

(define (llm-config--pending-bundle)
  (let ((p (llm-config--pending))) (and (pair? p) (cadr p))))

(define (llm-config--choose-bundle! buf bundle)
  (set-frame-local! 'llm-config-pending (list buf bundle))
  (llm-config--refresh!)
  (message (string-append "selected " (or (llm-bundle-name bundle) "recent setup")
                          " — applies when the menu closes")))

(define (llm-config--commit-pending!)
  (let ((p (llm-config--pending)))
    (set-frame-local! 'llm-config-pending #f)
    (when (pair? p)
      (let ((buf (car p)) (bundle (cadr p)))
        (llm-bundle-apply! buf bundle)
        (llm-config-remember! bundle)
        (set-frame-local! 'llm-config-base (llm-bundle-name bundle))
        (set-frame-local! 'llm-config-selected #f)))))

(define (llm-config--quit! buf)
  (when (frame-local 'llm-config-selected)
    (llm-config-remember! (llm-config-combination buf)))
  (set-frame-local! 'llm-config-selected #f))

;; level one owns the pending choice, so only its exit applies it
(define (llm-config--quit-top! buf)
  (llm-config--commit-pending!)
  (llm-config--quit! buf))

;;; Presets are the tool selection: a preset names MCP servers, and the
;;; servers serve the tools. So the menu picks presets and reports what
;;; they serve; it never offers a tool list of its own.

;; The session buffer a bundle's presets and stance belong to. editor.scm
;; resolves it, because a bundle is written and applied there too.
(define (llm-config--session buf) (llm-config-session buf))

(define (llm-config--presets buf)
  (if (boundp (quote chat-presets-of)) (chat-presets-of buf) '()))

(define (llm-config--presets-label buf)
  (let ((ps (llm-config--presets (llm-config--session buf))))
    (if (null? ps) "none" (string-join (map symbol->string ps) " "))))

;; how many tools one server serves right now, or #f while it connects
(define (llm-config--server-tools server)
  (if (equal? server 'compos)
      (if (boundp (quote llm-tool-specs)) (length (llm-tool-specs)) 0)
      (let ((d (mcp-server-detail (symbol->string server))))
        (and (pair? d)
             (equal? (plist-get d 'status) "ready")
             (length (or (plist-get d 'tools) '()))))))

;; What the presets serve, counted WITHOUT connecting anything: the menu
;; redraws on every keystroke and a connect belongs to a send. A chat
;; freezes its tool list at its first send, so say when the number is the
;; frozen one — that list, not the live surface, is what the model sees.
(define (llm-config--tools-label buf)
  (let* ((session (llm-config--session buf))
         (frozen (buffer-local session 'chat-tool-specs)))
    (cond
      ((pair? frozen)
       (string-append (number->string (length frozen)) " tools · frozen"))
      ((not (boundp (quote chat-active-servers))) "none")
      (else
        (let loop ((servers (chat-active-servers session)) (n 0) (pending 0))
          (if (null? servers)
              (string-append (number->string n) " tools"
                (if (> pending 0)
                    (string-append " · " (number->string pending) " connecting")
                    ""))
              (let ((count (llm-config--server-tools (car servers))))
                (if count
                    (loop (cdr servers) (+ n count) pending)
                    (loop (cdr servers) n (+ pending 1))))))))))

(define-command "llm-config-pick-preset" "Turn a tool preset on or off"
  (lambda ()
    (let ((buf (llm-config--session (transient-scope))))
      (if (not (boundp (quote chat-preset-candidates)))
          (message "No MCP presets — packages/mcp.scm is not loaded")
          (llm-config-read! "Preset: "
            (chat-preset-candidates buf)
            (lambda (name)
              (unless (equal? name "")
                (chat-preset-toggle! buf (string->symbol name))
                (llm-config--refresh!)))
            (lambda () #f))))))

(define (llm-config--prompt-label buf)
  (let ((off (prompt-disabled-parts (llm-config--session buf))))
    (if (null? off)
        "all on"
        (string-append (number->string (length off)) " off"))))

;; One child transient holds a draft. Toggling rows changes only that draft.
;; Apply commits every section once, so a frozen chat reconnects at most once.
(define *llm-config-prompt-keys*
  '("1" "2" "3" "4" "5" "6" "7" "8" "9" "0"
    "q" "w" "e" "r" "t" "y" "u" "o" "p"))

(define (llm-config--prompt-argument name)
  (string-append "--prompt-" name))

(define (llm-config--prompt-items buf)
  (let* ((session (llm-config--session buf))
         (off (prompt-disabled-parts session)))
    (let loop ((parts (chat-prompt-source-parts session))
               (keys *llm-config-prompt-keys*)
               (items '()))
      (if (or (null? parts) (null? keys))
          (reverse items)
          (let* ((part (car parts))
                 (name (car part)))
            (loop (cdr parts) (cdr keys)
              (cons (transient-switch (car keys) name
                      (llm-config--prompt-argument name)
                      'default (not (member name off)))
                    items)))))))

(define (llm-config--prompt-groups buf)
  (list
    (cons "Sections" (llm-config--prompt-items buf))
    (list "Selection"
      (transient-suffix "a" "Turn all on" "llm-config-prompt-all"
        'transient 'stay)
      (transient-suffix "n" "Turn all off" "llm-config-prompt-none"
        'transient 'stay)
      (transient-suffix "x" "Apply selection" "llm-config-apply-prompt-sections"
        'transient 'stay))))

(define (llm-config--prompt-set-draft! enabled?)
  (let ((buf (llm-config--session (transient-scope))))
    (for-each
      (lambda (part)
        (transient--set-value! (llm-config--prompt-argument (car part)) enabled?))
      (chat-prompt-source-parts buf))))

(define-command "llm-config-prompt-all" "Turn on every prompt section in this draft"
  (lambda () (llm-config--prompt-set-draft! #t)))

(define-command "llm-config-prompt-none" "Turn off every prompt section in this draft"
  (lambda () (llm-config--prompt-set-draft! #f)))

(define-command "llm-config-apply-prompt-sections" "Apply all selected prompt sections"
  (lambda ()
    (let* ((buf (llm-config--session (transient-scope)))
           (parts (chat-prompt-source-parts buf))
           (off
             (let loop ((rest parts) (out '()))
               (if (null? rest)
                   (reverse out)
                   (let ((name (car (car rest))))
                     (loop (cdr rest)
                       (if (transient-value (llm-config--prompt-argument name))
                           out
                           (cons name out))))))))
      (chat-prompt-sections-set! buf off)
      (llm-config--mark-selected!)
      (run-command "transient-quit-one")
      (message "Prompt sections applied"))))

(transient-define-prefix "llm-prompt-sections"
  "Select the prompt sections, then apply them together"
  llm-config--prompt-groups)

(define-command "llm-config-pick-backend" "Choose the LLM backend"
  (lambda ()
    (let* ((buf (transient-scope))
           (current (llm-config--connector buf)))
      (llm-config-read! "Backend: "
        (llm-config-current-first
          (map (lambda (c)
                 (let ((models (length (chat-model-options buf c))))
                   (llm-config-row c (connector-description c)
                     (list (list "backend" (connector-description c))
                           (list "models"
                                 (if (= models 0) "asks the backend"
                                     (string-append (number->string models) " known")))
                           (list "model" (if (equal? c current) (llm-config--model buf) "default"))))))
               (connector-names))
          current)
        (lambda (choice)
          (unless (equal? choice "")
            (llm-config-apply! buf choice "default" "default")
            (llm-config--mark-selected!)
            (llm-config--refresh!)))
        (lambda () #f)
        "RET switches the backend and resets the model and effort to its defaults. The conversation carries over."))))

(define-command "llm-config-pick-model" "Choose the LLM model"
  (lambda ()
    (let* ((buf (transient-scope))
           (connector (llm-config--connector buf))
           (current (llm-config--model buf)))
      ;; the direct lane offers every model a provider lists, so a day-old
      ;; catalog refreshes behind this list for the next time
      (when (and (equal? connector "api")
                 (boundp (quote llm-catalog-maybe-refresh!)))
        (llm-catalog-maybe-refresh!))
      (llm-config-read! "Model: "
        (llm-config-current-first
          (cons (llm-config-row "default" "connector default"
                  (list (list "backend" connector) (list "model" "the backend's own default")))
                (map (lambda (row) (llm-config--model-row buf connector row))
                     (chat-model-options buf connector)))
          current)
        (lambda (model)
          (unless (equal? model "")
            (llm-config-apply! buf connector model "default")
            (llm-config--mark-selected!)
            (llm-config--refresh!)))
        (lambda () #f)
        (string-append "RET sets the model on " connector
                       " and resets the effort to the model's default.")))))

;; one model row with the facts the rail shows: backend, provider prefix,
;; and the reasoning efforts the catalog or the live backend lists for it
(define (llm-config--model-row buf connector row)
  (let* ((id (car row))
         (hint (if (pair? (cdr row)) (cadr row) ""))
         (info (chat-model-effort-info buf connector id))
         (efforts (car info))
         (colon (string-index id ":")))
    (llm-config-row id hint
      (append
        (list (list "backend" connector))
        (if colon (list (list "provider" (substring id 0 colon))) '())
        (if (equal? hint "") '() (list (list "name" hint)))
        (list (list "efforts" (if (null? efforts) "none listed" (string-join efforts " "))))))))

(define-command "llm-config-pick-effort" "Choose the LLM reasoning effort"
  (lambda ()
    (let* ((buf (transient-scope))
           (connector (llm-config--connector buf))
           (model (llm-config--model buf))
           (current (llm-config--effort buf))
           (info (chat-model-effort-info buf connector model))
           (efforts (car info))
           (default (cadr info)))
      (llm-config-read! "Effort: "
        (llm-config-current-first
          (cons (llm-config-row "default"
                  (if (equal? default "") "model default"
                      (string-append "model default: " default))
                  (list (list "model" model)
                        (list "effort" (if (equal? default "") "the model decides" default))))
                (map (lambda (e)
                       (llm-config-row e "reasoning effort"
                         (list (list "model" model) (list "effort" e))))
                     efforts))
          current)
        (lambda (effort)
          (unless (equal? effort "")
            (llm-config-apply! buf connector model effort)
            (llm-config--mark-selected!)
            (llm-config--refresh!)))
        (lambda () #f)
        (string-append "RET sets how hard " (if (equal? model "default") connector model)
                       " reasons. More effort costs more time and tokens.")))))

;;; --- what stops to ask ----------------------------------------------------
;;; Permissions are part of the setup, not a separate subject: the same
;;; menu that chooses the model chooses what that model may do without
;;; asking. Three controls, and they are not the same control: the stance
;;; is compos's own policy, the agent mode is the backend's (ACP names it,
;;; and plan mode changes what a turn DOES), and the file switch says
;;; whether the agent may go around buffers to the filesystem.

(define (llm-config--permission-label buf)
  (symbol->string (llm-config-permission (llm-config--session buf))))

(define (llm-config--agent-mode-label buf)
  (let ((m (buffer-local (llm-config--session buf) 'agent-mode)))
    (if (or (not m) (equal? m "")) "none" m)))

;; the modes this buffer's backend can actually be put in. Empty for a
;; backend with no ACP session at all, and for one whose modes no session
;; has named yet: the row is hidden then, so `a` never sits there dead
(define (llm-config--agent-modes buf)
  (if (and buf (boundp (quote agent-mode-options)))
      (agent-mode-options (llm-config--session buf))
      '()))

(define (llm-config--filesystem)
  (if (boundp (quote agent-filesystem-tools)) agent-filesystem-tools "deny"))

(define-command "llm-config-pick-permission" "Choose when this session stops to ask"
  (lambda ()
    (let ((buf (llm-config--session (transient-scope))))
      (if (not (boundp (quote chat-permission-mode-set!)))
          (message "No permission policy — packages/agent-permissions.scm is not loaded")
          (llm-config-read! "Asks: "
            (llm-config-current-first
              (map (lambda (m) (list (symbol->string m)
                                     (chat-permission-mode-note m)))
                   *permission-modes*)
              (symbol->string (llm-config-permission buf)))
            (lambda (choice)
              (unless (equal? choice "")
                (chat-permission-mode-set! buf (string->symbol choice))
                (llm-config--mark-selected!)
                (llm-config--refresh!)))
            (lambda () #f))))))

(define-command "llm-config-pick-agent-mode" "Choose the agent session's own mode"
  (lambda ()
    (let* ((buf (llm-config--session (transient-scope)))
           (modes (llm-config--agent-modes buf)))
      (if (null? modes)
          (message "this backend has no session modes")
          (llm-config-read! "Agent mode: "
            (llm-config-current-first
              modes (or (buffer-local buf 'agent-mode) ""))
            (lambda (choice)
              (unless (equal? choice "")
                (if (agent-mode-set! buf choice)
                    (begin (llm-config--mark-selected!)
                           (llm-config--refresh!))
                    (message "the agent refused that mode"))))
            (lambda () #f))))))

(define-command "llm-config-pick-filesystem" "Choose what the agent's own file tools may do"
  (lambda ()
    (llm-config-read! "Agent file tools: "
      (llm-config-current-first
        (list (list "deny" "the agent edits buffers, and saves them")
              (list "ask" "each direct write asks first")
              (list "allow" "the agent writes files itself"))
        (llm-config--filesystem))
      (lambda (choice)
        (unless (equal? choice "")
          (customize-save! 'agent-filesystem-tools choice)
          (llm-config--refresh!)))
      (lambda () #f))))

;; the report never covers the chat that asked for it
(add-display-rule! "*permissions*" 'popup)

(define-command "llm-config-permission-report"
  "Show everything this session's permission policy does"
  (lambda ()
    (let ((buf (llm-config--session (transient-scope))))
      (if (not (boundp (quote permission-policy-report)))
          (message "No permission policy — packages/agent-permissions.scm is not loaded")
          (let ((out "*permissions*"))
            (buffer-create out)
            (buffer-set-read-only! out #f)
            (buffer-delete-range! out 0 (buffer-size out))
            (buffer-append! out (permission-policy-report buf))
            (buffer-set-read-only! out #t)
            (display-buffer out))))))

;;; --- bundles --------------------------------------------------------------

;; `t` opens this child menu: the tool surface as menu rows over the
;; same scope, not a buffer covering the chat. A digit echoes one
;; server's tools; l is the full text list for actual reading.
(define (llm-config--chat-servers session)
  (let ((frozen (buffer-local session 'chat-tool-specs)))
    (if (pair? frozen)
        (let loop ((specs frozen) (acc '()))
          (if (null? specs) (reverse acc)
              (loop (cdr specs)
                    (let ((s (chat-tool-server (car (car specs)))))
                      (if (member s acc) acc (cons s acc))))))
        (map symbol->string (chat-active-servers session)))))

(define (llm-config--server-row-count session server)
  ;; never connects: the frozen list counts itself, a live server is
  ;; only read through the registry's detail
  (let ((frozen (buffer-local session 'chat-tool-specs)))
    (if (pair? frozen)
        (length (filter (lambda (s) (equal? (chat-tool-server (car s)) server))
                        frozen))
        (llm-config--server-tools (string->symbol server)))))

(define (llm-config--server-tool-names session server)
  (let ((frozen (buffer-local session 'chat-tool-specs)))
    (cond
      ((pair? frozen)
       (map car (filter (lambda (s) (equal? (chat-tool-server (car s)) server))
                        frozen)))
      ((and (equal? server "compos") (boundp (quote llm-tool-specs)))
       (map car (llm-tool-specs)))
      (else
        (let ((d (mcp-server-detail server)))
          (map (lambda (t) (if (pair? t) (car t) t))
               (or (and (pair? d) (plist-get d 'tools)) '())))))))

(define (llm-config--tools-groups buf)
  (let* ((session (llm-config--session buf))
         (can (boundp (quote chat-tool-server)))
         (servers (if can (llm-config--chat-servers session) '())))
    (append
      (if (null? servers)
          '()
          (list
            (cons (string-append "Servers · " (llm-config--tools-label buf))
              (let loop ((ss servers) (k 1) (acc '()))
                (if (or (null? ss) (> k 9))
                    (reverse acc)
                    (loop (cdr ss) (+ k 1)
                      (cons
                        (let ((server (car ss)))
                          (transient-suffix (number->string k) server
                            (lambda ()
                              (let ((names (llm-config--server-tool-names session server)))
                                (message
                                  (string-append server ": "
                                    (if (null? names)
                                        "no tools yet — still connecting?"
                                        (string-join names ", "))))))
                            'transient 'stay
                            'value-fn
                            (lambda (_scope)
                              (let ((n (llm-config--server-row-count session server)))
                                (if n
                                    (string-append (number->string n) " tools")
                                    "connecting")))))
                        acc)))))))
      (list
        (list "Change"
          (transient-infix "p" "Presets" "llm-config-pick-preset"
            (lambda (scope) (llm-config--presets-label scope)))
          (transient-suffix "r" "Adopt the editor's live tools" "chat-refresh-tools")
          (transient-suffix "l" "The full list, with docs" "chat-tool-list"))))))

(transient-define-prefix "chat-tools"
  "This chat's tool surface"
  llm-config--tools-groups)

(define (llm-config--bundle-candidates)
  (map (lambda (b) (list (or (llm-bundle-name b) "?") (llm-bundle-label b)))
       *llm-bundles*))

(define-command "llm-config-save-bundle" "Save this whole setup as a named bundle"
  (lambda ()
    (let ((buf (transient-scope)))
      ;; the setup saved is the one on screen, so a pending choice lands first
      (llm-config--commit-pending!)
      ;; a free-text prompt, not a palette: the point is to type a NEW name,
      ;; and the saved ones complete so that saving over one is easy
      (minibuffer-read "Bundle name: " (llm-config--bundle-candidates)
        (lambda (name)
          (let ((n (string-trim name)))
            (unless (equal? n "")
              (llm-bundle-save! n (llm-config-combination buf))
              (llm-config--refresh!)
              (message (string-append "bundle " n ": "
                         (llm-bundle-label (llm-bundle-named n)))))))))))

(define-command "llm-config-use-bundle" "Select a saved bundle by name"
  (lambda ()
    (let ((buf (transient-scope)))
      (if (null? *llm-bundles*)
          (message "no saved bundles — s saves this setup as one")
          (llm-config-read! "Bundle: " (llm-config--bundle-candidates)
            (lambda (name)
              (let ((b (and (not (equal? name "")) (llm-bundle-named name))))
                (when b (llm-config--choose-bundle! buf b))))
            (lambda () #f))))))

(define-command "llm-config-forget-bundle" "Forget a saved bundle"
  (lambda ()
    (if (null? *llm-bundles*)
        (message "no saved bundles")
        (llm-config-read! "Forget bundle: " (llm-config--bundle-candidates)
          (lambda (name)
            (unless (equal? name "")
              (llm-bundle-forget! name)
              (llm-config--refresh!)
              (message (string-append "bundle " name " forgotten"))))
          (lambda () #f)))))

;;; The bundle a new chat starts with. It is a setting like any other, so it
;;; lands in custom.scm, survives a restart, and can be edited by hand. ""
;;; means no default: a new chat keeps whatever it inherits.
(defgroup 'llm "The language model a chat talks to.")

(defcustom 'llm-default-bundle ""
  "The saved bundle every new chat starts with. Empty means no default."
  'group 'llm 'type 'string)

(define (llm-default-bundle-record)
  (and (string? llm-default-bundle)
       (not (equal? llm-default-bundle ""))
       (llm-bundle-named llm-default-bundle)))

;;; A new chat has no agent session yet, so its locals are the whole setup:
;;; the session reads them when it attaches on the first send. Going through
;;; llm-bundle-apply! here would attach the connector at once, and every new
;;; chat would start a process before the user had typed anything.
(define (llm-default--seed! buf b)
  (buffer-set-local! buf 'agent-connector (llm-bundle-connector b))
  (let ((m (llm-bundle-model b)))
    (buffer-set-local! buf 'agent-model (if (equal? m "default") #f m)))
  (let ((e (llm-bundle-effort b)))
    (buffer-set-local! buf 'agent-effort (if (equal? e "default") #f e)))
  (let ((k (llm-bundle-permission b)))
    (when (and k (boundp 'chat-permission-mode-set!))
      (chat-permission-mode-set! buf (string->symbol k))))
  (let ((p (llm-bundle-presets b)))
    (when (and p (boundp 'chat-presets-set!))
      (chat-presets-set! buf p)))
  (let ((off (llm-bundle-prompt-disabled b)))
    (when (and off (boundp 'chat-prompt-sections-set!))
      (chat-prompt-sections-set! buf off)))
  (let ((mode (llm-bundle-agent-mode b)))
    (when (and mode (not (equal? mode "")) (boundp 'agent-mode-set!))
      (agent-mode-set! buf mode)))
  (when (boundp 'agent-update-modeline!) (agent-update-modeline! buf))
  b)

(define (llm-default-bundle-apply! buf)
  (let ((b (llm-default-bundle-record)))
    (cond ((not b) #f)
          ((buffer-local buf 'agent-slug) (llm-bundle-apply! buf b))
          (else (llm-default--seed! buf b)))))

(public! 'llm-default-bundle-apply!
  "(llm-default-bundle-apply! BUF) — put llm-default-bundle's setup on a new chat; #f when no default is named")

(define-command "llm-config-save-default" "Make this bundle the default for new chats"
  (lambda ()
    (let* ((buf (transient-scope))
           (b (or (llm-config--pending-bundle) (llm-config--base buf)))
           (name (and b (llm-bundle-name b))))
      (if (not name)
          (message "no saved bundle here — save one first with s")
          (begin
            (customize-save! 'llm-default-bundle name)
            (llm-config--refresh!)
            (message (string-append "new chats start with " name)))))))

(define (llm-config--history-key index)
  (if (= index 10) "0" (number->string index)))

(define (llm-config--history-items buf)
  (let loop ((choices *llm-config-history*) (index 1) (items '()))
    (if (null? choices)
        (reverse items)
        (let ((choice (llm-bundle-normalize (car choices))))
          (loop (cdr choices) (+ index 1)
            (cons
              (transient-suffix
                (llm-config--history-key index)
                (llm-bundle-label choice)
                (lambda () (llm-config--choose-bundle! buf choice))
                'transient 'stay 'bundle choice
                'value-fn (lambda (_scope)
                            (if (equal? (llm-config--pending-bundle) choice)
                                "selected" "")))
              items))))))

(define (llm-config--bundle-items buf)
  (let loop ((bs *llm-bundles*) (items '()))
    (if (null? bs)
        (reverse items)
        (let* ((b (car bs)) (key (llm-bundle-key b)))
          (loop (cdr bs)
            (if key
                (cons
                  (transient-suffix key
                    (or (llm-bundle-name b) "?")
                    (lambda () (llm-config--choose-bundle! buf b))
                    'transient 'stay 'bundle b
                    'value-fn (lambda (scope)
                                (llm-config--bundle-value scope b)))
                  items)
                items))))))

;;; Two facts share one cell: what this bundle is to the session at hand,
;;; and whether it is the one new chats start with.
(define (llm-config--bundle-value scope b)
  (let ((state (cond ((llm-config--pending-bundle)
                      (if (equal? (llm-config--pending-bundle) b)
                          "selected" ""))
                     ((llm-config--bundle-active? scope b) "active")
                     (else "")))
        (default (if (equal? (llm-bundle-name b) llm-default-bundle)
                     "default" "")))
    (cond ((equal? state "") default)
          ((equal? default "") state)
          (else (string-append state " · " default)))))

;;; --- two levels ------------------------------------------------------------
;;; Picking a bundle and tuning one field are two different acts, so they
;;; are two levels of one menu. Level one (C-c b) is the saved bundles on
;;; letters and the recent setups on digits: one key selects the whole
;;; setup, the menu stays open, and closing it applies the last selection.
;;; The rail on the right says what the highlighted row resolves to, and
;;; marks in amber what would change.
;;; Level two (.) is the fields. Its rail compares the live setup with the
;;; base bundle, and u goes back to it.

;; BUF's live setup as one normalized bundle, with no name
(define (llm-config--current buf)
  (llm-bundle-normalize (llm-config-combination buf)))

;; the saved bundle whose setup equals BUF's live setup, or #f
;; The live setup is read once for the whole walk: llm-config--current
;; asks the session, and the session is a buffer scan. Six bundles read
;; it six times, after every command, in the dashboard sync.
(define (llm-config--matching-bundle buf)
  (let ((cur (llm-config--current buf)))
    (let loop ((bs *llm-bundles*))
      (cond ((null? bs) #f)
            ((llm-config--bundle-active-against? cur (car bs)) (car bs))
            (else (loop (cdr bs)))))))

(define (llm-config--optional-match? want have)
  (or (not want) (equal? want have)))

;;; A bundle can leave a field unspecified, and llm-bundle-apply! then skips
;;; it and leaves the buffer's own value alone: presets, permission and
;;; prompt-disabled when #f, and agent-mode when #f or "". Such a field must
;;; not count against the match, or a bundle that deliberately leaves the
;;; agent mode alone reads as inactive the moment it is applied.
(define (llm-config--bundle-active? buf b)
  (llm-config--bundle-active-against? (llm-config--current buf) b))

;; CUR is the normalized live setup, read once by the caller
(define (llm-config--bundle-active-against? cur b)
  (let ((nb (llm-bundle-normalize b)))
    (and (equal? (llm-bundle-connector nb) (llm-bundle-connector cur))
         (equal? (llm-bundle-model nb) (llm-bundle-model cur))
         (equal? (llm-bundle-effort nb) (llm-bundle-effort cur))
         (llm-config--optional-match? (llm-bundle-presets nb)
                                      (llm-bundle-presets cur))
         (llm-config--optional-match? (llm-bundle-permission nb)
                                      (llm-bundle-permission cur))
         (or (equal? (llm-bundle-agent-mode nb) "")
             (llm-config--optional-match? (llm-bundle-agent-mode nb)
                                          (llm-bundle-agent-mode cur)))
         (llm-config--optional-match? (llm-bundle-prompt-disabled nb)
                                      (llm-bundle-prompt-disabled cur)))))

;; the bundle the fine-tune level measures drift against: the one applied
;; last in this frame, else the one the live setup equals, else #f
(define (llm-config--base buf)
  (let ((name (frame-local 'llm-config-base)))
    (or (and (string? name) (llm-bundle-named name))
        (llm-config--matching-bundle buf))))

(define (llm-config--base-name buf)
  (let ((b (llm-config--base buf)))
    (and b (llm-bundle-name b))))

;;; The name the dashboard line shows. It follows the buffer's own setup, not
;;; the frame's last choice, so a chat that drifted off its bundle names no
;;; preset and every other buffer keeps its own answer.
(define (llm-config-preset-name buf)
  (let ((b (llm-config--matching-bundle buf)))
    (and b (llm-bundle-name b))))

;; one field of a bundle as the rail shows it
(define (llm-config--field-text key b)
  (let ((v (llm-bundle-get b key #f)))
    (cond
      ((equal? key 'presets)
       (cond ((not v) "as is")
             ((null? v) "none")
             (else
               (let ((extra (remove (lambda (x) (equal? x 'compos)) v)))
                 (if (null? extra) "editor only"
                     (string-join (map symbol->string extra) " "))))))
      ((equal? key 'prompt-disabled)
       (cond ((not v) "as is")
             ((null? v) "all on")
             (else (string-append (number->string (length v)) " off"))))
      ((equal? key 'agent-mode)
       (if (or (not v) (equal? v "") (equal? v "default")) "none" v))
      ((equal? key 'permission) (or v "as is"))
      ((equal? key 'connector) (or v *default-connector*))
      (else (or v "default")))))

(define *llm-config-fields*
  '((connector "backend") (model "model") (effort "effort") (presets "tools")
    (permission "asks") (agent-mode "agent mode") (prompt-disabled "prompt")))

;; A bundle that recorded no presets, stance, agent mode, or prompt
;; exceptions changes none of them when it applies.
(define (llm-config--unrecorded? key b)
  (and (member key '(presets permission agent-mode prompt-disabled))
       (not (llm-bundle-get b key #f))))

;; The rail rows for bundle B. A row whose value differs from AGAINST
;; carries the drift tone; with no AGAINST every row is plain. A field B
;; never recorded shows AGAINST's value, dimmed: applying B keeps it.
(define (llm-config--rows b against)
  (map (lambda (field)
         (let* ((key (car field))
                (v (llm-config--field-text key b))
                (o (and against (llm-config--field-text key against))))
           (cond ((and against (llm-config--unrecorded? key b))
                  (list (cadr field) o "dim"))
                 ((and against (llm-config--unrecorded? key against))
                  (list (cadr field) v ""))
                 ((and against (not (equal? v o)))
                  (list (cadr field) v "drift"))
                 (else (list (cadr field) v "")))))
       *llm-config-fields*))

(define (llm-config--drift-count b against)
  (length (filter (lambda (row) (equal? (caddr row) "drift"))
                  (llm-config--rows b against))))

;; what the menu writes to: this buffer, or the group chat whose session
;; the buffer shares
(define (llm-config--target buf)
  (let ((session (llm-config--session buf)))
    (if (equal? session buf) "this buffer" (string-append "chat " session))))

(define (llm-config--context buf)
  (let* ((g (and (boundp (quote buffer-group)) (buffer-group buf)))
         (gname (and g (boundp (quote group-name)) (group-name g))))
    (string-append (if (string? gname) (string-append "group " gname " · ") "")
                   (llm-config--target buf))))

(define (llm-config--subtitle buf)
  (let ((p (llm-config--pending-bundle))
        (m (llm-config--matching-bundle buf)))
    (cond
      (p (string-append "selected " (or (llm-bundle-name p) "recent setup")
                        " · applies on close"))
      (m (string-append "on bundle " (or (llm-bundle-name m) "?")))
      (else (string-append "off-bundle · " (llm-bundle-label (llm-config--current buf)))))))

;; the rail of level one follows the highlighted row
(define (llm-config--detail buf item)
  (let* ((current (llm-config--current buf))
         (b (and item (plist-get item 'bundle))))
    (if b
        (let* ((nb (llm-bundle-normalize b))
               (name (llm-bundle-name nb))
               (n (llm-config--drift-count nb current)))
          (list (or name "recent setup")
                (llm-config--rows nb current)
                (string-append
                  (if (equal? (llm-config--pending-bundle) b)
                      (string-append "selected · applies to " (llm-config--target buf)
                                     " when the menu closes")
                      (string-append "RET selects " (or name "it") " for "
                                     (llm-config--target buf)))
                  (cond ((= n 0) "\nnothing changes: this is the live setup")
                        ((= n 1) "\n1 field changes")
                        (else (string-append "\n" (number->string n) " fields change"))))))
        (list "live setup"
              (llm-config--rows current #f)
              (let ((m (llm-config--matching-bundle buf)))
                (if m
                    (string-append "equal to bundle " (or (llm-bundle-name m) "?"))
                    ". tunes it field by field\ns saves it as a bundle"))))))

(define (llm-config--key-span items)
  (let ((keys (map (lambda (i) (plist-get i 'key)) items)))
    (cond ((null? keys) #f)
          ((null? (cdr keys)) (car keys))
          (else (string-append (car keys) "…" (car (reverse keys)))))))

(define (llm-config--legend buf)
  (let ((bundles (llm-config--key-span (llm-config--bundle-items buf)))
        (recent (llm-config--key-span (llm-config--history-items buf))))
    (append
      (if bundles (list (list bundles "bundle")) '())
      (if recent (list (list recent "recent")) '())
      (list (list "." "fine-tune") (list "s" "save"))
      (if (null? *llm-bundles*) '() (list (list "D" "default")))
      (list (list "RET" "select")
            (list "↑↓ ←→" "move")
            (if (llm-config--pending-bundle)
                (list "ESC" "apply and close")
                (list "ESC" "dismiss"))))))

;; Bundles, then the setup actions, then the recents: the groups pack
;; column-wise on screen, so the short groups share the first column and
;; the long recent list takes the second.
(define (llm-config--groups buf)
  (let ((bundles (llm-config--bundle-items buf))
        (history (llm-config--history-items buf)))
    (append
      (list (cons "Bundles" bundles))
      (list
        (append
          (list "Setup"
            (transient-suffix "." "fine-tune" "llm-fine-tune")
            (transient-suffix "s" "save as bundle" "llm-config-save-bundle"
              'transient 'stay))
          (if (null? *llm-bundles*)
              '()
              (list (transient-suffix "D" "default for new chats"
                      "llm-config-save-default" 'transient 'stay)
                    (transient-suffix "u" "use by name" "llm-config-use-bundle"
                      'transient 'stay)
                    (transient-suffix "x" "forget" "llm-config-forget-bundle"
                      'transient 'stay)))))
      (if (null? history) '() (list (cons "Recent" history))))))

;; The groups fn is looked up by name on every render, not captured once:
;; a hot reload of llm-config--groups then reaches the open menu, and the
;; prefix form itself does not have to change.
(transient-define-prefix "llm-configure"
  "Language model"
  (lambda (buf) (llm-config--groups buf))
  'columns '(("Bundles" "Setup") ("Recent"))
  'on-setup llm-config--setup!
  'on-quit llm-config--quit-top!
  'subtitle-fn llm-config--subtitle
  'context-fn llm-config--context
  'detail-fn llm-config--detail
  'legend-fn llm-config--legend)

;;; level two: the fields

(define (llm-fine-tune--setup! buf)
  ;; a choice at level one is the base this level tunes from, so it lands first
  (llm-config--commit-pending!)
  (let ((base (llm-config--base buf)))
    (set-frame-local! 'llm-config-base (and base (llm-bundle-name base)))))

(define-command "llm-config-revert" "Put the base bundle back, every field"
  (lambda ()
    (let* ((buf (transient-scope))
           (base (llm-config--base buf)))
      (if (not base)
          (message "no base bundle to revert to")
          (begin
            (llm-bundle-apply! buf base)
            (llm-config--mark-selected!)
            (llm-config--refresh!)
            (message (string-append "reverted to " (or (llm-bundle-name base) "?"))))))))

(define (llm-fine-tune--subtitle buf)
  (let ((base (llm-config--base-name buf)))
    (if base
        (string-append "field by field · base " base)
        "field by field · no base bundle")))

(define (llm-fine-tune--detail buf _item)
  (let* ((current (llm-config--current buf))
         (base (llm-config--base buf))
         (n (if base (llm-config--drift-count current (llm-bundle-normalize base)) 0)))
    (list (if base (string-append "against " (or (llm-bundle-name base) "?")) "unsaved setup")
          (llm-config--rows current (and base (llm-bundle-normalize base)))
          (cond ((not base) "no bundle equals this setup\ns saves it under a name")
                ((= n 0) (string-append "identical to " (or (llm-bundle-name base) "?")))
                (else (string-append (number->string n)
                        (if (= n 1) " field differs" " fields differ")
                        " · u reverts · s saves as a bundle"))))))

(define (llm-fine-tune--legend _buf)
  '(("b m e" "model") ("p t" "tools") ("i v" "prompt") ("k a f d" "asks")
    ("u" "revert") ("s" "save") ("↑↓ ←→" "move") ("ESC" "up")))

(define (llm-fine-tune--groups buf)
  (list
    (list "Model"
      (transient-infix "b" "backend" "llm-config-pick-backend"
        (lambda (scope) (llm-config--connector scope)))
      (transient-infix "m" "model" "llm-config-pick-model"
        (lambda (scope) (llm-config--model scope)))
      (transient-infix "e" "effort" "llm-config-pick-effort"
        (lambda (scope) (llm-config--effort scope))))
    (list "Tools"
      (transient-infix "p" "presets" "llm-config-pick-preset"
        (lambda (scope) (llm-config--presets-label scope)))
      (transient-suffix "t" "tools" "chat-tools"
        'value-fn (lambda (scope) (llm-config--tools-label scope))))
    (list "Prompt"
      (transient-suffix "i" "sections" "llm-prompt-sections"
        'value-fn (lambda (scope) (llm-config--prompt-label scope)))
      (transient-suffix "v" "show prompt" "chat-show-prompt" 'transient 'stay))
    (list "Permissions"
      (transient-infix "k" "asks" "llm-config-pick-permission"
        (lambda (scope) (llm-config--permission-label scope)))
      (transient-infix "a" "agent mode" "llm-config-pick-agent-mode"
        (lambda (scope) (llm-config--agent-mode-label scope))
        'if (lambda (scope) (pair? (llm-config--agent-modes scope))))
      (transient-infix "f" "files" "llm-config-pick-filesystem"
        (lambda (_scope) (llm-config--filesystem)))
      (transient-suffix "d" "policy" "llm-config-permission-report"
        'value-fn (lambda (_scope)
                    (if (boundp (quote *permission-deny-patterns*))
                        (string-append (number->string
                                         (length *permission-deny-patterns*))
                                       " deny patterns")
                        ""))))
    (list "Setup"
      (transient-suffix "u"
        (let ((base (llm-config--base-name buf)))
          (if base (string-append "revert to " base) "revert"))
        "llm-config-revert" 'transient 'stay)
      (transient-suffix "s" "save as bundle" "llm-config-save-bundle"
        'transient 'stay))))

(transient-define-prefix "llm-fine-tune"
  "Fine-tune"
  (lambda (buf) (llm-fine-tune--groups buf))
  'columns '(("Model" "Tools" "Prompt") ("Permissions" "Setup"))
  'on-setup llm-fine-tune--setup!
  'on-quit llm-config--quit!
  'subtitle-fn llm-fine-tune--subtitle
  'context-fn llm-config--context
  'detail-fn llm-fine-tune--detail
  'legend-fn llm-fine-tune--legend)
