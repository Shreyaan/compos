;;; migrations.scm --- one-shot buffer migrations, run once per buffer.
;;;
;;; A saved desktop can carry a buffer in a shape the code no longer
;;; writes: an old local, marker bytes in the text, a mode under its old
;;; name. Each such shape gets ONE migration here, named and dated. The
;;; pass runs on restore, before the mode setup, and stamps the buffer
;;; ('migrations, a persisted local), so a migration runs once per buffer
;;; and never again. A migration checks the old shape itself: a buffer
;;; made in this process has no stamp, and the pass runs every migration
;;; on it after the next restart.
;;;
;;; The cut-off: a migration lives 90 days from its SINCE date. After
;;; that the code, its registration and its test go; a desktop older than
;;; the cut-off is restored as it is. M-x list-migrations shows the dates.

(domain! 'desktop)
(effects! '(write))

;; ((NAME SINCE FN) ...) in registration order
(define *buffer-migrations* '())

(public! 'define-buffer-migration!
  "(define-buffer-migration! NAME SINCE FN) — register FN as the one-shot migration NAME; SINCE is its date, \"YYYY-MM-DD\"; FN takes the buffer")
(define (define-buffer-migration! name since fn)
  (set! *buffer-migrations*
    (append (filter (lambda (m) (not (equal? (car m) name))) *buffer-migrations*)
            (list (list name since fn)))))

(public! 'buffer-migrations-done
  "(buffer-migrations-done BUF) — the names of the migrations that ran on BUF")
(define (buffer-migrations-done buf)
  (or (buffer-local buf 'migrations) '()))

;; one migration that throws does not stop the restore or the others
(define (migration--run! m buf)
  (unless (ignore-errors (lambda () ((car (cdr (cdr m))) buf) #t))
    (message (string-append "migration " (symbol->string (car m))
                            " failed on " buf))))

(public! 'migrate-buffer!
  "(migrate-buffer! BUF) — run every registered migration BUF has not seen, and stamp it; return the names that ran")
(define (migrate-buffer! buf)
  (let* ((done (buffer-migrations-done buf))
         (due (filter (lambda (m) (not (member (car m) done))) *buffer-migrations*)))
    (when (pair? due)
      (for-each (lambda (m) (migration--run! m buf)) due)
      (buffer-set-local! buf 'migrations (append done (map car due))))
    (map car due)))

(add-hook! 'buffer-restore-hook 'migrate-buffer!)

(effects! '(read))
(define-command "list-migrations" "Show the registered one-shot migrations and their dates"
  (lambda ()
    (message
      (if (null? *buffer-migrations*)
          "No migrations are registered"
          (string-join
            (map (lambda (m) (string-append (symbol->string (car m)) " since " (car (cdr m))))
                 *buffer-migrations*)
            "; ")))))
