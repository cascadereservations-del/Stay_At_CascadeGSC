#!/usr/bin/env python3
"""Evaluate a P4 soak log against the handoff abort conditions and completeness
rules. Usage: soak-evaluate.py <p4-soak.jsonl> <p4-baseline.json> [--hours 72]
Prints a JSON verdict. A missing interval (>90 s between samples) breaks the
continuous window; only the longest complete window counts toward the 72 hours."""
import json, sys

GIB = 1024 ** 3
MIN_RAM, MIN_DISK, MAX_LOAD15 = 1.5 * GIB, 15 * GIB, 3.0
MAX_GAP = 90

def main():
    log, base = sys.argv[1], sys.argv[2]
    hours = float(sys.argv[sys.argv.index("--hours") + 1]) if "--hours" in sys.argv else 72.0
    baseline = json.load(open(base))
    b_exist = {r["id"]: r for r in baseline["existing"]}
    b_casc = {r["name"]: r for r in baseline["cascade"]}
    samples = [json.loads(l) for l in open(log) if l.strip()]
    if not samples: print(json.dumps({"pass": False, "reason": "no samples"})); return 1
    aborts, low_ram, swap_grow, prev_swap_used = [], 0, 0, None
    windows, win_start, prev_epoch = [], samples[0]["epoch"], samples[0]["epoch"]
    for s in samples:
        t = s["ts"]
        if s["epoch"] - prev_epoch > MAX_GAP:
            windows.append((win_start, prev_epoch)); win_start = s["epoch"]
            aborts.append((t, f"gap {s['epoch']-prev_epoch}s"))
        prev_epoch = s["epoch"]
        if s["existing"] is None or s["cascade"] is None: aborts.append((t, "docker inspect failed")); continue
        low_ram = low_ram + 1 if s["mem_available"] < MIN_RAM else 0
        if low_ram >= 3: aborts.append((t, "available RAM < 1.5 GiB for 3 samples"))
        used = s["swap_total"] - s["swap_free"]
        swap_grow = swap_grow + 1 if prev_swap_used is not None and used > prev_swap_used else 0
        prev_swap_used = used
        if swap_grow >= 5: aborts.append((t, "swap used grew 5 consecutive samples"))
        if s["load15"] > MAX_LOAD15: aborts.append((t, f"load15 {s['load15']}"))
        if min(s["disk_free_root"], s["disk_free_opt"]) < MIN_DISK: aborts.append((t, "free disk < 15 GiB"))
        seen = {r["id"] for r in s["existing"]}
        if seen != set(b_exist): aborts.append((t, "existing container set changed"))
        for r in s["existing"]:
            b = b_exist.get(r["id"])
            if not b: continue
            if r["started"] != b["started"] or r["restarts"] != 0 or r["oom"] or r["health"] == "unhealthy" or r["status"] != "running":
                aborts.append((t, f"existing {r['name']} changed/restarted/unhealthy/oom"))
        for r in s["cascade"]:
            b = b_casc.get(r["name"])
            if not b or r["started"] != b["started"] or r["restarts"] != 0 or r["oom"] or r["health"] != "healthy" or r["mem"] != b["mem"] or r["cpu"] != b["cpu"]:
                aborts.append((t, f"cascade {r['name']} restarted/unhealthy/oom/limits changed"))
        if len(s["cascade"]) != 2: aborts.append((t, "cascade container count != 2"))
        a = s["aggregates"]
        if not isinstance(a, dict) or a.get("workflows") != 13 or a.get("active") != 0 or a.get("credentials") != 0:
            aborts.append((t, f"aggregates {a}"))
        if s["healthz_cascade"] != 200 or s["healthz_existing"] != 200: aborts.append((t, "healthz not 200"))
        if s["listeners_5679"].strip() != "127.0.0.1:5679": aborts.append((t, f"5679 listener {s['listeners_5679']!r}"))
    windows.append((win_start, prev_epoch))
    longest = max(windows, key=lambda w: w[1] - w[0])
    span_h = (longest[1] - longest[0]) / 3600
    verdict = {"samples": len(samples), "first": samples[0]["ts"], "last": samples[-1]["ts"],
               "complete_windows": len(windows), "longest_window_hours": round(span_h, 2),
               "required_hours": hours, "abort_count": len(aborts), "first_aborts": aborts[:10],
               "pass": span_h >= hours and not aborts}
    print(json.dumps(verdict, indent=1)); return 0 if verdict["pass"] else 1

if __name__ == "__main__": sys.exit(main())
