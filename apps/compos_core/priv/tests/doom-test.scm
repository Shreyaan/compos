;;; doom-test.scm --- where DOOM lives, what it needs, and how it opens.
;;;
;;; The engine is a WebAssembly build and the IWAD is four megabytes, so
;;; no test here fetches anything. Every test points doom-home at a
;;; temporary directory and writes stand-in files, which is enough to
;;; check what the package decides: which assets are missing, when the
;;; game counts as installed, that the page follows the package, and
;;; that opening the game leaves the buffer in app render-mode.

(domain! 'testing)
(effects! '(write))

(define *doom-test-home* "/tmp/compos-doom-test")

(define (doom-test-reset!)
  (shell-command->string
    (string-append "rm -rf " (doom--sh-quote *doom-test-home*)
                   " && mkdir -p " (doom--sh-quote *doom-test-home*)))
  (set! doom-home *doom-test-home*))

(define (doom-test-done!)
  (let ((page (doom--file "doom.html")))
    (when (buffer-exists? page) (buffer-kill! page)))
  (shell-command->string (string-append "rm -rf " (doom--sh-quote *doom-test-home*)))
  (set! doom-home ""))

;; stand-ins: the package asks whether a file is there, never what is in it
(define (doom-test-write-assets!)
  (for-each (lambda (f) (write-file! (doom--file f) "stand-in"))
            *doom-assets*))

;;; --- where the files live -----------------------------------------------------

(deftest 'doom-home-names-the-directory-and-an-empty-one-means-the-config-home
  "the custom decides the directory, and its default follows the config home"
  (lambda ()
    (set! doom-home "/tmp/zz-doom-elsewhere")
    (check-equal! (doom--dir) "/tmp/zz-doom-elsewhere"
                  "a set doom-home is the directory")
    (check-equal! (doom--file "doom1.wad") "/tmp/zz-doom-elsewhere/doom1.wad"
                  "and every file hangs off it")
    (set! doom-home "")
    (check-equal! (doom--dir) (string-append (compos-config-dir) "/apps/doom")
                  "an empty doom-home means apps/doom under the config home")))

;;; --- the install --------------------------------------------------------------

(deftest 'an-empty-directory-is-missing-every-asset
  "nothing installed means the engine, the IWAD and the config are all named"
  (lambda ()
    (doom-test-reset!)
    (check-equal! (length (doom--missing)) (length *doom-assets*)
                  "every asset is missing")
    (check-false! (doom--installed?) "so the game is not installed")
    (doom-test-done!)))

(deftest 'the-install-writes-the-page-and-asks-only-for-what-is-absent
  "with the assets in place the install writes the page and fetches nothing"
  (lambda ()
    (doom-test-reset!)
    (doom-test-write-assets!)
    (check-equal! (doom--missing) '() "no asset is missing now")
    (check-false! (doom--installed?) "but the page is not written yet")
    (let ((answer 'pending))
      (doom--install! (lambda (ok) (set! answer ok)))
      (check-equal! answer #t "the install finished without a fetch")
      (check-true! (file-exists? (doom--file "doom.html")) "and wrote the page")
      (check-true! (doom--installed?) "so the game counts as installed"))
    (doom-test-done!)))

(deftest 'a-stale-page-is-put-back
  "the package owns the page: an edited one is replaced before the app runs"
  (lambda ()
    (doom-test-reset!)
    (doom-test-write-assets!)
    (write-file! (doom--file "doom.html") "<html>an older page</html>")
    (doom--sync-page!)
    (check-equal! (read-file (doom--file "doom.html")) *doom-page*
                  "the page on disk is the page the package holds")
    (doom-test-done!)))

;;; --- the page -------------------------------------------------------------------

(deftest 'the-page-loads-the-engine-and-preloads-the-iwad
  "the app document names every file the app origin has to serve"
  (lambda ()
    (check-true! (string-contains? *doom-page* "websockets-doom.js")
                 "it loads the engine glue")
    (check-true! (string-contains? *doom-page* "doom1.wad")
                 "it preloads the IWAD")
    (check-true! (string-contains? *doom-page* "default.cfg")
                 "and the engine config")
    (check-true! (string-contains? *doom-page* "callMain")
                 "and it starts the engine itself, because the build does not")
    (for-each (lambda (f)
                (check-true! (string-contains? *doom-page* f)
                             (string-append "the page or its assets name " f)))
              '("doom1.wad" "default.cfg" "websockets-doom.js"))))

;;; --- opening the game -----------------------------------------------------------

(deftest 'opening-the-game-puts-the-page-buffer-in-app-render-mode
  "the buffer that visits the page runs as an app, and a reopen reloads it"
  (lambda ()
    (doom-test-reset!)
    (doom-test-write-assets!)
    (let ((answer 'pending))
      (doom--install! (lambda (ok) (set! answer ok)))
      (check-equal! answer #t "the install is done"))
    (doom--open!)
    (let ((page (doom--file "doom.html")))
      (check-true! (buffer-exists? page) "the page has a buffer")
      (check-equal! (buffer-local page 'render-mode) "app"
                    "and the buffer runs as an app")
      (let ((gen (buffer-local page 'app-generation)))
        (check-true! (and (number? gen) (> gen 0)) "the app has a generation")
        (doom--open!)
        (check-true! (> (buffer-local page 'app-generation) gen)
                     "and opening it again reloads the app")))
    (doom-test-done!)))

(deftest 'the-command-installs-before-it-opens
  "M-x doom on a directory that already holds the assets writes the page and opens it"
  (lambda ()
    (doom-test-reset!)
    (doom-test-write-assets!)
    (check-false! (doom--installed?) "the page is not there yet")
    (run-command "doom")
    (check-true! (wait-until (lambda () (doom--installed?)) 5000 50)
                 "the command wrote the page")
    (let ((page (doom--file "doom.html")))
      (check-true! (wait-until (lambda () (equal? (buffer-local page 'render-mode) "app"))
                               5000 50)
                   "and left the buffer running as an app"))
    (doom-test-done!)))
