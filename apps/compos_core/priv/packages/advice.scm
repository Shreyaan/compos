;;; advice.scm --- named, removable function advice.

(category! 'functions)
(domain! 'functions)
(effects! '(write))

;; Loading the package again keeps registrations and their enabled state.
(unless (boundp '*advice-registry*)
  (set-symbol-value! '*advice-registry* '()))

(define (advice--symbol! value)
  (unless (symbol? value) (error "advice expects symbol names"))
  value)

(define (advice--function! value)
  (let ((fn (if (symbol? value) (symbol-value value) value)))
    (unless (procedure? fn) (error "advice expects a function"))
    fn))

(define (advice--find target name)
  (let loop ((rows *advice-registry*))
    (cond ((null? rows) #f)
          ((and (equal? (plist-get (car rows) 'target) target)
                (equal? (plist-get (car rows) 'name) name)) (car rows))
          (else (loop (cdr rows))))))

(define (advice--replace! old new)
  (set! *advice-registry*
    (if old
        (map (lambda (row) (if (equal? row old) new row)) *advice-registry*)
        (append *advice-registry* (list new)))))

(define (advice--dispatch target original args)
  ;; Snapshot enabled rows and resolve named handlers once for this call.
  (let* ((rows (filter (lambda (row) (plist-get row 'enabled)) (advice-list target)))
         (calls (map (lambda (row)
                       (list (plist-get row 'where)
                             (advice--function! (plist-get row 'function)))) rows))
         (before (filter (lambda (row) (equal? (car row) 'before)) calls))
         (after (filter (lambda (row) (equal? (car row) 'after)) calls))
         (around (filter (lambda (row) (equal? (car row) 'around)) calls))
         (body (lambda (&rest actual)
                 (for-each (lambda (row) (apply (cadr row) actual)) before)
                 (let ((result (apply original actual)))
                   (for-each (lambda (row) (apply (cadr row) actual)) after)
                   result))))
    (let ((chain
            (fold (lambda (next row)
                    (lambda (&rest actual)
                      (apply (cadr row) (cons next actual))))
                  body (reverse around))))
      (apply chain args))))

(define (advice-add! target where name function)
  (advice--symbol! target)
  (advice--symbol! name)
  (unless (member where '(before after around))
    (error "advice position must be before, after, or around"))
  (advice--function! (symbol-value target))
  (advice--function! function)
  (with-scheme-lock "advice-registry"
    (lambda ()
      (let* ((old (advice--find target name))
             (row (list 'target target 'name name 'where where 'function function
                        'enabled (if old (plist-get old 'enabled) #t))))
        (function-interpose! target
          (lambda (original args) (advice--dispatch target original args)))
        (advice--replace! old row)
        name))))

(define (advice--enabled-set! target name enabled)
  (with-scheme-lock "advice-registry"
    (lambda ()
      (let ((old (advice--find target name)))
        (unless old (error "no such advice"))
        (advice--replace! old
          (list 'target target 'name name 'where (plist-get old 'where)
                'function (plist-get old 'function) 'enabled enabled))
        enabled))))

(define (advice-enable! target name) (advice--enabled-set! target name #t))
(define (advice-disable! target name) (advice--enabled-set! target name #f))

(define (advice-remove! target name)
  (with-scheme-lock "advice-registry"
    (lambda ()
      (let ((old (advice--find target name)))
        (if (not old)
            #f
            (begin
              (when (= (length (advice-list target)) 1)
                (function-interpose! target #f))
              (set! *advice-registry*
                (filter (lambda (row) (not (equal? row old))) *advice-registry*))
              #t))))))

(public! 'advice-add! "(advice-add! TARGET WHERE NAME FUNCTION) — register before, after, or around advice; replacing NAME preserves its order and enabled state")
(public! 'advice-remove! "(advice-remove! TARGET NAME) — remove named advice; return #f if absent")
(public! 'advice-enable! "(advice-enable! TARGET NAME) — enable registered advice; error if absent")
(public! 'advice-disable! "(advice-disable! TARGET NAME) — disable registered advice without removing it; error if absent")

(effects! '(read))

(define (advice-list &optional target)
  (if target
      (filter (lambda (row) (equal? (plist-get row 'target) target)) *advice-registry*)
      *advice-registry*))

(define (advice-enabled? target name)
  (let ((row (advice--find target name)))
    (and row (plist-get row 'enabled))))

(public! 'advice-list "(advice-list [TARGET]) — registered advice plists in registration order, including disabled entries")
(public! 'advice-enabled? "(advice-enabled? TARGET NAME) — #t if the named advice exists and is enabled")
