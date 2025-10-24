#!/usr/bin/env bash
set -euo pipefail

# Aggregation-only script: rebuilds aggregate CSVs from existing run directories, does NOT rerun experiments.

SCENARIOS=(balanced moderate short aggressive very_aggressive)

BATCH_TS=$(date -u +%Y%m%dT%H%M%SZ)
AGG_DIR="runs/_aggregate/${BATCH_TS}"
mkdir -p "${AGG_DIR}"

AGG_P95_GATEWAY="${AGG_DIR}/agg_p95_gateway_latency.csv"
AGG_AVG_GATEWAY="${AGG_DIR}/agg_avg_gateway_latency.csv"
AGG_RPS_GATEWAY="${AGG_DIR}/agg_rps_gateway.csv"
AGG_P95_INTROSPECT="${AGG_DIR}/agg_p95_introspect.csv"
AGG_MISUSE="${AGG_DIR}/agg_misuse_window.csv"

echo "scenario,timestamp,value" > "$AGG_P95_GATEWAY"
echo "scenario,timestamp,value" > "$AGG_AVG_GATEWAY"
echo "scenario,timestamp,value" > "$AGG_RPS_GATEWAY"
echo "scenario,timestamp,value" > "$AGG_P95_INTROSPECT"
echo "scenario,elapsed_s,http_code" > "$AGG_MISUSE"

prepend_scenario_csv() {
  local scenario="$1"
  local infile="$2"
  local outfile="$3"
  if [[ ! -f "$infile" ]]; then
    echo "[WARN] Missing CSV: $infile (skipping)" >&2
    return
  fi
  local nrows=$(awk 'END{print NR}' "$infile")
  if [[ "$nrows" -le 1 ]]; then
    echo "[WARN] Empty CSV: $infile (skipping)" >&2
    return
  fi
  awk -v s="$scenario" -F, '
    BEGIN { OFS="," }
    NR==1 { next } # skip header
    {
      gsub(/"/, "", $1); gsub(/"/, "", $2);
      if ($1 ~ /^[0-9]+$/ && $2 ~ /^-?[0-9.]+$/) {
        print s,$1,$2
      }
    }
  ' "$infile" >> "$outfile"
  local added=$(awk 'END{print NR-1}' "$infile")
  echo "[INFO] Aggregated $added rows from $infile into $outfile"
}

prepend_scenario_misuse() {
  local scenario="$1"
  local infile="$2"
  local outfile="$3"
  if [[ ! -f "$infile" ]]; then
    echo "[WARN] Missing misuse CSV: $infile (skipping)" >&2
    return
  fi
  local nrows=$(awk 'END{print NR}' "$infile")
  if [[ "$nrows" -le 1 ]]; then
    echo "[WARN] Empty misuse CSV: $infile (skipping)" >&2
    return
  fi
  awk -v s="$scenario" -F, '
    BEGIN { OFS="," }
    NR==1 { next }
    {
      gsub(/"/, "", $1); gsub(/"/, "", $2);
      if ($1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/) {
        print s,$1,$2
      }
    }
  ' "$infile" >> "$outfile"
  local added=$(awk 'END{print NR-1}' "$infile")
  echo "[INFO] Aggregated $added rows from $infile into $outfile"
}


for NAME in "${SCENARIOS[@]}"; do
  # Only consider directories, not .tar.gz files
  RUN_DIR=$(find runs -maxdepth 1 -type d -name "${NAME}_*" | sort | tail -n1)
  if [[ -z "$RUN_DIR" ]]; then
    echo "[WARN] No run directory found for $NAME, skipping."
    continue
  fi
  echo "[INFO] Aggregating $NAME from $RUN_DIR"
  for METRIC in p95_gateway_latency avg_gateway_latency rps_gateway p95_introspect; do
    FILE="$RUN_DIR/${METRIC}.csv"
    if [[ -f "$FILE" ]]; then
      echo "[DEBUG] Found $FILE, head:"; head -3 "$FILE"
    else
      echo "[DEBUG] Missing $FILE"
    fi
  done
  MISUSE_FILE="$RUN_DIR/misuse_window.csv"
  if [[ -f "$MISUSE_FILE" ]]; then
    echo "[DEBUG] Found $MISUSE_FILE, head:"; head -3 "$MISUSE_FILE"
  else
    echo "[DEBUG] Missing $MISUSE_FILE"
  fi
  prepend_scenario_csv "$NAME" "$RUN_DIR/p95_gateway_latency.csv" "$AGG_P95_GATEWAY"
  prepend_scenario_csv "$NAME" "$RUN_DIR/avg_gateway_latency.csv" "$AGG_AVG_GATEWAY"
  prepend_scenario_csv "$NAME" "$RUN_DIR/rps_gateway.csv" "$AGG_RPS_GATEWAY"
  prepend_scenario_csv "$NAME" "$RUN_DIR/p95_introspect.csv" "$AGG_P95_INTROSPECT"
  prepend_scenario_misuse "$NAME" "$RUN_DIR/misuse_window.csv" "$AGG_MISUSE"
  echo "[INFO] Finished aggregating for $NAME"
done

echo
"=== DONE. Aggregates in: $AGG_DIR ==="
echo "- $AGG_P95_GATEWAY"
echo "- $AGG_AVG_GATEWAY"
echo "- $AGG_RPS_GATEWAY"
echo "- $AGG_P95_INTROSPECT"
echo "- $AGG_MISUSE"
