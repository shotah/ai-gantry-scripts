.DEFAULT_GOAL := help

COMPOSE := docker compose
SERVICE := zeroclaw
ENV_FILE := .env
ENV_EXAMPLE := .env.example
CONFIG_EXAMPLE := config/config.toml.example
PERSONA_DIR := config/agents/main/workspace

# Bust mcp-beam / youtube-go-mcp fetch stages so `latest` re-resolves each build.
ifeq ($(OS),Windows_NT)
  TOOLS_CACHEBUST ?= $(shell powershell -NoProfile -Command "[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()")
else
  TOOLS_CACHEBUST ?= $(shell date +%s)
endif

ifeq ($(OS),Windows_NT)
  ENV_COPY := powershell -NoProfile -Command "if (-not (Test-Path '$(ENV_FILE)')) { Copy-Item '$(ENV_EXAMPLE)' '$(ENV_FILE)'; Write-Host 'Created $(ENV_FILE) — edit GEMINI_API_KEY and Telegram vars' } else { Write-Host '$(ENV_FILE) already exists (use make env-force to overwrite)' }"
  ENV_FORCE := powershell -NoProfile -Command "Copy-Item '$(ENV_EXAMPLE)' '$(ENV_FILE)' -Force; Write-Host 'Overwrote $(ENV_FILE)'"
  MKDIR_DATA := powershell -NoProfile -Command "New-Item -ItemType Directory -Force -Path data/.zeroclaw, data/data | Out-Null"
  RM_GARMIN_SESSION := powershell -NoProfile -Command "Remove-Item -Force -ErrorAction SilentlyContinue 'secrets/garmin/session.json'"
  # SOUL.example.md → SOUL.md  ($$ → $ for Make; $$_ → $_ in PowerShell)
  PERSONA_COPY := powershell -NoProfile -Command "New-Item -ItemType Directory -Force -Path '$(PERSONA_DIR)' | Out-Null; Get-ChildItem '$(PERSONA_DIR)\*.example.md' | ForEach-Object { $$dest = Join-Path $$_.DirectoryName ($$_.Name.Replace('.example.md','.md')); if (-not (Test-Path $$dest)) { Copy-Item $$_.FullName $$dest; Write-Host ('Created ' + $$dest + ' — edit personal details (gitignored)') } else { Write-Host ($$dest + ' already exists (use make persona-force to overwrite)') } }"
  PERSONA_FORCE := powershell -NoProfile -Command "New-Item -ItemType Directory -Force -Path '$(PERSONA_DIR)' | Out-Null; Get-ChildItem '$(PERSONA_DIR)\*.example.md' | ForEach-Object { $$dest = Join-Path $$_.DirectoryName ($$_.Name.Replace('.example.md','.md')); Copy-Item $$_.FullName $$dest -Force; Write-Host ('Overwrote ' + $$dest) }"
  REMOTE := powershell -NoProfile -ExecutionPolicy Bypass -File scripts/remote.ps1
