;;; peek.scm --- look at a definition without going there.
;;;
;;; Emacs has three verbs for showing a buffer. switch-to-buffer shows it
;;; in the selected window. display-buffer shows it in another window and
;;; leaves point where it is. pop-to-buffer shows it and selects it. `M-.`
;;; in a code buffer is pop-to-buffer at the definition.
;;;
;;; A prose buffer names many definitions. The reader wants to check each
;;; one and go to few. That is display-buffer plus one rule: the window
;;; lives until the next command, unless that command goes there. The
;;; peek command run again on the same name goes there. Any other
;;; command discards the window, and the buffer with it when the peek
;;; opened it.
;;;
;;; The post-command hook runs before the editor records last-command, and
;;; it can run more than once per key. So the hook does not count
;;; commands. It compares where the reader is with where the reader was
;;; when the peek was made: the same window, buffer, and point keep the
;;; peek; the peek window itself adopts it; anything else discards it.

(domain! 'code)
(effects! '(read))

;; The peek is the frame's look (preview-show ... 'other): the slot
;; holds the window, and its data is (definition NAME OPENED? ORIGIN-BUFFER
;; ORIGIN-POINT). The window's leaf records what the peek covers.
(define (peek--chars)
  *scheme-ide-chars*)

(define (peek--name) (symbol-at-point-in (peek--chars)))

;; -> (SOURCE-KIND TARGET BYTE-POS) or #f. One chain for every buffer:
;; the Scheme catalog sources. A file target is a path; a file buffer is
;; named by its path, so the target is also the buffer name.
(define (definition-locate name &optional kind)
  (scheme-ide--find-def name kind))

;; the definition look on screen: (NAME OPENED? ORIGIN-BUFFER ORIGIN-POINT)
(define (peek--data)
  (let ((d (preview-data)))
    (and (pair? d) (equal? (car d) 'definition) (cdr d))))

(define (peek--window) (and (peek--data) (nth 3 (preview-slot))))

(define (peek--show! name hit)
  (let* ((target (cadr hit))
         (opened? (not (buffer-exists? target)))
         (buf (if (equal? (car hit) 'buffer) target (visit-quietly target)))
         (origin (window-buffer (active-window)))
         (win (preview-show buf 'other #f
                (list 'definition name opened? origin (buffer-point origin)))))
    (when win (window-set-point! win (caddr hit)))
    win))

(define (peek-discard!)
  (let ((d (peek--data)))
    (when d
      (let ((buf (car (preview-end #f))))
        (when (and (cadr d) (buffer-exists? buf) (not (window-showing buf))
                   (not (buffer-modified? buf)))
          (buffer-kill! buf))))))

(define (peek-go!)
  (let ((name (car (peek--data))) (win (peek--window)))
    (preview-end #t)
    (lsp--push-marker!)
    (select-window! win)
    (message (string-append "Definition of " name))))

;; the reader is where the peek was made: the origin window is active, it
;; still shows the origin buffer, and that buffer's point did not move.
;; Everything is read by id or name, so the answer does not depend on
;; which buffer the calling lane treats as current.
(define (peek--still-here? d)
  (let ((origin (nth 2 (preview-slot))) (buf (nth 2 d)))
    (and (equal? (active-window) origin)
         (equal? (window-buffer origin) buf)
         (buffer-exists? buf)
         (equal? (buffer-point buf) (nth 3 d)))))

(define (peek--post-command!)
  (let ((d (peek--data)))
    (when d
      (cond ((equal? (active-window) (peek--window))
             ;; the reader moved into the window by any road: it is theirs
             (preview-end #t))
            ((peek--still-here? d) #t)
            (else (peek-discard!))))))

(add-hook! 'post-command-hook 'peek--post-command!)


(define-command "definition-peek"
  "Show the definition of the name at point in the other window; run again to go there; a link there is followed"
  (lambda ()
    (unless (goto-address-follow-at-point!)
      (definition-peek!))))

(define (definition-peek!)
    (let ((name (peek--name)))
      (cond
        ((not name) (message "No name at point"))
        ((and (peek--window) (equal? name (car (peek--data))))
         (peek-go!))
        (else
          (peek-discard!)
          (let ((hit (definition-locate name)))
            (cond
              (hit
                (peek--show! name hit)
                (message (string-append "Definition of " name " in the other window; press again to go there, any other key closes it")))
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
  "Close the peek window"
  (lambda () (peek-discard!)))

(for-each (lambda (name) (undo-exempt! name))
          '("definition-peek" "definition-peek-go" "definition-peek-discard"))

(public! 'definition-locate
  "(definition-locate NAME [KIND]) -- (SOURCE-KIND TARGET BYTE-POS) of NAME's definition, or #f")
(public! 'peek-discard!
  "(peek-discard!) -- close the peek window; kill its buffer when the peek opened it")
