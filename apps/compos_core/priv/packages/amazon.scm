;;; amazon.scm --- the storefront as an app: a listing, a page per row.
;;;
;;; Amazon is a website, but a website is a poor place to compare eight
;;; things. The listing is a table you walk with n and p; every row you
;;; land on renders as its own buffer beside it, so C-` flips between the
;;; three you are actually choosing between without going back to the list.
;;;
;;; The app reads the signed-in session. (browse URL) fetches through the
;;; reader, which carries the browser's cookies, so the prices here are the
;;; account's own -- business prices, excluding GST, with the retail price
;;; beside them. Nothing is scraped from a logged-out page.
;;;
;;; The app lives in ONE group (app-creator): the listing and every product
;;; page join *amazon*, so the group saves the three-column layout and
;;; gives it back. Actions that leave the editor -- the cart -- are the
;;; reader pressing a button, never a render.

(domain! 'web)
(effects! '(read))

(defcustom 'amazon-group-name "*amazon*"
  "The group the Amazon app lives in. The listing and the product pages are one app, so they always open in this group and a layout holding them is saved and restored with it."
  'group 'amazon)

(defcustom 'amazon-host "www.amazon.in"
  "The Amazon storefront the app reads. Change it to shop another country's site."
  'group 'amazon)

(defcustom 'amazon-default-query "scientific calculator"
  "The search the app opens with the first time, before you have run one."
  'group 'amazon)

(defcustom 'amazon-fetch-tries 25
  "How many times the app looks for the search page before giving up. Each look is 400ms."
  'group 'amazon 'type 'number)

(define *amazon-buffer* "*amazon*")
(define *amazon-log* "*amazon-log*")

;;; --- reading the page ----------------------------------------------------
;;; The reader hands us Markdown, not HTML: one blank-line-separated
;;; paragraph per thing the page says. A result begins at its photo and ends
;;; at the next one, so the whole parser is a walk over paragraphs.

(define (amz-after s sub) (let ((p (string-split s sub))) (if (pair? (cdr p)) (car (cdr p)) #f)))
(define (amz-before s sub) (car (string-split s sub)))
(define (amz-has? s sub) (pair? (cdr (string-split s sub))))
(define (amz-clip s n) (if (> (string-length s) n) (substring s 0 n) s))

(define (amz-replace s from to)
  (let ((ps (string-split s from)))
    (let loop ((l (cdr ps)) (acc (car ps)))
      (if (null? l) acc (loop (cdr l) (string-append acc to (car l)))))))

(define (amz-clean s) (amz-replace (amz-replace s "\\|" "|") "  " " "))

;; when it lands. The page writes "Sun, 20 Sept", "23 - 25 Sept" or
;; "Tomorrow 6 am - 10 am", and never a year.
(define *amz-months*
  '(("Jan" 1) ("Feb" 2) ("Mar" 3) ("Apr" 4) ("May" 5) ("Jun" 6)
    ("Jul" 7) ("Aug" 8) ("Sep" 9) ("Oct" 10) ("Nov" 11) ("Dec" 12)))

(define (amz-day s)
  (let ((n (string->number s)))
    (and (number? n) (not (amz-has? s ".")) (equal? (number->string n) s)
         (>= n 1) (<= n 31) n)))

(define (amz-month tok)
  (let loop ((ms *amz-months*))
    (cond ((null? ms) #f)
          ((and (>= (string-length tok) 3)
                (equal? (substring tok 0 3) (car (car ms))))
           (car (cdr (car ms))))
          (else (loop (cdr ms))))))

(define (amz-month-name n)
  (let loop ((ms *amz-months*))
    (cond ((null? ms) "")
          ((equal? n (car (cdr (car ms)))) (car (car ms)))
          (else (loop (cdr ms))))))

(define (amz-today) (string->number (format-time (current-time) "%Y%m%d")))
(define (amz-tomorrow) (string->number (format-time (+ (current-time) 86400) "%Y%m%d")))

;; the day it lands as YYYYMMDD; a range counts from its first day and an
;; unreadable line sorts last
(define (amz-delivery-key text)
  (if (not (string? text))
      99999999
      (let ((dated (let loop ((ts (string-split (amz-replace text "," " ") " ")) (day #f))
                     (cond ((null? ts) #f)
                           ((and day (amz-month (car ts))) (list day (amz-month (car ts))))
                           ((and (not day) (amz-day (car ts))) (loop (cdr ts) (amz-day (car ts))))
                           (else (loop (cdr ts) day))))))
        (cond (dated
               (let* ((mon (car (cdr dated)))
                      (now (amz-today))
                      (year (quotient now 10000)))
                 ;; no year on the page, so a month behind us is next year's
                 (+ (* 10000 (if (< mon (modulo (quotient now 100) 100)) (+ year 1) year))
                    (* 100 mon) (car dated))))
              ((amz-has? text "Tomorrow") (amz-tomorrow))
              ((amz-has? text "Today") (amz-today))
              (else 99999999)))))

(define (amz-delivery-label text)
  (let ((k (amz-delivery-key text)))
    (cond ((>= k 99999999) "—")
          ((equal? k (amz-today)) "today")
          ((equal? k (amz-tomorrow)) "tomorrow")
          (else (string-append (number->string (modulo k 100)) " "
                               (amz-month-name (modulo (quotient k 100) 100)))))))

;; soonest first, stable, so one day's products keep the order Amazon gave them
(define (amz-sort-by-delivery rows)
  (let* ((keyed (map (lambda (r) (list (amz-delivery-key (plist-get r 'delivery)) r)) rows))
         (sorted (let ins-all ((ks keyed) (acc '()))
                   (if (null? ks)
                       acc
                       (ins-all (cdr ks)
                                (let place ((xs acc) (out '()))
                                  (cond ((null? xs) (reverse (cons (car ks) out)))
                                        ((< (car (car ks)) (car (car xs)))
                                         (append (reverse out) (cons (car ks) xs)))
                                        (else (place (cdr xs) (cons (car xs) out))))))))))
    (map (lambda (p) (car (cdr p))) sorted)))

;; "Rs1,263.56Rs1,263.56excl. GST" -- the page prints every price twice
(define (amz-rupees s)
  (let ((a (amz-after s "₹")))
    (and a (let ((b (amz-before a "₹"))) (if (equal? b "") #f b)))))

;; The canonical link, not a colour variant and not the next row's teaser:
;; the ASIN we want is the one followed by a search-result ref. A sponsored
;; row wraps its link in a click tracker, so the same pair comes URL-encoded.
(define (amz-asin-in p)
  (let try ((seps (list (list "/dp/" "/ref=sr_")
                        (list "%2Fdp%2F" "%2Fref%3Dsr_")
                        (list "/dp/" "/ref=cs_sr_dp_1"))))
    (if (null? seps)
        #f
        (let* ((sep (car (car seps)))
               (mark (car (cdr (car seps))))
               (mlen (string-length mark))
               (tails (cdr (string-split p sep))))
          (let scan ((ts tails))
            (cond ((null? ts) (try (cdr seps)))
                  ((and (> (string-length (car ts)) (+ 10 mlen))
                        (equal? (substring (car ts) 10 (+ 10 mlen)) mark))
                   (substring (car ts) 0 10))
                  (else (scan (cdr ts)))))))))

(define (amz-image p)
  (let ((a (amz-after p "](")))
    (and a (amz-has? a "m.media-amazon.com/images/I/")
         (amz-before (amz-before a ")") "?"))))

(define *amz-chrome-titles* '("Results" "More results" "Need help?" "Filters" "Sponsored" "Highly rated"))

(define (amz-title? t)
  (and (> (string-length t) 12)
       (not (member t *amz-chrome-titles*))
       (not (amz-has? t " results for "))))

;; the brand is its own short heading above the long one
(define (amz--longest ts)
  (let loop ((l ts) (best #f))
    (cond ((null? l) best)
          ((or (not best) (> (string-length (car l)) (string-length best))) (loop (cdr l) (car l)))
          (else (loop (cdr l) best)))))

(define (amz--brand ts long)
  (let loop ((l ts))
    (cond ((null? l) #f)
          ((and (< (string-length (car l)) 22) (not (equal? (car l) long))) (car l))
          (else (loop (cdr l))))))

;; one result, from the paragraphs between two photos. A group with no
;; "Add to cart" is a carousel, not a result, and is dropped.
(define (amz-item paras)
  (let loop ((ps paras) (asin #f) (img #f) (titles '()) (rating #f) (revs #f)
             (biz #f) (incl #f) (mrp #f) (deliv #f) (spons #f) (cart #f))
    (if (null? ps)
        (let* ((long (amz--longest titles))
               (brand (and long (amz--brand titles long))))
          (and asin long cart
               (list 'asin asin
                     'title (amz-clean (if (and brand (not (amz-has? long brand)))
                                           (string-append brand " " long)
                                           long))
                     'img img 'rating rating 'reviews revs
                     'biz biz 'incl incl 'mrp mrp 'delivery deliv 'sponsored spons)))
        (let ((p (car ps)))
          (loop (cdr ps)
                (or asin (amz-asin-in p))
                (or img (amz-image p))
                (if (and (> (string-length p) 3)
                         (equal? (substring p 0 3) "## ")
                         (amz-title? (substring p 3 (string-length p))))
                    (cons (substring p 3 (string-length p)) titles)
                    titles)
                (or rating (and (amz-has? p " out of 5 stars") (amz-before p "*")))
                (or revs (and (amz-has? p "[(") (amz-has? p "out of 5 stars")
                              (amz-before (amz-after p "[(") ")")))
                (or biz (and (amz-has? p "excl. GST") (amz-rupees p)))
                (or incl (and (amz-has? p "incl. GST") (amz-rupees (or (amz-after p "[") p))))
                (or mrp (and (> (string-length p) 7) (equal? (substring p 0 7) "M.R.P: ") (amz-rupees p)))
                (or deliv (and (amz-has? p "delivery") (amz-clip p 44)))
                (or spons (amz-has? p "Sponsored Ad -"))
                (or cart (equal? p "Add to cart")))))))

(define (amz-parse text)
  (let* ((paras (string-split text "\n\n"))
         (groups (let loop ((ps paras) (cur '()) (acc '()))
                   (cond ((null? ps) (reverse (if (null? cur) acc (cons (reverse cur) acc))))
                         ((amz-image (car ps))
                          (loop (cdr ps) (list (car ps)) (if (null? cur) acc (cons (reverse cur) acc))))
                         (else (loop (cdr ps) (if (null? cur) cur (cons (car ps) cur)) acc)))))
         (items (filter (lambda (x) x) (map amz-item groups))))
    (let dedupe ((is items) (seen '()) (acc '()))
      (cond ((null? is) (reverse acc))
            ((member (plist-get (car is) 'asin) seen) (dedupe (cdr is) seen acc))
            (else (dedupe (cdr is) (cons (plist-get (car is) 'asin) seen) (cons (car is) acc)))))))

;;; --- the home group ------------------------------------------------------
;;; The app has one home, not whichever group the frame stood in when a key
;;; was pressed: a pane holding a member is a place, so the group saves this
;;; layout and restores it whole.

(effects! '(write display))

(define (amazon-home-group!)
  (and (boundp 'group-ensure-record!)
       (string? amazon-group-name)
       (not (equal? amazon-group-name ""))
       (group-ensure-record! amazon-group-name)))

(define (amazon-enter-group!)
  (let ((id (amazon-home-group!)))
    (when (and id (boundp 'switch-to-group!) (not (equal? (frame-group) id)))
      (switch-to-group! id))
    id))

(define (amazon-join-group! buf)
  (when (and buf (buffer-exists? buf))
    (let ((id (or (amazon-home-group!) (frame-group))))
      (when (and id (not (buffer-in-group? buf id)))
        (buffer-add-group! buf id))))
  buf)

(define (amazon-log! line)
  (unless (buffer-exists? *amazon-log*) (buffer-create *amazon-log*))
  (buffer-append! *amazon-log* (string-append line "\n")))

;;; --- fetching ------------------------------------------------------------
;;; (browse URL) reads the page through the reader and fills its buffer off
;;; the lane, so the answer is not here when the call returns. Look again
;;; until it lands: a search is one round trip to Amazon, not a stream.

(effects! '(read write external))

(define (amazon-search-url query)
  (string-append "https://" amazon-host "/s?k=" (url-encode query)))

(define (amz-link-url line)
  (let ((parts (string-split line "](")))
    (and (> (length parts) 1)
         (let ((u (car (string-split (car (reverse parts)) ")"))))
           (and (> (string-length u) 3) (equal? (substring u 0 3) "/s?") u)))))

(define (amazon-next-url text)
  (let loop ((ls (string-split text "\n")))
    (cond ((null? ls) #f)
          ((and (string-contains? (car ls) "[Next")
                (string-contains? (car ls) "ref=sr_pg_"))
           (let ((u (amz-link-url (car ls))))
             (and u (string-append "https://" amazon-host u))))
          (else (loop (cdr ls))))))

(define (amazon-product-url asin)
  (string-append "https://" amazon-host "/dp/" asin))

(define (amazon--land! buf tries k)
  (let ((text (if (buffer-exists? buf) (buffer-text buf) "")))
    (cond ((> (string-length text) 4000)
           (let ((rows (amz-parse text)))
             (buffer-kill! buf)
             (k rows)))
          ((<= tries 0)
           (when (buffer-exists? buf) (buffer-kill! buf))
           (k #f))
          (else
           (debounce! 'amazon-fetch 400
                      (lambda (_) (amazon--land! buf (- tries 1) k))
                      #f)))))

(define (amazon-fetch! query k)
  (amazon--land! (browse (amazon-search-url query)) amazon-fetch-tries k))

;;; --- the product page ----------------------------------------------------
;;; A detail is one buffer per row, named after the ASIN, so the details
;;; opened from one listing are siblings and C-` walks them. It renders as
;;; HTML: the preview iframe runs no scripts, so every button on the page is
;;; a compos: link the editor hands back to Scheme.

