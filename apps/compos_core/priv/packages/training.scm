;;; training.scm --- the Emacs-style tutorial and its optional companion.

(package! 'training)
(domain! 'learning)
(effects! '(read write external))

(defgroup 'training "Guided editor training.")

(defcustom 'training-bot-silent-mode #f
  "Start the tour without changing the editor window setup."
  'group 'training 'type 'boolean)

(define *training-tutorial-buffer* "TUTORIAL")

(define (training-document-path)
  "Return the bundled, immutable tutorial master."
  (string-append (compos-priv-dir) "/tutorials/COMPOS"))

(define (training-state-dir)
  (string-append (compos-home) "/tutorial"))

(define (training-state-path)
  (string-append (training-state-dir) "/COMPOS.tut"))

(define (training-encode-state point text)
  (string-append (number->string point) "\n" text))

(define (training-decode-state raw)
  (and (string? raw)
       (let ((nl (string-index raw "\n")))
         (and nl
              (let* ((head (substring-bytes raw 0 nl))
                     (point (string->number head)))
                (and (re-match "^[0-9]+$" head)
                     (number? point)
                     (>= point 0)
                     (list point
                           (substring-bytes raw (+ nl 1) (string-byte-length raw)))))))))

(define (training-read-state)
  (let ((raw (read-file (training-state-path))))
    (and raw (training-decode-state raw))))

(define (training-save-state! buf)
  (make-directory! (training-state-dir))
  (write-file! (training-state-path)
               (training-encode-state (buffer-point buf) (buffer-text buf)))
  #t)

(define (training--load-tutorial! text point)
  (let ((buf *training-tutorial-buffer*))
    (buffer-create buf)
    (buffer-set-read-only! buf #f)
    (buffer-delete-range! buf 0 (buffer-size buf))
    (buffer-insert! buf 0 text)
    (with-current-buffer buf (lambda () (set-mode! "text-mode")))
    (let ((point (max 0 (min point (buffer-size buf)))))
      (buffer-goto! buf point)
      (buffer-set-local! buf 'training-starting-point point))
    (buffer-set-local! buf 'training-tutorial #t)
    (buffer-mark-saved! buf)
    buf))

(define (training-fresh-tutorial!)
  (let ((text (read-file (training-document-path))))
    (if text
        (training--load-tutorial! text 0)
        (error "The bundled Compos tutorial is missing"))))

(define (training-resume-tutorial! state)
  (training--load-tutorial! (cadr state) (car state)))

(define (training--show! buf)
  (switch-to-buffer! buf)
  buf)

(define (training--prepare-document!)
  (if (buffer-known? *training-tutorial-buffer*)
      (buffer-create *training-tutorial-buffer*)
      (let ((state (training-read-state)))
        (if state
            (training-resume-tutorial! state)
            (training-fresh-tutorial!)))))

(define (training--open-tutorial!)
  (training--show! (training--prepare-document!)))

(define-command "help-with-tutorial"
  "Select the Compos learn-by-doing tutorial, resuming saved progress"
  (lambda () (training--open-tutorial!)))

(define (training--tutorial-progressed? buf)
  (or (buffer-modified? buf)
      (not (equal? (buffer-point buf)
                   (or (buffer-local buf 'training-starting-point) 0)))))

(define (training--kill-buffer-confirm! next target done)
  (if (and (equal? target *training-tutorial-buffer*)
           (buffer-known? target)
           (training--tutorial-progressed? target))
      (y-or-n "Save your position in the tutorial?"
        (lambda ()
          (training-save-state! target)
          (next target done))
        (lambda ()
          (when (file-exists? (training-state-path))
            (delete-file-path! (training-state-path) #t))
          (next target done)))
      (next target done)))

(define-command "training-kill-buffer"
  "Kill a buffer; when C-x k leaves TUTORIAL, offer to retain its progress"
  (lambda ()
    (let ((cur (current-buffer)))
      (minibuffer-read (string-append "Kill buffer (default " cur "): ")
        (cons (list cur "current") (buffer-candidates))
        (lambda (name)
          (training--kill-buffer-confirm!
            kill-buffer-confirm!
            (if (equal? name "") cur name)
            (lambda (killed?) #t)))))))

(define-key "help-map" "t" "help-with-tutorial")
(global-set-key "C-x k" "training-kill-buffer")

(define (training-tour-prompt)
  "Return the first companion turn for the guided tour."
  (string-append
    "You are the training bot. Read the live TUTORIAL buffer before you reply. "
    "Start its interactive tour now. Teach one short step per turn, then wait for "
    "the user to try it. Begin with M-x and ask the user to run describe-mode. "
    "Later, teach shortcut keys, C-h k, C-h m, M-?, C-c w, and "
    "M-x chat-companion-ask. "
    "Demonstrate that a companion can summarize the current buffer's major mode. "
    "Keep each turn concise and encouraging."))

(define (training--open-document!)
  (let ((buf (training--prepare-document!)))
    (unless training-bot-silent-mode
      (display-buffer-other-window! buf))
    buf))

(define (training-mode-summary-prompt buf)
  "Return the companion request that teaches BUF's major mode."
  (let* ((mode (or (buffer-local buf 'mode-name) "fundamental-mode"))
         (doc (or (mode-doc mode) "No mode documentation is registered.")))
    (string-append
      "Teach me the major mode of the buffer named \"" buf "\". "
      "The major mode is " mode ". Summarize its purpose, philosophy, "
      "most useful commands, and shortcut keys. Explain how M-x relates "
      "to those keys. Keep the lesson concise.\n\n"
      "Registered mode documentation:\n" doc)))

(define (training--send! chat prompt)
  (with-current-buffer chat
    (lambda ()
      (set-mode! "chat-mode")
      (end-of-buffer!)
      (insert! prompt)
      (run-command "agent-send"))))

(define (training--show-chat-beside! document chat)
  ;; The document already occupies the other window. Use it as the reference
  ;; window, then show and select its companion in the remaining pane.
  (let ((doc-window (window-showing document)))
    (when doc-window
      (select-window! doc-window)
      (display-buffer-other-window! chat)
      (let ((chat-window (window-showing chat)))
        (when chat-window
          (select-window! chat-window))))))

(define (training-start-tour!)
  "Open TUTORIAL, start its companion chat, and send the first tour turn."
  (let* ((document (training--open-document!))
         (group (group-ensure! document))
         (chat (group-chat group)))
    (unless training-bot-silent-mode
      (training--show-chat-beside! document chat))
    (training--send! chat (training-tour-prompt))
    (message "Training tour started in the companion chat")
    chat))

(define (training-companion-summarize-mode!)
  "Ask the current buffer's companion chat to summarize its major mode."
  (let* ((source (current-buffer))
         (group (group-ensure! source))
         (chat (group-chat group)))
    (unless training-bot-silent-mode
      (display-buffer-other-window! chat))
    (training--send! chat (training-mode-summary-prompt source))
    (message (string-append "Asked the companion about "
                            (or (buffer-local source 'mode-name) "fundamental-mode")))
    chat))

(define-command "training-bot"
  "Open the tutorial and start its guided companion-chat tour"
  (lambda () (training-start-tour!)))

(define-command "training-guide" "Open the learn-by-doing tutorial"
  (lambda () (run-command "help-with-tutorial")))

(define-command "training-companion-summarize-mode"
  "Ask the companion chat to summarize the current major mode"
  (lambda () (training-companion-summarize-mode!)))

(define (training--follow-link arg)
  (cond ((equal? arg "tutorial") (run-command "help-with-tutorial"))
        ((equal? arg "summarize-mode")
         (run-command "training-companion-summarize-mode"))
        ((equal? arg "start-tour") (run-command "training-bot"))
        ((equal? arg "guide") (run-command "training-guide"))
        (else (message (string-append "Unknown training link: " arg)))))

(on-preview-link! "training" training--follow-link)

(category! 'training)
(public! 'training-document-path
  "(training-document-path) — the bundled immutable tutorial master")
(public! 'training-state-path
  "(training-state-path) — the reader's saved tutorial content and point")
(public! 'training-tour-prompt
  "(training-tour-prompt) — the first companion turn in the interactive curriculum")
(public! 'training-mode-summary-prompt
  "(training-mode-summary-prompt BUFFER) — ask a companion to teach BUFFER's major mode")
(public! 'training-start-tour!
  "(training-start-tour!) — open TUTORIAL and start its companion-chat tour")
(public! 'training-companion-summarize-mode!
  "(training-companion-summarize-mode!) — ask this buffer's companion to teach its major mode")
