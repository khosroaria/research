#!/usr/bin/env python3
import os
import sys
import pandas as pd
import matplotlib.pyplot as plt

# --------- config ----------
# Folder created by run_batch.sh: runs/_aggregate/<timestamp>/
AGG_DIR = sys.argv[1] if len(sys.argv) > 1 else None
if not AGG_DIR:
    print("Usage: python plot_aggregates.py runs/_aggregate/<timestamp>/")
    sys.exit(1)

OUT_DIR = os.path.join(AGG_DIR, "plots")
os.makedirs(OUT_DIR, exist_ok=True)

paths = {
    "p95_gateway": os.path.join(AGG_DIR, "agg_p95_gateway_latency.csv"),
    "avg_gateway": os.path.join(AGG_DIR, "agg_avg_gateway_latency.csv"),
    "rps_gateway": os.path.join(AGG_DIR, "agg_rps_gateway.csv"),
    "p95_introspect": os.path.join(AGG_DIR, "agg_p95_introspect.csv"),
    "misuse": os.path.join(AGG_DIR, "agg_misuse_window.csv"),
}

def load_series(path):
    if not os.path.exists(path):
        print(f"WARNING: missing {path}")
        return pd.DataFrame(columns=["scenario","timestamp","value"])
    df = pd.read_csv(path)
    # coerce numeric
    for col in ["timestamp","value"]:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")
    df = df.dropna(subset=["timestamp","value"])
    # sort
    return df.sort_values(["scenario","timestamp"])

def load_misuse(path):
    if not os.path.exists(path):
        print(f"WARNING: missing {path}")
        return pd.DataFrame(columns=["scenario","elapsed_s","http_code"])
    df = pd.read_csv(path)
    df["elapsed_s"] = pd.to_numeric(df["elapsed_s"], errors="coerce")
    df["http_code"] = pd.to_numeric(df["http_code"], errors="coerce")
    df = df.dropna(subset=["elapsed_s","http_code"])
    return df

# Load data
df_p95_gw  = load_series(paths["p95_gateway"])
df_avg_gw  = load_series(paths["avg_gateway"])
df_rps_gw  = load_series(paths["rps_gateway"])
df_p95_int = load_series(paths["p95_introspect"])
df_misuse  = load_misuse(paths["misuse"])

# Helper to plot a time series per scenario
def plot_timeseries(df, title, outfile, ylabel):
    if df.empty:
        print(f"Skip {title}: empty data")
        return
    plt.figure()
    for scen, g in df.groupby("scenario"):
        # normalize time to start at 0 for readability
        t0 = g["timestamp"].min()
        plt.plot(g["timestamp"] - t0, g["value"], label=scen)
    plt.title(title)
    plt.xlabel("time (s since start of scenario)")
    plt.ylabel(ylabel)
    plt.legend()
    plt.tight_layout()
    plt.savefig(outfile, dpi=160)
    plt.close()
    print(f"Wrote {outfile}")

plot_timeseries(df_p95_gw,  "Gateway p95 latency (ms)",       os.path.join(OUT_DIR,"p95_gateway_latency_timeseries.png"), "ms")
plot_timeseries(df_avg_gw,  "Gateway avg latency (ms)",       os.path.join(OUT_DIR,"avg_gateway_latency_timeseries.png"), "ms")
plot_timeseries(df_rps_gw,  "Gateway throughput (req/s)",     os.path.join(OUT_DIR,"rps_gateway_timeseries.png"), "req/s")
plot_timeseries(df_p95_int, "Auth introspection p95 (ms)",     os.path.join(OUT_DIR,"p95_introspect_timeseries.png"), "ms")

# Misuse window: take, for each scenario, the first 401 time (or max time if none)
misuse_summary_rows = []
if not df_misuse.empty:
    for scen, g in df_misuse.groupby("scenario"):
        g = g.sort_values("elapsed_s")
        first_401 = g.loc[g["http_code"] == 401, "elapsed_s"]
        misuse_sec = float(first_401.iloc[0]) if not first_401.empty else float(g["elapsed_s"].max())
        misuse_summary_rows.append({"scenario": scen, "misuse_window_seconds": misuse_sec})
    df_misuse_summary = pd.DataFrame(misuse_summary_rows).sort_values("misuse_window_seconds", ascending=False)

    # Bar plot
    plt.figure()
    plt.bar(df_misuse_summary["scenario"], df_misuse_summary["misuse_window_seconds"])
    plt.title("Misuse window (seconds) per scenario\n(time until 401 for stolen token)")
    plt.ylabel("seconds")
    plt.xlabel("scenario")
    plt.tight_layout()
    plt.savefig(os.path.join(OUT_DIR,"misuse_window_bars.png"), dpi=160)
    plt.close()
    print(f"Wrote {os.path.join(OUT_DIR,'misuse_window_bars.png')}")
else:
    df_misuse_summary = pd.DataFrame(columns=["scenario","misuse_window_seconds"])
    print("No misuse data found; skipping misuse plot.")

# Summary stats per scenario (averages over time-series)
def summarize(df, metric_name):
    if df.empty:
        return pd.DataFrame(columns=["scenario", f"{metric_name}_mean", f"{metric_name}_median"])
    out = df.groupby("scenario")["value"].agg(["mean","median"]).reset_index()
    out = out.rename(columns={"mean": f"{metric_name}_mean", "median": f"{metric_name}_median"})
    return out

sum_p95_gw  = summarize(df_p95_gw,  "p95_gateway_ms")
sum_avg_gw  = summarize(df_avg_gw,  "avg_gateway_ms")
sum_rps_gw  = summarize(df_rps_gw,  "rps_gateway")
sum_p95_int = summarize(df_p95_int, "p95_introspect_ms")

# Merge all summaries
summary = None
for s in [sum_p95_gw, sum_avg_gw, sum_rps_gw, sum_p95_int]:
    summary = s if summary is None else pd.merge(summary, s, on="scenario", how="outer")

# Add misuse seconds
summary = pd.merge(summary, df_misuse_summary, on="scenario", how="outer")

# Reorder columns nicely
cols = ["scenario",
        "misuse_window_seconds",
        "p95_gateway_ms_mean","p95_gateway_ms_median",
        "avg_gateway_ms_mean","avg_gateway_ms_median",
        "rps_gateway_mean","rps_gateway_median",
        "p95_introspect_ms_mean","p95_introspect_ms_median"]
summary = summary.reindex(columns=[c for c in cols if c in summary.columns])

summary_path = os.path.join(OUT_DIR, "summary_stats.csv")
summary.to_csv(summary_path, index=False)
print(f"Wrote {summary_path}")

print("All done.")
