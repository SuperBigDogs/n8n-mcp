# syntax=docker/dockerfile:1.7
# Ultra-optimized Dockerfile - minimal runtime dependencies (no n8n packages)

# --- Stage 1: Builder (TypeScript compilation only)
FROM node:22-alpine AS builder
WORKDIR /app

COPY tsconfig*.json ./

RUN --mount=type=cache,target=/root/.npm \
    echo '{}' > package.json && \
    npm install --no-save typescript@^5.8.3 @types/node@^22.15.30 @types/express@^5.0.3 \
        @modelcontextprotocol/sdk@^1.12.1 dotenv@^16.5.0 express@^5.1.0 axios@^1.10.0 \
        n8n-workflow@^1.96.0 uuid@^11.0.5 @types/uuid@^10.0.0

COPY src ./src
RUN npx tsc -p tsconfig.build.json

# --- Stage 2: Runtime (minimal dependencies)
FROM node:22-alpine AS runtime
WORKDIR /app

RUN apk add --no-cache curl su-exec && rm -rf /var/cache/apk/*

COPY package.runtime.json package.json
RUN --mount=type=cache,target=/root/.npm \
    npm install --production --no-audit --no-fund

COPY --from=builder /app/dist ./dist
COPY data/nodes.db ./data/
COPY src/database/schema-optimized.sql ./src/database/
COPY .env.example ./

COPY docker/docker-entrypoint.sh /usr/local/bin/
COPY docker/parse-config.js /app/docker/
COPY docker/n8n-mcp /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/n8n-mcp

LABEL org.opencontainers.image.source="https://github.com/czlonkowski/n8n-mcp"
LABEL org.opencontainers.image.description="n8n MCP Server - Runtime Only"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.title="n8n-mcp"

# non-root user
RUN BUILD_HASH=$(date +%s | sha256sum | head -c 8) && \
    UID=$((10000 + 0x${BUILD_HASH} % 50000)) && \
    GID=$((10000 + 0x${BUILD_HASH} % 50000)) && \
    addgroup -g ${GID} -S nodejs && \
    adduser -S nodejs -u ${UID} -G nodejs && \
    chown -R nodejs:nodejs /app
USER nodejs

ENV IS_DOCKER=true

# Render will set $PORT; we expose a sane default too
EXPOSE 10000

STOPSIGNAL SIGTERM

# Healthcheck hits the gateway
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD sh -lc 'curl -fsS "http://127.0.0.1:${PORT:-10000}/healthz" || exit 1'

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

# Run stdio MCP via Supergateway to expose HTTP/SSE on $PORT
# Added: --cors and --logLevel debug (helps with n8n preflight/POST)
CMD ["sh","-lc","npx -y supergateway \
  --stdio \"node dist/mcp/index.js\" \
  --port ${PORT:-10000} \
  --baseUrl https://${RENDER_EXTERNAL_HOSTNAME} \
  --ssePath /sse \
  --messagePath /message \
  --healthEndpoint /healthz \
  --logLevel debug \
  --cors"]
