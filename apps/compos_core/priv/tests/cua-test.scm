;;; cua-test.scm --- Shift-selection, by the commands under the keys.
;;;
;;; The keys are preferences and no test names one. What is worth a test:
;;; the mode is on from the start, and each cua-select-* command starts a
;;; region at point when there is none and extends it.

(domain! 'testing)
(effects! '(write))

(define t--cua-buf "zz-cua-select")

(define (t--cua! text point)
  (test-buffer! t--cua-buf text)
  (buffer-goto! t--cua-buf point)
  t--cua-buf)

(define (t--cua-run! cmd)
  (with-current-buffer t--cua-buf (lambda () (run-command cmd))))

(deftest 'shift-selection-is-on-from-the-start
  "no setup step stands between a fresh editor and a Shift selection"
  (lambda ()
    (check-true! (cua-mode-on?) "cua-mode is on at boot")))

(deftest 'a-select-command-starts-a-region-and-extends-it
  "point moves, the mark stays where the selection began"
  (lambda ()
    (t--cua! "alpha\nbravo\ncharlie\n" 2)
    (t--cua-run! "cua-select-buffer-end")
    (check-equal! (with-current-buffer t--cua-buf (lambda () (mark))) 2 "the mark holds the start")
    (check-equal! (buffer-point t--cua-buf) 20 "and point reached the end")
    (t--cua-run! "cua-select-buffer-start")
    (check-equal! (with-current-buffer t--cua-buf (lambda () (mark))) 2 "the same region, extended")
    (check-equal! (buffer-point t--cua-buf) 0 "now to the buffer's start")
    (buffer-kill! t--cua-buf)))

(deftest 'a-page-select-extends-by-a-screenful
  "the same page the plain motion steps by, with the region held"
  (lambda ()
    (let ((lines ""))
      (let loop ((i 0) (acc ""))
        (if (= i 80)
            (set! lines acc)
            (loop (+ i 1) (string-append acc "line\n"))))
      (t--cua! lines 0)
      (t--cua-run! "cua-select-page-down")
      (check-equal! (with-current-buffer t--cua-buf (lambda () (mark))) 0 "the mark holds the start")
      (check-true! (> (buffer-point t--cua-buf) 0) "and point moved a screenful")
      (buffer-kill! t--cua-buf))))

;;; The gate: the selections answer in a buffer you are editing, and a
;;; buffer you have just landed on keeps the plain meaning of the chords.

(define (t--cua-key keys)
  (with-current-buffer t--cua-buf (lambda () (key-binding keys))))

(define (t--cua-after! cmd)
  (with-current-buffer t--cua-buf (lambda () (editing--after-command! cmd))))

(deftest 'a-landing-buffer-keeps-the-plain-shift-chords
  "until a key says you are editing here, S-<left> walks buffers and M-S-<left> moves a group"
  (lambda ()
    (t--cua! "alpha bravo charlie\n" 0)
    (editing-state-off! t--cua-buf)
    (check-equal! (t--cua-key "S-<left>") "previous-buffer" "the buffer walk holds")
    (check-equal! (t--cua-key "M-S-<left>") "group-tab-left" "and the group move")
    (editing-state-on! t--cua-buf)
    (check-equal! (t--cua-key "S-<left>") "cua-select-backward" "armed, Shift selects")
    (check-equal! (t--cua-key "M-S-<left>") "group-tab-left" "the group move holds armed too")
    (buffer-kill! t--cua-buf)))

(deftest 'any-key-but-a-cua-chord-arms-the-buffer
  "a letter or an arrow puts the selections in force; the Shift chords never do"
  (lambda ()
    (t--cua! "alpha bravo charlie\n" 0)
    (editing-state-off! t--cua-buf)
    (t--cua-after! "previous-buffer")
    (check-false! (editing-state? t--cua-buf) "S-<left> leaves the buffer as it found it")
    (t--cua-after! "group-tab-left")
    (check-false! (editing-state? t--cua-buf) "and so does M-S-<left>")
    (t--cua-after! "cua-select-forward")
    (check-false! (editing-state? t--cua-buf) "a selection is no evidence either")
    (t--cua-after! "forward-char")
    (check-true! (editing-state? t--cua-buf) "a plain arrow arms it")
    (editing-state-off! t--cua-buf)
    (t--cua-after! "self-insert-command")
    (check-true! (editing-state? t--cua-buf) "and so does a letter")
    (buffer-kill! t--cua-buf)))
