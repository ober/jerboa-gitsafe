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

;; Load shared build logic (defines find-csv-dir and all step functions).
;; jerboa-dir must be defined before any of the shared step functions are CALLED
;; (not before this include — lambdas capture it lazily).
(include "build-common.ss")

;; --- Locate Chez install directory (macOS) ---
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

;; --- Steps 0–3: shared compile + WPO + boot file ---
(setup-library-dirs!)
(do-compile!)
(define wpo-missing (do-wpo!))
(do-boot! wpo-missing chez-dir)

;; --- Step 4: Generate C main (macOS — no dlopen stubs needed) ---
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

;; --- Step 5: Compile and link (maximally static, macOS) ---
(printf "[5/6] Compiling and linking (maximally static)...\n")

(define kernel-a (format "~a/libkernel.a" chez-dir))
(define chez-lz4-a (format "~a/liblz4.a" chez-dir))
(define chez-z-a (format "~a/libz.a" chez-dir))

(for-each
  (lambda (pair)
    (unless (file-exists? (cdr pair))
      (printf "Error: ~a not found at ~a\n" (car pair) (cdr pair))
      (exit 1)))
  (list (cons "libkernel.a" kernel-a)
        (cons "liblz4.a" chez-lz4-a)
        (cons "libz.a" chez-z-a)))

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

(define static-libs
  (string-append
    kernel-a " " chez-lz4-a " " chez-z-a
    (if ncurses-a (string-append " " ncurses-a) "")))

(define dynamic-libs
  (string-append
    (if ncurses-a "" " -lncurses")
    " -liconv -lpthread -lm"))

(let ([cc (or (getenv "CC") "cc")])
  (let ([rc (system (format "~a -c -O2 -I~a -o gitsafe-main-macos.o gitsafe-main-macos.c"
                            cc chez-dir))])
    (unless (= rc 0) (printf "Error: C compilation failed\n") (exit 1)))
  (let* ([cmd (format "~a -o gitsafe-macos gitsafe-main-macos.o ~a~a"
                      cc static-libs dynamic-libs)])
    (printf "  Link: ~a\n" cmd)
    (let ([rc (system cmd)])
      (unless (= rc 0) (printf "Error: linking failed\n") (exit 1)))))

(printf "  Stripping binary...\n")
(system "strip -x gitsafe-macos")
(system "shasum -a 256 gitsafe-macos > gitsafe-macos.sha256")

;; --- Step 6: Cleanup ---
(do-cleanup! "macos")

(printf "\nDone! Binary: ./gitsafe-macos\n")
(printf "  Size:   ")
(system "ls -lh gitsafe-macos | awk '{print $5}'")
(printf "  SHA256: ")
(system "cat gitsafe-macos.sha256")
(printf "\n  Test:   ./gitsafe-macos --version\n")
(printf "  Deps:   otool -L gitsafe-macos\n")
