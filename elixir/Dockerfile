# syntax=docker/dockerfile:1
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
RUN apk add --no-cache build-base git bash

# VERSION lives at the repo root and is read at compile time by
# elixir/mix.exs and api/mix.exs. The gateway image only needs the
# elixir tree to compile, so copy it next to the mix files.
COPY VERSION ../VERSION
COPY elixir/mix.exs elixir/mix.lock ./
RUN mix local.hex --force && mix local.rebar --force

# --mount=type=cache 一枚岩(deps+_build)を deps.get / deps.compile /
# release の三つで共有する。理由は build-on-box.sh の運用と噛み合わせて:
# 箱の上で毎回 `docker build` を打つ(CI の使い捨てランナーではない)ので、
# レイヤーキャッシュが効かない(= lib/ が変わって上のレイヤーが全部作り
# 直しになる)ときでも、_build の中身自体は箱に残り続ける。mix の
# コンパイルはもともと差分でしか効かないので、これで「変わったファイル
# だけ」に戻る。id を付けて他の Dockerfile(api/delivery)の同名マウント
# と混ざらないようにする ── 別プロジェクトの _build を混ぜると意味が無い。
RUN --mount=type=cache,id=gateway-deps,target=/app/deps \
    MIX_ENV=prod mix deps.get --only prod
RUN --mount=type=cache,id=gateway-deps,target=/app/deps \
    --mount=type=cache,id=gateway-build,target=/app/_build \
    MIX_ENV=prod mix deps.compile

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

# release の出力は cache mount の中に居るあいだはイメージに焼き込まれない
# (マウントはその RUN のあいだだけ見える書き込み可能な別ボリューム)。
# マウント外の /release へ複製してから、次のステージで拾う。
RUN --mount=type=cache,id=gateway-deps,target=/app/deps \
    --mount=type=cache,id=gateway-build,target=/app/_build \
    MIX_ENV=prod mix release && \
    cp -r /app/_build/prod/rel/sukhi_fedi /release

# ── Runtime ───────────────────────────────────────────────────────────────
FROM elixir:1.20-alpine

# Kamal asserts a `service` label matches `service:` in config/deploy.yml
# before accepting the image. Baking it in here keeps Kamal happy when
# we deploy via `--skip-push` from CI-built images.
LABEL service="sukhi-fedi"

WORKDIR /app

RUN apk add --no-cache libstdc++ openssl ncurses-libs

COPY --from=build /release ./
COPY elixir/rel/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENV MIX_ENV=prod
EXPOSE 4000

CMD ["/app/entrypoint.sh"]
