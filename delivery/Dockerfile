# SPDX-License-Identifier: AGPL-3.0-or-later
FROM elixir:1.20-alpine AS build

WORKDIR /app

RUN apk add --no-cache build-base git

# Build context is the repo root (`docker build -f delivery/Dockerfile .`):
# this image needs ../shared, a path dependency (UrlGuard, shared with the
# gateway), which a ./delivery context cannot see.
COPY shared ../shared
COPY delivery/mix.exs delivery/mix.lock* ./
RUN mix local.hex --force && mix local.rebar --force
RUN MIX_ENV=prod mix deps.get --only prod
RUN MIX_ENV=prod mix deps.compile

COPY delivery/config config
COPY delivery/lib lib

RUN MIX_ENV=prod mix release

FROM elixir:1.20-alpine

WORKDIR /app

RUN apk add --no-cache libstdc++ openssl ncurses-libs

COPY --from=build /app/_build/prod/rel/sukhi_delivery ./
COPY delivery/rel/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENV MIX_ENV=prod
EXPOSE 4001

CMD ["/app/entrypoint.sh"]
