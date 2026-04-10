#!chezscheme
(library (gitsafe allowlist)
  (export line-suppressed?
          allowlisted?
          load-ignorefile
          ignored-file?)
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
          (std misc ports)
          (std misc string)
          (gitsafe config))

  ;; --- Inline suppression detection ---
  ;; Supports:
  ;;   # gitsafe:ignore
  ;;   # gitsafe:ignore=pattern-id
  ;;   // gitsafe:ignore
  ;;   /* gitsafe:ignore */

  (def *suppress-pat*
    (pregexp "(?:#|//|/\\*)\\s*gitsafe:ignore(?:=([A-Za-z0-9_-]+))?"))

  ;; Returns #t if the line is suppressed (optionally for a specific pattern-id symbol).
  (def (line-suppressed? line (pattern-id #f))
    (let ([m (pregexp-match *suppress-pat* line)])
      (if (not m)
        #f
        ;; m = (full-match maybe-pattern-id-group)
        (let ([specific (and (pair? (cdr m)) (cadr m))])
          (cond
            ;; No specific pattern in comment — suppress all
            [(not specific) #t]
            ;; No pattern-id filter requested — suppress all
            [(not pattern-id) #t]
            ;; Specific pattern matches requested id
            [else (string=? specific (symbol->string pattern-id))])))))

  ;; --- Allowlist string check ---
  ;; Returns #t if the matched text contains any known-safe string.
  (def (allowlisted? matched-text config)
    (and (any (lambda (s) (string-contains matched-text s))
              (gitsafe-config-allowlist-strings config))
         #t))

  ;; --- .gitsafeignore file ---
  ;; Loads glob patterns from a gitignore-style file.
  ;; Blank lines and lines starting with # are ignored.
  (def (load-ignorefile (path ".gitsafeignore"))
    (if (not (file-exists? path))
      '()
      (filter (lambda (line)
                (and (not (string-empty? line))
                     (not (string-prefix? "#" line))))
              (read-file-lines path))))

  ;; --- Check if a file path matches any ignorefile pattern ---
  (def (ignored-file? path ignore-patterns)
    (any (lambda (glob) (glob-match? glob path))
         ignore-patterns))

) ;; end library
