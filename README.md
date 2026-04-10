# gitsafe

A fast, zero-dependency git hook that blocks commits and pushes containing leaked secrets, API keys, tokens, and credentials. Compiles to a single static binary — no runtime dependencies on the target machine.

## Quick Start

```bash
git clone https://github.com/ober/jerboa-gitsafe.git
cd jerboa-gitsafe
make install
```

This builds a fully static binary via Docker and installs it to `~/.local/bin/gitsafe`, then configures global git hooks so every new repo is protected automatically.

## Install

### From Docker (recommended)

Requires only Docker. No Chez Scheme, no Jerboa, no compiler toolchain.

```bash
make install
```

This runs `make linux` (Docker build) and then:
- Copies the static binary to `~/.local/bin/gitsafe`
- Creates pre-commit and pre-push hooks in `~/.git-templates/hooks/`
- Sets `git config --global init.templateDir ~/.git-templates`

Make sure `~/.local/bin` is on your `PATH`:

```bash
# Add to ~/.bashrc or ~/.zshrc if not already present
export PATH="$HOME/.local/bin:$PATH"
```

### Build only (no install)

```bash
make linux                 # Docker build → ./gitsafe-musl
make linux-local           # Local build (requires musl-gcc + musl Chez)
```

## Setting Up Existing Repos

`make install` configures git's global template directory, which applies to all **new** repos (`git init` / `git clone`). To add gitsafe hooks to repos that already exist, you have two options:

### Option 1: Re-initialize (safe, non-destructive)

Run `git init` inside existing repos. This copies the template hooks without touching your code, branches, or history:

```bash
# Single repo
cd ~/projects/my-repo && git init

# All repos under a directory
find ~/projects -name .git -type d -execdir git init \;
```

### Option 2: Per-repo install

```bash
cd ~/projects/my-repo
gitsafe install
```

This writes gitsafe hooks directly into `.git/hooks/` for that repo.

### Option 3: Per-repo uninstall

```bash
cd ~/projects/my-repo
gitsafe uninstall
```

Removes only hooks that were installed by gitsafe. Leaves other hooks untouched.

## Global Configuration

The global git template is set during `make install`:

```
~/.git-templates/hooks/pre-commit   → exec gitsafe pre-commit
~/.git-templates/hooks/pre-push     → exec gitsafe pre-push
```

You can verify this is active:

```bash
git config --global init.templateDir
# → /home/you/.git-templates
```

## Per-Repo Configuration

Place a `.gitsafe.json` in any repo root to customize behavior for that project:

```json
{
  "severity": "medium",
  "entropy": true,
  "patterns": {
    "disabled": ["high-entropy-hex"],
    "custom": []
  },
  "exclude": [
    "*.lock",
    "go.sum",
    "*.md",
    "vendor/**",
    "node_modules/**",
    "*.min.js",
    "*.min.css",
    "test/fixtures/**"
  ],
  "allowlist": {
    "files": [],
    "patterns": [
      "EXAMPLE_KEY",
      "YOUR_API_KEY_HERE"
    ]
  }
}
```

### Config Fields

| Field | Default | Description |
|---|---|---|
| `severity` | `"medium"` | Minimum severity to report: `low`, `medium`, `high`, `critical` |
| `entropy` | `true` | Enable Shannon entropy analysis for detecting random-looking strings |
| `patterns.disabled` | `[]` | Pattern IDs to skip (e.g. `["high-entropy-hex", "jwt"]`) |
| `patterns.custom` | `[]` | Custom pattern definitions |
| `exclude` | Lock files, docs, vendor dirs | Glob patterns for paths to skip |
| `allowlist.files` | `[]` | File paths to skip entirely |
| `allowlist.patterns` | `[]` | Known-safe strings to ignore (e.g. placeholder keys) |

### Default Excludes

Without a `.gitsafe.json`, these paths are excluded automatically:
`*.lock`, `go.sum`, `*.md`, `vendor/**`, `node_modules/**`, `*.min.js`, `*.min.css`

