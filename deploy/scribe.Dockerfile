# Scribe data tier, production image (compiled dist + prod-only node_modules).
#
# Build context = the Scribe repo:
#   docker build -f deploy/scribe.Dockerfile -t scribe:local ../scribe

# ---- build: install all deps, compile TS -> dist (+ copy the default schema) ----
FROM node:20.20.2-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

# ---- runtime: prod deps + compiled dist ----
FROM node:20.20.2-bookworm-slim
ENV NODE_ENV=production
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY --from=build /app/dist ./dist
EXPOSE 1337
# Config (SCRIBE_APP_DB_HOST, SCRIBE_APP_REDIS_HOST, SCRIBE_APP_SCHEMA_BASE_URL, ...)
# comes from the orchestrator. NB: Scribe forks one worker per CPU — cap the
# container's CPU (k8s limits / compose `cpus`) to control worker count.
CMD ["node", "dist/scribe.cli.js"]
