#!chezscheme
;; Build gitsafe as a fully static binary using musl libc.
;;
;; Usage: make gitsafe-musl-local
;;   (runs via build-gitsafe-musl.sh → this script)
;;
;; Prerequisites:
;;   - musl-gcc installed (apt install musl-tools)
;;   - Chez Scheme built with: ./configure --threads --static CC=musl-gcc
;;     installed to ~/chez-musl (or set JERBOA_MUSL_CHEZ_PREFIX)
;;   - Stock scheme (glibc) for compilation steps
;;
;; Produces: ./gitsafe-musl (fully static ELF binary, zero runtime dependencies)

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

;; --- Locate musl-built Chez Scheme ---
(define musl-chez-prefix
  (or (getenv "JERBOA_MUSL_CHEZ_PREFIX")
      (let* ([home (getenv "HOME")]
             [p (format "~a/chez-musl" home)])
        (and (file-exists? p) p))))

(unless musl-chez-prefix
  (display "Error: Cannot find musl Chez install.\n")
  (display "  Set JERBOA_MUSL_CHEZ_PREFIX or install to ~/chez-musl\n")
  (display "  See: https://github.com/ober/ChezScheme (build with --static CC=musl-gcc)\n")
  (exit 1))

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

(define musl-chez-dir
  (let ([mt (symbol->string (machine-type))])
    (or (find-csv-dir (format "~a/lib" musl-chez-prefix) mt)
        (begin
          (printf "Error: Cannot find Chez ~a dir under ~a/lib\n"
                  (machine-type) musl-chez-prefix)
          (printf "  Expected: ~a/lib/csv<version>/~a/main.o\n"
                  musl-chez-prefix mt)
          (exit 1)))))

;; --- Locate Jerboa ---
(define home (getenv "HOME"))
(define jerboa-dir
  (or (getenv "JERBOA_HOME")
      (let ([sibling (format "~a/../jerboa" (current-directory))])
        (and (file-exists? sibling) sibling))
      (begin
        (display "Error: Cannot find Jerboa. Set JERBOA_HOME.\n")
        (exit 1))))

(printf "=== gitsafe musl static build ===\n")
(printf "Musl Chez dir: ~a\n" musl-chez-dir)
(printf "Jerboa dir:    ~a\n" jerboa-dir)
(printf "Machine type:  ~a\n" (machine-type))

;; Add library paths (stock Chez for compilation)
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

(define gitsafe-modules
  '("gitsafe/entropy"
    "gitsafe/config"
    "gitsafe/allowlist"
    "gitsafe/patterns"
    "gitsafe/git"
    "gitsafe/scanner"
    "gitsafe/output"))

(apply make-boot-file "gitsafe.boot" '("scheme" "petite")
  (existing-so-files
    (map (lambda (m) (format "~a.so" m)) gitsafe-modules)))

;; Embed musl Chez boot files (must match musl kernel for ABI compatibility)
(file->c-header "gitsafe-all.so"
                "gitsafe_program.h"
                "gitsafe_program_data" "gitsafe_program_size")
(file->c-header (format "~a/petite.boot" musl-chez-dir)
                "gitsafe_petite_boot.h"
                "petite_boot_data" "petite_boot_size")
(file->c-header (format "~a/scheme.boot" musl-chez-dir)
                "gitsafe_scheme_boot.h"
                "scheme_boot_data" "scheme_boot_size")
(file->c-header "gitsafe.boot"
                "gitsafe_boot.h"
                "gitsafe_boot_data" "gitsafe_boot_size")

;; --- Step 4: Generate C main with embedded program ---
(printf "[4/6] Generating C main...\n")

