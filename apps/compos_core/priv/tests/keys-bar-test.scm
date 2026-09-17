;;; keys-bar-test.scm — the keymap card every list-mode buffer carries.

(domain! 'testing)
(effects! '(write execute))

(define (t--keys-bar buf)
  (car (list-keys-bar-blocks buf)))

(define (t--keys-bar-more blocks)
  ;; the `? all N` span on the card's line
  (let* ((line (car (plist-get blocks 'children)))
         (more (cadr (plist-get line 'children))))
    (cadr (cadr (plist-get more 'segs)))))

(deftest 'a-list-buffer-carries-its-mode-keys-on-a-card
  "the mode declares the main keys as its footer; the card adds ? all N"
  (lambda ()
    (let ((buf "*zz-keys-bar*"))
      (test-buffer! buf "")
      (with-current-buffer buf (lambda () (set-mode! "ibuffer-mode")))
      (let ((bar (t--keys-bar buf)))
        (check-equal! (plist-get bar 'tag) "c-keys-bar" "the card is one block")
        (check-equal! (plist-get bar 'class) "c-keys-bar" "folded at first")
        (check-true! (string-prefix? "all " (t--keys-bar-more bar))
                     "the line ends in ? all N")
        (check-equal! (length (plist-get bar 'children)) 1
                      "and holds no grid while folded")
        ;; every pressable key is one element, so it is always one colour
        (let* ((line (car (plist-get bar 'children)))
               (strip (car (plist-get line 'children)))
               (row (car (plist-get strip 'children)))
               (key (car (plist-get row 'segs))))
          (check-equal! (caddr key) "c-action-key" "a key draws as c-action-key")))
      (buffer-kill! buf))))

(deftest 'question-mark-grows-the-card-into-the-whole-map
  "the grids come from the mode's own keymap and every list's map, a key shown once"
  (lambda ()
    (let ((buf "*zz-keys-bar-grow*"))
      (test-buffer! buf "")
      (with-current-buffer buf (lambda () (set-mode! "ibuffer-mode")))
      (with-current-buffer buf (lambda () (run-command "list-keys-toggle")))
      (let ((bar (t--keys-bar buf))
            (grids (list-keys-grids buf)))
        (check-equal! (plist-get bar 'class) "c-keys-bar expanded" "the card grew")
        (check-equal! (t--keys-bar-more bar) "fewer" "and offers to fold")
        (check-true! (> (length (plist-get bar 'children)) 1) "a grid per keymap follows")
        (check-equal! (car (car grids)) "ibuffer" "the mode's own map leads")
        (check-equal! (car (car (reverse grids))) "list" "every list's map closes")
        (let ((seqs (apply append (map (lambda (g) (map car (cadr g))) grids))))
          (check-equal! (length seqs) (length (t--dedupe seqs))
                        "a key the mode shadows shows once")))
      (with-current-buffer buf (lambda () (run-command "list-keys-toggle")))
      (check-equal! (plist-get (t--keys-bar buf) 'class) "c-keys-bar" "? folds it back")
      (buffer-kill! buf))))

(define (t--dedupe xs)
  (let loop ((rest xs) (seen '()))
    (cond ((null? rest) (reverse seen))
          ((member (car rest) seen) (loop (cdr rest) seen))
          (else (loop (cdr rest) (cons (car rest) seen))))))

(deftest 'a-list-without-a-footer-carries-no-card
  "a mode that declared no keys gets no card, not an empty one"
  (lambda ()
    (let ((buf "*zz-keys-bar-none*"))
      (test-buffer! buf "")
      (check-false! (list-keys-bar-blocks buf) "no footer, no card")
      (buffer-kill! buf))))
