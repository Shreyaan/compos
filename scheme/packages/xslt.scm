;;; xslt.scm --- a site parser the editor writes for itself.
;;;
;;; browse-mode reads a page through a stylesheet when the site has one, and
;;; through Readability when it does not. A hand-written stylesheet is better
;;; and costs an afternoon. This package writes one.
;;;
;;; Three steps, and each one is a stylesheet or a question:
;;;
;;;   DISCOVER  web/discover.xsl walks the page and answers a table: one row
;;;             per structural element, with its text volume, link density,
;;;             class tokens and how to address it.
;;;   JUDGE     JEV scores each row. Is this navigation, a masthead, an ad
;;;             slot, an upsell, a consent notice -- or the content?
;;;   EMIT      each flagged row becomes an empty template. The sheet copies
;;;             the document and deletes those nodes.
;;;
;;; The walk is top down. Ask about body's children first, then descend only
;;; into what survives. A page's chrome sits near the top, so a page costs
;;; two or three JEV calls, not one per node.
;;;
;;; Discovery and the finished parser run in the same engine, so a pattern
;;; that selects a node during discovery selects it in production.
;;;
;;; xslt-score asks JEV, so that step needs the jev package loaded. Every
;;; other step is a stylesheet or string work.
;;;
;;; The sheet is also the cache. JEV judges a site once; every later visit
;;; reads web/parsers/HOST.xsl and spends nothing.

