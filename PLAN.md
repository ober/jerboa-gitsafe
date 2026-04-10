# jerboa-gitsafe — Implementation Plan

A fast, intelligent git pre-commit/pre-push hook that detects leaked secrets, API keys, tokens, and credentials. Written in Jerboa Scheme, compiled to a fully static binary.

## Motivation

A model pulled API keys from `~/.local/opencode/auth.json` and committed them to a `jcode.json` in a public repository. Simple regex-based scanners (`grep -i password`) are insufficient — they produce false positives on variable names and miss high-entropy tokens that don't match keyword patterns. This tool combines **pattern matching**, **entropy analysis**, **known-format detection**, and **context-aware filtering** to catch real secrets while staying fast enough for a pre-commit hook.

---

## Architecture Overview

```
jerboa-gitsafe (static ELF binary, ~3-4 MB)
├── gitsafe/main-binary.ss       ← binary entry point (no library-directories)
├── gitsafe/main.ss              ← interpreter entry point (dev mode)
├── gitsafe/scanner.ss           ← core scanning engine
├── gitsafe/patterns.ss          ← secret pattern definitions
├── gitsafe/entropy.ss           ← Shannon entropy calculator
├── gitsafe/git.ss               ← git integration (diff parsing, staged files)
├── gitsafe/config.ss            ← .gitsafe.json config loading
├── gitsafe/output.ss            ← formatted output / reporting
├── gitsafe/allowlist.ss         ← .gitsafeignore / inline suppression
├── build-binary.ss              ← static binary build script
└── Makefile                     ← build orchestration
```

---

## Module Inventory

### 1. `gitsafe/main.ss` — Interpreter Entry Point

**Purpose:** Dev-mode entry point that sets up `library-directories` before imports.

**Imports:**
```scheme
(import (jerboa prelude))
;; then: (gitsafe scanner), (gitsafe git), (gitsafe config), (gitsafe output)
```

**CLI interface:**
```
gitsafe [MODE] [OPTIONS]

Modes:
  pre-commit       Scan staged files (default)
  pre-push         Scan commits being pushed
  scan [PATH...]   Scan specific files or directories
  install          Install git hooks into .git/hooks/
  uninstall        Remove git hooks

Options:
  --config PATH    Path to .gitsafe.json (default: .gitsafe.json in repo root)
  --format text|json   Output format (default: text)
  --severity LEVEL     Minimum severity to report: low|medium|high|critical (default: medium)
  --no-entropy         Disable entropy analysis (faster, less accurate)
  --verbose            Show skipped files and scan statistics
  --version            Print version
  --help               Print usage
```

**Argument parsing:** Use `(cdr (command-line))` and a manual `let loop` over args (same pattern as `jerboa-lsp/lsp/main-binary.ss:11-32`). No external arg-parsing library needed.

**Exit codes:**
- `0` — no secrets found
- `1` — secrets found (blocks commit/push)
- `2` — configuration or runtime error

### 2. `gitsafe/main-binary.ss` — Binary Entry Point

**Purpose:** Minimal entry point for the compiled static binary. No `library-directories` setup — everything is in the boot file.

```scheme
#!chezscheme
(import (chezscheme)
        (gitsafe scanner)
        (gitsafe git)
        (gitsafe config)
        (gitsafe output))
;; ... parse args, dispatch to mode ...
```

Follow the exact pattern from `jerboa-lsp/lsp/main-binary.ss`.

### 3. `gitsafe/patterns.ss` — Secret Pattern Definitions

**Purpose:** Define all known secret patterns with metadata. This is the intelligence layer.

**Imports:**
```scheme
(import (jerboa prelude)
        (std pregexp))
```

**Key data structure:**
```scheme
(defstruct secret-pattern
  (id           ;; symbol, e.g. 'aws-access-key
   name         ;; string, human-readable, e.g. "AWS Access Key ID"
   severity     ;; symbol: 'critical | 'high | 'medium | 'low
   pregexp      ;; compiled pregexp pattern (from (std pregexp))
   validator    ;; #f or (lambda (match-string) -> boolean) for post-match validation
   description  ;; string explaining what this catches
   ))
```

**Pattern categories to implement (each as a `secret-pattern` struct):**

