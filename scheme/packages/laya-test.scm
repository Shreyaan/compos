;;; laya-test.scm --- packages/laya.scm: the decision model's daemon.
;;;
;;; Nothing here starts the daemon. What this package owns is where the
;;; daemon is registered, what its spec says, and that the script it names
;;; ships with the editor.

(domain! 'testing)
(effects! '(read))

(deftest 'laya-registers-its-daemon-where-a-manager-looks
  "the endpoint registry is the one place a long-lived program is named"
  (lambda ()
    (let ((spec (endpoint-spec "laya")))
      (check-true! (pair? spec) "the daemon is in the endpoint registry")
      (check-equal! (plist-get spec 'framing) "line"
                    "one JSON line a request, one a reply")
      (check-equal! (plist-get spec 'serves) "models"
                    "and it says it serves models, which is how the list finds it")
      (check-equal! (plist-get spec 'command) laya-python
                    "the python that holds the laya-mlx package")
      (check-equal! (nth 0 (plist-get spec 'args)) (laya-script)
                    "running the daemon that ships beside this package"))))

(deftest 'laya-the-daemon-ships-with-the-editor
  "a spec naming a script nobody installed is a daemon that never starts"
  (lambda ()
    (check-true! (file-exists? (laya-script)) "the daemon script is there")
    (check-true! (string-suffix? "laya-daemon.py" (laya-script)) "under its own name")))

(deftest 'laya-says-whether-this-machine-can-run-it
  "decide asks this before it chooses the laya backend"
  (lambda ()
    (let ((held laya-python))
      (set! laya-python "/no/such/python3")
      (check-false! (laya-available?) "no python, no laya")
      (set! laya-python held)
      (check-equal! (laya-available?) (file-exists? laya-python)
                    "and with one, laya is as available as its python"))))

(deftest 'laya-the-daemon-answers-the-shape-an-http-reply-answers
  "one shape for a server, a socket and a pipe, so a caller reads one thing"
  (lambda ()
    (let ((r (endpoint-json-reply #t (list "{\"ok\": true, \"models\": []}"))))
      (check-true! (http-ok? r) "an answer that says ok is an answer")
      (check-equal! (plist-get (http-json r) 'models) '() "and its JSON is the body"))
    (let ((r (endpoint-json-reply #t (list "{\"ok\": false, \"error\": \"no checkpoint\"}"))))
      (check-false! (http-ok? r) "a daemon that refuses is not an answer")
      (check-true! (string-contains? (http-message r) "no checkpoint") "and it says why"))
    (let ((r (endpoint-json-reply #f "the pipe closed")))
      (check-false! (http-ok? r) "a dead pipe is not an answer")
      (check-true! (string-contains? (http-message r) "pipe") "and it says what happened"))
    (let ((r (endpoint-json-reply #t (list "Traceback (most recent call last):"))))
      (check-false! (http-ok? r) "nor is a line that is not JSON"))))
