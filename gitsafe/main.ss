#!chezscheme
;;; gitsafe/main -- Interpreter entry point (dev/install mode)
;;; Sets up library-directories before any gitsafe imports.

(import (except (chezscheme)
                make-hash-table hash-table?
                sort sort!
                printf fprintf
                path-extension path-absolute?
                with-input-from-string with-output-to-string
                iota 1+ 1-
                partition
                make-date make-time))

;; --- Library path setup ---
(define home        (or (getenv "HOME") "."))
(define jerboa-dir  (or (getenv "JERBOA_HOME")
                        (string-append home "/mine/jerboa")))
(define project-dir (or (getenv "GITSAFE_DIR")
                        (let ([p (current-directory)])
                          ;; Walk up to find the project root (contains build-binary.ss)
                          p)))

(library-directories
  (append
    (list (cons project-dir project-dir)
          (cons (string-append jerboa-dir "/lib")
                (string-append jerboa-dir "/lib")))
    (library-directories)))

;; --- Now we can import gitsafe modules ---
(import (jerboa prelude)
        (std misc process)
        (std misc ports)
        (gitsafe config)
        (gitsafe scanner)
        (gitsafe git)
        (gitsafe output))

;; --- Version ---
(def *gitsafe-version* "0.1.0")

;; --- Hook installation ---

(def (install-hook! hook-path content)
  (if (file-exists? hook-path)
    (let ([existing (call-with-input-file hook-path
                      (lambda (p) (get-line p)))])
      (if (and (string? existing)
               (or (string-contains existing "gitsafe")
                   (string-contains existing "Installed by gitsafe")))
        (begin
          (write-file-string hook-path content)
          (displayln "  Updated: " hook-path))
        (begin
          (displayln "  Warning: " hook-path " already exists and wasn't installed by gitsafe.")
          (displayln "  Append manually or back it up first."))))
    (begin
      (write-file-string hook-path content)
      (displayln "  Created: " hook-path))))

(def (make-executable! path)
  ;; chmod +x via shell
  (run-process (list "chmod" "+x" path))
  (void))

(def (cmd-install)
  (if (not (git-repo?))
    (begin (displayln "gitsafe: error: not inside a git repository") (exit 2))
    (let* ([root      (git-root)]
           [hooks-dir (string-append root "/.git/hooks")])
      (displayln "Installing git hooks into " hooks-dir "...")
      (install-hook!
        (string-append hooks-dir "/pre-commit")
        "#!/bin/sh\n# Installed by gitsafe\nexec gitsafe pre-commit\n")
      (make-executable! (string-append hooks-dir "/pre-commit"))
      (install-hook!
        (string-append hooks-dir "/pre-push")
        "#!/bin/sh\n# Installed by gitsafe\nwhile read local_ref local_sha remote_ref remote_sha; do\n  gitsafe pre-push --local-ref \"$local_ref\" --remote-ref \"$remote_ref\" || exit $?\ndone\n")
      (make-executable! (string-append hooks-dir "/pre-push"))
      (displayln "Done."))))

(def (cmd-uninstall)
  (if (not (git-repo?))
    (begin (displayln "gitsafe: error: not inside a git repository") (exit 2))
    (let* ([root      (git-root)]
           [hooks-dir (string-append root "/.git/hooks")]
           [pre-commit (string-append hooks-dir "/pre-commit")]
           [pre-push   (string-append hooks-dir "/pre-push")])
      (for-each (lambda (hook-path)
                  (if (file-exists? hook-path)
                    (let ([content (read-file-string hook-path)])
                      (if (string-contains content "Installed by gitsafe")
                        (begin
                          (delete-file hook-path)
                          (displayln "  Removed: " hook-path))
                        (displayln "  Skipped: " hook-path " (not installed by gitsafe)")))
                    (displayln "  Not found: " hook-path)))
                (list pre-commit pre-push))
      (displayln "Done."))))

;; --- Main scanning dispatch ---

(def (run-scan findings format verbose?)
  (if (null? findings)
    (begin
      (when verbose? (display-findings findings format verbose?))
      (display-summary findings)
      (exit 0))
    (begin
      (display-findings findings format verbose?)
      (exit 1))))

(def (cmd-pre-commit config format verbose?)
  (if (not (git-repo?))
    (begin (displayln "gitsafe: error: not inside a git repository") (exit 2))
    (run-scan (scan-staged config) format verbose?)))

(def (cmd-pre-push local-ref remote-ref config format verbose?)
  (if (not (git-repo?))
    (begin (displayln "gitsafe: error: not inside a git repository") (exit 2))
    (run-scan (scan-push-range local-ref remote-ref config) format verbose?)))

(def (cmd-scan paths config format verbose?)
  (if (null? paths)
    (begin (displayln "gitsafe: error: no paths specified") (exit 2))
    (run-scan (scan-files paths config) format verbose?)))

;; --- Argument parsing ---

