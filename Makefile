# claude-autoresume
#
# The code is shell, so there is nothing to build. This exists to make the
# development loop and the toolchain one command each.

SHELL := /bin/sh
.DEFAULT_GOAL := help

REPO := $(shell pwd)

.PHONY: help setup dev lint fmt test install uninstall status logs clean

help: ## Show this help
	@printf '\n\033[1mclaude-autoresume\033[0m\n\n'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@printf '\n'

setup: ## Install the toolchain (asdf tools + bun deps + git hooks)
	@printf '\033[1m→ toolchain\033[0m\n'
	@if command -v asdf >/dev/null 2>&1; then \
		for p in bun shellcheck shfmt; do asdf plugin add $$p 2>/dev/null || true; done; \
		asdf install; \
	else \
		printf '  asdf not found — install it, or provide bun, shellcheck and shfmt yourself\n'; \
	fi
	@command -v jq >/dev/null 2>&1 || printf '  \033[33m!\033[0m jq is required at runtime: brew install jq\n'
	@printf '\033[1m→ dependencies + git hooks\033[0m\n'
	@bun install
	@printf '\n  ready. \033[36mmake dev\033[0m to install from this checkout.\n\n'

dev: ## Install live from this checkout (edits take effect immediately)
	@CLAUDE_AUTORESUME_PREFIX=$(REPO) sh ./install.sh
	@printf '  \033[2mthe service now points at %s — do not move or delete it\033[0m\n\n' "$(REPO)"

lint: ## shellcheck + shfmt on sh files, zsh -n on zsh files
	@./scripts/lint.sh

fmt: ## Apply shfmt formatting in place
	@./scripts/lint.sh --fix

test: ## Full install/uninstall integration suite in a throwaway HOME
	@./test/run.sh

install: ## Install normally, into ~/.local/share
	@sh ./install.sh

uninstall: ## Remove it and restore your original status line
	@sh ./uninstall.sh

status: ## Show what is armed right now
	@claude-autoresume-status 2>/dev/null || ./bin/claude-autoresume-status

logs: ## Tail the watcher log
	@tail -f "$${CLAUDE_AUTORESUME_DIR:-$$HOME/.claude/autoresume}/watch.log"

clean: ## Remove build/test leftovers
	@rm -rf test/.sandbox node_modules
	@printf '  cleaned\n'
