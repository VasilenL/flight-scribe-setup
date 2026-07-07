# Flight base image: compiled Flight + production-only node_modules.
# The app image (app.Dockerfile) builds FROM this. It carries no app code itself.
#
# Build context = the Flight repo:
#   docker build -f deploy/flight.Dockerfile -t flightjs:local ../flight
#
# (yargs is pinned to ^17 in the repo — Flight otherwise crashes at boot on the
#  ESM-only yargs 18. See the flight-yargs-esm-fix note.)

# ---- build: install all deps, compile TS -> dist ----
FROM node:20.20.2-bookworm-slim AS build
WORKDIR /flight
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

# ---- base runtime layer: prod deps + compiled dist, no CMD ----
FROM node:20.20.2-bookworm-slim
ENV NODE_ENV=production
WORKDIR /flight
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY --from=build /flight/dist ./dist
# Intentionally no CMD/ENTRYPOINT: the app image invokes node /flight/dist/flight.js.
