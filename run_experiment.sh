#!/usr/bin/env bash
set -euo pipefail

# -----------------------
# Configuration / Inputs
# -----------------------
# defaults
NAME="run_$(date -u +%Y%m%dT%H%M%SZ)"
TTL=600
ROTATE=300
GRACE=60
DURATION=180   # seconds for k6 runs
PROM_HOST="http://localhost:9090"
GATEWAY_URL="http://localhost:8080/accounts"
AUTH_ISSUE_URL="http://localhost:7700/issue"
AUTH_INTROSPECT_URL="http://localhost:7000/introspect"

# parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --name) NAME="$2"; shift 2;;
    --ttl) TTL="$2"; shift 2;;
    --rotate) ROTATE="$2"; shift 2;;
    --grace) GRACE="$2"; shift 2;;
    --duration) DURATION="$2"; shift 2;;
    *) echo "Unknown arg $1"; exit 1;;
  esac
done

# Derived
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="runs/${NAME}_${TIMESTAMP}"
mkdir -p "$RUN_DIR"

echo "=== Experiment: $NAME @ $TIMESTAMP ==="
echo "TTL=$TTL ROTATE=$ROTATE GRACE=$GRACE DURATION=${DURATION}s"
echo "Results will be saved into: $RUN_DIR"

# -----------------------
# 0) Create temporary .env.test for docker compose
# -----------------------
cat > .env.test <<EOF
ACCESS_TTL_SEC=${TTL}
ROTATE_INTERVAL_SEC=${ROTATE}
GRACE_SEC=${GRACE}
EOF

echo "Wrote .env.test:"
cat .env.test

# -----------------------
# 1) Reset stack (down + up)
# -----------------------
echo "Bringing down existing stack (if any) and removing volumes..."
docker compose down -v || true

echo "Starting stack with test env..."
# docker compose will read .env.test if you instruct it; easiest is to export variables so compose uses them
export ACCESS_TTL_SEC=${TTL}
export ROTATE_INTERVAL_SEC=${ROTATE}
export GRACE_SEC=${GRACE}

docker compose up --build -d
echo "Waiting 8s for services to be ready..."
sleep 8

# Save docker ps snapshot
docker compose ps > "$RUN_DIR/docker_ps.txt"

# -----------------------
# 2) Health checks
# -----------------------
echo "Prometheus targets at: $PROM_HOST/targets"
curl -s "$PROM_HOST/api/v1/targets" | jq '.data.activeTargets | length as $n | {count:$n} ' > "$RUN_DIR/prom_targets_summary.json" || true

# -----------------------
# 3) Issue token (clean)
# -----------------------
echo "Issuing test token..."
TOKEN_RAW=$(curl -s -X POST "$AUTH_ISSUE_URL" \
  -H 'Content-Type: application/json' \
  -d '{"service_id":"accounts"}')

echo "$TOKEN_RAW" | jq . > "$RUN_DIR/token_raw.json" || true

TOKEN=$(echo "$TOKEN_RAW" | jq -r .access_token 2>/dev/null || echo "")
# sanitize:
TOKEN=$(echo -n "$TOKEN" | tr -d '\r\n"')

if [[ -z "$TOKEN" ]]; then
  echo "Failed to obtain token. Contents of response saved at $RUN_DIR/token_raw.json"
  exit 1
fi

echo "Token issued and cleaned (saved to file)."
echo "$TOKEN" > "$RUN_DIR/token.txt"

# Quick sanity call through gateway
echo "Sanity call to gateway with token..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "$GATEWAY_URL" || true)
echo "Gateway responded with HTTP $HTTP_CODE" | tee "$RUN_DIR/gateway_sanity.txt"

# -----------------------
# 4) Start k6 baseline + replay concurrently
# -----------------------
echo "Starting k6 baseline and replay..."
# run baseline in background
( k6 run -e TOKEN="$TOKEN" --duration "${DURATION}s" k6/baseline.js 2>&1 | tee "$RUN_DIR/k6_baseline.log" ) & BASE_PID=$!

# small delay to let baseline ramp up
sleep 3

# run replay (attacker) in background
( k6 run -e STOLEN_TOKEN="$TOKEN" --duration "${DURATION}s" k6/replay.js 2>&1 | tee "$RUN_DIR/k6_replay.log" ) & REPLAY_PID=$!

echo "k6 baseline PID=$BASE_PID, replay PID=$REPLAY_PID"
wait $BASE_PID || true
wait $REPLAY_PID || true
echo "k6 runs completed."

