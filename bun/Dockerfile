# SPDX-License-Identifier: AGPL-3.0-or-later
FROM node:24-alpine

WORKDIR /app

RUN corepack enable
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY . .

# oxc-node runs the TypeScript as-is.
CMD ["node", "--import", "@oxc-node/core/register", "services/fedify_service.ts"]
