# syntax=docker/dockerfile:1.7
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Combined image: gateway + delivery in one BEAM, for small single-box
# deployments. Build context is the repo root (like elixir/Dockerfile):
#   docker build -f combined/Dockerfile .
# The SPA stage and runtime stage mirror elixir/Dockerfile — the
# combined release serves the same web UI on :4000.

# ── SPA build ─────────────────────────────────────────────────────────────
FROM node:20-alpine AS spa

WORKDIR /spa
COPY web/package.json web/package-lock.json* ./
RUN npm install --no-audit --no-fund

COPY web/ ./
RUN npm run build

# ── Elixir release build ──────────────────────────────────────────────────
FROM elixir:1.20-alpine AS build

WORKDIR /repo

# bash: ezstd's build_deps.sh needs it (see elixir/Dockerfile). sccache
# wraps cc/g++ so ezstd's from-scratch zstd+NIF build doesn't get rebuilt
# on a cache hit — measured ~75s saved on the gateway image; see
# elixir/Dockerfile's comment for why this is content-hashed and safe.
RUN apk add --no-cache build-base git bash sccache
ENV CC="sccache gcc" CXX="sccache g++"

COPY VERSION ./VERSION
COPY elixir/mix.exs elixir/mix.lock elixir/
COPY delivery/mix.exs delivery/mix.lock delivery/
COPY combined/mix.exs combined/

RUN mix local.hex --force && mix local.rebar --force
COPY elixir/rel/docker-deps-cache.exs /repo/docker-deps-cache.exs
WORKDIR /repo/combined
RUN MIX_ENV=prod mix deps.get --only prod

# See elixir/Dockerfile's comment on the matching step for why this is
# safe: docker-deps-cache.exs decides staleness from mix.lock's own
# content hash, never from mtime ordering alone.
RUN --mount=type=cache,target=/sccache,id=sukhi-fedi-combined-sccache,sharing=locked \
    --mount=type=cache,target=/build-cache,id=sukhi-fedi-combined-build,sharing=locked \
    sh -c ' \
      set -eu; \
      rm -rf ./_build; \
      # combined has path-deps on ../elixir and ../delivery, so `mix
      # deps.get` already leaves a partial ./_build scaffold behind —
      # without this rm, `cp -a` nests (src into an existing dst)
      # instead of replacing, and the restore silently does nothing.
      [ -d /build-cache/_build ] && cp -a /build-cache/_build ./_build || true; \
      elixir /repo/docker-deps-cache.exs; \
      SCCACHE_DIR=/sccache MIX_ENV=prod mix deps.compile; \
      sccache --show-stats; \
      rm -rf /build-cache/_build; \
      cp -a _build /build-cache/_build \
    '

WORKDIR /repo
COPY elixir/config elixir/config
COPY elixir/lib elixir/lib
COPY elixir/priv elixir/priv
COPY elixir/rel elixir/rel
COPY delivery/config delivery/config
COPY delivery/lib delivery/lib
COPY combined/config combined/config

# Same SPA embedding as elixir/Dockerfile, into the gateway's priv/.
COPY --from=spa /spa/build /spa-build
COPY web/src/styles /spa-styles
RUN mkdir -p elixir/priv/static elixir/priv/static/styles && \
    cp -r /spa-build/. elixir/priv/static/ && \
    cp /spa-styles/tokens.css /spa-styles/base.css /spa-styles/app.css elixir/priv/static/styles/

WORKDIR /repo/combined
RUN MIX_ENV=prod mix release

# ── Runtime ───────────────────────────────────────────────────────────────
FROM elixir:1.20-alpine

LABEL service="sukhi-fedi"

WORKDIR /app

RUN apk add --no-cache libstdc++ openssl ncurses-libs

COPY --from=build /repo/combined/_build/prod/rel/combined ./
COPY combined/rel/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# The combined runtime.exs reads both projects' runtime configs from
# here (same relative layout as the repo).
COPY elixir/config/runtime.exs /app/runtime-configs/elixir/config/runtime.exs
COPY delivery/config/runtime.exs /app/runtime-configs/delivery/config/runtime.exs
ENV RUNTIME_CONFIG_DIR=/app/runtime-configs

ENV MIX_ENV=prod
EXPOSE 4000

CMD ["/app/entrypoint.sh"]
