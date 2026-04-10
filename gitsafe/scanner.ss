#!chezscheme
(library (gitsafe scanner)
  (export make-finding
          finding?
          finding-pattern-id
          finding-pattern-name
          finding-severity
          finding-file
          finding-line-number
          finding-line-content
          finding-matched-text
          finding-redacted
          scan-line
          scan-content
          scan-diff-hunks
          scan-staged
          scan-push-range
          scan-files
          skip-file?)
  (import (except (chezscheme)
                  make-hash-table hash-table?
                  sort sort!
                  printf fprintf
                  path-extension path-absolute?
                  with-input-from-string with-output-to-string
                  iota 1+ 1-
                  partition
                  make-date make-time)
          (jerboa prelude)
          (std pregexp)
          (std misc string)
          (std misc ports)
          (std os path)
          (gitsafe patterns)
          (gitsafe entropy)
          (gitsafe config)
          (gitsafe allowlist)
          (gitsafe git))

  ;; --- Finding struct ---
  (defstruct finding
    (pattern-id    ;; symbol
     pattern-name  ;; string
     severity      ;; symbol
     file          ;; string
     line-number   ;; integer
     line-content  ;; string (redacted for output)
     matched-text  ;; string (original match)
     redacted      ;; string (middle replaced with ***)
     ))

  ;; --- Extensions to skip (binary / non-secret files) ---
  ;; path-extension returns WITH dot (e.g. ".png"), so we include dots here.
  (def *skip-extensions*
    '(".png" ".jpg" ".jpeg" ".gif" ".bmp" ".ico" ".svg" ".webp"
      ".woff" ".woff2" ".ttf" ".eot" ".otf"
      ".zip" ".gz" ".tar" ".bz2" ".xz" ".7z" ".rar" ".zst"
      ".pdf" ".doc" ".docx" ".xls" ".xlsx" ".pptx"
      ".exe" ".dll" ".so" ".dylib" ".o" ".a" ".lib"
      ".pyc" ".class" ".wasm"
      ".mp3" ".mp4" ".avi" ".mov" ".wav" ".flac" ".ogg"
      ".lock"))

  ;; --- Redact matched text ---
  (def (redact str)
    (let ([len (string-length str)])
      (cond
        [(<= len 4) "***"]
        [(<= len 8)
         (string-append (substring str 0 2) "***")]
        [else
         (string-append
           (substring str 0 4)
           "***"
           (substring str (- len 4) len))])))

  ;; --- Should we skip this file? ---
  (def (skip-file? path config)
    (let ([ext (path-extension path)])
      (and (or (member ext *skip-extensions*)
               (config-excluded? config path))
           #t)))

  ;; --- Severity ordering ---
  (def (severity-level sev)
    (match sev
      ['critical 3]
      ['high     2]
      ['medium   1]
      ['low      0]
      [_         0]))

  (def (severity>= a b)
    (>= (severity-level a) (severity-level b)))

  ;; --- Minimum severity from config ---
  (def (min-severity config)
    (gitsafe-config-severity config))

  ;; --- Extract matched substring from pregexp-match-positions result ---
  (def (extract-match line positions)
    ;; positions is ((start . end) ...) — first pair is the full match
    (and (pair? positions)
         (let* ([pair (car positions)]
                [s (car pair)]
                [e (cdr pair)])
           (substring line s e))))

  ;; --- Get active patterns given config ---
  (def (active-patterns config)
    (let ([disabled (gitsafe-config-disabled-patterns config)]
          [min-sev  (min-severity config)])
      (filter (lambda (p)
                (and (not (member (secret-pattern-id p) disabled))
                     (severity>= (secret-pattern-severity p) min-sev)))
              (all-patterns))))

  ;; --- Scan a single line against all patterns ---
  ;; Returns list of finding structs.
  (def (scan-line file line-number line patterns config)
    ;; Skip very long lines (minified/generated code)
    (if (> (string-length line) 2000)
      '()
      (let loop ([pats patterns] [results '()])
        (if (null? pats)
          (reverse results)
          (let ([pat (car pats)])
            (let ([positions (pregexp-match-positions
                               (secret-pattern-pregexp pat) line)])
              (if (not positions)
                (loop (cdr pats) results)
                (let ([matched (extract-match line positions)])
                  (if (not matched)
                    (loop (cdr pats) results)
                    ;; Run validator if present
                    (let ([valid? (let ([v (secret-pattern-validator pat)])
                                    (if v (v matched) #t))])
                      (if (not valid?)
                        (loop (cdr pats) results)
                        ;; Check allowlist
                        (if (allowlisted? matched config)
                          (loop (cdr pats) results)
                          ;; Check inline suppression
                          (if (line-suppressed? line (secret-pattern-id pat))
                            (loop (cdr pats) results)
                            ;; Build finding
                            (let ([f (make-finding
                                       (secret-pattern-id pat)
                                       (secret-pattern-name pat)
                                       (secret-pattern-severity pat)
                                       file
                                       line-number
                                       (redact line)
                                       matched
                                       (redact matched))])
                              (loop (cdr pats) (cons f results))))))))))
          ))))))

  ;; --- Scan full file content (string) ---
  (def (scan-content file content config)
    (let ([patterns (active-patterns config)])
      (let loop ([lines (string-split content #\newline)]
                 [line-no 1]
                 [results '()])
        (if (null? lines)
          (reverse results)
          (let ([findings (scan-line file line-no (car lines) patterns config)])
            (loop (cdr lines)
                  (+ line-no 1)
                  (append results findings)))))))

  ;; --- Scan diff hunks (added lines only) ---
  (def (scan-diff-hunks hunks config)
    (let ([patterns (active-patterns config)])
      (apply append
        (map (lambda (hunk)
               (apply append
                 (map (lambda (line-pair)
                        (scan-line
                          (diff-hunk-file hunk)
                          (car line-pair)
                          (cdr line-pair)
                          patterns
                          config))
                      (diff-hunk-lines hunk))))
             hunks))))

  ;; --- Top-level: scan staged changes (pre-commit mode) ---
  (def (scan-staged config)
    (let ([files (staged-files)]
          [ignore-pats (load-ignorefile)])
      (apply append
        (map (lambda (path)
               (cond
                 [(skip-file? path config) '()]
                 [(ignored-file? path ignore-pats) '()]
                 [else
                  (let ([hunks (staged-diff path)])
                    (if (null? hunks)
                      ;; New file — scan full staged content
                      (let ([content (staged-content path)])
                        (if (string-empty? content)
                          '()
                          (scan-content path content config)))
                      ;; Modified file — scan only added lines
                      (scan-diff-hunks hunks config)))]))
             files))))

  ;; --- Top-level: scan push range ---
  (def (scan-push-range local-ref remote-ref config)
    (let ([commits (push-commits local-ref remote-ref)]
          [ignore-pats (load-ignorefile)])
      (if (null? commits)
        '()
        ;; Scan diff of the entire range
        (let ([files (changed-files-in-range remote-ref local-ref)])
          (apply append
            (map (lambda (path)
                   (cond
                     [(skip-file? path config) '()]
                     [(ignored-file? path ignore-pats) '()]
                     [else
                      (let ([diff-text (range-diff remote-ref local-ref path)])
                        (let ([hunks (if (string-empty? diff-text)
                                       '()
                                       (parse-unified-diff-text diff-text path))])
                          (scan-diff-hunks hunks config)))]))
                 files))))))

  ;; Helper: expose parse for push range use
  (def (parse-unified-diff-text text file)
    (let loop ([lines (string-split text #\newline)]
               [hunks '()]
               [cur-hunk #f]
               [new-line-no 0])
      (if (null? lines)
        (reverse (if (and cur-hunk
                          (not (null? (diff-hunk-lines cur-hunk))))
                   (cons cur-hunk hunks)
                   hunks))
        (let ([line (car lines)]
              [rest (cdr lines)])
          (cond
            [(pregexp-match "^@@ -[0-9,]+ \\+([0-9]+)(?:,[0-9]+)? @@" line)
             =>
             (lambda (m)
               (let* ([new-start (string->number (cadr m))]
                      [hunks* (if (and cur-hunk
                                       (not (null? (diff-hunk-lines cur-hunk))))
                                (cons cur-hunk hunks)
                                hunks)])
                 (loop rest hunks*
                       (make-diff-hunk file 0 new-start '())
                       new-start)))]
            [(and cur-hunk
                  (> (string-length line) 0)
                  (char=? (string-ref line 0) #\+)
                  (not (string-prefix? "+++" line)))
             (let ([updated (make-diff-hunk
                              (diff-hunk-file cur-hunk)
                              (diff-hunk-old-start cur-hunk)
                              (diff-hunk-new-start cur-hunk)
                              (append (diff-hunk-lines cur-hunk)
                                      (list (cons new-line-no
                                                  (substring line 1 (string-length line))))))])
               (loop rest hunks updated (+ new-line-no 1)))]
            [(and cur-hunk (> (string-length line) 0)
                  (char=? (string-ref line 0) #\space))
             (loop rest hunks cur-hunk (+ new-line-no 1))]
            [else
             (loop rest hunks cur-hunk new-line-no)])))))

  ;; --- Top-level: scan specific files ---
  (def (scan-files paths config)
    (let ([ignore-pats (load-ignorefile)])
      (apply append
        (map (lambda (path)
               (cond
                 [(not (file-exists? path)) '()]
                 [(skip-file? path config) '()]
                 [(ignored-file? path ignore-pats) '()]
                 [else
                  (let ([content (read-file-string path)])
                    (scan-content path content config))]))
             paths))))

) ;; end library