# -----------------------
# 5) Measure misuse window - poll until 401 or timeout (max 2x TTL or 600s)
# -----------------------
echo "Measuring misuse window..."
START_TS=$(date +%s)
MAX_WAIT=$(( (TTL * 2) > 600 ? (TTL * 2) : 600 ))
MISUSE_CSV="$RUN_DIR/misuse_window.csv"
echo "elapsed_s,http_code" > "$MISUSE_CSV"

while true; do
  NOW_TS=$(date +%s)
  ELAPSED=$(( NOW_TS - START_TS ))
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" "$GATEWAY_URL" || echo "000")
  echo "${ELAPSED},${CODE}" | tee -a "$MISUSE_CSV" > /dev/null
  if [[ "$CODE" == "401" || "$ELAPSED" -ge "$MAX_WAIT" ]]; then
    break
  fi
  sleep 1
done

echo "Misuse window logged to $MISUSE_CSV"

# -----------------------
# 6) Export Prometheus metrics (time range from START_TS to now)
# -----------------------
END_TS=$(date +%s)
STEP=10

echo "Exporting Prometheus series (start=$START_TS end=$END_TS step=$STEP)..."

# helper to call prometheus query_range with url-encoded query
prom_query_range () {
  local q="$1"; local out="$2"
  # use curl --get --data-urlencode for proper encoding
  curl -s --get --data-urlencode "query=$q" \
    --data "start=${START_TS}" --data "end=${END_TS}" --data "step=${STEP}" \
    "$PROM_HOST/api/v1/query_range" \
    | jq -r '
      if (.data.result | length) == 0 then
        "timestamp,value"
      else
        .data.result[0].values[] | @csv
      end
    ' > "$out"
}

# p95 gateway latency (ms)
prom_query_range 'histogram_quantile(0.95, sum(rate(gateway_request_latency_ms_bucket[1m])) by (le))' "$RUN_DIR/p95_gateway_latency.csv"

# avg gateway latency (ms)
prom_query_range 'sum(rate(gateway_request_latency_ms_sum[1m])) / sum(rate(gateway_request_latency_ms_count[1m]))' "$RUN_DIR/avg_gateway_latency.csv"

# throughput (req/s)
prom_query_range 'sum(rate(gateway_request_latency_ms_count[1m]))' "$RUN_DIR/rps_gateway.csv"

# auth introspect p95
prom_query_range 'histogram_quantile(0.95, sum(rate(introspection_latency_ms_bucket[1m])) by (le))' "$RUN_DIR/p95_introspect.csv"

# rotation events and errors (cumulative increases)
prom_query_range 'increase(rotation_events_total[5m])' "$RUN_DIR/rotation_events_inc_5m.csv"
prom_query_range 'increase(rotation_errors_total[5m])' "$RUN_DIR/rotation_errors_inc_5m.csv"

echo "Prometheus exports saved to $RUN_DIR"

# -----------------------
# 7) Save logs
# -----------------------
echo "Saving container logs (auth,gateway,accounts,rotation,prometheus)..."
docker compose logs auth > "$RUN_DIR/log_auth.txt" || true
docker compose logs gateway > "$RUN_DIR/log_gateway.txt" || true
docker compose logs accounts > "$RUN_DIR/log_accounts.txt" || true
docker compose logs rotation > "$RUN_DIR/log_rotation.txt" || true
docker compose logs prometheus > "$RUN_DIR/log_prometheus.txt" || true

# -----------------------
# 8) Save prometheus targets & metrics snapshot
# -----------------------
curl -s "$PROM_HOST/api/v1/targets" | jq . > "$RUN_DIR/prom_targets_full.json" || true
curl -s "$PROM_HOST/api/v1/label/__name__/values" | jq . > "$RUN_DIR/prom_metric_names.json" || true

# -----------------------
# 9) Package run folder (optional)
# -----------------------
tar -czf "${RUN_DIR}.tar.gz" -C "$(dirname "$RUN_DIR")" "$(basename "$RUN_DIR")"
echo "Packaged run to ${RUN_DIR}.tar.gz"

# -----------------------
# 10) Cleanup .env.test (keep for record or remove)
# -----------------------
# mv .env.test "$RUN_DIR/"  # uncomment to archive the .env.test used
# rm .env.test               # uncomment to remove it

echo "=== DONE: run saved to $RUN_DIR (and tarball). ==="
echo "Inspect CSVs and logs. For plots, import CSV into Sheets/Excel or use Python plotting."

exit 0
