#!chezscheme
;; Build gitsafe as a maximally-static macOS binary.
;;
;; Usage: make macos
;;   (runs via build-gitsafe-macos.sh -> this script)
;;
;; Statically links: Chez kernel, lz4, zlib, ncurses
;; Dynamically links: libSystem (always present), libiconv
;;
;; macOS does not support fully static binaries (Apple linker requires
;; libSystem.B.dylib), but this binary has zero third-party runtime deps.
;;
;; Produces: ./gitsafe-macos (single Mach-O binary, self-contained)

(import (chezscheme))

;; --- Helper: generate C byte-array from binary file ---
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

;; --- Locate Chez install directory ---
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

(define chez-dir
  (or (getenv "CHEZ_DIR")
      (let ([mt   (symbol->string (machine-type))]
            [home (getenv "HOME")])
        (or (find-csv-dir (format "~a/.local/lib" home) mt)
            (find-csv-dir "/opt/homebrew/lib" mt)
            (find-csv-dir "/usr/local/lib" mt)))))

(unless chez-dir
  (display "Error: Cannot find Chez install dir. Set CHEZ_DIR.\n")
  (exit 1))

;; --- Locate Jerboa ---
(define home (getenv "HOME"))
(define jerboa-dir
  (or (getenv "JERBOA_HOME")
      (let ([sibling (format "~a/../jerboa" (current-directory))])
        (and (file-exists? sibling) sibling))
      (begin
        (display "Error: Cannot find Jerboa. Set JERBOA_HOME.\n")
        (exit 1))))

(printf "=== gitsafe macOS build ===\n")
(printf "Chez dir:      ~a\n" chez-dir)
(printf "Jerboa dir:    ~a\n" jerboa-dir)
(printf "Machine type:  ~a\n" (machine-type))

;; Add library paths
(library-directories
  (append
    (list (cons (current-directory) (current-directory))
          (cons (format "~a/lib" jerboa-dir)
                (format "~a/lib" jerboa-dir)))
    (library-directories)))

