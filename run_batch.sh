#!/usr/bin/env bash
set -euo pipefail

# Ensure the single-run script is present
if [[ ! -x ./run_experiment.sh ]]; then
  echo "ERROR: ./run_experiment.sh not found or not executable."
  echo "Make sure it exists and run: chmod +x run_experiment.sh"
  exit 1
fi

# --------------------------------------------
# Define scenarios: name,ttl,rotate,grace,duration
# Edit this list as needed.
# --------------------------------------------
SCENARIOS=(
  # name, TTL(sec), rotation(sec), grace(sec), duration(sec)
  "control,86400,0,0,300"             # No rotation — baseline misuse window (24h token)
  "balanced,300,150,30,300"           # Moderate rotation, realistic for production
  "moderate,600,300,60,300"           # Longer TTL — lower overhead
  "short,120,60,15,300"               # Aggressive, real-time apps (tight security)
  "aggressive,60,30,10,300"           # Very short TTL, rotation overlap for testing edge
  "very_aggressive,30,15,5,300"       # Stress-test scenario — extreme rotation cost
)


BATCH_TS=$(date -u +%Y%m%dT%H%M%SZ)
AGG_DIR="runs/_aggregate/${BATCH_TS}"
mkdir -p "${AGG_DIR}"

# Aggregate file names
AGG_P95_GATEWAY="${AGG_DIR}/agg_p95_gateway_latency.csv"
AGG_AVG_GATEWAY="${AGG_DIR}/agg_avg_gateway_latency.csv"
AGG_RPS_GATEWAY="${AGG_DIR}/agg_rps_gateway.csv"
AGG_P95_INTROSPECT="${AGG_DIR}/agg_p95_introspect.csv"
AGG_MISUSE="${AGG_DIR}/agg_misuse_window.csv"

# Initialize headers
echo "scenario,timestamp,value" > "$AGG_P95_GATEWAY"
echo "scenario,timestamp,value" > "$AGG_AVG_GATEWAY"
echo "scenario,timestamp,value" > "$AGG_RPS_GATEWAY"
echo "scenario,timestamp,value" > "$AGG_P95_INTROSPECT"
echo "scenario,elapsed_s,http_code" > "$AGG_MISUSE"

# Helper: latest run dir for a given name
latest_run_dir_for() {
  local name="$1"
  # Pick the most recent directory that starts with name_
  ls -1d runs/"${name}"_* 2>/dev/null | sort | tail -n1
}

# Helper: prepend scenario to CSV rows "timestamp,value" -> "scenario,timestamp,value"
# Skip headers/blank lines; only accept lines that start with [ or digit or quote-digit (Prom API often returns [ts,val])
prepend_scenario_csv() {
  local scenario="$1"
  local infile="$2"
  local outfile="$3"
  # Accept lines that look like "1234567890","12.3" or 1234567890,12.3
  awk -v s="$scenario" -F, '
    BEGIN { OFS="," }
    {
      gsub(/"/, "", $0);
      # lines like timestamp,value (both numeric)
      if ($1 ~ /^[0-9]+$/ && $2 ~ /^-?[0-9.]+$/) {
        print s,$1,$2
      }
    }
  ' "$infile" >> "$outfile"
}

# Helper: prepend scenario to misuse_window.csv "elapsed_s,http_code" -> "scenario,elapsed_s,http_code"
prepend_scenario_misuse() {
  local scenario="$1"
  local infile="$2"
  local outfile="$3"
  awk -v s="$scenario" -F, '
    BEGIN { OFS="," }
    NR==1 { next } # skip header "elapsed_s,http_code"
    {
      gsub(/"/, "", $0);
      # accept numeric elapsed_s and numeric http code
      if ($1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/) {
        print s,$1,$2
      }
    }
  ' "$infile" >> "$outfile"
}

# --------------------------------------------
# Main loop
# --------------------------------------------
for spec in "${SCENARIOS[@]}"; do
  IFS=',' read -r NAME TTL ROTATE GRACE DURATION <<< "$spec"

  echo
  echo "===== Running scenario: $NAME (TTL=$TTL, ROTATE=$ROTATE, GRACE=$GRACE, DURATION=${DURATION}s) ====="
  ./run_experiment.sh --name "$NAME" --ttl "$TTL" --rotate "$ROTATE" --grace "$GRACE" --duration "$DURATION"

  RUN_DIR=$(latest_run_dir_for "$NAME")
  if [[ -z "$RUN_DIR" ]]; then
    echo "ERROR: Could not locate run directory for scenario $NAME"
    exit 1
  fi
  echo "Using run dir: $RUN_DIR"

  # Aggregate Prometheus CSVs
  if [[ -f "$RUN_DIR/p95_gateway_latency.csv" ]]; then
    prepend_scenario_csv "$NAME" "$RUN_DIR/p95_gateway_latency.csv" "$AGG_P95_GATEWAY"
  fi
  if [[ -f "$RUN_DIR/avg_gateway_latency.csv" ]]; then
    prepend_scenario_csv "$NAME" "$RUN_DIR/avg_gateway_latency.csv" "$AGG_AVG_GATEWAY"
  fi
  if [[ -f "$RUN_DIR/rps_gateway.csv" ]]; then
    prepend_scenario_csv "$NAME" "$RUN_DIR/rps_gateway.csv" "$AGG_RPS_GATEWAY"
  fi
  if [[ -f "$RUN_DIR/p95_introspect.csv" ]]; then
    prepend_scenario_csv "$NAME" "$RUN_DIR/p95_introspect.csv" "$AGG_P95_INTROSPECT"
  fi

  # Aggregate misuse window CSV
  if [[ -f "$RUN_DIR/misuse_window.csv" ]]; then
    prepend_scenario_misuse "$NAME" "$RUN_DIR/misuse_window.csv" "$AGG_MISUSE"
  fi

  echo "Aggregated $NAME"
done

echo
echo "=== DONE. Aggregates in: $AGG_DIR ==="
echo "- $AGG_P95_GATEWAY"
echo "- $AGG_AVG_GATEWAY"
echo "- $AGG_RPS_GATEWAY"
echo "- $AGG_P95_INTROSPECT"
echo "- $AGG_MISUSE"