else
  ENV_COPY := @if [ -f $(ENV_FILE) ]; then \
                echo "$(ENV_FILE) already exists (use 'make env-force' to overwrite)"; \
              else \
                cp $(ENV_EXAMPLE) $(ENV_FILE) && echo "Created $(ENV_FILE) — edit GEMINI_API_KEY and Telegram vars"; \
              fi
  ENV_FORCE := cp $(ENV_EXAMPLE) $(ENV_FILE) && echo "Overwrote $(ENV_FILE)"
  MKDIR_DATA := mkdir -p data/.zeroclaw data/data
  RM_GARMIN_SESSION := rm -f secrets/garmin/session.json
  PERSONA_COPY := @mkdir -p $(PERSONA_DIR); \
	for f in $(PERSONA_DIR)/*.example.md; do \
	  [ -e "$$f" ] || continue; \
	  dest="$(PERSONA_DIR)/$$(basename "$$f" | sed 's/\.example\.md$$/.md/')"; \
	  if [ ! -f "$$dest" ]; then \
	    cp "$$f" "$$dest" && echo "Created $$dest — edit personal details (gitignored)"; \
	  else echo "$$dest already exists (use make persona-force to overwrite)"; fi; \
	done
  PERSONA_FORCE := @mkdir -p $(PERSONA_DIR); \
	for f in $(PERSONA_DIR)/*.example.md; do \
	  [ -e "$$f" ] || continue; \
	  dest="$(PERSONA_DIR)/$$(basename "$$f" | sed 's/\.example\.md$$/.md/')"; \
	  cp "$$f" "$$dest" && echo "Overwrote $$dest"; \
	done
  REMOTE := bash scripts/remote.sh
endif

.PHONY: help env env-force dirs init sync-config config persona persona-force build pull up down restart logs ps status shell clean \
        strava-auth garmin-auth google-auth google-mcp-import ytmusic-auth \
        remote-check remote-sync remote-up remote-down remote-restart remote-logs remote-ps remote-status \
        remote-pull remote-ssh remote-deploy remote-bind

help: ## Show available commands
	@echo.
	@echo   tim  /  a lean, self-hosted assistant on ZeroClaw
	@echo   ================================================
	@echo   Gemini + Telegram agent in Docker. No WhatsApp. No published ports.
	@echo.
	@echo   Quick start (local)
	@echo   -------------------
	@echo     make init              Create .env, data dirs, config
	@echo     # edit .env            GEMINI_API_KEY, TELEGRAM_BOT_TOKEN,
	@echo     #                      TELEGRAM_ALLOWED_USERS
	@echo     make sync-config       Apply .env into config/config.toml
	@echo     make build             Thin image: distroless + gws binary
	@echo     make up                Build if needed + start daemon
	@echo     make logs              Watch logs / message your Telegram bot
	@echo.
	@echo   Quick start (Ubuntu server from this PC)
	@echo   ----------------------------------------
	@echo     # set DEPLOY_HOST, DEPLOY_USER, DEPLOY_PATH in .env
	@echo     make remote-check      Verify SSH + Docker on the server
	@echo     make remote-deploy     Sync + build + up on server
	@echo     make remote-logs       Follow server logs
	@echo.
	@echo   Setup
	@echo   -----
	@echo     help                   Show this help (default)
	@echo     env                    Create .env from .env.example (skip if exists)
	@echo     env-force              Overwrite .env from .env.example
	@echo     persona                Create workspace *.md from *.example.md (skip if exists)
	@echo     persona-force          Overwrite workspace *.md from examples (wipes local edits)
	@echo     dirs                   Create ./data directories
	@echo     config                 Install config.toml template if missing
	@echo     sync-config            Sync model + Telegram peers into config/config.toml
	@echo     init                   env + dirs + config + persona + sync-config
	@echo.
	@echo     docs/persona.md        SOUL/USER system prompt (examples vs personal files)
	@echo     docs/models.md         Gemini / Grok chat provider swap
	@echo.
	@echo   Local Docker
	@echo   ------------
	@echo     build                  Build thin image (upstream distroless + gws)
	@echo     pull                   Pull upstream ZeroClaw base image
	@echo     up                     sync-config + compose up -d --build
	@echo     down                   Stop and remove containers
	@echo     restart                Restart containers
	@echo     logs                   Follow container logs
	@echo     ps                     Show compose status
	@echo     status                 zeroclaw health check inside container
	@echo     shell                  Debug shell (debian image; runtime is distroless)
	@echo     clean                  Same as down (keeps ./data)
	@echo     strava-auth            One-time Strava OAuth; writes secrets/strava/tokens.json
	@echo     garmin-auth            One-time Garmin login; writes secrets/garmin/session.json
	@echo     google-auth            One-time Google OAuth via container; writes google-mcp creds
	@echo     google-mcp-import      Legacy: import gws export into google-mcp (prefer google-auth)
	@echo     ytmusic-auth           YouTube Music headers -^> secrets/ytmusic/headers.json
	@echo.
	@echo   Remote deploy  (needs OpenSSH; see docs/deploy.md)
	@echo   --------------------------------------------------
	@echo     remote-check           SSH + docker available on DEPLOY_HOST?
	@echo     remote-sync            scp compose, .env, config, secrets to server
	@echo     remote-up              build + up -d on server
	@echo     remote-down            Stop stack on server
	@echo     remote-restart         Restart stack on server
	@echo     remote-logs            Follow logs on server
	@echo     remote-ps              compose ps on server
	@echo     remote-status          Health check on server
	@echo     remote-pull            Pull upstream base on server
	@echo     remote-bind            Pair Telegram (make remote-bind  or  TG_USER=id)
	@echo     remote-ssh             Interactive SSH in DEPLOY_PATH
	@echo     remote-ssh CMD='...'   Run one remote command in DEPLOY_PATH
	@echo     remote-deploy          remote-sync + remote-up
	@echo.
	@echo   Docs
	@echo   ----
	@echo     docs/telegram.md       BotFather + Telegram peers
	@echo     docs/persona.md        Tim prompt (SOUL/USER) — examples are committed
	@echo     docs/models.md         Chat model / Grok swap
	@echo     docs/whatsapp.md       WhatsApp Web friend / group (optional)
	@echo     docs/google-workspace.md Go MCP + OAuth import (Gmail/Docs/…)
	@echo     docs/strava.md         Strava workouts via strava-mcp (optional)
	@echo     docs/garmin.md         Garmin sleep/weight via go-garmin MCP (optional)
	@echo     docs/cast.md           Google Cast/DLNA via mcp-beam Go MCP (optional)
	@echo     docs/ytmusic.md        YouTube Music via youtube-go-mcp (optional)
	@echo     docs/deploy.md         Windows -^> Ubuntu remote deploy
	@echo     README.md              Overview and architecture
	@echo.
	@echo   Required .env keys: GEMINI_API_KEY  TELEGRAM_BOT_TOKEN  TELEGRAM_ALLOWED_USERS
	@echo   Remote .env keys:   DEPLOY_HOST  DEPLOY_USER  DEPLOY_PATH  [DEPLOY_SSH_KEY]
	@echo.

env: ## Create .env from .env.example (skips if exists)
	$(ENV_COPY)

env-force: ## Overwrite .env from .env.example
	$(ENV_FORCE)

dirs: ## Create data directories
	$(MKDIR_DATA)
	@echo Data dirs ready under ./data/

config: dirs ## Install config template into config/config.toml if missing
ifeq ($(OS),Windows_NT)
	@powershell -NoProfile -Command "if (-not (Test-Path 'config/config.toml')) { Copy-Item '$(CONFIG_EXAMPLE)' 'config/config.toml'; Write-Host 'Installed config/config.toml' } else { Write-Host 'config.toml already present' }"
else
	@if [ ! -f config/config.toml ]; then \
	  cp $(CONFIG_EXAMPLE) config/config.toml && echo "Installed config/config.toml"; \
	else echo "config.toml already present"; fi
endif

persona: ## Create agent workspace *.md from *.example.md (skips existing)
	$(PERSONA_COPY)

persona-force: ## Overwrite agent workspace *.md from examples (destructive)
	$(PERSONA_FORCE)

sync-config: dirs ## Sync .env model + Telegram allowlist into config/config.toml
	@node scripts/sync-config.js

init: env dirs config persona sync-config ## First-time setup: .env, dirs, config, persona
	@echo.
	@echo Next steps:
	@echo   1. Edit .env — GEMINI_API_KEY, TELEGRAM_*, and DEPLOY_* for remote
	@echo   2. Edit $(PERSONA_DIR)/USER.md (and friends) — personal; gitignored
	@echo   3. Local:  make up
	@echo   4. Remote: make remote-deploy
	@echo.
	@echo Guides: docs/telegram.md   docs/whatsapp.md   docs/google-workspace.md   docs/deploy.md
	@echo.

build: ## Build thin image (distroless + gws binary)
	$(COMPOSE) build --build-arg TOOLS_CACHEBUST=$(TOOLS_CACHEBUST) $(SERVICE)

pull: ## Pull upstream ZeroClaw base image
	docker pull ghcr.io/zeroclaw-labs/zeroclaw:latest

up: sync-config ## Start ZeroClaw daemon locally (build if needed; no published ports)
	$(COMPOSE) build --build-arg TOOLS_CACHEBUST=$(TOOLS_CACHEBUST) $(SERVICE)
	$(COMPOSE) up -d $(SERVICE)

down: ## Stop and remove local containers
	$(COMPOSE) down

restart: ## Restart local daemon
	$(COMPOSE) restart $(SERVICE)

logs: ## Follow local logs
	$(COMPOSE) logs -f $(SERVICE)

ps: ## Local container status
	$(COMPOSE) ps

status: ## Local ZeroClaw health
	$(COMPOSE) exec $(SERVICE) zeroclaw status --format=exit-code && echo OK || echo FAILED

shell: ## Shell via debian image (distroless has no shell)
	docker run --rm -it --entrypoint sh \
	  -v "$(CURDIR)/data:/zeroclaw-data" \
	  --env-file .env \
	  ghcr.io/zeroclaw-labs/zeroclaw:debian

clean: ## Stop local containers (keeps ./data)
	$(COMPOSE) down

strava-auth: ## One-time Strava OAuth in a throwaway container (see docs/strava.md)
	@echo Opening Strava OAuth. A URL will be printed below — open it in your browser and approve.
	$(COMPOSE) run --rm --build -p 19876:19876 --entrypoint strava-mcp $(SERVICE) auth

garmin-auth: ## Garmin login; clears stale session.json then writes a fresh one (see docs/garmin.md)
	@echo Clearing stale secrets/garmin/session.json if present...
	-$(RM_GARMIN_SESSION)
	@echo Garmin interactive login (email / password / MFA). Session lands in secrets/garmin/.
	$(COMPOSE) run --rm --build -it --entrypoint garmin $(SERVICE) login

ytmusic-auth: ## YouTube Music browser headers → secrets/ytmusic/headers.json (see docs/ytmusic.md)
	@echo DevTools → Network → browse → Request Headers: copy cookie, then x-goog-authuser.
	@echo The CLI prompts for each value. See docs/ytmusic.md.
	$(COMPOSE) run --rm --build -it --entrypoint youtube-go-mcp $(SERVICE) \
	  auth --out /zeroclaw-data/.config/ytmusic/headers.json

google-auth: ## Google Workspace OAuth via container; writes secrets/google-mcp (see docs/google-workspace.md)
ifeq ($(OS),Windows_NT)
	powershell -NoProfile -ExecutionPolicy Bypass -File scripts/google-auth.ps1
else
	bash scripts/google-auth.sh
endif

google-mcp-import: ## Legacy: import gws export into secrets/google-mcp (prefer make google-auth)
ifeq ($(OS),Windows_NT)
	powershell -NoProfile -ExecutionPolicy Bypass -File scripts/google-mcp-import.ps1
else
	bash scripts/google-mcp-import.sh
endif

# --- Remote Ubuntu server (from Windows via OpenSSH) -------------------------

remote-check: ## Test SSH + Docker on DEPLOY_HOST
	$(REMOTE) check

remote-sync: sync-config persona ## Copy compose/.env/config/persona to server (does not sync data volume)
	$(REMOTE) sync

remote-up: ## docker compose up -d on server
	$(REMOTE) up

remote-down: ## docker compose down on server
	$(REMOTE) down

remote-restart: ## Restart stack on server
	$(REMOTE) restart

remote-logs: ## Follow logs on server
	$(REMOTE) logs

remote-ps: ## docker compose ps on server
	$(REMOTE) ps

remote-status: ## Health check on server
	$(REMOTE) status

remote-pull: ## Pull image on server
	$(REMOTE) pull

remote-bind: ## Pair Telegram user (TG_USER=id or first TELEGRAM_ALLOWED_USERS)
	$(REMOTE) bind $(TG_USER)

remote-ssh: ## SSH into server (cd DEPLOY_PATH). Extra args: make remote-ssh CMD='ls'
	$(REMOTE) ssh $(CMD)

remote-deploy: remote-sync remote-up ## Sync files then start on server
	@echo.
	@echo Deployed. If Telegram asks to bind: make remote-bind
	@echo.
