# Convenience targets for the Flight + Scribe local dev stack.
# Requires Docker Desktop (docker compose v2) and Node 20.11 (see .nvmrc in flight/).

FLIGHT_DIR ?= ../flight
SCRIBE_DIR ?= ../scribe
APP_DIR ?= ./student-app

.PHONY: up down logs ps reset psql redis-cli scribe flight app help

help:
	@echo "Infra:   make up | down | logs | ps | reset"
	@echo "Shells:  make psql | redis-cli"
	@echo "Apps:    make scribe   (runs Scribe :1337)"
	@echo "         make flight   (builds local Flight)"
	@echo "         make app      (runs the student-app demo :3001)"

up:            ## Start Postgres + Redis + Caddy
	docker compose up -d

down:          ## Stop infra (keeps volumes)
	docker compose down

reset:         ## Stop infra AND wipe volumes (destroys DB + cache)
	docker compose down -v

logs:
	docker compose logs -f

ps:
	docker compose ps

psql:
	docker compose exec postgres psql -U scribe -d scribe

redis-cli:
	docker compose exec redis redis-cli

# Runs Scribe against the dockerized Postgres/Redis. Expects env/scribe.env copied
# into $(SCRIBE_DIR)/.env (or export the SCRIBE_APP_* vars yourself).
scribe:
	cd $(SCRIBE_DIR) && npm install && npm start

# Builds the local Flight repo so its dist/flight.js exists for apps to launch.
flight:
	cd $(FLIGHT_DIR) && npm install && npm run build

# Runs the bundled student-app demo (launches local Flight, which spawns Vite :3001).
# Expects `make flight` already built Flight and `make scribe` is running.
app:
	cd $(APP_DIR) && npm install && npm run dev