#### Critical Severity
| ID | Name | Pattern (pregexp) | Validator |
|----|------|-------------------|-----------|
| `aws-access-key` | AWS Access Key ID | `"(?:^|[^A-Za-z0-9])(?:AKIA\|ABIA\|ACCA\|ASIA)[A-Z0-9]{16}(?:[^A-Za-z0-9]|$)"` | Check 20-char length |
| `aws-secret-key` | AWS Secret Access Key | `"(?:aws_secret_access_key\|aws_secret\|secret_key)\\s*[=:]\\s*[A-Za-z0-9/+=]{40}"` | Check base64 charset, length=40 |
| `github-pat` | GitHub PAT | `"gh[pousr]_[A-Za-z0-9_]{36,255}"` | prefix + length check |
| `github-fine-grained` | GitHub Fine-Grained PAT | `"github_pat_[A-Za-z0-9_]{22,255}"` | prefix check |
| `openai-api-key` | OpenAI API Key | `"sk-[A-Za-z0-9]{20}T3BlbkFJ[A-Za-z0-9]{20}"` | Check T3BlbkFJ marker |
| `openai-project-key` | OpenAI Project Key | `"sk-proj-[A-Za-z0-9_-]{40,200}"` | prefix check |
| `anthropic-api-key` | Anthropic API Key | `"sk-ant-[A-Za-z0-9_-]{90,110}"` | prefix + length range |
| `stripe-secret` | Stripe Secret Key | `"[sr]k_live_[A-Za-z0-9]{24,99}"` | prefix check |
| `private-key-pem` | Private Key (PEM) | `"-----BEGIN (RSA\|DSA\|EC\|OPENSSH\|PGP)? ?PRIVATE KEY-----"` | — |

#### High Severity
| ID | Name | Pattern | Validator |
|----|------|---------|-----------|
| `generic-api-key` | Generic API Key Assignment | `"(?i)(api[_-]?key\|apikey\|api[_-]?secret)\\s*[=:]\\s*[\"'][A-Za-z0-9_/+=.-]{16,}[\"']"` | Entropy > 3.5 on value |
| `generic-secret` | Generic Secret Assignment | `"(?i)(secret\|token\|password\|passwd\|credential)\\s*[=:]\\s*[\"'][^\"'\\s]{8,}[\"']"` | Entropy > 3.5 on value, not a placeholder |
| `generic-bearer` | Bearer Token in Code | `"(?i)bearer\\s+[A-Za-z0-9_.~+/=-]{20,}"` | Entropy check |
| `slack-token` | Slack Token | `"xox[bpors]-[A-Za-z0-9-]{10,250}"` | prefix check |
| `slack-webhook` | Slack Webhook URL | `"hooks\\.slack\\.com/services/T[A-Z0-9]{8}/B[A-Z0-9]{8}/[A-Za-z0-9]{24}"` | — |
| `google-api-key` | Google API Key | `"AIza[A-Za-z0-9_-]{35}"` | length=39 check |
| `twilio-api-key` | Twilio API Key | `"SK[a-f0-9]{32}"` | hex charset, length=34 |
| `sendgrid-api-key` | SendGrid API Key | `"SG\\.[A-Za-z0-9_-]{22}\\.[A-Za-z0-9_-]{43}"` | dotted format check |
| `mailgun-api-key` | Mailgun API Key | `"key-[A-Za-z0-9]{32}"` | length check |
| `npm-token` | NPM Token | `"npm_[A-Za-z0-9]{36}"` | prefix check |
| `pypi-token` | PyPI Token | `"pypi-[A-Za-z0-9_-]{50,}"` | prefix check |
| `jwt` | JSON Web Token | `"eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}"` | 3-part dotted base64url |
| `basic-auth-url` | Credentials in URL | `"[a-z+]+://[^:@\\s]+:[^:@\\s]+@[^\\s]+"` | Not `localhost` user:pass |

#### Medium Severity
| ID | Name | Pattern | Validator |
|----|------|---------|-----------|
| `connection-string` | Database Connection String | `"(?i)(mongodb\|postgres\|mysql\|redis\|amqp)://[^:]+:[^@]+@[^\\s\"']+"` | Has user:pass@ |
| `high-entropy-hex` | High-Entropy Hex String | `"[0-9a-f]{32,}"` | Entropy > 4.0, not a known hash/checksum context |
| `high-entropy-base64` | High-Entropy Base64 String | `"[A-Za-z0-9+/]{40,}={0,2}"` | Entropy > 4.5, context check |

