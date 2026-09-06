;;; handheld-test.scm --- the handheld client's policy, on keys this test binds.
;;;
;;; No production binding appears here. The chord register is tested with
;;; a dummy key under <f9>, and the chip test binds its own key too.

(domain! 'testing)
(effects! '(write))

(define *handheld-test-fired* '())

(define (handheld-test-reset!) (set! *handheld-test-fired* '()))

(define (handheld-test-fired? tag) (member tag *handheld-test-fired*))

(define-command "handheld-test-dummy" "Test command: record that it ran"
  (lambda () (set! *handheld-test-fired* (cons 'dummy *handheld-test-fired*))))

(deftest 'the-composer-tells-a-chord-from-a-command-from-prose
  "classify: a key token opens a chord, M-x NAME is a command, the rest is prose"
  (lambda ()
    (check-equal! (handheld-classify "C-c b") '(keys ("C-c" "b")) "a modified key then a letter is a chord")
    (check-equal! (handheld-classify "<f9> a") '(keys ("<f9>" "a")) "a named key opens a chord")
    (check-equal! (handheld-classify "M-x") '(keys ("M-x")) "M-x alone is the key")
    (check-equal! (handheld-classify "M-x handheld-test-dummy") '(command "handheld-test-dummy")
                  "M-x and a name is a command")
    (check-equal! (handheld-classify "  what did aker say?  ") '(prose "what did aker say?")
                  "a sentence is prose, trimmed")
    (check-equal! (handheld-classify "C-c is a chord") '(prose "C-c is a chord")
                  "a chord followed by words is prose")
    (check-equal! (handheld-classify "   ") '(empty) "blank is empty")))

(deftest 'the-chord-register-presses-the-keys-it-names
  "compose a dummy chord and the command bound to it runs"
  (lambda ()
    (handheld-test-reset!)
    (global-set-key "<f9> h" "handheld-test-dummy")
    (check-equal! (handheld-compose! "<f9> h") 'keys "the composer used the chord register")
    (check-true! (wait-until (lambda () (handheld-test-fired? 'dummy)) 3000 20)
                 "and the bound command ran")
    (global-unset-key "<f9> h")))

(deftest 'the-command-register-runs-the-named-command
  "M-x NAME runs NAME at once; an unknown name is refused"
  (lambda ()
    (handheld-test-reset!)
    (check-equal! (handheld-compose! "M-x handheld-test-dummy") 'command "a known name runs")
    (check-true! (handheld-test-fired? 'dummy) "and the command ran")
    (check-equal! (handheld-compose! "M-x handheld-no-such-command") 'unknown "an unknown name is refused")))

(deftest 'the-tab-rail-carries-the-current-buffer-flagged
  "the current buffer is on the rail and marked current"
  (lambda ()
    (let ((buf (test-buffer! "zz-handheld-tab" "one\ntwo\n")))
      (delete-other-windows!)
      (switch-to-buffer! buf)
      (set-mode! "text-mode")
      (let ((row (assoc buf (handheld-tabs))))
        (check-true! row "the rail names the current buffer")
        (check-equal! (nth 2 row) "text" "the kind is the mode without its suffix")
        (check-equal! (nth 3 row) #t "and it is flagged current")))))

(deftest 'a-chip-teaches-the-key-bound-to-its-command
  "a chip carries the chord bound to its command, or M-x when nothing binds it"
  (lambda ()
    (let ((buf (test-buffer! "zz-handheld-chip" "")))
      (global-set-key "<f9> c" "handheld-test-dummy")
      (check-equal! (handheld-chip "Dummy" "handheld-test-dummy" buf)
                    '("Dummy" "<f9> c")
                    "a bound command's chip is its key")
      (global-unset-key "<f9> c")
      (check-equal! (handheld-chip "Dummy" "handheld-test-dummy" buf)
                    '("Dummy" "M-x handheld-test-dummy")
                    "an unbound command's chip is M-x and its name"))))

(deftest 'the-rail-moves-point-to-the-line-it-names
  "scrub to a line and point sits at its start; out-of-range lines clamp"
  (lambda ()
    (let ((buf (test-buffer! "zz-handheld-rail" "one\ntwo\nthree\n")))
      (delete-other-windows!)
      (switch-to-buffer! buf)
      (check-equal! (handheld-scrub! 2) 2 "line two is reachable")
      (check-equal! (point) 4 "and point is at its start")
      (check-equal! (handheld-scrub! 99) 4 "a line past the end clamps to the last line"))))
