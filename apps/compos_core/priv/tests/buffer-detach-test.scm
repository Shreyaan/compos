;;; buffer-detach-test.scm --- a buffer forgets its file and keeps its text.

(domain! 'testing)
(effects! '(write))

(define t--bd-dir (string-append (compos-home) "/buffer-detach-test"))
(define t--bd-buf "*buffer-detach-test*")

(define (t--bd-path name)
  (make-directory! t--bd-dir)
  (string-append t--bd-dir "/" name))

(define (t--bd-drop! p)
  (when (buffer-exists? t--bd-buf) (buffer-mark-saved! t--bd-buf) (buffer-kill! t--bd-buf))
  (when (file-exists? p) (delete-file! p)))

(deftest 'detach-forgets-the-adopted-path
  "the clobber: a chat given (buffer-save! PATH) owns PATH until it is detached"
  (lambda ()
    (let ((p (t--bd-path "adopted.txt")))
      (t--bd-drop! p)
      (buffer-create t--bd-buf)
      (buffer-append! t--bd-buf "transcript\n")
      (with-current-buffer t--bd-buf (lambda () (buffer-save! p)))
      (check-equal! (buffer-path t--bd-buf) p "save-as adopts the path")
      (check-true! (detach-buffer! t--bd-buf) "detach answers #t")
      (check-false! (buffer-path t--bd-buf) "the buffer forgets its file")
      (check-equal! (buffer-text t--bd-buf) "transcript\n" "the text stays")
      (write-file! p "on disk\n")
      (buffer-append! t--bd-buf "more\n")
      (check-false! (with-current-buffer t--bd-buf (lambda () (buffer-save!)))
                    "a save with no path writes nothing")
      (check-equal! (read-file p) "on disk\n" "the file keeps its own text")
      (t--bd-drop! p))))

(deftest 'detach-command-acts-on-the-current-buffer
  "M-x buffer-detach is the same mechanism from the keyboard"
  (lambda ()
    (let ((p (t--bd-path "command.txt")))
      (t--bd-drop! p)
      (buffer-create t--bd-buf)
      (with-current-buffer t--bd-buf (lambda () (buffer-save! p)))
      (with-current-buffer t--bd-buf (lambda () (run-command "buffer-detach")))
      (check-false! (buffer-path t--bd-buf) "the command detaches the current buffer")
      (t--bd-drop! p))))

(deftest 'detach-on-an-unknown-name-is-false
  "no buffer, no change"
  (lambda ()
    (check-false! (detach-buffer! "*no-such-buffer-for-detach*") "#f for an unknown name")))
