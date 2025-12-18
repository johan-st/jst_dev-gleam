.PHONY: help dev dev-server test fmt check build deploy preview preview-stop clean

help: ## Show this help message
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

dev: build-frontend dev-server ## Build frontend and run server

dev-server: ## Run backend server locally
	@mkdir -p data
	cd server && DB_PATH=../data/local.db JWT_SECRET=dev_secret WEB_HASH_SALT=dev_salt gleam run -m jst_server/app

test: ## Run all tests
	cd shared && gleam test
	cd server && gleam test
	cd client && gleam test

fmt: ## Format all code
	cd shared && gleam format
	cd server && gleam format
	cd client && gleam format

check: fmt test ## Format + test

build-frontend: ## Build frontend to server priv/static
	@mkdir -p server/priv/static
	cd client && gleam run -m lustre/dev build --minify --outdir=../server/priv/static
	cp client/index.html server/priv/static/

build: check build-frontend ## Build full application
	cd server && gleam build

deploy: build ## Deploy to production
	fly deploy

preview: ## Deploy to preview
	fly -a jst-dev-preview scale count 1 -y && fly deploy --config fly.preview.toml

preview-stop: ## Stop preview
	fly -a jst-dev-preview scale count 0 -y

clean: ## Clean build artifacts
	rm -rf build data/local.db */build server/priv/static
