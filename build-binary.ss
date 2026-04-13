#!chezscheme
;; Build the gitsafe static binary.
;;
;; Usage: make binary
;;   (which runs: scheme --libdirs . --script build-binary.ss)
;;
;; Produces: ./gitsafe-bin (single ELF binary with embedded boot files + program)

(import (chezscheme))

;; --- Helper: generate C header from binary file ---
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

;; --- Detect OS ---
(define freebsd?
  (let ([mt (symbol->string (machine-type))])
    (or (string=? mt "ta6fb") (string=? mt "a6fb")
        (string=? mt "tarm64fb") (string=? mt "arm64fb"))))

(define macos?
  (let ([mt (symbol->string (machine-type))])
    (or (string=? mt "ta6osx") (string=? mt "a6osx")
        (string=? mt "tarm64osx") (string=? mt "arm64osx"))))

(define termux?
  (let ([p (getenv "PREFIX")])
    (and p (> (string-length p) 0)
         (file-exists? (string-append p "/bin/termux-info")))))

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
            (find-csv-dir "/usr/local/lib" mt)
            (find-csv-dir "/opt/homebrew/lib" mt)
            (find-csv-dir "/usr/lib" mt)
            (let ([p (getenv "PREFIX")])
              (and p (find-csv-dir (format "~a/lib" p) mt)))))))

(unless chez-dir
  (display "Error: Cannot find Chez install dir. Set CHEZ_DIR.\n")
  (exit 1))

(define home       (getenv "HOME"))
(define jerboa-dir
  (or (getenv "JERBOA_HOME")
      (let ([sibling (format "~a/../jerboa"
                       (current-directory))])
        (and (file-exists? sibling) sibling))
      (begin
        (display "Error: Cannot find Jerboa. Set JERBOA_HOME.\n")
        (exit 1))))

(printf "Chez dir:   ~a\n" chez-dir)
(printf "Jerboa dir: ~a\n" jerboa-dir)

;; Add library paths
(library-directories
  (append
    (list (cons (current-directory) (current-directory))
          (cons (format "~a/lib" jerboa-dir)
                (format "~a/lib" jerboa-dir)))
    (library-directories)))

;; --- Step 1: Compile all modules (optimize-level 3, WPO) ---
(printf "\n[1/5] Compiling all modules (optimize-level 3, WPO)...\n")
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
(printf "[2/5] Running whole-program optimization...\n")
(define wpo-missing
  (compile-whole-program "gitsafe/main-binary.wpo" "gitsafe-all.so"))
(unless (null? wpo-missing)
  (printf "  WPO: ~a libraries not incorporated (missing .wpo) — will bundle .so files:\n"
          (length wpo-missing))
  (for-each (lambda (lib) (printf "    ~a\n" lib)) wpo-missing))

;; --- Step 3: Create boot file + C headers ---
(printf "[3/5] Creating boot file and C headers...\n")

(define (existing-so-files paths)
  (filter file-exists? paths))

;; Convert a library name like (std misc string) → jerboa-dir/lib/std/misc/string.so
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

(define gitsafe-modules
  '("gitsafe/entropy"
    "gitsafe/config"
    "gitsafe/allowlist"
    "gitsafe/patterns"
    "gitsafe/git"
    "gitsafe/scanner"
    "gitsafe/output"))

;; Bundle both gitsafe modules and any stdlib .so files the WPO couldn't inline.
;; This makes gitsafe-bin self-contained without requiring Chez library paths at runtime.
(define missing-sos
  (let loop ([libs wpo-missing] [acc '()])
    (if (null? libs)
      (reverse acc)
      (let ([so (lib-name->so-path (car libs))])
        (loop (cdr libs) (if so (cons so acc) acc))))))

(when (not (null? missing-sos))
  (printf "  Bundling ~a stdlib .so files into boot image.\n" (length missing-sos)))

(apply make-boot-file "gitsafe.boot" '("scheme" "petite")
  (existing-so-files
    (append
      (map (lambda (m) (format "~a.so" m)) gitsafe-modules)
      missing-sos)))

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

;; --- Step 4: Generate C main, compile, and link ---
(printf "[4/5] Compiling and linking...\n")

(call-with-output-file "gitsafe-main.c"
  (lambda (out)
    (fprintf out "/* Auto-generated — do not edit */\n")
    (fprintf out "#define _GNU_SOURCE\n")
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
    (display "  snprintf(prog_path, sizeof(prog_path), \"%s/gitsafe-XXXXXX\", tmpdir);\n" out)
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

(define link-libs
  (cond
    [freebsd? "-lkernel -llz4 -lz -lm -lpthread -lncurses"]
    [macos?   "-lkernel -llz4 -lz -lm -lpthread -lncurses -liconv"]
    [termux?  "-lkernel -llz4 -lz -lm -ldl -lpthread -lncurses -liconv"]
    [else     "-lkernel -llz4 -lz -lm -ldl -lpthread -luuid -lncurses"]))

(let ([cc (or (getenv "CC") "cc")])
  (let ([rc (system (format "~a -c -I~a -o gitsafe-main.o gitsafe-main.c" cc chez-dir))])
    (unless (= rc 0) (printf "Error: C compilation failed\n") (exit 1)))
  (let ([rc (system (format "~a -o gitsafe-bin gitsafe-main.o -L~a ~a"
                            cc chez-dir link-libs))])
    (unless (= rc 0) (printf "Error: linking failed\n") (exit 1))))

;; --- Step 5: Cleanup ---
(printf "[5/5] Cleaning up intermediate files...\n")
(for-each (lambda (f) (when (file-exists? f) (delete-file f)))
  '("gitsafe-main.c" "gitsafe-main.o"
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

(printf "\nDone! Binary: ./gitsafe-bin\n")
(printf "  Install: make install\n")
