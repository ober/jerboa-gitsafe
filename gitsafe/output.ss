#!chezscheme
(library (gitsafe output)
  (export display-findings
          display-summary
          findings-count-by-severity)
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
          (std text json)
          (gitsafe scanner))

  ;; --- Terminal color support ---
  (def (color-enabled?)
    (and (not (getenv "NO_COLOR"))
         (let ([term (getenv "TERM")])
           (not (and term (string=? term "dumb"))))))

  ;; ANSI color codes
  (def (severity-color sev)
    (if (not (color-enabled?))
      ""
      (match sev
        ['critical "\x1b;[1;31m"]   ;; bold red
        ['high     "\x1b;[31m"]     ;; red
        ['medium   "\x1b;[33m"]     ;; yellow
        ['low      "\x1b;[34m"]     ;; blue
        [_         ""])))

  (def *reset* "\x1b;[0m")
  (def *bold*  "\x1b;[1m")

  (def (color-reset)
    (if (color-enabled?) *reset* ""))

  (def (color-bold str)
    (if (color-enabled?)
      (string-append *bold* str *reset*)
      str))

  ;; --- Severity label ---
  (def (severity-label sev)
    (match sev
      ['critical "CRITICAL"]
      ['high     "HIGH"]
      ['medium   "MEDIUM"]
      ['low      "LOW"]
      [_         "UNKNOWN"]))

  ;; --- Count findings by severity ---
  (def (findings-count-by-severity findings)
    (let ([counts (list->hash-table '(("critical" . 0) ("high" . 0) ("medium" . 0) ("low" . 0)))])
      (for-each (lambda (f)
                  (let ([k (symbol->string (finding-severity f))])
                    (hash-put! counts k (+ 1 (hash-ref counts k 0)))))
                findings)
      counts))

  ;; --- Text output ---

  (def (display-finding-text f)
    (let* ([sev  (finding-severity f)]
           [col  (severity-color sev)]
           [rst  (color-reset)]
           [lbl  (severity-label sev)])
      (display (string-append col "[" lbl "]" rst))
      (display " ")
      (display (color-bold "gitsafe:"))
      (display " secret detected in ")
      (display (color-bold (finding-file f)))
      (display ":")
      (display (finding-line-number f))
      (newline)
      (display "  Pattern: ")
      (display (finding-pattern-name f))
      (newline)
      (display "  Match:   ")
      (display (finding-redacted f))
      (newline)
      (display "  Line:    ")
      (display (finding-line-content f))
      (newline)
      (newline)))

  (def (display-findings-text findings verbose?)
    (for-each display-finding-text findings))

  ;; --- JSON output ---

  (def (finding->json-obj f)
    (let ([ht (make-hash-table)])
      (hash-put! ht "id"       (symbol->string (finding-pattern-id f)))
      (hash-put! ht "severity" (symbol->string (finding-severity f)))
      (hash-put! ht "file"     (finding-file f))
      (hash-put! ht "line"     (finding-line-number f))
      (hash-put! ht "pattern"  (finding-pattern-name f))
      (hash-put! ht "match"    (finding-redacted f))
      ht))

  (def (display-findings-json findings)
    (let* ([objs     (map finding->json-obj findings)]
           [counts   (findings-count-by-severity findings)]
           [files    (length (unique (map finding-file findings)))]
           [summary  (let ([s (make-hash-table)])
                       (hash-put! s "total"    (length findings))
                       (hash-put! s "files"    files)
                       (hash-put! s "critical" (hash-ref counts "critical" 0))
                       (hash-put! s "high"     (hash-ref counts "high"     0))
                       (hash-put! s "medium"   (hash-ref counts "medium"   0))
                       (hash-put! s "low"      (hash-ref counts "low"      0))
                       s)]
           [root     (let ([r (make-hash-table)])
                       (hash-put! r "findings" objs)
                       (hash-put! r "summary"  summary)
                       r)])
      (display (json-object->string root))
      (newline)))

  ;; --- Summary line ---

  (def (display-summary findings)
    (let ([n     (length findings)]
          [files (length (unique (map finding-file findings)))])
      (if (= n 0)
        (begin
          (when (color-enabled?)
            (display "\x1b;[32m"))  ;; green
          (display "gitsafe: ")
          (when (color-enabled?)
            (display "\x1b;[0m"))
          (display "no secrets detected.")
          (newline))
        (begin
          (display (severity-color 'critical))
          (display "gitsafe: ")
          (display n)
          (display " secret")
          (when (> n 1) (display "s"))
          (display " found in ")
          (display files)
          (display " file")
          (when (> files 1) (display "s"))
          (display ". Commit blocked.")
          (display (color-reset))
          (newline)
          (display "Suppress with: # gitsafe:ignore  (inline)  or  .gitsafe.json  (project)")
          (newline)))))

  ;; --- Main dispatch ---

  (def (display-findings findings format verbose?)
    (match format
      ["json"
       (display-findings-json findings)]
      [_
       (display-findings-text findings verbose?)]))

) ;; end library
