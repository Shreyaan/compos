;;; ibuffer-prompt-test.scm --- C-x b and C-x c are the ibuffer table in the
;;; minibuffer form: a bottom popup with its filter line.
;;;
;;; Every test opens the form by command, reads the popup and the prompt,
;;; and drives the prompt through the minibuffer commands. No test names
;;; a key.

(domain! 'testing)
(effects! '(write))

(define *ibp-bufs* '("*zz-ibp-a*" "*zz-ibp-b*" "*zz-ibp-c*"))

(define (ibp-drop-group! name)
  (when (group-record-by-name name) (group-record-delete! name)))

(define (ibp-reset!)
  (when (minibuffer-state) (minibuffer-cancel!))
  (when (popup-open?) (popup-close!))
  (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
            (append *ibp-bufs* (list " *buffers*" " *chats*" "*zz-ibp-chat*")))
  ;; a group founded here brings a chat and a scratch along: take them away
  (for-each (lambda (b)
              (when (or (string-prefix? "*chat:zz-ibp" b) (string-prefix? "*scratch:zz-ibp" b))
                (buffer-kill! b)))
            (buffer-list))
  (ibp-drop-group! "zz-ibp-one")
  (ibp-drop-group! "zz-ibp-two")
  (delete-other-windows!))

;; a and b in group one, c in group two; the last switch was to b, and
;; the prompt opens from a
(define (ibp-setup!)
  (ibp-reset!)
  (let ((one (group-record-create! "zz-ibp-one"))
        (two (group-record-create! "zz-ibp-two")))
    (for-each (lambda (b) (test-buffer! b "")) *ibp-bufs*)
    (buffer-add-group! "*zz-ibp-a*" one)
    (buffer-add-group! "*zz-ibp-b*" one)
    (buffer-add-group! "*zz-ibp-c*" two)
    ;; shown through the mechanism a layout uses: a switch to a buffer of
    ;; another group would float it in the popup
    (switch-to-buffer-here! "*zz-ibp-c*")
    (switch-to-buffer-here! "*zz-ibp-b*")
    (switch-to-buffer-here! "*zz-ibp-a*")
    (set-frame-local! 'current-group one)
    (list one two)))

(define (ibp-names view)
  (filter string? (list-entries view)))

;; the fixture's own rows: a group founded here brings its chat along
(define (ibp-mine view)
  (filter (lambda (b) (member b *ibp-bufs*)) (ibp-names view)))

(define (ibp-labels view)
  (map (lambda (e) (if (ibuffer-heading? e) (ibuffer-heading-label e) e))
       (list-entries view)))

(deftest 'the-buffer-prompt-is-the-table-under-a-filter-line
  "C-x b opens the ibuffer view in a bottom popup, its rows by group, and the prompt in front"
  (lambda ()
    (ibp-setup!)
    (run-command "ibuffer-prompt")
    (check-true! (popup-open?) "the table is a popup")
    (check-equal! (window-buffer (popup-window)) " *buffers*" "the prompt's own view")
    (check-equal! (buffer-local " *buffers*" 'mode-name) "ibuffer-mode" "in ibuffer-mode")
    (check-equal! (plist-get (minibuffer-state) 'prompt) "Switch to: " "the prompt line is open")
    (list-set-filters! " *buffers*" (list (list "match" "zz-ibp-")))
    (let ((labels (ibp-labels " *buffers*")))
      (check-equal! (car labels) "in this group" "this group leads")
      (check-true! (and (member "zz-ibp-two" labels) #t) "the other group under its name")
      (check-equal! (ibp-mine " *buffers*") '("*zz-ibp-b*" "*zz-ibp-a*" "*zz-ibp-c*")
                    "the rows in the window's history order, the buffer you are on last in its group"))
    (ibp-reset!)))

(deftest 'typing-narrows-the-table-and-arrows-move-its-highlight
  "the prompt's change narrows the rows; next-candidate moves the table's highlight"
  (lambda ()
    (ibp-setup!)
    (run-command "ibuffer-prompt")
    (minibuffer-change! "zz-ibp-")
    (check-equal! (ibp-mine " *buffers*") '("*zz-ibp-b*" "*zz-ibp-a*" "*zz-ibp-c*") "three rows match")
    (check-equal! (list-current " *buffers*") "*zz-ibp-b*" "the highlight starts on the first row")
    (run-command "minibuffer-next-candidate")
    (check-equal! (list-current " *buffers*") "*zz-ibp-a*" "and moves down a row")
    (run-command "minibuffer-previous-candidate")
    (check-equal! (list-current " *buffers*") "*zz-ibp-b*" "and back up")
    (minibuffer-change! "zz-ibp-c")
    (check-equal! (ibp-names " *buffers*") '("*zz-ibp-c*") "a longer query narrows further")
    (check-equal! (list-current " *buffers*") "*zz-ibp-c*" "over the heading, onto the row that matches")
    (ibp-reset!)))

(deftest 'confirm-takes-the-row-and-closes-the-table
  "RET switches to the highlighted row and the popup goes"
  (lambda ()
    (ibp-setup!)
    (run-command "ibuffer-prompt")
    (minibuffer-change! "zz-ibp-c")
    (run-command "minibuffer-confirm")
    (check-false! (minibuffer-state) "the prompt is closed")
    ;; the table is gone; the row floats in the popup, because it is a
    ;; buffer of another group and this group's panes stay sealed
    (check-false! (and (popup-open?) (equal? (window-buffer (popup-window)) " *buffers*"))
                  "the table is closed")
    (check-equal! (current-buffer) "*zz-ibp-c*" "the row is the current buffer")
    (check-equal! (list-query " *buffers*") "" "the next open starts wide")
    (ibp-reset!)))

(deftest 'cancel-closes-the-table-and-keeps-the-buffer
  "C-g closes the popup and the buffer you came from stays current"
  (lambda ()
    (ibp-setup!)
    (run-command "ibuffer-prompt")
    (minibuffer-change! "zz-ibp-c")
    (minibuffer-cancel!)
    (check-false! (popup-open?) "the popup is closed")
    (check-equal! (current-buffer) "*zz-ibp-a*" "the buffer you came from")
    (ibp-reset!)))

(deftest 'the-chat-prompt-is-the-same-table-over-the-chats
  "C-x c opens the chats view in the same form, in ichat-mode, and RET switches to the chat"
  (lambda ()
    (ibp-setup!)
    (test-buffer! "*zz-ibp-chat*" "")
    (buffer-set-local! "*zz-ibp-chat*" 'mode-name "chat-mode")
    (switch-to-buffer-here! "*zz-ibp-a*")
    (run-command "ichat-prompt")
    (check-true! (popup-open?) "the table is a popup")
    (check-equal! (window-buffer (popup-window)) " *chats*" "the chats' own prompt view")
    (check-equal! (buffer-local " *chats*" 'mode-name) "ichat-mode" "in ichat-mode")
    (check-equal! (plist-get (minibuffer-state) 'prompt) "Chat: " "the prompt line")
    (minibuffer-change! "zz-ibp-chat")
    (check-equal! (ibp-names " *chats*") '("*zz-ibp-chat*") "the chat matches")
    (run-command "minibuffer-confirm")
    (check-false! (and (popup-open?) (equal? (window-buffer (popup-window)) " *chats*"))
                  "the table is closed")
    (check-equal! (current-buffer) "*zz-ibp-chat*" "the chat is current")
    (ibp-reset!)))
