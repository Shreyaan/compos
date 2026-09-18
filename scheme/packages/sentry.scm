;;; sentry.scm --- inspect and manage production errors in the editor.
;;;
;;; The package reads Sentry issues and can resolve one after confirmation.
;;; The token comes from the environment or one named Doppler config.
;;; curl reads it from a temporary config file, never from the command line.
;;;
;;; This is the API a model calls through eval: sentry-list-issues,
;;; sentry-issue-detail, sentry-issue-events, sentry-event-detail and
;;; sentry-resolve-issue. The list and detail buffers it once drew are gone;
;;; a chat is the surface.

(domain! 'sentry)
(effects! '(write))

(defgroup 'sentry "Sentry: read production errors in the editor.")

(defcustom 'sentry-base-url "https://sentry.io"
  "The Sentry API base URL." 'group 'sentry)

(defcustom 'sentry-org "svs-recruiting"
  "The default Sentry organization slug." 'group 'sentry)

(defcustom 'sentry-project "ats-ash"
  "The default Sentry project slug." 'group 'sentry)

(defcustom 'sentry-environment "prod"
  "The default Sentry environment." 'group 'sentry)

(defcustom 'sentry-time-range "24h"
  "The default Sentry statistics period." 'group 'sentry)

(defcustom 'sentry-query "is:unresolved"
  "The default Sentry issue search." 'group 'sentry)

;; The maximum rows one Sentry request returns.
(define sentry-limit 20)

(defcustom 'sentry-timeout 30
  "Seconds to wait for one Sentry request." 'group 'sentry)

(defcustom 'sentry-curl-program "curl"
  "The curl executable for Sentry requests." 'group 'sentry)

;;; --- small helpers ------------------------------------------------------------

(define (sentry--text value)
  (cond ((string? value) value)
        ((number? value) (number->string value))
        ((symbol? value) (symbol->string value))
        (else "")))

(define (sentry--config-escape text)
  (string-replace (string-replace (sentry--text text) "\\" "\\\\") "\"" "\\\""))

(define (sentry--truncate text width)
  (let ((value (sentry--text text)))
    (if (> (string-length value) width)
        (string-append (substring value 0 (- width 1)) "…")
        value)))

;; Sentry titles and culprit strings can contain addresses. The package shows
;; neither event payloads nor user objects, and masks common address forms here.
(define (sentry--redact text)
  (let* ((value (sentry--text text))
         (value (re-replace-all
                  "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
                  value "[redacted-email]")))
    (re-replace-all
      "\\b(?:[0-9]{1,3}\\.){3}[0-9]{1,3}\\b"
      value "[redacted-ip]")))

(define (sentry--limit value)
  (let ((n (if (number? value) value sentry-limit)))
    (max 1 (min 50 n))))

(define (sentry--url path params)
  (string-append
    sentry-base-url path
    (if (null? params)
        ""
        (string-append
          "?"
          (string-join
            (map (lambda (pair)
                   (string-append (url-encode (car pair)) "="
                                  (url-encode (sentry--text (cadr pair)))))
                 params)
            "&")))))

(define (sentry--project-path tail)
  (string-append "/api/0/projects/" (url-encode sentry-org) "/"
                 (url-encode sentry-project) "/" tail))

(define (sentry--org-path tail)
  (string-append "/api/0/organizations/" (url-encode sentry-org) "/" tail))

;;; --- credentials and wire -----------------------------------------------------

(define *sentry--seq* 0)

(define (sentry--tmp-path)
  (set! *sentry--seq* (+ *sentry--seq* 1))
  (let ((dir (string-append (compos-home) "/tmp")))
    (make-directory! dir)
    (string-append dir "/sentry-" (number->string (current-time)) "-"
                   (number->string *sentry--seq*) ".conf")))

;; the key chain answers: the environment, a key file, or the secret provider
(define (sentry--token) (key-get "SENTRY_AUTH_TOKEN"))

(define (sentry--curl-config url token)
  (string-append
    "url = \"" (sentry--config-escape url) "\"\n"
    "request = \"GET\"\n"
    "header = \"Authorization: Bearer " (sentry--config-escape token) "\"\n"
    "header = \"Accept: application/json\"\n"
    "max-time = " (number->string sentry-timeout) "\n"
    "silent\nshow-error\nwrite-out = \"\\n%{http_code}\"\n"))

(define (sentry--curl-write-config url token body)
  (string-append
    "url = \"" (sentry--config-escape url) "\"\n"
    "request = \"PUT\"\n"
    "header = \"Authorization: Bearer " (sentry--config-escape token) "\"\n"
    "header = \"Accept: application/json\"\n"
    "header = \"Content-Type: application/json\"\n"
    "data = \"" (sentry--config-escape body) "\"\n"
    "max-time = " (number->string sentry-timeout) "\n"
    "silent\nshow-error\nwrite-out = \"\\n%{http_code}\"\n"))

;; Return curl output with its final HTTP status line. Tests replace this seam.
(define (sentry--curl url)
  (let ((token (sentry--token)))
    (if (not token)
        "SENTRY_AUTH_TOKEN is not configured\n000"
        (let ((path (sentry--tmp-path)))
          (write-file! path (sentry--curl-config url token))
          (let ((out (shell-command->string
                       (string-append sentry-curl-program " --config "
                                      (sh-quote path)))))
            (delete-file! path)
            out)))))

(define (sentry--curl-write url body)
  (let ((token (sentry--token)))
    (if (not token)
        "SENTRY_AUTH_TOKEN is not configured\n000"
        (let ((path (sentry--tmp-path)))
          (write-file! path (sentry--curl-write-config url token body))
          (let ((out (shell-command->string
                       (string-append sentry-curl-program " --config "
                                      (sh-quote path)))))
            (delete-file! path)
            out)))))

(define *sentry-transport* sentry--curl)
(define *sentry-write-transport* sentry--curl-write)

;; The async transport: K gets the wire when curl answers, and the
;; calling lane moves on. The issue list fetches through this seam — a
;; synchronous request would hold the UI lane for the network round
;; trip. Tests replace this seam with a synchronous stub.
(define (sentry--curl-async url k)
  (let ((token (sentry--token)))
    (if (not token)
        (k "SENTRY_AUTH_TOKEN is not configured\n000")
        (let ((path (sentry--tmp-path)))
          (write-file! path (sentry--curl-config url token))
          (shell-command->string
            (string-append sentry-curl-program " --config "
                           (sh-quote path))
            (lambda (out)
              (delete-file! path)
              (k out)))))))

(define *sentry-async-transport* sentry--curl-async)

(define (sentry--split-status output)
  (let* ((lines (string-split output "\n"))
         (last (car (reverse lines)))
         (status (string->number last)))
    (if (number? status)
        (list status (string-join (reverse (cdr (reverse lines))) "\n"))
        (list 0 output))))

(define (sentry--error text)
  (list 'errors (list (list 'message text))))

(define (sentry--error? reply)
  (and (pair? reply) (equal? (car reply) 'errors)))

(define (sentry--error-message reply)
  (if (not (sentry--error? reply))
      #f
      (or (plist-get (car (plist-get reply 'errors)) 'message)
          "Sentry request failed")))

;; Parse every result into JSON or one stable error plist. Do not include an
;; HTTP response body in an error because it can hold deployment details.
(define (sentry--parse-reply wire)
  (let* ((parts (sentry--split-status wire))
         (status (car parts))
         (body (cadr parts)))
    (cond ((= status 0)
           (sentry--error (string-trim body)))
          ((or (< status 200) (> status 299))
           (sentry--error (string-append "Sentry returned HTTP "
                                         (number->string status))))
          (else
            (let ((reply (json-parse body)))
              (if (equal? reply #f)
                  (sentry--error "Sentry returned invalid JSON")
                  reply))))))

(define (sentry--request url)
  (sentry--parse-reply (*sentry-transport* url)))

(define (sentry--request-write url payload)
  (let* ((wire (*sentry-write-transport* url (json-encode payload)))
         (parts (sentry--split-status wire))
         (status (car parts))
         (body (cadr parts)))
    (cond ((= status 0)
           (sentry--error (string-trim body)))
          ((or (< status 200) (> status 299))
           (sentry--error (string-append "Sentry returned HTTP "
                                         (number->string status))))
          ((equal? (string-trim body) "")
           (list 'status "resolved"))
          (else
            (let ((reply (json-parse body)))
              (if (equal? reply #f)
                  (sentry--error "Sentry returned invalid JSON")
                  reply))))))

;;; --- API ----------------------------------------------------------------------

;; Reduce API objects at the boundary. Callers cannot accidentally print user
;; objects, request payloads, breadcrumbs, stack traces, or issue metadata.
(define (sentry--safe-issue issue)
  (list 'id (plist-get issue 'id)
        'shortId (plist-get issue 'shortId)
        'title (sentry--redact (plist-get issue 'title))
        'status (plist-get issue 'status)
        'level (plist-get issue 'level)
        'culprit (sentry--redact (plist-get issue 'culprit))
        'count (plist-get issue 'count)
        'userCount (plist-get issue 'userCount)
        'firstSeen (plist-get issue 'firstSeen)
        'lastSeen (plist-get issue 'lastSeen)
        'permalink (plist-get issue 'permalink)))

