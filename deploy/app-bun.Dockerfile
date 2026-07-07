# app-bun: the my-vue-app SPA served + /api by flight-bun (raw Bun.serve).
# The A/B twin of app.Dockerfile — SAME frontend, SAME data tier; only the server
# runtime differs (Bun/Bun.serve vs Node/Koa), so a load test isolates the runtime.
#
# Build context = /home/vasilen (needs both my-vue-app-bun and flight-bun):
#   docker build -f deploy/app-bun.Dockerfile -t my-vue-app-bun:local /home/vasilen

# ---- build the SPA (Node + pnpm — identical toolchain to the Node app, for fairness) ----
FROM node:24-bookworm-slim AS webbuild
WORKDIR /web
RUN npm i -g pnpm@10
COPY my-vue-app-bun/package.json my-vue-app-bun/pnpm-lock.yaml my-vue-app-bun/pnpm-workspace.yaml ./
RUN CI=true pnpm install --no-frozen-lockfile
COPY my-vue-app-bun/ ./
RUN pnpm exec vite build     # -> /web/dist

# ---- runtime: Bun runs flight-bun, serving built dist + /api on :3000 ----
FROM oven/bun:1
WORKDIR /app
ENV NODE_ENV=production \
    FLIGHT_MODE=production \
    FLIGHT_APP_HOME=/app \
    FLIGHT_PORT=3000 \
    FLIGHT_DIST_PATH=/app/dist \
    FLIGHT_EXCLUDE_PATHS=node_modules,dist
COPY flight-bun/ /flight-bun/
COPY --from=webbuild /web/dist ./dist
COPY my-vue-app-bun/components ./components
EXPOSE 3000
# flight-bun is dependency-free TypeScript — Bun runs it directly, no build step.
CMD ["bun", "/flight-bun/src/server.ts"]
