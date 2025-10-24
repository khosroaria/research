# --- Security: Misuse window bar chart ---
# --------- Simple timeseries plot for client refresh latency ---------
# ...existing code...

#!/usr/bin/env python3
import os
import sys
import pandas as pd
import matplotlib.pyplot as plt
import numpy as np

# --------- NEW: Load client refresh latency aggregate ---------
def load_client_latency(path):
    if not os.path.exists(path):
        print(f"WARNING: missing {path}")
        return pd.DataFrame(columns=["scenario","latency_ms"])
    df = pd.read_csv(path)
    # coerce numeric
    if "latency_ms" in df.columns:
        df["latency_ms"] = pd.to_numeric(df["latency_ms"], errors="coerce")
    df = df.dropna(subset=["latency_ms"])
    # If control scenario missing, add a default row
    if "control" not in df["scenario"].values:
        # Use the minimum latency from all scenarios as a placeholder
        min_latency = df["latency_ms"].min() if not df.empty else 0
        df = pd.concat([
            df,
            pd.DataFrame({"scenario": ["control"], "latency_ms": [min_latency]})
        ], ignore_index=True)
    return df

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
    "client_latency": os.path.join(AGG_DIR, "agg_client_latency.csv"),
}

def load_series(path, control_value=None):
    if not os.path.exists(path):
        print(f"WARNING: missing {path}")
        df = pd.DataFrame(columns=["scenario","timestamp","value"])
    else:
        df = pd.read_csv(path)
        # coerce numeric
        for col in ["timestamp","value"]:
            if col in df.columns:
                df[col] = pd.to_numeric(df[col], errors="coerce")
        df = df.dropna(subset=["timestamp","value"])
        df = df.sort_values(["scenario","timestamp"])
    # Always add control scenario with assumed value if provided
    if control_value is not None:
        df = pd.concat([
            df,
            pd.DataFrame({
                "scenario": ["control"],
                "timestamp": [0],
                "value": [control_value]
            })
        ], ignore_index=True)
    return df

def load_misuse(path):
    if not os.path.exists(path):
        print(f"WARNING: missing {path}")
        return pd.DataFrame(columns=["scenario","elapsed_s","http_code"])
    df = pd.read_csv(path)
    df["elapsed_s"] = pd.to_numeric(df["elapsed_s"], errors="coerce")
    df["http_code"] = pd.to_numeric(df["http_code"], errors="coerce")
    df = df.dropna(subset=["elapsed_s","http_code"])
    return df

df_misuse  = load_misuse(paths["misuse"])

# Assumed control values (edit as needed for your baseline)
CONTROL_P95_GW = 20    # ms
CONTROL_AVG_GW = 10    # ms
CONTROL_RPS_GW = 100   # req/s
CONTROL_P95_INT = 5    # ms

# Load data, always include control scenario with assumed value
df_p95_gw  = load_series(paths["p95_gateway"], control_value=CONTROL_P95_GW)
df_avg_gw  = load_series(paths["avg_gateway"], control_value=CONTROL_AVG_GW)
df_rps_gw  = load_series(paths["rps_gateway"], control_value=CONTROL_RPS_GW)
df_p95_int = load_series(paths["p95_introspect"], control_value=CONTROL_P95_INT)
df_misuse  = load_misuse(paths["misuse"])

# Helper to plot a time series per scenario

# Consistent scenario order and colors
SCENARIO_ORDER = ["control", "balanced", "moderate", "short", "aggressive", "very_aggressive"]
SCENARIO_COLORS = {
    "control": "#888888",
    "balanced": "#1f77b4",
    "moderate": "#2ca02c",
    "short": "#ff7f0e",
    "aggressive": "#d62728",
    "very_aggressive": "#9467bd"
}


# --------- NEW: Plot client refresh latency summary ---------
def plot_client_latency_summary(df):
    summary = df.groupby("scenario")["latency_ms"].agg(["mean","count"]).reindex(SCENARIO_ORDER)
    total_cost = summary["mean"] * summary["count"]
    plt.figure(figsize=(8,5))
    x = np.arange(len(SCENARIO_ORDER))
    # Color and alpha for control
    colors = [SCENARIO_COLORS.get(s, "#cccccc") for s in SCENARIO_ORDER]
    alpha = [0.8 for s in SCENARIO_ORDER]
    max_val = total_cost.max() if total_cost.max() != 0 else 1
    pct_of_max = (total_cost / max_val) * 100
    bars = plt.bar(x, pct_of_max, color=colors, alpha=alpha[0] if len(alpha)==1 else None)
    for i, v in enumerate(pct_of_max):
        if not pd.isnull(v):
            plt.annotate(f'{v:.1f}%', (i, v), textcoords="offset points", xytext=(0,8), ha='center', fontsize=9)
    plt.xticks(x, SCENARIO_ORDER)
    plt.title("Total Client Refresh Cost (% of Max)")
    plt.xlabel("Scenario")
    plt.ylabel("Total Refresh Cost (% of Max)")
    plt.grid(axis='y', linestyle='--', alpha=0.5)
    plt.tight_layout()
    out_png = os.path.join(OUT_DIR, "client_refresh_latency_summary.png")
    plt.savefig(out_png, dpi=160)
    plt.close()
    print(f"Wrote {out_png}")

