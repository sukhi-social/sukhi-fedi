# syntax=docker/dockerfile:1.7
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# sukhi-builder: the box's compiler.
#
# The old shape built a Docker *image* per app version, which meant every
# one-line change in a .ex file rebuilt and re-pushed a whole image. Now
# the box bakes a release tarball instead and the image is the part that
# stops changing. This one is that part: it holds the toolchain, and it
# is rebuilt only when the toolchain moves.
#
# It never has the source baked in. bin/release-on-box.sh bind-mounts
# ~/sukhi-build and runs the build inside — so `_build` and `deps` are
# ordinary directories on the host that survive between builds, and the
# second build of the day is incremental. (That is also why the elaborate
# docker-deps-cache.exs + sccache dance in elixir/Dockerfile can go: it
# existed to fight `mix deps.get` re-stamping every mtime inside a layer,
# and there is no layer here.)
#
# It carries node *and* bun, because the box bakes two instances' SPAs
# (web/ with npm, web-natadeco/ with bun) — see bin/release-on-box.sh.
#
# Same OS family as infra/deployex/Dockerfile's runtime stage — ubuntu
# noble, glibc — so the three NIFs (vix / ezstd / argon2_elixir) are
# compiled against what they will actually run on.
#
#   docker build -f infra/builder/Dockerfile -t sukhi-fedi-builder infra/builder

# Matches mise.toml: erlang 28.4.1, elixir 1.20.0-otp-28.
FROM hexpm/elixir:1.20.0-erlang-28.4.1-ubuntu-noble-20260509.1

ARG NODE_VERSION=20.20.2

# bash is ezstd's build_deps.sh; the rest is the ordinary NIF toolchain.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git bash curl ca-certificates xz-utils unzip \
 && rm -rf /var/lib/apt/lists/*

# node for the SPA under web/. Ubuntu's own nodejs is 18; take the
# official tarball so this matches mise.toml's `node = "20"`.
ARG TARGETARCH
RUN set -eu; \
    case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
      amd64) narch=x64 ;; \
      arm64) narch=arm64 ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${narch}.tar.xz" \
      | tar -xJ -C /usr/local --strip-components=1

# bun for web-natadeco. The two SPAs came from different places and kept
# their own lockfiles — web/ has package-lock.json, web-natadeco/ has
# bun.lock — and a release should install from the same lockfile the
# author builds with, so both package managers live here. (Unifying them
# is a separate decision; Makefile says the same.)
ARG BUN_VERSION=1.3.13
RUN set -eu; \
    case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
      amd64) barch=x64 ;; \
      arm64) barch=aarch64 ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/bun.zip \
      "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-${barch}.zip"; \
    unzip -q /tmp/bun.zip -d /tmp; \
    install -m 0755 "/tmp/bun-linux-${barch}/bun" /usr/local/bin/bun; \
    rm -rf /tmp/bun.zip "/tmp/bun-linux-${barch}"

# The container runs as the *host* user (see release-on-box.sh) so that
# everything it writes into the bind mount stays owned by `rocky`. That
# rules out /root/.mix, which nobody else can read — put the hex and
# rebar archives somewhere world-readable instead. HEX_HOME is left
# alone on purpose: it is a cache hex writes to, so it wants a writable
# home, and the build gets one via `-e HOME=/tmp`.
ENV MIX_HOME=/opt/mix
RUN mix local.hex --force && mix local.rebar --force \
 && chmod -R a+rX /opt/mix

WORKDIR /repo
