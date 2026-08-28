# SPDX-License-Identifier: AGPL-3.0-or-later
#
# One place to start from. `make` on its own lists everything.

.DEFAULT_GOAL := help
.PHONY: help setup dev dev-web test test-elixir test-delivery test-api test-web \
        test-pglite test-e2e check check-presets up down preflight \
        push-static push-styles clear-static static-status \
        release release-natadeco release-images push-deployex-config \
        push-natadeco-deployex-config \
        push-natadeco natadeco-images

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
	@command -v bun >/dev/null 2>&1 && (cd web-natadeco && bun install) \
	  || echo "note: skipping web-natadeco (needs bun)"

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
DOMAIN      ?= sukhi.f3liz.casa

# Rebuild the SPA locally and rsync it to the host override dir. The app
# serves /static/* and /_app/* from there, so this lands on the next
# request — no release, no restart. `make push-styles` is the lighter
# "only the raw token CSS" variant.
#
# Which of the two trees answers is decided by *when each was built*, not
# by file mtimes: `npm run build` leaves a .static-build.json behind and
# it rides along in the rsync. So a later `make release` supersedes this
# push, on purpose. To keep a push in place across releases, set
# STATIC_OVERRIDE=prefer on the deployex accessory. See
# docs/static-override.md.
#
# `--chmod=D755,F644` も要る。ここに置くものは全部 HTTP で配る公開
# ファイルで、アプリは root ではない uid で動いている ── 手元の umask
# や zip の中の mode がそのまま渡ると、読めないファイルが並ぶ(絵文字
# 983 個が 0700 で来て、9時間 502 を返していた)。
#
# `--delete --exclude=styles` 一行が肝。styles/ は build 出力に居な
# いので、素朴に --delete をかけると styles/ ごと吹き飛ばしてしまい
# /login の素のCSSがその瞬間に行方不明になる。styles/ は別の
# rsync で別途同期する役割なので、build rsync の delete 対象から
# 外しておく。emojis/ も同じ(あちらは実行時に増える)。
push-static:  ## build the SPA and rsync it to the host override dir
	cd web && SUKHI_STATIC_SOURCE=push $(RUN) npm run build
	ssh $(DEPLOY_USER)@$(DEPLOY_HOST) "sudo mkdir -p $(STATIC_DIR) && sudo chown $(DEPLOY_USER) $(STATIC_DIR)"
	rsync -av --delete --chmod=D755,F644 --exclude=styles --exclude=emojis web/build/ $(DEPLOY_USER)@$(DEPLOY_HOST):$(STATIC_DIR)/
	rsync -av --delete --chmod=D755,F644 web/src/styles/ $(DEPLOY_USER)@$(DEPLOY_HOST):$(STATIC_DIR)/styles/
	@$(MAKE) --no-print-directory static-status

# Take the push back off. emojis/ stays — nothing bakes those, they are
# uploaded at runtime and the override dir is where they live.
clear-static:  ## remove the pushed SPA/CSS, falling back to the release's
	ssh $(DEPLOY_USER)@$(DEPLOY_HOST) "find $(STATIC_DIR) -mindepth 1 -maxdepth 1 ! -name emojis -exec rm -rf {} +"
	@$(MAKE) --no-print-directory static-status

# Which tree is actually answering. This is the question that went
# unasked for ten days while `push-static` quietly did nothing.
static-status:  ## ask the live site which static tree is answering
	@echo "host $(STATIC_DIR):"
	@ssh $(DEPLOY_USER)@$(DEPLOY_HOST) "ls -1 $(STATIC_DIR) 2>/dev/null | sed 's/^/  /'; cat $(STATIC_DIR)/.static-build.json 2>/dev/null | sed 's/^/  /' || echo '  (no .static-build.json — pushed by hand?)'"
	@echo "serving:"
	@curl -sS -D- -o /dev/null https://$(DOMAIN)/static/index.html 2>/dev/null \
	  | grep -i '^x-static-source' | sed 's/^/  /' \
	  || echo "  (set DOMAIN=<host> to ask a live site)"

