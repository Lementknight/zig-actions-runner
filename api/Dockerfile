# The read API (api/README.md) on Bun. Bun runs src/server.ts directly; there is no build step.
# DATABASE_URL is read when the container starts and never baked into an image layer.
#
#   docker build -t zig-actions-api api
#   docker run --rm -e DATABASE_URL=... -p 8080:8080 zig-actions-api

# Install production dependencies only (hono, @hono/node-server, pg) from the npm lockfile, which
# bun reads in place. Local dev and CI stay on npm, so the repo has no bun.lock.
FROM oven/bun:1.4.3 AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN bun install --frozen-lockfile --production --no-cache

FROM oven/bun:1.4.3-slim
WORKDIR /app
ENV NODE_ENV=production \
    PORT=8080
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src
USER bun
EXPOSE 8080
# /api/health runs SELECT 1, so the container is healthy only while the database answers.
# The slim image has no curl; bun's own fetch does the request.
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD ["bun", "-e", "const r = await fetch(`http://127.0.0.1:${process.env.PORT}/api/health`); process.exit(r.ok ? 0 : 1)"]
CMD ["bun", "src/server.ts"]
