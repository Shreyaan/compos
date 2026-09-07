;;; ibuffer-test.scm --- the ibuffer table's policy: sections, order, folds, ages.
;;;
;;; Every test opens the table by command and narrows it to its own
;;; buffers, then reads the entries and the text. No test names a key.

(domain! 'testing)
(effects! '(write))

(define *ibuffer-test-mode* "zz-ib-mode")

(define (ibuffer-test-buffer! name text mode)
  (test-buffer! name text)
  (buffer-set-local! name 'mode-name mode)
  name)

(define (ibuffer-test-reset!)
  (when (buffer-known? "*ibuffer*")
    (buffer-set-locals! "*ibuffer*"
      (list 'ibuffer-sort #f 'ibuffer-grouping #f 'ibuffer-collapsed '()))
    (list-filter-clear! "*ibuffer*")
    (buffer-kill! "*ibuffer*"))
  (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
            '("*zz-ib-a*" "*zz-ib-b*" "*zz-ib-c*"))
  (delete-other-windows!))

;; three buffers of one mode, sizes 1, 3, 2, shown in the order a c b
(define (ibuffer-test-open! grouping sort)
  (ibuffer-test-reset!)
  (ibuffer-test-buffer! "*zz-ib-a*" "1" *ibuffer-test-mode*)
  (ibuffer-test-buffer! "*zz-ib-b*" "333" *ibuffer-test-mode*)
  (ibuffer-test-buffer! "*zz-ib-c*" "22" *ibuffer-test-mode*)
  (switch-to-buffer! "*zz-ib-a*")
  (switch-to-buffer! "*zz-ib-c*")
  (switch-to-buffer! "*zz-ib-b*")
  (run-command "ibuffer")
  (buffer-set-locals! "*ibuffer*"
    (list 'ibuffer-grouping grouping 'ibuffer-sort sort 'ibuffer-collapsed '()))
  (list-set-filters! "*ibuffer*" (list (list "match" "zz-ib-")))
  (ibuffer-refresh!))

(define (ibuffer-test-names)
  (filter string? (list-entries "*ibuffer*")))

(define (ibuffer-test-headings)
  (map ibuffer-heading-label
       (filter ibuffer-heading? (list-entries "*ibuffer*"))))

(deftest 'ibuffer-age-label-reads-as-a-short-age
  "seconds become now, Ns, Nm, Nh, Nd; no time is an empty label"
  (lambda ()
    (check-equal! (ibuffer-age-label #f) "" "no time")
    (check-equal! (ibuffer-age-label 5) "now" "under ten seconds")
    (check-equal! (ibuffer-age-label 42) "42s" "seconds")
    (check-equal! (ibuffer-age-label 300) "5m" "minutes")
    (check-equal! (ibuffer-age-label 7200) "2h" "hours")
    (check-equal! (ibuffer-age-label 200000) "2d" "days")))

(deftest 'ibuffer-notes-when-a-buffer-was-last-shown
  "the hook stamps the shown buffer, and the row reads the age back"
  (lambda ()
    (check-true! (member 'ibuffer--seen-hook!
                         (hook-functions 'window-configuration-change-hook))
                 "the hook is on window-configuration-change-hook")
    (ibuffer-note-seen! "*zz-ib-seen*")
    (check-equal! (ibuffer-last-label "*zz-ib-seen*") "now" "just noted")
    (check-equal! (ibuffer-last-label "*zz-ib-never-shown*") "" "never noted")))

(deftest 'ibuffer-sections-by-mode
  "grouped by mode, one heading per mode, by name, with the member count"
  (lambda ()
    (ibuffer-test-open! 'mode 'name)
    (buffer-set-local! "*zz-ib-b*" 'mode-name "aa-other-mode")
    (ibuffer-refresh!)
    (check-equal! (ibuffer-test-headings) '("aa-other" "zz-ib") "one heading per mode, by name")
    (let ((heading (car (filter ibuffer-heading? (list-entries "*ibuffer*")))))
      (check-equal! (ibuffer-heading-count heading) 1 "the first section holds b")
      (check-equal! (ibuffer-heading-members heading) '("*zz-ib-b*") "its member"))
    (check-contains! (buffer-text "*ibuffer*") "2 buffers" "the zz-ib heading counts two")
    (ibuffer-test-reset!)))

(deftest 'ibuffer-sections-by-directory-put-no-file-last
  "grouped by directory, a buffer with no file sits under no file"
  (lambda ()
    (ibuffer-test-open! 'directory 'name)
    (check-equal! (ibuffer-test-headings) '("no file") "no file buffers make one section")
    (check-equal! (ibuffer-test-names) '("*zz-ib-a*" "*zz-ib-b*" "*zz-ib-c*") "by name inside it")
    (ibuffer-test-reset!)))

(deftest 'ibuffer-sorts-a-section-by-name-recency-or-size
  "the three orders, on the same three rows"
  (lambda ()
    (ibuffer-test-open! 'mode 'name)
    (check-equal! (ibuffer-test-names) '("*zz-ib-a*" "*zz-ib-b*" "*zz-ib-c*") "name order")
    (ibuffer-set-sort! 'recent)
    (check-equal! (ibuffer-test-names) '("*zz-ib-b*" "*zz-ib-c*" "*zz-ib-a*") "recent order is MRU")
    (ibuffer-set-sort! 'size)
    (check-equal! (ibuffer-test-names) '("*zz-ib-b*" "*zz-ib-c*" "*zz-ib-a*") "largest first")
    (check-contains! (car (ibuffer-meta "*ibuffer*")) "by mode · size" "the meta names the order")
    (ibuffer-test-reset!)))

(deftest 'ibuffer-toggle-sorting-mode-cycles
  "the cycle runs name, recent, size, name"
  (lambda ()
    (ibuffer-test-open! 'mode 'name)
    (run-command "ibuffer-toggle-sorting-mode")
    (check-equal! (ibuffer-sort) 'recent "name then recent")
    (run-command "ibuffer-toggle-sorting-mode")
    (check-equal! (ibuffer-sort) 'size "recent then size")
    (run-command "ibuffer-toggle-sorting-mode")
    (check-equal! (ibuffer-sort) 'name "size then name")
    (run-command "ibuffer-toggle-grouping")
    (check-equal! (ibuffer-grouping) 'directory "mode then directory")
    (run-command "ibuffer-toggle-grouping")
    (check-equal! (ibuffer-grouping) 'group "directory then group")
    (ibuffer-test-reset!)))

(deftest 'ibuffer-folds-a-section-into-its-heading
  "a folded heading is a row that carries the counts; the narrowing keeps it while a member matches"
  (lambda ()
    (ibuffer-test-open! 'mode 'name)
    (list-goto-first-entry "*ibuffer*")
    (check-true! (string? (ibuffer-current)) "point starts on a member row")
    (run-command "ibuffer-toggle-filter-group")
    (let ((es (list-entries "*ibuffer*")))
      (check-equal! (length es) 1 "only the heading remains")
      (check-true! (ibuffer-heading-folded? (car es)) "and it is folded")
      (check-equal! (ibuffer-heading-count (car es)) 3 "it counts its members")
      (check-equal! (ibuffer-heading-bytes (car es)) 6 "and their bytes"))
    (check-contains! (buffer-text "*ibuffer*") "▸" "the chevron points right")
    (check-contains! (car (ibuffer-meta "*ibuffer*")) "3 buffers" "the meta still counts the folded rows")
    (check-true! (ibuffer-heading? (ibuffer-current)) "the highlight can rest on the heading")
    (list-set-filters! "*ibuffer*" (list (list "match" "zz-ib-b")))
    (check-equal! (length (list-entries "*ibuffer*")) 1 "a member matches, so the heading stays")
    (list-set-filters! "*ibuffer*" (list (list "match" "zz-nothing-here")))
    (check-equal! (length (list-entries "*ibuffer*")) 0 "no member matches, so it goes")
    (list-set-filters! "*ibuffer*" (list (list "match" "zz-ib-")))
    (run-command "ibuffer-visit")
    (check-equal! (length (ibuffer-test-names)) 3 "RET on the heading opens it again")
    (ibuffer-test-reset!)))

(deftest 'ibuffer-headings-and-marks-wear-bands
  "a heading row and a marked row each get a background overlay across the row"
  (lambda ()
    (ibuffer-test-open! 'mode 'name)
    (let* ((es (list-entries "*ibuffer*"))
           (heading (car es))
           (ov (ibuffer-row-overlays "*ibuffer*" heading 100)))
      (check-equal! (length ov) 1 "one band on a heading")
      (check-equal! (nth 2 (car ov)) "ibuffer-heading" "the heading face")
      (check-equal! (car (car ov)) 100 "from the row's start")
      (check-true! (> (cadr (car ov)) 100) "to its end"))
    (list-mark! "*ibuffer*" "*zz-ib-a*" "*")
    (let ((ov (ibuffer-row-overlays "*ibuffer*" "*zz-ib-a*" 200)))
      (check-equal! (nth 2 (car ov)) "ibuffer-marked" "a marked row wears the tint"))
    (list-mark! "*ibuffer*" "*zz-ib-a*" #f)
    (check-equal! (ibuffer-row-overlays "*ibuffer*" "*zz-ib-a*" 200) '() "an unmarked buffer with no file wears nothing")
    (ibuffer-test-reset!)))

(deftest 'ibuffer-toggle-mark-marks-then-unmarks
  "list-toggle-mark on an unmarked row marks it and moves down; on a marked row it unmarks"
  (lambda ()
    (ibuffer-test-open! 'mode 'name)
    (list-goto-first-entry "*ibuffer*")
    (check-equal! (ibuffer-current) "*zz-ib-a*" "start on the first row")
    (run-command "list-toggle-mark")
    (check-equal! (list-mark-of "*ibuffer*" "*zz-ib-a*") "*" "the row is marked")
    (check-equal! (ibuffer-current) "*zz-ib-b*" "and point moved down")
    (list-goto-first-entry "*ibuffer*")
    (run-command "list-toggle-mark")
    (check-equal! (list-mark-of "*ibuffer*" "*zz-ib-a*") " " "the same key clears the mark")
    (ibuffer-test-reset!)))

(deftest 'ibuffer-group-kill-kills-the-section-group
  "K on a row under group sectioning kills that row's group: the members and the record"
  (lambda ()
    (ibuffer-test-reset!)
    (when (group-record-by-name "zz-ib-group")
      (group-record-delete! (group-record-by-name "zz-ib-group")))
    (test-buffer! "*zz-ib-a*" "")
    (test-buffer! "*zz-ib-b*" "")
    (let ((g (group-record-create! "zz-ib-group")))
      (buffer-add-group! "*zz-ib-a*" g)
      (buffer-add-group! "*zz-ib-b*" g)
      (switch-to-buffer! "*zz-ib-a*")
      (run-command "ibuffer")
      (buffer-set-locals! "*ibuffer*"
        (list 'ibuffer-grouping 'group 'ibuffer-sort 'name 'ibuffer-collapsed '()))
      (list-set-filters! "*ibuffer*" (list (list "match" "zz-ib-")))
      (ibuffer-refresh!)
      (list-goto-first-entry "*ibuffer*")
      (check-true! (string? (ibuffer-current)) "point is on a member row")
      (check-equal! (ibuffer-group-at) g "the row's section names the group")
      (run-command "ibuffer-group-kill")
      (check-false! (buffer-known? "*zz-ib-a*") "the first member is gone")
      (check-false! (buffer-known? "*zz-ib-b*") "the second member is gone")
      (check-false! (group-record-by-id g) "and the group record with them"))
    (ibuffer-test-reset!)))

(deftest 'ibuffer-narrows-by-mode-and-name
  "the typed narrowing reads the mode as well as the name"
  (lambda ()
    (ibuffer-test-open! 'mode 'name)
    (list-set-filters! "*ibuffer*" (list (list "match" *ibuffer-test-mode*)))
    (check-equal! (length (ibuffer-test-names)) 3 "every row wears the mode")
    (list-set-filters! "*ibuffer*" (list (list "match" "zz-ib-c")))
    (check-equal! (ibuffer-test-names) '("*zz-ib-c*") "and the name still narrows")
    (ibuffer-test-reset!)))

(deftest 'ibuffer-rows-show-the-modified-dot-and-the-details
  "a modified row wears the dot; the details hold the size and the mode"
  (lambda ()
    (ibuffer-test-open! 'mode 'name)
    (let ((cells (ibuffer-compact-cells "*ibuffer*" "*zz-ib-b*")))
      (check-equal! (car cells) '("●" "warn") "the dot on a modified buffer")
      (check-equal! (car (nth 2 cells)) "*zz-ib-b*" "the name")
      (check-contains! (car (nth 3 cells)) "3 · zz-ib" "size and mode"))
    (ibuffer-test-reset!)))

;;; --- RET goes to the buffer where it lives ------------------------------------

;; two groups, one buffer each, the frame standing in the first
(define (ibuffer-test-two-groups!)
  (ibuffer-test-reset!)
  (for-each (lambda (name)
              (let ((old (group-record-by-name name)))
                (when old (group-record-delete! old))))
            '("zzgrp-one" "zzgrp-two"))
  (test-buffer! "*zz-ib-a*" "")
  (test-buffer! "*zz-ib-b*" "")
  (let ((one (group-record-create! "zzgrp-one"))
        (two (group-record-create! "zzgrp-two")))
    (buffer-add-group! "*zz-ib-a*" one)
    (buffer-add-group! "*zz-ib-b*" two)
    (switch-to-group! one)
    (switch-to-buffer! "*zz-ib-a*")
    (list one two)))

;; open the table on one row alone and rest the highlight on it
(define (ibuffer-test-point-on! name)
  (run-command "ibuffer")
  (buffer-set-locals! "*ibuffer*"
    (list 'ibuffer-grouping 'group 'ibuffer-sort 'name 'ibuffer-collapsed '()))
  (list-set-filters! "*ibuffer*" (list (list "match" name)))
  (ibuffer-refresh!)
  (list-goto-first-entry "*ibuffer*")
  (ibuffer-current "*ibuffer*"))

(define (ibuffer-test-groups-reset! ids)
  (ibuffer-test-reset!)
  ;; a group with no saved layout builds one, and that makes its chat: the
  ;; buffers a verb made must not outlive the test that made them
  (for-each (lambda (b)
              (when (and (buffer-known? b) (string-contains? b "zzgrp-"))
                (buffer-kill! b)))
            (buffer-list))
  (for-each (lambda (id) (when (group-record-by-id id) (group-record-delete! id))) ids))

(deftest 'ibuffer-visit-enters-the-group-of-the-row
  "RET on a row of another group enters that group and focuses the buffer"
  (lambda ()
    (let* ((ids (ibuffer-test-two-groups!))
           (one (car ids))
           (two (cadr ids)))
      (check-equal! (frame-group) one "the frame stands in the first group")
      (check-equal! (ibuffer-test-point-on! "zz-ib-b") "*zz-ib-b*" "point is on the other group's row")
      (run-command "ibuffer-visit")
      (check-equal! (frame-group) two "the frame entered the row's group")
      (check-equal! (current-buffer) "*zz-ib-b*" "and the buffer is the one in hand")
      (ibuffer-test-groups-reset! ids))))

(deftest 'ibuffer-visit-stays-put-for-a-buffer-of-this-group
  "a row of the group at hand opens without a switch"
  (lambda ()
    (let* ((ids (ibuffer-test-two-groups!))
           (one (car ids)))
      (check-equal! (ibuffer-test-point-on! "zz-ib-a") "*zz-ib-a*" "point is on this group's row")
      (run-command "ibuffer-visit")
      (check-equal! (frame-group) one "the frame kept its group")
      (check-equal! (current-buffer) "*zz-ib-a*" "and the buffer is the one in hand")
      (ibuffer-test-groups-reset! ids))))

;;; --- C-. on a row --------------------------------------------------------------

(define (ibuffer-test-act! name)
  (let ((a (assoc name (actions-for 'buffer))))
    (check-true! (and a #t) (string-append "the menu offers " name))
    ((cadr a) (ibuffer-current "*ibuffer*"))))

(deftest 'ibuffer-row-is-a-typed-target
  "the row at point answers as a buffer target, it follows the highlight, and a heading answers nothing"
  (lambda ()
    (let ((ids (ibuffer-test-two-groups!)))
      (ibuffer-test-point-on! "zz-ib-")
      (check-equal! (target-at "*ibuffer*") '(buffer "*zz-ib-a*" "*zz-ib-a*")
                    "the row at point names itself")
      (let* ((rows (list-entries "*ibuffer*"))
             (i (list-index-of "*ibuffer*" rows "*zz-ib-b*"))
             (heading (list-index-of "*ibuffer*" rows
                                     (list-key "*ibuffer*"
                                               (car (filter ibuffer-heading? rows))))))
        (list-goto-index! "*ibuffer*" i)
        (check-equal! (target-at "*ibuffer*") '(buffer "*zz-ib-b*" "*zz-ib-b*")
                      "the target follows the highlight")
        (list-goto-index! "*ibuffer*" heading)
        (check-false! (ibuffer-target-at "*ibuffer*") "a heading is no target"))
      (ibuffer-test-groups-reset! ids))))

(deftest 'ibuffer-act-move-here-takes-the-row-into-this-group
  "move here leaves the row's old group and joins the group at hand"
  (lambda ()
    (let* ((ids (ibuffer-test-two-groups!))
           (one (car ids))
           (two (cadr ids)))
      (ibuffer-test-point-on! "zz-ib-b")
      (ibuffer-test-act! "move here")
      (check-equal! (buffer-group-ids "*zz-ib-b*") (list one) "the buffer moved to the group at hand")
      (check-equal! (group-buffers two) '() "and left the group it was in")
      (ibuffer-test-groups-reset! ids))))

(deftest 'ibuffer-act-add-here-keeps-the-old-membership
  "add here joins the group at hand and keeps the row's own group"
  (lambda ()
    (let* ((ids (ibuffer-test-two-groups!))
           (one (car ids))
           (two (cadr ids)))
      (ibuffer-test-point-on! "zz-ib-b")
      (ibuffer-test-act! "add here")
      (check-true! (buffer-in-group? "*zz-ib-b*" one) "the buffer joined the group at hand")
      (check-true! (buffer-in-group? "*zz-ib-b*" two) "and kept the group it was in")
      (ibuffer-test-act! "remove here")
      (check-false! (buffer-in-group? "*zz-ib-b*" one) "remove here undoes it")
      (check-true! (buffer-in-group? "*zz-ib-b*" two) "and leaves the other membership")
      (ibuffer-test-groups-reset! ids))))

(deftest 'ibuffer-act-reads-the-marks
  "a verb acts on every marked row, not on the row at point alone"
  (lambda ()
    (let* ((ids (ibuffer-test-two-groups!))
           (one (car ids))
           (two (cadr ids)))
      (ibuffer-test-point-on! "zz-ib-")
      (check-equal! (group-here) one "the group at hand is the one the frame came from")
      (check-equal! (ibuffer-current "*ibuffer*") "*zz-ib-a*" "point rests on the first row")
      (list-mark! "*ibuffer*" "*zz-ib-a*" "*")
      (list-mark! "*ibuffer*" "*zz-ib-b*" "*")
      (ibuffer-test-act! "add here")
      (check-true! (buffer-in-group? "*zz-ib-b*" one)
                   "the marked row that point does not rest on joined too")
      (check-true! (buffer-in-group? "*zz-ib-b*" two) "and kept the group it was in")
      (ibuffer-test-groups-reset! ids))))
