#!chezscheme
(library (gitsafe git)
  (export staged-files
          staged-diff
          staged-content
          push-commits
          changed-files-in-range
          range-diff
          git-repo?
          git-root
          make-diff-hunk
          diff-hunk?
          diff-hunk-file
          diff-hunk-old-start
          diff-hunk-new-start
          diff-hunk-lines)
  (import (except (chezscheme)
                  make-hash-table hash-table?
                  sort sort!
                  printf fprintf
                  path-extension path-absolute?
                  with-input-from-string with-output-to-string
                  iota 1+ 1-
                  partition
                  make-date make-time)
           (except (jerboa prelude) meta atom?)
          (std regex)
          (std misc process)
          (std misc string)
          (std misc ports))

  ;; --- Diff hunk struct ---
  (defstruct diff-hunk
    (file       ;; string: file path
     old-start  ;; integer: original line number start
     new-start  ;; integer: new line number start
     lines      ;; list of (line-number . content) pairs (added lines only)
     ))

  ;; --- Internal helpers ---

  ;; Run a git command and return trimmed stdout.
  ;; Returns "" on error (non-zero exit), but warns on stderr.
  (def (git-output args)
    (try
      (let ([out (run-process args)])
        (string-trim out))
      (catch (e)
        (let ([p (current-error-port)])
          (display "gitsafe: warning: git command failed: " p)
          (display (string-join args " ") p)
          (newline p))
        "")))

  ;; Run git command and return exit code.
  (def (git-exit args)
    (try
      (run-process/batch args)
      (catch (e) 1)))

  ;; Split a string on newlines and remove empty lines.
  (def (split-lines str)
    (filter (lambda (s) (not (string-empty? s)))
            (string-split str #\newline)))

  ;; --- Parse unified diff format ---
  ;; Returns list of diff-hunk structs from a git diff output string.
  ;; Only captures added lines (lines starting with +, not +++).
  (def *hunk-header-re*
    (re "^@@ -[0-9,]+ \\+([0-9]+)(?:,[0-9]+)? @@"))

  (def (parse-unified-diff diff-text current-file)
    (let loop ([lines (string-split diff-text #\newline)]
               [hunks '()]
               [cur-hunk #f]
               [new-line-no 0])
      (if (null? lines)
        ;; Flush last hunk
        (reverse (if (and cur-hunk
                          (not (null? (diff-hunk-lines cur-hunk))))
                   (cons cur-hunk hunks)
                   hunks))
        (let ([line (car lines)]
              [rest (cdr lines)])
          (cond
            ;; Hunk header: @@ -old,count +new,count @@
            [(re-search *hunk-header-re* line)
             =>
             (lambda (m)
               (let* ([new-start (string->number (re-match-group m 1))]
                      ;; Save previous hunk if it had findings
                      [hunks* (if (and cur-hunk
                                       (not (null? (diff-hunk-lines cur-hunk))))
                                (cons cur-hunk hunks)
                                hunks)])
                 (loop rest
                       hunks*
                       (make-diff-hunk current-file 0 new-start '())
                       new-start)))]
            ;; Added line (not +++ header)
            [(and cur-hunk
                  (> (string-length line) 0)
                  (char=? (string-ref line 0) #\+)
                  (not (string-prefix? "+++" line)))
             (let ([content (substring line 1 (string-length line))]
                   [ln      new-line-no])
               ;; Append line to current hunk
               (let ([updated-hunk
                      (make-diff-hunk
                        (diff-hunk-file cur-hunk)
                        (diff-hunk-old-start cur-hunk)
                        (diff-hunk-new-start cur-hunk)
                        (append (diff-hunk-lines cur-hunk)
                                (list (cons ln content))))])
                 (loop rest hunks updated-hunk (+ new-line-no 1))))]
            ;; Context line (space) — advance new-line counter
            [(and cur-hunk
                  (> (string-length line) 0)
                  (char=? (string-ref line 0) #\space))
             (loop rest hunks cur-hunk (+ new-line-no 1))]
            ;; Removed line (-) — don't advance new-line counter
            [(and cur-hunk
                  (> (string-length line) 0)
                  (char=? (string-ref line 0) #\-))
             (loop rest hunks cur-hunk new-line-no)]
            ;; Any other line (diff header, etc.)
            [else
             (loop rest hunks cur-hunk new-line-no)])))))

  ;; --- Public API ---

  ;; Returns #t if inside a git repository.
  (def (git-repo?)
    (= 0 (git-exit '("git" "rev-parse" "--git-dir"))))

  ;; Returns the absolute path to the repo root.
  (def (git-root)
    (git-output '("git" "rev-parse" "--show-toplevel")))

  ;; Returns list of staged file paths (files added/modified/renamed in index).
  (def (staged-files)
    (split-lines
      (git-output '("git" "diff" "--cached" "--name-only"
                    "--diff-filter=ACMR"))))

  ;; Returns a list of diff-hunk structs for a staged file.
  ;; Only includes added lines.
  (def (staged-diff path)
    (let ([diff-text (git-output
                       (list "git" "diff" "--cached" "-U0" "--" path))])
      (if (string-empty? diff-text)
        '()
        (parse-unified-diff diff-text path))))

  ;; Returns the full staged (index) content of a file.
  ;; This is what would be committed, not the working copy.
  (def (staged-content path)
    (try
      (run-process (list "git" "show" (string-append ":" path)))
      (catch (e) "")))

  ;; Returns list of commit SHAs being pushed (from remote-ref..local-ref).
  (def (push-commits local-ref remote-ref)
    (let ([range (string-append remote-ref ".." local-ref)])
      (split-lines
        (git-output (list "git" "rev-list" range)))))

  ;; Returns list of file paths changed in a commit range.
  (def (changed-files-in-range from-ref to-ref)
    (split-lines
      (git-output (list "git" "diff" "--name-only"
                        "--diff-filter=ACMR"
                        from-ref to-ref))))

  ;; Returns unified diff text for a file in a commit range.
  (def (range-diff from-ref to-ref path)
    (git-output (list "git" "diff" "-U0" from-ref to-ref "--" path)))

) ;; end library
