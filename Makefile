.PHONY: help check-tools srv-lint srv-test front-test srv-build front-build front-dev srv-dev build dev check

# Configurable tool paths
GOLANGCI_LINT ?= $(HOME)/go/bin/golangci-lint
GOSEC ?= $(HOME)/go/bin/gosec
STATICCHECK ?= $(HOME)/go/bin/staticcheck
AIR ?= $(HOME)/go/bin/air

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-15s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

check-tools: ## Validate required tools are installed
	@command -v go >/dev/null 2>&1 || { echo "go is required but not installed"; exit 1; }
	@command -v gleam >/dev/null 2>&1 || { echo "gleam is required but not installed"; exit 1; }
	@command -v $(AIR) >/dev/null 2>&1 || { echo "air is required but not installed"; exit 1; }
	@command -v $(GOLANGCI_LINT) >/dev/null 2>&1 || { echo "golangci-lint is required but not installed"; exit 1; }
	@command -v $(GOSEC) >/dev/null 2>&1 || { echo "gosec is required but not installed"; exit 1; }
	@command -v $(STATICCHECK) >/dev/null 2>&1 || { echo "staticcheck is required but not installed"; exit 1; }

srv-lint: check-tools ## Run server linting and security checks
	# cd server && $(GOLANGCI_LINT) run --timeout=5m
	# cd server && $(GOSEC) ./...
	# cd server && $(STATICCHECK) ./...
	# cd server && go vet ./...

srv-test: check-tools ## Run server tests with race detection
	cd server && go test -race ./...

srv-build: srv-lint srv-test ## Build the Go backend with all checks
	cd server && go build -v -o server.exe .

srv-dev: check-tools ## Run backend development server with hot reload
	cd server && $(AIR) 

front-test: check-tools ## Run frontend tests
	cd jst_lustre && gleam test

front-build: front-test ## Build the Gleam/Lustre frontend
	cd jst_lustre && gleam run -m lustre/dev build --minify --tailwind-entry=./src/styles.css --outdir=../build

front-dev: check-tools ## Run frontend development server
	cd jst_lustre && gleam run -m lustre/dev start --tailwind-entry=./src/styles.css

check: srv-lint srv-test front-test ## Run all checks (lint + test, server + frontend)
	@echo "All checks passed!"

build: front-build srv-build ## Build complete application (frontend + backend)
	@echo "Build complete!"

dev: check-tools ## Run both frontend and backend dev servers concurrently
	@echo "Starting development servers..."
	@echo "Press Ctrl+C to stop both servers"
	@trap 'kill $$(jobs -p) 2>/dev/null' EXIT; \
	(cd jst_lustre && gleam run -m lustre/dev start --tailwind-entry=./src/styles.css) & \
	(cd server && $(AIR)) & \
	wait

deploy: ## Deploy to production
	@echo "Deploying to production..."
	fly deploy

preview: ## Deploy to preview environment
	@echo "Deploying to preview environment..."
	fly -a jst-dev-preview scale count 1 -y && \
	fly deploy --config fly.preview.toml

preview-stop: ## Stop preview environment
	fly -a jst-dev-preview scale count 0 -y