(domain! 'web)
(effects! '(read external execute))

(defcustom 'xslt-discover-depth 3
  "How many levels below body discovery reports."
  'group 'web 'type 'integer)

(defcustom 'xslt-chrome-threshold 0.5
  "How sure JEV must be before a rule deletes the element."
  'group 'web 'type 'float)

(defcustom 'xslt-token-max 40
  "A class token on more elements than this is a layout utility, not a name. Below it, a shared token is a rule for the whole family: news18 carries one token on fourteen ad slots, and one line deletes all of them. Each rule's note says how many elements it reaches, so a sheet that deletes too much says so before anyone saves it."
  'group 'web 'type 'integer)

(defcustom 'xslt-content-min 400
  "The walk descends only into a kept element with this many characters."
  'group 'web 'type 'integer)

(defcustom 'xslt-level-max 24
  "How many elements one JEV call judges. The largest go first."
  'group 'web 'type 'integer)

;;; --- the table ----------------------------------------------------------------
;;; discover.xsl answers text, so everything in this section is string work.
;;; It runs without a browser, a network or an API key.

(domain! 'web)
(effects! '(pure))

(define *xslt-fields*
  '(path d tag id cls role aria len a img tags toks sample))

(define (xslt--num s)
  (let ((n (string->number (or s "0"))))
    (if (number? n) n 0)))

;; ascending by KEY, a number. A level holds tens of rows, not thousands.
(define (xslt--insert x acc key)
  (cond ((null? acc) (list x))
        ((<= (key x) (key (car acc))) (cons x acc))
        (else (cons (car acc) (xslt--insert x (cdr acc) key)))))

(define (xslt--sort-by rows key)
  (let loop ((rs rows) (acc '()))
    (if (null? rs) acc (loop (cdr rs) (xslt--insert (car rs) acc key)))))

;; "tok:4 other:1" becomes (("tok" 4) ("other" 1))
(define (xslt--toks s)
  (let loop ((parts (string-split (or s "") " ")) (acc '()))
    (if (null? parts)
        (reverse acc)
        (let* ((p (car parts))
               (cut (string-index p ":")))
          (loop (cdr parts)
                (if cut
                    (cons (list (substring p 0 cut)
                                (xslt--num (substring p (+ cut 1) (string-length p))))
                          acc)
                    acc))))))

(define (xslt--row line)
  (let loop ((fs *xslt-fields*) (vs (string-split line "|")) (acc '()))
    (if (null? fs)
        (reverse acc)
        (let ((v (if (null? vs) "" (car vs))))
          (loop (cdr fs)
                (if (null? vs) '() (cdr vs))
                (cons (cond ((member (car fs) '(d len a img tags)) (xslt--num v))
                            ((equal? (car fs) 'toks) (xslt--toks v))
                            (else v))
                      (cons (car fs) acc)))))))

;; a row has every field. xsltproc writes its errors to the same stream, and
;; an error line holds no separators, so it never becomes a row.
(define (xslt-rows text)
  (filter (lambda (r) (not (equal? (plist-get r 'path) "")))
          (map xslt--row
               (filter (lambda (l)
                         (= (length (string-split l "|")) (length *xslt-fields*)))
                       (string-split (or text "") "\n")))))

;; the rows one level below PARENT, largest first. PARENT #f means body.
(define (xslt-children rows parent)
  (let* ((d (if parent (+ 1 (plist-get parent 'd)) 0))
         (under (if parent (string-append (plist-get parent 'path) "/") ""))
         (kids (filter (lambda (r)
                         (and (= (plist-get r 'd) d)
                              (or (not parent)
                                  (string-prefix? under (plist-get r 'path)))))
                       rows)))
    (xslt--sort-by kids (lambda (r) (- 0 (plist-get r 'len))))))

;;; --- a match pattern ----------------------------------------------------------
;;; A rule has to address the node in libxml2's parse of the raw bytes. An id
;;; or a rare class token does that. A positional path is the last resort: a
;;; page that changes moves every position.

;; XPath 1.0 has no escape inside a string literal, so a value that holds a
;; quote is not addressable this way.
(define (xslt--plain? s)
  (and (string? s)
       (not (equal? s ""))
       (not (re-match? "['\"<>&]" s))))

;; class is a token list, so the rule tests the token. Without this, 'ad'
;; matches 'header-loaded'.
(define (xslt--class-test tok)
  (string-append "contains(concat(' ', normalize-space(@class), ' '), ' " tok " ')"))

;; the rarest addressable token; the longest name breaks a tie
(define (xslt--token row)
  (let ((ok (filter (lambda (t)
                      (and (<= (cadr t) xslt-token-max) (xslt--plain? (car t))))
                    (plist-get row 'toks))))
    (if (null? ok)
        #f
        (car (car (xslt--sort-by
                    ok
                    (lambda (t) (- (* 1000 (cadr t)) (string-length (car t))))))))))

(define *xslt-semantic* '("nav" "header" "footer" "aside" "main" "form" "dialog"))

(define (xslt-pattern row)
  (let ((tag (plist-get row 'tag))
        (id (plist-get row 'id))
        (aria (plist-get row 'aria))
        (tok (xslt--token row)))
    (cond ((xslt--plain? id) (string-append tag "[@id='" id "']"))
          (tok (string-append tag "[" (xslt--class-test tok) "]"))
          ((xslt--plain? aria) (string-append tag "[@aria-label='" aria "']"))
          ((and (= (plist-get row 'tags) 1) (member tag *xslt-semantic*)) tag)
          (else (plist-get row 'path)))))

;;; --- the sheet ----------------------------------------------------------------
;;; Copy everything, then delete. The identity template is the whole reason
;;; this is cheap: a new rule is one line and affects nothing else.

(define (xslt--comment s)
  (string-replace (or s "") "--" "-"))

;; Framework markup wraps the part that has a name in parts that have none.
;; news18 puts its footer inside a bare div, and its ad slots two bare divs
;; deep. Dropping the wrapper needs a positional path, which the next deploy
;; moves; dropping the named descendant needs one token. The wrapper survives
;; empty, and an empty div reads as nothing.
(define (xslt--positional? row)
  (string-prefix? "/" (xslt-pattern row)))

;; a part small enough to stand for the whole is not the whole
(define (xslt--stands-for? row kid)
  (let ((len (plist-get row 'len)))
    (or (= len 0) (>= (* 10 (plist-get kid 'len)) (* 9 len)))))

;; ROW itself when it has a name, else the named part inside it. news18 puts
;; its ad slots two bare divs deep, so the search goes two levels.
(define (xslt--target rows row depth)
  (if (or (not (xslt--positional? row)) (>= depth 2))
      row
      (let loop ((kids (filter (lambda (k) (xslt--stands-for? row k))
                               (xslt-children rows row))))
        (if (null? kids)
            row
            (let ((t (xslt--target rows (car kids) (+ depth 1))))
              (if (xslt--positional? t) (loop (cdr kids)) t))))))

;; how many elements the rule deletes, when the walk can tell
(define (xslt--reach row)
  (let ((tok (xslt--token row)))
    (if (and tok (not (xslt--plain? (plist-get row 'id))))
        (cadr (car (filter (lambda (t) (equal? (car t) tok))
                           (plist-get row 'toks))))
        1)))

(define (xslt--note row target)
  (string-append
    (plist-get row 'tag)
    (if (equal? (plist-get row 'id) "")
        "" (string-append " #" (plist-get row 'id)))
    (if (equal? (plist-get row 'aria) "")
        "" (string-append " " (plist-get row 'aria)))
    ", " (number->string (plist-get row 'len)) " chars, p="
    (number->string (plist-get row 'p))
    (if (equal? (plist-get target 'path) (plist-get row 'path))
        ""
        (string-append "; named by its " (plist-get target 'tag)))
    (let ((n (xslt--reach target)))
      (if (> n 1)
          (string-append "; deletes " (number->string n) " elements")
          ""))))

(define (xslt--drop rows row)
  (let ((target (xslt--target rows row 0)))
    (list (xslt-pattern target) (xslt--note row target))))

(define (xslt--rule d)
  (string-append "\n  <!-- " (xslt--comment (cadr d)) " -->\n"
                 "  <xsl:template match=\"" (car d) "\" mode=\"copy\"/>\n"))

(define (xslt-stylesheet keep drops)
  (string-append
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<xsl:stylesheet version=\"1.0\" xmlns:xsl=\"http://www.w3.org/1999/XSL/Transform\">\n"
    "  <xsl:output method=\"html\" encoding=\"UTF-8\" omit-xml-declaration=\"yes\"/>\n"
    "  <xsl:strip-space elements=\"*\"/>\n\n"
    "  <xsl:template match=\"/\">\n"
    "    <html><body>\n"
    "      <xsl:apply-templates select=\"" keep "\" mode=\"copy\"/>\n"
    "    </body></html>\n"
    "  </xsl:template>\n\n"
    "  <xsl:template match=\"@*|node()\" mode=\"copy\">\n"
    "    <xsl:copy>\n"
    "      <xsl:apply-templates select=\"@*|node()\" mode=\"copy\"/>\n"
    "    </xsl:copy>\n"
    "  </xsl:template>\n\n"
    ;; the rules every page needs. An inlined icon is never content, and an
    ;; anchor with no text is not a link a reader can follow.
    "  <xsl:template match=\"script|style|noscript\" mode=\"copy\"/>\n"
    "  <xsl:template match=\"svg\" mode=\"copy\"/>\n"
    "  <xsl:template match=\"img[starts-with(@src, 'data:')]\" mode=\"copy\"/>\n"
    "  <xsl:template match=\"a[not(normalize-space(.))]\" mode=\"copy\"/>\n"
    ;; a leaf whose whole text is a separator. The bar sat between an icon
    ;; and a comment count; both went, and the bar stayed.
    "  <xsl:template match=\"*[not(*) and normalize-space(.) = '|']\" mode=\"copy\"/>\n"
    "  <xsl:template match=\"text()[normalize-space(.) = '|']\" mode=\"copy\"/>\n"
    ;; A card wraps its heading in the link. Pandoc holds no block inside a
    ;; link, so it writes an empty one and then the blocks. Put the link
    ;; inside the heading instead: the label is the headline, and RET still
    ;; follows it.
    "  <xsl:template match=\"a[h1|h2|h3|h4|h5|h6]\" mode=\"copy\">\n"
    "    <h2><a href=\"{@href}\">\n"
    "      <xsl:value-of select=\"normalize-space((h1|h2|h3|h4|h5|h6)[1])\"/>\n"
    "    </a></h2>\n"
    "    <xsl:apply-templates mode=\"copy\" select=\"node()[not(self::h1 or self::h2 or self::h3 or self::h4 or self::h5 or self::h6)]\"/>\n"
    "  </xsl:template>\n"
    (apply string-append (map xslt--rule drops))
    "</xsl:stylesheet>\n"))

;;; --- the question -------------------------------------------------------------

(define (xslt-row-text row)
  (string-append
    "<" (plist-get row 'tag)
    " class=\"" (plist-get row 'cls) "\""
    " id=\"" (plist-get row 'id) "\""
    " role=\"" (plist-get row 'role) "\""
    " aria-label=\"" (plist-get row 'aria) "\">"
    "  text-chars=" (number->string (plist-get row 'len))
    " links=" (number->string (plist-get row 'a))
    " images=" (number->string (plist-get row 'img))
    "  text-starts: " (plist-get row 'sample)))

(define *xslt-question*
  (string-append
    "\n\nIs this element page furniture that a reader does not want -- "
    "navigation, masthead, footer, advertising, sponsored promotion, "
    "subscription or premium upsell, cookie or consent notice, social share "
    "widget, fixed overlay, skip link -- rather than the content the reader "
    "came for?"))

(define (xslt--key i)
  (string->symbol (string-append "c" (number->string i))))

(define (xslt-questions rows)
  (let loop ((rs rows) (i 0) (acc '()))
    (if (null? rs)
        (reverse acc)
        (loop (cdr rs) (+ i 1)
              (cons (jev-noul (string-append "Element " (number->string i)
                                             " of the page is:\n"
                                             (xslt-row-text (car rs))
                                             *xslt-question*))
                    (cons (xslt--key i) acc))))))

;;; --- the judgement ------------------------------------------------------------

(domain! 'web)
(effects! '(read external execute spend))

;; every row comes back with 'p: how sure JEV is that it is furniture
(define (xslt-score rows state)
  (let ((reply (jev-systemone state (xslt-questions rows))))
    (let loop ((rs rows) (i 0) (acc '()))
      (if (null? rs)
          (reverse acc)
          (loop (cdr rs) (+ i 1)
                (cons (append (car rs)
                              (list 'p (or (and reply
                                                (jev-answer-noul reply (xslt--key i)))
                                           0)))
                      acc))))))

(define (xslt--state url)
  (string-append
    "The page is " url ". Judge each element by its tag, class, id, role, "
    "aria-label, text volume, link density and opening text. An element with "
    "no text and an ad-serving class or id is an ad slot."))

;; the XSLT processor. web.scm names the same one for the reading pipeline.
(define (xslt--tool) "xsltproc")

;; discovery is one process: the walk stylesheet over the fetched bytes.
;; web.scm already writes the body to a file for its own pipeline.
(define (xslt--discover-command file)
  (string-append (xslt--tool) " --html --stringparam depth "
                 (number->string xslt-discover-depth) " "
                 (sh-quote (locate-library "web/discover.xsl")) " "
                 (sh-quote file)))

(define (xslt-discover html)
  (xslt-rows (shell-command->string (xslt--discover-command (web--write-html! html)))))

;; the sheet for URL, learned from HTML. Answers a plist: the text to save,
;; what it deletes, and what the learning cost.
(define (xslt-learn url html)
  (let ((rows (xslt-discover html))
        (state (xslt--state url)))
    (let loop ((level (xslt-children rows #f)) (drops '()) (calls 0) (asked 0))
      (if (null? level)
          (list 'sheet (xslt-stylesheet "//body" (reverse drops))
                'drops (reverse drops)
                'rows (length rows)
                'calls calls
                'asked asked)
          (let* ((ask (take-n level xslt-level-max))
                 (over (- (length level) (length ask))))
            ;; a bounded level is a bounded reading: say what went unjudged
            (if (> over 0)
                (message (string-append "xslt-learn: " (number->string over)
                                        " smaller elements not judged at this level"))
                #f)
            (let* ((scored (xslt-score ask state))
                   (cut xslt-chrome-threshold)
                   (furniture (filter (lambda (r) (>= (plist-get r 'p) cut)) scored))
                   (content (filter (lambda (r) (< (plist-get r 'p) cut)) scored))
                   (deeper (filter (lambda (r) (>= (plist-get r 'len) xslt-content-min))
                                   content)))
              (loop (apply append (map (lambda (r) (xslt-children rows r)) deeper))
                    (append (reverse (map (lambda (r) (xslt--drop rows r)) furniture))
                            drops)
                    (+ calls 1)
                    (+ asked (length ask)))))))))

;;; --- keeping it ---------------------------------------------------------------

(domain! 'web)
(effects! '(write))

(define (xslt--parsers-dir)
  (let ((p (locate-library "web/parsers/feed.xsl")))
    (substring p 0 (- (string-length p) (string-length "feed.xsl")))))

(define (xslt--host url)
  (let* ((s (string-replace (string-replace url "https://" "") "http://" ""))
         (cut (string-index s "/")))
    (if cut (substring s 0 cut) s)))

;; save SHEET as the parser for URL's site and register it. The next visit
;; reads the page through it and asks JEV nothing.
(define (xslt-save! url sheet)
  (let* ((host (xslt--host url))
         (name (string-append host ".xsl"))
         (path (string-append (xslt--parsers-dir) name)))
    (write-file! path sheet)
    (web-register-site! (string-append "https://" host) name #f)
    path))

;;; --- the catalog --------------------------------------------------------------

(domain! 'web)
(effects! '(read external execute spend))

(public! 'xslt-learn
  "(xslt-learn URL HTML) - learn a site parser: walk the page, ask JEV what is furniture, answer (sheet TEXT drops ((PATTERN NOTE) ...) rows N calls N asked N)")
(public! 'xslt-discover
  "(xslt-discover HTML) - the page's structure as rows: path, depth, tag, id, class, role, aria, chars, links, images, tag count, class tokens, sample")
(public! 'xslt-score
  "(xslt-score ROWS STATE) - every row back with 'p, how sure JEV is that it is page furniture")

(domain! 'web)
(effects! '(pure))

(public! 'xslt-pattern
  "(xslt-pattern ROW) - the XSLT match pattern that addresses ROW: an id, a rare class token, an aria-label, a lone semantic tag, else its position")
(public! 'xslt-stylesheet
  "(xslt-stylesheet KEEP DROPS) - a stylesheet that copies KEEP and deletes each (PATTERN NOTE) in DROPS")
(public! 'xslt-rows
  "(xslt-rows TEXT) - the walk stylesheet's table as plists")
(public! 'xslt-children
  "(xslt-children ROWS PARENT) - the rows one level below PARENT, largest first; PARENT #f means body")
(public! 'xslt-row-text
  "(xslt-row-text ROW) - one row as the line a classifier reads")

(domain! 'web)
(effects! '(write))

(public! 'xslt-save!
  "(xslt-save! URL SHEET) - write SHEET as web/parsers/HOST.xsl and register the site; answers the path")
