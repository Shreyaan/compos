;;; decide-test.scm --- packages/decide.scm: one typed-decision API over
;;; three backends.
;;;
;;; No test here reaches a backend. What this package owns is which
;;; backend a call chooses, that the options a caller passes arrive, and
;;; that an answer reads the same whichever backend wrote it.

(domain! 'testing)
(effects! '(read))

(define t--decide-seen '())

;; a backend that answers nothing and records what it was handed
(define (t--decide-stub!)
  (set! t--decide-seen '())
  (set! decide--call-laya
    (lambda (state questions model timeout)
      (set! t--decide-seen (list 'laya state model timeout))
      '(answers () usage (0 0 laya))))
  (set! decide--call-jev
    (lambda (state questions model timeout)
      (set! t--decide-seen (list 'jev state model timeout))
      '(answers () usage (0 0 jev)))))

(deftest 'decide-the-options-a-caller-passes-arrive
  "a rest parameter this interpreter does not read is every option lost"
  (lambda ()
    (let ((held-laya decide--call-laya)
          (held-jev decide--call-jev))
      (t--decide-stub!)
      (decide "a passage" '(q (type "noul" instructions "is it?")) 'backend 'laya)
      (check-equal! (nth 0 t--decide-seen) 'laya "the backend a caller named")
      (decide "a passage" '(q (type "noul" instructions "is it?"))
              'backend 'laya 'timeout 7)
      (check-equal! (nth 3 t--decide-seen) 7 "and the timeout beside it")
      (decide "a passage" '(q (type "noul" instructions "is it?")) 'backend 'jev)
      (check-equal! (nth 0 t--decide-seen) 'jev "another backend, the same way")
      (set! decide--call-laya held-laya)
      (set! decide--call-jev held-jev))))

(deftest 'decide-a-backend-is-called-and-not-returned
  "the dispatch table answers (NAME FN), and the function is the second"
  (lambda ()
    (let ((held decide--call-laya))
      (t--decide-stub!)
      (let ((answer (decide "a passage" '(q (type "noul" instructions "is it?"))
                            'backend 'laya)))
        (check-true! (pair? answer) "a call answers a result")
        (check-equal! (nth 2 (plist-get answer 'usage)) 'laya
                      "and the usage names the backend that wrote it"))
      (set! decide--call-laya held))))

(deftest 'decide-a-laya-answer-reads-as-one-row-a-question
  "the daemon answers JSON, so an answer is a plist and not an alist"
  (lambda ()
    (let* ((result '(model "laya-rl-agent"
                     answers (department (type "choice" choice "billing"
                                          confidence 0.76
                                          action (act_probability 1.0))
                              refund (type "noul" noul 0.82 confidence 0.82))
                     usage (input_tokens 116 output_tokens 0)))
           (standard (decide--laya->standard result))
           (rows (plist-get standard 'answers)))
      (check-equal! (length rows) 2 "one row a question")
      (check-equal! (nth 0 (nth 0 rows)) 'department "the question is the key")
      (check-equal! (plist-get (nth 1 (nth 0 rows)) 'choice) "billing"
                    "and the answer is the standard shape")
      (check-equal! (plist-get (nth 1 (nth 1 rows)) 'noul) 0.82 "whatever its type")
      (check-equal! (plist-get standard 'usage) '(116 0 laya)
                    "the tokens the daemon counted, under the backend's name"))))

(deftest 'decide-a-laya-answer-that-is-not-there-is-no-answer
  "a daemon that refused must not read as a decision"
  (lambda ()
    (let ((standard (decide--laya->standard #f)))
      (check-equal! (plist-get standard 'answers) '() "no rows")
      (check-equal! (plist-get standard 'usage) '(0 0 laya) "and nothing spent"))))
