;; build-common.ss — shared build logic for all gitsafe static binary builds.
;;
;; Include this file via (include "build-common.ss") AFTER defining:
;;   jerboa-dir  — absolute path to the Jerboa home directory
;;
;; Provides helpers, the gitsafe module list, and the six shared build steps:
;;   setup-library-dirs!   — Step 0: add jerboa lib to search path
;;   do-compile!           — Step 1: compile all modules with WPO
;;   do-wpo!               — Step 2: whole-program optimization (returns wpo-missing)
;;   do-boot!              — Step 3: make boot file + C headers
;;   do-cleanup!           — Step 6: remove intermediate files
;;
;; Steps 4 (generate C main) and 5 (compile + link) are platform-specific
;; and live in the including script.

;; --- C byte-array header generation ---
(define (file->c-header input-path output-path array-name size-name)
  (let* ([port (open-file-input-port input-path)]
         [data (get-bytevector-all port)]
         [size (bytevector-length data)])
    (close-port port)
    (call-with-output-file output-path
      (lambda (out)
        (fprintf out "/* Auto-generated — do not edit */\n")
        (fprintf out "static const unsigned char ~a[] = {\n" array-name)
        (let loop ([i 0])
          (when (< i size)
            (when (= 0 (modulo i 16)) (fprintf out "  "))
            (fprintf out "0x~2,'0x" (bytevector-u8-ref data i))
            (when (< (+ i 1) size) (fprintf out ","))
            (when (= 15 (modulo i 16)) (fprintf out "\n"))
            (loop (+ i 1))))
        (fprintf out "\n};\n")
        (fprintf out "static const unsigned int ~a = ~a;\n" size-name size))
      'replace)
    (printf "  ~a: ~a bytes\n" output-path size)))

;; --- Find the csv<version>/<machine-type> dir inside a Chez lib directory ---
(define (find-csv-dir lib-dir mt)
  (let ([csv-dir
          (let lp ([dirs (guard (e [#t '()]) (directory-list lib-dir))])
            (cond
              [(null? dirs) #f]
              [(and (> (string-length (car dirs)) 3)
                    (string=? "csv" (substring (car dirs) 0 3)))
               (format "~a/~a/~a" lib-dir (car dirs) mt)]
              [else (lp (cdr dirs))]))])
    (and csv-dir
         (file-exists? (format "~a/main.o" csv-dir))
         csv-dir)))

;; --- Filter a path list to files that actually exist ---
(define (existing-so-files paths)
  (filter file-exists? paths))

;; --- Convert a library name to its .so path under jerboa-dir ---
;; e.g. (std misc string) → <jerboa-dir>/lib/std/misc/string.so
;; References `jerboa-dir` from the including script's scope.
(define (lib-name->so-path lib-name)
  (let* ([parts (map symbol->string lib-name)]
         [rel   (let loop ([ps parts] [acc ""])
                  (if (null? ps)
                    acc
                    (loop (cdr ps)
                          (if (string=? acc "")
                            (car ps)
                            (string-append acc "/" (car ps))))))]
         [so    (format "~a/lib/~a.so" jerboa-dir rel)])
    (and (file-exists? so) so)))

;; --- gitsafe application modules (same on all platforms) ---
(define gitsafe-modules
  '("gitsafe/entropy"
    "gitsafe/config"
    "gitsafe/allowlist"
    "gitsafe/patterns"
    "gitsafe/git"
    "gitsafe/scanner"
    "gitsafe/output"))

;; --- Step 0: add library search paths ---
(define (setup-library-dirs!)
  (library-directories
    (append
      (list (cons (current-directory) (current-directory))
            (cons (format "~a/lib" jerboa-dir)
                  (format "~a/lib" jerboa-dir)))
      (library-directories))))

;; --- Step 1: compile all modules (optimize-level 3, WPO) ---
(define (do-compile!)
  (printf "\n[1/6] Compiling all modules (optimize-level 3, WPO)...\n")
  (parameterize ([compile-imported-libraries         #t]
                 [optimize-level                     3]
                 [cp0-effort-limit                   500]
                 [cp0-score-limit                    50]
                 [cp0-outer-unroll-limit             1]
                 [commonization-level                4]
                 [enable-unsafe-application          #t]
                 [enable-unsafe-variable-reference   #t]
                 [enable-arithmetic-left-associative #t]
                 [debug-level                        0]
                 [generate-inspector-information     #f]
                 [generate-wpo-files                 #t])
    (compile-program "gitsafe/main-binary.ss")))

;; --- Step 2: whole-program optimization ---
;; Returns the list of libraries not incorporated (no .wpo file available).
;; The caller passes this to do-boot! so they are bundled as .so files instead.
(define (do-wpo!)
  (printf "[2/6] Running whole-program optimization...\n")
  (let ([wpo-missing (compile-whole-program "gitsafe/main-binary.wpo" "gitsafe-all.so")])
    (unless (null? wpo-missing)
      (printf "  WPO: ~a libraries not incorporated (missing .wpo) — will bundle .so files:\n"
              (length wpo-missing))
      (for-each (lambda (lib) (printf "    ~a\n" lib)) wpo-missing))
    wpo-missing))

;; --- Step 3: create boot file and C headers ---
;; wpo-missing  — list returned by do-wpo!
;; chez-boot-dir — directory containing petite.boot and scheme.boot
;;                 (the platform Chez install dir, NOT necessarily the host Chez)
(define (do-boot! wpo-missing chez-boot-dir)
  (printf "[3/6] Creating boot file and C headers...\n")
  ;; Find .so files for any stdlib lib that WPO couldn't inline.
  (let ([missing-sos
         (let loop ([libs wpo-missing] [acc '()])
           (if (null? libs)
             (reverse acc)
             (let ([so (lib-name->so-path (car libs))])
               (loop (cdr libs) (if so (cons so acc) acc)))))])
    (when (not (null? missing-sos))
      (printf "  Bundling ~a stdlib .so files into boot image.\n" (length missing-sos)))
    (apply make-boot-file "gitsafe.boot" '("scheme" "petite")
      (existing-so-files
        (append
          (map (lambda (m) (format "~a.so" m)) gitsafe-modules)
          missing-sos))))
  (file->c-header "gitsafe-all.so"
                  "gitsafe_program.h"
                  "gitsafe_program_data" "gitsafe_program_size")
  (file->c-header (format "~a/petite.boot" chez-boot-dir)
                  "gitsafe_petite_boot.h"
                  "petite_boot_data" "petite_boot_size")
  (file->c-header (format "~a/scheme.boot" chez-boot-dir)
                  "gitsafe_scheme_boot.h"
                  "scheme_boot_data" "scheme_boot_size")
  (file->c-header "gitsafe.boot"
                  "gitsafe_boot.h"
                  "gitsafe_boot_data" "gitsafe_boot_size"))

;; --- Step 6: remove intermediate files ---
;; platform: "macos" or "musl" — determines the C source/object file names
(define (do-cleanup! platform)
  (printf "[6/6] Cleaning up intermediate files...\n")
  (for-each (lambda (f) (when (file-exists? f) (delete-file f)))
    (list (format "gitsafe-main-~a.c" platform)
          (format "gitsafe-main-~a.o" platform)
          "gitsafe_program.h" "gitsafe_petite_boot.h"
          "gitsafe_scheme_boot.h" "gitsafe_boot.h"
          "gitsafe-all.so" "gitsafe.boot"
          "gitsafe/main-binary.wpo" "gitsafe/main-binary.so"))
  (for-each (lambda (m)
              (for-each (lambda (ext)
                          (let ([f (format "~a~a" m ext)])
                            (when (file-exists? f) (delete-file f))))
                        '(".so" ".wpo")))
            gitsafe-modules))
