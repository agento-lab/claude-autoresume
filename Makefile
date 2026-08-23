.PHONY: help setup check-system install-deps setup-git-hooks dev lint lint-fix fmt security test ci install uninstall uninstall-dev status logs update clean

# Colors for output
GREEN = \033[0;32m
YELLOW = \033[1;33m
RED = \033[0;31m
BLUE = \033[0;34m
NC = \033[0m # No Color

# Default target
.DEFAULT_GOAL := help

REPO := $(shell pwd)

# Tools this repo cannot work without. Format: <command>:<how to get it>
REQUIRED_TOOLS := bun:asdf zsh:preinstalled-on-macos jq:brew shellcheck:asdf shfmt:asdf

help: ## Show this help message
	@echo "$(BLUE)claude-autoresume Development Commands$(NC)"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ { printf "  $(GREEN)%-15s$(NC) %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo ""

setup: check-system install-deps setup-git-hooks ## Complete development environment setup
	@echo ""
	@echo "$(GREEN)🎉 Setup complete!$(NC)"
	@echo ""
	@echo "$(BLUE)Next steps:$(NC)"
	@echo "  make dev     # Install live from this checkout"
	@echo "  make test    # Run the integration suite"
	@echo "  make ci      # Everything CI runs"
	@echo ""

check-system: ## Check system prerequisites
	@echo "$(BLUE)🔍 Checking system prerequisites...$(NC)"
	@echo ""
	@if [ "$$(uname -s)" != "Darwin" ]; then \
		echo "$(RED)⚠️  macOS only — this uses launchd, osascript and BSD stat/date$(NC)"; \
		exit 1; \
	fi
	@echo "$(GREEN)✅ macOS$(NC)"
	@if ! command -v asdf >/dev/null 2>&1; then \
		echo "$(YELLOW)⚠️  asdf not found — install it, or provide the tools yourself:$(NC)"; \
		echo "  brew install asdf"; \
	else \
		echo "$(GREEN)✅ asdf installed$(NC)"; \
	fi
	@if ! command -v jq >/dev/null 2>&1; then \
		echo "$(YELLOW)⚠️  jq not found (required at runtime, not just for dev): brew install jq$(NC)"; \
	else \
		echo "$(GREEN)✅ jq installed$(NC)"; \
	fi

install-deps: ## Install development dependencies (asdf tools + bun packages)
	@echo ""
	@echo "$(BLUE)📦 Installing dependencies...$(NC)"
	@echo ""
	@if command -v asdf >/dev/null 2>&1; then \
		for p in bun shellcheck shfmt; do asdf plugin add $$p 2>/dev/null || true; done; \
		asdf install || exit 1; \
		echo "$(GREEN)✅ asdf tools installed$(NC)"; \
	fi
	@bun install
	@echo "$(GREEN)✅ Packages installed$(NC)"

setup-git-hooks: ## Set up Git hooks with Husky
	@echo ""
	@echo "$(BLUE)🪝 Setting up Git hooks...$(NC)"
	@echo ""
	@if [ -d ".git" ]; then \
		bun run prepare || exit 1; \
		echo "$(GREEN)✅ Git hooks configured with Husky$(NC)"; \
	else \
		echo "$(YELLOW)⚠️  Not a git repository. Skipping Git hooks setup.$(NC)"; \
	fi

dev: ## Install live from this checkout (edits take effect immediately)
	@echo "$(BLUE)🔧 Installing from $(REPO)...$(NC)"
	@CLAUDE_AUTORESUME_PREFIX="$(REPO)" sh ./install.sh
	@echo "$(YELLOW)⚠️  The service now points at this checkout — do not move or delete it$(NC)"

lint: ## Run code linter (shellcheck + shfmt on sh, zsh -n on zsh)
	@echo "$(BLUE)🔍 Running code linter...$(NC)"
	@./scripts/lint.sh

lint-fix: ## Run code linter with auto-fix
	@echo "$(BLUE)🔧 Running code linter with auto-fix...$(NC)"
	@./scripts/lint.sh --fix

fmt: lint-fix ## Alias for lint-fix

security: ## Run security vulnerability scanner
	@echo "$(BLUE)🔒 Running security scanner...$(NC)"
	@bun audit || true
	@bun audit --audit-level=high
	@echo "$(GREEN)✅ No high or critical advisories$(NC)"

test: ## Run test suite (full install/uninstall in a throwaway HOME)
	@echo "$(BLUE)🧪 Running test suite...$(NC)"
	@./test/run.sh

ci: lint security test ## Run CI checks (lint, security, test)

install: ## Install normally, into ~/.local/share
	@sh ./install.sh

uninstall: ## Remove it and restore your original status line
	@sh ./uninstall.sh

uninstall-dev: ## Undo a `make dev` install (prefix = this checkout)
	@CLAUDE_AUTORESUME_PREFIX="$(REPO)" sh ./uninstall.sh

status: ## Show what is armed right now
	@claude-autoresume-status 2>/dev/null || ./bin/claude-autoresume-status

logs: ## Tail the watcher log
	@tail -f "$${CLAUDE_AUTORESUME_DIR:-$$HOME/.claude/autoresume}/watch.log"

update: ## Update dependencies
	@echo "$(BLUE)🔄 Updating dependencies...$(NC)"
	@bun update
	@echo "$(GREEN)✅ Dependencies updated$(NC)"

clean: ## Clean temporary files and caches
	@echo "$(BLUE)🧹 Cleaning temporary files...$(NC)"
	@rm -rf test/.sandbox node_modules
	@echo "$(GREEN)✅ Cleanup complete$(NC)"
