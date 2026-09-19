;;; web-server.scm --- programmable inbound HTTP servers.
;;;
;;; Elixir and Bandit own listeners, HTTP parsing, limits, and response writes.
;;; Scheme handlers own routes and all callback or webhook policy.

(category! 'system)
(domain! 'web-servers)
(effects! '(write external))

(public! 'web-server-start!
  "(web-server-start! NAME SPEC HANDLER) — start an HTTP callback or webhook server; SPEC has 'host, 'port, and 'max-body")
(public! 'web-server-stop!
  "(web-server-stop! NAME) — stop the named HTTP server; stopping a missing server succeeds")

(effects! '(read external))

(defrecipe! "receive an HTTP callback or webhook"
  "(web-server-start! {{name}} '(host \"127.0.0.1\" port 0) (lambda (request) (list 'status 200 'headers '((\"content-type\" \"text/plain\")) 'body \"ok\")))"
  (list (list 'name "Server name: ")))
