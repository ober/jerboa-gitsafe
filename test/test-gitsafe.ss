#!chezscheme
;;; test/test-gitsafe.ss -- gitsafe test suite

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
(define home       (or (getenv "HOME") "."))
(define jerboa-dir (or (getenv "JERBOA_HOME")
                       (string-append home "/mine/jerboa")))
(define project-dir (current-directory))

(library-directories
  (append
    (list (cons project-dir project-dir)
          (cons (string-append jerboa-dir "/lib")
                (string-append jerboa-dir "/lib")))
    (library-directories)))

 (import (except (jerboa prelude) meta atom?)
        (std test)
        (std regex)
        (gitsafe entropy)
        (gitsafe patterns)
        (gitsafe config)
        (gitsafe allowlist)
        (gitsafe scanner))

;; ============================================================
;; Entropy tests
;; ============================================================

(def suite-entropy
  (test-suite "entropy"

    (test-case "empty string returns 0.0"
      (check-eqv? (shannon-entropy "") 0.0))

    (test-case "single char returns 0.0"
      (check-eqv? (shannon-entropy "a") 0.0))

    (test-case "two identical chars returns 0.0"
      (check-eqv? (shannon-entropy "aa") 0.0))

    (test-case "two distinct chars returns 1.0"
      (check-eqv? (shannon-entropy "ab") 1.0))

    (test-case "four distinct chars returns 2.0"
      (check-eqv? (shannon-entropy "abcd") 2.0))

    (test-case "repeated pattern has low entropy"
      (check-predicate (shannon-entropy "abababababab") (lambda (e) (< e 2.0))))

    (test-case "random-looking string has high entropy"
      (check-predicate (shannon-entropy "xK9mP2nQrT5vWy8zA3bCdEfGhJkLmNpQ") (lambda (e) (> e 4.0))))

    (test-case "high-entropy? respects threshold"
      (check-equal? #t (high-entropy? "xK9mP2nQrT5vWy8zA3bCdEfGhJkLmNpQ" 3.0))
      (check-equal? #f (high-entropy? "aaaaaaaaaaaaaaaa" 3.0)))

    (test-case "string-charset detects hex"
      (check-eq? 'hex (string-charset "deadbeef1234abcd")))

    ;; Pure alphanumeric chars are a subset of base64 chars (A-Z, a-z, 0-9),
    ;; so string-charset returns 'base64 for pure letter/digit strings.
    (test-case "string-charset: pure alphanumeric classified as base64"
      (check-eq? 'base64 (string-charset "Hello123World")))

    (test-case "string-charset detects base64"
      (check-eq? 'base64 (string-charset "SGVsbG8gV29ybGQ=")))

    (test-case "string-charset detects printable for mixed chars"
      (check-eq? 'printable (string-charset "hello world!")))

  ))

;; ============================================================
;; Pattern tests
;; ============================================================

(def suite-patterns
  (test-suite "patterns"

    (test-case "all-patterns returns non-empty list"
      (check-predicate (all-patterns) pair?))

    (test-case "patterns-by-severity returns only matching severity"
      (let ([crits (patterns-by-severity 'critical)])
        (check-predicate crits pair?)
        (for-each (lambda (p)
                    (check-eq? 'critical (secret-pattern-severity p)))
                  crits)))

    (test-case "aws-access-key: detects AKIA prefix"
      (let ([pat (car (filter (lambda (p) (eq? (secret-pattern-id p) 'aws-access-key))
                              (all-patterns)))])
        (check-predicate
          (re-search (secret-pattern-pregexp pat) "AKIAIOSFODNN7EXAMPLE!!!")
          (lambda (m) m))))

    (test-case "github-pat: detects ghp_ token"
      (let ([pat (car (filter (lambda (p) (eq? (secret-pattern-id p) 'github-pat))
                              (all-patterns)))])
        (check-predicate
          (re-search (secret-pattern-pregexp pat)
                         "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef1234")
          (lambda (m) m))))

    (test-case "anthropic-api-key: detects sk-ant- prefix"
      (let ([pat (car (filter (lambda (p) (eq? (secret-pattern-id p) 'anthropic-api-key))
                              (all-patterns)))])
        (check-predicate
          (re-search (secret-pattern-pregexp pat)
                         "sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcde")
          (lambda (m) m))))

    (test-case "jwt: detects eyJ... format"
      (let ([pat (car (filter (lambda (p) (eq? (secret-pattern-id p) 'jwt))
                              (all-patterns)))])
        (check-predicate
          (re-search (secret-pattern-pregexp pat)
                         "eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyIjoiYWRtaW4ifQ.SflKxwRJSMeKKF2QT4fw")
          (lambda (m) m))))

    (test-case "stripe-secret: detects sk_live_ format"
      (let ([pat (car (filter (lambda (p) (eq? (secret-pattern-id p) 'stripe-secret))
                              (all-patterns)))])
        (check-predicate
          (re-search (secret-pattern-pregexp pat)
                         "sk_live_ABCDEFGHIJKLMNOPQRSTUVWXYZabc")
          (lambda (m) m))))

    (test-case "private-key-pem: detects OpenSSH private key"
      (let ([pat (car (filter (lambda (p) (eq? (secret-pattern-id p) 'private-key-pem))
                              (all-patterns)))])
        (check-predicate
          (re-search (secret-pattern-pregexp pat)
                         "-----BEGIN OPENSSH PRIVATE KEY-----")
          (lambda (m) m))))

    (test-case "private-key-pem: detects encrypted private key"
      (let ([pat (car (filter (lambda (p) (eq? (secret-pattern-id p) 'private-key-pem))
                              (all-patterns)))])
        (check-predicate
          (re-search (secret-pattern-pregexp pat)
                         "-----BEGIN ENCRYPTED PRIVATE KEY-----")
          (lambda (m) m))))

    (test-case "putty-private-key: detects PuTTY key file"
      (let ([pat (car (filter (lambda (p) (eq? (secret-pattern-id p) 'putty-private-key))
                              (all-patterns)))])
        (check-predicate
          (re-search (secret-pattern-pregexp pat)
                         "PuTTY-User-Key-File-3: ssh-rsa")
          (lambda (m) m))))

  ))

;; ============================================================
;; Config tests
;; ============================================================

(def suite-config
  (test-suite "config"

    (test-case "default-config returns valid struct"
      (let ([c (default-config)])
        (check-equal? #t (gitsafe-config? c))
        (check-eq? 'medium (gitsafe-config-severity c))
        (check-equal? #t (gitsafe-config-entropy-enabled c))))

    (test-case "load-config returns default when file missing"
      (let ([c (load-config "/nonexistent/.gitsafe.json")])
        (check-equal? #t (gitsafe-config? c))
        (check-eq? 'medium (gitsafe-config-severity c))))

    (test-case "glob-match?: exact match"
      (check-equal? #t (glob-match? "foo.json" "foo.json")))

    (test-case "glob-match?: * wildcard"
      (check-equal? #t (glob-match? "*.json" "config.json"))
      (check-equal? #f (glob-match? "*.json" "config.yaml")))

    (test-case "glob-match?: ** wildcard"
      (check-equal? #t (glob-match? "vendor/**" "vendor/foo/bar.go"))
      (check-equal? #t (glob-match? "test/**" "test/fixtures/fake.txt")))

    (test-case "glob-match?: ? wildcard"
      (check-equal? #t (glob-match? "file?.txt" "file1.txt"))
      (check-equal? #f (glob-match? "file?.txt" "file12.txt")))

    (test-case "config-excluded? works for default excludes"
      (let ([c (default-config)])
        (check-equal? #t (config-excluded? c "Cargo.lock"))
        (check-equal? #f (config-excluded? c "main.ss"))))

  ))

;; ============================================================
;; Allowlist tests
;; ============================================================

(def suite-allowlist
  (test-suite "allowlist"

    (test-case "line-suppressed?: detects # gitsafe:ignore"
      (check-equal? #t (line-suppressed? "secret = \"abc\"  # gitsafe:ignore")))

    (test-case "line-suppressed?: detects // gitsafe:ignore"
      (check-equal? #t (line-suppressed? "secret = \"abc\"  // gitsafe:ignore")))

    (test-case "line-suppressed?: pattern-specific match"
      (check-equal? #t (line-suppressed? "x  # gitsafe:ignore=aws-access-key" 'aws-access-key))
      (check-equal? #f (line-suppressed? "x  # gitsafe:ignore=github-pat" 'aws-access-key)))

    (test-case "line-suppressed?: returns #f for normal lines"
      (check-equal? #f (line-suppressed? "api_key = \"realvalue\"")))

    (test-case "allowlisted?: matches allowlist strings"
      (let ([c (make-gitsafe-config
                 'medium #t '() '() '() '() '("EXAMPLE_KEY" "fake_secret"))])
        (check-equal? #t (allowlisted? "EXAMPLE_KEY_12345" c))
        (check-equal? #f (allowlisted? "sk-ant-realkey" c))))

    (test-case "load-ignorefile: returns empty list when file missing"
      (check-equal? '() (load-ignorefile "/nonexistent/.gitsafeignore")))

  ))

;; ============================================================
;; Scanner integration tests
;; ============================================================

(def suite-scanner
  (test-suite "scanner"

    (test-case "skip-file?: skips binary extensions"
      (let ([c (default-config)])
        (check-equal? #t (skip-file? "image.png" c))
        (check-equal? #t (skip-file? "archive.zip" c))
        (check-equal? #f (skip-file? "config.json" c))
        (check-equal? #f (skip-file? "Makefile" c))))

    (test-case "extract-match: AWS key with boundary chars extracts key only"
      (let* ([c        (default-config)]
             [patterns (filter (lambda (p) (eq? (secret-pattern-id p) 'aws-access-key))
                               (all-patterns))]
             [findings (scan-line "test.txt" 1
                         "aws_access_key_id = AKIAIOSFODNN7EXAMPLS"
                         patterns c)])
        (check-predicate findings pair?)
        (check-equal? "AKIAIOSFODNN7EXAMPLS"
                      (finding-matched-text (car findings)))))

    (test-case "extract-match: generic-secret extracts value not whole assignment"
      (let* ([c        (default-config)]
             [patterns (filter (lambda (p) (eq? (secret-pattern-id p) 'generic-secret))
                               (all-patterns))]
             [findings (scan-line "test.txt" 1
                         "secret = \"xK9mP2nQrT5vWy8zA3bCdEfGhJkLmNpQ\""
                         patterns c)])
        (check-predicate findings pair?)
        (check-equal? "xK9mP2nQrT5vWy8zA3bCdEfGhJkLmNpQ"
                      (finding-matched-text (car findings)))))

    (test-case "not-placeholder: does not reject keys containing test/fake substrings"
      (let* ([c        (default-config)]
             [patterns (filter (lambda (p) (eq? (secret-pattern-id p) 'generic-secret))
                               (all-patterns))]
             [findings (scan-line "test.txt" 1
                         "secret = \"testX9mP2nQrT5vWy8zA3bCdEfGhJk\""
                         patterns c)])
        (check-predicate findings pair?)))

    (test-case "basic-auth-url: rejects placeholder credentials"
      (let* ([c        (default-config)]
             [patterns (filter (lambda (p) (eq? (secret-pattern-id p) 'basic-auth-url))
                               (all-patterns))]
             [real     (scan-line "test.txt" 1
                         "DATABASE_URL=postgres://admin:s3cr3tP4ss@db.example.com:5432/mydb"
                         patterns c)]
             [fake     (scan-line "test.txt" 1
                         "DATABASE_URL=postgres://user:password@localhost:5432/mydb"
                         patterns c)])
        (check-predicate real pair?)
        (check-equal? '() fake)))

    (test-case "scan-content: detects secrets in fixture file"
      (let* ([c       (default-config)]
             [content (read-file-string "test/fixtures/fake-secrets.txt")]
             [findings (scan-content "fake-secrets.txt" content c)])
        (check-predicate findings pair?)
        (check-predicate (length findings) (lambda (n) (>= n 10)))))

    (test-case "scan-content: jcode.json fixture is caught"
      (let* ([c       (default-config)]
             [content (read-file-string "test/fixtures/jcode.json")]
             [findings (scan-content "jcode.json" content c)])
        (check-predicate (length findings) (lambda (n) (>= n 3)))))

    (test-case "scan-content: gitsafe:ignore suppresses finding"
      (let* ([c        (default-config)]
             [findings (scan-content "test.txt"
                         "sk_live_ABCDEFGHIJKLMNOPQRSTUVWXYZabc  # gitsafe:ignore\n"
                         c)])
        (check-equal? '() findings)))

    (test-case "scan-content: env-var references not flagged"
      (let* ([c        (default-config)]
             [findings (scan-content "test.py"
                         "api_key = os.getenv('API_KEY')\ntoken = os.environ.get('TOKEN')\n"
                         c)])
        (check-equal? '() findings)))

    (test-case "scan-content: URLs in comments are not flagged as entropy secrets"
      ;; Long URL paths match [A-Za-z0-9/]{40+} but are not secrets.
      (let* ([c        (default-config)]
             [findings (scan-content "dissectors/kafka.ss"
                         ";; https://kafka.apache.org/protocol/protocol\n;; https://github.com/couchbase/couchbase-protocol\n;; https://en.wikipedia.org/wiki/RTTRP#History-2ddb12341234abcdef12abcd2cf5\n"
                         c)])
        (check-equal? '() (filter (lambda (f)
                                    (member (finding-pattern-id f)
                                            '(high-entropy-base64 high-entropy-hex)))
                                  findings))))

    (test-case "scan-content: false-positives fixture produces no entropy findings"
      (let* ([c        (default-config)]
             [content  (read-file-string "test/fixtures/false-positives.txt")]
             [findings (scan-content "false-positives.txt" content c)]
             [entropy-findings (filter (lambda (f)
                                         (member (finding-pattern-id f)
                                                 '(high-entropy-base64 high-entropy-hex)))
                                       findings)])
        (check-equal? '() entropy-findings)))

  ))

;; ============================================================
;; Run all suites
;; ============================================================

(run-tests! suite-entropy suite-patterns suite-config suite-allowlist suite-scanner)
