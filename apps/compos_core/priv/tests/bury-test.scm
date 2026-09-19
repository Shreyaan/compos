;;; bury-test.scm --- Emacs bury-buffer and unbury-buffer.

(domain! 'testing)
(effects! '(write))

(deftest 'bury-moves-a-buffer-to-the-end-and-its-window-shows-the-one-before
  "bury-buffer! puts BUF last in the buffer list; the window leaves it"
  (lambda ()
    (let ((a (test-buffer! "zz-bury-a" "a"))
          (b (test-buffer! "zz-bury-b" "b")))
      (switch-to-buffer! a)
      (switch-to-buffer! b)
      (bury-buffer! b)
      (check-equal! (car (reverse (buffer-list-mru))) b "the buried buffer is last")
      (check-false! (equal? (window-buffer (active-window)) b)
                    "the window no longer shows the buried buffer")
      (check-equal! (window-buffer (active-window)) a "it shows the buffer it had before")
      (buffer-kill! a)
      (buffer-kill! b))))

(deftest 'unbury-switches-to-the-last-buffer
  "unbury-buffer! brings back the buffer at the end of the list"
  (lambda ()
    (let ((a (test-buffer! "zz-unbury-a" "a"))
          (b (test-buffer! "zz-unbury-b" "b")))
      (switch-to-buffer! a)
      (switch-to-buffer! b)
      (bury-buffer! b)
      (unbury-buffer!)
      (check-equal! (window-buffer (active-window)) b "the buried buffer is back")
      (buffer-kill! a)
      (buffer-kill! b))))

(deftest 'burying-a-buffer-no-window-shows-keeps-the-window
  "bury-buffer! on a buffer the selected window does not show moves only the list"
  (lambda ()
    (let ((a (test-buffer! "zz-bury-x" "x"))
          (b (test-buffer! "zz-bury-y" "y")))
      (switch-to-buffer! a)
      (bury-buffer! b)
      (check-equal! (window-buffer (active-window)) a "the window keeps its buffer")
      (check-equal! (car (reverse (buffer-list-mru))) b "the other buffer is last")
      (buffer-kill! a)
      (buffer-kill! b))))
