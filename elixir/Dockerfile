# syntax=docker/dockerfile:1.7
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build context is the repo root, as in combined/Dockerfile. release.yml
# passes `context: .` and `file: ./elixir/Dockerfile`. The gateway holds no
# web UI: pages come from a web front (web-next, web-natadeco…) that is
# built and run on its own.

# ── libhosi ───────────────────────────────────────────────────────────────
# `hosi` (the store, through ecto_hosi) compiles a NIF against libhosi, and
# hosigraph has no prebuilt release for the commit mix.lock pins ("... is not
# in checksum.txt"), so this stage builds libhosi from that commit, on the
# Alpine the release runs on. The commit reaches it as a file with nothing but
# the sha, so the (long) build reruns only when that sha moves, not on every
# mix.lock change. /opt/libhosi has to be at the same path in the runtime
# image: the NIF finds libhosi there.
FROM elixir:1.20-alpine AS libhosi-ref
COPY elixir/mix.lock /mix.lock
RUN sed -n 's/^  "hosi": {:git, "[^"]*", "\([0-9a-f]*\)".*/\1/p' /mix.lock > /ref && test -s /ref

FROM elixir:1.20-alpine AS libhosi
COPY --from=libhosi-ref /ref /ref
COPY elixir/rel/build-libhosi-alpine.sh /build-libhosi-alpine.sh
RUN apk add --no-cache bash && bash /build-libhosi-alpine.sh /ref /opt/libhosi

# ── Elixir release build ──────────────────────────────────────────────────
FROM elixir:1.20-alpine AS build

WORKDIR /app

# build-base: a few deps (argon2_elixir) compile C with make; cmake is
# optional and intentionally absent. git: ojak is a github dep.
RUN apk add --no-cache build-base git

# The NIF of `hosi` is compiled against this libhosi (see the stage above).
COPY --from=libhosi /opt/libhosi /opt/libhosi
ENV HOSI_BUILD=source HOSI_LIB_DIR=/opt/libhosi/lib HOSI_INCLUDE_DIR=/opt/libhosi/include

# VERSION lives at the repo root and is read at compile time by
# elixir/mix.exs and api/mix.exs. The gateway image only needs the
# elixir tree to compile, so copy it next to the mix files.
COPY VERSION ../VERSION
# Path dependency (../shared): code the gateway and the delivery node must
# decide identically. Needed in full before `mix deps.get` / `deps.compile`.
COPY shared ../shared
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
# Deps compile in parallel OS processes (Elixir 1.19+): `mix deps.compile`
# otherwise walks ~150 deps one at a time and a cold build is mostly that
# walk. One partition per core.
RUN --mount=type=cache,target=/build-cache,id=sukhi-fedi-gateway-build,sharing=locked \
    sh -c ' \
      set -eu; \
      rm -rf ./_build; \
      # `cp -a src dst` nests (src into dst) rather than replacing when dst
      # already exists — a prior step can leave a stray ./_build, so this
      # rm keeps the restore exact.
      [ -d /build-cache/_build ] && cp -a /build-cache/_build ./_build || true; \
      elixir docker-deps-cache.exs; \
      MIX_OS_DEPS_COMPILE_PARTITION_COUNT=$(nproc) MIX_ENV=prod mix deps.compile; \
      rm -rf /build-cache/_build; \
      cp -a _build /build-cache/_build \
    '

COPY elixir/config config
COPY elixir/lib lib
COPY elixir/priv priv
COPY elixir/rel rel

RUN MIX_ENV=prod mix release

# ── Runtime ───────────────────────────────────────────────────────────────
FROM elixir:1.20-alpine

# Kamal asserts a `service` label matches `service:` in config/deploy.yml
# before accepting the image. Baking it in here keeps Kamal happy when
# we deploy via `--skip-push` from CI-built images.
LABEL service="sukhi-fedi"

WORKDIR /app

RUN apk add --no-cache libstdc++ openssl ncurses-libs

COPY --from=libhosi /opt/libhosi /opt/libhosi
COPY --from=build /app/_build/prod/rel/sukhi_fedi ./
COPY elixir/rel/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENV MIX_ENV=prod
EXPOSE 4000

CMD ["/app/entrypoint.sh"]
