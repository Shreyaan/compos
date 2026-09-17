;;; list-keys-test.scm --- a list mode's key table binds each key once.
;;;
;;; The table is installed in order and the last entry for a key wins,
;;; so a second entry is a silent override: dired's q was "dired-quit"
;;; and, three entries later, "quit-window" again.

(domain! 'testing)
(effects! '(read write))

(deftest 'no-list-mode-binds-one-key-twice
  "every 'keys table names each key once"
  (lambda ()
    (for-each
      (lambda (m)
        (let ((keys (map car (or (plist-get (cadr m) 'keys) '()))))
          (let loop ((ks keys) (seen '()))
            (unless (null? ks)
              (check-false! (member (car ks) seen)
                            (string-append (car m) " binds " (car ks) " twice"))
              (loop (cdr ks) (cons (car ks) seen))))))
      *list-modes*)))

(define-list-mode! "zz-keybar-mode"
  (list
    'buffer "*zz-keybar*"
    'rows (lambda (buf) (list "one" "two"))
    'key (lambda (buf row) row)
    'columns (lambda (buf) (list (list "name" #f)))
    'cells (lambda (buf row) (list row))
    'title (lambda (buf) "Keybar")
    'footer (lambda (buf) '(("q" "quit")))))

(deftest 'a-list-key-bar-defaults-to-the-keymap-component
  "a mode's footer renders through the shared ui/keymap component unless it opts out"
  (lambda ()
    (list-mode-show! "zz-keybar-mode")
    (let ((buf "*zz-keybar*"))
      (check-true! (list-keymap-component? buf)
                   "a list without 'keymap-component uses the component")
      (let ((blocks (buffer-local buf 'footer-line-blocks)))
        (check-true! (pair? blocks) "the footer arrives as blocks")
        (check-equal! (plist-get (car blocks) 'tag) "c-key-hints"
                      "and those blocks are the keymap component")))
    (buffer-kill! "*zz-keybar*")))

(define-list-mode! "zz-keybar-optout-mode"
  (list
    'buffer "*zz-keybar-optout*"
    'keymap-component #f
    'rows (lambda (buf) (list "one"))
    'key (lambda (buf row) row)
    'columns (lambda (buf) (list (list "name" #f)))
    'cells (lambda (buf row) (list row))
    'title (lambda (buf) "Keybar opt-out")
    'footer (lambda (buf) '(("q" "quit")))))

(deftest 'a-list-key-bar-can-opt-out-to-header-lines
  "a mode sets 'keymap-component #f to keep the header-line bar"
  (lambda ()
    (list-mode-show! "zz-keybar-optout-mode")
    (check-false! (list-keymap-component? "*zz-keybar-optout*")
                  "the opt-out is read back")
    (check-false! (buffer-local "*zz-keybar-optout*" 'footer-line-blocks)
                  "and no component blocks are set")
    (buffer-kill! "*zz-keybar-optout*")))