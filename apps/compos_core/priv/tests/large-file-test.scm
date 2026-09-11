;;; large-file-test.scm --- a file too big to open, and the way in.
;;;
;;; The cost of a big file is not the read. The text becomes a rope, the
;;; rope becomes a checkpoint on disk, and the checkpoint restores at
;;; every boot. A 189 MB screen recording opened by accident pinned the
;;; Editor for seven seconds on each boot and took the desktop's globals
;;; down with it.
;;;
;;; So a visit refuses. The reader who means it answers a question, and
;;; the buffer that question opens is not persistent.

(domain! 'testing)
(effects! '(write))

(define t--lf-dir (string-append (compos-home) "/large-file-test"))

(define (t--lf-file name bytes)
  (make-directory! t--lf-dir)
  (let ((p (string-append t--lf-dir "/" name)))
    (write-file! p (string-repeat "x" bytes))
    p))

(define (t--lf-drop! p)
  (when (buffer-exists? p) (buffer-mark-saved! p) (buffer-kill! p))
  (when (file-exists? p) (delete-file! p)))

(deftest 'a-visit-refuses-a-file-over-the-threshold
  "the loss this prevents: one accidental visit, then every boot pays"
  (lambda ()
    (let ((p (t--lf-file "big.txt" 4096))
          (was large-file-warning-threshold))
      (set! large-file-warning-threshold 1024)
      (check-true! (file-too-big? p) "a file over the threshold is too big")
      (check-false! (visit p) "and a visit of it opens nothing")
      (check-false! (buffer-known? p) "so no buffer holds it")
      (check-false! (visit-quietly p) "a quiet visit refuses the same way")
      (check-false! (buffer-known? p) "and still no buffer holds it")

      ;; the size is the whole reason, so the message carries it
      (check-true! (string-contains? (file-too-big-message p)
                                     "large-file-warning-threshold")
                   "the message names the variable that sets the cap")

      (set! large-file-warning-threshold was)
      (t--lf-drop! p))))

(deftest 'the-way-in-opens-the-file-for-this-session-only
  "one yes must not cost every later boot"
  (lambda ()
    (let ((p (t--lf-file "big-anyway.txt" 4096))
          (was large-file-warning-threshold))
      (set! large-file-warning-threshold 1024)
      (check-equal! (visit-anyway p) p "visit-anyway opens the file")
      (check-true! (buffer-known? p) "so the buffer is there")
      (check-false! (buffer-persistent? p)
                    "and it holds the file for this session only")

      ;; a buffer that is open already is never too big: the work is paid
      (check-false! (file-too-big? p) "an open file is not too big to open")

      (set! large-file-warning-threshold was)
      (t--lf-drop! p))))

(deftest 'a-file-under-the-threshold-opens-as-before
  "the cap holds the big ones and nothing else"
  (lambda ()
    (let ((p (t--lf-file "small.txt" 16))
          (was large-file-warning-threshold))
      (set! large-file-warning-threshold 1024)
      (check-false! (file-too-big? p) "a small file is not too big")
      (check-equal! (visit p) p "and a visit opens it")
      (check-true! (buffer-persistent? p)
                   "an ordinary file buffer comes back at the next boot")

      (set! large-file-warning-threshold was)
      (t--lf-drop! p))))

(deftest 'a-zero-threshold-removes-the-cap
  "the variable is the policy, and 0 turns it off"
  (lambda ()
    (let ((p (t--lf-file "uncapped.txt" 4096))
          (was large-file-warning-threshold))
      (set! large-file-warning-threshold 0)
      (check-false! (file-too-big? p) "no file is too big without a cap")
      (check-equal! (visit p) p "so the visit opens it")

      (set! large-file-warning-threshold was)
      (t--lf-drop! p))))

(deftest 'a-file-shown-from-disk-is-never-too-big
  "the cap counts the cost of a read, and a viewer that reads the file itself pays none of it"
  (lambda ()
    (let ((p (t--lf-file "shown.mov" 4096))
          (was large-file-warning-threshold))
      (set! large-file-warning-threshold 1024)
      (check-true! (file-shown-from-disk? p) "a video opens in the browser viewer")
      (check-false! (file-too-big? p) "so the cap does not apply to it")
      (check-equal! (visit p) p "and the visit opens it whatever its size")
      (check-equal! (buffer-size p) 0 "the buffer holds none of the file")
      (check-true! (buffer-unread-file? p) "and it knows it never read it")

      (set! large-file-warning-threshold was)
      (t--lf-drop! p))))
