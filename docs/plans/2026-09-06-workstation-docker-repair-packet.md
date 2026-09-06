# Workstation Docker repair packet

Status: diagnosis complete; repair not executed. This is a P4 prerequisite and requires a separate owner decision because it installs workstation software.

## Observed state

`C:\Program Files\Docker\Docker\Docker Desktop.exe` is absent while the orphaned Docker CLI remains at `C:\Program Files\Docker\Docker\resources\bin\docker.exe`. No Docker Desktop uninstall registration or `com.docker.service` record was returned by the checked Windows inventory. The CLI therefore cannot supply a local Compose plugin or local engine. This matches the post-P1 failure recorded in the handoff.

Alfred is unaffected: Docker Engine 29.5.3 and Compose 5.1.4 are healthy there. Alfred does not have PowerShell, standalone `docker-compose`, or `age`, so the existing Windows-oriented `backup.ps1` cannot simply run on Alfred.

## Proposed repair

Download the current signed Docker Desktop installer from Docker's official distribution, record its version and SHA-256, verify its Authenticode signature names Docker Inc., then perform the normal Windows installation without enabling Kubernetes. Preserve existing WSL distributions and local Docker data directories; do not manually delete them. Reboot only if the signed installer explicitly requires it.

After installation, start Docker Desktop and verify the engine, Compose plugin, WSL backend, existing local containers/volumes and the exact P1 images. Run the focused infrastructure and recovery-contract tests, render the digest-pinned Compose candidate, and repeat the disposable 13-workflow inactive round trip. Do not connect to production or restore real data during the repair check.

If installation fails, retain installer logs and stop. Do not delete WSL distributions, Docker data, registry entries or user configuration as an automatic fallback. A clean-data reset is destructive and would need a separate reviewed decision.

## P4 boundary

Docker repair alone does not authorize a new-stack backup or restore. After P3 starts, P4 still needs an approved encrypted capture, off-host copy and disposable restore using the dedicated Cascade recovery identity, followed by the full 72-hour dormant soak.
