# syntax=docker/dockerfile:1.7
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Combined image: gateway + delivery + api in one BEAM, for single-box
# deployments. Build context is the repo root (like elixir/Dockerfile):
#   docker build -f combined/Dockerfile .
# The SPA stage and runtime stage mirror elixir/Dockerfile — the
# combined release serves the same web UI on :4000.

# ── SPA build ─────────────────────────────────────────────────────────────
FROM node:20-alpine AS spa-deps

WORKDIR /spa
COPY web/package.json web/package-lock.json* ./
RUN npm install --no-audit --no-fund

FROM spa-deps AS spa
COPY web/ ./
RUN npm run build

# ── Elixir release build ──────────────────────────────────────────────────
FROM elixir:1.20-alpine AS deps

WORKDIR /repo

# build-base: a few deps (argon2_elixir) compile C with make. git: ojak is
# a github dep.
RUN apk add --no-cache build-base git

COPY VERSION ./VERSION
# Path dependency of elixir/ and delivery/; needed in full before deps.get.
COPY shared shared/
COPY elixir/mix.exs elixir/mix.lock elixir/
COPY delivery/mix.exs delivery/mix.lock delivery/
COPY api/mix.exs api/mix.lock api/
COPY combined/mix.exs combined/

RUN mix local.hex --force && mix local.rebar --force
COPY elixir/rel/docker-deps-cache.exs /repo/docker-deps-cache.exs
WORKDIR /repo/combined
RUN MIX_ENV=prod mix deps.get --only prod

# See elixir/Dockerfile's comment on the matching step for why this is
# safe: docker-deps-cache.exs decides staleness from mix.lock's own
# content hash, never from mtime ordering alone.
# Deps compile in parallel OS processes (Elixir 1.19+): `mix deps.compile`
# otherwise walks ~150 deps one at a time and a cold build is mostly that
# walk. One partition per core.
RUN --mount=type=cache,target=/build-cache,id=sukhi-fedi-combined-build,sharing=locked \
    sh -c ' \
      set -eu; \
      rm -rf ./_build; \
      # combined has path-deps on ../elixir, ../delivery and ../api, so `mix
      # deps.get` already leaves a partial ./_build scaffold behind —
      # without this rm, `cp -a` nests (src into an existing dst)
      # instead of replacing, and the restore silently does nothing.
      [ -d /build-cache/_build ] && cp -a /build-cache/_build ./_build || true; \
      elixir /repo/docker-deps-cache.exs; \
      MIX_OS_DEPS_COMPILE_PARTITION_COUNT=$(nproc) MIX_ENV=prod mix deps.compile; \
      rm -rf /build-cache/_build; \
      cp -a _build /build-cache/_build \
    '

# Everything above changes only with a lockfile; everything below changes
# with every commit. CI exports its layer cache from `cache-warm` (below)
# and only reads it for the full build, so the per-commit layers (SPA
# output, the release) aren't uploaded just to be thrown away.
FROM deps AS build

WORKDIR /repo
COPY elixir/config elixir/config
COPY elixir/lib elixir/lib
COPY elixir/priv elixir/priv
COPY elixir/rel elixir/rel
COPY delivery/config delivery/config
COPY delivery/lib delivery/lib
COPY api/config api/config
COPY api/lib api/lib
COPY combined/config combined/config
# rel/env.sh.eex becomes releases/<vsn>/env.sh — the cookie check and the
# "the api plugin node is this node" defaults live there, so a release
# assembled without it boots with neither.
COPY combined/rel combined/rel

# Same SPA embedding as elixir/Dockerfile, into the gateway's priv/.
COPY --from=spa /spa/build /spa-build
COPY web/src/styles /spa-styles
RUN mkdir -p elixir/priv/static elixir/priv/static/styles && \
    cp -r /spa-build/. elixir/priv/static/ && \
    cp /spa-styles/tokens.css /spa-styles/base.css /spa-styles/app.css elixir/priv/static/styles/

WORKDIR /repo/combined
# Keep each app's own compile output (manifests + .beam) between builds so
# a change in one app, or only in web/, doesn't recompile the other three.
# Deps stay with the step above (their fingerprints live there); only these
# four dirs are restored over it. Mix decides staleness itself, from its
# manifests — this cache only carries them across builds.
RUN --mount=type=cache,target=/app-cache,id=sukhi-fedi-combined-app,sharing=locked \
    sh -c ' \
      set -eu; \
      apps="sukhi_fedi sukhi_delivery sukhi_api sukhi_combined"; \
      for a in $apps; do \
        if [ -d /app-cache/$a ]; then rm -rf _build/prod/lib/$a; cp -a /app-cache/$a _build/prod/lib/$a; fi; \
      done; \
      MIX_ENV=prod mix release; \
      for a in $apps; do rm -rf /app-cache/$a; cp -a _build/prod/lib/$a /app-cache/$a; done \
    '

# ── CI cache export target ────────────────────────────────────────────────
# Builds the two slow-to-change stages and nothing else:
#   docker build --target cache-warm --cache-to ... -f combined/Dockerfile .
FROM scratch AS cache-warm
COPY --from=spa-deps /spa/package.json /spa-deps
COPY --from=deps /repo/combined/mix.exs /deps

# ── Runtime ───────────────────────────────────────────────────────────────
FROM elixir:1.20-alpine

LABEL service="sukhi-fedi"

WORKDIR /app

RUN apk add --no-cache libstdc++ openssl ncurses-libs

COPY --from=build /repo/combined/_build/prod/rel/combined ./
COPY combined/rel/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# The combined runtime.exs reads all three projects' runtime configs
# from here (same relative layout as the repo).
COPY elixir/config/runtime.exs /app/runtime-configs/elixir/config/runtime.exs
COPY delivery/config/runtime.exs /app/runtime-configs/delivery/config/runtime.exs
COPY api/config/runtime.exs /app/runtime-configs/api/config/runtime.exs
ENV RUNTIME_CONFIG_DIR=/app/runtime-configs

ENV MIX_ENV=prod
EXPOSE 4000

CMD ["/app/entrypoint.sh"]
