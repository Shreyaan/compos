;;; buffer-create-file-test.scm --- a buffer name that is a file names that file.

(domain! 'testing)
(effects! '(write))

(define t--bcf-dir (string-append (compos-home) "/buffer-create-file-test"))

(define (t--bcf-file name text)
  (make-directory! t--bcf-dir)
  (let ((p (string-append t--bcf-dir "/" name)))
    (write-file! p text)
    p))

(define (t--bcf-drop! p)
  (when (buffer-exists? p) (buffer-mark-saved! p) (buffer-kill! p))
  (when (file-exists? p) (delete-file! p)))

(deftest 'buffer-create-on-a-file-name-loads-the-file
  "the clobber: an empty buffer under a file's name, then a save"
  (lambda ()
    (let ((p (t--bcf-file "config.scm" "(define kept #t)\n")))
      (check-true! (buffer-shadows-file? p)
                   "a file on disk with no buffer is shadowed by that name")
      (check-equal! (buffer-create p) p "buffer-create answers the name")
      (check-equal! (buffer-text p) "(define kept #t)\n"
                    "the buffer starts as the file")
      (check-equal! (buffer-path p) p "and it is the file's buffer")
      (check-false! (buffer-shadows-file? p)
                    "a buffer that read its file shadows nothing")
      (buffer-append! p "(define added #t)\n")
      (with-current-buffer p (lambda () (run-command "save-buffer")))
      (check-equal! (read-file p) "(define kept #t)\n(define added #t)\n"
                    "a save keeps the file's text and adds the edit")
      (t--bcf-drop! p))))

(deftest 'buffer-create-on-a-directory-or-a-new-name-stays-plain
  "a Dired listing is named by its directory; a new path is a new file"
  (lambda ()
    (make-directory! t--bcf-dir)
    (check-false! (buffer-shadows-file? t--bcf-dir)
                  "a directory is not shadowed")
    (buffer-create t--bcf-dir)
    (check-false! (buffer-path t--bcf-dir) "a directory buffer has no file")
    (buffer-kill! t--bcf-dir)
    (let ((p (string-append t--bcf-dir "/absent.txt")))
      (check-false! (buffer-shadows-file? p) "a name with no file is free")
      (buffer-create p)
      (check-false! (buffer-path p) "the buffer is plain")
      (check-equal! (buffer-text p) "" "and empty")
      (buffer-kill! p))))

(deftest 'a-path-named-buffer-that-never-read-its-file-is-a-clobber
  "the guard's predicate: raw-buffer-create bypasses the wrapper"
  (lambda ()
    (let ((p (t--bcf-file "raw.txt" "on disk\n")))
      (raw-buffer-create p)
      (buffer-append! p "in memory\n")
      (check-true! (buffer-shadows-file? p)
                   "a path-named buffer with no file and a file on disk")
      (buffer-kill! p)
      (t--bcf-drop! p))))