;; --- Step 1: Compile all modules (optimize-level 3, WPO) ---
(printf "\n[1/6] Compiling all modules (optimize-level 3, WPO)...\n")
(parameterize ([compile-imported-libraries  #t]
               [optimize-level              3]
               [cp0-effort-limit            500]
               [cp0-score-limit             50]
               [cp0-outer-unroll-limit      1]
               [commonization-level         4]
               [enable-unsafe-application   #t]
               [enable-unsafe-variable-reference #t]
               [enable-arithmetic-left-associative #t]
               [debug-level                 0]
               [generate-inspector-information #f]
               [generate-wpo-files          #t])
  (compile-program "gitsafe/main-binary.ss"))

;; --- Step 2: Whole-program optimization ---
(printf "[2/6] Running whole-program optimization...\n")
(let ([missing (compile-whole-program "gitsafe/main-binary.wpo" "gitsafe-all.so")])
  (unless (null? missing)
    (printf "  WPO: ~a libraries not incorporated (missing .wpo):\n" (length missing))
    (for-each (lambda (lib) (printf "    ~a\n" lib)) missing)))

;; --- Step 3: Create boot file + C headers ---
(printf "[3/6] Creating boot file and C headers...\n")

(define (existing-so-files paths)
  (filter file-exists? paths))

;; Standard library modules that WPO can't inline (no .wpo files).
;; These must be included in the boot file so the binary is self-contained.
;; Order matters: dependencies before dependents.
(define jerboa-std-modules
  (map (lambda (m) (format "~a/lib/~a.so" jerboa-dir m))
    '("std/pregexp"
      "std/os/path"
      "std/text/json"
      "std/misc/list"
      "std/misc/process"
      "std/misc/ports"
      "std/misc/string"
      "jerboa/runtime")))

(define gitsafe-modules
  '("gitsafe/entropy"
    "gitsafe/config"
    "gitsafe/allowlist"
    "gitsafe/patterns"
    "gitsafe/git"
    "gitsafe/scanner"
    "gitsafe/output"))

(apply make-boot-file "gitsafe.boot" '("scheme" "petite")
  (append
    (existing-so-files jerboa-std-modules)
    (existing-so-files
      (map (lambda (m) (format "~a.so" m)) gitsafe-modules))))

(file->c-header "gitsafe-all.so"
                "gitsafe_program.h"
                "gitsafe_program_data" "gitsafe_program_size")
(file->c-header (format "~a/petite.boot" chez-dir)
                "gitsafe_petite_boot.h"
                "petite_boot_data" "petite_boot_size")
(file->c-header (format "~a/scheme.boot" chez-dir)
                "gitsafe_scheme_boot.h"
                "scheme_boot_data" "scheme_boot_size")
(file->c-header "gitsafe.boot"
                "gitsafe_boot.h"
                "gitsafe_boot_data" "gitsafe_boot_size")

;; --- Step 4: Generate C main ---
(printf "[4/6] Generating C main...\n")

(call-with-output-file "gitsafe-main-macos.c"
  (lambda (out)
    (fprintf out "/* Auto-generated — do not edit */\n")
    (fprintf out "#include <stdlib.h>\n")
    (fprintf out "#include <stdio.h>\n")
    (fprintf out "#include <string.h>\n")
    (fprintf out "#include <unistd.h>\n")
    (fprintf out "#include \"scheme.h\"\n")
    (fprintf out "#include \"gitsafe_petite_boot.h\"\n")
    (fprintf out "#include \"gitsafe_scheme_boot.h\"\n")
    (fprintf out "#include \"gitsafe_boot.h\"\n")
    (fprintf out "#include \"gitsafe_program.h\"\n")
    (fprintf out "\n")
    (fprintf out "int main(int argc, char *argv[]) {\n")
    (fprintf out "  char prog_path[256];\n")
    (fprintf out "  const char *tmpdir = getenv(\"TMPDIR\");\n")
    (fprintf out "  if (!tmpdir) tmpdir = \"/tmp\";\n")
    (display  "  snprintf(prog_path, sizeof(prog_path), \"%s/gitsafe-XXXXXX\", tmpdir);\n" out)
    (fprintf out "  int fd = mkstemp(prog_path);\n")
    (fprintf out "  if (fd < 0) { perror(\"mkstemp\"); return 1; }\n")
    (fprintf out "  if (write(fd, gitsafe_program_data, gitsafe_program_size)\n")
    (fprintf out "      != (ssize_t)gitsafe_program_size) {\n")
    (fprintf out "    perror(\"write\"); close(fd); unlink(prog_path); return 1;\n")
    (fprintf out "  }\n")
    (fprintf out "  close(fd);\n")
    (fprintf out "\n")
    (fprintf out "  Sscheme_init(NULL);\n")
    (fprintf out "  Sregister_boot_file_bytes(\"petite\", (void*)petite_boot_data, petite_boot_size);\n")
    (fprintf out "  Sregister_boot_file_bytes(\"scheme\", (void*)scheme_boot_data, scheme_boot_size);\n")
    (fprintf out "  Sregister_boot_file_bytes(\"gitsafe\", (void*)gitsafe_boot_data, gitsafe_boot_size);\n")
    (fprintf out "  Sbuild_heap(NULL, NULL);\n")
    (fprintf out "  int status = Sscheme_script(prog_path, argc, (const char **)argv);\n")
    (fprintf out "  unlink(prog_path);\n")
    (fprintf out "  Sscheme_deinit();\n")
    (fprintf out "  return status;\n")
    (fprintf out "}\n"))
  'replace)

;; --- Step 5: Compile and link (maximally static) ---
(printf "[5/6] Compiling and linking (maximally static)...\n")

;; Find static .a archives bundled with Chez
(define kernel-a (format "~a/libkernel.a" chez-dir))
(define chez-lz4-a (format "~a/liblz4.a" chez-dir))
(define chez-z-a (format "~a/libz.a" chez-dir))

;; Verify Chez static libs exist
(for-each
  (lambda (pair)
    (unless (file-exists? (cdr pair))
      (printf "Error: ~a not found at ~a\n" (car pair) (cdr pair))
      (exit 1)))
  (list (cons "libkernel.a" kernel-a)
        (cons "liblz4.a" chez-lz4-a)
        (cons "libz.a" chez-z-a)))

;; Find ncurses static lib (from homebrew or env)
(define ncurses-a
  (or (let ([p (getenv "NCURSES_STATIC_PATH")])
        (and p (> (string-length p) 0) (file-exists? p) p))
      (let ([p "/opt/homebrew/opt/ncurses/lib/libncurses.a"])
        (and (file-exists? p) p))
      (let ([p "/usr/local/opt/ncurses/lib/libncurses.a"])
        (and (file-exists? p) p))))

(printf "  Static libs:\n")
(printf "    kernel:  ~a\n" kernel-a)
(printf "    lz4:     ~a\n" chez-lz4-a)
(printf "    zlib:    ~a\n" chez-z-a)
(printf "    ncurses: ~a\n" (or ncurses-a "(dynamic fallback)"))

;; Build link command: static .a files + system dynamic libs
(define static-libs
  (string-append
    kernel-a " " chez-lz4-a " " chez-z-a
    (if ncurses-a (string-append " " ncurses-a) "")))

(define dynamic-libs
  (string-append
    (if ncurses-a "" " -lncurses")
    " -liconv -lpthread -lm"))

(let ([cc (or (getenv "CC") "cc")])
  ;; Compile
  (let ([rc (system (format "~a -c -O2 -I~a -o gitsafe-main-macos.o gitsafe-main-macos.c"
                            cc chez-dir))])
    (unless (= rc 0) (printf "Error: C compilation failed\n") (exit 1)))
  ;; Link: our main + static archives + system dylibs
  ;; Note: Chez main.o is NOT included — it contains its own main() entry point.
  ;; We provide our own main() that sets up embedded boot files.
  (let* ([cmd (format "~a -o gitsafe-macos gitsafe-main-macos.o ~a~a"
                      cc static-libs dynamic-libs)])
    (printf "  Link: ~a\n" cmd)
    (let ([rc (system cmd)])
      (unless (= rc 0) (printf "Error: linking failed\n") (exit 1)))))

;; Strip
(printf "  Stripping binary...\n")
(system "strip -x gitsafe-macos")

;; SHA256
(system "shasum -a 256 gitsafe-macos > gitsafe-macos.sha256")

;; --- Step 6: Cleanup ---
(printf "[6/6] Cleaning up intermediate files...\n")
(for-each (lambda (f) (when (file-exists? f) (delete-file f)))
  '("gitsafe-main-macos.c" "gitsafe-main-macos.o"
    "gitsafe_program.h" "gitsafe_petite_boot.h"
    "gitsafe_scheme_boot.h" "gitsafe_boot.h"
    "gitsafe-all.so" "gitsafe.boot"
    "gitsafe/main-binary.wpo" "gitsafe/main-binary.so"))

(for-each (lambda (m)
            (for-each (lambda (ext)
                        (let ([f (format "~a~a" m ext)])
                          (when (file-exists? f) (delete-file f))))
                      '(".so" ".wpo")))
          gitsafe-modules)

(printf "\nDone! Binary: ./gitsafe-macos\n")
(printf "  Size:   ")
(system "ls -lh gitsafe-macos | awk '{print $5}'")
(printf "  SHA256: ")
(system "cat gitsafe-macos.sha256")
(printf "\n  Test:   ./gitsafe-macos --version\n")
(printf "  Deps:   otool -L gitsafe-macos\n")
