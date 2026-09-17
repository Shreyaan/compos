;;; buffer-set-text-test.scm --- one whole-buffer rewrite.

(deftest 'buffer-set-text-makes-the-buffer-hold-the-text-alone
  "a missing buffer is created; a read-only one is written past the flag; the flag is set when asked"
  (lambda ()
    (when (buffer-known? "*zz-set-text*") (buffer-kill! "*zz-set-text*"))
    (buffer-set-text! "*zz-set-text*" "one")
    (check-equal! (buffer-text "*zz-set-text*") "one" "created and written")
    (buffer-set-text! "*zz-set-text*" "two" #t)
    (check-equal! (buffer-text "*zz-set-text*") "two" "replaced, not appended")
    (check-true! (buffer-read-only? "*zz-set-text*") "read-only when asked")
    (buffer-set-text! "*zz-set-text*" "three")
    (check-equal! (buffer-text "*zz-set-text*") "three" "written past read-only")
    (check-true! (buffer-read-only? "*zz-set-text*") "the flag stays when not asked")
    (buffer-set-text! "*zz-set-text*" "four" #f)
    (check-false! (buffer-read-only? "*zz-set-text*") "and clears when asked")
    (buffer-kill! "*zz-set-text*")))
