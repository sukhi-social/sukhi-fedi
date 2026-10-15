# SPDX-License-Identifier: AGPL-3.0-or-later
FROM node:22-alpine

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY . .

# tsx runs the TypeScript as-is (node 22 alone would need a flag).
CMD ["node", "--import", "tsx", "services/fedify_service.ts"]
