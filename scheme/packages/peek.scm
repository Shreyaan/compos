;;; peek.scm --- look at a definition without going there.
;;;
;;; Emacs has three verbs for showing a buffer. switch-to-buffer shows it
;;; in the selected window. display-buffer shows it in another window and
;;; leaves point where it is. pop-to-buffer shows it and selects it. `M-.`
;;; in a code buffer is pop-to-buffer at the definition.
;;;
;;; A prose buffer names many definitions. The reader wants to check each
;;; one and go to few. That is display-buffer: the definition shows in
;;; another window by the display chain and the focus stays. The command
;;; run again on the same name goes there.
;;;
;;; Peeks are deprecated. The window is an ordinary window and the buffer
;;; an ordinary buffer: nothing closes or kills them on the next command.

(domain! 'code)
(effects! '(read))

;; the last definition shown: (NAME WINDOW), or #f
(define peek--last #f)

(define (peek--chars)
  *scheme-ide-chars*)

(define (peek--name) (symbol-at-point-in (peek--chars)))

;; -> (SOURCE-KIND TARGET BYTE-POS) or #f. One chain for every buffer:
;; the Scheme catalog sources. A file target is a path; a file buffer is
;; named by its path, so the target is also the buffer name.
(define (definition-locate name &optional kind)
  (scheme-ide--find-def name kind))

;; the window of the last definition shown, while it still shows it
(define (peek--window)
  (and peek--last
       (window-exists? (cadr peek--last))
       (cadr peek--last)))

(define (peek--show! name hit)
  (let* ((target (cadr hit))
         (buf (if (equal? (car hit) 'buffer) target (visit-quietly target)))
         (win (display-buffer-other-window! buf)))
    (when (window-exists? win) (window-set-point! win (caddr hit)))
    (set! peek--last (list name win))
    win))

;; forget the last definition; its window and buffer stay
(define (peek-discard!)
  (set! peek--last #f))

(define (peek-go!)
  (let ((name (car peek--last)) (win (peek--window)))
    (set! peek--last #f)
    (lsp--push-marker!)
    (select-window! win)
    (message (string-append "Definition of " name))))


(define-command "definition-peek"
  "Show the definition of the name at point in the other window; run again to go there; a link there is followed"
  (lambda ()
    (unless (goto-address-follow-at-point!)
      (definition-peek!))))

(define (definition-peek!)
    (let ((name (peek--name)))
      (cond
        ((not name) (message "No name at point"))
        ((and (peek--window) (equal? name (car peek--last)))
         (peek-go!))
        (else
          (peek-discard!)
          (let ((hit (definition-locate name)))
            (cond
              (hit
                (peek--show! name hit)
                (message (string-append "Definition of " name " in the other window; press again to go there")))
              ((and (boundp 'primitive-doc) (primitive-doc name))
               (message (string-append name " is a primitive: " (primitive-doc name))))
              (else (message (string-append "No definition of " name)))))))))

(define-command "definition-peek-go"
  "Go to the definition the peek window shows"
  (lambda ()
    (if (peek--window)
        (peek-go!)
        (message "No peek to go to"))))

(define-command "definition-peek-discard"
  "Forget the last definition shown; its window stays"
  (lambda () (peek-discard!)))

(for-each (lambda (name) (undo-exempt! name))
          '("definition-peek" "definition-peek-go" "definition-peek-discard"))

(public! 'definition-locate
  "(definition-locate NAME [KIND]) -- (SOURCE-KIND TARGET BYTE-POS) of NAME's definition, or #f")
(public! 'peek-discard!
  "(peek-discard!) -- deprecated: forget the last definition shown; its window and buffer stay")
