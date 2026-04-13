#!chezscheme
;; Build gitsafe as a fully static binary using musl libc.
;;
;; Usage: make linux-local
;;   (runs via build-gitsafe-musl.sh → this script)
;;
;; Prerequisites:
;;   - musl-gcc installed (apt install musl-tools)
;;   - Chez Scheme built with: ./configure --threads --static CC=musl-gcc
;;     installed to ~/chez-musl (or set JERBOA_MUSL_CHEZ_PREFIX)
;;   - Stock scheme (glibc) for the compilation steps
;;
;; Produces: ./gitsafe-musl (fully static ELF binary, zero runtime dependencies)

(import (chezscheme))

;; Load shared build logic (defines find-csv-dir and all step functions).
;; jerboa-dir must be defined before any of the shared step functions are CALLED
;; (not before this include — lambdas capture it lazily).
(include "build-common.ss")

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

;; --- Steps 0–3: shared compile + WPO + boot file ---
;; Boot files come from the musl Chez (ABI must match the musl kernel).
(setup-library-dirs!)
(do-compile!)
(define wpo-missing (do-wpo!))
(do-boot! wpo-missing musl-chez-dir)

;; --- Step 4: Generate C main (musl — with dlopen stubs + Sforeign_symbol) ---
;;
;; dlopen(NULL, ...) returns a fake self-handle so Chez can query its own
;; symbol table. All other dlopen calls return NULL, causing
;; (load-shared-object "libjerboa_native.so") in (std regex) to throw an
;; exception that the guard catches → native-available? = #f → all regex
;; falls back to the pure-Scheme pregexp engine.
;;
;; Sforeign_symbol MUST be called after Sbuild_heap (the foreign entry table
;; is not initialized until then). We register the three Rust regex symbols
;; with a harmless C stub so (std regex)'s (foreign-procedure ...) forms
;; succeed at WPO program init. The stub returns -1 but is never called
;; because native-available? = #f prevents all native regex code paths.
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

;; --- Step 5: Compile and link with musl-gcc (fully static) ---
(printf "[5/6] Compiling and linking with musl-gcc (static)...\n")

(define link-libs "-lkernel -llz4 -lz -lm -ldl -lpthread")

(let ([rc (system (format "musl-gcc -c -O2 -I~a -o gitsafe-main-musl.o gitsafe-main-musl.c"
                          musl-chez-dir))])
  (unless (= rc 0) (printf "Error: C compilation failed\n") (exit 1)))

(let ([rc (system (format "musl-gcc -o gitsafe-musl gitsafe-main-musl.o -L~a ~a -static -Wl,--allow-multiple-definition"
                          musl-chez-dir link-libs))])
  (unless (= rc 0) (printf "Error: linking failed\n") (exit 1)))

(printf "  Stripping binary...\n")
(system "strip --strip-all gitsafe-musl")
(system "sha256sum gitsafe-musl > gitsafe-musl.sha256")

;; --- Step 6: Cleanup ---
(do-cleanup! "musl")

(printf "\nDone! Binary: ./gitsafe-musl\n")
(printf "  Size:   ")
(system "ls -lh gitsafe-musl | awk '{print $5}'")
(printf "  SHA256: ")
(system "cat gitsafe-musl.sha256")
(printf "\n  Test:   ./gitsafe-musl --version\n")
(printf "  Verify: file gitsafe-musl && ldd gitsafe-musl\n")
