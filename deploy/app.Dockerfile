# my-vue-app + its Flight backend, as one production image.
#
# The Vue SPA is built to static assets at image-build time; at runtime Flight
# runs in PRODUCTION mode with --disable-vite, serving those static assets AND
# the /api routes (from components/**/*.backend.ts) on a single port :3000.
# This avoids known-issue #10 (every prod worker racing `npx vite build`).
#
# Requires the flightjs:local base image to exist first.
# Build context = the my-vue-app repo:
#   docker build -f deploy/app.Dockerfile -t my-vue-app:local ../my-vue-app

# ---- build stage: install deps + vite build ----
FROM flightjs:local AS build
WORKDIR /app
RUN npm i -g pnpm@10
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN CI=true pnpm install --frozen-lockfile
COPY . .
# Build the SPA (skip vue-tsc typecheck here; `vite build` is what produces dist/).
RUN pnpm exec vite build
# Strip dev deps; runtime only needs the backend component's deps (@koa/router).
RUN CI=true pnpm prune --prod

# ---- runtime stage: Flight (from base) + built app ----
FROM flightjs:local
WORKDIR /app
ENV NODE_ENV=production \
    FLIGHT_MODE=production \
    FLIGHT_APP_HOME=/app \
    FLIGHT_PORT=3000 \
    FLIGHT_DISABLE_VITE=true \
    FLIGHT_DIST_PATH=/app/dist \
    FLIGHT_EXCLUDE_PATHS=node_modules,dist
COPY --from=build /app/dist ./dist
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/components ./components
COPY --from=build /app/package.json ./package.json
EXPOSE 3000
# Runtime config (FLIGHT_APP_SECRET, FLIGHT_REDIS_HOST, SCRIBE_BASE_URL, ...) is
# supplied by the orchestrator (compose / k8s), NOT baked in.
CMD ["node", "/flight/dist/flight.js", "--mode", "production", "--disable-vite"]
