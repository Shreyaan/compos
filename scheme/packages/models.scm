;;; models.scm --- the model hosts on this machine, and on the network.
;;;
;;; M-x models lists the models one Ollama host holds, and says which of
;;; them the host keeps loaded in memory now.
;;;
;;;   RET   show what the model is: family, parameters, quantization
;;;   s     load the model; it stays loaded for models-keep-alive
;;;   k     unload the model now
;;;   i     install another model: give the name, the host pulls it
;;;   d     uninstall the model, after a confirmation
;;;   S     start the model server on this machine
;;;   h     talk to another host
;;;   g / q refresh, bury. / filters.
;;;
;;; Ollama is the one backend. Its HTTP API is the whole mechanism, so a
;;; host is a URL, and a host on the network costs no more than this one.
;;; Nothing here runs the ollama command, except the S that starts the
;;; server on this machine. A second backend goes behind models--request,
;;; not beside it.

(domain! 'llm)
(effects! '(read external))

(define *models-buffer* "*models*")
(define *models-detail-buffer* "*model*")

;; why the last scan answered nothing, so the meta line can say it
(define *models-error* #f)

(defgroup 'models "Models: the local model hosts and the models they hold.")

(defcustom 'models-host "http://localhost:11434"
  "The model host the list talks to." 'group 'models)

(defcustom 'models-hosts (list "http://localhost:11434")
  "Every model host h switches between." 'group 'models)

(defcustom 'models-keep-alive "10m"
  "How long a model you load stays in the host memory." 'group 'models)

;; Seconds before the model list asks the host again.
(define models-cache-ttl 15)

;; Seconds to wait for an install. A large model takes minutes.
(define models-pull-timeout 3600)

(defface! 'models-loaded 'fg "#2e6b45" 'weight "600")
(defface! 'models-name 'fg "#26356b" 'weight "600")
(defface! 'models-size 'fg "#7a5a1a")

;;; --- the host -------------------------------------------------------------------
;;; A host is a URL. "localhost", "box.local" and "10.0.0.4:8080" are all
;;; names a person types, so the scheme and the default port fill in. A
;;; name that already carries a port or a path keeps it.

(define *models-default-port* "11434")

(define (models--strip-slash url)
  (if (string-suffix? "/" url)
      (substring url 0 (- (string-length url) 1))
      url))

;; the text after the scheme: "box.local:8080/v1" of "http://box.local:8080/v1"
(define (models--rest url)
  (let ((parts (string-split url "://")))
    (if (> (length parts) 1) (cadr parts) url)))

(define (models--host-url host)
  (let* ((h (string-trim (or host "")))
         (h (if (or (equal? h "") (equal? h "local")) "localhost" h))
         (h (if (string-contains? h "://") h (string-append "http://" h)))
         (h (models--strip-slash h))
         (rest (models--rest h)))
    (if (or (string-contains? rest ":") (string-contains? rest "/"))
        h
        (string-append h ":" *models-default-port*))))

(define (models-base) (models--host-url models-host))

(define (models--local? url)
  (or (string-contains? url "//localhost")
      (string-contains? url "//127.0.0.1")))

;;; --- the requests ---------------------------------------------------------------
;;; One door to the host: the method, the path, a JSON body or #f, the
;;; seconds to wait, and K. K always gets an http reply plist, so a
;;; refused connection and a 404 read the same way. Tests replace this seam.
;;;
;;; A body names the model under both "model" and "name". Ollama renamed
;;; that field, and a host older than the rename still reads "name". A
;;; field the host does not know costs nothing: its JSON decoder drops it.

(define (models--request method path body seconds k)
  (http-request (string-append (models-base) path)
                (append (list 'method method
                              'timeout (* 1000 seconds)
                              'headers (list 'user-agent "compos"))
                        (if body (list 'json body) '()))
                k))

(define *models-request* models--request)

(define (models--model-body name &rest extra)
  (append (list 'model name 'name name) extra))

;; plist-get stops the interpreter when it is handed #f, and JSON answers
;; leave out what they have nothing to say about
(define (models--text v) (if (string? v) v ""))

;;; --- what the host holds ----------------------------------------------------------
;;; /api/tags names every installed model. /api/ps names the ones in
;;; memory. One row per installed model, and a row for a loaded model the
;;; tags do not name, because a host can hold one.

(define (models--entry name size params quant loaded vram until)
  (list 'name name 'size size 'params params 'quant quant
        'loaded loaded 'vram vram 'until until))

(define (models--name obj)
  (let ((n (or (plist-get obj 'name) (plist-get obj 'model))))
    (models--text n)))

(define (models--models json)
  (let ((ms (plist-get json 'models)))
    (if (pair? ms) ms '())))

;; "2026-09-17T18:04:33.12+05:30" -> "18:04", the host clock. A person
;; reads the clock, not the timestamp.
(define (models--clock stamp)
  (if (and (string? stamp) (> (string-length stamp) 16))
      (substring stamp 11 16)
      ""))

(define (models--loaded-row obj)
  (list (models--name obj)
        (plist-get obj 'size_vram)
        (models--clock (plist-get obj 'expires_at))))

(define (models--installed-entry m loaded)
  (let* ((name (models--name m))
         (d (plist-get m 'details))
         (r (assoc name loaded)))
    (models--entry name
                   (plist-get m 'size)
                   (models--text (plist-get d 'parameter_size))
                   (models--text (plist-get d 'quantization_level))
                   (if r #t #f)
                   (if r (nth 1 r) #f)
                   (if r (nth 2 r) ""))))

(define (models--merge installed loaded)
  (let* ((names (map models--name installed))
         (extra (filter (lambda (r) (not (member (car r) names))) loaded)))
    (append (map (lambda (m) (models--installed-entry m loaded)) installed)
            (map (lambda (r)
                   (models--entry (car r) (nth 1 r) "" "" #t (nth 1 r) (nth 2 r)))
                 extra))))

;; loaded first, then by name: what the host is doing now is the answer
;; the list is open for
(define (models--sort entries)
  (map cadr
       (sort (map (lambda (e)
                    (list (string-append (if (plist-get e 'loaded) "0" "1")
                                         (plist-get e 'name))
                          e))
                  entries))))

(define (models--fetch buf k)
  (*models-request* "GET" "/api/tags" #f 10
    (lambda (tags)
      (if (not (http-ok? tags))
          (begin (set! *models-error* (http-message tags)) (k '()))
          (*models-request* "GET" "/api/ps" #f 10
            (lambda (ps)
              (set! *models-error* #f)
              (k (models--sort
                   (models--merge (models--models (http-json tags))
                                  (map models--loaded-row
                                       (models--models (http-json ps))))))))))))

;; the names the host holds in memory now. Another package asks this to
;; know what a request costs nothing to start.
(define (models-loaded k)
  (*models-request* "GET" "/api/ps" #f 10
    (lambda (reply)
      (k (map models--name (models--models (http-json reply)))))))

;;; --- the list ---------------------------------------------------------------------

;; integer arithmetic all the way: a float prints its own rounding error
(define (models--scaled bytes unit suffix)
  (let* ((tenths (quotient (* 10 bytes) unit))
         (whole (quotient tenths 10))
         (frac (remainder tenths 10)))
    (string-append (number->string whole) "." (number->string frac) suffix)))

(define (models--size-label bytes)
  (cond ((not (number? bytes)) "")
        ((>= bytes 1073741824) (models--scaled bytes 1073741824 " GB"))
        ((>= bytes 1048576) (models--scaled bytes 1048576 " MB"))
        (else (string-append (number->string bytes) " B"))))

(define (models--state e)
  (if (plist-get e 'loaded)
      (let ((vram (models--size-label (plist-get e 'vram)))
            (until (plist-get e 'until)))
        (string-append "loaded"
                       (if (equal? vram "") "" (string-append " " vram))
                       (if (equal? until "") "" (string-append " until " until))))
      ""))

(define (models--cells buf e)
  (let ((loaded (plist-get e 'loaded)))
    (list (list (if loaded "*" "") "models-loaded")
          (list (plist-get e 'name) "models-name")
          (list (models--size-label (plist-get e 'size)) "models-size")
          (list (plist-get e 'params) "dim")
          (list (plist-get e 'quant) "dim")
          (list (models--state e) (if loaded "models-loaded" "dim")))))

(define (models--meta buf)
  (let* ((es (list-entries buf))
         (loaded (length (filter (lambda (e) (plist-get e 'loaded)) es))))
    (string-append
      (models-base)
      (if *models-error*
          (string-append " - no answer: " *models-error*)
          (string-append " - " (number->string (length es)) " models, "
                         (number->string loaded) " loaded"))
      (let ((age (cache-age-label buf)))
        (if age (string-append " - " age) "")))))

(define (models--current)
  (let ((e (list-current *models-buffer*)))
    (if e e (begin (message "no model on this line") #f))))

;;; --- load, unload, install, uninstall ----------------------------------------------

(effects! '(write external))

(define (models--report! verb name reply)
  (if (http-ok? reply)
      (message (string-append name ": " verb))
      (message (string-append name ": " verb " failed - "
                              (or (http-message reply) "no answer"))))
  (when (buffer-known? *models-buffer*) (cache-refresh! *models-buffer*)))

;; An empty prompt with a keep_alive loads the model and answers as soon
;; as it is in memory. keep_alive 0 is the same call the other way.
(define (models--keep-alive! name value verb)
  (*models-request* "POST" "/api/generate"
    (models--model-body name 'keep_alive value 'stream #f)
    600
    (lambda (reply) (models--report! verb name reply))))

(define-command "models-start" "Load the model on this line into the host memory"
  (lambda ()
    (let ((e (models--current)))
      (when e
        (let ((name (plist-get e 'name)))
          (message (string-append "loading " name "..."))
          (models--keep-alive! name models-keep-alive "loaded"))))))

(define-command "models-stop" "Unload the model on this line from the host memory"
  (lambda ()
    (let ((e (models--current)))
      (when e
        (let ((name (plist-get e 'name)))
          (models--keep-alive! name 0 "unloaded"))))))

(define-command "models-install" "Install another model on this host"
  (lambda ()
    (read-string "Install model: "
      (lambda (input)
        (let ((name (string-trim input)))
          (unless (equal? name "")
            (message (string-append "pulling " name ", this takes minutes..."))
            (*models-request* "POST" "/api/pull"
              (models--model-body name 'stream #f)
              models-pull-timeout
              (lambda (reply) (models--report! "installed" name reply)))))))))

(effects! '(destroy external))

(define-command "models-uninstall" "Uninstall the model on this line from the host"
  (lambda ()
    (let ((e (models--current)))
      (when e
        (let ((name (plist-get e 'name)))
          (yes-or-no-p (string-append "Uninstall " name " from " (models-base) "? ")
            (lambda (ok)
              (when ok
                (*models-request* "DELETE" "/api/delete"
                  (models--model-body name) 60
                  (lambda (reply)
                    (models--report! "uninstalled" name reply)))))))))))

;;; --- another host, and the server on this one --------------------------------------

(effects! '(write))

(define-command "models-set-host" "Talk to another model host"
  (lambda ()
    (minibuffer-read* "Model host: "
      (map (lambda (h) (list h "")) models-hosts)
      (list (list 'confirm
                  (lambda (input)
                    (let ((h (string-trim input)))
                      (unless (equal? h "")
                        (customize-save! 'models-host h)
                        (unless (member h models-hosts)
                          (customize-save! 'models-hosts
                                           (append models-hosts (list h))))
                        (message (string-append "models: " (models-base)))
                        (when (buffer-known? *models-buffer*)
                          (cache-refresh! *models-buffer*))))))))))

(effects! '(write external execute))

;; A host on the network is that machine's own business, so only the local
;; server starts from here. nohup keeps it after the editor stops: a
;; model server outlives the editor that asked for it. The sleep gives
;; the server time to bind its port before the version request.
(define (models--serve-command)
  (string-append
    "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" "
    "nohup ollama serve >> " (compos-home) "/ollama.log 2>&1 & sleep 2"))

(define-command "models-serve" "Start the model server on this machine"
  (lambda ()
    (if (not (models--local? (models-base)))
        (message (string-append (models-base)
                                " is not this machine - start the server there"))
        (begin
          (message "starting ollama...")
          (shell-command->string (models--serve-command) (default-directory)
            (lambda (out)
              (*models-request* "GET" "/api/version" #f 10
                (lambda (reply)
                  (if (http-ok? reply)
                      (models--report! "the server runs" (models-base) reply)
                      (message (string-append
                                 "ollama did not start - see "
                                 (compos-home) "/ollama.log")))))))))))

;;; --- what a model is ----------------------------------------------------------------
;;; /api/show answers what the file holds. The detail goes to the window
;;; the list opens its rows into, and the list keeps the point.

(effects! '(write display))

(define (models--pad s n)
  (if (>= (string-length s) n) s (models--pad (string-append s " ") n)))

(define (models--line label v)
  (if (and (string? v) (not (equal? v "")))
      (string-append (models--pad label 15) v "\n")
      ""))

(define (models--block label v)
  (if (and (string? v) (not (equal? v "")))
      (string-append "\n" label "\n" v "\n")
      ""))

(define (models--detail-text name json)
  (let ((d (plist-get json 'details)))
    (string-append
      name "\n\n"
      (models--line "family" (plist-get d 'family))
      (models--line "parameters" (plist-get d 'parameter_size))
      (models--line "quantization" (plist-get d 'quantization_level))
      (models--line "format" (plist-get d 'format))
      (models--block "parameters" (plist-get json 'parameters))
      (models--block "template" (plist-get json 'template)))))

(define (models--show-detail! name json)
  (unless (buffer-exists? *models-detail-buffer*)
    (buffer-create *models-detail-buffer*))
  (buffer-delete-range! *models-detail-buffer* 0
                        (buffer-size *models-detail-buffer*))
  (buffer-insert! *models-detail-buffer* 0 (models--detail-text name json))
  (display-buffer-detail! *models-detail-buffer* *models-buffer*))

(define-command "models-show" "Show what the model on this line is"
  (lambda ()
    (let ((e (models--current)))
      (when e
        (let ((name (plist-get e 'name)))
          (*models-request* "POST" "/api/show" (models--model-body name) 30
            (lambda (reply)
              (if (http-ok? reply)
                  (models--show-detail! name (http-json reply))
                  (message (string-append name ": "
                                          (or (http-message reply)
                                              "no answer")))))))))))

;;; --- the list buffer ------------------------------------------------------------------

(effects! '(read external))

(define-command "models-refresh" "Ask the host for its models again"
  (lambda ()
    (message "asking the host...")
    (cache-refresh! *models-buffer*)))

(define-list-mode! "models-mode"
  (list
    'doc (string-append
           "Every model one local model host holds, the loaded ones first. "
           "`RET` shows what a model is, `s` loads it into memory, `k` "
           "unloads it, `i` installs another, `d` uninstalls one. `h` talks "
           "to another host and `S` starts the server on this machine.")
    'buffer *models-buffer*
    'rows (lambda (buf) (list-entries buf))
    'cache-fetch models--fetch
    'cache-ttl models-cache-ttl
    'columns (lambda (buf)
               (list (list "" 1) (list "model" 32) (list "size" 9)
                     (list "params" 7) (list "quant" 10) (list "state" #f)))
    'cells models--cells
    'title (lambda (buf) "Models")
    'meta models--meta
    'total (lambda (buf) (length (list-entries buf)))
    ;; no local-filter here: it caches the source rows once, and the next
    ;; answer from the host would never reach the table. / still filters.
    'no-marks #t
    'key (lambda (buf e) (plist-get e 'name))
    'footer (lambda (buf)
              '(("RET" "show") ("s" "load") ("k" "unload") ("i" "install")
                ("d" "uninstall") ("h" "host") ("g" "refresh") ("q" "quit")))
    'keys '(("RET" "models-show") ("s" "models-start") ("k" "models-stop")
            ("i" "models-install") ("d" "models-uninstall")
            ("S" "models-serve") ("h" "models-set-host")
            ("g" "models-refresh") ("q" "quit-window"))))

(define-command "models" "List the models a local model host holds"
  (lambda () (list-mode-show! "models-mode")))

;;; --- the public surface -----------------------------------------------------------------

(category! 'system)
(domain! 'llm)
(effects! '(read external))

(public! 'models
  "M-x models - list the models a local model host holds, and which of them it keeps loaded")
(public! 'models-base
  "(models-base) - the URL of the model host the list talks to")
(public! 'models-loaded
  "(models-loaded K) - K gets the names of the models the host holds in memory now")

(effects! '(write external))

(public! 'models-install
  "M-x models-install - install another model on the current host")
(public! 'models-set-host
  "M-x models-set-host - point the model list at another host")
(public! 'models-serve
  "M-x models-serve - start the model server on this machine")

(defrecipe! "which local models are running" "(models)")
(defrecipe! "install a local model" "(run-command \"models-install\")")
