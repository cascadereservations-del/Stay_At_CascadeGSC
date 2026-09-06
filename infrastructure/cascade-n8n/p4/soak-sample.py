#!/usr/bin/env python3
"""P4 dormant soak sampler. Runs on Alfred as root. Appends one JSON line per
call to the soak log (default /var/lib/cascade-soak/p4-soak.jsonl). With
--baseline it writes the existing-container fingerprint baseline instead.
Captures only aggregates and identities; never environment values or rows."""
import json, os, subprocess, sys, time, urllib.request

LOG = os.environ.get("CASCADE_SOAK_LOG", "/var/lib/cascade-soak/p4-soak.jsonl")
BASELINE = os.environ.get("CASCADE_SOAK_BASELINE", "/var/lib/cascade-soak/p4-baseline.json")
CASCADE = {"/cascade-n8n-app", "/cascade-n8n-postgres"}
SQL = ("select json_build_object('workflows',(select count(*) from workflow_entity),"
       "'active',(select count(*) from workflow_entity where active),"
       "'credentials',(select count(*) from credentials_entity));")

def run(args, inp=None, timeout=40):
    p = subprocess.run(args, input=inp, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout.strip()

def meminfo():
    d = {}
    for line in open("/proc/meminfo"):
        k, v = line.split(":", 1); d[k] = int(v.split()[0]) * 1024
    return d

def disk(path):
    s = os.statvfs(path); return s.f_bavail * s.f_frsize

def health(url):
    try:
        with urllib.request.urlopen(url, timeout=5) as r: return r.status
    except Exception as e:
        return f"error:{type(e).__name__}"

def listeners():
    rc, out = run(["ss", "-ltnH"])
    if rc: return f"error:{rc}"
    cols = [l.split()[3] for l in out.splitlines() if len(l.split()) > 3]
    return " ".join(sorted(c for c in cols if c.endswith(":5679")))

def containers():
    rc, ids = run(["docker", "ps", "-q"])
    if rc or not ids: return None
    rc, out = run(["docker", "inspect"] + ids.split())
    if rc: return None
    rows = []
    for c in json.loads(out):
        s, h = c["State"], c["HostConfig"]
        rows.append({"id": c["Id"], "name": c["Name"], "started": s["StartedAt"], "restarts": c["RestartCount"],
                     "oom": s["OOMKilled"], "health": s.get("Health", {}).get("Status", "n/a"), "status": s["Status"],
                     "mem": h["Memory"], "cpu": h["NanoCpus"]})
    return sorted(rows, key=lambda r: r["name"])

def sample():
    m = meminfo(); la = os.getloadavg(); rows = containers()
    rc, agg = run(["docker", "exec", "-i", "cascade-n8n-postgres", "sh", "-c",
                   'psql -At -U "$POSTGRES_USER" -d "$POSTGRES_DB"'], inp=SQL + "\n")
    try: agg = json.loads(agg) if rc == 0 else {"error": rc}
    except Exception: agg = {"error": "parse"}
    return {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "epoch": int(time.time()),
        "mem_available": m.get("MemAvailable"), "swap_total": m.get("SwapTotal"), "swap_free": m.get("SwapFree"),
        "disk_free_root": disk("/"), "disk_free_opt": disk("/opt"),
        "load1": la[0], "load5": la[1], "load15": la[2],
        "running": None if rows is None else len(rows),
        "cascade": None if rows is None else [r for r in rows if r["name"] in CASCADE],
        "existing": None if rows is None else [{k: r[k] for k in ("id", "name", "started", "restarts", "oom", "health", "status")} for r in rows if r["name"] not in CASCADE],
        "aggregates": agg,
        "healthz_cascade": health("http://127.0.0.1:5679/healthz"),
        "healthz_existing": health("http://127.0.0.1:5678/healthz"),
        "listeners_5679": listeners(),
    }

if __name__ == "__main__":
    os.makedirs(os.path.dirname(LOG), mode=0o700, exist_ok=True)
    if "--baseline" in sys.argv:
        rows = containers()
        base = {"captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "existing": [{k: r[k] for k in ("id", "name", "started", "mem", "cpu")} for r in rows if r["name"] not in CASCADE],
                "cascade": [r for r in rows if r["name"] in CASCADE]}
        with open(BASELINE, "w") as f: json.dump(base, f, indent=1)
        os.chmod(BASELINE, 0o600)
        print(f"baseline written: existing={len(base['existing'])} cascade={len(base['cascade'])}")
    else:
        line = json.dumps(sample(), separators=(",", ":"))
        with open(LOG, "a") as f: f.write(line + "\n")
        os.chmod(LOG, 0o600)
        if "--print" in sys.argv: print(line)
