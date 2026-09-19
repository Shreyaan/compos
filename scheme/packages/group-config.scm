;;; group-config.scm -- the AI setup a group shares with its chats.
;;;
;;; A group keeps one config file in its home, <group-home>/ai-config.scm. It
;;; is ordinary Scheme -- the same language, and the same job, as the global
;;; ~/.compos/ai-config.scm -- and it runs with the chat it configures
;;; current. So it says what it wants the plain way:
;;;
;;;     (buffer-set-local! (current-buffer) 'agent-model "opus[1m]")
;;;     (chat-presets-set! (current-buffer) '(compos jj))
;;;     (llm-bundle-apply! (current-buffer) (llm-bundle-named "pair"))
;;;
;;; init.scm and ~/.compos/ai-config.scm still decide the global defaults; a
;;; group narrows them for its own chats:
;;;
;;;     ~/.compos/ai-config.scm -> <group-home>/ai-config.scm -> the chat
;;;
;;; A chat runs the group's config ONCE, when it first joins the group. After
;;; that the chat is its own: nothing re-runs the file behind the user's back,
;;; however the file or the chat changes later. Two commands ask for it out
;;; loud -- chat-load-config for this chat, group-reload-config for every chat
;;; in the group.

(domain! 'buffers)
(effects! '(write execute))

(define (group-config-file g)
  (string-append (group-home-dir g) "/ai-config.scm"))

;; A group chat wears chat-mode only after it is created, so its name has to
;; answer for it: the config has to reach the buffer before that.
(define (group-config-chat? buf)
  (or (chat-buffer? buf) (string-prefix? "*chat:" buf)))

;; the group whose config this buffer has already run, or #f. It is one of
;; chat-identity-locals, so a chat still knows after a restart.
(define (group-config-loaded buf)
  (and buf (buffer-known? buf) (buffer-local buf 'group-config-loaded)))

(define (group-config-run! buf id path)
  ;; the file is ordinary Scheme and runs with BUF current, so (current-buffer)
  ;; inside it is the chat being configured.
  (let ((result (with-current-buffer buf
                  (lambda () (eval-string-safe (read-file path))))))
    (cond
      ((equal? (car result) 'ok)
       (buffer-set-local! buf 'group-config-loaded id)
       (when (boundp 'agent-update-modeline!) (agent-update-modeline! buf))
       #t)
      (else
        (message (string-append (group-name id) " ai-config.scm: "
                                (value->string (car (cdr result)))))
        #f))))

;; Run the group's config on BUF whether or not it has run there before. The
;; two commands below call this; nothing else asks for it unprompted.
(define (group-config-apply! buf)
  (let* ((id (and buf (buffer-known? buf) (group-resolve-id (buffer-group buf))))
         (path (and id (group-config-file id))))
    (and id
         (group-config-chat? buf)
         (file-exists? path)
         (group-config-run! buf id path))))

;;; The group's working directory.
;;;
;;; A group is a quasi-application: its own buffers, its own home, and its
;;; own working directory. That directory belongs to the group, not to any
;;; buffer in it -- the 'cwd setting when it differs from where the group
;;; was founded, the group's origin otherwise. It outlives every buffer
;;; that borrows it, and a restart.
;;;
;;; A buffer takes it only when nothing on the buffer already answers: a
;;; file buffer's directory is its file's, and stays that way.

(define (group-cwd-slash dir)
  (if (string-suffix? dir "/") dir (string-append dir "/")))

(define (group-cwd g)
  (let* ((id (group-resolve-id g))
         (record (and id (group-record-by-id id)))
         (dir (and record (or (group-setting id 'cwd)
                              (group-record-origin record)))))
    (and (string? dir) (file-directory? dir) (group-cwd-slash dir))))

;; Mirrors the cond in buffer-directory: a buffer takes the group's directory
;; only when nothing fixes it already. dired answers with the directory it
;; lists and a file buffer with its file's -- neither is ours to move. The
;; companion branch is not a rival: 'chat-directory IS the per-buffer cwd,
;; and it is what we write.
(define (buffer-takes-cwd? buf)
  (and buf (buffer-known? buf)
       (not (dired-buffer? buf))
       (not (buffer-path buf))
       (not (string-prefix? "/" buf))))

;; Hand the group's directory to one buffer. A buffer with an agent on it
;; moves the agent too; anything else just learns where it works.
(define (group-cwd-apply! buf)
  (let ((dir (and (buffer-takes-cwd? buf) (group-cwd (buffer-group buf)))))
    (cond
      ((not dir) #f)
      ((and (boundp 'chat-cwd-target?) (chat-cwd-target? buf))
       (car (chat-cwd-move! buf dir)))
      (else (buffer-set-local! buf 'default-directory dir) 'set))))

;; every buffer in G that takes a directory -> how many took it
(define (group-cwd-push! g)
  (let ((id (group-resolve-id g)) (n 0))
    (when id
      (for-each (lambda (buf)
                  (when (and (equal? id (group-resolve-id (buffer-group buf)))
                             (group-cwd-apply! buf))
                    (set! n (+ n 1))))
                (buffer-list)))
    n))

;; Set it, and hand it to every buffer already in the group: (COUNT DIR),
;; or (no-group "") / (no-such-directory DIR).
(define (group-cwd-set! g dir)
  (let ((id (group-resolve-id g))
        (dir (and (string? dir)
                  (expand-path (normalize-file-input (string-trim dir))))))
    (cond
      ((not id) (list 'no-group ""))
      ((not (and dir (file-directory? dir)))
       (list 'no-such-directory (or dir "")))
      (else (group-setting-set! id 'cwd dir)
            (list (group-cwd-push! id) (group-cwd-slash dir))))))

(define (group-cwd-note id status dir)
  (cond
    ((equal? status 'no-group) "no group here")
    ((equal? status 'no-such-directory) (string-append "no such directory: " dir))
    (else (string-append (group-name id) ": " (abbreviate-file-name dir)
                         " -- " (number->string status)
                         (if (equal? status 1) " buffer" " buffers")))))

;; The seam. groups.scm calls this as a buffer joins a group, and the wake
;; hook below catches a buffer that comes back with its group already on it.
;; A chat that has run this group's config keeps whatever it holds now: the
;; group reaches into a chat once, and never again on its own.
(define (group-configure-buffer! buf)
  (let ((id (and buf (buffer-known? buf) (group-resolve-id (buffer-group buf)))))
    (when id
      ;; the directory is a group property, not a script, but it reaches in
      ;; on the same terms: once, on the join, and never again on its own.
      (unless (equal? (buffer-local buf 'group-cwd-loaded) id)
        (buffer-set-local! buf 'group-cwd-loaded id)
        (group-cwd-apply! buf))
      (unless (equal? (group-config-loaded buf) id)
        (group-config-apply! buf))))
  buf)

(add-hook! 'buffer-woken-hook 'group-configure-buffer!)

(define-command "chat-load-config" "Load this group's config into this chat"
  (lambda ()
    (let* ((buf (current-buffer))
           (id (group-resolve-id (buffer-group buf)))
           (path (and id (group-config-file id))))
      (cond
        ((not id) (message "no group here"))
        ((not (group-config-chat? buf)) (message "not a chat"))
        ((not (file-exists? path)) (message (string-append "no config at " path)))
        ((group-config-apply! buf)
         (message (string-append (group-name id) ": loaded " path)))
        (else #f)))))

(define-command "group-reload-config" "Re-read this group's config and directory into every buffer in it"
  (lambda ()
    (let* ((id (group-resolve-id (or (buffer-group (current-buffer)) (frame-group))))
           (path (and id (group-config-file id)))
           (dir (and id (group-cwd id))))
      (if (not id)
          (message "no group here")
          (let ((moved (group-cwd-push! id)) (n 0))
            (when (file-exists? path)
              (for-each
                (lambda (buf)
                  (when (and (equal? id (group-resolve-id (buffer-group buf)))
                             (group-config-apply! buf))
                    (set! n (+ n 1))))
                (buffer-list)))
            (message
              (string-append
                (group-name id) ": "
                (if (file-exists? path)
                    (string-append "loaded " path " into " (number->string n)
                                   (if (equal? n 1) " chat" " chats") ", ")
                    "no config file, ")
                (if dir
                    (string-append (abbreviate-file-name dir) " into "
                                   (number->string moved)
                                   (if (equal? moved 1) " buffer" " buffers"))
                    "no directory"))))))))

(define-command "group-cwd" "Set this group's working directory, and move its buffers there"
  (lambda ()
    (let ((id (group-resolve-id (or (buffer-group (current-buffer)) (frame-group)))))
      (if (not id)
          (message "no group here")
          (read-file-name-initial "Group working directory: "
            (or (group-cwd id) (buffer-directory (current-buffer)))
            (lambda (input)
              (let ((r (group-cwd-set! id input)))
                (message (group-cwd-note id (car r) (cadr r))))))))))

(category! 'buffers)
(public! 'group-config-file
  "(group-config-file G) -> the path of the ai-config.scm G shares with its chats")
(catalog-meta! 'function "group-config-file" 'domain 'buffers 'effects '(read))
(public! 'group-config-loaded
  "(group-config-loaded BUF) -> the group whose config BUF has run, or #f")
(catalog-meta! 'function "group-config-loaded" 'domain 'buffers 'effects '(read))
(public! 'group-config-apply!
  "(group-config-apply! BUF) -- run BUF's group config on it, first time or not")
(catalog-meta! 'function "group-config-apply!" 'domain 'buffers 'effects '(write execute))
(public! 'group-configure-buffer!
  "(group-configure-buffer! BUF) -- run the group's config on BUF the first time it joins")
(catalog-meta! 'function "group-configure-buffer!" 'domain 'buffers 'effects '(write execute))
(public! 'group-cwd
  "(group-cwd G) -> the directory G and its buffers work in, or #f")
(catalog-meta! 'function "group-cwd" 'domain 'buffers 'effects '(read))
(public! 'group-cwd-set!
  "(group-cwd-set! G DIR) -- set it and move every buffer in G: (COUNT DIR)")
(catalog-meta! 'function "group-cwd-set!" 'domain 'buffers 'effects '(write))
(public! 'group-cwd-apply!
  "(group-cwd-apply! BUF) -- give BUF its group's directory, agent and all")
(catalog-meta! 'function "group-cwd-apply!" 'domain 'buffers 'effects '(write))
(public! 'group-cwd-push!
  "(group-cwd-push! G) -> how many buffers in G took its directory")
(catalog-meta! 'function "group-cwd-push!" 'domain 'buffers 'effects '(write))
(public! 'buffer-takes-cwd?
  "(buffer-takes-cwd? BUF) -> #t when nothing on BUF already fixes its directory")
(catalog-meta! 'function "buffer-takes-cwd?" 'domain 'buffers 'effects '(read))
(catalog-meta! 'command "group-cwd" 'domain 'buffers 'effects '(write))
(catalog-meta! 'command "chat-load-config" 'domain 'buffers 'effects '(write execute))
(catalog-meta! 'command "group-reload-config" 'domain 'buffers 'effects '(write execute))