(define (sentry--safe-event event)
  (list 'eventID (plist-get event 'eventID)
        'dateCreated (plist-get event 'dateCreated)
        'environment (plist-get event 'environment)
        'platform (plist-get event 'platform)
        'culprit (sentry--redact (plist-get event 'culprit))))

(define (sentry--issues-url query environment time-range count)
  (sentry--url
    (sentry--project-path "issues/")
    (list (list "environment" (or environment sentry-environment))
          (list "statsPeriod" (or time-range sentry-time-range))
          (list "query" (or query sentry-query))
          (list "per_page" count))))

(define (sentry--parse-issues reply count)
  (if (sentry--error? reply)
      reply
      (map sentry--safe-issue (take reply count))))

(define (sentry-list-issues &optional query environment time-range limit)
  (let ((count (sentry--limit limit)))
    (sentry--parse-issues
      (sentry--request (sentry--issues-url query environment time-range count))
      count)))

(define (sentry--issue-url issue-id)
  (sentry--url
    (sentry--org-path
      (string-append "issues/" (url-encode (sentry--text issue-id)) "/"))
    '()))

(define (sentry-issue-detail issue-id)
  (sentry--request (sentry--issue-url issue-id)))

(define (sentry-issue-events issue-id &optional environment time-range limit)
  (let* ((count (sentry--limit limit))
         (reply
           (sentry--request
             (sentry--url
               (sentry--org-path
                 (string-append "issues/" (url-encode (sentry--text issue-id))
                                "/events/"))
               (list (list "environment" (or environment sentry-environment))
                     (list "statsPeriod" (or time-range sentry-time-range))
                     (list "per_page" count))))))
    (if (sentry--error? reply)
        reply
        (map sentry--safe-event (take reply count)))))

(define (sentry-event-detail event-id)
  (let ((reply
          (sentry--request
            (sentry--url
              (sentry--project-path
                (string-append "events/" (url-encode (sentry--text event-id)) "/"))
              '()))))
    (if (sentry--error? reply) reply reply)))

(define (sentry-resolve-issue issue-id)
  (sentry--request-write
    (sentry--url
      (sentry--org-path
        (string-append "issues/"
                       (url-encode (sentry--text issue-id))
                       "/"))
      '())
    (list 'status "resolved")))

;;; --- an issue as text ---------------------------------------------------------
;;; the one rendering the API keeps: what a model or a person reads

(define (sentry--issue-text issue)
  (let* ((metadata (plist-get issue 'metadata))
         (exception (sentry--text (plist-get metadata 'value))))
    (string-append
      (sentry--text (plist-get issue 'shortId)) "  "
      (sentry--issue-title issue) "\n\n"
      "Exception\n"
      (if (equal? exception "") "No exception message was returned." exception)
      "\n\nRaw issue JSON\n"
      (sentry--pretty-json issue))))

(define (sentry--pretty-json value)
  (json-encode value #t))

(define (sentry--issue-title issue)
  (let* ((title (string-trim (sentry--text (plist-get issue 'title))))
         (metadata (plist-get issue 'metadata))
         (kind (string-trim (sentry--text (plist-get metadata 'type)))))
    (cond ((not (equal? title "")) (sentry--redact title))
          ((not (equal? kind "")) kind)
          (else (sentry--text (plist-get issue 'shortId))))))

;;; --- catalog ------------------------------------------------------------------

(category! 'sentry)
(effects! '(read external))
(public! 'sentry-list-issues
  "(sentry-list-issues [QUERY] [ENVIRONMENT] [TIME-RANGE] [LIMIT]) — list Sentry issues; defaults are unresolved production issues from the last 24 hours")
(public! 'sentry-issue-detail
  "(sentry-issue-detail ISSUE-ID) — read one Sentry issue")
(public! 'sentry-issue-events
  "(sentry-issue-events ISSUE-ID [ENVIRONMENT] [TIME-RANGE] [LIMIT]) — list events for one Sentry issue")
(public! 'sentry-event-detail
  "(sentry-event-detail EVENT-ID) — read safe identifiers for one Sentry event")
(effects! '(write external))
(public! 'sentry-resolve-issue
  "(sentry-resolve-issue ISSUE-ID) — resolve one Sentry issue")
