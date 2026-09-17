;;; models-test.scm --- packages/models.scm: the models a local host holds.
;;;
;;; Every test that talks to a host replaces the one seam,
;;; *models-request*, so no test needs a model server.

(domain! 'testing)
(effects! '(write))

(define t--models-held '())

(define (t--models-reply json)
  (list 'ok #t 'status 200 'body "" 'json json))

(define (t--models-tags)
  (list 'models
        (list (list 'name "llama3:8b" 'size 4661224676
                    'details (list 'family "llama" 'parameter_size "8.0B"
                                   'quantization_level "Q4_0"))
              (list 'name "qwen2.5:0.5b" 'size 394998579
                    'details (list 'parameter_size "0.5B"
                                   'quantization_level "Q4_K_M")))))

(define (t--models-ps)
  (list 'models
        (list (list 'name "qwen2.5:0.5b" 'size_vram 1073741824
                    'expires_at "2026-09-17T18:04:33.12+05:30"))))

;; the calls the last test made, newest first
(define t--models-calls '())

(define (t--models-stub!)
  (set! t--models-calls '())
  (set! *models-request*
    (lambda (method path body seconds k)
      (set! t--models-calls (cons (list method path body) t--models-calls))
      (k (cond ((equal? path "/api/tags") (t--models-reply (t--models-tags)))
               ((equal? path "/api/ps") (t--models-reply (t--models-ps)))
               (else (t--models-reply '())))))))

(define (t--models-setup!)
  (set! t--models-held (list *models-request* models-host *models-error*))
  (set! models-host "http://localhost:11434")
  (set! *models-error* #f)
  (t--models-stub!))

(define (t--models-teardown!)
  (set! *models-request* (nth 0 t--models-held))
  (set! models-host (nth 1 t--models-held))
  (set! *models-error* (nth 2 t--models-held))
  (when (buffer-exists? *models-buffer*) (buffer-kill! *models-buffer*))
  (when (buffer-exists? *models-detail-buffer*)
    (buffer-kill! *models-detail-buffer*)))

(define (t--models-show!)
  (list-mode-show! "models-mode")
  (wait-until (lambda () (string-contains? (buffer-text *models-buffer*) "llama3"))
              3000))

(deftest 'models-a-host-is-a-url
  "a name a person types becomes the URL the requests go to"
  (lambda ()
    (check-equal! (models--host-url "") "http://localhost:11434" "nothing is this machine")
    (check-equal! (models--host-url "local") "http://localhost:11434" "so is local")
    (check-equal! (models--host-url "box.local") "http://box.local:11434"
                  "a bare name takes the scheme and the port")
    (check-equal! (models--host-url "10.0.0.4:8080") "http://10.0.0.4:8080"
                  "a port the person gave stays")
    (check-equal! (models--host-url "http://box:11434/") "http://box:11434"
                  "the trailing slash goes")
    (check-equal! (models--host-url "https://gpu.example.com/ollama")
                  "https://gpu.example.com/ollama"
                  "a path means a proxy, and no port is added")))

(deftest 'models-labels-read-as-a-person-reads-them
  "bytes become GB, and a timestamp becomes a clock"
  (lambda ()
    (check-equal! (models--size-label 4661224676) "4.3 GB" "a model in GB")
    (check-equal! (models--size-label 268435456) "256.0 MB" "a small one in MB")
    (check-equal! (models--size-label #f) "" "no size, no label")
    (check-equal! (models--clock "2026-09-17T18:04:33.12+05:30") "18:04" "the clock")
    (check-equal! (models--clock #f) "" "no expiry, no clock")))

(deftest 'models-the-loaded-ones-come-first
  "the list answers what the host is doing now, before what it could do"
  (lambda ()
    (let* ((rows (models--sort
                   (models--merge (models--models (t--models-tags))
                                  (map models--loaded-row
                                       (models--models (t--models-ps))))))
           (first (nth 0 rows))
           (second (nth 1 rows)))
      (check-equal! (length rows) 2 "one row per installed model")
      (check-equal! (plist-get first 'name) "qwen2.5:0.5b" "the loaded one is first")
      (check-true! (plist-get first 'loaded) "and it says it is loaded")
      (check-equal! (plist-get first 'vram) 1073741824 "with the memory it holds")
      (check-equal! (plist-get first 'until) "18:04" "and when it goes")
      (check-equal! (plist-get second 'name) "llama3:8b" "the other one follows")
      (check-false! (plist-get second 'loaded) "and it is not loaded")
      (check-equal! (plist-get second 'params) "8.0B" "it reads its own details"))))

(deftest 'models-a-loaded-model-the-tags-do-not-name-still-gets-a-row
  "a host can hold a model in memory that it does not list"
  (lambda ()
    (let ((rows (models--merge '() (list (list "ghost:7b" 700000000 "18:09")))))
      (check-equal! (length rows) 1 "the row is there")
      (check-equal! (plist-get (nth 0 rows) 'name) "ghost:7b" "under its own name")
      (check-true! (plist-get (nth 0 rows) 'loaded) "and it is loaded"))))

(deftest 'models-the-list-shows-what-the-host-holds
  "the table, the state column, and the meta line"
  (lambda ()
    (t--models-setup!)
    (check-true! (t--models-show!) "the rows arrive")
    (let* ((text (buffer-text *models-buffer*))
           (lines (string-split text "\n")))
      (check-true! (string-contains? text "qwen2.5:0.5b") "the loaded model is there")
      (check-true! (string-contains? text "4.3 GB") "a size reads as a size")
      (check-true! (string-contains? text "loaded 1.0 GB until 18:04")
                   "the state says what the host holds and for how long")
      (check-true! (string-contains? text "2 models, 1 loaded")
                   "the meta counts both")
      (check-true! (string-contains? text "http://localhost:11434")
                   "and names the host"))
    (t--models-teardown!)))

(deftest 'models-a-host-that-does-not-answer-says-so
  "a refused connection is the answer, not an empty table with no reason"
  (lambda ()
    (t--models-setup!)
    (set! *models-request*
      (lambda (method path body seconds k)
        (k (list 'ok #f 'status #f 'body "" 'error "connection refused"))))
    (list-mode-show! "models-mode")
    (wait-until (lambda () (string-contains? (buffer-text *models-buffer*)
                                             "connection refused"))
                3000)
    (check-true! (string-contains? (buffer-text *models-buffer*)
                                   "no answer: connection refused")
                 "the meta line carries the reason")
    (check-equal! (length (list-entries *models-buffer*)) 0 "and the table is empty")
    (t--models-teardown!)))

(deftest 'models-the-keys-name-the-commands
  "the verbs are commands, and the keymap is data"
  (lambda ()
    (let ((keys (plist-get (list-mode-opts "models-mode") 'keys)))
      (check-equal! (cadr (assoc "RET" keys)) "models-show" "RET shows the model")
      (check-equal! (cadr (assoc "s" keys)) "models-start" "s loads it")
      (check-equal! (cadr (assoc "k" keys)) "models-stop" "k unloads it")
      (check-equal! (cadr (assoc "i" keys)) "models-install" "i installs another")
      (check-equal! (cadr (assoc "d" keys)) "models-uninstall" "d uninstalls one")
      (check-equal! (cadr (assoc "h" keys)) "models-set-host" "h changes the host"))))

(deftest 'models-load-and-unload-are-one-request-each
  "s and k send the same call with the other keep_alive"
  (lambda ()
    (t--models-setup!)
    (check-true! (t--models-show!) "the rows arrive")
    (set! t--models-calls '())
    (with-current-buffer *models-buffer* (lambda () (run-command "models-start")))
    (let ((call (nth 0 (reverse t--models-calls))))
      (check-equal! (nth 0 call) "POST" "a load is a POST")
      (check-equal! (nth 1 call) "/api/generate" "to generate, with no prompt")
      (check-equal! (plist-get (nth 2 call) 'keep_alive) models-keep-alive
                    "and it names how long the model stays")
      (check-equal! (plist-get (nth 2 call) 'model) "qwen2.5:0.5b"
                    "the model on the line")
      (check-equal! (plist-get (nth 2 call) 'name) "qwen2.5:0.5b"
                    "under the old field name as well, for an older host"))
    (set! t--models-calls '())
    (with-current-buffer *models-buffer* (lambda () (run-command "models-stop")))
    (let ((call (nth 0 (reverse t--models-calls))))
      (check-equal! (nth 1 call) "/api/generate" "an unload is the same call")
      (check-equal! (plist-get (nth 2 call) 'keep_alive) 0 "with keep_alive 0"))
    (t--models-teardown!)))

(deftest 'models-what-a-model-is-goes-to-its-own-buffer
  "RET asks the host to show the model, and renders the answer"
  (lambda ()
    (t--models-setup!)
    (check-true! (t--models-show!) "the rows arrive")
    (set! *models-request*
      (lambda (method path body seconds k)
        (k (t--models-reply
             (list 'details (list 'family "qwen2" 'parameter_size "0.5B"
                                  'quantization_level "Q4_K_M")
                   'parameters "stop token")))))
    (with-current-buffer *models-buffer* (lambda () (run-command "models-show")))
    (let ((text (buffer-text *models-detail-buffer*)))
      (check-true! (string-contains? text "qwen2.5:0.5b") "the name heads the page")
      (check-true! (string-contains? text "family         qwen2") "the family")
      (check-true! (string-contains? text "quantization   Q4_K_M") "the quantization")
      (check-true! (string-contains? text "stop token") "and the parameters"))
    (t--models-teardown!)))