**Important implementation notes:**
- Use `(std pregexp)` which exports `pregexp`, `pregexp-match`, `pregexp-match-positions`, `pregexp-replace`, `pregexp-replace*`, `pregexp-split`, `pregexp-quote`. This is a pure-Scheme regex engine — no C/FFI deps, perfect for static builds.
- `pregexp-match` signature: `(pregexp-match pattern string)` or with start/end positions (2-4 args).
- `pregexp-match-positions` returns `((start . end) ...)` pairs — use this for extracting matched substrings.
- Pre-compile all patterns at module load time with `(pregexp "...")` and store the compiled value in the struct. Do NOT recompile per-line.
- Export `(all-patterns)` that returns the list of all `secret-pattern` structs.
- Export `(patterns-by-severity sev)` filter.

### 4. `gitsafe/entropy.ss` — Shannon Entropy Calculator

**Purpose:** Calculate Shannon entropy of strings to detect high-randomness tokens that don't match known patterns.

**Imports:**
```scheme
(import (jerboa prelude))
```

**Functions to implement:**

```scheme
;; Shannon entropy of a string (bits per character)
;; Returns a flonum in range [0.0, ~6.0] for printable ASCII
(def (shannon-entropy str) -> flonum)
```

**Algorithm:**
1. Count frequency of each character in `str` using a 256-slot vector (one per byte value)
2. For each non-zero frequency, compute `-p * log2(p)` where `p = count/total`
3. Sum all terms

```scheme
(def (shannon-entropy str)
  (let* ([len (string-length str)]
         [freqs (make-vector 256 0)])
    (when (= len 0) (return 0.0))  ;; guard: empty string
    ;; Count character frequencies
    (let loop ([i 0])
      (when (< i len)
        (let ([b (char->integer (string-ref str i))])
          (vector-set! freqs b (+ 1 (vector-ref freqs b)))
          (loop (+ i 1)))))
    ;; Calculate entropy
    (let ([n (inexact len)])
      (let loop ([i 0] [entropy 0.0])
        (if (>= i 256)
          entropy
          (let ([count (vector-ref freqs i)])
            (if (= count 0)
              (loop (+ i 1) entropy)
              (let ([p (/ (inexact count) n)])
                (loop (+ i 1) (- entropy (* p (log p 2))))))))))))
```

**Thresholds (tuned constants):**
```scheme
(def *entropy-threshold-hex* 3.0)      ;; hex strings: lower bar (charset is only 16)
(def *entropy-threshold-base64* 4.0)   ;; base64: medium bar
(def *entropy-threshold-generic* 4.5)  ;; generic strings: high bar to avoid false positives
```

**Additional exports:**
```scheme
;; Check if a string looks like it could be a secret based on entropy alone
(def (high-entropy? str (threshold *entropy-threshold-generic*)) -> boolean)

;; Classify a string's character set
(def (string-charset str) -> symbol)
;; Returns: 'hex | 'base64 | 'alphanumeric | 'printable | 'mixed
```

**Note:** `(log x 2)` is available in Chez Scheme — `log` accepts an optional base argument.

### 5. `gitsafe/git.ss` — Git Integration

**Purpose:** Interface with git to get staged files, diffs, and push ranges.

**Imports:**
```scheme
(import (jerboa prelude)
        (std misc process))  ;; run-process, open-input-process
```

**Verified API from `(std misc process)`:**
- `run-process` — 1+ args (variadic), returns stdout as string. Call as `(run-process '("git" "diff" "--cached" "--name-only"))`.
- `run-process/batch` — returns exit status.
- `open-input-process` — returns a port for streaming large output.

**Functions to implement:**

```scheme
;; Get list of staged file paths (for pre-commit)
(def (staged-files) -> list-of-strings)
;; Implementation: run-process '("git" "diff" "--cached" "--name-only" "--diff-filter=ACMR")
;; Split output by newlines, filter empty strings

;; Get staged diff content for a single file (only added/modified lines)
(def (staged-diff path) -> list-of-diff-hunks)
;; Implementation: run-process '("git" "diff" "--cached" "-U0" "--" path)
;; Parse unified diff format, extract only "+" lines with line numbers

;; Get the full staged content of a file (what would be committed)
(def (staged-content path) -> string)
;; Implementation: run-process '("git" "show" ":path")
;; This gets the index version, not the working copy

;; Get commits being pushed (for pre-push)
(def (push-commits local-ref remote-ref) -> list-of-strings)
;; Implementation: run-process '("git" "rev-list" remote-ref..local-ref)

;; Get files changed in a commit range (for pre-push)
(def (changed-files-in-range from-ref to-ref) -> list-of-strings)
;; Implementation: run-process '("git" "diff" "--name-only" from-ref to-ref)

;; Get diff content for a commit range
(def (range-diff from-ref to-ref path) -> string)

;; Check if we're in a git repository
(def (git-repo?) -> boolean)
;; Implementation: (= 0 (run-process/batch '("git" "rev-parse" "--git-dir")))

;; Get repo root
(def (git-root) -> string)
;; Implementation: string-trim (run-process '("git" "rev-parse" "--show-toplevel"))
```

