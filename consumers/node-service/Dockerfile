FROM node:24-bookworm-slim@sha256:879b21aec4a1ad820c27ccd565e7c7ed955f24b92e6694556154f251e4bdb240 AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build && npm prune --omit=dev


FROM gcr.io/distroless/nodejs24-debian13:nonroot@sha256:f16acace4aa70086d4a2caad6c716f01e3e2fe0dd8274c4530c7c17d987bdb1a AS runner
WORKDIR /app
COPY --from=builder --chown=nonroot:nonroot /app/dist ./dist
COPY --from=builder --chown=nonroot:nonroot /app/node_modules ./node_modules
COPY --from=builder --chown=nonroot:nonroot /app/package*.json ./
EXPOSE 3000
CMD ["dist/main.js"]
