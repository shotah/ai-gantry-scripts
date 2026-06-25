.DEFAULT_GOAL := help

COMPOSE       := docker compose
SERVICE       := openclaw
IMAGE         := docker-open-claw:latest
ENV_FILE      := .env
ENV_EXAMPLE   := .env.example

# Detect Windows vs Unix for file copy
ifeq ($(OS),Windows_NT)
  MKDIR    := mkdir
  RM_RF    := rmdir /s /q
  ENV_COPY := powershell -NoProfile -Command "if (-not (Test-Path '$(ENV_FILE)')) { Copy-Item '$(ENV_EXAMPLE)' '$(ENV_FILE)'; Write-Host 'Created $(ENV_FILE) — edit it with your API keys' } else { Write-Host '$(ENV_FILE) already exists (use make env-force to overwrite)' }"
  ENV_FORCE := powershell -NoProfile -Command "Copy-Item '$(ENV_EXAMPLE)' '$(ENV_FILE)' -Force; Write-Host 'Overwrote $(ENV_FILE) from $(ENV_EXAMPLE)'"
  MKDIR_DATA := powershell -NoProfile -Command "New-Item -ItemType Directory -Force -Path data/workspace, data/google | Out-Null"
else
  MKDIR    := mkdir -p
  RM_RF    := rm -rf
  ENV_COPY := @if [ -f $(ENV_FILE) ]; then \
                echo "$(ENV_FILE) already exists (use 'make env-force' to overwrite)"; \
              else \
                cp $(ENV_EXAMPLE) $(ENV_FILE) && echo "Created $(ENV_FILE) — edit it with your API keys"; \
              fi
  ENV_FORCE := cp $(ENV_EXAMPLE) $(ENV_FILE) && echo "Overwrote $(ENV_FILE) from $(ENV_EXAMPLE)"
  MKDIR_DATA := $(MKDIR) data/workspace data/google
endif

.PHONY: help env env-force init dirs build build-no-cache pull onboard sync-config up down restart logs ps shell \
        whatsapp-login google-check google-credentials google-install google-setup google-auth google-status clean

help: ## Show available commands
	@echo.
	@echo   docker_open_claw
	@echo   =================
	@echo.
	@powershell -NoProfile -Command "$$content = Get-Content 'Makefile' -Raw; $$content -split \"`n\" | Where-Object { $$_ -match '^[a-zA-Z0-9_-]+:.*## ' } | ForEach-Object { if ($$_ -match '^([a-zA-Z0-9_-]+):.*?## (.+)$$') { Write-Host ('  {0,-20} {1}' -f $$matches[1], $$matches[2]) } }" 2>nul || \
	grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*## "}; {printf "  %-20s %s\n", $$1, $$2}'
	@echo.
	@echo   Quick start:  make init   then edit .env   then   make up
	@echo.

env: ## Create .env from .env.example (skips if .env already exists)
	$(ENV_COPY)

env-force: ## Overwrite .env from .env.example
	$(ENV_FORCE)

dirs: ## Create local data directories for persistent storage
	$(MKDIR_DATA)
	@echo Data directories ready under ./data/

init: env dirs ## First-time setup: create .env and data directories
	@echo.
	@echo Next steps:
	@echo   1. Edit .env with your GEMINI_API_KEY and WHATSAPP_ALLOW_FROM
	@echo   2. Google (optional): docs/google-workspace.md — dedicated bot Gmail + make google-setup
	@echo   3. make build, then make onboard, then make up
	@echo   4. make whatsapp-login
	@echo.

build: ## Build the Docker image
	$(COMPOSE) build $(SERVICE)

build-no-cache: ## Build the Docker image without cache
	$(COMPOSE) build --no-cache $(SERVICE)

pull: ## Pull the upstream OpenClaw base image
	docker pull $(or $(OPENCLAW_IMAGE),ghcr.io/openclaw/openclaw:latest)

