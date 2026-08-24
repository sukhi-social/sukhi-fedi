# syntax=docker/dockerfile:1.7
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# DeployEx, in a container.
#
# Kamal keeps looking after the box: one docker network, the same
# accessories as before. DeployEx is a resident of it, not a rival — it
# watches only the BEAM inside its own container. Nested, not parallel.
#
# What lives in here is the whole runtime side of sukhi-fedi: DeployEx
# supervises the `combined` release (gateway + delivery + api, one BEAM)
# by unpacking tarballs it finds under the mounted releases dir. Which
# means this image also carries the *app's* runtime dependencies — the
# app has no container of its own any more.
#
# Why we build DeployEx from source instead of downloading the release:
# upstream publishes exactly one artifact per OTP version, built on a
# GitHub `ubuntu-24.04` runner, so it is amd64 only. This box is an OCI
# A1 — arm64. Building from the pinned tag costs one `mix release`, and
# only when the version below moves.
#
#   docker build -f infra/deployex/Dockerfile -t sukhi-fedi-deployex infra/deployex

ARG DEPLOYEX_VERSION=0.9.13

# ── DeployEx build ────────────────────────────────────────────────────────
# The toolchain is DeployEx's own pin (devops/releases/otp-28/.tool-versions
# at tag 0.9.13), not this repo's — they are separate releases that only
# meet over Erlang distribution, and each carries its own ERTS.
FROM hexpm/elixir:1.19.5-erlang-28.5.0.4-ubuntu-noble-20260730.1 AS build
ARG DEPLOYEX_VERSION
ENV MIX_ENV=prod

# libcap-dev is erlexec's, and erlexec is how DeployEx starts and stops
# the release it supervises.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git ca-certificates libcap-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 --branch "${DEPLOYEX_VERSION}" \
      https://github.com/thiagoesteves/deployex.git .

RUN mix local.hex --force && mix local.rebar --force \
 && mix deps.get \
 && mix compile \
 && mix assets.deploy \
 && mix release

# ── Runtime ───────────────────────────────────────────────────────────────
FROM ubuntu:24.04

LABEL service="sukhi-fedi"

# procps: DeployEx shells out to `ps` and `free`. openssl: the self-signed
# distribution certificates below. curl: the container healthcheck, which
# pokes the *application's* port — a live DeployEx with a dead app would
# otherwise look perfectly healthy.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates openssl libncurses6 libstdc++6 procps mawk curl tzdata \
 && rm -rf /var/lib/apt/lists/*

# erlexec refuses to start children as root unless told to, and telling it
# to is the wrong answer. Upstream's installer makes the same user; the
# fixed uid is so the host-side bind mounts can be chowned to match.
RUN groupadd -g 10002 deployex \
 && useradd -u 10002 -g 10002 -M -d /var/lib/deployex -s /usr/sbin/nologin deployex

COPY --from=build --chown=deployex:deployex /src/_build/prod/rel/deployex /opt/deployex
COPY --chown=deployex:deployex entrypoint.sh /usr/local/bin/deployex-entrypoint
RUN chmod +x /usr/local/bin/deployex-entrypoint \
 && mkdir -p /var/lib/deployex /var/log/deployex /var/log/monitored-apps /etc/deployex \
 && chown deployex:deployex /var/lib/deployex /var/log/deployex /var/log/monitored-apps

ENV LANG=C.UTF-8 \
    DEPLOYEX_CONFIG_YAML_PATH=/etc/deployex/deployex.yaml \
    DEPLOYEX_OTP_TLS_CERT_PATH=/var/lib/deployex/certs

# 4000 is the app DeployEx supervises; 5001 is DeployEx's own dashboard.
EXPOSE 4000 5001

USER deployex
ENTRYPOINT ["/usr/local/bin/deployex-entrypoint"]
