# natadeco の頁を描く Node。gateway の前に立つ web(front)で、頁も静的な
# もの(build/client)も、この image が自分で配る。`/.sukhi/web.json` で
# 何を答えるかを gateway に申告する(src/hooks.server.ts)。データは
# INTERNAL_API_URL の BEAM から取る。
#
#   IMAGE_PREFIX=natadeco bin/build-on-box.sh ssr
FROM node:24.22.1-alpine AS build
WORKDIR /app
RUN corepack enable
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
COPY . .
RUN pnpm run build \
  && pnpm prune --prod

FROM node:24.22.1-alpine
WORKDIR /app
ENV NODE_ENV=production PORT=3000 HOST=0.0.0.0
COPY --from=build /app/build ./build
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json ./package.json
EXPOSE 3000
USER node
CMD ["node", "build"]