push-styles:  ## rsync only the raw token CSS (server-rendered pages)
	ssh $(DEPLOY_USER)@$(DEPLOY_HOST) "sudo mkdir -p $(STATIC_DIR)/styles && sudo chown -R $(DEPLOY_USER) $(STATIC_DIR)"
	rsync -av --delete --chmod=D755,F644 web/src/styles/ $(DEPLOY_USER)@$(DEPLOY_HOST):$(STATIC_DIR)/styles/

# ── natadeco ────────────────────────────────────────────────────────────────
# natadeco.com rides this repo's deco addon and its combined image, but has
# a frontend of its own (web-natadeco/, brought in 2026-08-25). It is not on
# DeployEx: its version still travels as an image.
#
# It builds with bun, not npm — its own lockfile, left as it was. Unifying
# the two package managers is a separate decision from moving the code.
NATADECO_STATIC_DIR ?= /var/lib/natadeco/static

push-natadeco:  ## build web-natadeco and rsync it to natadeco's override dir
	cd web-natadeco && bun run build
	ssh $(DEPLOY_USER)@$(DEPLOY_HOST) "sudo mkdir -p $(NATADECO_STATIC_DIR) && sudo chown $(DEPLOY_USER) $(NATADECO_STATIC_DIR)"
	rsync -av --delete --chmod=D755,F644 web-natadeco/build/ $(DEPLOY_USER)@$(DEPLOY_HOST):$(NATADECO_STATIC_DIR)/

# natadeco's backend. One image: the combined release carries :sukhi_api
# too, and natadeco stopped running a separate api node on 2026-08-26.
natadeco-images:  ## (re)build natadeco's combined image on the box
	IMAGE_PREFIX=natadeco bash bin/build-on-box.sh combined
	@echo
	@echo "next, in ~/repos/natadeco-deploy:"
	@echo "  kamal deploy --skip-push --version=v0"

# Bake a release tarball on the box and hand it to DeployEx, which swaps
# the running BEAM for it. No image, no registry, no container restart —
# the app version is data now. See bin/release-on-box.sh.
release:  ## build a release on the box and deploy it (DeployEx)
	@bash bin/release-on-box.sh

# The same thing for natadeco.com. Its own build tree, its own dist dir,
# its own frontend (web-natadeco, bun) — one script, switched by INSTANCE.
release-natadeco:  ## build natadeco's release on the box and deploy it
	@INSTANCE=natadeco bash bin/release-on-box.sh

# The two images the box needs but that almost never change: the toolchain
# that bakes releases, and DeployEx itself. Run after touching
# infra/builder/, infra/deployex/Dockerfile, or the toolchain pins.
release-images:  ## (re)build the builder + deployex images on the box
	@bash bin/build-on-box.sh builder deployex

# How the app runs — replicas, thresholds, paths — lives in a file on the
# host, not in the image. DeployEx re-reads it and applies the reloadable
# parts without a restart.
DEPLOYEX_DIR ?= /var/lib/sukhi-fedi/deployex

push-deployex-config:  ## rsync infra/deployex/deployex.yaml to the box
	ssh $(DEPLOY_USER)@$(DEPLOY_HOST) "sudo mkdir -p $(DEPLOYEX_DIR) && sudo chown $(DEPLOY_USER) $(DEPLOYEX_DIR)"
	rsync -av infra/deployex/deployex.yaml $(DEPLOY_USER)@$(DEPLOY_HOST):$(DEPLOYEX_DIR)/

# natadeco's own DeployEx reads the same filename out of its own
# directory, so the source file carries the instance in its name and the
# rsync drops the suffix on the way.
NATADECO_DEPLOYEX_DIR ?= /var/lib/natadeco/deployex

push-natadeco-deployex-config:  ## rsync deployex.natadeco.yaml to natadeco's config dir
	ssh $(DEPLOY_USER)@$(DEPLOY_HOST) "sudo mkdir -p $(NATADECO_DEPLOYEX_DIR) && sudo chown $(DEPLOY_USER) $(NATADECO_DEPLOYEX_DIR)"
	rsync -av infra/deployex/deployex.natadeco.yaml $(DEPLOY_USER)@$(DEPLOY_HOST):$(NATADECO_DEPLOYEX_DIR)/deployex.yaml
