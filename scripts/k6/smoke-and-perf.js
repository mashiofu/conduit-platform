// Smoke test + performance baseline probe, run by conduit-platform's
// deploy-backend.yml right after a deploy, against the real,
// just-deployed endpoint (BASE_URL). Deliberately mixes a cache-friendly
// anonymous read (/tags, /articles - see the backend's cache middleware)
// with a real write (register) so the numbers reflect more than just
// "how fast is Redis."
//
// Each iteration registers a new user - this does add rows to the real
// database on every run (not cleaned up). Acceptable at this scale
// (10 VUs x 30s), not something to run continuously.
import http from "k6/http";
import { check, sleep } from "k6";

const BASE_URL = __ENV.BASE_URL || "http://localhost:8080/api";

export const options = {
  scenarios: {
    smoke_and_perf: {
      executor: "constant-vus",
      vus: 10,
      duration: "30s",
    },
  },
  thresholds: {
    http_req_failed: ["rate<0.05"],
  },
};

export default function () {
  const tagsRes = http.get(`${BASE_URL}/tags`);
  check(tagsRes, { "tags: 200": (r) => r.status === 200 });

  const articlesRes = http.get(`${BASE_URL}/articles?limit=20`);
  check(articlesRes, { "articles: 200": (r) => r.status === 200 });

  const username = `k6_${__VU}_${__ITER}_${Date.now()}`;
  const registerRes = http.post(
    `${BASE_URL}/users`,
    JSON.stringify({
      user: { username, email: `${username}@example.com`, password: "k6smoketestpass123" },
    }),
    { headers: { "Content-Type": "application/json" } },
  );
  check(registerRes, { "register: 2xx": (r) => r.status >= 200 && r.status < 300 });

  sleep(1);
}

export function handleSummary(data) {
  const summary = {
    p95_ms: Math.round(data.metrics.http_req_duration.values["p(95)"]),
    error_rate: data.metrics.http_req_failed ? data.metrics.http_req_failed.values.rate : 0,
    timestamp: new Date().toISOString(),
  };
  return {
    stdout: JSON.stringify(summary, null, 2),
    "summary.json": JSON.stringify(summary, null, 2),
  };
}
