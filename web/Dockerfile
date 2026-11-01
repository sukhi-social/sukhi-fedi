# syntax=docker/dockerfile:1.7
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# web-simple: the SPA build and a tiny static server (serve/server.mjs).
# It sits behind the gateway, which reads /.sukhi/web.json from it
# (SukhiFedi.Web.Upstreams) and forwards only the paths that file claims.
# Its own image — a change here no longer rebuilds the gateway, and the
# other way round.
#
#   docker build -t sukhi-fedi-web-simple web
FROM node:24.22.1-alpine AS build
WORKDIR /app
RUN corepack enable
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
COPY . .
RUN pnpm run build

FROM node:24.22.1-alpine
WORKDIR /app
ENV NODE_ENV=production PORT=3000 BUILD_DIR=/app/build
COPY --from=build /app/build ./build
COPY serve/server.mjs ./serve/server.mjs
EXPOSE 3000
USER node
CMD ["node", "serve/server.mjs"]
