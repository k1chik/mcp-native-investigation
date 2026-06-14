// V4 — tools/call hot-path latency
//
// Measures p50 / p90 / p95 of the native mcp_router tools/call path under load.
// Thresholds are sanity ceilings only (not a performance SLA); the actual numbers
// in the run output are the measurement.
//
// Run:   k6 run v4-latency.js
// Needs: gateway on localhost:10000 (docker compose up -d first)

import http from 'k6/http';
import { check } from 'k6';

export const options = {
  vus: 10,
  duration: '15s',
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<200'],
  },
};

const GW = 'http://localhost:10000';
const HEADERS = {
  'Content-Type': 'application/json',
  'Accept': 'application/json, text/event-stream',
};

export default function () {
  const res = http.post(GW, JSON.stringify({
    jsonrpc: '2.0',
    id: 1,
    method: 'tools/call',
    params: { name: 'server1__tool1', arguments: {} },
  }), { headers: HEADERS });
  check(res, { 'status 200': (r) => r.status === 200 });
}
