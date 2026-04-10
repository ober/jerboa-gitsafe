JERBOA_HOME ?= $(realpath $(CURDIR)/../jerboa)
SCHEME ?= scheme
BIN_DIR := $(HOME)/.local/bin
TEMPLATE_DIR := $(HOME)/.git-templates
HOOK_DIR := $(TEMPLATE_DIR)/hooks

.PHONY: run test binary install clean \
        gitsafe-musl gitsafe-musl-local docker verify-harden help

run:
	JERBOA_HOME=$(JERBOA_HOME) \
		$(SCHEME) -q --libdirs $(CURDIR):$(JERBOA_HOME)/lib --script gitsafe/main.ss -- $(ARGS)

binary:
	JERBOA_HOME=$(JERBOA_HOME) \
		$(SCHEME) -q --libdirs $(CURDIR):$(JERBOA_HOME)/lib --script build-binary.ss

test:
	JERBOA_HOME=$(JERBOA_HOME) \
		$(SCHEME) -q --libdirs $(CURDIR):$(JERBOA_HOME)/lib --script test/test-gitsafe.ss

install: binary
	mkdir -p $(BIN_DIR)
	cp gitsafe-bin $(BIN_DIR)/gitsafe
	@echo "Installed gitsafe to $(BIN_DIR)/gitsafe"
	mkdir -p $(HOOK_DIR)
	printf '#!/bin/sh\nexec gitsafe pre-commit\n' > $(HOOK_DIR)/pre-commit
	chmod +x $(HOOK_DIR)/pre-commit
	printf '#!/bin/sh\nwhile read local_ref local_sha remote_ref remote_sha; do\n  gitsafe pre-push --local-ref "$$local_ref" --remote-ref "$$remote_ref" || exit $$?\ndone\n' > $(HOOK_DIR)/pre-push
	chmod +x $(HOOK_DIR)/pre-push
	git config --global init.templateDir $(TEMPLATE_DIR)
	@echo ""
	@echo "Global git hooks installed:"
	@echo "  $(HOOK_DIR)/pre-commit"
	@echo "  $(HOOK_DIR)/pre-push"
	@echo "  git config --global init.templateDir = $(TEMPLATE_DIR)"
	@echo ""
	@echo "All new repos (git init / git clone) will use gitsafe automatically."
	@echo "To add to an existing repo: cd repo && git init"

# ── Static musl binary ──────────────────────────────────────────────────────
# Use `make gitsafe-musl` to build in Docker (canonical, reproducible).
# Use `make gitsafe-musl-local` to build directly on the host (requires
# musl-gcc and a musl-built Chez at ~/chez-musl or JERBOA_MUSL_CHEZ_PREFIX).

gitsafe-musl: docker

gitsafe-musl-local:
	JERBOA_HOME=$(JERBOA_HOME) \
		./build-gitsafe-musl.sh

docker:
	@echo "=== Building gitsafe-musl in Docker ==="
	docker build --platform linux/amd64 --build-arg CACHE_BUST=$$(date +%s) -t gitsafe-builder .
	@id=$$(docker create --platform linux/amd64 gitsafe-builder) && \
	docker cp $$id:/out/gitsafe-musl ./gitsafe-musl && \
	docker cp $$id:/out/gitsafe-musl.sha256 ./gitsafe-musl.sha256 && \
	docker rm $$id >/dev/null && \
	chmod +x gitsafe-musl
	@echo ""
	@ls -lh gitsafe-musl
	@file gitsafe-musl

install-musl: gitsafe-musl
	mkdir -p $(BIN_DIR)
	cp gitsafe-musl $(BIN_DIR)/gitsafe
	@echo "Installed gitsafe-musl to $(BIN_DIR)/gitsafe"
	mkdir -p $(HOOK_DIR)
	printf '#!/bin/sh\nexec gitsafe pre-commit\n' > $(HOOK_DIR)/pre-commit
	chmod +x $(HOOK_DIR)/pre-commit
	printf '#!/bin/sh\nwhile read local_ref local_sha remote_ref remote_sha; do\n  gitsafe pre-push --local-ref "$$local_ref" --remote-ref "$$remote_ref" || exit $$?\ndone\n' > $(HOOK_DIR)/pre-push
	chmod +x $(HOOK_DIR)/pre-push
	git config --global init.templateDir $(TEMPLATE_DIR)
	@echo ""
	@echo "Global git hooks installed. Static binary — no runtime dependencies."

verify-harden: gitsafe-musl
	@echo "=== Hardening verification ==="
	@(file gitsafe-musl | grep -qE 'stripped|no section header') && echo "  PASS: binary is stripped" || echo "  FAIL: binary not stripped"
	@if strings gitsafe-musl | grep -q "$(HOME)"; then \
		echo "  WARN: home directory path found in binary"; \
	else \
		echo "  PASS: no home directory paths leaked"; \
	fi
	@if [ -f gitsafe-musl.sha256 ]; then \
		echo "  PASS: gitsafe-musl.sha256 exists ($$(wc -c < gitsafe-musl.sha256) bytes)"; \
	else \
		echo "  FAIL: gitsafe-musl.sha256 not found"; \
	fi
	@./gitsafe-musl --version >/dev/null 2>&1 && echo "  PASS: binary runs" || echo "  FAIL: binary doesn't run"

# ── Cleanup ──────────────────────────────────────────────────────────────────
clean:
	find . -name '*.so' -delete
	find . -name '*.wpo' -delete
	rm -f gitsafe-bin gitsafe-musl gitsafe-musl.sha256

# ── Help ─────────────────────────────────────────────────────────────────────
help:
	@echo "gitsafe — secret-scanning git hooks"
	@echo ""
	@echo "Development:"
	@echo "  make run ARGS='...'           Run gitsafe in interpreter mode"
	@echo "  make test                     Run test suite"
	@echo ""
	@echo "Native binary (requires local Chez + Jerboa):"
	@echo "  make binary                   Build gitsafe-bin (dynamic, native)"
	@echo "  make install                  Build + install to ~/.local/bin"
	@echo ""
	@echo "Static binary (zero runtime dependencies):"
	@echo "  make gitsafe-musl             Docker build (canonical, reproducible)"
	@echo "  make gitsafe-musl-local       Local build (requires musl-gcc + musl Chez)"
	@echo "  make install-musl             Docker build + install to ~/.local/bin"
	@echo "  make verify-harden            Verify binary hardening (stripped, no leaks)"
	@echo ""
	@echo "  make clean                    Remove all build artifacts"
