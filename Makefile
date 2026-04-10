JERBOA_HOME ?= $(realpath $(CURDIR)/../jerboa)
SCHEME ?= scheme
BIN_DIR := $(HOME)/.local/bin
TEMPLATE_DIR := $(HOME)/.git-templates
HOOK_DIR := $(TEMPLATE_DIR)/hooks

.PHONY: run test binary install clean linux linux-local docker \
        verify-harden help install-native macos gitsafe-macos

run:
	JERBOA_HOME=$(JERBOA_HOME) \
		$(SCHEME) -q --libdirs $(CURDIR):$(JERBOA_HOME)/lib --script gitsafe/main.ss -- $(ARGS)

binary:
	JERBOA_HOME=$(JERBOA_HOME) \
		$(SCHEME) -q --libdirs $(CURDIR):$(JERBOA_HOME)/lib --script build-binary.ss

test:
	JERBOA_HOME=$(JERBOA_HOME) \
		$(SCHEME) -q --libdirs $(CURDIR):$(JERBOA_HOME)/lib --script test/test-gitsafe.ss

install: $(if $(filter Darwin,$(shell uname -s)),gitsafe-macos,linux)
	mkdir -p $(BIN_DIR)
ifeq ($(shell uname -s),Darwin)
	cp gitsafe-macos $(BIN_DIR)/gitsafe
	@echo "Installed gitsafe to $(BIN_DIR)/gitsafe (macOS binary)"
else
	cp gitsafe-musl $(BIN_DIR)/gitsafe
	@echo "Installed gitsafe to $(BIN_DIR)/gitsafe (static binary)"
endif
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

install-native: binary
	mkdir -p $(BIN_DIR)
	cp gitsafe-bin $(BIN_DIR)/gitsafe
	@echo "Installed gitsafe-bin to $(BIN_DIR)/gitsafe (native, requires Chez runtime)"

# ── macOS binary (maximally static) ─────────────────────────────────────────
# Statically links Chez kernel, lz4, zlib, ncurses.
# Only libSystem (always present on macOS) and libiconv are dynamic.
# Use `make macos` or `make gitsafe-macos` to build on macOS.

macos: gitsafe-macos

gitsafe-macos:
	JERBOA_HOME=$(JERBOA_HOME) \
		./build-gitsafe-macos.sh

# ── Static musl binary ──────────────────────────────────────────────────────
# Use `make linux` to build in Docker (canonical, reproducible).
# Use `make linux-local` to build directly on the host (requires
# musl-gcc and a musl-built Chez at ~/chez-musl or JERBOA_MUSL_CHEZ_PREFIX).

linux: docker

linux-local:
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

verify-harden: linux
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
	rm -f gitsafe-bin gitsafe-musl gitsafe-musl.sha256 gitsafe-macos gitsafe-macos.sha256

# ── Help ─────────────────────────────────────────────────────────────────────
help:
	@echo "gitsafe — secret-scanning git hooks"
	@echo ""
	@echo "Development:"
	@echo "  make run ARGS='...'           Run gitsafe in interpreter mode"
	@echo "  make test                     Run test suite"
	@echo ""
	@echo "Build & install:"
	@echo "  make macos                    macOS build (statically linked, no runtime deps)"
	@echo "  make linux                    Linux static build via Docker (canonical)"
	@echo "  make linux-local              Linux static build locally (requires musl-gcc)"
	@echo "  make install                  Build + install to ~/.local/bin (auto-detects OS)"
	@echo "  make verify-harden            Verify binary hardening (stripped, no leaks)"
	@echo ""
	@echo "Native binary (requires local Chez + Jerboa):"
	@echo "  make binary                   Build gitsafe-bin (dynamic, native)"
	@echo "  make install-native           Build native + install to ~/.local/bin"
	@echo ""
	@echo "  make clean                    Remove all build artifacts"
