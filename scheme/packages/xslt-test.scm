;;; xslt-test.scm --- packages/xslt.scm: the site parser the editor writes.
;;;
;;; The learn itself asks a model and fetches a page, so it is not tested
;;; here. What is tested is everything the learn decides with: which class
;;; token earns a rule, which pattern a row gets, which drops survive, and
;;; how web.scm finds a sheet a learn left on disk.

(domain! 'testing)
(effects! '(pure))

(deftest 'a-class-token-earns-a-rule-only-when-it-is-a-word
  "a generated class name is dead the next time the site ships"
  (lambda ()
    (check-true! (xslt--word? "content-footer") "a name a person chose")
    (check-true! (xslt--word? "ad-slot") "another")
    (check-false! (xslt--word? "dcr-1uu0ds5") "the Guardian's compiler")
    (check-false! (xslt--word? "sc-bdVaJa") "styled-components")
    (check-false! (xslt--word? "css-1x2y3z") "emotion")
    (check-false! (xslt--word? "Header_nav__2x9Kd") "CSS modules")
    (check-false! (xslt--word? "") "nothing is not a word")))

(deftest 'a-position-is-trusted-at-the-top-of-the-document-only
  "a direct child of body keeps its place; deeper down a position is one fetch"
  (lambda ()
    (check-true! (xslt--shallow-path? "/html[1]/body[1]/footer[1]") "the footer")
    (check-true! (xslt--shallow-path? "/html[1]/body[1]/a[2]") "a skip link")
    (check-false! (xslt--shallow-path? "/html[1]/body[1]/div[3]/div[2]/span[1]")
                  "five steps in is the shape of one fetch")))

(deftest 'a-row-is-addressed-by-its-name-before-its-place
  "id, then a word class token, then aria-label, then a lone semantic tag"
  (lambda ()
    (check-equal! (xslt-pattern (list 'tag "div" 'id "sign-in-gate" 'aria ""
                                        'toks '() 'tags 400 'path "/html[1]/body[1]/div[9]"))
                  "div[@id='sign-in-gate']" "an id wins")
    (check-equal! (xslt-pattern (list 'tag "div" 'id "" 'aria ""
                                        'toks '(("ad-slot" 4)) 'tags 400 'path "/x"))
                  "div[contains(concat(' ', normalize-space(@class), ' '), ' ad-slot ')]"
                  "a word token is next")
    (check-equal! (xslt-pattern (list 'tag "div" 'id "" 'aria "Cookie banner"
                                        'toks '(("dcr-1uu0ds5" 4)) 'tags 400 'path "/x"))
                  "div[@aria-label='Cookie banner']"
                  "a generated token is no token, so the label answers")
    (check-equal! (xslt-pattern (list 'tag "footer" 'id "" 'aria ""
                                        'toks '() 'tags 1 'path "/html[1]/body[1]/footer[1]"))
                  "footer" "the only footer on the page is named by its tag")
    (check-equal! (xslt-pattern (list 'tag "footer" 'id "" 'aria ""
                                        'toks '() 'tags 149 'path "/html[1]/body[1]/footer[1]"))
                  "/html[1]/body[1]/footer[1]"
                  "one footer of 149 is named by its place")))

(deftest 'a-drop-is-kept-once-and-never-from-deep-inside-one-fetch
  "the sheet takes each rule once, and refuses a deep position"
  (lambda ()
    (let* ((named (list 'tag "div" 'id "sign-in-gate" 'aria "" 'toks '() 'tags 400
                          'path "/html[1]/body[1]/div[9]" 'len 0 'd 1))
           (deep (list 'tag "span" 'id "" 'aria "" 'toks '() 'tags 900
                         'path "/html[1]/body[1]/div[3]/div[2]/span[1]" 'len 0 'd 3))
           (shallow (list 'tag "footer" 'id "" 'aria "" 'toks '() 'tags 149
                            'path "/html[1]/body[1]/footer[1]" 'len 0 'd 1))
           (rows (list named deep shallow))
           (kept (xslt--keep-drops rows (list named deep shallow named) '())))
      (check-equal! (length kept) 2 "the deep one is refused and the repeat is dropped")
      (check-true! (assoc "div[@id='sign-in-gate']" kept) "the named one")
      (check-true! (assoc "/html[1]/body[1]/footer[1]" kept) "the shallow one"))))

(deftest 'a-sheet-on-disk-is-how-a-learned-site-registers
  "web--host-parser finds HOST.xsl with no line in the site list"
  (lambda ()
    (check-equal! (web--parser-host "https://www.news18.com/india/x.html") "news18.com"
                  "www and the apex are one site")
    (check-equal! (web--parser-host "https://news18.com/") "news18.com" "either way in")
    (check-equal! (web--site-parser "https://www.news18.com/india/x.html") "news18.com.xsl"
                  "the file answers for a site the list never named")
    (check-false! (web--host-parser "https://nothing-here.example/")
                  "a site with no sheet has no parser")))

(deftest 'the-stylesheet-carries-one-template-per-drop
  "each rule is an empty template, and its note is the comment above it"
  (lambda ()
    (let ((sheet (xslt-stylesheet "//body"
                                  '(("div[@id='sign-in-gate']" "div #sign-in-gate, p=0.81")
                                    ("footer" "footer, p=0.93")))))
      (check-contains! sheet "<xsl:apply-templates select=\"//body\" mode=\"copy\"/>" "the keep")
      (check-contains! sheet "<xsl:template match=\"div[@id='sign-in-gate']\" mode=\"copy\"/>"
                       "the first rule")
      (check-contains! sheet "<xsl:template match=\"footer\" mode=\"copy\"/>" "the second")
      (check-contains! sheet "div #sign-in-gate, p=0.81" "the note says why"))))

;;; --- the fan-out --------------------------------------------------------------
;;; Every level goes in one call, so which boxes a deeper level reaches is
;;; settled by the walk and not by an answer. These check the three pieces
;;; that decide it: which levels are asked, which answers are thrown away,
;;; and which furniture verdict a deeper answer overrules.

(deftest 'a-deeper-level-is-chosen-before-a-single-question
  "the walk holds the whole tree, so the questions about a box inside
another box are asked beside it and not after it"
  (lambda ()
    (let* ((head (list 'path "/html[1]/body[1]/header[1]" 'd 0 'len 300 'a 2))
           (main (list 'path "/html[1]/body[1]/div[1]" 'd 0 'len 5000 'a 9))
           (art (list 'path "/html[1]/body[1]/div[1]/div[1]" 'd 1 'len 4500 'a 4))
           (rail (list 'path "/html[1]/body[1]/div[1]/aside[1]" 'd 1 'len 500 'a 3))
           (nav (list 'path "/html[1]/body[1]/header[1]/nav[1]" 'd 1 'len 300 'a 2))
           (levels (xslt--levels (list head main art rail nav))))
      (check-equal! (length levels) 2 "two levels, one call")
      (check-equal! (map (lambda (r) (plist-get r 'path)) (car levels))
                    (list "/html[1]/body[1]/div[1]" "/html[1]/body[1]/header[1]")
                    "the largest box goes first")
      (check-equal! (map (lambda (r) (plist-get r 'path)) (cadr levels))
                    (list "/html[1]/body[1]/div[1]/div[1]"
                          "/html[1]/body[1]/div[1]/aside[1]")
                    "asked inside the big box, with no verdict on it yet")
      (check-equal! (map (lambda (r) (plist-get r 'path))
                         (cadr (xslt--levels
                                 (list main art rail nav
                                       (list 'path "/html[1]/body[1]/header[1]"
                                             'd 0 'len 300 'a 40)))))
                    (list "/html[1]/body[1]/div[1]/div[1]"
                          "/html[1]/body[1]/div[1]/aside[1]"
                          "/html[1]/body[1]/header[1]/nav[1]")
                    "forty links in 300 characters is a menu, so the walk goes into it")
      (check-equal! (map length (xslt--regroup (append (car levels) (cadr levels))
                                               (list 2 2)))
                    (list 2 2) "one flat answer list splits back into its levels"))))

(deftest 'an-answer-is-read-inside-the-box-it-was-asked-in
  "a speculative answer counts only when the box above it was content, and a
path step is a step and not a spelling"
  (lambda ()
    (let ((box (list 'path "/html[1]/body[1]/div[1]"))
          (kid (list 'path "/html[1]/body[1]/div[1]/aside[1]"))
          (cousin (list 'path "/html[1]/body[1]/div[10]/aside[1]"))
          (other (list 'path "/html[1]/body[1]/header[1]")))
      (check-true! (xslt--under? box kid) "its own child")
      (check-false! (xslt--under? box cousin) "div[10] is not inside div[1]")
      (check-false! (xslt--under? box other) "a sibling is not inside it")
      (check-false! (xslt--under? box box) "a box is not inside itself"))))

(deftest 'a-wrapper-around-the-article-is-not-furniture
  "a box whose text is mostly one part the model called content is a wrapper,
and deleting it deletes the page"
  (lambda ()
    (let* ((wrap (list 'path "/html[1]/body[1]/div[1]" 'len 5000 'p 0.8))
           (article (list 'path "/html[1]/body[1]/div[1]/div[1]" 'len 4500 'p 0.2))
           (blurb (list 'path "/html[1]/body[1]/div[1]/p[1]" 'len 450 'p 0.2))
           (unsure (list 'path "/html[1]/body[1]/div[1]/div[1]" 'len 4500 'p 0.5))
           (cut 0.7))
      (check-true! (xslt--vetoed? wrap (list article) cut)
                   "the part is most of the whole, so the whole is a wrapper")
      (check-false! (xslt--vetoed? wrap (list blurb) cut)
                    "a tenth of the text does not stand for the box")
      (check-false! (xslt--vetoed? wrap (list unsure) cut)
                    "only a clear content verdict overrules a furniture one")
      (check-false! (xslt--vetoed? wrap '() cut)
                    "nothing asked below it is no second opinion"))))

(deftest 'the-box-that-holds-the-page-title-is-not-furniture
  "Wikipedia hangs its language menu in the same header as the h1, so the
rule that takes the menu would take the title too"
  (lambda ()
    (let* ((title (list 'path "/html[1]/body[1]/main[1]/header[1]/h1[1]" 'tag "h1"))
           (bar (list 'path "/html[1]/body[1]/main[1]/header[1]" 'tag "header"))
           (rail (list 'path "/html[1]/body[1]/aside[1]" 'tag "aside"))
           (rows (list title bar rail)))
      (check-true! (xslt--holds-the-title? rows bar)
                   "the header around the only h1 stays, and a rule inside it takes the menu")
      (check-false! (xslt--holds-the-title? rows rail) "a rail holds no title")
      (check-false! (xslt--holds-the-title? (list bar rail) bar)
                    "a page with no h1 has no title to lose")
      (check-false! (xslt--holds-the-title?
                      (list title (list 'path "/html[1]/body[1]/div[2]/h1[1]" 'tag "h1") bar)
                      bar)
                    "two h1s name sections, not the page"))))
