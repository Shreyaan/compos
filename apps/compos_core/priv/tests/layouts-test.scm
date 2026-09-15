;;; layouts-test.scm — responsive window policy is inspectable Scheme data.

(domain! 'testing)
(effects! '(read))

(deftest 'adaptive-layout-stacks-on-compact-frames
  "a narrow editor preserves horizontal reading room"
  (lambda ()
    (check-equal! (window-layout-for-width 80 3) 'main-bottom
                  "compact frames stack the secondary panes")))

(deftest 'adaptive-layout-keeps-a-third-rail-on-regular-frames
  "the common desktop arrangement is a main pane and side rail"
  (lambda ()
    (check-equal! (window-layout-for-width 140 3) 'main-right
                  "regular frames use the one-third rail")))

(deftest 'adaptive-layout-uses-monitor-width-for-wide-arrangements
  "wide frames promote three panes to columns and four to a grid"
  (lambda ()
    (check-equal! (window-layout-for-width 240 2) 'main-right
                  "two panes retain the main/rail hierarchy")
    (check-equal! (window-layout-for-width 240 3) 'columns
                  "three panes become exact thirds")
    (check-equal! (window-layout-for-width 240 4) 'grid
                  "four panes become a balanced grid")))

(deftest 'overview-uses-only-the-current-group
  "the overview includes each group member and excludes other buffers"
  (lambda ()
    (let ((stale (group-resolve-id "zz-ov-list")))
      (when stale (group-record-delete! stale)))
    (let ((work (test-buffer! "*zz-ov-list-work*" ""))
          (foreign (test-buffer! "*zz-ov-list-foreign*" ""))
          (group (group-record-create! "zz-ov-list"))
          (origin (current-buffer)))
      (buffer-add-group! work group)
      (switch-to-buffer! work)
      (set-frame-local! 'current-group group)
      (let* ((chat (group-chat group))
             (buffers (overview-buffers)))
        (check-true! (member work buffers) "the work buffer tiles")
        (check-true! (member chat buffers) "the group chat tiles")
        (check-false! (member foreign buffers) "the foreign buffer stays out")
        (switch-to-buffer! origin)
        (set-frame-local! 'current-group #f)
        (group-record-delete! group)
        (for-each buffer-kill! (list work chat foreign))))))

(deftest 'dashboard-one-line-keeps-the-expanded-dashboard-facts
  "the persistent modeline summary names the mode and input lane"
  (lambda ()
    (let ((buf "zz-dashboard-line"))
      (test-buffer! buf "hello\n")
      (switch-to-buffer! buf)
      (dashboard--sync! buf)
      ;; the compact line carries the facts the expanded segments carry:
      ;; mode, group, model, lane. Neither rendering names the read-only
      ;; state today.
      (check-contains! (buffer-local buf 'dashboard-line) "mode "
                       "the compact line names the mode")
      (check-contains! (buffer-local buf 'dashboard-line) "groups "
                       "the compact line names the groups")
      (check-contains! (buffer-local buf 'dashboard-line) "llm "
                       "the compact line names the model")
      (check-contains! (buffer-local buf 'dashboard-line) "lane api"
                       "the compact line names the lane")
      (buffer-kill! buf))))

;; A group is sealed: the third column never comes from outside it.
(deftest 'three-columns-in-a-group-fill-from-members-without-manufacturing-panes
  "in a group only ordinary members fill spare capacity"
  (lambda ()
    (let ((a (test-buffer! "zz-seal-a" "a"))
          (b (test-buffer! "zz-seal-b" "b"))
          (c (test-buffer! "zz-seal-c" "c"))
          (foreign (test-buffer! "zz-seal-foreign" "f"))
          (group (group-record-create! "zz-sealed-group")))
      (for-each (lambda (buf) (buffer-add-group! buf group)) (list a b c))
      ;; the foreign buffer is the most recent one: the old pool led with it
      (when (popup-open?) (popup-close!))
      (delete-other-windows!)
      (switch-to-buffer-here! foreign)
      (switch-to-buffer-here! a)
      (set-frame-local! 'current-group group)
      (let ((three (layout--three-columns (list a b))))
        (check-equal! (length three) 3 "a third column is found")
        (check-equal! (nth 2 three) c "it is the group's other member")
        (check-false! (member foreign three) "the foreign buffer stays out"))
      ;; Members run out: leave the target underfilled.
      (buffer-remove-group! c group)
      (let ((three (layout--three-columns (list a b))))
        (check-equal! three (list a b) "unused capacity stays empty")
        (check-false! (member foreign three) "the foreign buffer still stays out"))
      ;; One member occupies the frame by itself.
      (buffer-remove-group! b group)
      (let ((two (layout--three-columns (list a))))
        (check-equal! two (list a) "one member stays one pane")
        (check-false! (member foreign two) "and nothing foreign"))
      (set-frame-local! 'current-group #f)
      (for-each (lambda (buf) (when (buffer-known? buf) (buffer-kill! buf)))
                (append (group-buffers-as group 'scratch) (list a b c foreign)))
      (group-record-delete! group))))

(deftest 'three-columns-outside-a-group-fill-from-the-buffer-mru
  "with no group the third column is the most recent other buffer"
  (lambda ()
    (let ((a (test-buffer! "zz-open-a" "a"))
          (b (test-buffer! "zz-open-b" "b"))
          (recent (test-buffer! "zz-open-recent" "r")))
      (set-frame-local! 'current-group #f)
      (switch-to-buffer! recent)
      (switch-to-buffer! a)
      (let ((three (layout--three-columns (list a b))))
        (check-equal! (length three) 3 "a third column is found")
        (check-equal! (nth 2 three) recent "it is the most recent other buffer"))
      (for-each buffer-kill! (list a b recent)))))

(deftest 'dashboard-sync-writes-its-four-locals-together
  "one sync lands the line, the blocks, the modeline name and the context"
  (lambda ()
    (let ((buf "zz-dashboard-sync"))
      (test-buffer! buf "hello\n")
      (switch-to-buffer! buf)
      (dashboard--sync! buf)
      (check-true! (string? (buffer-local buf 'dashboard-line)) "the compact line landed")
      (check-true! (pair? (buffer-local buf 'dashboard-line-blocks)) "the blocks landed")
      (check-equal! (buffer-local buf 'modeline-name) buf "the modeline name landed")
      (check-true! (member 'dashboard-line (buffer-local buf 'desktop-skip-locals))
                   "the line is runtime state the desktop skips")
      (buffer-kill! buf))))