(define amazon-detail-css "<style>
:root{--bg:#faf9f7;--fg:#1b1a17;--dim:#6b6760;--line:#e3dfd8;--accent:#0f6b52;--chip:#efece6;--card:#fff}
@media (prefers-color-scheme:dark){:root{--bg:#161513;--fg:#eceae5;--dim:#9a958c;--line:#34312c;--accent:#5fd0aa;--chip:#26241f;--card:#fff}}
*{box-sizing:border-box}
html{font-size:clamp(13px,0.62vw,40px)}
body{margin:0;background:var(--bg);color:var(--fg);font:1rem/1.5 -apple-system,BlinkMacSystemFont,Inter,system-ui,sans-serif}
.wrap{padding:1.2rem;max-width:54rem}
.top{display:flex;gap:1.3rem;flex-wrap:wrap;align-items:flex-start}
.shot{flex:0 0 10rem;background:var(--card);border:1px solid var(--line);border-radius:.7rem;padding:.6rem}
.shot img{max-width:100%;max-height:13rem;height:auto;display:block;margin:0 auto}
.head{flex:1 1 18rem;min-width:14rem}
h1{font-size:1.4rem;line-height:1.3;margin:0 0 .4rem;letter-spacing:-.01em}
.price{font-size:1.9rem;font-weight:650;letter-spacing:-.02em;font-variant-numeric:tabular-nums}
.price small{font-size:.85rem;font-weight:400;color:var(--dim);margin-left:.55rem;text-decoration:line-through}
.chips{display:flex;gap:.4rem;flex-wrap:wrap;margin:.85rem 0 0}
.chip{background:var(--chip);border-radius:999px;padding:.2rem .7rem;font-size:.8rem;color:var(--dim);white-space:nowrap}
.chip.on{background:var(--accent);color:var(--bg);font-weight:600}
.act{margin:1.1rem 0 0;display:flex;gap:.6rem;flex-wrap:wrap}
.btn{display:inline-block;background:var(--accent);color:var(--bg);font-size:.9rem;font-weight:600;padding:.5rem 1.15rem;border-radius:999px;text-decoration:none;border:1px solid var(--accent)}
.btn.ghost{background:transparent;color:var(--accent)}
.btn.done{background:transparent;color:var(--dim);border-color:var(--line);font-weight:500}
table{border-collapse:collapse;margin:1.2rem 0 0;width:100%;font-size:.87rem}
td{padding:.42rem 0;border-top:1px solid var(--line);vertical-align:top}
td:first-child{color:var(--dim);width:42%;white-space:nowrap}
td:last-child{font-variant-numeric:tabular-nums}
a{color:var(--accent);text-decoration:none}
.note{margin:1.2rem 0 0;background:var(--chip);border-left:3px solid var(--accent);border-radius:.5rem;padding:.75rem .95rem;font-size:.9rem;white-space:pre-wrap}
.note h2{margin:0 0 .35rem;font-size:.72rem;font-weight:600;letter-spacing:.09em;text-transform:uppercase;color:var(--dim)}
</style>")

(define (amazon--row-field row key alt) (or (plist-get row key) alt))

(define (amazon-in-cart? asin)
  (member asin (or (buffer-local *amazon-buffer* 'amazon-cart) '())))

;; saved products and their notes live on the listing buffer, so they survive
;; the next search and come back with the desktop
(define (amazon-saved-list) (or (buffer-local *amazon-buffer* 'amazon-saved) '()))
(define (amazon-saved? asin) (and (member asin (amazon-saved-list)) #t))

;; a hidden product stays in the rows but out of the listing, so a search is
;; never re-read to get it back; X shows the hidden ones again, marked ⊘
(define (amazon-hidden-list) (or (buffer-local *amazon-buffer* 'amazon-hidden) '()))
(define (amazon-hidden? asin) (and (member asin (amazon-hidden-list)) #t))
(define (amazon-showing-hidden?) (and (buffer-local *amazon-buffer* 'amazon-show-hidden) #t))

(define (amazon-notes) (or (buffer-local *amazon-buffer* 'amazon-notes) '()))
(define (amazon-note asin)
  (let ((hit (assoc asin (amazon-notes)))) (and hit (car (cdr hit)))))

;; redraw the row, and the product's own page when it is open
(define (amazon-touch! asin)
  (let ((row (amazon-row-by-asin asin)))
    (when (and row (buffer-exists? (amazon-detail-buffer row)))
      (amazon-render-detail! (amazon-detail-buffer row) row)))
  (list-refresh! *amazon-buffer*))

(define (amazon-save-toggle! asin)
  (buffer-set-local! *amazon-buffer* 'amazon-saved
                     (if (amazon-saved? asin)
                         (filter (lambda (a) (not (equal? a asin))) (amazon-saved-list))
                         (cons asin (amazon-saved-list))))
  (amazon-touch! asin)
  (amazon-saved? asin))

(define (amazon-hide-toggle! asin)
  (buffer-set-local! *amazon-buffer* 'amazon-hidden
                     (if (amazon-hidden? asin)
                         (filter (lambda (a) (not (equal? a asin))) (amazon-hidden-list))
                         (cons asin (amazon-hidden-list))))
  (amazon-touch! asin)
  (amazon-hidden? asin))

(define (amazon-note-set! asin text)
  (let ((rest (filter (lambda (n) (not (equal? (car n) asin))) (amazon-notes))))
    (buffer-set-local! *amazon-buffer* 'amazon-notes
                       (if (or (not (string? text)) (equal? text ""))
                           rest
                           (cons (list asin text) rest))))
  (amazon-touch! asin))

(define (amazon-detail-html row)
  (let* ((asin (plist-get row 'asin))
         (img (plist-get row 'img))
         (mrp (plist-get row 'mrp))
         (incl (plist-get row 'incl))
         (rating (plist-get row 'rating))
         (revs (plist-get row 'reviews))
         (deliv (plist-get row 'delivery))
         (note (amazon-note asin))
         (kept? (amazon-saved? asin))
         (in? (amazon-in-cart? asin)))
    (string-append
     amazon-detail-css
     "<div class='wrap'><div class='top'>"
     (if img (string-append "<div class='shot'><img src='" img "' alt=''></div>") "")
     "<div class='head'><h1>" (plist-get row 'title) "</h1>"
     "<div class='price'>₹" (amazon--row-field row 'biz "—")
     (if mrp (string-append "<small>₹" mrp "</small>") "") "</div>"
     "<div class='chips'>"
     (if rating (string-append "<span class='chip'>★ " rating
                               (if revs (string-append " · " revs) "") "</span>") "")
     (if incl (string-append "<span class='chip'>₹" incl " incl. GST</span>") "")
     (if (plist-get row 'sponsored) "<span class='chip'>sponsored</span>" "")
     (if kept? "<span class='chip on'>saved</span>" "")
     (if in? "<span class='chip on'>in your cart</span>" "")
     "</div><div class='act'>"
     "<a class='btn" (if in? " done" "") "' href='compos:amazon-cart/" asin "'>"
     (if in? "✓ in cart · add another" "Add to cart") "</a>"
     "<a class='btn ghost' href='compos:amazon-save/" asin "'>"
     (if kept? "★ saved" "Save") "</a>"
     "<a class='btn ghost' href='compos:amazon-note/" asin "'>"
     (if note "Edit note" "Add a note") "</a>"
     "<a class='btn ghost' href='compos:amazon-open/" asin "'>Open in browser</a>"
     "</div></div></div><table>"
     "<tr><td>Price</td><td>₹" (amazon--row-field row 'biz "—") " excl. GST</td></tr>"
     (if incl (string-append "<tr><td>With GST</td><td>₹" incl "</td></tr>") "")
     (if mrp (string-append "<tr><td>M.R.P.</td><td>₹" mrp "</td></tr>") "")
     (if rating (string-append "<tr><td>Rating</td><td>" rating " / 5"
                               (if revs (string-append " · " revs " ratings") "") "</td></tr>") "")
     (if deliv (string-append "<tr><td>Delivery</td><td>" deliv "</td></tr>") "")
     "<tr><td>ASIN</td><td>" asin "</td></tr>"
     "</table>"
     (if note (string-append "<div class='note'><h2>Your note</h2>" note "</div>") "")
     "</div>")))

(define (amazon-detail-buffer row)
  (string-append "*amazon:" (plist-get row 'asin) "*"))

(define (amazon-render-detail! buf row)
  (unless (buffer-exists? buf) (buffer-create buf))
  (buffer-set-read-only! buf #f)
  (let ((old (buffer-text buf)) (new (amazon-detail-html row)))
    (if (> (string-length old) 0)
        (buffer-replace! buf old new)
        (buffer-append! buf new)))
  (buffer-set-local! buf 'amazon-row row)
  (buffer-set-local! buf 'amazon-title (amz-clip (plist-get row 'title) 40))
  (unless (buffer-derived-mode? buf "amazon-detail-mode")
    (with-current-buffer buf (lambda () (set-mode! "amazon-detail-mode"))))
  (buffer-set-local! buf 'preview-renderer "html")
  (enable-minor-mode! buf "preview-mode")
  (preview-heal! buf)
  (buffer-set-read-only! buf #t)
  buf)

(define (amazon-show-detail! row)
  (when row
    (let ((buf (amazon-render-detail! (amazon-detail-buffer row) row)))
      (amazon-join-group! buf)
      (display-buffer-detail! buf *amazon-buffer*)
      buf)))

;;; --- the cart ------------------------------------------------------------
;;; The add goes through the reader's own browser tab, so it lands in the
;;; signed-in cart and nothing on screen navigates. The answer is the cart
;;; page, which says whether the ASIN is in it.

(define (amazon-row-by-asin asin)
  (let loop ((rs (or (buffer-local *amazon-buffer* 'amazon-rows) '())))
    (cond ((null? rs) #f)
          ((equal? (plist-get (car rs) 'asin) asin) (car rs))
          (else (loop (cdr rs))))))

(define (amazon-name-of asin)
  (let ((r (amazon-row-by-asin asin))) (if r (amz-clip (plist-get r 'title) 48) asin)))

(define (amazon--tab k)
  (tab-list (lambda (ts)
    (let loop ((ts ts))
      (cond ((null? ts) (k #f))
            ((amz-has? (or (plist-get (car ts) 'url) "") amazon-host) (k (plist-get (car ts) 'id)))
            (else (loop (cdr ts))))))))

(define (amazon--cart-js asin)
  (string-append
   "(function(){window.__amzcart='pending';"
   "fetch('/gp/aws/cart/add.html?ASIN.1=" asin "&Quantity.1=1',{credentials:'include'})"
   ".then(function(r){return r.text()})"
   ".then(function(t){var d=new DOMParser().parseFromString(t,'text/html');"
   "var n=d.querySelector('#nav-cart-count');"
   "window.__amzcart=JSON.stringify({added:t.indexOf('" asin "')>-1,"
   "count:n?n.textContent.trim():null,title:(d.title||'').slice(0,60)})})"
   ".catch(function(e){window.__amzcart='err:'+e.message});return 'started'})()"))

(define (amazon--cart-done! asin answer)
  (if (and (string? answer) (amz-has? answer "\"added\":true"))
      (begin
        (unless (amazon-in-cart? asin)
          (buffer-set-local! *amazon-buffer* 'amazon-cart
                             (cons asin (or (buffer-local *amazon-buffer* 'amazon-cart) '()))))
        (amazon-log! (string-append asin " added -- " answer))
        (message (string-append (amazon-name-of asin) " added to the cart"))
        (let ((row (amazon-row-by-asin asin)))
          (when (and row (buffer-exists? (amazon-detail-buffer row)))
            (amazon-render-detail! (amazon-detail-buffer row) row)))
        (list-refresh! *amazon-buffer*))
      (begin
        (amazon-log! (string-append asin " failed -- " (if (string? answer) answer "no answer")))
        (message (string-append "Could not add " (amazon-name-of asin) " -- see " *amazon-log*)))))

(define (amazon-cart-add! asin)
  (message (string-append "Adding " (amazon-name-of asin) " to the cart..."))
  (amazon--tab
   (lambda (tab)
     (if (not tab)
         (begin (amazon-log! (string-append asin ": no " amazon-host " tab open"))
                (message (string-append "No " amazon-host " tab is open -- open one and try again")))
         (begin
           (tab-eval tab (amazon--cart-js asin) (lambda (v) #f))
           (debounce! 'amazon-cart 1800
                      (lambda (_)
                        (tab-eval tab "window.__amzcart"
                                  (lambda (v) (amazon--cart-done! asin v))))
                      #f))))))

(define (amazon-open-external! asin)
  (if (boundp 'tab-open)
      (begin (tab-open (amazon-product-url asin))
             (message (string-append "Opened " asin " in the browser")))
      (message "No browser is connected")))

;; the page's own buttons, pressed in Scheme
(on-preview-link! "amazon-cart" (lambda (asin) (amazon-cart-add! asin)))
(on-preview-link! "amazon-open" (lambda (asin) (amazon-open-external! asin)))
(on-preview-link! "amazon-save" (lambda (asin) (amazon-save-toggle! asin)))
(on-preview-link! "amazon-note" (lambda (asin) (amazon-ask-note! asin)))

;;; --- actions, on the listing and on the page -----------------------------
;;; The same verb under the same key in both places: the listing reads the
;;; row at point, the page keeps its own.

(define (amazon-row-here)
  (or (buffer-local (current-buffer) 'amazon-row)
      (list-current *amazon-buffer*)))

(define-command "amazon-detail" "Show the product on this row beside the listing"
  (lambda () (amazon-show-detail! (amazon-row-here))))

(define-command "amazon-cart" "Add this product to the Amazon cart"
  (lambda () (let ((r (amazon-row-here))) (when r (amazon-cart-add! (plist-get r 'asin))))))

(define-command "amazon-open" "Open this product's page in the real browser"
  (lambda () (let ((r (amazon-row-here))) (when r (amazon-open-external! (plist-get r 'asin))))))

(define-command "amazon-copy-link" "Copy this product's link"
  (lambda ()
    (let ((r (amazon-row-here)))
      (when r (let ((u (amazon-product-url (plist-get r 'asin))))
                (kill-new u) (message (string-append "Copied " u)))))))

;; a note is one line you write about the product; an empty answer clears it
(define (amazon-ask-note! asin)
  (read-string (string-append "Note on " (amz-clip (amazon-name-of asin) 34) ": ")
               (lambda (text)
                 (amazon-note-set! asin text)
                 (message (if (or (not (string? text)) (equal? text ""))
                              "Note cleared"
                              "Noted")))))

(define-command "amazon-save" "Save this product, marking it in the listing"
  (lambda ()
    (let ((r (amazon-row-here)))
      (when r
        (let ((asin (plist-get r 'asin)))
          (message (string-append (amz-clip (amazon-name-of asin) 34)
                                  (if (amazon-save-toggle! asin) " saved" " no longer saved"))))))))

(define-command "amazon-note" "Write a note on this product"
  (lambda ()
    (let ((r (amazon-row-here)))
      (when r (amazon-ask-note! (plist-get r 'asin))))))

(define-command "amazon-sort-delivery" "Order the listing by soonest delivery, or back to Amazon's order"
  (lambda ()
    (let ((on (not (equal? (buffer-local *amazon-buffer* 'amazon-sort) 'delivery))))
      (buffer-set-local! *amazon-buffer* 'amazon-sort (if on 'delivery 'relevance))
      (list-refresh! *amazon-buffer*)
      (message (if on "Soonest delivery first" "Amazon's order")))))

(define-command "amazon-hide" "Take this product out of the listing"
  (lambda ()
    (let ((r (amazon-row-here)))
      (when r
        (let ((asin (plist-get r 'asin)))
          (message (string-append (amz-clip (amazon-name-of asin) 34)
                                  (if (amazon-hide-toggle! asin) " hidden" " back in the listing"))))))))

(define-command "amazon-hidden" "Show the hidden products too, or put them away"
  (lambda ()
    (let ((on (not (amazon-showing-hidden?))))
      (buffer-set-local! *amazon-buffer* 'amazon-show-hidden on)
      (list-refresh! *amazon-buffer*)
      (message (if on
                   (string-append (number->string (length (amazon-hidden-list))) " hidden, shown")
                   "Hidden products put away")))))

;;; --- the listing ---------------------------------------------------------

(define (amazon--cells buf row)
  (let ((asin (plist-get row 'asin)))
    (list (string-append (if (amazon-hidden? asin) "⊘" " ")
                         (if (amazon-saved? asin) "★" " ")
                         (if (amazon-note asin) "✎" " ")
                         (if (amazon-in-cart? asin) "✓" " "))
          (amz-clip (plist-get row 'title) 52)
          (or (plist-get row 'biz) "—")
          (list (or (plist-get row 'incl) "") "dim")
          (list (or (plist-get row 'rating) "") "dim")
          (list (amz-delivery-label (plist-get row 'delivery)) "dim")
          (list asin "dim"))))

(define-list-mode! "amazon-mode"
  (list 'doc "Amazon Business search results, as the account sees them: the price is yours, excluding GST, with the retail price beside it. The delivery column is the day it lands, and d orders the listing by the soonest. Moving shows that product as a page beside the listing, and C-` there flips through the pages you have opened. RET shows it again, m saves it and marks the row, n writes a note on it, x takes it out of the listing and X shows the hidden ones again marked ⊘, c adds it to the cart, o opens it in the real browser, w copies its link, s runs another search, g searches again, q quits."
        'buffer *amazon-buffer*
        'transient #f
        'noun "product"
        'rows (lambda (buf)
                (let* ((all (or (buffer-local buf 'amazon-rows) '()))
                       (rows (if (amazon-showing-hidden?)
                                 all
                                 (filter (lambda (r) (not (amazon-hidden? (plist-get r 'asin)))) all))))
                  (if (equal? (buffer-local buf 'amazon-sort) 'delivery)
                      (amz-sort-by-delivery rows)
                      rows)))
        'key (lambda (buf row) (plist-get row 'asin))
        'columns (lambda (buf)
                   (list (list "" 4) (list "product" 52) (list "₹" 10)
                         (list "with gst" 9) (list "rating" 7)
                         (list "delivery" 9) (list "asin" 12)))
        'cells amazon--cells
        'title (lambda (buf) (or (buffer-local buf 'amazon-query) "Amazon"))
        'meta (lambda (buf)
                (string-append amazon-host " · business price, excluding GST"
                               (if (equal? (buffer-local buf 'amazon-sort) 'delivery)
                                   " · soonest delivery first"
                                   "")
                               (let ((n (length (amazon-hidden-list))))
                                 (cond ((= n 0) "")
                                       ((amazon-showing-hidden?)
                                        (string-append " · showing " (number->string n) " hidden"))
                                       (else (string-append " · " (number->string n) " hidden"))))))
        'total (lambda (buf)
                 (let ((all (or (buffer-local buf 'amazon-rows) '())))
                   (if (amazon-showing-hidden?)
                       (length all)
                       (length (filter (lambda (r) (not (amazon-hidden? (plist-get r 'asin)))) all)))))
        'footer (lambda (buf) (list (list "RET" "page") (list "m" "save") (list "n" "note")
                                    (list "x" "hide")
                                    (list "X" (if (amazon-showing-hidden?) "hide hidden" "show hidden"))
                                    (list "d" "by delivery") (list "c" "cart")
                                    (list "o" "browser") (list "s" "search") (list "q" "quit")))
        'preview (lambda (buf row) (amazon-show-detail! row))
        'keys (list (list "RET" "amazon-detail")
                    (list "m" "amazon-save")
                    (list "n" "amazon-note")
                    (list "x" "amazon-hide")
                    (list "X" "amazon-hidden")
                    (list "d" "amazon-sort-delivery")
                    (list "c" "amazon-cart")
                    (list "o" "amazon-open")
                    (list "w" "amazon-copy-link")
                    (list "s" "amazon-search")
                    (list "g" "amazon-refresh")
                    (list "q" "quit-window"))))

;;; --- the page's mode -----------------------------------------------------
;;; detail-mode arrives with the buffer (display-buffer-detail!) and brings
;;; C-`, C-M-` and M-RET. This mode adds the app's own verbs, so the page
;;; answers the same keys as the row it came from.

(define-mode "amazon-detail-mode"
  (lambda () (buffer-set-read-only! (current-buffer) #t)))
(mode-parent! "amazon-detail-mode" "special-mode")
(mode-doc! "amazon-detail-mode"
  "One product, as its own page. m saves it and marks it in the listing, n writes a note that stays on this page, c adds it to the cart, o opens it in the real browser, w copies its link, g reads the listing again, q puts it away. C-` walks the other pages opened from this listing, C-M-` walks back, and M-RET keeps this one so the next row opens a fresh page.")
(mode-keys! "amazon-detail-mode"
  (list (list "c" "amazon-cart")
        (list "m" "amazon-save")
        (list "n" "amazon-note")
        (list "o" "amazon-open")
        (list "w" "amazon-copy-link")
        (list "g" "amazon-refresh")
        (list "q" "quit-window")))

;; a kept page takes the product's name, not a number
(detail-name! "amazon-detail-mode"
  (lambda (buf) (string-append "*" (or (buffer-local buf 'amazon-title) "amazon") "*")))

;;; --- the layout ----------------------------------------------------------
;;; Three panes -- the group's chat, the listing, the page -- handed to the
;;; responsive tiler, which makes them three columns on a wide frame and
;;; stacks them on a narrow one. No split here decides a width.

(define (amazon-current-detail)
  (let ((row (list-current *amazon-buffer*)))
    (and row (amazon-detail-buffer row))))

(define (amazon-layout!)
  (let* ((id (amazon-home-group!))
         (chat (and id (boundp 'group-chat) (group-chat id)))
         (panes (filter (lambda (b) (and b (buffer-exists? b)))
                        (list chat *amazon-buffer* (amazon-current-detail)))))
    ;; the app is always chat | listing | detail, side by side, whatever
    ;; the frame width -- adaptive tiling stacked them on a narrow frame
    (when (pair? (cdr panes)) (tile-windows! 'columns panes))
    panes))

;;; --- opening it ----------------------------------------------------------

(define (amazon-open! query)
  (unless (buffer-exists? *amazon-buffer*) (buffer-create *amazon-buffer*))
  (amazon-join-group! *amazon-buffer*)
  (buffer-set-local! *amazon-buffer* 'amazon-query query)
  (message (string-append "Amazon: " query "..."))
  (amazon-fetch! query
    (lambda (rows)
      (if (not rows)
          (message "Amazon did not answer -- try again")
          (begin
            (buffer-set-local! *amazon-buffer* 'amazon-rows rows)
            (unless (buffer-derived-mode? *amazon-buffer* "amazon-mode")
              (with-current-buffer *amazon-buffer* (lambda () (set-mode! "amazon-mode"))))
            (list-refresh! *amazon-buffer*)
            (switch-to-buffer! *amazon-buffer*)
            (amazon-show-detail! (list-current *amazon-buffer*))
            (amazon-layout!)
            (let ((id (amazon-home-group!))) (when id (group-layout-save! id)))
            (message (string-append (number->string (length rows))
                                    " results for " query)))))))

(define-command "amazon" "Open the Amazon app"
  (lambda ()
    (amazon-enter-group!)
    (amazon-open! (or (buffer-local *amazon-buffer* 'amazon-query) amazon-default-query))))

(define-command "amazon-search" "Search Amazon and fill the listing"
  (lambda ()
    (read-string "Amazon: "
                 (lambda (q)
                   (when (and (string? q) (not (equal? q "")))
                     (amazon-enter-group!)
                     (amazon-open! q))))))

(define-command "amazon-refresh" "Read the search again"
  (lambda ()
    (amazon-open! (or (buffer-local *amazon-buffer* 'amazon-query) amazon-default-query))))

;;; --- the catalog ---------------------------------------------------------

(public! 'amazon-open!
  "(amazon-open! QUERY) — search the storefront and fill the listing, in the app's own group")
(public! 'amazon-cart-add!
  "(amazon-cart-add! ASIN) — add one of a product to the signed-in cart, through the reader's browser tab")
(public! 'amazon-show-detail!
  "(amazon-show-detail! ROW) — render ROW as its own page beside the listing")
(public! 'amz-parse
  "(amz-parse TEXT) — the search page the reader read, as product rows")

(public! 'amz-delivery-key
  "(amz-delivery-key TEXT) — the day a delivery line names, as YYYYMMDD; 99999999 when it names none")

(public! 'amazon-save-toggle!
  "(amazon-save-toggle! ASIN) — save or unsave a product; a saved one is marked ★ in the listing")

(public! 'amazon-note-set!
  "(amazon-note-set! ASIN TEXT) — write the note shown on the product's page; \"\" clears it")

(public! 'amazon-hide-toggle!
  "(amazon-hide-toggle! ASIN) — take a product out of the listing, or put it back; a hidden one is marked ⊘ when X shows them")

(catalog-meta! 'function "amazon-open!" 'domain 'web 'effects '(read write external display))
(catalog-meta! 'function "amazon-cart-add!" 'domain 'web 'effects '(write external))
(catalog-meta! 'function "amazon-show-detail!" 'domain 'web 'effects '(write display))
(catalog-meta! 'function "amz-parse" 'domain 'web 'effects '(pure))
(catalog-meta! 'function "amz-delivery-key" 'domain 'web 'effects '(read))
(catalog-meta! 'function "amazon-save-toggle!" 'domain 'web 'effects '(write))
(catalog-meta! 'function "amazon-note-set!" 'domain 'web 'effects '(write))
(catalog-meta! 'function "amazon-hide-toggle!" 'domain 'web 'effects '(write))
