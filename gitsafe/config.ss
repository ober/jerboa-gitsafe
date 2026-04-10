#!chezscheme
(library (gitsafe config)
  (export make-gitsafe-config
          gitsafe-config?
          gitsafe-config-severity
          gitsafe-config-entropy-enabled
          gitsafe-config-disabled-patterns
          gitsafe-config-custom-patterns
          gitsafe-config-exclude-globs
          gitsafe-config-allowlist-files
          gitsafe-config-allowlist-strings
          default-config
          load-config
          config-excluded?
          glob-match?)
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
          (std misc ports)
          (std misc string))

  ;; --- Config struct ---
  (defstruct gitsafe-config
    (severity           ;; symbol: 'low | 'medium | 'high | 'critical
     entropy-enabled    ;; boolean
     disabled-patterns  ;; list of symbols (pattern IDs to skip)
     custom-patterns    ;; list of alists from JSON
     exclude-globs      ;; list of glob strings
     allowlist-files    ;; list of file paths
     allowlist-strings  ;; list of literal strings known safe
     ))

  ;; --- Default configuration ---
  (def (default-config)
    (make-gitsafe-config
      'medium   ;; severity
      #t        ;; entropy-enabled
      '()       ;; disabled-patterns
      '()       ;; custom-patterns
      ;; Standard excludes: lock files, docs, test dirs
      '("*.lock" "go.sum" "*.md" "vendor/**"
        "node_modules/**" "*.min.js" "*.min.css")
      '()       ;; allowlist-files
      '()       ;; allowlist-strings
      ))

  ;; --- Glob matching ---
  ;; Supports: * (non-separator), ** (any), ? (single char)
  (def (glob-match? pattern path)
    (let loop ([ps (string->list pattern)]
               [xs (string->list path)])
      (cond
        ;; Both exhausted — match
        [(and (null? ps) (null? xs)) #t]
        ;; Pattern exhausted, path not — no match
        [(null? ps) #f]
        ;; ** matches any sequence including /
        [(and (pair? ps) (char=? (car ps) #\*)
              (pair? (cdr ps)) (char=? (cadr ps) #\*))
         (let ([rest-ps (cddr ps)])
           ;; Skip any leading / after **
           (let ([rest-ps (if (and (pair? rest-ps) (char=? (car rest-ps) #\/))
                            (cdr rest-ps)
                            rest-ps)])
             (or (loop rest-ps xs)
                 (and (pair? xs)
                      (loop ps (cdr xs))))))]
        ;; * matches any non-/ chars
        [(char=? (car ps) #\*)
         (let ([rest-ps (cdr ps)])
           (or (loop rest-ps xs)
               (and (pair? xs)
                    (not (char=? (car xs) #\/))
                    (loop ps (cdr xs)))))]
        ;; ? matches a single non-/ char
        [(char=? (car ps) #\?)
         (and (pair? xs)
              (not (char=? (car xs) #\/))
              (loop (cdr ps) (cdr xs)))]
        ;; Path exhausted, pattern not — no match
        [(null? xs) #f]
        ;; Literal character match
        [(char=? (car ps) (car xs))
         (loop (cdr ps) (cdr xs))]
        ;; No match
        [else #f])))

  ;; --- Check if path matches any exclude glob ---
  (def (config-excluded? config path)
    (any (lambda (glob) (glob-match? glob path))
         (gitsafe-config-exclude-globs config)))

  ;; --- Parse severity string to symbol ---
  (def (parse-severity s)
    (match s
      ["low"      'low]
      ["medium"   'medium]
      ["high"     'high]
      ["critical" 'critical]
      [_          'medium]))

  ;; --- Parse a JSON value as a list of strings ---
  (def (json->string-list v)
    (if (vector? v)
      (filter string? (vector->list v))
      '()))

  ;; --- Load config from file ---
  (def (load-config (path ".gitsafe.json"))
    (if (not (file-exists? path))
      (default-config)
      (try
        (let* ([content  (read-file-string path)]
               [obj      (string->json-object content)]
               [severity (parse-severity
                           (hash-ref obj "severity" "medium"))]
               [entropy  (let ([v (hash-ref obj "entropy" #t)])
                           (if (boolean? v) v #t))]
               [patterns-obj (hash-ref obj "patterns" #f)]
               [disabled (if (and patterns-obj
                                  (hash-key? patterns-obj "disabled"))
                           (map string->symbol
                                (json->string-list
                                  (hash-ref patterns-obj "disabled" (vector))))
                           '())]
               [custom   (if (and patterns-obj
                                  (hash-key? patterns-obj "custom"))
                           (let ([cv (hash-ref patterns-obj "custom" (vector))])
                             (if (vector? cv)
                               (vector->list cv)
                               '()))
                           '())]
               [excludes (json->string-list (hash-ref obj "exclude" (vector)))]
               [allowlist-obj (hash-ref obj "allowlist" #f)]
               [al-files (if allowlist-obj
                           (json->string-list
                             (hash-ref allowlist-obj "files" (vector)))
                           '())]
               [al-strs  (if allowlist-obj
                           (json->string-list
                             (hash-ref allowlist-obj "patterns" (vector)))
                           '())])
          (make-gitsafe-config
            severity entropy disabled custom
            excludes al-files al-strs))
        (catch (e)
          (displayln "gitsafe: warning: could not parse .gitsafe.json, using defaults")
          (default-config)))))

) ;; end library