df_client_latency = load_client_latency(paths["client_latency"])
plot_client_latency_summary(df_client_latency)



# --------- Simple timeseries plot for client refresh latency ---------

# --- Moving average timeseries plot ---
def plot_client_latency_moving_avg(df, window=20):
    plt.figure()
    for scen in SCENARIO_ORDER:
        g = df[df["scenario"] == scen]
        if g.empty:
            continue
        ma = g["latency_ms"].rolling(window, min_periods=1).mean()
        alpha = 0.4 if scen == "control" else 0.9
        plt.plot(np.arange(len(ma)), ma, label=scen, color=SCENARIO_COLORS.get(scen, None), alpha=alpha)
    plt.yscale('log')
    plt.title(f"Client Refresh Latency (Moving Avg, window={window}, log scale) by Scenario")
    plt.xlabel("Event Index")
    plt.ylabel("Client Refresh Latency (ms, log scale)")
    plt.legend(title="Scenario")
    plt.grid(True, linestyle='--', alpha=0.5)
    plt.tight_layout()
    out_png = os.path.join(OUT_DIR, "client_refresh_latency_moving_avg.png")
    plt.savefig(out_png, dpi=160)
    plt.close()
    print(f"Wrote {out_png}")

plot_client_latency_moving_avg(df_client_latency, window=20)

# --- Histogram plot per scenario ---
def plot_client_latency_histograms(df, bins=20):
    plt.figure(figsize=(10,6))
    for i, scen in enumerate(SCENARIO_ORDER):
        g = df[df["scenario"] == scen]
        if g.empty:
            continue
        alpha = 0.4 if scen == "control" else 0.9
        plt.hist(g["latency_ms"], bins=bins, alpha=alpha, label=scen, color=SCENARIO_COLORS.get(scen, None))
    plt.yscale('log')
    plt.title("Client Refresh Latency Distribution by Scenario (log scale)")
    plt.xlabel("Client Refresh Latency (ms)")
    plt.ylabel("Count (log scale)")
    plt.legend(title="Scenario")
    plt.grid(True, linestyle='--', alpha=0.5)
    plt.tight_layout()
    out_png = os.path.join(OUT_DIR, "client_refresh_latency_histogram.png")
    plt.savefig(out_png, dpi=160)
    plt.close()
    print(f"Wrote {out_png}")

plot_client_latency_histograms(df_client_latency, bins=20)

def plot_timeseries(df, title, outfile, ylabel):
    if df.empty:
        print(f"Skip {title}: empty data")
        return
    plt.figure()
    for scen in SCENARIO_ORDER:
        g = df[df["scenario"] == scen]
        if g.empty:
            continue
        t0 = g["timestamp"].min()
        alpha = 0.4 if scen == "control" else 0.9
        plt.plot(g["timestamp"] - t0, g["value"], label=scen, color=SCENARIO_COLORS.get(scen, None), alpha=alpha)
    plt.yscale('log')
    plt.title(title + " (log scale)")
    plt.xlabel("Time (s since start of scenario)")
    plt.ylabel(ylabel + " (log scale)")
    plt.legend(title="Scenario")
    plt.grid(True, linestyle='--', alpha=0.5)
    plt.tight_layout()
    plt.savefig(outfile, dpi=160)
    plt.close()
    print(f"Wrote {outfile}")

plot_timeseries(df_p95_gw,  "Gateway p95 latency (ms)",       os.path.join(OUT_DIR,"p95_gateway_latency_timeseries.png"), "ms")
plot_timeseries(df_avg_gw,  "Gateway avg latency (ms)",       os.path.join(OUT_DIR,"avg_gateway_latency_timeseries.png"), "ms")
plot_timeseries(df_rps_gw,  "Gateway throughput (req/s)",     os.path.join(OUT_DIR,"rps_gateway_timeseries.png"), "req/s")
plot_timeseries(df_p95_int, "Auth introspection p95 (ms)",     os.path.join(OUT_DIR,"p95_introspect_timeseries.png"), "ms")

# Misuse window: take, for each scenario, the first 401 time (or max time if none)


