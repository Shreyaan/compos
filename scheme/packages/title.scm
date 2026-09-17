;;; title.scm --- the on-device card writer: a title and a description for a passage.
;;;
;;; A 350M Granite fine-tune (desert-ant-labs/title) that names a passage of
;;; text: a factual title of three to eight words and a one- or two-sentence
;;; description. It runs on MLX, so Apple silicon and nowhere else.
;;;
;;; There is no transport code here, on purpose. mlx_lm.server speaks the
;;; OpenAI chat API and req_llm's vllm provider is exactly that shape, so a
;;; local model is a model string like any other and keys.scm carries its
;;; address. What this file owns is the part that cannot be config: the
;;; prompt the model was fine-tuned against, byte for byte, and the tolerant
;;; parse of its two labelled lines.
;;;
;;; chat.scm's running summary uses it whenever it is ready, which is the
;;; point of installing it: a label and a title for every chat, on device,
;;; for no money and no round trip.

(domain! 'llm)
(effects! '(read external execute))

(defgroup 'title "Title: the on-device model that names a passage of text.")

(defcustom 'title-model-directory (string-append (compos-home) "/models/title")
  "The MLX model folder the card writer serves. Nothing is downloaded: populate it with the weights."
  'group 'title 'type 'string)

(defcustom 'title-server-command (string-append (getenv "HOME") "/.local/bin/mlx_lm.server")
  "The mlx_lm.server executable. An absolute path, because the daemon's PATH is not a login shell's."
  'group 'title 'type 'string)

(defcustom 'title-server-port 8127
  "The loopback port the card writer answers on." 'group 'title 'type 'integer)

;; The token cap on one card. It stops a degenerate run, a real failure mode for a small instruct model given unusual input.
(define title-max-tokens 96)

;;; --- the address ----------------------------------------------------------------

;; The provider is self-hosted, so the address is ours to state and the key is
;; a formality: mlx_lm.server never reads it, and req_llm requires a non-empty
;; one. Both live beside every other provider's, in keys.scm.
(define (title--base-url)
  (string-append "http://127.0.0.1:" (number->string title-server-port) "/v1"))

(define (title--model) (string-append "vllm:" title-model-directory))

(register-llm-base-url! "vllm" (title--base-url))
(register-llm-key! "vllm" "local")

;;; --- the server -----------------------------------------------------------------

;; Loading is expensive and generation is cheap, so the server loads once and
;; stays warm. Started at most once a session and never waited for: a start
;; answers #f for this round, because the model is still loading, and the
;; caller's next refresh finds it ready. Once ready, no probe runs again.
(define *title-server-ready* #f)
(define *title-server-started* #f)

(define (title-installed?)
  (file-exists? (string-append title-model-directory "/config.json")))

(define (title--listening?)
  (not (equal? "" (string-trim
    (shell-command->string
      (string-append "lsof -nP -iTCP:" (number->string title-server-port) " -sTCP:LISTEN -t")
      (compos-home))))))

(define (title--start!)
  (shell-command->string
    (string-append "nohup " title-server-command
                   " --model " title-model-directory
                   " --host 127.0.0.1 --port " (number->string title-server-port)
                   " --temp 0.0 --max-tokens " (number->string title-max-tokens)
                   " >" (compos-home) "/title-server.log 2>&1 &")
    (compos-home))
  (message "title: the on-device card writer is loading"))

(define (title-ready?)
  (and (title-installed?)
       (or *title-server-ready*
           (cond ((title--listening?) (set! *title-server-ready* #t) #t)
                 (*title-server-started* #f)
                 (else (set! *title-server-started* #t) (title--start!) #f)))))

;;; --- the prompt -----------------------------------------------------------------

;; The prompt the model is fine-tuned against, byte for byte, copied from
;; Titles.prompt in the SDK rather than rewritten. A paraphrase is a different
;; task to this model: an earlier version of that property shipped a string
;; training had never used, so the model was served an unseen prompt on every
;; call, and the rule it spent four lines on could not have been learned. It
;; says passage and not clip because the model is not clip-specific.
(define (title--prompt text)
  (string-append
    "Write a factual title (3-8 words) and a 1-2 sentence description for this passage."
    "Be specific enough to identify this passage. No emoji, no hashtags, no hype."
    "Write in the same language as the passage.\n\nPASSAGE:\n"
    text))

;; Tolerant, the same way the SDK's parse is: a card model that drifts off
;; format should degrade to a usable title rather than to nothing. DESC and
;; DESCRIPTION are both taken -- the training data uses DESC, but base-model
;; habits leak the longer spelling through.
(define (title--parse raw)
  (let loop ((lines (string-split raw "\n")) (title "") (desc ""))
    (if (null? lines)
        (list title desc)
        (let* ((line (string-trim (car lines)))
               (up (string-upcase line))
               (rest (lambda (n) (string-trim (substring line n (string-length line))))))
          (cond ((string-prefix? "TITLE:" up) (loop (cdr lines) (rest 6) desc))
                ((string-prefix? "DESCRIPTION:" up) (loop (cdr lines) title (rest 12)))
                ((string-prefix? "DESC:" up) (loop (cdr lines) title (rest 5)))
                ((and (equal? title "") (not (equal? line "")))
                 (loop (cdr lines) line desc))
                (else (loop (cdr lines) title desc)))))))

;;; --- the card -------------------------------------------------------------------

(define (title-card text k)
  (if (not (title-ready?))
      (k #f)
      (llm-with-model (title--prompt text) (title--model)
        (lambda (raw) (k (and (string? raw) (not (equal? raw "")) (title--parse raw)))))))

(define-command "title-server"
  "Start the on-device card writer, or say where it stands"
  (lambda ()
    (message
      (cond ((not (title-installed?))
             (string-append "title: no model in " title-model-directory))
            ((title-ready?) (string-append "title: ready on " (title--base-url)))
            (else "title: loading")))))

(public! 'title-card
  "(title-card TEXT K) - K gets (TITLE DESCRIPTION) for a passage of text, or #f when the on-device model is not ready")
(public! 'title-ready?
  "(title-ready?) - #t when the card writer is installed and serving; starts it once when it is not")
(public! 'title-installed?
  "(title-installed?) - #t when the MLX model folder holds a model")
