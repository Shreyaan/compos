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
