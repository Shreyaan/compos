;;; http-test.scm --- the HTTP client: options in, replies out.
;;;
;;; Nothing here reaches the network. The option building and the reply
;;; reading are the whole policy this package owns; the primitive's own
;;; refusals happen before a request leaves, so they cost no traffic
;;; either.

(domain! 'testing)
(effects! '(read))

(define (t--plist-get pl key) (if (pair? pl) (plist-get pl key) #f))

(deftest 'http-names-the-editor-to-a-server
  "a request carries a user-agent, and a caller's own one wins"
  (lambda ()
    (check-equal! (t--plist-get (http--headers '()) 'user-agent) http-user-agent
                  "an empty option set still names the editor")
    (check-equal! (t--plist-get (http--headers '(headers (accept "text/plain")))
                                'accept)
                  "text/plain" "the caller's own header survives")
    (check-equal! (t--plist-get (http--headers '(headers (user-agent "mine")))
                                'user-agent)
                  "mine" "a plist answers with the first pair, so the caller's wins")
    ;; a header set written as pairs is for names that are not symbols:
    ;; merging a default into it would make a list nothing could read
    (check-equal! (http--headers '(headers (("X-Trace-Id" "7"))))
                  '(("X-Trace-Id" "7"))
                  "a pair-form header set is left exactly as it is")))

(deftest 'http-chooses-a-body-by-its-shape
  "a plist body is JSON, a string body is bytes, anything else is no body"
  (lambda ()
    (check-equal! (t--plist-get (http--with-body "POST" '(name "ada") '()) 'json)
                  '(name "ada") "a plist becomes a JSON body")
    (check-false! (t--plist-get (http--with-body "POST" '(name "ada") '()) 'body)
                  "and not a byte body as well")
    (check-equal! (t--plist-get (http--with-body "POST" "a=1" '()) 'body)
                  "a=1" "a string is the bytes")
    (check-false! (t--plist-get (http--with-body "POST" #f '()) 'json)
                  "#f sends no body")
    (check-equal! (t--plist-get (http--with-body "PUT" #f '()) 'method)
                  "PUT" "the verb is the one the caller asked for")
    (check-equal! (t--plist-get (http--with-method "GET" '(method "POST")) 'method)
                  "GET" "the verb of the call beats a method left in the options")))

(define t--reply
  '(ok #t status 200
    headers (content-type "application/json" etag "abc")
    body "{\"id\":7}"
    json (id 7)))

(define t--not-found
  '(ok #f status 404 headers (content-type "text/html")
    body "<html>\nmore" ))

(define t--unreached
  '(ok #f status #f headers () body "" error "connection refused"))

(deftest 'http-reads-one-answer-one-way
  "the readers answer for a success, a status failure and a request that never arrived"
  (lambda ()
    (check-true! (http-ok? t--reply) "2xx is ok")
    (check-equal! (http-status t--reply) 200 "the status is a number")
    (check-equal! (http-json t--reply) '(id 7) "the parsed body is there as well")
    (check-false! (http-message t--reply) "a success has nothing to report")
    (check-false! (http-error t--reply) "and no error line")
    ;; HTTP/2 writes header names lower-cased, and a caller should not have
    ;; to know that
    (check-equal! (http-header t--reply "Content-Type") "application/json"
                  "a header answers whatever the capitalisation")
    (check-equal! (http-header t--reply 'etag) "abc" "a symbol name works too")
    (check-false! (http-header t--reply 'nothing) "a header that is not there is #f")
    (check-false! (http-ok? t--not-found) "404 is not ok")
    (check-equal! (http-message t--not-found) "HTTP 404: <html>"
                  "a status failure reports the status and the first line")
    (check-equal! (http-message t--unreached) "connection refused"
                  "a request that never arrived reports why")
    (check-false! (http-status t--unreached) "and has no status")))

(deftest 'http-readers-never-throw
  "plist-get stops the interpreter on #f, so no reader may hand it one"
  (lambda ()
    (for-each
      (lambda (junk)
        (check-false! (http-ok? junk) "ok? of junk is #f")
        (check-false! (http-status junk) "status of junk is #f")
        (check-equal! (http-body junk) "" "body of junk is empty")
        (check-false! (http-json junk) "json of junk is #f")
        (check-false! (http-header junk 'content-type) "a header of junk is #f"))
      (list #f '() "not a reply" 7))))

;; A refusal is the same plist shape as an answer. These never open a
;; socket: the primitive decides before it asks Req for anything.
(deftest 'http-refuses-a-request-it-cannot-make
  "a bad URL and an unknown method answer like a failure, not by throwing"
  (lambda ()
    (let ((r (http-request "example.com/api")))
      (check-false! (http-ok? r) "a URL with no scheme is not ok")
      (check-false! (http-status r) "and never reached a server")
      (check-contains! (http-error r) "absolute" "the error says what is wrong"))
    (check-contains! (http-error (http-request "ftp://example.com")) "https"
                     "a scheme we do not speak is refused here")
    (check-contains! (http-error (http-request 7)) "string"
                     "a URL that is not a string is refused here")
    (check-contains! (http-error (http-request "https://example.com" '(method "FETCH")))
                     "Unsupported HTTP method" "an invented verb is refused here")
    (check-contains! (http-message (http-get "nope")) "absolute"
                     "and the whole client reports it as one line")))
