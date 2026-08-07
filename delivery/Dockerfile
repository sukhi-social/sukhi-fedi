# syntax=docker/dockerfile:1
# SPDX-License-Identifier: AGPL-3.0-or-later
FROM elixir:1.20-alpine AS build

WORKDIR /app

RUN apk add --no-cache build-base git

COPY mix.exs mix.lock* ./
RUN mix local.hex --force && mix local.rebar --force

# cache mount の理由は elixir/Dockerfile と同じ。id を分けて他の
# Dockerfile と混ざらないようにする。
RUN --mount=type=cache,id=delivery-deps,target=/app/deps \
    MIX_ENV=prod mix deps.get --only prod
RUN --mount=type=cache,id=delivery-deps,target=/app/deps \
    --mount=type=cache,id=delivery-build,target=/app/_build \
    MIX_ENV=prod mix deps.compile

COPY config config
COPY lib lib

# release の出力は cache mount の中に居るあいだはイメージに焼き込まれない
# ので、マウント外の /release へ複製してから次のステージで拾う。
RUN --mount=type=cache,id=delivery-deps,target=/app/deps \
    --mount=type=cache,id=delivery-build,target=/app/_build \
    MIX_ENV=prod mix release && \
    cp -r /app/_build/prod/rel/sukhi_delivery /release

FROM elixir:1.20-alpine

WORKDIR /app

RUN apk add --no-cache libstdc++ openssl ncurses-libs

COPY --from=build /release ./
COPY rel/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENV MIX_ENV=prod
EXPOSE 4001

CMD ["/app/entrypoint.sh"]
