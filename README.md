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

## What It Detects

### Critical
- AWS Access Key IDs and Secret Keys
- GitHub Personal Access Tokens (classic and fine-grained)
- OpenAI API Keys (standard and project-scoped)
- Anthropic API Keys
- Stripe Secret Keys
- PEM-encoded Private Keys

### High
- Generic API key/secret/token/password assignments (with entropy validation)
- Bearer tokens
- Slack tokens and webhook URLs
- Google API keys
- Twilio, SendGrid, Mailgun API keys
- NPM and PyPI tokens
- JWTs
- Credentials embedded in URLs

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
