# SPDX-License-Identifier: AGPL-3.0-or-later
#
# One place to start from. `make` on its own lists everything.

.DEFAULT_GOAL := help
.PHONY: help setup dev dev-web test test-elixir test-delivery test-api test-web \
        test-pglite test-e2e check check-presets up down preflight \
        push-static push-styles

# The toolchain lives in mise.toml (elixir / erlang / node). mise puts
# those on PATH through a *shell* hook, which make's own /bin/sh never
# gets — so `npm` goes missing exactly when you run it from a Makefile,
# an editor task runner, or a bare shell. Route through `mise exec` when
# mise is there; fall through to PATH when it isn't.
MISE := $(shell command -v mise 2>/dev/null)
RUN  := $(if $(MISE),$(MISE) exec --,)

help:  ## list these targets
	@echo "sukhi-fedi"
	@echo
	@grep -hE '^[a-z][a-z0-9_-]*:.*?##' $(MAKEFILE_LIST) \
	  | sed 's/:.*##/\t/' \
	  | awk -F'\t' '{printf "  \033[1m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  Deploy targets need DEPLOY_HOST set."

setup:  ## fetch every project's dependencies
	@if [ -n "$(MISE)" ]; then $(MISE) trust >/dev/null 2>&1 && $(MISE) install; fi
	@command -v bun >/dev/null 2>&1 || echo "note: bun is missing — 'make dev' and 'make test-pglite' need it (https://bun.sh)"
	@command -v nats-server >/dev/null 2>&1 || echo "note: nats-server is missing — 'make dev' runs without streaming (brew install nats-server nats)"
	for d in elixir delivery api combined; do (cd $$d && $(RUN) mix deps.get); done
	cd web && $(RUN) npm install --no-audit --no-fund

# ── Running it locally ──────────────────────────────────────────────────────

dev:  ## run the whole thing locally, no Docker (:4000, IEx shell)
	@bash scripts/dev.sh

dev-web:  ## the SPA dev server (:5173), in a second terminal
	cd web && $(RUN) npm run dev

up:  ## the full docker-compose stack instead (:4000)
	@docker info >/dev/null 2>&1 || { echo "Docker isn't answering — start it first (colima start / Docker Desktop)."; exit 1; }
	@test -f .env || { echo "no .env yet — see the Docker quick start in README.md"; exit 1; }
	@test -f docker-compose.override.yml || cp docker-compose.override.example.yml docker-compose.override.yml
	docker compose up -d --build

down:  ## stop that stack (volumes are kept)
	docker compose down

# ── Checking it ─────────────────────────────────────────────────────────────

test: test-elixir test-delivery test-api test-web  ## every layer's unit tests

test-elixir:
	cd elixir && $(RUN) mix test --no-start

test-delivery:
	cd delivery && $(RUN) mix test --no-start

test-api:
	cd api && $(RUN) mix test --no-start

test-web:
	cd web && $(RUN) npm run check

# The DB-backed integration suite, against an embedded PGlite Postgres —
# no Docker. Extra args pass through to `mix test`:
#   make test-pglite
#   make test-pglite ARGS="test/integration/social_test.exs:97"
test-pglite:  ## DB integration tests on embedded PGlite (no Docker)
	@bash scripts/test-pglite.sh $(ARGS)

# Cross-browser smoke for the SPA (Chromium + Firefox) via Playwright.
# Builds the SPA and runs the flow in web/e2e against `vite preview`.
#   make test-e2e ARGS="--project=firefox"
test-e2e:  ## cross-browser SPA smoke (Playwright)
	cd web && $(RUN) npx playwright test $(ARGS)

# `mix credo --strict` is deliberately not here: credo 1.7.18 crashes on
# Elixir 1.20's sigil tokens (`Protocol.UndefinedError ... for Tuple` out
# of Credo.Code.Token) and exits 1 on every run, so it can only make this
# target useless. Run it by hand once credo catches up.
check: check-presets  ## linters and type checks
	cd web && $(RUN) npm run check

check-presets:
	@bash scripts/check_presets_sync.sh

preflight:  ## pre-deploy verification (see infra/preflight.sh)
	@bash infra/preflight.sh

# ── Deploying ───────────────────────────────────────────────────────────────
# export DEPLOY_HOST=<box ip or hostname> before these.
DEPLOY_HOST ?=
DEPLOY_USER ?= rocky
STATIC_DIR  ?= /var/lib/sukhi-fedi/static

# Rebuild the SPA locally and rsync the result to the host override
# dir. Gateway serves /static/* and /_app/* from there before falling
# back to the image-baked priv/static, so this lands instantly ─ no
# image rebuild, no container reboot. Same for `make push-styles`
# which is the lighter "only the raw token CSS" variant.
#
# `--delete --exclude=styles` 一行が肝。styles/ は build 出力に居な
# いので、素朴に --delete をかけると styles/ ごと吹き飛ばしてしまい
# /login の素のCSSがその瞬間に行方不明になる。styles/ は別の
# rsync で別途同期する役割なので、build rsync の delete 対象から
# 外しておく。
push-static:  ## build the SPA and rsync it to the host override dir
	cd web && $(RUN) npm run build
	ssh $(DEPLOY_USER)@$(DEPLOY_HOST) "sudo mkdir -p $(STATIC_DIR) && sudo chown $(DEPLOY_USER) $(STATIC_DIR)"
	rsync -av --delete --exclude=styles --exclude=emojis web/build/ $(DEPLOY_USER)@$(DEPLOY_HOST):$(STATIC_DIR)/
	rsync -av --delete web/src/styles/ $(DEPLOY_USER)@$(DEPLOY_HOST):$(STATIC_DIR)/styles/

push-styles:  ## rsync only the raw token CSS (server-rendered pages)
	ssh $(DEPLOY_USER)@$(DEPLOY_HOST) "sudo mkdir -p $(STATIC_DIR)/styles && sudo chown -R $(DEPLOY_USER) $(STATIC_DIR)"
	rsync -av --delete web/src/styles/ $(DEPLOY_USER)@$(DEPLOY_HOST):$(STATIC_DIR)/styles/