## How It Works

gitsafe uses a multi-layered detection pipeline to catch leaked secrets with high accuracy and low false positives. Each line of scanned content passes through several stages before a finding is reported.

### Detection Pipeline

```
  line of code
       |
  [1. Pattern Match]     -- regex against 28 known secret formats
       |
  [2. Capture Extract]   -- pull the secret value from capture groups
       |
  [3. Validator]         -- pattern-specific checks (length, prefix, entropy)
       |
  [4. Placeholder Filter] -- reject example/dummy values
       |
  [5. Allowlist Check]   -- skip known-safe strings from config
       |
  [6. Inline Suppression] -- honor gitsafe:ignore comments
       |
    FINDING
```

### 1. Pattern Matching

gitsafe ships with 28 built-in regex patterns organized by severity. Each pattern targets a specific secret format (e.g. `AKIA` prefix for AWS keys, `ghp_` for GitHub PATs, `eyJ` for JWTs). Patterns are compiled once at startup and matched against every line of scanned content.

When a pattern has capture groups, gitsafe extracts the last non-empty capture group as the matched value. This ensures validators receive just the secret (e.g. `AKIAIOSFODNN7EXAMPLE`) rather than the full match with surrounding context characters.

### 2. Validators

Many patterns include a validator function that runs additional checks on the extracted match:

- **Length checks** -- AWS access keys must be exactly 20 characters, Google API keys exactly 39
- **Prefix checks** -- Anthropic keys must start with `sk-ant-`, GitHub PATs with `gh`
- **Marker checks** -- OpenAI keys must contain the `T3BlbkFJ` marker
- **Entropy checks** -- Generic patterns (API key assignments, bearer tokens) require the matched value to exceed a Shannon entropy threshold, rejecting low-randomness values that are unlikely to be real secrets
- **Placeholder rejection** -- URL credential patterns reject common test values like `user:password@localhost`

### 3. Shannon Entropy Analysis

