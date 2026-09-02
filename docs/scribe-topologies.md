# Scribe deployment topologies

Scribe is a **reusable data-tier primitive**: a schemaless service with a plain HTTP API
that owns its tables (DDL-on-the-fly), validates writes, keeps version history, and holds
its own connection pool to Postgres. Because it's one small, self-contained image, *where*
and *how* you run it is a **deployment decision made per service** — not a fixed part of the
architecture.

This doc lays out the topologies, when each fits, the trade-offs, and — grounded in our load
tests — how the choice interacts with the write ceiling.

> **Benchmark facts referenced below** (single 24-core node, Bun stack):
> - Edge returning `200` with no data hop: **~146k req/s**.
> - Full write path (edge → scribe → pooled Postgres): **~35k req/s** — node/DB-bound.
> - A **cross-pod** hop costs real kernel networking (overlay + kube-proxy + conntrack); a
>   **localhost** hop skips all of it.
> - **Connection pooling** (pg-promise's warm pool) is what keeps the write path at ~35k
>   instead of collapsing; an *unpooled* per-request hop is far slower.

---

## The decision drivers

Pick a topology by answering four questions about the *specific* service:

| Driver | Leans embedded/sidecar | Leans separate/shared |
|--------|------------------------|-----------------------|
| **Data ownership** — does this service own its data? | yes (own table/DB) | data is cross-cutting/shared |
| **Load symmetry** — does data load track request load? | yes (proportional) | no (fan-out, bursty, write-heavy) |
| **Independent scaling** — must the data tier scale apart from the caller? | no | yes |
| **Latency sensitivity** — is per-request latency critical? | yes (localhost = ~free) | tolerant (saga/async) |

---

## Topology 1 — Embedded / sidecar (service owns its data)

Each service runs its **own scribe** as a sidecar; they talk over **localhost**. The service
owns its table(s), and its writes hit its own Postgres (or its own logical DB).

```
Pod: orders-svc
┌────────────────────────────┐
│  business logic            │
│     │  http://127.0.0.1    │   ← localhost: no overlay, no kube-proxy, no conntrack
│     ▼                      │
│  scribe (sidecar)          │
└─────────────┬──────────────┘
              ▼
       Postgres · orders
```

- **When:** the default for a service that **owns its data** and has **balanced** load
  (data work tracks request work). Microservices-orthodox: each service owns its store.
- **How scribe affects it:** because scribe is one image with its own pool and does its own
  DDL, "each service owns its table" is trivial — the service just embeds a scribe and starts
  writing; no shared schema, no central DB coordination. The localhost hop is **~free**
  (loopback), so the "extra tier" costs almost nothing.
- **Trade-off:** flight/business and scribe **scale together** (same pod). Fine when load is
  proportional; wrong for write-fan-out (see Topology 4).
- **Example:** a `profile-svc` — one write per profile update, latency-sensitive, owns the
  `profiles` table. Sidecar scribe, done.

---

## Topology 2 — Shared central scribe (one data substrate)

Many services call **one shared scribe** (a fleet behind a Service). All chains land in the
same place; scribe hosts everyone's tables.

```
users-svc  ─┐
orders-svc ─┼── http ──►  scribe (shared fleet)  ──►  Postgres (one DB, many tables)
carts-svc  ─┘
```

- **When:** low-to-moderate scale, or genuinely **cross-cutting data** with no clear owner
  (e.g., an internal tool, a small back-office, a shared reference dataset). Operationally
  simplest — one thing to run, monitor, back up.
- **How scribe affects it:** scribe's schemaless multi-table nature makes "one service, many
  tenants' tables" easy — but that convenience is also the trap.
- **Trade-off (important):** this is the classic **shared-database coupling**. Every service
  depends on one component, and — critically — **they all share one ~35k ceiling** and one
  blast radius. A hot service starves the others. Good for convenience/low scale; **does not
  scale writes** for a busy mesh.
- **Example:** an early-stage app where five small services share one scribe — simple, and
  fine until one service's write volume dominates.

---

## Topology 3 — Dedicated scribe fleet (independently scaled)

A service's data tier is a **separate scribe Deployment**, scaled on its own (HPA), fronting
its own Postgres.

```
audit-svc ── http ──►  scribe fleet (×N, autoscaled)  ──►  Postgres · audit
```

- **When:** the data tier must scale **independently** of the caller — scribe itself is
  CPU-bound (heavy validation/transform), or you want to absorb spikes with more replicas,
  or several callers share this one dataset and you size it to their combined load.
- **How scribe affects it:** same image as the sidecar — you just deploy it standalone with
  its own Service + HPA. **Nothing about scribe changes**; only the topology does.
- **Trade-off:** you pay a **cross-pod hop** (real network cost) and inherit the
  **persistent-connection vs L4-load-balancing** tension: keep-alive/gRPC connections pin to
  pods, so scaled-up replicas can starve unless you **recycle connections** (max-lifetime),
  do **client-side LB**, or run a **service mesh** (L7). Also: for *pure inserts* this doesn't
  beat the DB's ~35k — more scribe replicas past the DB's capacity make it *worse* (measured).
  It buys **burst headroom** and **scribe-CPU** scaling, not raw insert throughput.
- **Example:** a `search-index-svc` where each write triggers heavy transform work in scribe
  before the insert — scribe's CPU is the bottleneck, so scale it apart from its callers.

---

## Topology 4 — Queue + writer fleet (async, write-heavy)

For fan-out / bursty writes, the caller **enqueues** and returns; an independently-scaled
**writer fleet** (scribe) drains the queue at the DB's sustainable pace.

```
orders-svc ── enqueue ──►  [ queue ]  ──►  scribe-writer fleet (×N)  ──►  Postgres
   (returns fast)                            (drains at ~DB pace)
```

- **When:** one request fans out into **many writes**, or writes are **bursty/bulk**, or you
  must decouple caller latency from write throughput. (Sagas often land here.)
- **How scribe affects it:** scribe is the **writer** that consumes the queue — plus it's the
  natural home for a **transactional outbox** (persist the row *and* the outgoing event in one
  local commit) and **idempotency** on replay. The queue is the **relief valve** a fixed
  sidecar lacks: a burst backs up instead of timing out.
- **Trade-off:** eventual consistency + operational complexity (a queue to run). Still capped
  by the DB's ~35k per shard — the queue smooths bursts and decouples latency, it doesn't
  exceed the ceiling.
- **Example:** `order-fulfillment` — placing one order writes order + line-items + inventory
  reservations + audit events. Enqueue them; the writer fleet drains, retries safely, emits
  saga events via the outbox.

---

## The key insight: per-service ownership *shards the write ceiling*

This is where the benchmark findings meet the mesh.

We proved a single scribe+Postgres tops out at **~35k writes/s** (node-bound), and sharding
*inside one app* didn't help — same node, same wall. But in a **mesh**:

```
users-svc   → scribe → Postgres · users     (own node)  →  ~35k
orders-svc  → scribe → Postgres · orders    (own node)  →  ~35k
carts-svc   → scribe → Postgres · carts     (own node)  →  ~35k
...×12
                                            aggregate  →  ~12 × 35k
```

Because **each service owns its own scribe + Postgres on its own resources**, each gets its
*own* ~35k ceiling. **Aggregate write throughput scales with the number of services** — the
horizontal scaling we *couldn't* get by sharding one database, obtained "for free" from
**service decomposition + data ownership.**

The corollary: **shared central scribe (Topology 2) forfeits this** — everyone shares one
~35k. For a high-throughput mesh, per-service ownership (Topology 1/3) is what scales.

---

## Decision matrix

| Situation | Topology | Hop | Scales writes? |
|-----------|----------|-----|----------------|
| Owns its data, balanced load, latency-sensitive | **1 · sidecar** | localhost (~free) | per-service (shards the ceiling) |
| Cross-cutting data, low/moderate scale, simple ops | **2 · shared** | cross-pod | ❌ one shared ceiling |
| Data tier must scale independently / scribe-CPU-bound | **3 · dedicated fleet** | cross-pod (+ LB/mesh) | burst & CPU, not raw inserts |
| Write fan-out / bursty / saga steps | **4 · queue + writers** | async | smooths bursts; DB-capped |

---

## Worked example — a mesh that mixes all four

An e-commerce backend, 12 services, some in a checkout saga:

```
profile-svc      →  Topology 1 (sidecar)         own profiles table, localhost
catalog-svc      →  Topology 1 (sidecar)         own catalog, read-heavy
cart-svc         →  Topology 1 (sidecar)         own carts, balanced
search-svc       →  Topology 3 (dedicated fleet) heavy transform per write, scale apart
reporting-svc    →  Topology 2 (shared scribe)   cross-cutting, low write rate
order-fulfilment →  Topology 4 (queue + writers) checkout saga fans out many writes
```

- **Latency where it matters:** profile/catalog/cart do a **localhost** scribe hop — ~free,
  and each shards its own ~35k ceiling.
- **Independent scaling where needed:** search-svc's scribe is CPU-bound, so it's a separate
  autoscaled fleet (with connection recycling so HPA actually rebalances).
- **Convenience where it's cheap:** reporting shares a scribe — low volume, simplest ops.
- **Throughput + durability under saga load:** fulfilment enqueues; a writer fleet drains at
  DB pace, with a transactional outbox emitting the saga events. In the saga, the per-step
  scribe hop is **negligible** next to the 11 inter-service calls — the real concerns are
  durability, idempotency, and ordering, which scribe (write + outbox in one commit) anchors.

Same scribe image everywhere — **only the topology differs, chosen per service by data
ownership and load shape.**

---

## Rules of thumb

1. **Default to sidecar (Topology 1)** for a service that owns its data with balanced load —
   localhost hop is ~free and it shards the write ceiling.
2. **Reach for a dedicated fleet (Topology 3)** only when the data tier must scale *apart*
   from its caller — and then add **connection recycling / client-LB / a mesh** so persistent
   connections don't break HPA.
3. **Use a queue + writer fleet (Topology 4)** for write fan-out / bursts / sagas — decouple
   latency, absorb bursts, and host the outbox there.
4. **Shared central scribe (Topology 2)** is for convenience at low scale or genuinely
   ownerless data — never as the write path of a busy mesh (one shared ceiling).
5. **Writes are ultimately DB-bound (~35k/shard/node).** You scale writes by **owning data
   per service** (many DBs on many nodes), not by piling replicas on one DB.
6. **Pooling is non-negotiable** — a warm connection pool (pg-promise per pod) is what makes
   any of these fast; an unpooled per-request hop is slower than the DB it's trying to reach.
