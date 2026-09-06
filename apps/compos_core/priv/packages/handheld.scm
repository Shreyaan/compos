;;; handheld.scm --- policy for the handheld client.
;;;
;;; The handheld client (/m) is a second client of the same frame payload
;;; the desktop renders. Elixir draws it and forwards every gesture as a
;;; key. This file decides what the client offers: the prefixes on the
;;; chord fan, which keys the fan shows under a prefix, the tab rail, the
;;; chips above the composer, and what the composer does with a line of
;;; text.
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

(defcustom 'handheld-fan-limit 7
  "How many bindings the chord fan shows under a prefix. The rest open as a list."
  'group 'handheld 'type 'number)

(defcustom 'handheld-fan-pins
  '(("C-x" "b" "g" "C-f" "k" "s" "d")
    ("C-c" "b" "c" "n" "a")
    ("C-h" "b" "k" "m" "f"))
  "The keys the fan shows first under a prefix, in this order. Each entry is (PREFIX KEY ...). A pinned key that the keymap does not bind is skipped."
  'group 'handheld 'type 'list)

;;; --- the fan: which keys sit under the thumb -------------------------------------
;;; The frame's which-key rows are every binding under the prefix, and a
;;; phone has room for a handful. The rule: the pinned keys for this
;;; prefix first, then single letters and digits, then any other single
;;; key, then the nested sequences. The limit cuts the list and the client
;;; offers the rest as a scrolling list.

(define (handheld-single-key? key)
  (not (string-contains? key " ")))

(define *handheld-plain-chars*
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

(define (handheld-plain-key? key)
  (and (= (string-length key) 1)
       (string-contains? *handheld-plain-chars* key)))

(define (handheld-take xs n)
  (if (or (null? xs) (<= n 0))
      '()
      (cons (car xs) (handheld-take (cdr xs) (- n 1)))))

(define (handheld-fan-rank key)
  (cond ((handheld-plain-key? key) 0)
        ((handheld-single-key? key) 1)
        (else 2)))

(define (handheld-fan-pinned prefix)
  (let ((e (assoc prefix handheld-fan-pins)))
    (if e (cdr e) '())))

;; ROWS are ((KEY COMMAND) ...) under PREFIX, as the frame reports them.
;; Returns (SHOWN HIDDEN): SHOWN is ((KEY COMMAND) ...) in fan order, cut
;; at handheld-fan-limit; HIDDEN counts the rows the cut left out.
(define (handheld-fan prefix rows)
  (let* ((pins (handheld-fan-pinned prefix))
         (pinned (filter (lambda (r) r)
                         (map (lambda (k) (assoc k rows)) pins)))
         (rest (filter (lambda (r) (not (member (car r) pins))) rows))
         (ranked (append
                   (filter (lambda (r) (= (handheld-fan-rank (car r)) 0)) rest)
                   (filter (lambda (r) (= (handheld-fan-rank (car r)) 1)) rest)
                   (filter (lambda (r) (= (handheld-fan-rank (car r)) 2)) rest)))
         (ordered (append pinned ranked))
         (n (length ordered))
         (limit (max 1 handheld-fan-limit)))
    (if (<= n limit)
        (list ordered 0)
        (list (handheld-take ordered limit) (- n limit)))))

;;; --- the tab rail: groups -------------------------------------------------------
;;; A phone switches groups, not buffers. The rail is the groups in MRU
;;; order, and a tap lands in that group's chat.
;;; Each row is (ID LABEL KIND CURRENT?).

(define (handheld-tabs &optional cur)
  (let ((here (or cur (frame-group))))
    (map (lambda (id)
           (list id
                 (group-display-name id)
                 "group"
                 (equal? id here)))
         (group-ids-mru))))

(effects! '(write))

;; A tap on a tab: switch to the group and show its chat, founding the
;; chat when the group has none yet. Returns the chat buffer, or #f.
(define (handheld-tab! g)
  (let ((id (group-resolve-id g)))
    (cond ((not id) (message "No such group") #f)
          (else
           (switch-to-group! id)
           (let ((chat (or (group-chat id) (group-chat-new! id))))
             (if chat
                 (group-chat-buffer-show! chat)
                 (message "This group has no chat"))
             chat)))))

;; A long press on a tab: switch to the group and open the buffer switcher
;; as a prompt, so the group's buffers come up as tappable rows.
(define (handheld-tab-hold! g)
  (let ((id (group-resolve-id g)))
    (cond ((not id) (message "No such group") #f)
          (else
           (unless (equal? id (frame-group)) (switch-to-group! id))
           (run-command "switch-to-buffer-prompt")
           id))))

(effects! '(read))

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
        (handheld-tabs)
        (handheld-chips buf)))

(public! 'handheld-view
  "(handheld-view BUF) -> (PREFIXES FAN-LIMIT TABS CHIPS): what the handheld client shows for BUF")
(public! 'handheld-fan
  "(handheld-fan PREFIX ROWS) -> (SHOWN HIDDEN): the which-key rows the fan shows under PREFIX, pins first, and how many it left out")
(public! 'handheld-classify
  "(handheld-classify TEXT) -> (empty) | (keys KEYS) | (command NAME) | (prose TEXT)")
(public! 'handheld-compose!
  "(handheld-compose! TEXT) — dispatch a chord, run an M-x command, or send prose to the group chat")
(catalog-meta! 'function "handheld-compose!" 'domain 'interaction 'effects '(write))
(public! 'handheld-scrub!
  "(handheld-scrub! N) — move point to the start of line N; returns the line reached")
(catalog-meta! 'function "handheld-scrub!" 'domain 'interaction 'effects '(write))
(public! 'handheld-tabs
  "(handheld-tabs [CUR]) -> ((ID LABEL KIND CURRENT?) ...): the groups in MRU order; CUR is the current group")
(public! 'handheld-tab!
  "(handheld-tab! GROUP) — switch to GROUP and show its chat; returns the chat buffer or #f")
(catalog-meta! 'function "handheld-tab!" 'domain 'interaction 'effects '(write display))
(public! 'handheld-tab-hold!
  "(handheld-tab-hold! GROUP) — switch to GROUP and open the buffer switcher as a prompt; returns the group id or #f")
(catalog-meta! 'function "handheld-tab-hold!" 'domain 'interaction 'effects '(write display))
(public! 'handheld-chips
  "(handheld-chips BUF) -> ((LABEL CHORD) ...): the composer chips for BUF")
