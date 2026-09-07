;;; chats-list-test.scm --- *chats* is the ibuffer table over the chats:
;;; sections by group, the chat row kind, and the words a row shows.
;;;
;;; Every test opens the table by command and narrows it to its own
;;; chats, then reads the entries and the text. No test names a key.

(domain! 'testing)
(effects! '(write))

(define *chats-test-bufs* '("*zz-chats-a*" "*zz-chats-b*" "*zz-chats-c*"))

(define (chats-test-drop-group! name)
  (when (group-record-by-name name) (group-record-delete! name)))

(define (chats-test-reset!)
  (when (buffer-known? "*chats*")
    (buffer-set-locals! "*chats*"
      (list 'ibuffer-sort #f 'ibuffer-grouping #f 'ibuffer-collapsed '()))
    (list-filter-clear! "*chats*")
    (buffer-kill! "*chats*"))
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

;; a and b in group one, c in group two; answers (ONE TWO)
(define (chats-test-open! grouping sort)
  (chats-test-reset!)
  (let ((one (group-record-create! "zz-chats-one"))
        (two (group-record-create! "zz-chats-two")))
    (chats-test-chat! "*zz-chats-a*" one)
    (chats-test-chat! "*zz-chats-b*" one)
    (chats-test-chat! "*zz-chats-c*" two)
    (run-command "chat-list")
    (buffer-set-locals! "*chats*"
      (list 'ibuffer-grouping grouping 'ibuffer-sort sort 'ibuffer-collapsed '()))
    (list-set-filters! "*chats*" (list (list "match" "zz-chats-")))
    (list-refresh! "*chats*")
    (list one two)))

(define (chats-test-names)
  (filter string? (list-entries "*chats*")))

(define (chats-test-headings)
  (filter ibuffer-heading? (list-entries "*chats*")))

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

(deftest 'chats-is-the-ibuffer-table
  "*chats* wears the chat mode built from the ibuffer template, over the chat scope"
  (lambda ()
    (chats-test-open! 'group 'name)
    (check-equal! (buffer-local "*chats*" 'mode-name) "ichat-mode" "the mode")
    (check-equal! (buffer-local "*chats*" 'ibuffer-scope) 'chats "the scope by name")
    (check-true! (ibuffer-view? "*chats*") "a registered view")
    (check-equal! (ibuffer-row-kind "*zz-chats-a*") 'chat "a chat row wears the chat kind")
    (check-contains! (buffer-text "*chats*") "Chats" "the title")
    (check-contains! (buffer-text "*chats*") "3 chats" "the noun is chat")
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
      (check-contains! (buffer-text "*chats*") "2 chats" "the heading counts two")
      (check-contains! (buffer-text "*chats*") "idle" "a chat with no runtime is idle")
      (chats-test-reset!))))

(deftest 'chats-size-is-the-context
  "sorted by size, the fuller conversation comes first, and the heading adds the tokens up"
  (lambda ()
    (chats-test-open! 'group 'name)
    (buffer-set-local! "*zz-chats-a*" 'chat-context-used 100)
    (buffer-set-local! "*zz-chats-b*" 'chat-context-used 5000)
    (ibuffer-set-sort! 'size "*chats*")
    (check-equal! (ibuffer-sort "*chats*") 'size "the sort is on the list buffer")
    (check-equal! (ibuffer-heading-members (car (chats-test-headings)))
                  '("*zz-chats-b*" "*zz-chats-a*") "b holds more")
    (check-equal! (ibuffer-heading-bytes (car (chats-test-headings))) 5100 "the heading sums")
    (check-equal! (ibuffer-row-size "*zz-chats-c*") #f "no context yet is no size")
    (chats-test-reset!)))

(deftest 'chats-fold-hides-a-section
  "a folded heading stands for its rows and stays a row of its own"
  (lambda ()
    (let ((ids (chats-test-open! 'group 'name)))
      (ibuffer-toggle-fold! (string-append "group:" (car ids)) "*chats*")
      (check-equal! (chats-test-names) '("*zz-chats-c*") "group one's rows are gone")
      (let ((folded (car (chats-test-headings))))
        (check-true! (ibuffer-heading-folded? folded) "the heading is folded")
        (check-true! (list-selectable? "*chats*" folded) "and selectable")
        (check-equal! (ibuffer-heading-count folded) 2 "it still counts its members"))
      (ibuffer-toggle-fold! (string-append "group:" (car ids)) "*chats*")
      (check-equal! (length (chats-test-names)) 3 "unfolded, the rows return")
      (chats-test-reset!))))

(deftest 'chats-sections-by-state
  "grouped by mode, the chats with no runtime sit under idle; the command cycles the grouping"
  (lambda ()
    (chats-test-open! 'group 'name)
    (run-command "ibuffer-toggle-grouping")
    (check-equal! (ibuffer-grouping "*chats*") 'mode "group then mode")
    (check-equal! (chats-test-heading-labels) '("idle") "one section: idle")
    (check-equal! (ibuffer-heading-count (car (chats-test-headings))) 3 "every chat is idle")
    (run-command "ibuffer-toggle-grouping")
    (check-equal! (ibuffer-grouping "*chats*") 'directory "mode then directory")
    (run-command "ibuffer-toggle-grouping")
    (check-equal! (ibuffer-grouping "*chats*") 'group "directory then group")
    (check-equal! (ibuffer-grouping "*ibuffer*") 'group "the *ibuffer* view keeps its own")
    (chats-test-reset!)))

(deftest 'chats-narrowing-reads-the-summary
  "the narrowing matches the running summary, and the row leads with it"
  (lambda ()
    (chats-test-open! 'group 'name)
    (buffer-set-local! "*zz-chats-c*" 'chat-summary "Narrowed the retry budget to one lane.")
    (list-set-filters! "*chats*" (list (list "match" "retry budget")))
    (list-refresh! "*chats*")
    (check-equal! (chats-test-names) '("*zz-chats-c*") "only the chat whose summary matches")
    (check-equal! (chats-test-heading-labels) '("zz-chats-two") "under its group")
    (check-contains! (buffer-text "*chats*") "Narrowed the retry budget" "the row leads with the sentence")
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
