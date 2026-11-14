#!/usr/bin/env python3
"""Reads isolate-bench JSON result lines on stdin and prints markdown table
rows. Non-JSON and seed lines pass through as raw text so the log keeps
everything."""
import json
import sys

for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        r = json.loads(raw)
    except json.JSONDecodeError:
        print(raw)
        continue
    if r.get("role") == "seed":
        print(f"seed {r['size']}: {r['seedMs']} ms")
        continue
    engine = str(r.get("engine", "")).replace("cocoon-", "")
    extra = ""
    if "p50Us" in r:
        extra = f" (p50 {r['p50Us']}us p95 {r['p95Us']}us)"
    print(
        f"| {r['op']} | {engine} | {r['wallMs']} | {r['longestStallMs']} | "
        f"{r['totalStallMs']} | {r['stallsOver8ms']} | "
        f"{int(r['peakRssBytes']) // (1024 * 1024)} |{extra}"
    )