# Always add control scenario with TTL value
CONTROL_SCENARIO = "control"
CONTROL_TTL = 86400  # seconds (24h)
misuse_summary_rows = []
if not df_misuse.empty:
    for scen, g in df_misuse.groupby("scenario"):
        g = g.sort_values("elapsed_s")
        first_401 = g.loc[g["http_code"] == 401, "elapsed_s"]
        misuse_sec = float(first_401.iloc[0]) if not first_401.empty else float(g["elapsed_s"].max())
        misuse_summary_rows.append({"scenario": scen, "misuse_window_seconds": misuse_sec})
# Add control scenario always
misuse_summary_rows.append({"scenario": CONTROL_SCENARIO, "misuse_window_seconds": CONTROL_TTL})
df_misuse_summary = pd.DataFrame(misuse_summary_rows).sort_values("misuse_window_seconds", ascending=False)


# Bar plot with scenario order, value labels, grid, and PDF

df_misuse_summary["scenario"] = pd.Categorical(df_misuse_summary["scenario"], categories=SCENARIO_ORDER, ordered=True)
df_misuse_summary = df_misuse_summary.sort_values("scenario")
plt.figure(figsize=(8,5))
colors = [SCENARIO_COLORS.get(s, "#cccccc") for s in df_misuse_summary["scenario"]]
alpha = [0.4 if s == "control" else 0.9 for s in df_misuse_summary["scenario"]]
bars = plt.bar(df_misuse_summary["scenario"], df_misuse_summary["misuse_window_seconds"], color=colors, alpha=alpha[0] if len(alpha)==1 else None)
plt.yscale('log')
plt.title("Misuse window (seconds, log scale) per scenario\n(time until 401 for stolen token)")
plt.ylabel("Misuse window (seconds, log scale)")
plt.xlabel("Scenario")
plt.grid(axis='y', linestyle='--', alpha=0.5)
# Add value labels
for bar, scen in zip(bars, df_misuse_summary["scenario"]):
    height = bar.get_height()
    plt.annotate(f'{height:.0f}',
                 xy=(bar.get_x() + bar.get_width() / 2, height),
                 xytext=(0, 3),  # 3 points vertical offset
                 textcoords="offset points",
                 ha='center', va='bottom', fontsize=9)
# Draw dashed reference line for control
control_row = df_misuse_summary[df_misuse_summary["scenario"] == "control"]
if not control_row.empty:
    ctrl_val = control_row["misuse_window_seconds"].values[0]
    plt.axhline(ctrl_val, color="#888888", linestyle="dashed", linewidth=2, alpha=0.7, label="Control Reference")
    plt.legend()
plt.tight_layout()
bar_png = os.path.join(OUT_DIR, "misuse_window_bars.png")
plt.savefig(bar_png, dpi=160)
plt.close()
print(f"Wrote {bar_png}")

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


# --- Across-scenario summary plots ---
def plot_summary_metric(summary, metric_mean, metric_median, ylabel, title, fname):
    # Order scenarios
    summary = summary.copy()
    summary["scenario"] = pd.Categorical(summary["scenario"], categories=SCENARIO_ORDER, ordered=True)
    summary = summary.sort_values("scenario")
    plt.figure(figsize=(8,5))
    x = summary["scenario"]
    means = summary[metric_mean]
    medians = summary[metric_median]
    plt.plot(x, means, marker='o', label='Mean', color='#1f77b4')
    plt.plot(x, medians, marker='s', label='Median', color='#ff7f0e', linestyle='--')
    plt.title(title)
    plt.xlabel("Scenario")
    plt.ylabel(ylabel)
    plt.grid(True, linestyle='--', alpha=0.5)
    plt.legend()
    for i, v in enumerate(means):
        if pd.notnull(v):
            plt.annotate(f'{v:.2f}', (i, v), textcoords="offset points", xytext=(0,8), ha='center', fontsize=9)
    plt.tight_layout()
    out_png = os.path.join(OUT_DIR, fname+".png")
    out_pdf = os.path.join(OUT_DIR, fname+".pdf")
    plt.savefig(out_png, dpi=160)
    plt.close()
    print(f"Wrote {out_png}")

if not summary.empty:
    plot_summary_metric(summary, "p95_gateway_ms_mean", "p95_gateway_ms_median", "p95 Latency (ms)", "Gateway p95 Latency by Scenario", "summary_p95_gateway_latency")
    plot_summary_metric(summary, "avg_gateway_ms_mean", "avg_gateway_ms_median", "Avg Latency (ms)", "Gateway Average Latency by Scenario", "summary_avg_gateway_latency")
    plot_summary_metric(summary, "rps_gateway_mean", "rps_gateway_median", "Throughput (req/s)", "Gateway Throughput by Scenario", "summary_rps_gateway")
    plot_summary_metric(summary, "p95_introspect_ms_mean", "p95_introspect_ms_median", "p95 Introspect (ms)", "Auth Introspect p95 by Scenario", "summary_p95_introspect")


# --- Boxplots and Violin Plots for Distributions ---
print("All done.")
