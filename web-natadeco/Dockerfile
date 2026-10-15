# natadeco の頁を描く Node。BEAM の横に立ち、Elixir が HTML の要求だけ
# ここへ回す(SukhiFedi.Web.SSR)。データは INTERNAL_API_URL の BEAM から
# 取る。静的なもの(build/client)はこの image からは配らない ── Elixir の
# override dir に `make push-natadeco` で置く。同じコミットから焼くので、
# 中身のハッシュは一致する(Vite のハッシュは中身から決まる)。
#
#   IMAGE_PREFIX=natadeco bin/build-on-box.sh ssr
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
RUN npm run build \
  && npm prune --omit=dev --no-audit --no-fund

FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production PORT=3000 HOST=0.0.0.0
COPY --from=build /app/build ./build
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json ./package.json
EXPOSE 3000
USER node
CMD ["node", "build"]
