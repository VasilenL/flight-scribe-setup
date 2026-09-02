# A/B build of scribe-bun pinned to a specific Bun version, so we can compare the last
# Zig release (1.3.14) against the Rust rewrite (latest). Same source, same everything —
# only the Bun runtime binary differs.
#
#   docker build --build-arg BUN_TAG=1.3.14 -f deploy/scribe-bun-ab.Dockerfile -t scribe-bun-zig:local  ../scribe-bun
#   docker build --build-arg BUN_TAG=latest  -f deploy/scribe-bun-ab.Dockerfile -t scribe-bun-rust:local ../scribe-bun
ARG BUN_TAG=latest
FROM oven/bun:${BUN_TAG}
WORKDIR /app
ENV NODE_ENV=production
COPY package.json bun.lock* ./
RUN bun install --production
COPY src ./src
EXPOSE 1337
CMD ["bun", "src/server.ts"]
