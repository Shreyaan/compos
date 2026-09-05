;;; advice-test.scm --- advice policy, exercised through the Scheme API.
(domain! 'testing)
(effects! '(write))

(define *advice-test-log* '())
(define (advice-test-note value)
  (set! *advice-test-log* (append *advice-test-log* (list value))))
(define (advice-test-target x)
  (advice-test-note 'target)
  (+ x 1))
(define (advice-test-before x) (advice-test-note (list 'before x)))
(define (advice-test-after x) (advice-test-note (list 'after x)) 'ignored)
(define (advice-test-reset!)
  (for-each (lambda (row)
              (when (string-prefix? "advice-test-" (symbol->string (plist-get row 'target)))
                (advice-remove! (plist-get row 'target) (plist-get row 'name))))
            (advice-list))
  (set! *advice-test-log* '()))

(deftest 'advice-before-after-order-and-result
  "before and after receive arguments in registration order and preserve the result"
  (lambda ()
    (advice-test-reset!)
    (advice-add! 'advice-test-target 'after 'after-one 'advice-test-after)
    (advice-add! 'advice-test-target 'before 'before-one 'advice-test-before)
    (advice-add! 'advice-test-target 'before 'before-two
      (lambda (x) (advice-test-note 'second)))
    (check-equal! (advice-test-target 7) 8 "the original result")
    (check-equal! *advice-test-log* '((before 7) second target (after 7)) "ordered effects")
    (check-true! (procedure? advice-test-target) "the binding stays callable")
    (check-equal! (apply advice-test-target '(9)) 10 "apply takes the same path")))

(deftest 'advice-disable-update-enable-remove
  "disabled advice remains registered and stays disabled when replaced"
  (lambda ()
    (advice-test-reset!)
    (advice-add! 'advice-test-target 'after 'member 'advice-test-after)
    (advice-disable! 'advice-test-target 'member)
    (check-false! (advice-enabled? 'advice-test-target 'member) "disabled")
    (advice-add! 'advice-test-target 'before 'member 'advice-test-before)
    (check-equal! (length (advice-list 'advice-test-target)) 1 "no duplicate")
    (check-false! (plist-get (car (advice-list 'advice-test-target)) 'enabled) "inspect disabled row")
    (advice-test-target 1)
    (check-equal! *advice-test-log* '(target) "disabled handler does not run")
    (set! *advice-test-log* '())
    (advice-enable! 'advice-test-target 'member)
    (advice-test-target 2)
    (check-equal! *advice-test-log* '((before 2) target) "updated handler runs")
    (check-true! (advice-remove! 'advice-test-target 'member) "removed")
    (check-false! (advice-remove! 'advice-test-target 'member) "removing absent advice is harmless")
    (check-equal! (advice-list 'advice-test-target) '() "registration is gone")))

(deftest 'advice-around-nesting-and-short-circuit
  "around advice controls arguments and results; the first registration is outermost"
  (lambda ()
    (advice-test-reset!)
    (advice-add! 'advice-test-target 'before 'before 'advice-test-before)
    (advice-add! 'advice-test-target 'after 'after 'advice-test-after)
    (advice-add! 'advice-test-target 'around 'outer
      (lambda (next x)
        (advice-test-note 'outer-in)
        (let ((result (next (+ x 10))))
          (advice-test-note 'outer-out)
          (* result 2))))
    (advice-add! 'advice-test-target 'around 'inner
      (lambda (next x) (advice-test-note 'inner) (next x)))
    (check-equal! (advice-test-target 1) 24 "around changes arguments and result")
    (check-equal! *advice-test-log*
      '(outer-in inner (before 11) target (after 11) outer-out) "nesting")
    (advice-add! 'advice-test-target 'around 'outer (lambda (next x) 'skipped))
    (set! *advice-test-log* '())
    (check-equal! (advice-test-target 1) 'skipped "around can bypass")
    (check-equal! *advice-test-log* '() "bypass skips inner advice and target")))

(deftest 'advice-redefinition-and-lexical-shadow
  "advice survives global writes while local functions and old aliases stay independent"
  (lambda ()
    (advice-test-reset!)
    (set-symbol-value! 'advice-test-fresh (lambda (x) (+ x 1)))
    (let ((alias advice-test-fresh))
      (advice-add! 'advice-test-fresh 'after 'after 'advice-test-after)
      (check-equal! (alias 1) 2 "old alias returns its value")
      (check-equal! *advice-test-log* '() "old alias has no advice"))
    (set! advice-test-fresh (lambda (x) (+ x 2)))
    (check-equal! (advice-test-fresh 1) 3 "set! replaces the original")
    (set-symbol-value! 'advice-test-fresh (lambda (x) (+ x 3)))
    (check-equal! (advice-test-fresh 1) 4 "reflection replaces the original")
    (check-equal! *advice-test-log* '((after 1) (after 1)) "both retain advice")
    (set! *advice-test-log* '())
    (let ()
      (define (advice-test-fresh x) (+ x 20))
      (check-equal! (advice-test-fresh 1) 21 "local definition shadows global"))
    (check-equal! *advice-test-log* '() "local shadow is not advised")
    (advice-remove! 'advice-test-fresh 'after)
    (check-equal! (advice-test-fresh 1) 4 "removal restores the latest original")))

(deftest 'advice-handlers-resolve-by-name-and-accept-rest-arguments
  "named handler replacement takes effect and rest arguments reach handlers"
  (lambda ()
    (advice-test-reset!)
    (set-symbol-value! 'advice-test-many (lambda (&rest args) args))
    (set-symbol-value! 'advice-test-handler (lambda (&rest args) (advice-test-note args)))
    (advice-add! 'advice-test-many 'after 'record 'advice-test-handler)
    (check-equal! (advice-test-many 1 2 3) '(1 2 3) "variadic result")
    (set-symbol-value! 'advice-test-handler (lambda (&rest args) (advice-test-note 'new)))
    (advice-test-many)
    (check-equal! *advice-test-log* '((1 2 3) new) "current handler and original argument list")))

(deftest 'advice-errors-and-validation
  "invalid registration is rejected and after advice runs only on normal return"
  (lambda ()
    (advice-test-reset!)
    (set-symbol-value! 'advice-test-fail (lambda (x) (error "target failed")))
    (advice-add! 'advice-test-fail 'after 'after 'advice-test-after)
    (check-equal! (car (eval-string-safe "(advice-test-fail 1)")) 'error "target error propagates")
    (check-equal! *advice-test-log* '() "after did not run")
    (advice-add! 'advice-test-target 'before 'fail (lambda (x) (error "before failed")))
    (check-equal! (car (eval-string-safe "(advice-test-target 1)")) 'error "before error propagates")
    (check-equal! *advice-test-log* '() "target did not run")
    (check-equal! (car (eval-string-safe "(advice-add! 'advice-test-target 'wrong 'invalid 'advice-test-after)")) 'error "invalid position")
    (check-equal! (car (eval-string-safe "(advice-add! 'advice-test-missing 'after 'invalid 'advice-test-after)")) 'error "missing target")
    (check-equal! (car (eval-string-safe "(advice-add! 'advice-test-target 'after 'invalid 42)")) 'error "non-callable handler")
    (check-equal! (car (eval-string-safe "(advice-enable! 'advice-test-target 'missing)")) 'error "missing toggle")
    (check-equal! (length (advice-list 'advice-test-target)) 1 "invalid entries do not register")))

(deftest 'advice-invocations-snapshot-enabled-handlers
  "disabling a handler within a call changes the next invocation"
  (lambda ()
    (advice-test-reset!)
    (advice-add! 'advice-test-target 'before 'disable
      (lambda (x) (advice-disable! 'advice-test-target 'after)))
    (advice-add! 'advice-test-target 'after 'after 'advice-test-after)
    (advice-test-target 1)
    (advice-test-target 2)
    (check-equal! *advice-test-log* '(target (after 1) target) "the active call keeps its snapshot")))
