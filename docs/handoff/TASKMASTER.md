# Shared Task Master workflow

The repository-owned task ledger is `.taskmaster/tasks/tasks.json`, tag `master`. Commit it with implementation and validation evidence so collaborators receive the same tasks through Git. The input is `.taskmaster/docs/remaining-work-prd.md`; plans and dated validation evidence remain authoritative for business scope and release gates.

## Open an existing checkout

Install Task Master 0.43.1 (`npm install -g task-master-ai@0.43.1`) and an authenticated Codex CLI under your own account. Basic list/show/status commands do not need AI generation. Do not share credentials. This repository uses the Codex CLI provider; do not commit API keys or environment secrets.

From the repository root:

```sh
task-master list --tag master
task-master next --tag master
task-master show 2 --tag master
task-master tags use master
```

On Windows, use `task-master.cmd` if PowerShell blocks the script shim. If npm's global directory is missing from PATH, open a new terminal after installation or invoke the shim from the directory printed by `npm config get prefix`.

Do not initialize over an existing ledger or re-import the full PRD. If the ledger is missing, first verify the branch and fetch/pull the commit that introduced it.

## Claim, work, and finish

1. Pull the latest shared branch with a clean working tree. Read the selected task and its dependencies before acting.
2. Coordinate ownership with other developers. Set the selected task in progress, then commit/push the claim to the agreed collaboration branch so others see it. Git is the sharing mechanism, not a real-time lock.
3. Use Task Master commands for task changes. Never hand-edit `tasks.json`. Use `task-master <command> --help` for installed-version options. AI-backed commands can transmit their input; use only approved, minimized project material.
4. Preserve production approval gates regardless of task status. Read AGENTS.md and applicable runbooks. Use synthetic fixtures and attach dated validation evidence.
5. Mark done only when acceptance criteria and checks pass. Commit ledger status alongside source and evidence, then share through the repository's reviewed branch/PR workflow.

```sh
task-master tags use master
task-master set-status --id 2 --status in-progress
task-master show 2 --tag master
# After implementation and validation:
task-master set-status --id 2 --status done
task-master validate-dependencies --tag master
```

Task numbers above are examples; inspect the actual ledger before changing status. Deferred production gates stay deferred until the owner approves the specific action and prerequisites are proven.

## Concurrent changes and portability

Use one agreed Git branch and the Task Master `master` tag as the shared ledger. Run `task-master tags use master` before commands such as `set-status` that do not accept `--tag`. A local commit becomes visible to teammates only after it is pushed and they fetch/pull it. Repository write access or an accepted PR is required to share updates; this setup grants neither hosting permissions nor production authority.

Avoid simultaneous ledger edits. If a merge conflicts, retain both versions for reference, choose the agreed current ledger, then replay the other developer's changes using Task Master commands and validate dependencies. Do not resolve JSON conflicts by silently discarding task updates or by hand-editing tasks.

Tracked: the task ledger, shared sanitized model configuration, approved PRD, AGENTS.md and this guide. Local-only: `.taskmaster/state.json`, cache/reports, logs, credentials and environment files. Use explicit `--tag master` to avoid local tag-selection differences.

The configuration is not a credential bundle. Each collaborator supplies their own supported Codex login. A model/provider change must be coordinated and committed if it changes the shared configuration.

## Codex compatibility

Task Master 0.43.1 bundles an obsolete Codex client. The shared configuration selects scripts/taskmaster-codex.mjs, which finds each contributor's globally installed @openai/codex through npm and forwards arguments without a shell. It translates the old experimental JSON flag to the current JSON flag. Verified with Codex CLI 0.150.1. Install that version or a compatible newer version globally and authenticate separately. No user-specific absolute path is stored. Run all commands from the repository root.

The shared model is gpt-5.6-sol with medium reasoning. Automatic codebase analysis is disabled; the approved import source is explicit. If your account cannot use this model, coordinate a supported shared configuration change before AI-backed commands. Ordinary ledger commands remain local.

The launcher also adapts a temporary copy of Task Master's output schema to strict structured output (closed objects and required declared fields). Open-ended metadata is reduced to an empty object; named task fields remain declared. Task Master validates and writes the generated ledger. The adapter never edits tasks.json or the installed Task Master package, and removes its temporary schema on normal completion.