**Diff hunk structure:**
```scheme
(defstruct diff-hunk
  (file       ;; string: file path
   old-start  ;; integer: original line number
   new-start  ;; integer: new line number
   lines      ;; list of (line-number . content) pairs — only added lines
   ))
```

**Important:** Use `string-trim` from `(std misc string)` (verified: exported) to strip trailing newlines from `run-process` output. `string-split` takes a **char** delimiter: `(string-split output #\newline)`.

### 6. `gitsafe/scanner.ss` — Core Scanning Engine

**Purpose:** Orchestrates pattern matching and entropy analysis on file content.

**Imports:**
```scheme
(import (jerboa prelude)
        (std pregexp)
        (gitsafe patterns)
        (gitsafe entropy)
        (gitsafe config)
        (gitsafe allowlist))
```

**Key data structure:**
```scheme
(defstruct finding
  (pattern-id   ;; symbol from secret-pattern
   pattern-name ;; string from secret-pattern
   severity     ;; symbol: 'critical | 'high | 'medium | 'low
   file         ;; string: file path
   line-number  ;; integer
   line-content ;; string: the actual line (for context)
   matched-text ;; string: the specific matched substring
   redacted     ;; string: matched text with middle chars replaced by ***
   ))
```

**Core scanning functions:**

```scheme
;; Scan a single line against all patterns
;; Returns list of findings
(def (scan-line file line-number line patterns config) -> list-of-findings)

;; Scan entire file content (string) against patterns
;; Splits into lines, calls scan-line on each
(def (scan-content file content config) -> list-of-findings)

;; Scan only the diff hunks (added lines only)
;; This is the primary mode for pre-commit — only scan what's being added
(def (scan-diff-hunks hunks config) -> list-of-findings)

;; Top-level: scan staged changes for pre-commit
(def (scan-staged config) -> list-of-findings)

;; Top-level: scan a commit range for pre-push
(def (scan-push-range local-ref remote-ref config) -> list-of-findings)

;; Top-level: scan specific files (full content)
(def (scan-files paths config) -> list-of-findings)
```

**Scanning algorithm for `scan-line`:**
1. Skip if line is in allowlist (see `gitsafe/allowlist.ss`)
2. For each `secret-pattern` in the active pattern set:
   a. Run `(pregexp-match-positions (secret-pattern-pregexp pat) line)`
   b. If match found, extract the matched substring
   c. If pattern has a `validator`, call it on the matched text. Skip if `#f`.
   d. If pattern category is `'medium` and it's an entropy-based pattern, compute `shannon-entropy` on the matched substring. Skip if below threshold.
   e. Create a `finding` struct with redacted text
3. Return all findings for this line

**Redaction:**
```scheme
(def (redact str)
  (let ([len (string-length str)])
    (if (<= len 8)
      "***"
      (string-append
        (substring str 0 4)
        "***"
        (substring str (- len 4) len)))))
```

**File filtering (skip non-text files):**
```scheme
;; Skip binary files and known non-secret extensions
(def *skip-extensions*
  '("png" "jpg" "jpeg" "gif" "bmp" "ico" "svg"
    "woff" "woff2" "ttf" "eot"
    "zip" "gz" "tar" "bz2" "xz" "7z"
    "pdf" "doc" "docx" "xls" "xlsx"
    "exe" "dll" "so" "dylib" "o" "a"
    "pyc" "class" "wasm"
    "mp3" "mp4" "avi" "mov" "wav"))

(def (skip-file? path config)
  (or (member (path-extension path) *skip-extensions*)
      (config-excluded? config path)))
```

Use `path-extension` from `(std os path)` (verified: exported, returns extension without dot as string).

### 7. `gitsafe/config.ss` — Configuration

**Purpose:** Load and validate `.gitsafe.json` configuration file.

**Imports:**
```scheme
(import (jerboa prelude)
        (std text json))  ;; string->json-object, read-json
```

