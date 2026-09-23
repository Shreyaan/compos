;;; ats.scm --- SVS recruiting as a live website app

(package! 'ats)
(origin! 'user)

(unless (boundp 'define-site-app)
  (load "/Users/svs/src/compos/scheme/packages/site-app.scm"))

(define *ats-spec*
  (list 'name 'ats
        'title "ATS"
        'base-url "https://svsrecruiting.com"
        'home "/staff/approvals"
        'home-page 'approvals
        ;; a page is called by who and for what
        'detail-name (lambda (row)
                       (string-append (site-app-field row 'candidate) " · " (site-app-field row 'job)))
        ;; words the site colours, wherever they appear on a page
        'tones '(("^(?i)(unfit|withdrawn|withdraw|reject|rejected|declined|dropped)$" bad)
                 ("^(?i)(potential|pending|snoozed|scheduled|maybe)$" warn)
                 ("^(?i)(elite|strong|fit|advance|advanced|approved|hired|shortlisted|offer)$" good)
                 ("^(?i)(new|applied|create|created)$" info))
        'pages
        (list
          (list 'id 'approvals
                'label "Approvals"
                'key "1"
                'path "/staff/approvals"
                'wait "main section ul > li"
                'sheet "/Users/svs/src/svs-recruiting/compos-recruiting/approvals.xsl"
                'detail-sheet "/Users/svs/src/svs-recruiting/compos-recruiting/approval-detail.xsl"
                'detail-wait "#approvals-show-root"
                'detail-tab-param "tab"
                'detail-mode "ats-approval-mode"
                ;; only the happy path has a key: approve; o opens the site for the rest
                'detail-keys (list "a")
                'detail-tabs
                (map (lambda (tab)
                       (let ((button (string-append "#approvals-show-root nav.brut-tabs button[phx-value-tab=\"" (car tab) "\"]")))
                         (list 'id (car tab) 'tag (cadr tab)
                               'click button
                               'wait (string-append button ".brut-tab--active"))))
                     '(("history" "c-application-history")
                       ("assessment" "c-assessment")
                       ("candidate" "c-candidate")
                       ("job" "c-job-details")))
                'columns
                (list (list 'label "★" 'width 5 'field 'rating 'face "dim")
                      (list 'label "candidate" 'width 22 'field 'candidate)
                      (list 'label "proposal" 'width 20 'field 'proposal)
                      (list 'label "fit" 'width 11 'field 'fit 'face "dim")
                      (list 'label "job" 'width #f 'field 'job))))))

(define-site-app *ats-spec*)

(domain! 'web)
(effects! '(write external display))

(define-command "ats" "Open SVS recruiting as a live website app"
  (lambda () (site-app-open! 'ats)))
