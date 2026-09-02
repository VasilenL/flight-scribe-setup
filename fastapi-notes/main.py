import json
import os
from contextlib import asynccontextmanager

import asyncpg
from fastapi import FastAPI
from pydantic import BaseModel

DB_DSN = os.environ.get("DB_DSN", "postgres://scribe:scribe@pgbouncer:5432/scribe")
# Per-worker pool. With WEB_WORKERS workers per pod, total = WEB_WORKERS * DB_POOL_MAX.
# Sized so the POD total matches scribe-bun's SCRIBE_APP_DB_POOL_MAX (100 per pod).
POOL_MAX = int(os.environ.get("DB_POOL_MAX", "25"))

pool: asyncpg.Pool | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global pool
    # statement_cache_size=0 is REQUIRED behind PgBouncer transaction pooling — asyncpg's
    # prepared-statement cache otherwise collides across pooled server connections.
    pool = await asyncpg.create_pool(
        dsn=DB_DSN, min_size=10, max_size=POOL_MAX, statement_cache_size=0
    )
    async with pool.acquire() as c:
        await c.execute(
            "CREATE TABLE IF NOT EXISTS bench_notes "
            "(id serial PRIMARY KEY, title text, body text, created_at timestamptz DEFAULT now())"
        )
        # Mirrors scribe's `<component>_history` table so the write path does the SAME DB
        # work: same shape, same json column, same FK-with-cascade. See create() below.
        await c.execute(
            "CREATE TABLE IF NOT EXISTS bench_notes_history "
            "(id serial PRIMARY KEY, "
            " foreign_key integer REFERENCES bench_notes (id) ON DELETE CASCADE, "
            " patches json)"
        )
    yield
    await pool.close()


app = FastAPI(lifespan=lifespan)


class NoteIn(BaseModel):
    title: str
    body: str


@app.post("/api/notes", status_code=201)
async def create(n: NoteIn):
    # TWO inserts per write, deliberately — scribe-bun writes a row PLUS a version-history
    # row on every create (db.ts createSingle), so a single-INSERT endpoint here would do
    # half the database work and the cross-runtime comparison would be meaningless.
    #
    # NOT replicated: scribe's diff_match_patch patch computation — that's runtime CPU, not
    # DB work. We store the serialized row instead, keeping the written payload comparable
    # in size.
    async with pool.acquire() as c:
        row = await c.fetchrow(
            "INSERT INTO bench_notes(title, body) VALUES($1, $2) "
            "RETURNING id, title, body, created_at",
            n.title, n.body,
        )
        patches = json.dumps([json.dumps(dict(row), default=str)])
        await c.fetchrow(
            "INSERT INTO bench_notes_history(foreign_key, patches) "
            "VALUES($1, $2::json) RETURNING id",
            row["id"], patches,
        )
    return dict(row)


@app.get("/api/notes")
async def list_notes():
    async with pool.acquire() as c:
        rows = await c.fetch(
            "SELECT id, title, body, created_at FROM bench_notes ORDER BY id DESC LIMIT 100"
        )
    return [dict(r) for r in rows]


@app.get("/health")
async def health():
    return {"status": "ok"}