**Verified JSON API:**
- `string->json-object` — parse JSON string to hash table
- `json-object->string` — serialize hash table to JSON string
- `read-json` — read from port
- `write-json` — write to port

**Configuration file format (`.gitsafe.json`):**
```json
{
  "severity": "medium",
  "entropy": true,
  "patterns": {
    "disabled": ["high-entropy-hex"],
    "custom": [
      {
        "id": "my-internal-key",
        "name": "Internal Service Key",
        "severity": "high",
        "pattern": "ISK_[A-Za-z0-9]{32}",
        "description": "Internal service authentication key"
      }
    ]
  },
  "exclude": [
    "*.test.*",
    "test/**",
    "vendor/**",
    "*.md",
    "go.sum",
    "package-lock.json",
    "yarn.lock",
    "Cargo.lock"
  ],
  "allowlist": {
    "files": [".gitsafe.json"],
    "patterns": ["EXAMPLE_KEY", "fake_secret_for_testing"]
  }
}
```

**Config struct:**
```scheme
(defstruct gitsafe-config
  (severity          ;; symbol: 'low | 'medium | 'high | 'critical
   entropy-enabled   ;; boolean
   disabled-patterns ;; list of symbol IDs
   custom-patterns   ;; list of secret-pattern structs
   exclude-globs     ;; list of glob strings
   allowlist-files   ;; list of file paths
   allowlist-strings ;; list of literal strings to ignore
   ))
```

**Functions:**
```scheme
;; Load config from .gitsafe.json, return default config if file missing
(def (load-config (path ".gitsafe.json")) -> gitsafe-config)

;; Default config (used when no .gitsafe.json exists)
(def (default-config) -> gitsafe-config)

;; Check if a file path matches any exclude glob
(def (config-excluded? config path) -> boolean)
```

**Glob matching:** Implement a simple glob matcher (no external library needed):
- `*` matches any sequence of non-`/` chars
- `**` matches any sequence including `/`
- `?` matches a single char

This is ~30 lines of recursive matching code. Use `string->list` and character-level matching.

### 8. `gitsafe/allowlist.ss` — Suppression System

**Purpose:** Allow suppressing findings via inline comments, `.gitsafeignore`, and config.

**Imports:**
```scheme
(import (jerboa prelude)
        (std pregexp)
        (gitsafe config))
```

**Suppression mechanisms (in priority order):**

1. **Inline comment:** `# gitsafe:ignore` or `// gitsafe:ignore` or `/* gitsafe:ignore */` at end of line
2. **Inline with specific pattern:** `# gitsafe:ignore=aws-access-key`
3. **`.gitsafeignore` file:** gitignore-style patterns for files to skip entirely
4. **Config `allowlist.patterns`:** literal strings that are known-safe (test fixtures, examples)
5. **Config `allowlist.files`:** specific files to skip

**Functions:**
```scheme
;; Check if a line has an inline suppression comment
(def (line-suppressed? line (pattern-id #f)) -> boolean)

;; Check if a matched string is in the allowlist
(def (allowlisted? matched-text config) -> boolean)

;; Load .gitsafeignore from repo root
(def (load-ignorefile (path ".gitsafeignore")) -> list-of-globs)

;; Check if a file path matches ignorefile patterns
(def (ignored-file? path ignore-patterns) -> boolean)
```

### 9. `gitsafe/output.ss` — Formatted Output

**Purpose:** Format and display findings to the user.

**Imports:**
```scheme
(import (jerboa prelude)
        (std text json))  ;; for --format json
```

**Functions:**
```scheme
;; Display findings in human-readable text format
(def (display-findings-text findings verbose?)

;; Display findings as JSON (for CI/CD integration)
(def (display-findings-json findings)

;; Display a summary line
(def (display-summary findings)

;; Format a single finding for text output
(def (format-finding finding) -> string)
```

**Text output format:**
```
[CRITICAL] gitsafe: secret detected in jcode.json:3
  Pattern: Anthropic API Key
  Match:   sk-a***Kf9w
  Line:    "api_key": "sk-a***Kf9w"

[HIGH] gitsafe: secret detected in config.py:27
  Pattern: Generic API Key Assignment
  Match:   AIza***xY2q
  Line:    API_KEY = "AIza***xY2q"

---
gitsafe: 2 secret(s) found in 2 file(s). Commit blocked.
Suppress with: # gitsafe:ignore (inline) or .gitsafe.json (project)
```

