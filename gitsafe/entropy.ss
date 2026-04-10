#!chezscheme
(library (gitsafe entropy)
  (export shannon-entropy
          high-entropy?
          string-charset
          *entropy-threshold-hex*
          *entropy-threshold-base64*
          *entropy-threshold-generic*)
  (import (except (chezscheme)
                  make-hash-table hash-table?
                  sort sort!
                  printf fprintf
                  path-extension path-absolute?
                  with-input-from-string with-output-to-string
                  iota 1+ 1-
                  partition
                  make-date make-time)
          (jerboa prelude))

  ;; --- Thresholds ---
  (def *entropy-threshold-hex*     3.0)
  (def *entropy-threshold-base64*  4.0)
  (def *entropy-threshold-generic* 4.5)

  ;; Shannon entropy of a string (bits per character).
  ;; Returns a flonum in [0.0, ~6.0] for printable ASCII.
  ;; Safe for Unicode — uses hash table for frequency counts.
  (def (shannon-entropy str)
    (let ([len (string-length str)])
      (if (= len 0)
        0.0
        (let ([freqs (make-hash-table)])
          ;; Count character frequencies
          (let loop ([i 0])
            (when (< i len)
              (let ([b (char->integer (string-ref str i))])
                (hash-put! freqs b (+ 1 (hash-ref freqs b 0))))
              (loop (+ i 1))))
          ;; Calculate entropy: sum of -p*log2(p)
          (let ([n (inexact len)])
            (let loop ([vals (hash-values freqs)] [entropy 0.0])
              (if (null? vals)
                entropy
                (let ([p (/ (inexact (car vals)) n)])
                  (loop (cdr vals) (- entropy (* p (log p 2))))))))))))

  ;; Check if a string exceeds the entropy threshold.
  (def (high-entropy? str (threshold *entropy-threshold-generic*))
    (> (shannon-entropy str) threshold))

  ;; Classify the character set of a string.
  ;; Returns: 'hex | 'base64 | 'alphanumeric | 'printable | 'mixed
  (def (string-charset str)
    (let ([len (string-length str)])
      (if (= len 0)
        'empty
        (let loop ([i 0] [is-hex #t] [is-b64 #t] [is-alnum #t] [is-printable #t])
          (if (>= i len)
            (cond
              [is-hex        'hex]
              [is-b64        'base64]
              [is-alnum      'alphanumeric]
              [is-printable  'printable]
              [else          'mixed])
            (let ([c (string-ref str i)])
              (let ([hex?   (or (char<=? #\0 c #\9)
                                (char<=? #\a c #\f)
                                (char<=? #\A c #\F))]
                    [b64?   (or (char<=? #\A c #\Z)
                                (char<=? #\a c #\z)
                                (char<=? #\0 c #\9)
                                (char=? c #\+) (char=? c #\/)
                                (char=? c #\=))]
                    [alnum? (or (char<=? #\A c #\Z)
                                (char<=? #\a c #\z)
                                (char<=? #\0 c #\9))]
                    [print? (and (char>=? c #\space) (char<? c #\delete))])
                (loop (+ i 1)
                      (and is-hex hex?)
                      (and is-b64 b64?)
                      (and is-alnum alnum?)
                      (and is-printable print?)))))))))

) ;; end library
