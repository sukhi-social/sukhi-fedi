# syntax=docker/dockerfile:1.7
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Combined image: gateway + delivery + api in one BEAM, for single-box
# deployments. Build context is the repo root (like elixir/Dockerfile):
#   docker build -f combined/Dockerfile .
# The SPA stage and runtime stage mirror elixir/Dockerfile — the
# combined release serves the same web UI on :4000.

# ── SPA build ─────────────────────────────────────────────────────────────
FROM node:24.22.1-alpine AS spa-deps

WORKDIR /spa
RUN corepack enable
COPY web/package.json web/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

FROM spa-deps AS spa
COPY web/ ./
RUN pnpm run build

# ── Elixir release build ──────────────────────────────────────────────────
FROM elixir:1.20-alpine AS deps

WORKDIR /repo

# build-base: a few deps (argon2_elixir) compile C with make. git: ojak is
# a github dep.
# vips-dev: vix links the system libvips. Its default is a precompiled libvips
# from GitHub Releases, which fails the same way ojak's download did on OTP 29.
RUN apk add --no-cache build-base git pkgconf vips-dev
ENV VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS

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

# ── dtlv (SUKHI_STORE=datalevin) ──────────────────────────────────────────
# The Datalevin store runs `dtlv` as a child of the BEAM. Only releases built
# for glibc are published, so the runtime stage below adds `gcompat`.
# The release must match the image's CPU: the amd64 build does not start on
# arm64 ("Error loading shared library ld-linux-x86-64.so.2"), which is what
# production runs. Pinned per architecture and checked; ignored unless
# SUKHI_STORE=datalevin.
#
# gcompat lacks `posix_fallocate64`, which the arm64 build needs at load time
# ("Error relocating /dtlv: posix_fallocate64: symbol not found"). musl has
# posix_fallocate, so a one-function shim maps it, and `dtlv` is a wrapper
# that preloads the shim. The wrapper `exec`s, so no extra process stays.
FROM alpine:3.22 AS dtlv
ARG TARGETARCH
ARG DTLV_VERSION=1.2.10
ARG DTLV_SHA256_AMD64=b42c1ef4b6a9ccf2a42b21f9c576fe774ff877c15826031755f0b94a3c0df3e5
ARG DTLV_SHA256_ARM64=8b4d6beed819861b0daa3a1bc363017238a93ffba34230cad3267228e5045083
RUN apk add --no-cache curl unzip gcc musl-dev && \
    case "${TARGETARCH}" in \
      amd64) asset=ubuntu-22.04-amd64;        sha="${DTLV_SHA256_AMD64}" ;; \
      arm64) asset=ubuntu-24.04-arm-aarch64;  sha="${DTLV_SHA256_ARM64}" ;; \
      *) echo "no dtlv release for ${TARGETARCH}" >&2; exit 1 ;; \
    esac && \
    curl -fsSL -o /tmp/dtlv.zip \
      "https://github.com/datalevin/datalevin/releases/download/${DTLV_VERSION}/dtlv-${DTLV_VERSION}-${asset}.zip" && \
    echo "${sha}  /tmp/dtlv.zip" | sha256sum -c - && \
    mkdir -p /opt/dtlv/bin /opt/dtlv/lib && \
    unzip -j /tmp/dtlv.zip dtlv -d /opt/dtlv/lib && mv /opt/dtlv/lib/dtlv /opt/dtlv/lib/dtlv-real && \
    chmod +x /opt/dtlv/lib/dtlv-real && \
    printf '#define _GNU_SOURCE\n#include <fcntl.h>\nint posix_fallocate64(int fd, off_t o, off_t l) { return posix_fallocate(fd, o, l); }\n' > /tmp/shim.c && \
    gcc -shared -fPIC -o /opt/dtlv/lib/libdtlvshim.so /tmp/shim.c && \
    printf '#!/bin/sh\nLD_PRELOAD=/usr/local/lib/libdtlvshim.so exec /usr/local/lib/dtlv-real "$@"\n' > /opt/dtlv/bin/dtlv && \
    chmod +x /opt/dtlv/bin/dtlv

# ── Runtime ───────────────────────────────────────────────────────────────
FROM elixir:1.20-alpine

LABEL service="sukhi-fedi"

WORKDIR /app

RUN apk add --no-cache libstdc++ openssl ncurses-libs vips gcompat zlib
COPY --from=dtlv /opt/dtlv/bin/dtlv /usr/local/bin/dtlv
COPY --from=dtlv /opt/dtlv/lib/ /usr/local/lib/

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