onboard: ## First-run OpenClaw setup (run once before make up)
	$(COMPOSE) run --rm --no-deps --entrypoint sh $(SERVICE) -c \
		'node dist/index.js onboard --non-interactive --mode local --auth-choice gemini-api-key --gemini-api-key "$$GEMINI_API_KEY" --gateway-port 18789 --gateway-bind "$${OPENCLAW_GATEWAY_BIND:-lan}" --skip-health'
	@$(MAKE) sync-config

sync-config: ## Sync .env → data/openclaw.json (WhatsApp allowlist, model, timezone)
ifeq ($(OS),Windows_NT)
	@powershell -NoProfile -Command "if (-not (Test-Path 'data/openclaw.json')) { Write-Error 'Run make onboard first'; exit 1 }"
	@node scripts/sync-config.js
else
	@test -f data/openclaw.json || (echo "Run make onboard first" && exit 1)
	@node scripts/sync-config.js
endif

up: sync-config ## Start containers in the background
	$(COMPOSE) up -d $(SERVICE)

down: ## Stop and remove containers
	$(COMPOSE) down

restart: ## Restart running containers
	$(COMPOSE) restart $(SERVICE)

logs: ## Follow container logs
	$(COMPOSE) logs -f $(SERVICE)

ps: ## Show container status
	$(COMPOSE) ps

shell: ## Open a shell inside the running container
	$(COMPOSE) exec $(SERVICE) sh

whatsapp-login: ## Link WhatsApp (scan QR with the assistant phone)
	$(COMPOSE) exec -it $(SERVICE) node dist/index.js channels login --channel whatsapp

google-check: dirs ## Verify data/google/credentials.json exists
ifeq ($(OS),Windows_NT)
	@powershell -NoProfile -Command "if (-not (Test-Path 'data/google/credentials.json')) { Write-Host 'Missing data/google/credentials.json'; Write-Host 'See docs/google-workspace.md or run: make google-credentials SRC=path\to\client_secret.json'; exit 1 } else { Write-Host 'OK: data/google/credentials.json' }"
else
	@test -f data/google/credentials.json || (echo "Missing data/google/credentials.json — see docs/google-workspace.md" && exit 1)
	@echo "OK: data/google/credentials.json"
endif

google-credentials: dirs ## Copy OAuth JSON to data/google/credentials.json (SRC=path)
ifndef SRC
	$(error Usage: make google-credentials SRC=/path/to/client_secret.json)
endif
ifeq ($(OS),Windows_NT)
	@powershell -NoProfile -Command "Copy-Item -Path '$(SRC)' -Destination 'data/google/credentials.json' -Force; Write-Host 'Installed data/google/credentials.json'"
else
	@cp "$(SRC)" data/google/credentials.json
	@echo "Installed data/google/credentials.json"
endif

google-install: ## Install the gog (Google Workspace) skill in the container
	$(COMPOSE) exec $(SERVICE) sh -c "npx --yes clawhub@latest install gog"

google-setup: google-check ## Check creds and install gog skill (container must be running)
	$(COMPOSE) exec $(SERVICE) sh -c "npx --yes clawhub@latest install gog"
	@echo.
	@echo Google skill installed. Next:
	@echo   1. Set GOG_ACCOUNT + GOG_KEYRING_PASSWORD in .env, then: make restart
	@echo   2. make google-auth
	@echo   3. make google-status
	@echo.
	@echo Full guide: docs/google-workspace.md

google-auth: google-check ## OAuth login for GOG_ACCOUNT (interactive)
	$(COMPOSE) exec -it $(SERVICE) sh -c \
		'gog auth credentials /home/node/.config/gogcli/credentials.json && gog auth add "$$GOG_ACCOUNT" --services gmail,calendar,drive,docs'

google-status: ## Show gog OAuth connection status
	$(COMPOSE) exec $(SERVICE) sh -c 'gog auth status || true'

clean: ## Stop containers and remove built image
	$(COMPOSE) down --rmi local 2>nul || $(COMPOSE) down --rmi local
