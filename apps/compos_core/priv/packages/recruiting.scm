;;; recruiting.scm --- the recruiting queue as a document of blocks.
;;;
;;; M-x recruiting reads the staff applications queue and writes it as a
;;; document: a heading, the queues with their counts, and ONE fenced
;;; `application` block per row. The block is the unit of work, so the
;;; editor's own block vocabulary carries the rest. M-<up> and M-<down>
;;; step application to application, and RET reads the one at point in
;;; the other window, through the same text reader every page uses.
;;;
;;; The page is a DOM, so the transform is XSLT, like the browse reading
;;; beside it under web/parsers. recruiting/applications.xsl writes the
;;; document; the Scheme here owns the mode, the keys and the fetch.
;;;
;;; The fence carries the application id. Every verb reads its target
;;; from the text at point, so no table lives beside the document and a
;;; redraw cannot fall out of step with one.

(domain! 'recruiting)
(effects! '(read external))

(defcustom 'recruiting-site "https://svsrecruiting.com"
  "The recruiting site the queue is read from."
  'group 'recruiting 'type 'string)

(defcustom 'recruiting-cache-ttl 300
  "Seconds the queue serves its drawn blocks before a wake refetches."
  'group 'recruiting 'type 'number)

(define *recruiting-buffer* "*applications*")

(define (recruiting--queue-url)
  (string-append recruiting-site "/staff/applications"))

(define (recruiting--application-url id)
  (string-append recruiting-site "/staff/applications/" id))

(define (recruiting--stylesheet)
  (string-append (compos-priv-dir) "/packages/recruiting/applications.xsl"))

;;; --- the fetch ------------------------------------------------------------------
;;; browser-fetch, because a staff queue is behind the session the real
;;; browser holds. The transform is ONE command over one file, the shape
;;; web.scm uses for a reading.

(define (recruiting--transform html k)
  (let ((file (string-append (compos-home) "/recruiting-queue.html")))
    (write-file! file html)
    (shell-command->string
      (string-append "xsltproc --html "
                     (sh-quote (recruiting--stylesheet)) " "
                     (sh-quote file) " 2>/dev/null")
      (lambda (out)
        (delete-file! file)
        (k (if (equal? (string-trim out) "") #f out))))))

(define (recruiting--fetch buf k)
  (browser-fetch (recruiting--queue-url)
    (lambda (html)
      (if html (recruiting--transform html k) (k #f)))))

(define (recruiting--render! buf text)
  (when text
    (let ((fresh (= (buffer-size buf) 0)))
      (buffer-set-read-only! buf #f)
      (buffer-delete-range! buf 0 (buffer-size buf))
      (buffer-insert! buf 0 text)
      (buffer-set-read-only! buf #t)
      ;; a first draw opens at the top; a refresh leaves point where it is
      (when fresh (with-current-buffer buf (lambda () (goto-char! 0)))))))

(define (recruiting--declare-cache! buf)
  (cache-declare! buf recruiting--fetch recruiting--render! recruiting-cache-ttl))

;;; --- the blocks -----------------------------------------------------------------
;;; A row is a fenced block whose info string is the kind and the
;;; application id. block-list answers
;;; (START END INFO BODY-START BODY-END), and BODY-START is the line
;;; under the fence: the candidate's name, which is what the row is about.

(define-fence-kind! "application"
  "One application in the recruiting queue; its info string carries the id."
  'ts-lang #f
  'runnable #f)

(define (recruiting--block-id b)
  (let ((parts (filter (lambda (s) (not (equal? s "")))
                       (string-split (string-trim (nth 2 b)) " "))))
    (cond ((null? parts) #f)
          ((not (equal? (car parts) "application")) #f)
          ((null? (cdr parts)) #f)
          (else (nth 1 parts)))))

(define (recruiting--blocks buf)
  (filter recruiting--block-id (block-list buf)))

(define (recruiting--block-here)
  (let* ((buf (current-buffer))
         (b (block-at buf (point))))
    (if (and b (recruiting--block-id b)) b #f)))

;;; --- application to application --------------------------------------------------

(define (recruiting--first-after stops pos)
  (let loop ((s stops))
    (cond ((null? s) #f)
          ((> (car s) pos) (car s))
          (else (loop (cdr s))))))

(define (recruiting--last-before stops pos)
  (let loop ((s stops) (best #f))
    (cond ((null? s) best)
          ((< (car s) pos) (loop (cdr s) (car s)))
          (else best))))

(define (recruiting--step! dir edge)
  (let* ((buf (current-buffer))
         (stops (map (lambda (b) (nth 3 b)) (recruiting--blocks buf)))
         (target (if (> dir 0)
                     (recruiting--first-after stops (point))
                     (recruiting--last-before stops (point)))))
    (cond (target (goto-char! target) target)
          (else (message edge) #f))))

(define-command "recruiting-next-application" "Move to the next application"
  (lambda () (recruiting--step! 1 "last application")))

(define-command "recruiting-previous-application" "Move to the previous application"
  (lambda () (recruiting--step! -1 "first application")))

;;; --- what a row can do -----------------------------------------------------------

(define-command "recruiting-details" "Read the application at point in the other window"
  (lambda ()
    (let ((b (recruiting--block-here)))
      (if b
          (browse-other-window (recruiting--application-url (recruiting--block-id b)))
          (message "no application here")))))

(define-command "recruiting-open-external" "Open the application at point in the real browser"
  (lambda ()
    (let ((b (recruiting--block-here)))
      (if b
          (tab-open (recruiting--application-url (recruiting--block-id b)))
          (message "no application here")))))

(define-command "recruiting-refresh" "Read the queue again"
  (lambda () (cache-refresh! (current-buffer))))

;;; --- the mode --------------------------------------------------------------------
;;; morg-mode owns fenced text: the scan, the folding, the block at
;;; point. recruiting-mode is that, read-only, rendered, and with the
;;; landmark keys narrowed from every landmark to every application.

(define-derived-mode "recruiting-mode" "morg-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-read-only! buf #t)
      (buffer-set-local! buf 'window-class "writing")
      (buffer-set-local! buf 'line-numbers "off")
      (buffer-set-local! buf 'visual-line-mode #t)
      ;; a generated buffer has no .md suffix, so it declares its renderer
      (buffer-set-local! buf 'preview-renderer "markdown")
      (unless (minor-mode-on? buf "preview-mode")
        (enable-minor-mode! buf "preview-mode"))
      (recruiting--declare-cache! buf)
      (cache-wake! buf))))

(mode-keys! "recruiting-mode"
  '(("M-<up>" "recruiting-previous-application")
    ("M-<down>" "recruiting-next-application")
    ("n" "recruiting-next-application")
    ("p" "recruiting-previous-application")
    ("RET" "recruiting-details")
    ("o" "recruiting-open-external")
    ("g" "recruiting-refresh")
    ("q" "quit-window")))

(mode-doc! "recruiting-mode"
  "The recruiting queue, one block per application. M-<up> and M-<down>
step application to application, and n and p do the same. RET reads
the application at point in the other window; o opens it in the real
browser. g reads the queue again, and q puts it away.")

(define-command "recruiting" "Read the recruiting queue as blocks"
  (lambda ()
    (buffer-create *recruiting-buffer*)
    (with-current-buffer *recruiting-buffer*
      (lambda () (set-mode! "recruiting-mode")))
    (switch-to-buffer! *recruiting-buffer*)))
