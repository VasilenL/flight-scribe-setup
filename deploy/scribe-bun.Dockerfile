# Scribe data tier, rewritten on Bun (Bun.serve + cached Ajv). A/B twin of scribe.Dockerfile.
# Build context = the scribe-bun repo:
#   docker build -f deploy/scribe-bun.Dockerfile -t scribe-bun:local ../scribe-bun
FROM oven/bun:1
WORKDIR /app
ENV NODE_ENV=production
COPY package.json bun.lock* ./
RUN bun install --production
COPY src ./src
EXPOSE 1337
# Bun runs the TypeScript directly — no build step.
CMD ["bun", "src/server.ts"]
