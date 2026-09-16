;;; substack.scm --- subscriptions, publication pages, and post readers.

(domain! 'web)
(effects! '(read))

(defcustom 'substack-group-name "*substack*"
  "The group that owns the Substack listing, publication pages, and readers."
  'group 'substack)
(defcustom 'substack-post-limit 20
  "How many recent posts each publication page lists."
  'group 'substack 'type 'number)

(define *substack-buffer* "*substack*")
(define *substack-log* "*substack-log*")

(define (substack--get value key) (and (pair? value) (plist-get value key)))
(define (substack--text value)
  (if (string? value) value (if value (value->string value) "")))
(define (substack--contains? text needle)
  (pair? (cdr (string-split (substack--text text) needle))))
(define (substack--date value)
  (let ((s (substack--text value)))
    (if (>= (string-length s) 10) (substring s 0 10) s)))
(define (substack--base-url publication)
  (let ((custom (substack--get publication 'custom_domain))
        (subdomain (substack--get publication 'subdomain)))
    (cond ((and (string? custom) (not (equal? custom "")))
           (string-append "https://" custom))
          ((and (string? subdomain) (not (equal? subdomain "")))
           (string-append "https://" subdomain ".substack.com"))
          (else ""))))
(define (substack--replace-buffer! buf text)
  (unless (buffer-exists? buf) (buffer-create buf))
  (buffer-set-read-only! buf #f)
  (let ((old (buffer-text buf)))
    (if (equal? old "") (buffer-append! buf text) (buffer-replace! buf old text)))
  (buffer-set-read-only! buf #t)
  buf)
(define (substack--html-escape text)
  (let loop ((pairs '(("&" "&amp;") ("<" "&lt;") (">" "&gt;") ("\"" "&quot;")))
             (out (substack--text text)))
    (if (null? pairs) out
        (loop (cdr pairs)
              (string-join (string-split out (car (car pairs)))
                           (car (cdr (car pairs))))))))

(define (substack--subscription payload publication-id)
  (let loop ((rows (or (substack--get payload 'subscriptions) '())))
    (cond ((null? rows) #f)
          ((equal? (substack--get (car rows) 'publication_id) publication-id) (car rows))
          (else (loop (cdr rows))))))
(define (substack--own-ids payload)
  (map (lambda (entry) (substack--get entry 'publication_id))
       (or (substack--get payload 'publicationUsers) '())))
(define (substack--publication-row payload publication)
  (let* ((id (substack--get publication 'id))
         (subscription (substack--subscription payload id)))
    (list 'id id
          'name (substack--text (substack--get publication 'name))
          'author (substack--text
                    (or (substack--get publication 'author_name)
                        (substack--get publication 'primary_profile_name)))
          'url (substack--base-url publication)
          'membership (substack--text
                        (and subscription (substack--get subscription 'membership_state)))
          'last-post "")))
(define (substack-parse-subscriptions payload)
  "Return subscription rows and exclude publications owned by the account."
  (let ((own (substack--own-ids payload)))
    (filter (lambda (row)
              (and (substack--get row 'id)
                   (not (member (substack--get row 'id) own))))
            (map (lambda (publication)
                   (substack--publication-row payload publication))
                 (or (substack--get payload 'publications) '())))))

(effects! '(write display))
(define (substack-home-group!)
  (and (string? substack-group-name)
       (not (equal? substack-group-name ""))
       (group-ensure-record! substack-group-name)))
(define (substack-enter-group!)
  (let ((id (substack-home-group!)))
    (when (and id (not (equal? (frame-group) id))) (switch-to-group! id))
    id))
(define (substack-join-group! buf)
  (when (buffer-exists? buf)
    (let ((id (or (substack-home-group!) (frame-group))))
      (when (and id (not (buffer-in-group? buf id))) (buffer-add-group! buf id))))
  buf)
(define (substack-log! text)
  (unless (buffer-exists? *substack-log*) (buffer-create *substack-log*))
  (buffer-append! *substack-log* (string-append text "\n")))

(effects! '(write external))
(define (substack--tab k)
  (tab-list
    (lambda (tabs)
      (let loop ((rest tabs))
        (cond ((null? rest) (k #f))
              ((substack--contains? (substack--get (car rest) 'url)
                                    "substack.com/settings")
               (k (substack--get (car rest) 'id)))
              (else (loop (cdr rest))))))))
(define (substack--fetch-authenticated! k)
  (substack--tab
    (lambda (tab)
      (if (not tab)
          (begin (substack-log! "No substack.com/settings tab is open")
                 (message "Open substack.com/settings, then press g")
                 (k #f))
          (tab-eval tab
            "(()=>{const x=new XMLHttpRequest();x.open('GET','/api/v1/subscriptions/page_v2?cb='+Date.now(),false);x.send();return x.status===200?x.responseText:'ERROR '+x.status})()"
            (lambda (text)
              (let ((payload (and (string? text) (json-parse text))))
                (if payload (k payload)
                    (begin
                      (substack-log! (string-append "Subscription fetch failed: "
                                                   (substack--text text)))
                      (message (string-append "Substack fetch failed. See "
                                              *substack-log*))
                      (k #f))))))))))
(define *substack-browser-fetch* substack--fetch-authenticated!)
(define *substack-json-fetch* (lambda (url k) (http-get-json url '() k)))

;;; --- listing state and authenticated actions -----------------------------

(define (substack--rows buf)
  (or (buffer-local buf 'substack-rows) (list-entries buf) '()))
(define (substack--set-rows! rows)
  (buffer-set-local! *substack-buffer* 'substack-rows rows)
  (buffer-set-local! *substack-buffer* 'list-source-entries rows)
  (list-refresh! *substack-buffer*)
  rows)
(define (substack--fetch-subscriptions! buf k)
  (substack-join-group! buf)
  (*substack-browser-fetch*
    (lambda (payload) (k (and payload (substack-parse-subscriptions payload))))))
(define (substack--row-by-id id)
  (let loop ((rows (substack--rows *substack-buffer*)))
    (cond ((null? rows) #f)
          ((equal? (substack--get (car rows) 'id) id) (car rows))
          (else (loop (cdr rows))))))
(define (substack--remove-row! id)
  (substack--set-rows!
    (filter (lambda (row) (not (equal? (substack--get row 'id) id)))
            (substack--rows *substack-buffer*))))
(define (substack--unsubscribe-key! buf id)
  (let* ((row (substack--row-by-id id))
         (name (if row (substack--get row 'name) (number->string id))))
    (substack--tab
      (lambda (tab)
        (if (not tab)
            (message "Open substack.com/settings, then try x again")
            (tab-eval tab
              (string-append
                "(()=>{const x=new XMLHttpRequest();x.open('DELETE','/api/v1/free',false);"
                "x.setRequestHeader('content-type','application/json');"
                "x.send(JSON.stringify({publication_id:" (number->string id)
                ",source:'account'}));return String(x.status)})()")
              (lambda (status)
                (if (or (equal? status "200") (equal? status "404"))
                    (begin (substack--remove-row! id)
                           (message (string-append "Unsubscribed: " name)))
                    (begin
                      (substack-log! (string-append name ": DELETE " (substack--text status)))
                      (message (string-append "Unsubscribe failed. See "
                                              *substack-log*)))))))))
    #t))

;;; --- publication pages ---------------------------------------------------

(effects! '(read write external display))
(define (substack--detail-buffer row)
  (string-append "*substack:" (number->string (substack--get row 'id)) "*"))
(define (substack--archive-url row)
  (string-append (substack--get row 'url)
                 "/api/v1/archive?sort=new&search=&offset=0&limit="
                 (number->string substack-post-limit)))
(define (substack--post-author post)
  (let ((bylines (or (substack--get post 'publishedBylines) '())))
    (if (pair? bylines)
        (substack--text (substack--get (car bylines) 'name))
        "")))
(define (substack--plist-set plist key value)
  (cond ((null? plist) (list key value))
        ((equal? (car plist) key) (cons key (cons value (cdr (cdr plist)))))
        (else (cons (car plist)
                    (cons (car (cdr plist))
                          (substack--plist-set (cdr (cdr plist)) key value))))))
(define (substack--enrich! row posts)
  (if (null? posts) row
      (let* ((first (car posts))
             (author (substack--post-author first))
             (row1 (substack--plist-set
                     row 'author
                     (if (equal? author "") (substack--get row 'author) author)))
             (row2 (substack--plist-set
                     row1 'last-post
                     (substack--date (substack--get first 'post_date))))
             (id (substack--get row 'id)))
        (substack--set-rows!
          (map (lambda (old)
                 (if (equal? (substack--get old 'id) id) row2 old))
               (substack--rows *substack-buffer*)))
        row2)))
(define (substack--fetch-posts! buf)
  (let ((row (buffer-local buf 'substack-publication)))
    (when row
      (message (string-append "Reading " (substack--get row 'name) "..."))
      (*substack-json-fetch* (substack--archive-url row)
        (lambda (posts)
          (if (not (list? posts))
              (begin
                (substack-log! (string-append "Archive failed: "
                                             (substack--get row 'name)))
                (message "Could not read this publication"))
              (begin
                (buffer-set-local! buf 'substack-posts posts)
                (buffer-set-local! buf 'list-source-entries posts)
                (buffer-set-local! buf 'substack-publication
                                   (substack--enrich! row posts))
                (list-refresh! buf)
                (message (string-append (number->string (length posts))
                                        " posts · "
                                        (substack--get row 'name))))))))))
(define (substack-show-detail! row)
  "Show ROW in one publication buffer beside the listing."
  (when row
    (let ((buf (substack--detail-buffer row)))
      (unless (buffer-exists? buf) (buffer-create buf))
      (buffer-set-local! buf 'substack-publication row)
      (substack-join-group! buf)
      (unless (buffer-derived-mode? buf "substack-detail-mode")
        (with-current-buffer buf
          (lambda () (set-mode! "substack-detail-mode"))))
      (when (null? (or (buffer-local buf 'substack-posts) '()))
        (substack--fetch-posts! buf))
      (buffer-set-local! *substack-buffer* 'substack-current-detail buf)
      (display-buffer-detail! buf *substack-buffer*)
      buf)))

;;; --- post readers --------------------------------------------------------

(define substack-reader-css
  "<style>:root{color-scheme:light dark}html{font-size:clamp(14px,.72vw,32px)}body{margin:0 auto;padding:2rem;max-width:46rem;font:1rem/1.65 Georgia,serif}h1{font:700 2rem/1.15 system-ui,sans-serif}.meta{color:#777;font:.86rem/1.4 system-ui,sans-serif;margin-bottom:2rem}img{max-width:100%;height:auto}pre{overflow:auto}a{color:#2f7d62}</style>")
(define (substack--reader-buffer post)
  (string-append "*substack-read:" (number->string (substack--get post 'id)) "*"))
(define (substack--post-url publication post)
  (or (substack--get post 'canonical_url)
      (string-append (substack--get publication 'url) "/p/"
                     (substack--get post 'slug))))
(define (substack--post-api-url publication post)
  (string-append (substack--get publication 'url) "/api/v1/posts/"
                 (substack--get post 'slug)))
(define (substack--reader-html publication post)
  (let ((body (or (substack--get post 'body_html)
                  (substack--get post 'truncated_body_text)
                  "<p>This post did not return a readable body.</p>"))
        (author (substack--post-author post)))
    (string-append
      substack-reader-css "<article><h1>"
      (substack--html-escape (substack--get post 'title))
      "</h1><div class='meta'>"
      (substack--html-escape
        (string-append
          (if (equal? author "") (substack--get publication 'author) author)
          " · " (substack--date (substack--get post 'post_date))
          " · " (substack--get publication 'name)))
      "</div>" body "</article>")))
(define (substack--apply-reader! buf publication post)
  (substack--replace-buffer! buf (substack--reader-html publication post))
  (buffer-set-local! buf 'substack-publication publication)
  (buffer-set-local! buf 'substack-post post)
  (buffer-set-local! buf 'preview-renderer "html")
  (enable-minor-mode! buf "preview-mode")
  (preview-heal! buf)
  buf)
(define (substack--fetch-reader! buf)
  (let ((publication (buffer-local buf 'substack-publication))
        (post (buffer-local buf 'substack-post)))
    (when (and publication post)
      (*substack-json-fetch* (substack--post-api-url publication post)
        (lambda (full)
          (if full
              (begin
                (substack--apply-reader! buf publication full)
                (message (substack--get full 'title)))
              (begin
                (substack-log! (string-append "Post failed: "
                                             (substack--get post 'title)))
                (message "Could not read this post"))))))))
(define (substack-show-reader! owner post)
  "Show POST in one reader buffer beside publication OWNER."
  (when post
    (let* ((publication (buffer-local owner 'substack-publication))
           (buf (substack--reader-buffer post)))
      (unless (buffer-exists? buf) (buffer-create buf))
      (buffer-set-local! buf 'substack-publication publication)
      (buffer-set-local! buf 'substack-post post)
      (substack-join-group! buf)
      (unless (buffer-derived-mode? buf "substack-reader-mode")
        (with-current-buffer buf
          (lambda () (set-mode! "substack-reader-mode"))))
      (when (= (buffer-size buf) 0)
        (substack--replace-buffer! buf
          (string-append (substack--get post 'title) "\n\nLoading...\n"))
        (substack--fetch-reader! buf))
      (buffer-set-local! *substack-buffer* 'substack-current-reader buf)
      (display-buffer-detail! buf owner)
      (substack-layout!)
      buf)))

;;; --- shared commands -----------------------------------------------------

(effects! '(write external display))
(define (substack--mode) (buffer-local (current-buffer) 'mode-name))
(define-command "substack-open" "Open the next Substack view"
  (lambda ()
    (cond ((equal? (substack--mode) "substack-mode")
           (substack-show-detail! (list-current *substack-buffer*)))
          ((equal? (substack--mode) "substack-detail-mode")
           (substack-show-reader! (current-buffer)
                                  (list-current (current-buffer))))
          (else (message "There is no deeper Substack view")))))
(define-command "substack-refresh" "Refresh the current Substack view"
  (lambda ()
    (cond ((equal? (substack--mode) "substack-mode") (substack-sync!))
          ((equal? (substack--mode) "substack-detail-mode")
           (substack--fetch-posts! (current-buffer)))
          ((equal? (substack--mode) "substack-reader-mode")
           (substack--fetch-reader! (current-buffer)))
          (else (message "This is not a Substack buffer")))))
(define-command "substack-open-browser"
  "Open this publication or post in the browser"
  (lambda ()
    (let* ((buf (current-buffer))
           (publication
             (if (equal? (substack--mode) "substack-mode")
                 (list-current *substack-buffer*)
                 (buffer-local buf 'substack-publication)))
           (post (buffer-local buf 'substack-post))
           (url (and publication
                     (if post
                         (substack--post-url publication post)
                         (substack--get publication 'url)))))
      (if url (tab-open url) (message "No Substack URL on this row")))))

;;; --- modes ---------------------------------------------------------------

(define (substack--publication-cells buf row)
  (list (substack--get row 'name)
        (list (substack--get row 'author) "dim")
        (list (substack--get row 'last-post) "dim")
        (list (substack--get row 'membership) "dim")))
(define (substack--post-cells buf post)
  (list (list (substack--date (substack--get post 'post_date)) "dim")
        (substack--get post 'title)
        (list (substack--text (substack--get post 'audience)) "dim")))

(define-list-mode! "substack-mode"
  (list
    'doc
      "Your Substack subscriptions. Moving previews a publication. RET opens it. d flags unsubscribe and x executes. g syncs. o opens the site. q quits."
    'buffer *substack-buffer*
    'transient #f
    'local-filter #t
    'noun "subscription"
    'rows substack--rows
    'cache-fetch substack--fetch-subscriptions!
    'cache-ttl 60
    'key (lambda (buf row) (substack--get row 'id))
    'columns (lambda (buf)
      (list (list "publication" #f) (list "author" 28)
            (list "last post" 10) (list "membership" 12)))
    'cells substack--publication-cells
    'title (lambda (buf) "Substack")
    'meta (lambda (buf)
      (string-append (number->string (length (substack--rows buf)))
                     " subscriptions"))
    'total (lambda (buf) (length (substack--rows buf)))
    'footer (lambda (buf)
      '(("RET" "publication") ("SPC" "mark") ("d" "unsubscribe")
        ("x" "execute") ("o" "browser") ("g" "sync")
        ("/" "filter") ("q" "quit")))
    'preview (lambda (buf row) (substack-show-detail! row))
    'flags (list (list "d" "D" "unsubscribe" substack--unsubscribe-key! #t))
    'keys '(("RET" "substack-open") ("o" "substack-open-browser")
            ("g" "substack-refresh") ("q" "quit-window"))))

(define-list-mode! "substack-detail-mode"
  (list
    'doc
      "One publication and its recent posts. Moving previews a post. RET reads it. g refreshes. o opens the publication. q quits."
    'transient #f
    'rows (lambda (buf) (or (buffer-local buf 'substack-posts) '()))
    'key (lambda (buf post) (substack--get post 'id))
    'columns (lambda (buf)
      (list (list "date" 10) (list "post" #f) (list "audience" 12)))
    'cells substack--post-cells
    'title (lambda (buf)
      (let ((row (buffer-local buf 'substack-publication)))
        (if row (substack--get row 'name) "Substack")))
    'meta (lambda (buf)
      (let ((row (buffer-local buf 'substack-publication)))
        (if row
            (string-append (substack--get row 'author) " · "
                           (substack--get row 'url))
            "")))
    'total (lambda (buf)
      (length (or (buffer-local buf 'substack-posts) '())))
    'footer (lambda (buf)
      '(("RET" "read") ("o" "browser") ("g" "refresh") ("q" "quit")))
    'preview (lambda (buf post) (substack-show-reader! buf post))
    'keys '(("RET" "substack-open") ("o" "substack-open-browser")
            ("g" "substack-refresh") ("q" "quit-window"))))

(define-mode "substack-reader-mode"
  (lambda ()
    (substack-join-group! (current-buffer))
    (buffer-set-read-only! (current-buffer) #t)))
(mode-parent! "substack-reader-mode" "special-mode")
(mode-doc! "substack-reader-mode"
  "One Substack post. o opens it in the browser, g refreshes it, q quits. The detail keys walk sibling readers.")
(mode-keys! "substack-reader-mode"
  '(("o" "substack-open-browser") ("g" "substack-refresh")
    ("q" "quit-window")))

(detail-name! "substack-detail-mode"
  (lambda (buf)
    (let ((row (buffer-local buf 'substack-publication)))
      (string-append "*" (if row (substack--get row 'name) "Substack") "*"))))
(detail-name! "substack-reader-mode"
  (lambda (buf)
    (let ((post (buffer-local buf 'substack-post)))
      (string-append "*" (if post (substack--get post 'title) "Substack post") "*"))))

(mode-icon! "substack-mode" "")
(mode-icon! "substack-detail-mode" "")
(mode-icon! "substack-reader-mode" "")

;;; --- app entry and layout ------------------------------------------------

(define (substack-current-detail)
  (buffer-local *substack-buffer* 'substack-current-detail))
(define (substack-current-reader)
  (buffer-local *substack-buffer* 'substack-current-reader))
(define (substack-layout!)
  (let* ((id (substack-home-group!))
         (chat (and id (group-chat id)))
         (panes (filter buffer-exists?
                        (list *substack-buffer*
                              (substack-current-detail)
                              (substack-current-reader)
                              chat))))
    (when (pair? (cdr panes)) (tile-adaptive-windows! panes))
    panes))
(define (substack-sync!)
  "Fetch subscriptions and redraw the app."
  (unless (buffer-exists? *substack-buffer*) (buffer-create *substack-buffer*))
  (substack-join-group! *substack-buffer*)
  (unless (buffer-derived-mode? *substack-buffer* "substack-mode")
    (with-current-buffer *substack-buffer*
      (lambda () (set-mode! "substack-mode"))))
  (message "Syncing Substack subscriptions...")
  (substack--fetch-subscriptions! *substack-buffer*
    (lambda (rows)
      (when rows
        (substack--set-rows! rows)
        (let ((row (list-current *substack-buffer*)))
          (when row (substack-show-detail! row)))
        (substack-layout!)
        (let ((id (substack-home-group!)))
          (when id (group-layout-save! id)))
        (message (string-append (number->string (length rows))
                                " Substack subscriptions"))))))
(define-command "substack" "Open the Substack app"
  (lambda ()
    (substack-enter-group!)
    (unless (buffer-exists? *substack-buffer*) (buffer-create *substack-buffer*))
    (substack-join-group! *substack-buffer*)
    (unless (buffer-derived-mode? *substack-buffer* "substack-mode")
      (with-current-buffer *substack-buffer*
        (lambda () (set-mode! "substack-mode"))))
    (switch-to-buffer! *substack-buffer*)
    (if (pair? (substack--rows *substack-buffer*))
        (begin
          (list-refresh! *substack-buffer*)
          (substack-show-detail! (list-current *substack-buffer*))
          (substack-layout!))
        (substack-sync!))))

(public! 'substack-parse-subscriptions
  "(substack-parse-subscriptions PAYLOAD) — rows from page_v2, excluding owned publications")
(public! 'substack-show-detail!
  "(substack-show-detail! ROW) — show ROW in its publication buffer")
(public! 'substack-show-reader!
  "(substack-show-reader! OWNER POST) — show POST in its reader buffer")
(public! 'substack-sync!
  "(substack-sync!) — fetch subscriptions and redraw the app")
(public! 'substack
  "(substack) — open the Substack app")
