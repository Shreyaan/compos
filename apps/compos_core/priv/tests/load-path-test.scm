;;; load-path-test.scm --- (load NAME) searches load-path.

(define t--lp-dir (string-append (compos-home) "/zz-load-path"))

(define (t--lp-make!)
  (shell-command->string (string-append "rm -rf " (sh-quote t--lp-dir)))
  (shell-command->string (string-append "mkdir -p " (sh-quote t--lp-dir)))
  (write-file! (string-append t--lp-dir "/zz-lp-lib.scm")
               (string-append "(define zz-lp-mark 'loaded)\n"
                              "(define zz-lp-package *loading-package*)\n"
                              "(define zz-lp-origin *loading-origin*)\n")))

(define (t--lp-remove!)
  (set! load-path (remove (lambda (d) (equal? d t--lp-dir)) load-path))
  (shell-command->string (string-append "rm -rf " (sh-quote t--lp-dir))))

(deftest 'load-path-default-names-the-editor-trees
  "priv, its packages, the config home and its packages are on load-path"
  (lambda ()
    (check-true! (member (compos-priv-dir) load-path) "priv")
    (check-true! (member (string-append (compos-priv-dir) "/packages") load-path)
                 "the bundled packages")
    (check-true! (member (compos-config-dir) load-path) "the config home")
    (check-true! (member (string-append (compos-config-dir) "/packages") load-path)
                 "the user's packages")))

(deftest 'locate-library-finds-a-bundled-package-by-bare-name
  "a bare name resolves to the package file, with or without .scm"
  (lambda ()
    (let ((advice (string-append (compos-project-dir) "/scheme/packages/advice.scm")))
      (check-equal! (locate-library "advice.scm") advice "with .scm")
      (check-equal! (locate-library "advice") advice "without .scm")
      (check-equal! (locate-library advice) advice "an absolute path is itself")
      (check-false! (locate-library "zz-no-such-library") "a missing name is #f"))))

(deftest 'load-searches-a-directory-added-to-load-path
  "add-to-list! puts the directory first once; load finds the file and stamps it"
  (lambda ()
    (t--lp-make!)
    (add-to-list! 'load-path t--lp-dir)
    (add-to-list! 'load-path t--lp-dir)
    (check-equal! (car load-path) t--lp-dir "the added directory comes first")
    (check-equal! (length (filter (lambda (d) (equal? d t--lp-dir)) load-path)) 1
                  "the directory is added once")
    (let ((pkg *loading-package*)
          (org *loading-origin*))
      (load "zz-lp-lib.scm")
      (check-equal! zz-lp-mark 'loaded "the file ran")
      (check-equal! zz-lp-package 'zz-lp-lib "the package stamp is the file's name")
      (check-equal! zz-lp-origin 'user "a file outside the editor's trees is the user's")
      (check-equal! *loading-package* pkg "the package stamp is back after the load")
      (check-equal! *loading-origin* org "the origin stamp is back after the load"))
    (t--lp-remove!)))

(deftest 'load-stamps-the-editor-trees-as-bundled
  "a file under priv or the project is bundled; a file in the home is the user's"
  (lambda ()
    (check-equal! (load--origin (string-append (compos-priv-dir) "/editor.scm"))
                  'bundled "priv is bundled")
    (check-equal! (load--origin (string-append (compos-project-dir) "/scheme/packages/advice.scm"))
                  'bundled "the project's packages are bundled")
    (check-equal! (load--origin (string-append (compos-home) "/x.scm"))
                  'user "the home is the user's")))
