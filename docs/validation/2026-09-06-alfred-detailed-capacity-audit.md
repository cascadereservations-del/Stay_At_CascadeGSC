# Alfred detailed capacity audit — 2026-09-06

Status: read-only audit complete. Conditional same-host feasibility established. No Portainer, Docker, VPS, swap, container, stack, volume, network, workflow, credential, provider, DNS, or production change was made.

This audit supersedes the conservative host-placement conclusion in `2026-09-06-portainer-capacity-feasibility.md`. That earlier review correctly identified shared-host risk but lacked current Docker statistics, resource limits, restart/OOM state, and kernel history.

## Host observations

| Check | Observation |
| --- | --- |
| Host uptime | 87 days |
| CPU | 4 cores; repeated load averages remained below 0.3 |
| Memory | 7,751 MiB total; 3,196–3,209 MiB available across repeated samples |
| Swap | 0 MiB |
| Disk | 75 GB total; 36 GB available; 51% used |
| Docker images | 31.45 GB total; 2.835 GB reclaimable |
| Running containers | 19 |
| Current Docker health | 9 healthy; 10 without health checks; 0 unhealthy |
| Current OOM/restart evidence | No running container reported OOMKilled or a restart; no Docker OOM event or kernel OOM entry was found in the checked history |

Portainer's dashboard had displayed five unhealthy containers, but the live Docker health filter returned none. The dashboard figure was stale or aggregated incorrectly and is not used as evidence.

The four stopped AppFlowy containers with exit code 137 all report `OOMKilled=false`, zero restarts, and a common shutdown window. Exit 137 therefore does not establish host memory exhaustion in this case.

## Stable usage samples

Three samples produced stable host memory and low CPU load. Representative container memory was:

| Container | Observed memory | Limit |
| --- | ---: | ---: |
| Alfred n8n | about 455 MiB | none |
| Metabase | about 1.459 GiB | 1.5 GiB |
| OmniRoute | about 810 MiB | none |
| Budget Tracker backend | about 437 MiB | none |
| Parser service | about 186 MiB | 2 GiB |

Metabase remains close to its own 1.5 GiB cgroup limit, although it showed no restart or OOM kill and its CPU settled near 1% in the repeated samples. Treat a Metabase restart/OOM as an abort signal during any Cascade trial.

Ollama has no active model. Its only stored model is the 274 MB `nomic-embed-text` embedding model. It is still unbounded, so an unexpected future model installation or load is a capacity-change trigger.

## Conclusion

A second Docker daemon is unnecessary and would add complexity. Portainer can deploy a separate `cascade-n8n` Compose stack on Alfred's existing Docker Engine while retaining distinct containers, networks, volumes, secrets, database, hostname, and resource limits.

The same-host option is feasible for the current one-property Cascade automation workload because Docker memory limits are ceilings rather than pre-allocated reservations. Based on the existing n8n and PostgreSQL services, the new stack will likely use roughly 0.6–0.9 GiB at idle/light load. The reviewed Compose ceiling is 2.25 GiB. At the measured host state, expected use leaves roughly 2.3–2.6 GiB available; simultaneous use at both Cascade ceilings would leave only about 0.9 GiB and must be treated as an abort condition.

## Mandatory same-host gates

1. Prove an encrypted Alfred backup and disposable restore before changing the host.
2. Add at least 2 GiB swap through a separately approved maintenance action.
3. Keep the existing Compose CPU and memory ceilings, loopback binding, execution timeout, concurrency limit, and log rotation; reject an unbounded render.
4. Import the 13 workflows inactive and omit real provider credentials during the initial soak.
5. Observe at least 72 hours with the dormant stack. Stop only `cascade-n8n` if host available memory stays below 1.5 GiB, swap use grows continuously, load exceeds 3 for 15 minutes, Metabase or another existing service restarts/OOMs, or disk free falls below 15 GB.
6. Re-run the audit before each activation batch. Activation and provider setup remain separately approved actions after Module A closes.
7. Move Cascade to a separate VPS if any abort threshold is reached, workload expands beyond the current one-property scope, Ollama gains a larger model, or independent maintenance/recovery becomes operationally necessary.

This conclusion authorizes local source planning only. It does not authorize adding swap, creating the stack, importing workflows, configuring credentials/providers, or activating production behavior.
