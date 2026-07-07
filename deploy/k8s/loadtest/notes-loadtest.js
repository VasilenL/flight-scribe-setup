// k6 load test — fires a fixed number of requests (default 50,000) at the app
// through Caddy, exercising the full path: Caddy -> app(Flight) -> scribe -> postgres.
//
// Run (native k6):
//   k6 run -e BASE_URL=http://<node-ip> deploy/k8s/loadtest/notes-loadtest.js
// Run (no install, via Docker):
//   docker run --rm -i -e BASE_URL=http://<node-ip> grafana/k6 run - < deploy/k8s/loadtest/notes-loadtest.js
//
// Tunables (env): BASE_URL, VUS (concurrency), ITERATIONS (total requests),
//   WRITE_RATIO (0..1 fraction of requests that POST a new note; default 0 = reads only).
import http from 'k6/http'
import { check } from 'k6'

const BASE = __ENV.BASE_URL || 'http://localhost'
const WRITE_RATIO = Number(__ENV.WRITE_RATIO || 0)
const VUS = Number(__ENV.VUS || 100)
const DURATION = __ENV.DURATION || '' // e.g. "3m" → sustained load (nicer for Grafana)
const RAMP = __ENV.RAMP === '1' || __ENV.RAMP === 'true' // step VUs to find the knee

function pickScenario() {
  // RAMP → step the load up so a single run traces the throughput/latency curve.
  if (RAMP) {
    return {
      ramp: {
        executor: 'ramping-vus',
        startVUs: 0,
        stages: [
          { duration: '1m', target: 100 },
          { duration: '1m', target: 200 },
          { duration: '1m', target: 300 },
          { duration: '1m', target: 500 },
          { duration: '1m', target: 700 },
          { duration: '1m', target: 1000 },
          { duration: '30s', target: 0 },
        ],
      },
    }
  }
  // DURATION → constant load for a fixed time (easy to watch in Grafana).
  if (DURATION) {
    return { sustained: { executor: 'constant-vus', vus: VUS, duration: DURATION } }
  }
  // default → fire a fixed number of requests.
  return {
    fixed: {
      executor: 'shared-iterations',
      vus: VUS,
      iterations: Number(__ENV.ITERATIONS || 50000),
      maxDuration: '15m',
    },
  }
}

export const options = {
  scenarios: pickScenario(),
  // Informational markers (a ramp is EXPECTED to cross these near the top — that's the point).
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<1000'],
  },
}

export default function () {
  if (WRITE_RATIO > 0 && Math.random() < WRITE_RATIO) {
    const res = http.post(
      `${BASE}/api/notes`,
      JSON.stringify({ title: `k6-${__VU}-${__ITER}`, body: 'load test' }),
      { headers: { 'Content-Type': 'application/json' } }
    )
    check(res, { 'POST 201': (r) => r.status === 201 })
  } else {
    const res = http.get(`${BASE}/api/notes`)
    check(res, { 'GET 200': (r) => r.status === 200 })
  }
}
