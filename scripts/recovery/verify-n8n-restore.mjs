import { randomBytes } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { compareWorkflowSets, inventoryWorkflowFiles } from './recovery-contract.mjs';

const IMAGE = 'n8nio/n8n:2.34.6';
const VOLUME_PATTERN = /^cascade-n8n-recovery-[a-z0-9]{8,32}$/;
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith('--')) throw new Error(`Unexpected argument: ${argument}.`);
    const key = argument.slice(2);
    const value = argv[index + 1];
    if (!value || value.startsWith('--')) throw new Error(`Missing value for ${argument}.`);
    result[key] = value;
    index += 1;
  }
  return result;
}

function assertDisposableVolumeName(name) {
  if (!VOLUME_PATTERN.test(name)) throw new Error(`Unsafe disposable n8n volume: ${name || '<empty>'}.`);
  return name;
}

function runDocker(args, label, { allowFailure = false } = {}) {
  const result = spawnSync('docker', args, { cwd: repoRoot, encoding: 'utf8', windowsHide: true });
  if (!allowFailure && (result.error || result.status !== 0)) {
    const detail = [result.error?.message, result.stdout, result.stderr].filter(Boolean).join('\n').trim();
    throw new Error(`${label} failed${detail ? `: ${detail}` : '.'}`);
  }
  return result;
}

function dockerMount(hostPath, containerPath, readOnly = false) {
  return `${path.resolve(hostPath)}:${containerPath}${readOnly ? ':ro' : ''}`;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const volumeName = assertDisposableVolumeName(args['volume-name'] ?? `cascade-n8n-recovery-${randomBytes(6).toString('hex')}`);
  const sourceDirectory = path.resolve(args.source ?? path.join(repoRoot, 'automation', 'n8n', 'workflows'));
  if (!existsSync(sourceDirectory) || !statSync(sourceDirectory).isDirectory()) {
    throw new Error(`Workflow source directory does not exist: ${sourceDirectory}.`);
  }
  const source = await inventoryWorkflowFiles(sourceDirectory);
  const tempRoot = mkdtempSync(path.join(tmpdir(), 'cascade-n8n-recovery-'));
  const exportDirectory = path.join(tempRoot, 'exported');
  mkdirSync(exportDirectory, { recursive: true });
  const importContainer = `${volumeName}-import`;
  const exportContainer = `${volumeName}-export`;
  let volumeCreated = false;

  try {
    runDocker(['image', 'inspect', IMAGE], 'Pinned n8n image inspection');
    runDocker(['volume', 'create', volumeName], 'Disposable n8n volume creation');
    volumeCreated = true;

    const environment = [
      '-e', 'N8N_ENCRYPTION_KEY=cascade-disposable-recovery-proof-only',
      '-e', 'N8N_DIAGNOSTICS_ENABLED=false',
      '-e', 'N8N_VERSION_NOTIFICATIONS_ENABLED=false',
      '-e', 'N8N_TEMPLATES_ENABLED=false',
    ];
    runDocker([
      'run', '--rm', '--name', importContainer,
      ...environment,
      '-v', `${volumeName}:/home/node/.n8n`,
      '-v', dockerMount(sourceDirectory, '/input', true),
      IMAGE, 'import:workflow', '--separate', '--input=/input', '--activeState=false',
    ], 'Disposable n8n workflow import');
    runDocker([
      'run', '--rm', '--name', exportContainer,
      ...environment,
      '-v', `${volumeName}:/home/node/.n8n`,
      '-v', dockerMount(exportDirectory, '/output'),
      IMAGE, 'export:workflow', '--backup', '--output=/output',
    ], 'Disposable n8n workflow export');

    const restored = await inventoryWorkflowFiles(exportDirectory);
    const comparison = compareWorkflowSets(source, restored);
    const digest = runDocker(['image', 'inspect', IMAGE, '--format', '{{index .RepoDigests 0}}'], 'Pinned n8n image digest')
      .stdout.trim();
    const evidence = {
      ok: true,
      checked_at: new Date().toISOString(),
      image: IMAGE,
      image_digest: digest,
      imported_workflows: comparison.count,
      exported_workflows: comparison.count,
      all_inactive: restored.every(workflow => workflow.active === false),
      semantic_sha256: comparison.semantic_sha256,
      workflow_names: comparison.names,
      persistent_container_started: false,
    };
    if (args.output) {
      const output = path.resolve(args.output);
      mkdirSync(path.dirname(output), { recursive: true });
      writeFileSync(output, `${JSON.stringify(evidence, null, 2)}\n`, 'utf8');
    }
    process.stdout.write(`${JSON.stringify(evidence)}\n`);
  } finally {
    assertDisposableVolumeName(volumeName);
    for (const container of [importContainer, exportContainer]) {
      runDocker(['rm', '-f', container], `Cleanup ${container}`, { allowFailure: true });
    }
    if (volumeCreated) runDocker(['volume', 'rm', volumeName], 'Disposable n8n volume cleanup');
    const resolvedTemp = path.resolve(tempRoot);
    const resolvedSystemTemp = path.resolve(tmpdir());
    if (!resolvedTemp.startsWith(`${resolvedSystemTemp}${path.sep}`) || !path.basename(resolvedTemp).startsWith('cascade-n8n-recovery-')) {
      throw new Error(`Unsafe disposable n8n temporary path: ${resolvedTemp}.`);
    }
    rmSync(resolvedTemp, { recursive: true, force: true });
  }
}

main().catch(error => {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
});
