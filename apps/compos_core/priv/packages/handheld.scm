;;; handheld.scm --- policy for the handheld client.
;;;
;;; The handheld client (/m) is a second client of the same frame payload
;;; the desktop renders. Elixir draws it and forwards every gesture as a
;;; key. This file decides what the client offers: the prefixes on the
;;; chord fan, the size of the fan, the tab rail, the chips above the
;;; composer, and what the composer does with a line of text.
;;;
;;; The composer has three registers. A literal chord dispatches its keys.
;;; "M-x NAME" runs the named command. Anything else goes to the group's
;;; chat as a message.

(package! 'handheld)
(category! 'interaction)
(domain! 'interaction)
(effects! '(read))

(defgroup 'handheld "The handheld client: the chord fan, the tab rail, the composer.")

(defcustom 'handheld-prefixes
  '(("C-c" "Compos verbs")
    ("C-x" "Buffers and windows")
    ("M-x" "Command by name")
    ("C-h" "What does this do?")
    ("C-g" "Never mind"))
  "The keys the chord fan offers first. Each entry is (KEY LABEL)."
  'group 'handheld 'type 'list)

(defcustom 'handheld-fan-limit 6
  "How many bindings the chord fan shows under a prefix. The rest open as a list."
  'group 'handheld 'type 'number)

;;; --- what a buffer is, in one word --------------------------------------------

;; the kind word on a tab: the mode name without its -mode suffix
(define (handheld-buffer-kind buf)
  (let ((mode (or (buffer-local buf 'mode-name) "Fundamental")))
    (cond ((chat-buffer? buf) "chat")
          ((equal? mode "Dired") "dir")
          ((string-suffix? "-mode" mode)
           (substring mode 0 (- (string-length mode) 5)))
          (else (string-downcase mode)))))

(define (handheld-tab-label buf)
  (or (buffer-local buf 'modeline-name)
      (switch-buffer-label buf)))

;; The tab rail: the current group's buffers in MRU order. Outside a
;; group, the buffer MRU. CUR is the buffer the window shows, and it is
;; always on the rail; it defaults to the current buffer.
;; Each row is (NAME LABEL KIND CURRENT?).
(define (handheld-tabs &optional cur)
  (let* ((g (frame-group))
         (cur (or cur (current-buffer)))
         (pool (filter buffer-exists?
                       (if g (group-user-buffers-mru g) (buffer-list-mru))))
         (pool (if (member cur pool) pool (cons cur pool))))
    (map (lambda (b)
           (list b (handheld-tab-label b) (handheld-buffer-kind b) (equal? b cur)))
         pool)))

;;; --- chips ----------------------------------------------------------------------

;; A chip names a command. Its chord is the key bound to that command in
;; BUF, or "M-x NAME" when nothing binds it. The composer sends the chord
;; as text, so a chip teaches the key it presses. The row is (LABEL CHORD).
(define (handheld-chip label command buf)
  (let ((key (key-for-command command buf)))
    (list label
          (if (and (string? key) (not (equal? key "")))
              key
              (string-append "M-x " command)))))

(define (handheld-chips buf)
  (if (chat-buffer? buf)
      (list (handheld-chip "Configure chat" "llm-configure" buf)
            (handheld-chip "Switch buffer" "switch-to-buffer" buf)
            (handheld-chip "Every command" "execute-extended-command" buf))
      (list (handheld-chip "Chat about this" "chat" buf)
            (handheld-chip "Switch buffer" "switch-to-buffer" buf)
            (handheld-chip "Every command" "execute-extended-command" buf))))

;;; --- the composer: prose, a chord, or M-x ---------------------------------------

(define *handheld-named-keys* '("RET" "TAB" "SPC" "DEL" "ESC"))

;; a token that is a key on its own: a named key, a <named> key, or a
;; modified key
(define (handheld-key-token? tok)
  (let ((n (string-length tok)))
    (or (member tok *handheld-named-keys*)
        (and (> n 2) (string-prefix? "<" tok) (string-suffix? ">" tok))
        (and (>= n 3)
             (member (substring tok 0 2) '("C-" "M-" "s-" "S-"))))))

;; a token that can follow a prefix: a key token or one character
(define (handheld-chord-token? tok)
  (or (handheld-key-token? tok) (= (string-length tok) 1)))

(define (handheld-all? pred xs)
  (or (null? xs)
      (and (pred (car xs)) (handheld-all? pred (cdr xs)))))

(define (handheld-tokens text)
  (filter (lambda (s) (not (equal? s "")))
          (string-split (string-trim text) " ")))

;; What a line of text means: (empty), (keys KEYS), (command NAME), or
;; (prose TEXT). A chord starts with a key token and every later token is
;; a chord token. "M-x NAME" is a command. The rest is prose.
(define (handheld-classify text)
  (let ((toks (handheld-tokens text)))
    (cond ((null? toks) (list 'empty))
          ((and (equal? (car toks) "M-x")
                (pair? (cdr toks))
                (null? (cdr (cdr toks))))
           (list 'command (car (cdr toks))))
          ((and (handheld-key-token? (car toks))
                (handheld-all? handheld-chord-token? (cdr toks)))
           (list 'keys toks))
          (else (list 'prose (string-trim text))))))

(effects! '(write))

;; Send TEXT to the group's chat. Outside a chat, the chat command opens
;; the group chat first. Returns the chat buffer, or #f when no chat
;; receives the message.
(define (handheld-say! text)
  (let ((cur (current-buffer)))
    (unless (chat-buffer? cur) (run-command "chat"))
    (let ((buf (current-buffer)))
      (if (chat-buffer? buf)
          (begin
            (chat-replace-input! buf text)
            (run-command "agent-send")
            buf)
          (begin (message "No chat receives this message") #f)))))

;; The composer's one entry. Returns the register it used.
(define (handheld-compose! text)
  (let ((c (handheld-classify text)))
    (cond ((equal? (car c) 'empty)
           (message "Nothing to send. Type prose, a chord, or M-x and a command.")
           'empty)
          ((equal? (car c) 'keys)
           (dispatch-keys (car (cdr c)))
           'keys)
          ((equal? (car c) 'command)
           (let ((name (car (cdr c))))
             (if (member name (command-names))
                 (begin (run-command name) 'command)
                 (begin (message (string-append "No command named " name))
                        'unknown))))
          (else (handheld-say! (car (cdr c))) 'prose))))

;; The point rail: move point to the start of line N in the current
;; buffer. The client turns a drag position into N.
(define (handheld-scrub! n)
  (let* ((total (line-number-at-pos (buffer-size (current-buffer))))
         (line (max 1 (min total n))))
    (goto-char! (line-start-position line))
    line))

(effects! '(read))

;; Everything the client asks for in one call:
;; (PREFIXES FAN-LIMIT TABS CHIPS)
(define (handheld-view buf)
  (list handheld-prefixes
        handheld-fan-limit
        (handheld-tabs buf)
        (handheld-chips buf)))

(public! 'handheld-view
  "(handheld-view BUF) -> (PREFIXES FAN-LIMIT TABS CHIPS): what the handheld client shows for BUF")
(public! 'handheld-classify
  "(handheld-classify TEXT) -> (empty) | (keys KEYS) | (command NAME) | (prose TEXT)")
(public! 'handheld-compose!
  "(handheld-compose! TEXT) — dispatch a chord, run an M-x command, or send prose to the group chat")
(catalog-meta! 'function "handheld-compose!" 'domain 'interaction 'effects '(write))
(public! 'handheld-scrub!
  "(handheld-scrub! N) — move point to the start of line N; returns the line reached")
(catalog-meta! 'function "handheld-scrub!" 'domain 'interaction 'effects '(write))
(public! 'handheld-tabs
  "(handheld-tabs [CUR]) -> ((NAME LABEL KIND CURRENT?) ...): the tab rail; CUR is the shown buffer")
(public! 'handheld-chips
  "(handheld-chips BUF) -> ((LABEL CHORD) ...): the composer chips for BUF")
