JERBOA_HOME ?= $(realpath $(CURDIR)/../jerboa)
SCHEME ?= scheme
BIN_DIR := $(HOME)/.local/bin
TEMPLATE_DIR := $(HOME)/.git-templates
HOOK_DIR := $(TEMPLATE_DIR)/hooks

.PHONY: run test binary install clean

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

clean:
	find . -name '*.so' -delete
	find . -name '*.wpo' -delete
	rm -f gitsafe-bin
