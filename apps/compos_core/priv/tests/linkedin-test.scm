;;; linkedin-test.scm --- packages/linkedin.scm, the two readings, offline.
;;;
;;; The page is never fetched here. Both parsers take the markdown the
;;; stylesheet-then-pandoc reading hands them, so the fixtures below are
;;; that markdown, copied from a real reading, and the tests say what a
;;; row is. The tab state is a buffer local, so switching tabs is checked
;;; without a browser and without a window.

(domain! 'testing)
(effects! '(read))

(define t--li-projects
  (string-append
    "# Projects\n\n"
    "- [Anthriq Compiler Expert](https://www.linkedin.com/talent/hire/1923656034/overview)  \n"
    "  *Created 1/27/2026, Pipeline: 3 candidates*\n\n"
    "- [Engineering Manager](https://www.linkedin.com/talent/hire/1411635218/overview)  \n"
    "  *Created 8/9/2024, Pipeline: 23 candidates*\n"))

;; the third line is the whole last message, and the meta line carries as
;; little as the day it moved: an old thread has no InMail status and no
;; unread badge
(define t--li-inbox
  (string-append
    "# Messages\n\n"
    "- [Arnab chaudhuri](https://www.linkedin.com/talent/inbox/0/main/id/2-ZThkMDNlY2Mt_100)  \n"
    "  *Sep 12, Accepted, unread*\n\n"
    "  > Thank you for reaching out. Please let me know a convenient time.\n\n"
    "- [Shashank N](https://www.linkedin.com/talent/inbox/0/main/id/2-ZDhiYjQ4YzQt_100)  \n"
    "  *Mar 6*\n\n"
    "  > Sure thing\n"))

(deftest 'a-conversation-is-its-person-its-day-and-the-whole-last-message
  "the inbox reading, as rows"
  (lambda ()
    (let* ((rows (li-parse-threads t--li-inbox))
           (first (car rows))
           (second (car (cdr rows))))
      (check-equal! (length rows) 2 "two conversations")
      (check-equal! (plist-get first 'name) "Arnab chaudhuri" "who it is with")
      (check-equal! (plist-get first 'moved) "Sep 12" "the day it last moved")
      (check-equal! (plist-get first 'status) "Accepted" "where the InMail stands")
      (check-equal! (plist-get first 'unread) #t "the unread badge")
      (check-equal! (plist-get first 'body)
                    "Thank you for reaching out. Please let me know a convenient time."
                    "the message, not a truncation")
      (check-equal! (plist-get second 'status) "" "a thread with no InMail status")
      (check-equal! (plist-get second 'unread) #f "a thread with no badge"))))

(deftest 'two-conversations-never-share-a-key
  "the key is the head of the urn, and the tail is the same on every thread"
  (lambda ()
    (let ((keys (map li-key (li-parse-threads t--li-inbox))))
      (check-equal! (length keys) 2 "two keys")
      (check-false! (equal? (car keys) (car (cdr keys))) "and they differ"))))

(deftest 'a-page-is-named-after-the-row-that-opened-it
  "a project by its id, a conversation by the head of its urn"
  (lambda ()
    (let ((project (car (li-parse t--li-projects)))
          (thread (car (li-parse-threads t--li-inbox))))
      (check-equal! (linkedin-detail-buffer project) "*linkedin:1923656034*" "a project page")
      (check-equal! (linkedin-detail-buffer thread) "*linkedin:msg:ZThkMDNlY2Mt*" "a thread page"))))

(effects! '(write))

(deftest 'each-tab-answers-with-its-own-rows-and-its-own-columns
  "one listing buffer, two readings over it"
  (lambda ()
    (let ((buf "*t-linkedin-tabs*"))
      (buffer-create buf)
      (buffer-set-local! buf 'linkedin-rows (li-parse t--li-projects))
      (buffer-set-local! buf 'linkedin-threads (li-parse-threads t--li-inbox))
      (buffer-set-local! buf 'linkedin-tab 'projects)
      (check-equal! (length (linkedin--rows buf)) 2 "the projects")
      (check-equal! (car (car (linkedin--columns buf))) "project" "the projects columns")
      (buffer-set-local! buf 'linkedin-tab 'messages)
      (check-equal! (car (car (linkedin--rows buf))) 'kind "the conversations")
      (check-equal! (car (car (linkedin--columns buf))) "who" "the messages columns")
      (buffer-kill! buf))))

;;; --- the index as cards --------------------------------------------------
;;; The same rows, projected as blocks. A field role is what the shared
;;; list lays a card out by, so the roles are what these check.

(define (t--li-field block role)
  (let loop ((cs (plist-get block 'children)))
    (cond ((null? cs) #f)
          ((equal? (cadr (car (plist-get (car cs) 'attrs))) role) (car cs))
          (else (loop (cdr cs))))))

(deftest 'a-card-says-the-name-the-count-and-the-day
  "a project row, as the blocks the list lays out"
  (lambda ()
    (let* ((row (car (li-parse t--li-projects)))
           (block (linkedin--project-block "*t-li-cards*" row)))
      (check-equal! (plist-get (t--li-field block "primary") 'text)
                    "Anthriq Compiler Expert" "the name leads")
      (check-equal! (plist-get (t--li-field block "count") 'text) "3" "the pipeline counts")
      (check-true! (li-has? (plist-get (t--li-field block "secondary") 'text) "1/27/2026")
                   "and the day it was created sits under both"))))

(deftest 'an-unread-card-says-so-where-the-list-can-see-it
  "the unread attribute is the shared list's own: it lights the left edge"
  (lambda ()
    (let* ((rows (li-parse-threads t--li-inbox))
           (unread (linkedin--thread-block "*t-li-cards*" (car rows)))
           (read (linkedin--thread-block "*t-li-cards*" (car (cdr rows)))))
      (check-equal! (cadr (car (plist-get unread 'attrs))) "true" "the badge carries")
      (check-equal! (cadr (car (plist-get read 'attrs))) "false" "and a read thread says so")
      (check-equal! (plist-get (t--li-field unread "detail") 'text)
                    "Thank you for reaching out. Please let me know a convenient time."
                    "the whole message rides the card; the clamp is CSS"))))

(deftest 'the-tab-you-are-on-is-the-filled-pill
  "the head draws its own blocks, so a tab bar reads as tabs"
  (lambda ()
    (let ((buf "*t-linkedin-head*"))
      (buffer-create buf)
      (buffer-set-local! buf 'linkedin-rows (li-parse t--li-projects))
      (buffer-set-local! buf 'linkedin-threads (li-parse-threads t--li-inbox))
      (buffer-set-local! buf 'linkedin-tab 'projects)
      (let* ((head (linkedin--composml-head buf '()))
             (pills (plist-get (nth 1 head) 'children))
             (style (lambda (p) (cadr (car (plist-get p 'attrs))))))
        (check-equal! (length pills) 2 "one pill per tab")
        (check-equal! (plist-get (car pills) 'text) "projects  2" "each says what it holds")
        (check-true! (li-has? (style (car pills)) "background:var(--accent-fg")
                     "the tab you are on is filled")
        (check-false! (li-has? (style (cadr pills)) "background:var(--accent-fg")
                      "and the other is outlined"))
      (buffer-kill! buf))))
