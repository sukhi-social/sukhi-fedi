# SPDX-License-Identifier: AGPL-3.0-or-later
# web-next(Unpoly + Alpine.js の MPA)の郵便局。gateway の前に立ち、
# /api /oauth /nodeinfo /users /inbox などはそのまま通す。
# Node 24 は型をそのまま読むので、ビルドは要らない ── 依存を入れるだけ。
#
# 書くものが一つある: /app/data に、セッション(sessions.json)と OAuth の
# アプリ登録(client.json)。volume に出さないと、deploy のたびに全員が
# ログアウトして、アプリ登録もやりなおしになる。
#
#   docker run -v sukhi-web-data:/app/data -e GATEWAY_URL=... -e PUBLIC_ORIGIN=... <image>
FROM node:24.22.1-alpine AS deps
WORKDIR /app
RUN corepack enable
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile --prod

FROM node:24.22.1-alpine
WORKDIR /app
ENV NODE_ENV=production PORT=3000
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY server ./server
COPY public ./public
# volume の持ち主は、箱の側で uid 1000(node)にそろえる。
RUN mkdir data && chown node:node data
EXPOSE 3000
USER node
CMD ["node", "server/main.ts"]
