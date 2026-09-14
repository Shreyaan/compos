;;; chats-list-test.scm --- *chat-list* is the chat list application:
;;; one arrival, sections by group, the chat row kind, and the words a
;;; row shows.
;;;
;;; Every test opens the application by command and narrows it to its own
;;; chats, then reads the entries and the text. No test names a key.

(domain! 'testing)
(effects! '(write))

(tests-need-a-disposable-editor!
  "the chat list is an application: it takes the frame, enters its own group, and holds the focus")

(define *chats-test-bufs* '("*zz-chats-a*" "*zz-chats-b*" "*zz-chats-c*"))

(define (chats-test-drop-group! name)
  (when (group-record-by-name name) (group-record-delete! name)))

(define *chat-list* "*chat-list*")

(define (chats-test-reset!)
  (when (buffer-known? *chat-list*)
    (run-command "chat-list-quit")
    (buffer-set-locals! *chat-list*
      (list 'ibuffer-sort #f 'ibuffer-grouping #f 'ibuffer-collapsed '()))
    (list-filter-clear! *chat-list*)
    (buffer-kill! *chat-list*))
  ;; the transcripts go before the buffers do: the path is read off the
  ;; chat's own group, which a killed buffer no longer has
  (for-each (lambda (b)
              (let ((id (and (buffer-known? b) (buffer-local b 'chat-log-id))))
                (when (string? id)
                  (delete-file-path! (string-append (chat-log-dir-for b) "/" id ".chat") #t))))
            *chats-test-bufs*)
  (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b))) *chats-test-bufs*)
  (chats-test-drop-group! "zz-chats-one")
  (chats-test-drop-group! "zz-chats-two")
  (delete-other-windows!))

;; a chat with no runtime: the api state, which the row calls idle
(define (chats-test-chat! name group-id)
  (test-buffer! name "")
  (buffer-set-local! name 'mode-name "chat-mode")
  (when group-id (buffer-set-local! name 'group-id group-id))
  name)

;; a chat's size is its transcript on disk, so a chat that needs a size
;; needs a file: BYTES of one, under the group's own chats directory
(define (chats-test-log! name id bytes)
  (buffer-set-local! name 'chat-log-id id)
  (write-file! (string-append (chat-log-dir-for name) "/" id ".chat")
               (string-repeat "x" bytes))
  name)

;; a and b in group one, c in group two; answers (ONE TWO)
(define (chats-test-open! grouping sort)
  (chats-test-reset!)
  (let ((one (group-record-create! "zz-chats-one"))
        (two (group-record-create! "zz-chats-two")))
    (chats-test-chat! "*zz-chats-a*" one)
    (chats-test-chat! "*zz-chats-b*" one)
    (chats-test-chat! "*zz-chats-c*" two)
    (run-command "chat-list")
    (buffer-set-locals! *chat-list*
      (list 'ibuffer-grouping grouping 'ibuffer-sort sort 'ibuffer-collapsed '()))
    (list-set-filters! *chat-list* (list (list "match" "zz-chats-")))
    (list-refresh! *chat-list*)
    (ibuffer-goto-first-row! *chat-list*)
    (list one two)))

(define (chats-test-names)
  (filter string? (list-entries *chat-list*)))

(define (chats-test-headings)
  (filter ibuffer-heading? (list-entries *chat-list*)))

(define (chats-test-heading-labels)
  (map ibuffer-heading-label (chats-test-headings)))

(deftest 'chats-state-words
  "a runtime status reads as what the chat waits for"
  (lambda ()
    (check-equal! (chats-state-label 'needs_attention) "your turn" "attention")
    (check-equal! (chats-state-label 'running) "streaming" "running")
    (check-equal! (chats-state-label 'idle) "idle" "idle")
    (check-equal! (chats-state-label 'api) "idle" "a chat with no runtime is idle")
    (check-equal! (chats-state-label 'dead) "stopped" "dead")
    (check-equal! (chats-state-face 'needs_attention) "alert" "attention is lit")))

(deftest 'chats-note-activity
  "the event batch stamps the chat, and the row reads the age back"
  (lambda ()
    (chats-note-activity! "*zz-chats-stamped*")
    (check-equal! (chats-age-label (chats-activity-at "*zz-chats-stamped*")) "now" "just stamped")
    (check-equal! (chats-age-label (chats-activity-at "*zz-chats-never*")) "" "never stamped")))

(deftest 'the-chat-list-is-one-application
  "*chat-list* wears the chat list mode built from the ibuffer template, over the chat scope"
  (lambda ()
    (chats-test-open! 'group 'name)
    (check-equal! (buffer-local *chat-list* 'mode-name) "chat-list-mode" "the mode")
    (check-equal! (buffer-local *chat-list* 'ibuffer-scope) 'chat-list "the scope by name")
    (check-true! (ibuffer-view? *chat-list*) "a registered view")
    (check-equal! (ibuffer-row-kind "*zz-chats-a*") 'chat "a chat row wears the chat kind")
    (check-contains! (buffer-text *chat-list*) "Chats" "the title")
    (check-contains! (buffer-text *chat-list*) "3 chats" "the noun is chat")
    (check-equal! (list-key-lines *chat-list*) '() "no key bar stands over the rows")
    (chats-test-reset!)))

(deftest 'the-application-arrives-in-its-own-group
  "one arrival: the chat list's own group, two panes, and the focus on the list"
  (lambda ()
    (chats-test-open! 'group 'name)
    (check-equal! (frame-group) (chat-list-group) "the frame stands in the chat list's group")
    (check-true! (and (member (chat-list-group) (buffer-groups *chat-list*)) #t)
                 "and the buffer belongs to it")
    (check-equal! (group-pinned) (chat-list-group)
                  "the group is pinned, so previewing a chat does not move the frame")
    (check-equal! (length (window-list)) 2 "two panes: the list and the preview")
    (check-equal! (window-buffer (active-window)) *chat-list*
                  "the application holds the focus")
    (check-true! (and (chat-list-preview-window) #t) "the preview pane is the other one")
    (chats-test-reset!)))

(deftest 'the-row-at-point-previews-its-chat
  "looking is free: the row under the cursor shows in the preview pane"
  (lambda ()
    (chats-test-open! 'none 'name)
    (chat-list-preview!)
    (check-equal! (window-buffer (chat-list-preview-window)) (list-current *chat-list*)
                  "the preview pane shows the row at point")
    (chats-test-reset!)))

(deftest 'the-resting-list-is-flat-and-most-recent-first
  "no sections at rest: the order you last used a chat is the order it arrives in"
  (lambda ()
    (chats-test-reset!)
    (chats-test-chat! "*zz-chats-a*" #f)
    (chats-test-chat! "*zz-chats-b*" #f)
    (chats-test-chat! "*zz-chats-c*" #f)
    (run-command "chat-list")
    (check-equal! (ibuffer-grouping *chat-list*) 'none "flat, every time")
    (check-equal! (ibuffer-sort *chat-list*) 'recent "most recently used first")
    (list-set-filters! *chat-list* (list (list "match" "zz-chats-")))
    (list-refresh! *chat-list*)
    (check-equal! (chats-test-heading-labels) '() "no section stands over the rows")
    (check-equal! (length (chats-test-names)) 3 "every chat is a row of its own")
    (chats-test-reset!)))

(deftest 'the-application-leaves-the-way-it-arrived
  "q puts the frame back where it stood and leaves the pin behind"
  (lambda ()
    (let ((from (frame-group)))
      (chats-test-open! 'none 'name)
      (run-command "chat-list-quit")
      (check-equal! (frame-group) from "the frame is back in the group you came from")
      (check-false! (group-pinned) "the application's pin is gone")
      (check-false! (window-showing *chat-list*) "and the list is not left standing"))
    (chats-test-reset!)))

(deftest 'chats-sections-by-group
  "grouped by group, one heading per group, by name, each with its members"
  (lambda ()
    (let ((ids (chats-test-open! 'group 'name)))
      (check-equal! (chats-test-heading-labels) '("zz-chats-one" "zz-chats-two")
                    "one heading per group, by name")
      (let ((one (car (chats-test-headings))))
        (check-equal! (ibuffer-heading-key one) (string-append "group:" (car ids))
                      "the heading names its group")
        (check-equal! (ibuffer-heading-count one) 2 "group one holds two chats")
        (check-equal! (ibuffer-heading-members one) '("*zz-chats-a*" "*zz-chats-b*")
                      "its members, by name"))
      (check-equal! (chats-test-names) '("*zz-chats-a*" "*zz-chats-b*" "*zz-chats-c*")
                    "the rows follow their headings")
      (check-contains! (buffer-text *chat-list*) "3 chats" "the meta counts the table's chats")
      (check-contains! (buffer-text *chat-list*) "idle" "a chat with no runtime is idle")
      (chats-test-reset!))))

(deftest 'chats-size-is-the-transcript
  "sorted by size, the longer transcript comes first, and the heading adds the bytes up"
  (lambda ()
    (chats-test-open! 'group 'name)
    (chats-test-log! "*zz-chats-a*" "zz-chats-a" 100)
    (chats-test-log! "*zz-chats-b*" "zz-chats-b" 5000)
    (ibuffer-set-sort! 'size *chat-list*)
    (check-equal! (ibuffer-sort *chat-list*) 'size "the sort is on the list buffer")
    (check-equal! (ibuffer-row-size "*zz-chats-b*") 5000 "the row reads the file's own bytes")
    (check-equal! (ibuffer-size-label "*zz-chats-b*") "4.9k" "and writes them the way dired does")
    (check-equal! (ibuffer-heading-members (car (chats-test-headings)))
                  '("*zz-chats-b*" "*zz-chats-a*") "b's transcript is longer")
    (check-equal! (ibuffer-heading-bytes (car (chats-test-headings))) 5100 "the heading sums")
    (check-equal! (ibuffer-row-size "*zz-chats-c*") #f "no transcript yet is no size")
    (chats-test-reset!)))

(deftest 'chats-fold-hides-a-section
  "a folded heading stands for its rows and stays a row of its own"
  (lambda ()
    (let ((ids (chats-test-open! 'group 'name)))
      (ibuffer-toggle-fold! (string-append "group:" (car ids)) *chat-list*)
      (check-equal! (chats-test-names) '("*zz-chats-c*") "group one's rows are gone")
      (let ((folded (car (chats-test-headings))))
        (check-true! (ibuffer-heading-folded? folded) "the heading is folded")
        (check-true! (list-selectable? *chat-list* folded) "and selectable")
        (check-equal! (ibuffer-heading-count folded) 2 "it still counts its members"))
      (ibuffer-toggle-fold! (string-append "group:" (car ids)) *chat-list*)
      (check-equal! (length (chats-test-names)) 3 "unfolded, the rows return")
      (chats-test-reset!))))

(deftest 'chats-group-row-stands-for-its-chats
  "a group row takes the highlight, and a verb on it reads every chat under it"
  (lambda ()
    (let* ((ids (chats-test-open! 'group 'name))
           (es (list-entries *chat-list*))
           (at (let loop ((k 0) (rest es))
                 (cond ((null? rest) #f)
                       ((ibuffer-heading? (car rest)) k)
                       (else (loop (+ k 1) (cdr rest)))))))
      (check-true! (string? (list-current *chat-list*))
                   "the list opens on a chat, not on the group over it")
      (check-true! (list-selectable? *chat-list* (nth at es))
                   "an open group row is a row like any other")
      (list-goto-index! *chat-list* at)
      (check-true! (ibuffer-heading? (list-current *chat-list*))
                   "and it takes the highlight")
      (check-equal! (agents-targets) '("*zz-chats-a*" "*zz-chats-b*")
                    "a verb on the group row acts on every chat under it")
      (check-false! (agents-current-buf)
                    "and no one chat answers as the chat at point")
      (chats-test-reset!))))

(deftest 'chats-sections-by-state
  "the grouping cycles none, group, state, model; a chat with no runtime sits under idle"
  (lambda ()
    (chats-test-open! 'none 'name)
    (run-command "chat-list-regroup")
    (check-equal! (ibuffer-grouping *chat-list*) 'group "none then group")
    (run-command "chat-list-regroup")
    (check-equal! (ibuffer-grouping *chat-list*) 'state "group then state")
    (check-equal! (chats-test-heading-labels) '("idle") "one section: idle")
    (check-equal! (length (chats-test-names)) 3 "every chat is idle")
    (run-command "chat-list-regroup")
    (check-equal! (ibuffer-grouping *chat-list*) 'model "state then model")
    (check-equal! (chats-test-heading-labels) '("no model") "a chat with no model says so")
    (run-command "chat-list-regroup")
    (check-equal! (ibuffer-grouping *chat-list*) 'none "model then none, and round again")
    (check-equal! (ibuffer-grouping "*ibuffer*") 'group "the *ibuffer* view keeps its own")
    (chats-test-reset!)))

(deftest 'a-word-nobody-titled-finds-its-chat
  "the filter line reads the text of every alive chat, and the row shows the words it found"
  (lambda ()
    (chats-test-open! 'none 'name)
    (buffer-append! "*zz-chats-c*" "we settled on the zzhaystack budget in the end")
    (run-command "chat-list-filter")
    (minibuffer-change! "zzhaystack")
    (check-equal! (filter (lambda (b) (string-prefix? "*zz-chats-" b)) (chats-test-names))
                  '("*zz-chats-c*") "only the chat that says the word")
    (check-contains! (chat-list-hit "*zz-chats-c*") "zzhaystack"
                     "the row shows the words around the hit")
    (minibuffer-cancel!)
    (check-false! (chat-list-hit "*zz-chats-c*") "closing the filter forgets the search")
    (check-equal! (list-query *chat-list*) "" "and the list stands unnarrowed")
    (chats-test-reset!)))

(deftest 'chats-narrowing-reads-the-summary
  "the narrowing matches the running summary, and the row leads with it"
  (lambda ()
    (chats-test-open! 'group 'name)
    (buffer-set-local! "*zz-chats-c*" 'chat-summary "Narrowed the retry budget to one lane.")
    (list-set-filters! *chat-list* (list (list "match" "retry budget")))
    (list-refresh! *chat-list*)
    (check-equal! (chats-test-names) '("*zz-chats-c*") "only the chat whose summary matches")
    (check-equal! (chats-test-heading-labels) '("zz-chats-two") "under its group")
    (check-contains! (buffer-text *chat-list*) "Narrowed the retry budget" "the row leads with the sentence")
    (chats-test-reset!)))

(deftest 'chat-prompt-splits-by-group
  "C-x c: the rows come in sections by group, each heading before its chats"
  (lambda ()
    (chats-test-open! 'group 'name)
    (let* ((rows (chat-prompt-rows))
           (mine (filter (lambda (r)
                           (or (member (car r) '("zz-chats-one" "zz-chats-two"))
                               (and (not (chat-prompt-separator? r))
                                    (string-prefix? "*zz-chats-" (nth 3 r)))))
                         rows)))
      (check-equal! (map car mine)
                    '("zz-chats-one" "*zz-chats-a*" "*zz-chats-b*" "zz-chats-two" "*zz-chats-c*")
                    "one heading per group, its chats under it")
      (check-true! (chat-prompt-separator? (car mine)) "the heading is a separator row")
      (check-equal! (length (car mine)) 3 "a heading has label, annotation, kind"))
    (chats-test-reset!)))
