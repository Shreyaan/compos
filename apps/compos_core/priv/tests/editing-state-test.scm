;;; editing-state-test.scm --- the movement state and the editing state of a buffer.
;;;
;;; A landing starts in the movement state. A command enters the editing
;;; state; keyboard-quit and windmove do not. A read-only buffer never
;;; enters it. The tests call the hook functions with a command name and
;;; read the state; no test names a key.

(domain! 'testing)
(effects! '(write))

(define t--es-a "*zz-es-a*")
(define t--es-b "*zz-es-b*")

(define (t--es-setup!)
  (delete-other-windows!)
  (for-each (lambda (b)
              (unless (buffer-exists? b) (buffer-create b))
              (buffer-set-read-only! b #f)
              (editing-state-off! b))
            (list t--es-a t--es-b))
  (switch-to-buffer! t--es-a)
  (editing--check-landing!))

(deftest 'a-command-enters-the-editing-state-and-keyboard-quit-leaves-it
  "after a command the buffer is in the editing state; after keyboard-quit it is not"
  (lambda ()
    (t--es-setup!)
    (check-equal! (editing-state? t--es-a) #f "a landing starts in the movement state")
    (editing--after-command! "forward-char")
    (check-equal! (editing-state? t--es-a) #t "a command enters the editing state")
    (check-equal! (if (member "editing-state-map" (buffer-minor-maps t--es-a)) #t #f) #t
                  "editing-state-map is in force")
    (editing--after-command! "keyboard-quit")
    (check-equal! (editing-state? t--es-a) #f "keyboard-quit returns to the movement state")
    (check-equal! (if (member "editing-state-map" (buffer-minor-maps t--es-a)) #t #f) #f
                  "editing-state-map is gone")))

(deftest 'windmove-keeps-the-movement-state
  "a windmove command after a landing does not enter the editing state"
  (lambda ()
    (t--es-setup!)
    (editing--after-command! "windmove-up")
    (check-equal! (editing-state? t--es-a) #f "windmove changes no state")))

(deftest 'a-new-landing-starts-in-the-movement-state
  "the editing state ends when the window shows another buffer"
  (lambda ()
    (t--es-setup!)
    (editing--after-command! "forward-char")
    (switch-to-buffer! t--es-b)
    (editing--check-landing!)
    (check-equal! (editing-state? t--es-b) #f "the new buffer lands in the movement state")
    (editing--after-command! "forward-char")
    (check-equal! (editing-state? t--es-b) #t "a command in the new buffer enters the editing state")
    (switch-to-buffer! t--es-a)
    (editing--check-landing!)
    (check-equal! (editing-state? t--es-a) #f "coming back is a new landing")))

(deftest 'a-read-only-buffer-stays-in-the-movement-state
  "a command in a read-only buffer does not enter the editing state"
  (lambda ()
    (t--es-setup!)
    (buffer-set-read-only! t--es-a #t)
    (editing--after-command! "forward-char")
    (check-equal! (editing-state? t--es-a) #f "read-only: no editing state")
    (buffer-set-read-only! t--es-a #f)))
