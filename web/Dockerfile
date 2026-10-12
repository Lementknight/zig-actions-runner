# The web app as one image: Vite bundles it under Bun, then a small Bun server (server.ts) serves
# dist/, answers every non /api path with index.html (deep links), and proxies /api to the read
# API named by API_UPSTREAM at container start. Local dev and CI stay on npm; Bun is used only here.
#
#   docker build -t zig-runner-web web
#   docker run --rm -p 8080:3000 -e API_UPSTREAM=http://host.docker.internal:8081 zig-runner-web
# The Bun version both images share (api/Dockerfile pins the same one; docker.yml fails if they differ).
ARG BUN_VERSION=1.4.3

FROM oven/bun:${BUN_VERSION}-slim AS build
WORKDIR /app
# Installed from the existing package-lock.json; there is no bun.lock in the repo.
COPY package.json package-lock.json ./
RUN bun install --frozen-lockfile
COPY . .
# Only VITE_ names are baked into the browser bundle, so never pass a secret here.
ARG VITE_DATA_SOURCE=http
ARG VITE_API_BASE_URL=/api
ENV VITE_DATA_SOURCE=${VITE_DATA_SOURCE} VITE_API_BASE_URL=${VITE_API_BASE_URL}
# --bun runs tsc and vite on Bun's runtime, so the image needs no Node.
RUN bun --bun run build

FROM oven/bun:${BUN_VERSION}-alpine
WORKDIR /app
COPY --from=build --chown=bun:bun /app/dist ./dist
COPY --chown=bun:bun server.ts ./
ENV NODE_ENV=production PORT=3000
USER bun
EXPOSE 3000
CMD ["bun", "server.ts"]
