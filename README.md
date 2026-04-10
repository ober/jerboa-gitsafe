# jerboa-gitsafe

A fast, intelligent git pre-commit/pre-push hook that detects leaked secrets, API keys, tokens, and credentials. Written in Jerboa Scheme, compiled to a fully static binary.

## Install

```bash
make binary
make install-binary
```

This places `gitsafe` in `~/.local/bin/`.

## Usage

### Per-repo hook

```bash
cd your-repo
gitsafe install
```

### Global git template (recommended)

Automatically install the pre-commit hook in every new repo you create or clone:

```bash
mkdir -p ~/.git-templates/hooks
cat > ~/.git-templates/hooks/pre-commit << 'EOF'
#!/bin/sh
exec gitsafe pre-commit
EOF
chmod +x ~/.git-templates/hooks/pre-commit
git config --global init.templateDir ~/.git-templates
```

Now every `git init` or `git clone` gets the gitsafe pre-commit hook. No per-repo setup needed.

To retroactively add hooks to existing repos, re-run `git init` inside them (this is safe and non-destructive).

### Manual scan

```bash
gitsafe scan path/to/file.json
gitsafe scan src/
```

## Configuration

Place a `.gitsafe.json` in your repo root. See `PLAN.md` for the full config schema.

## Suppression

- Inline: append `# gitsafe:ignore` to a line
- Per-pattern: `# gitsafe:ignore=aws-access-key`
- Per-file: add paths to `.gitsafeignore` or `exclude` in `.gitsafe.json`