**JSON output format:**
```json
{
  "findings": [
    {
      "id": "anthropic-api-key",
      "severity": "critical",
      "file": "jcode.json",
      "line": 3,
      "match": "sk-a***Kf9w",
      "pattern": "Anthropic API Key"
    }
  ],
  "summary": { "total": 2, "files": 2, "critical": 1, "high": 1 }
}
```

Use severity-based coloring if stdout is a tty. Check with `(foreign-procedure "isatty" (int) int)` on fd 1, or more simply check if `(getenv "NO_COLOR")` is set and `(getenv "TERM")` is not `"dumb"`.

ANSI colors:
- CRITICAL: red bold (`\x1b[1;31m`)
- HIGH: red (`\x1b[31m`)
- MEDIUM: yellow (`\x1b[33m`)
- LOW: blue (`\x1b[34m`)
- Reset: `\x1b[0m`

---

## Build System

### Makefile

```makefile
JERBOA_HOME ?= $(HOME)/mine/jerboa
SCHEME ?= scheme

.PHONY: run test binary install-binary install clean

# Dev mode (interpreted)
run:
	JERBOA_HOME=$(JERBOA_HOME) \
		$(SCHEME) -q --libdirs $(CURDIR):$(JERBOA_HOME)/lib --script gitsafe/main.ss -- $(ARGS)

# Compile static binary
binary:
	JERBOA_HOME=$(JERBOA_HOME) \
		$(SCHEME) -q --libdirs $(CURDIR):$(JERBOA_HOME)/lib --script build-binary.ss

# Install binary to ~/.local/bin
install-binary: binary
	mkdir -p $(HOME)/.local/bin
	cp gitsafe-bin $(HOME)/.local/bin/gitsafe
	@echo "Installed to ~/.local/bin/gitsafe"

# Install git hooks in current repo (convenience target)
install:
	@echo "Run: gitsafe install   (in a git repo)"

# Run tests
test:
	JERBOA_HOME=$(JERBOA_HOME) \
		$(SCHEME) -q --libdirs $(CURDIR):$(JERBOA_HOME)/lib --script test/test-gitsafe.ss

clean:
	find . -name '*.so' -delete
	find . -name '*.wpo' -delete
	rm -f gitsafe-bin
```

### `build-binary.ss` — Static Binary Build Script

Follow the **exact pattern** from `jerboa-lsp/build-binary.ss`. The steps are:

**Step 1: Compile all modules with WPO enabled**
```scheme
(parameterize ((compile-imported-libraries #t)
               (optimize-level 3)
               (cp0-effort-limit 500)
               (cp0-score-limit 50)
               (cp0-outer-unroll-limit 1)
               (commonization-level 4)
               (enable-unsafe-application #t)
               (enable-unsafe-variable-reference #t)
               (enable-arithmetic-left-associative #t)
               (debug-level 0)
               (generate-inspector-information #f)
               (generate-wpo-files #t))
  (compile-program "gitsafe/main-binary.ss"))
```

**Step 2: Whole-program optimization**
```scheme
(compile-whole-program "gitsafe/main-binary.wpo" "gitsafe-all.so")
```

**Step 3: Create boot file + C headers**
The module list for the boot file:
```scheme
(define gitsafe-modules
  '("gitsafe/patterns"
    "gitsafe/entropy"
    "gitsafe/config"
    "gitsafe/allowlist"
    "gitsafe/git"
    "gitsafe/scanner"
    "gitsafe/output"))
```

Generate C headers via `file->c-header` for:
- `gitsafe-all.so` -> `gitsafe_program.h`
- `petite.boot` -> `gitsafe_petite_boot.h`
- `scheme.boot` -> `gitsafe_scheme_boot.h`
- `gitsafe.boot` -> `gitsafe_boot.h`

**Step 4: Generate C main, compile, and link**
Generate `gitsafe-main.c` following the jerboa-lsp pattern:
- `Sscheme_init(NULL)`
- `Sregister_boot_file_bytes` for all 3 boots
- `Sbuild_heap(NULL, NULL)`
- Extract program `.so` to mkstemp tmpfile
- `Sscheme_script(prog_path, argc, argv)`
- Cleanup + deinit

Link flags (Linux): `-lkernel -llz4 -lz -lm -ldl -lpthread -luuid -lncurses`

**Step 5: Cleanup intermediates**

### Alternative: Use `(jerboa build)` High-Level API

If the implementer prefers, they can use the `build-binary` function from `(jerboa build)`:

```scheme
(import (jerboa build))
(build-binary "gitsafe/main-binary.ss" "gitsafe-bin"
              'release: #t)
```

This is a 3-line build script that does steps 1-5 automatically. However, the manual approach (copying from jerboa-lsp) gives more control over the module list and boot file contents. The implementer should try the `(jerboa build)` API first and fall back to manual if it doesn't handle pure-Scheme projects cleanly.

---

## Hook Installation

### `gitsafe install` command

When the user runs `gitsafe install` inside a git repo:

1. Verify `.git/` exists
2. Create/update `.git/hooks/pre-commit`:
```bash
#!/bin/sh
# Installed by gitsafe
exec gitsafe pre-commit
```
3. Create/update `.git/hooks/pre-push`:
```bash
#!/bin/sh
# Installed by gitsafe
# Read push info from stdin (required by git)
while read local_ref local_sha remote_ref remote_sha; do
  gitsafe pre-push --local-ref "$local_ref" --remote-ref "$remote_ref"
  status=$?
  if [ $status -ne 0 ]; then
    exit $status
  fi
done
exit 0
```
4. `chmod +x` both hooks
5. Print confirmation

**Important:** If hooks already exist and weren't installed by gitsafe (no `# Installed by gitsafe` marker), warn the user and suggest appending instead.

### `gitsafe uninstall` command

Remove hooks only if they contain the `# Installed by gitsafe` marker. Otherwise warn.

---

## File Layout (what the implementer should create)

```
jerboa-gitsafe/
├── PLAN.md                    ← this file
├── Makefile
├── build-binary.ss            ← static binary build script
├── .gitsafe.json              ← example/default config
├── gitsafe/
│   ├── main.ss                ← interpreter entry point
│   ├── main-binary.ss         ← binary entry point
│   ├── scanner.ss             ← core scanning engine
│   ├── patterns.ss            ← secret pattern definitions
│   ├── entropy.ss             ← Shannon entropy calculator
│   ├── git.ss                 ← git integration
│   ├── config.ss              ← configuration loading
│   ├── output.ss              ← formatted output
│   └── allowlist.ss           ← suppression system
└── test/
    ├── test-gitsafe.ss        ← main test runner
    ├── test-entropy.ss        ← entropy unit tests
    ├── test-patterns.ss       ← pattern matching tests
    ├── test-scanner.ss        ← scanner integration tests
    └── fixtures/
        ├── fake-secrets.txt   ← file with known secrets for testing
        ├── clean-code.py      ← file with no secrets
        ├── false-positives.txt ← known false-positive triggers
        └── jcode.json         ← reproduction of the original incident
```

---

## Implementation Order

The implementer should build and verify in this order:

1. **`gitsafe/entropy.ss`** — Pure computation, easy to test in isolation with `jerboa_eval`
2. **`gitsafe/patterns.ss`** — Pattern definitions, test each regex with `pregexp-match`
3. **`gitsafe/config.ss`** — Config loading, test with sample `.gitsafe.json`
4. **`gitsafe/allowlist.ss`** — Suppression logic
5. **`gitsafe/git.ss`** — Git integration (requires a git repo to test)
6. **`gitsafe/scanner.ss`** — Wire everything together
7. **`gitsafe/output.ss`** — Formatting
8. **`gitsafe/main.ss`** — CLI entry point, test interpreted first
9. **`test/`** — Test suite
10. **`build-binary.ss` + `Makefile`** — Static binary build
11. **`gitsafe/main-binary.ss`** — Binary entry point

---

## Verified Jerboa APIs Used

All symbols below have been verified via `jerboa_module_exports` and `jerboa_function_signature`:

| Symbol | Module | Arity | Notes |
|--------|--------|-------|-------|
| `pregexp` | `(std pregexp)` | 1 | Compile regex pattern |
| `pregexp-match` | `(std pregexp)` | 2-4 | Match against string |
| `pregexp-match-positions` | `(std pregexp)` | 2-4 | Match with position pairs |
| `pregexp-replace` | `(std pregexp)` | 3+ | Replace first match |
| `pregexp-replace*` | `(std pregexp)` | 3+ | Replace all matches |
| `pregexp-split` | `(std pregexp)` | 2+ | Split on pattern |
| `pregexp-quote` | `(std pregexp)` | 1 | Escape special chars |
| `run-process` | `(std misc process)` | 1+ | Run command, capture stdout |
| `run-process/batch` | `(std misc process)` | 1+ | Run command, get exit code |
| `open-input-process` | `(std misc process)` | 1+ | Stream stdout as port |
| `string->json-object` | `(std text json)` | 1 | Parse JSON string |
| `json-object->string` | `(std text json)` | 1 | Serialize to JSON |
| `read-json` | `(std text json)` | 1 | Read JSON from port |
| `write-json` | `(std text json)` | 2 | Write JSON to port |
| `path-extension` | `(std os path)` | 1 | Get file extension |
| `path-join` | `(std os path)` | 2+ | Join path segments |
| `path-directory` | `(std os path)` | 1 | Parent directory |
| `string-split` | `(std misc string)` | 2 | Split string (char delim) |
| `string-contains` | `(std misc string)` | 2 | Find substring (returns index or #f) |
| `string-trim` | `(std misc string)` | 1 | Trim whitespace |
| `string-prefix?` | `(std misc string)` | 2 | Check prefix |
| `string-empty?` | `(std misc string)` | 1 | Empty string check |
| `read-file-string` | `(std misc ports)` | 1 | Read entire file |
| `read-file-lines` | `(std misc ports)` | 1 | Read file as line list |
| `write-file-string` | `(std misc ports)` | 2 | Write string to file |
| `sha256` | `(std crypto digest)` | 1 | SHA-256 hash |
| `digest->hex-string` | `(std crypto digest)` | 1 | Hash to hex |
| `hash-ref` | prelude | 2-3 | Hash table lookup |
| `hash-get` | prelude | 1-2 | Safe lookup (#f default) |
| `hash-put!` | prelude | 3 | Hash table insert |
| `hash-key?` | prelude | 2 | Key existence check |
| `hash-keys` | prelude | 1 | List all keys |
| `hash->list` | prelude | 1 | Alist conversion |

**Modules that do NOT exist** (verified — do not use):
- `(std text regex)` — **does not exist**. Use `(std pregexp)` instead.
- `(std pcre2)` — requires `chez-pcre2` C library, **not available** in standard installs. Use `(std pregexp)`.

---

## Performance Considerations

- **Pattern pre-compilation:** All `pregexp` patterns must be compiled once at module load time, not per-line.
- **Early exit on binary files:** Check `path-extension` before reading content.
- **Scan only added lines:** In pre-commit mode, parse the diff and only scan `+` lines. Don't re-scan unchanged code.
- **Short-circuit on long lines:** Skip lines > 2000 characters (likely minified/generated code, not hand-written secrets).
- **Lazy config loading:** Load `.gitsafe.json` once, pass the struct through all calls.
- **Target performance:** < 100ms for typical commits (< 50 changed files). The binary starts in ~10ms (Chez boot) + ~50ms scanning.

---

## Testing Strategy

### Unit Tests (`test/test-entropy.ss`)
- Known entropy values: `"aaaa"` -> 0.0, `"abcd"` -> 2.0, `"aB3$xY9!"` -> ~3.0
- Random-looking strings -> high entropy (> 4.0)

### Pattern Tests (`test/test-patterns.ss`)
- Each pattern must have at least 2 true positives and 2 true negatives
- Test with real-format (but invalid) keys:
  - `AKIAIOSFODNN7EXAMPLE` (AWS example key)
  - `ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef12` (GitHub PAT format)
  - `sk-ant-api03-XXXXXXXX...` (Anthropic format)
- False positive tests:
  - `password_field = "password"` (the word "password" as a value — not a real secret)
  - `API_KEY = ""` (empty value)
  - `API_KEY = os.environ["API_KEY"]` (reference, not a literal)
  - `sha256: abcdef1234567890abcdef1234567890` (known checksum context)

### Integration Tests (`test/test-scanner.ss`)
- Create fixture files with known secrets embedded
- Scan them and assert exact finding count and pattern IDs
- Test allowlist suppression
- Test config exclusion

### Test the original incident
- Create `test/fixtures/jcode.json` containing fake API keys in the format that was committed
- Verify the scanner catches all of them

---

## Future Enhancements (out of scope for v1)

- **Git blame context:** Show who last modified the line containing the secret
- **Auto-remediation:** Offer to remove the secret and add to `.gitignore`
- **GitHub Actions integration:** Publish as a CI action
- **Incremental caching:** Cache scan results per file hash to avoid re-scanning
- **Custom regex via CLI:** `gitsafe scan --pattern "CUSTOM_[A-Z]{32}" .`
- **Pre-receive hook:** Server-side hook for gitolite/GitLab