(call-with-output-file "gitsafe-main-musl.c"
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
    ;; dlopen/dlsym stubs for fully static musl build.
    ;;
    ;; dlopen(NULL, ...) returns a fake self-handle so Chez can query its own
    ;; symbol table. All other dlopen calls return NULL, causing
    ;; (load-shared-object "libjerboa_native.so") in (std regex) to throw an
    ;; exception that the guard catches → native-available? = #f → all regex
    ;; falls back to the pure-Scheme pregexp engine.
    ;;
    ;; dlsym returns a harmless stub for the three known regex foreign-procedure
    ;; symbols in case Chez resolves them eagerly on this build (empirically
    ;; it can). The stub returns -1 but is never called because native-available?
    ;; = #f prevents any code path that would invoke c-native-compile/find/free.
    (fprintf out "/* dlopen/dlsym stubs — fully static musl binary, no dynamic libraries */\n")
    (fprintf out "static int _jerboa_native_stub(void) { return -1; }\n")
    (fprintf out "void *dlopen(const char *f, int m) { (void)m; return (!f) ? (void*)1 : NULL; }\n")
    (fprintf out "void *dlsym(void *h, const char *s) {\n")
    (fprintf out "  (void)h;\n")
    (fprintf out "  if (s && (strcmp(s, \"jerboa_regex_compile\") == 0 ||\n")
    (fprintf out "            strcmp(s, \"jerboa_regex_find\") == 0 ||\n")
    (fprintf out "            strcmp(s, \"jerboa_regex_free\") == 0))\n")
    (fprintf out "    return (void *)_jerboa_native_stub;\n")
    (fprintf out "  return NULL;\n")
    (fprintf out "}\n")
    (fprintf out "int dlclose(void *h) { (void)h; return 0; }\n")
    (fprintf out "char *dlerror(void) { return \"static build\"; }\n")
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
    ;; Sforeign_symbol MUST be called after Sbuild_heap (foreign entry table is
    ;; not initialized until then). We register the three Rust regex symbols with
    ;; a harmless C stub so that (std regex)'s (foreign-procedure ...) definitions
    ;; succeed when the WPO program initializes. The stub returns -1 but is never
    ;; called: dlopen("libjerboa_native.so") returns NULL (our stub), so
    ;; native-available? = #f, which prevents any call to c-native-compile/find/free.
    (fprintf out "  /* Register regex native symbols AFTER Sbuild_heap */\n")
    (fprintf out "  Sforeign_symbol(\"jerboa_regex_compile\", (void *)_jerboa_native_stub);\n")
    (fprintf out "  Sforeign_symbol(\"jerboa_regex_find\",    (void *)_jerboa_native_stub);\n")
    (fprintf out "  Sforeign_symbol(\"jerboa_regex_free\",    (void *)_jerboa_native_stub);\n")
    (fprintf out "  int status = Sscheme_script(prog_path, argc, (const char **)argv);\n")
    (fprintf out "  unlink(prog_path);\n")
    (fprintf out "  Sscheme_deinit();\n")
    (fprintf out "  return status;\n")
    (fprintf out "}\n"))
  'replace)

;; --- Step 5: Compile and link with musl-gcc ---
(printf "[5/6] Compiling and linking with musl-gcc (static)...\n")

(define link-libs "-lkernel -llz4 -lz -lm -ldl -lpthread")

(let ([rc (system (format "musl-gcc -c -O2 -I~a -o gitsafe-main-musl.o gitsafe-main-musl.c"
                          musl-chez-dir))])
  (unless (= rc 0) (printf "Error: C compilation failed\n") (exit 1)))

(let ([rc (system (format "musl-gcc -o gitsafe-musl gitsafe-main-musl.o -L~a ~a -static -Wl,--allow-multiple-definition"
                          musl-chez-dir link-libs))])
  (unless (= rc 0) (printf "Error: linking failed\n") (exit 1)))

;; Strip and generate integrity hash
(printf "  Stripping binary...\n")
(system "strip --strip-all gitsafe-musl")
(system "sha256sum gitsafe-musl > gitsafe-musl.sha256")

;; --- Step 6: Cleanup ---
(printf "[6/6] Cleaning up intermediate files...\n")
(for-each (lambda (f) (when (file-exists? f) (delete-file f)))
  '("gitsafe-main-musl.c" "gitsafe-main-musl.o"
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

(printf "\nDone! Binary: ./gitsafe-musl\n")
(printf "  Size:   ")
(system "ls -lh gitsafe-musl | awk '{print $5}'")
(printf "  SHA256: ")
(system "cat gitsafe-musl.sha256")
(printf "\n  Test:   ./gitsafe-musl --version\n")
(printf "  Verify: file gitsafe-musl && ldd gitsafe-musl\n")
