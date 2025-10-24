#!/usr/bin/env bash
set -euo pipefail


# Script to run k6 baseline.js for each scenario, restarting the stack and setting scenario parameters each time.
set -euo pipefail

# Define scenarios: name,ttl,rotate,grace,duration (should match run_batch.sh)
SCENARIOS=(
  "aggressive,10,5,2,120"
  "balanced,30,15,5,120"
  "moderate,60,30,10,120"
  "short,10,5,2,120"
  "very_aggressive,5,2,1,120"
)

for spec in "${SCENARIOS[@]}"; do
  IFS=',' read -r NAME TTL ROTATE GRACE DURATION <<< "$spec"
  echo
  echo "===== Running client latency for scenario: $NAME (TTL=$TTL, ROTATE=$ROTATE, GRACE=$GRACE, DURATION=${DURATION}s) ====="

  # Write .env.test for docker compose
  cat > .env.test <<EOF
ACCESS_TTL_SEC=${TTL}
ROTATE_INTERVAL_SEC=${ROTATE}
GRACE_SEC=${GRACE}
EOF

  echo "Bringing down existing stack (if any) and removing volumes..."
  docker compose down -v || true

  echo "Starting stack with test env..."
  export ACCESS_TTL_SEC=${TTL}
  export ROTATE_INTERVAL_SEC=${ROTATE}
  export GRACE_SEC=${GRACE}
  docker compose up --build -d
  echo "Waiting 8s for services to be ready..."
  sleep 8

  # Find the latest existing run directory for this scenario
  RUN_DIR=$(find runs/ -maxdepth 1 -type d -name "${NAME}_*" | sort | tail -n1)
  if [[ -z "$RUN_DIR" ]]; then
    echo "[WARN] No run directory found for $NAME, skipping."
    continue
  fi
  OUTFILE="$RUN_DIR/client_refresh_latency.csv"

  # Issue a fresh token for this scenario (after stack is up)
  TOKEN_RAW=$(curl -s -X POST http://localhost:7700/issue \
    -H 'Content-Type: application/json' \
    -d '{"service_id":"accounts"}')
  TOKEN=$(echo "$TOKEN_RAW" | jq -r .access_token 2>/dev/null || echo "")
  TOKEN=$(echo -n "$TOKEN" | tr -d '\r\n"')
  if [[ -z "$TOKEN" ]]; then
    echo "[ERROR] Failed to obtain token for $NAME."
    continue
  fi
  echo "[INFO] Fresh token issued for $NAME."

  echo "[INFO] Running k6 baseline for $NAME, capturing CLIENT_REFRESH_LATENCY_MS..."
  set +e
  k6 run -e TOKEN="$TOKEN" --duration "${DURATION}s" k6/baseline.js 2>&1 | grep 'CLIENT_REFRESH_LATENCY_MS' | tee "$OUTFILE.raw"
  set -e
  # Convert raw log to CSV: timestamp,latency_ms
  echo "timestamp,latency_ms" > "$OUTFILE"
  awk -F '[:,"]' '/CLIENT_REFRESH_LATENCY_MS/ { \
    for(i=1;i<=NF;i++) { \
      if ($i ~ /time=/) ts=$(i+1); \
      if ($i ~ /CLIENT_REFRESH_LATENCY_MS/) val=$(i+1); \
    } \
    if (ts && val) print ts "," val; \
  }' "$OUTFILE.raw" >> "$OUTFILE"
  rm -f "$OUTFILE.raw"
  echo "[INFO] Saved $OUTFILE as CSV"
done


# Aggregate all per-scenario client latency CSVs into a single aggregate CSV in _aggregate
AGG_TS=$(date -u +%Y%m%dT%H%M%SZ)
AGG_DIR="runs/_aggregate/${AGG_TS}"
mkdir -p "$AGG_DIR"
AGG_CSV="$AGG_DIR/agg_client_latency.csv"
echo "scenario,latency_ms" > "$AGG_CSV"
for d in runs/*_[0-9TZ]*; do
  SCEN=$(basename "$d" | sed 's/_.*//')
  LAT_FILE="$d/client_refresh_latency.csv"
  if [[ -f "$LAT_FILE" ]]; then
    awk -v s="$SCEN" -F, '{ print s "," $2 }' "$LAT_FILE" >> "$AGG_CSV"
  fi
done
echo "[INFO] Aggregated client latency CSVs into $AGG_CSV"
echo "All scenarios processed and aggregated. Aggregate CSV ready for plotting: $AGG_CSV"