For patterns that match broad formats (generic key assignments, high-entropy hex/base64), gitsafe computes the [Shannon entropy](https://en.wikipedia.org/wiki/Entropy_(information_theory)) of the matched string -- a measure of randomness in bits per character. Real secrets tend to have high entropy; configuration values and identifiers tend to have low entropy.

Thresholds vary by character set:

| Character Set | Threshold | Example |
|---|---|---|
| Hex (`0-9a-f`) | 3.0 bits | `deadbeef1234...` |
| Base64 (`A-Za-z0-9+/=`) | 4.0 bits | `SGVsbG8gV29y...` |
| Generic (validator-level) | 3.0--3.5 bits | Used by bearer tokens, API key assignments |

A string like `"aaaaaaaaaaaaaaaa"` has 0.0 bits of entropy and is ignored. A string like `"xK9mP2nQrT5vWy8zA3bCdEfGhJk"` has >4.0 bits and triggers a finding.

### 4. Placeholder Filtering

The `not-placeholder?` filter rejects common test and example values that structurally match secret formats but aren't real credentials. It catches:

- Repeated single characters (`XXXXXXXX`, `aaaaaaaa`)
- Strings shorter than 8 characters
- Placeholder words at word boundaries: `example`, `placeholder`, `dummy`, `sample`, `your-api-key`, `replace-me`, `change-me`, `insert-here`

Word-boundary matching prevents false negatives -- a real secret like `testX9mP2nQrT5vWy8zA3b` won't be rejected just because it contains the substring "test".

### 5. Scan Modes

gitsafe scans different content depending on how it's invoked:

- **Pre-commit** (`gitsafe pre-commit`): Reads the git index via `git diff --cached`. For modified files, only added lines in diff hunks are scanned. For entirely new files, the full staged content is scanned. This means gitsafe only flags secrets you're about to commit, not existing content.
- **Pre-push** (`gitsafe pre-push`): Computes `git rev-list` for the commit range being pushed and scans the unified diff across all changed files in that range.
- **Manual scan** (`gitsafe scan PATH...`): Reads and scans entire file contents.

In all modes, binary files (images, archives, compiled objects, `.lock` files) are skipped based on file extension. Paths matching exclude globs from `.gitsafe.json` are also skipped.

### 6. False Positive Reduction

Several layers work together to minimize noise:

- **Severity filtering**: Only patterns at or above the configured severity level are active (default: `medium`). Set to `critical` to only catch the most dangerous leaks.
- **Env-var detection**: Lines like `os.getenv('API_KEY')` or `os.environ.get('TOKEN')` match generic patterns but the extracted values (`API_KEY'`) fail entropy checks.
- **Long line skip**: Lines over 2000 characters (minified JS, generated code) are skipped entirely.
- **Allowlist strings**: Known-safe values (e.g. `EXAMPLE_KEY`) in `.gitsafe.json` are ignored when found in any match.
- **`.gitsafeignore`**: A gitignore-style file for excluding paths from scanning.
- **Inline suppression**: `# gitsafe:ignore` or `// gitsafe:ignore=pattern-id` on a line suppresses that finding.

## What It Detects

### Critical
- AWS Access Key IDs (`AKIA...`) and Secret Access Keys
- GitHub Personal Access Tokens (classic `ghp_` and fine-grained `github_pat_`)
- OpenAI API Keys (standard, project-scoped `sk-proj-`, and service account `sk-svcacct-`)
- Anthropic API Keys (`sk-ant-`)
- Stripe Secret and Restricted Keys (`sk_live_`, `rk_live_`)
- PEM-encoded Private Keys (RSA, DSA, EC, OpenSSH, PGP, encrypted)
- PuTTY Private Keys (PPK format)

### High
- Generic API key/secret/token/password assignments (with entropy validation)
- Bearer tokens
- Slack tokens (`xoxb-`, `xoxp-`, etc.) and webhook URLs
- Google API keys (`AIza...`)
- Twilio, SendGrid, Mailgun API keys
- NPM and PyPI tokens
- JWTs (`eyJ...` three-part base64url)
- Credentials embedded in URLs (with placeholder rejection)

### Medium
- Database connection strings with credentials
- High-entropy hex strings (40+ chars)
- High-entropy base64 strings (40+ chars)

## Usage

### As git hooks (automatic)

Once installed, gitsafe runs automatically on `git commit` and `git push`. If secrets are found, the operation is blocked and findings are printed.

### Manual scan

```bash
gitsafe scan path/to/file.json
gitsafe scan src/
```

### CLI Options

```
gitsafe [MODE] [OPTIONS]

Modes:
  pre-commit         Scan staged files (default)
  pre-push           Scan commits being pushed
  scan PATH...       Scan specific files or directories
  install            Install git hooks in .git/hooks/
  uninstall          Remove gitsafe-installed hooks

Options:
  --config PATH      Path to .gitsafe.json (default: .gitsafe.json)
  --format text|json Output format (default: text)
  --severity LEVEL   Minimum severity: low|medium|high|critical
  --no-entropy       Disable entropy analysis
  --verbose          Show scan statistics
  --version          Print version
  --help             Print this help
```

## Suppression

- **Inline:** append `# gitsafe:ignore` to a line
- **Per-pattern:** `# gitsafe:ignore=aws-access-key`
- **Per-file:** add paths to `exclude` in `.gitsafe.json`
- **Per-string:** add known-safe values to `allowlist.patterns` in `.gitsafe.json`

## Make Targets

```
make linux                  Docker build (canonical, reproducible)
make linux-local            Local build (requires musl-gcc + musl Chez)
make install                Docker build + install to ~/.local/bin + global hooks
make verify-harden          Verify binary hardening (stripped, no path leaks)
make binary                 Native build (requires local Chez + Jerboa)
make run ARGS='...'         Run in interpreter mode (development)
make test                   Run test suite
make clean                  Remove all build artifacts
```
