# syntax=docker/dockerfile:1
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build context is the repo root so this Dockerfile can read the
# shared `VERSION` file. release.yml passes `context: .` and
# `file: ./api/Dockerfile`.

FROM elixir:1.20-alpine AS build

WORKDIR /app

RUN apk add --no-cache build-base git

# VERSION lives at the repo root and is read at compile time by
# api/mix.exs. Mirror the on-disk layout (`../VERSION` relative to the
# api directory) so the mix.exs path expression resolves the same in
# the container as it does in dev.
COPY VERSION ../VERSION
COPY api/mix.exs ./
COPY api/mix.lock* ./
RUN mix local.hex --force && mix local.rebar --force

# cache mount の理由は elixir/Dockerfile と同じ(箱の上で毎回 docker build
# するので、レイヤーキャッシュではなく _build 自体を箱に残す)。id を
# 分けて他の Dockerfile と混ざらないようにする。
RUN --mount=type=cache,id=api-deps,target=/app/deps \
    MIX_ENV=prod mix deps.get
RUN --mount=type=cache,id=api-deps,target=/app/deps \
    --mount=type=cache,id=api-build,target=/app/_build \
    MIX_ENV=prod mix deps.compile

COPY api/config config
COPY api/lib lib
COPY api/rel rel

# release の出力は cache mount の中に居るあいだはイメージに焼き込まれない
# ので、マウント外の /release へ複製してから次のステージで拾う。
RUN --mount=type=cache,id=api-deps,target=/app/deps \
    --mount=type=cache,id=api-build,target=/app/_build \
    MIX_ENV=prod mix release && \
    cp -r /app/_build/prod/rel/sukhi_api /release

FROM elixir:1.20-alpine

WORKDIR /app

RUN apk add --no-cache libstdc++ openssl ncurses-libs

COPY --from=build /release ./
COPY api/rel/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENV MIX_ENV=prod

# Distributed Erlang knobs — RELEASE_DISTRIBUTION, RELEASE_NODE, and
# RELEASE_COOKIE are read by the release runtime. entrypoint.sh maps
# Kamal's `ERLANG_COOKIE` → `RELEASE_COOKIE` so the gateway and this
# node share a cluster cookie.
CMD ["/app/entrypoint.sh"]
