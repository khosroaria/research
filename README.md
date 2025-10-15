
# Token Replay vs Short-Lived Rotation (Ultra Mini)
Minimal setup to measure token replay risk vs short-lived automated rotation.

## Run
docker compose up --build -d

# Issue token (use as "stolen" in replay)
curl -s -X POST http://localhost:7000/issue -H 'Content-Type: application/json' -d '{"service_id":"accounts"}'

# Baseline (valid token)
TOKEN=PASTE_TOKEN k6 run k6/baseline.js

# Replay (stolen token)
STOLEN_TOKEN=PASTE_TOKEN k6 run k6/replay.js

## Change TTL / Rotation
- In docker-compose.yml:
  - auth.ACCESS_TTL_SEC (e.g., 86400, 600, 300, 60)
  - rotation.ROTATE_INTERVAL_SEC (e.g., =TTL or TTL/2)
docker compose up -d --force-recreate auth rotation

## Metrics
Prometheus: http://localhost:9090
- gateway_request_latency_ms (p50/p95/p99)
- introspection_latency_ms
- issue_tokens_total
- rotation_events_total / rotation_errors_total
