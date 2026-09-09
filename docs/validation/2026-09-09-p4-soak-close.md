# P4 soak close — 72-hour dormant-stack soak on Alfred

**Evaluated:** 2026-09-09 15:16 UTC · **Soak window:** `2026-09-06T16:15:37Z` → `2026-09-09T15:16:00Z` (71.0 h at evaluation; the 72.0 h mark is 16:15:37Z)
**Evaluator:** `/usr/local/lib/cascade-soak/soak-evaluate.py p4-soak.jsonl p4-baseline.json` on `alfred-brain`
**Verdict:** **PASS WITH EXCEPTION** — closed on Lloyd's instruction ("close P4") after review of the exception below.

## Raw evaluator output

```
samples 4262   first 2026-09-06T16:15:37Z   last 2026-09-09T15:16:00Z
complete_windows 1   longest_window_hours 70.99   required_hours 72.0
abort_count 2595   pass false
```

## Abort breakdown (independent re-computation from the same samples)

| Reason | Count | First seen |
|---|---:|---|
| `existing set changed` — Watchtower recreated `budget-tracker-prod-backend-1`, `budget-tracker-prod-frontend-1` | 1,432 | 2026-09-07T20:01Z |
| `existing set changed` — Watchtower recreated the two above plus `metabase`, `n8n` | 1,145 | 2026-09-08T20:02Z |
| `existing set changed` — a transient Cascade drill container (`--rm` backup/restore/rehearsal) present for 1–3 min | 18 | 2026-09-07T23:08Z |
| **Cascade container restarted / unhealthy / OOM / limits changed** | **0** | — |
| Cascade container count ≠ 2 | 0 | — |
| Available RAM < 1.5 GiB | 0 | — |
| Swap growth 5 consecutive samples | 0 | — |
| load15 > 4 | 0 | — |
| Free disk < 15 GiB | 0 | — |
| Docker inspect failed | 0 | — |

Every abort is the single reason "existing set changed". The soak's own subject — the two
`cascade-n8n` containers — never restarted, never went unhealthy, never OOMed, kept their
limits, and the host stayed within every resource threshold for the entire window.

## Why the host-immutability invariant failed

`watchtower-watchtower-1` runs with `WATCHTOWER_SCHEDULE=0 0 4 * * *` in `Asia/Manila`
(20:00 UTC) and `WATCHTOWER_CLEANUP=true`. Its log:

- 2026-09-08 04:00 PHT: "Found new letehaha/budget-tracker-be/fe:latest" → stopped and
  recreated Alfred Money's backend and frontend. `Session done Scanned=22 Updated=2`.
- 2026-09-09 04:00 PHT: found new `budget-tracker-*`, `metabase/metabase:latest`,
  `n8nio/n8n:latest` → recreated four containers. `Updated=4`.

The evaluator compares the *ids* of the 20 baseline containers. A recreated container has a
new id, so from the first Watchtower update every subsequent minute aborts. Nothing Cascade
did caused this; it is the shared host's own nightly behaviour on unpinned `:latest` images.

The 18 transient aborts are Cascade's sanctioned P4/P5 drills (encrypted backup, restore
proof, migration rehearsal), all `--rm`, all gone within three minutes, zero leftovers.

## Exception accepted

The purpose of the invariant was to detect the Cascade stack disturbing its neighbours. It
instead detected the neighbours' auto-updater. On that reading the soak achieved its purpose:
**the dormant stack ran 71 hours without a single Cascade-side or resource-side abort on a
shared host that itself churned twice.**

Two consequences for the record:

1. **Future soaks** must compare existing containers by compose project + service name and
   image *tag*, not by id, or explicitly exclude `com.centurylinklabs.watchtower`-managed
   containers. Otherwise no soak on this host can pass by construction.
2. **Not a Cascade issue, but Lloyd should know:** Watchtower auto-updates Alfred Money's
   production backend/frontend, the shared `deploy` n8n and Metabase nightly from `:latest`
   with no pin and no notification (`notify=no`). Two of the containers it tries to update fail
   every night (`parser-svc`, `obsidian-livesync-bridge`).

## What P4 gated

P4 gated P9 (provider activation). With this close, P9 is gated only on Lloyd's credential
actions listed in `docs/plans/2026-09-09-p9-provider-activation-packet.md`.
