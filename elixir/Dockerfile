# syntax=docker/dockerfile:1.7
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build context is the repo root so this Dockerfile can pull in both
# `web/` (SPA source) and `elixir/` (gateway source). release.yml
# passes `context: .` and `file: ./elixir/Dockerfile`.

# ── SPA build ─────────────────────────────────────────────────────────────
FROM node:20-alpine AS spa

WORKDIR /spa
COPY web/package.json web/package-lock.json* ./
RUN npm install --no-audit --no-fund

COPY web/ ./
RUN npm run build

# ── Elixir release build ──────────────────────────────────────────────────
FROM elixir:1.20-alpine AS build

WORKDIR /app

# bash: ezstd's build_deps.sh (compiles the bundled zstd for the NIF) has
# a bash shebang; Alpine ships only busybox sh, so without it the dep
# fails with `env: can't execute 'bash'`. zstd builds with make here
# (build-base) — cmake is optional and intentionally absent.
#
# sccache wraps cc/g++ so ezstd's from-scratch zstd+NIF build (measured at
# ~85s of a cold build, mostly C compilation) can be skipped on a cache hit
# instead of rebuilt. Content-hashed, unlike caching _build/deps directly —
# it can only ever serve back an identical result or miss, never something
# stale, which is what bit us caching compiled Elixir output before.
RUN apk add --no-cache build-base git bash sccache
ENV CC="sccache gcc" CXX="sccache g++"

# VERSION lives at the repo root and is read at compile time by
# elixir/mix.exs and api/mix.exs. The gateway image only needs the
# elixir tree to compile, so copy it next to the mix files.
COPY VERSION ../VERSION
COPY elixir/mix.exs elixir/mix.lock ./
RUN mix local.hex --force && mix local.rebar --force
COPY elixir/rel/docker-deps-cache.exs ./docker-deps-cache.exs
RUN MIX_ENV=prod mix deps.get --only prod

# _build persists across builds via a cache mount so Mix's own incremental
# compiler can skip deps whose locked version didn't change — most of a
# ~150-dependency tree, on a typical lockfile bump. Restored/saved with
# `cp -a` (not left inside the mount) so mtimes survive into a normal
# layer for the later `mix release` step, which doesn't get the mount.
# docker-deps-cache.exs does the actual staleness decision — see its
# header for why a plain persisted _build isn't safe on its own.
RUN --mount=type=cache,target=/sccache,id=sukhi-fedi-gateway-sccache,sharing=locked \
    --mount=type=cache,target=/build-cache,id=sukhi-fedi-gateway-build,sharing=locked \
    sh -c ' \
      set -eu; \
      rm -rf ./_build; \
      # `cp -a src dst` nests (src into dst) rather than replacing when dst
      # already exists — a prior step can leave a stray ./_build, so this
      # rm keeps the restore exact.
      [ -d /build-cache/_build ] && cp -a /build-cache/_build ./_build || true; \
      elixir docker-deps-cache.exs; \
      SCCACHE_DIR=/sccache MIX_ENV=prod mix deps.compile; \
      sccache --show-stats; \
      rm -rf /build-cache/_build; \
      cp -a _build /build-cache/_build \
    '

COPY elixir/config config
COPY elixir/lib lib
COPY elixir/priv priv
COPY elixir/rel rel

# Drop the prebuilt SPA into priv/static so the release embeds it.
# Gateway's `serve_spa/1` reads `index.html` from there. Separately
# copy the raw token CSS files into priv/static/styles/ so the
# server-rendered pages (OAuth consent / error pages) can reference them
# at the same paths (the SvelteKit build hashes them under
# _app/immutable/assets/ which isn't predictable from an EEx template).
COPY --from=spa /spa/build /spa-build
COPY web/src/styles /spa-styles
RUN mkdir -p priv/static priv/static/styles && \
    cp -r /spa-build/. priv/static/ && \
    cp /spa-styles/tokens.css /spa-styles/base.css /spa-styles/app.css priv/static/styles/

RUN MIX_ENV=prod mix release

# ── Runtime ───────────────────────────────────────────────────────────────
FROM elixir:1.20-alpine

# Kamal asserts a `service` label matches `service:` in config/deploy.yml
# before accepting the image. Baking it in here keeps Kamal happy when
# we deploy via `--skip-push` from CI-built images.
LABEL service="sukhi-fedi"

WORKDIR /app

RUN apk add --no-cache libstdc++ openssl ncurses-libs

COPY --from=build /app/_build/prod/rel/sukhi_fedi ./
COPY elixir/rel/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENV MIX_ENV=prod
EXPOSE 4000

CMD ["/app/entrypoint.sh"]