(def (parse-args args)
  (let loop ([args  args]
             [mode  "pre-commit"]
             [paths '()]
             [cfg-path ".gitsafe.json"]
             [format "text"]
             [severity #f]
             [entropy #t]
             [verbose #f]
             [local-ref  #f]
             [remote-ref #f])
    (cond
      [(null? args)
       (list mode paths cfg-path format severity entropy verbose local-ref remote-ref)]

      [(member (car args) '("pre-commit" "pre-push" "scan" "install" "uninstall"))
       (loop (cdr args) (car args) paths cfg-path format severity entropy verbose local-ref remote-ref)]

      [(string=? (car args) "--config")
       (if (pair? (cdr args))
         (loop (cddr args) mode paths (cadr args) format severity entropy verbose local-ref remote-ref)
         (loop (cdr args) mode paths cfg-path format severity entropy verbose local-ref remote-ref))]

      [(string=? (car args) "--format")
       (if (pair? (cdr args))
         (loop (cddr args) mode paths cfg-path (cadr args) severity entropy verbose local-ref remote-ref)
         (loop (cdr args) mode paths cfg-path format severity entropy verbose local-ref remote-ref))]

      [(string=? (car args) "--severity")
       (if (pair? (cdr args))
         (loop (cddr args) mode paths cfg-path format (cadr args) entropy verbose local-ref remote-ref)
         (loop (cdr args) mode paths cfg-path format severity entropy verbose local-ref remote-ref))]

      [(string=? (car args) "--no-entropy")
       (loop (cdr args) mode paths cfg-path format severity #f verbose local-ref remote-ref)]

      [(string=? (car args) "--verbose")
       (loop (cdr args) mode paths cfg-path format severity entropy #t local-ref remote-ref)]

      [(string=? (car args) "--local-ref")
       (if (pair? (cdr args))
         (loop (cddr args) mode paths cfg-path format severity entropy verbose (cadr args) remote-ref)
         (loop (cdr args) mode paths cfg-path format severity entropy verbose local-ref remote-ref))]

      [(string=? (car args) "--remote-ref")
       (if (pair? (cdr args))
         (loop (cddr args) mode paths cfg-path format severity entropy verbose local-ref (cadr args))
         (loop (cdr args) mode paths cfg-path format severity entropy verbose local-ref remote-ref))]

      [(string=? (car args) "--version")
       (displayln "gitsafe " *gitsafe-version*)
       (exit 0)]

      [(string=? (car args) "--help")
       (display
"Usage: gitsafe [MODE] [OPTIONS]

Modes:
  pre-commit         Scan staged files (default)
  pre-push           Scan commits being pushed
  scan PATH...       Scan specific files or directories
  install            Install git hooks in .git/hooks/
  uninstall          Remove git hooks

Options:
  --config PATH      Path to .gitsafe.json (default: .gitsafe.json)
  --format text|json Output format (default: text)
  --severity LEVEL   Minimum severity: low|medium|high|critical (default: medium)
  --no-entropy       Disable entropy analysis
  --verbose          Show scan statistics
  --version          Print version
  --help             Print this help
")
       (exit 0)]

      ;; Positional args go to paths (for scan mode)
      [else
       (loop (cdr args) mode (append paths (list (car args)))
             cfg-path format severity entropy verbose local-ref remote-ref)])))

;; --- Entry point ---

(let* ([args   (cdr (command-line))]
       [parsed (parse-args args)]
       [mode        (list-ref parsed 0)]
       [paths       (list-ref parsed 1)]
       [cfg-path    (list-ref parsed 2)]
       [format      (list-ref parsed 3)]
       [severity    (list-ref parsed 4)]
       [entropy     (list-ref parsed 5)]
       [verbose     (list-ref parsed 6)]
       [local-ref   (list-ref parsed 7)]
       [remote-ref  (list-ref parsed 8)]
       [config      (let ([c (load-config cfg-path)])
                      ;; Override config fields from CLI flags
                      (make-gitsafe-config
                        (if severity
                          (match severity
                            ["low"      'low]
                            ["medium"   'medium]
                            ["high"     'high]
                            ["critical" 'critical]
                            [_          (gitsafe-config-severity c)])
                          (gitsafe-config-severity c))
                        (if entropy
                          (gitsafe-config-entropy-enabled c)
                          #f)
                        (gitsafe-config-disabled-patterns c)
                        (gitsafe-config-custom-patterns c)
                        (gitsafe-config-exclude-globs c)
                        (gitsafe-config-allowlist-files c)
                        (gitsafe-config-allowlist-strings c)))])
  (match mode
    ["install"    (cmd-install)]
    ["uninstall"  (cmd-uninstall)]
    ["pre-commit" (cmd-pre-commit config format verbose)]
    ["pre-push"
     (let ([lr (or local-ref "HEAD")]
           [rr (or remote-ref "origin/HEAD")])
       (cmd-pre-push lr rr config format verbose))]
    ["scan"
     (cmd-scan paths config format verbose)]
    [_
     (displayln "gitsafe: unknown mode: " mode)
     (exit 2)]))
