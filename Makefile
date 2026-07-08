.PHONY: preflight check push-static push-styles test-pglite test-e2e

# Run the DB-only integration tests against an embedded PGlite Postgres —
# no Docker. Extra args pass through to `mix test`:
#   make test-pglite
#   make test-pglite ARGS="test/integration/social_test.exs:97"
test-pglite:
	@bash scripts/test-pglite.sh $(ARGS)

# Cross-browser smoke for the SPA (Chromium + Firefox) via Playwright.
# Builds the SPA and runs the flow in web/e2e against `vite preview`.
#   make test-e2e
#   make test-e2e ARGS="--project=firefox"
test-e2e:
	cd web && npx playwright test $(ARGS)

# export DEPLOY_HOST=<box ip or hostname> before the deploy targets.
DEPLOY_HOST ?=
DEPLOY_USER ?= rocky
STATIC_DIR  ?= /var/lib/sukhi-fedi/static

preflight:
	@bash infra/preflight.sh

check:
	@bash scripts/check_presets_sync.sh

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
push-static:
	cd web && npm run build
	ssh $(DEPLOY_USER)@$(DEPLOY_HOST) "sudo mkdir -p $(STATIC_DIR) && sudo chown $(DEPLOY_USER) $(STATIC_DIR)"
	rsync -av --delete --exclude=styles web/build/ $(DEPLOY_USER)@$(DEPLOY_HOST):$(STATIC_DIR)/
	rsync -av --delete web/src/styles/ $(DEPLOY_USER)@$(DEPLOY_HOST):$(STATIC_DIR)/styles/

push-styles:
	ssh $(DEPLOY_USER)@$(DEPLOY_HOST) "sudo mkdir -p $(STATIC_DIR)/styles && sudo chown -R $(DEPLOY_USER) $(STATIC_DIR)"
	rsync -av --delete web/src/styles/ $(DEPLOY_USER)@$(DEPLOY_HOST):$(STATIC_DIR)/styles/
