import { randomBytes } from 'node:crypto';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import net from 'node:net';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

import {
  assertDisposableProjectId,
  buildRecoveryMigrationPlan,
  prepareRecoveryMigrationContent,
  rewriteDisposableSupabaseConfig,
  validateRecoveryBaselineManifest,
} from '../recovery/recovery-contract.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const npxCommand = process.platform === 'win32' ? 'npx.cmd' : 'npx';

function run(command, args, label, workdir, { allowFailure = false } = {}) {
  const result = spawnSync(command, args, { cwd: workdir, encoding: 'utf8', stdio: 'inherit', shell: false });
  if (!allowFailure && (result.error || result.status !== 0)) throw new Error(`${label} failed.`);
}

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.unref();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(error => error ? reject(error) : resolve(port));
    });
  });
}

function loadBaseline(sourceSupabase) {
  const manifest = JSON.parse(readFileSync(path.join(sourceSupabase, 'recovery', 'baseline.json'), 'utf8'));
  const readSource = relativePath => readFileSync(path.join(sourceSupabase, ...relativePath.split('/')), 'utf8');
  const baselineSql = readSource(manifest.baseline_source);
  const prerequisiteSql = readSource(manifest.prerequisite_source);
  const compatibilitySql = readSource(manifest.compatibility_source);
  return {
    manifest: validateRecoveryBaselineManifest(manifest, { baselineSql, prerequisiteSql, compatibilitySql }),
    baselineSql,
    prerequisiteSql,
    compatibilitySql,
  };
}

function writePreparedMigrations({ sourceSupabase, destinationSupabase, baseline }) {
  const sourceDirectory = path.join(sourceSupabase, 'migrations');
  const destinationDirectory = path.join(destinationSupabase, 'migrations');
  const sourceFiles = readdirSync(sourceDirectory).filter(name => name.endsWith('.sql'));
  const plan = buildRecoveryMigrationPlan(baseline.manifest, sourceFiles);
  rmSync(destinationDirectory, { recursive: true, force: true });
  mkdirSync(destinationDirectory, { recursive: true });
  writeFileSync(path.join(destinationDirectory, plan[0]), baseline.prerequisiteSql, 'utf8');
  writeFileSync(path.join(destinationDirectory, plan[1]), baseline.baselineSql, 'utf8');
  writeFileSync(path.join(destinationDirectory, plan[2]), baseline.compatibilitySql, 'utf8');
  for (const file of plan.slice(3)) {
    const source = readFileSync(path.join(sourceDirectory, file), 'utf8');
    const prepared = prepareRecoveryMigrationContent(file, source, baseline.manifest.recovery_assertion_only_migrations);
    writeFileSync(path.join(destinationDirectory, file), prepared, 'utf8');
  }
  return plan;
}

async function main() {
  const sourceSupabase = path.join(repoRoot, 'supabase');
  if (!existsSync(sourceSupabase)) throw new Error('Supabase source directory does not exist.');
  const baseline = loadBaseline(sourceSupabase);
  const projectId = assertDisposableProjectId(`cascade-recovery-ci${randomBytes(6).toString('hex')}`);
  const tempRoot = mkdtempSync(path.join(tmpdir(), `${projectId}-`));
  const tempSupabase = path.join(tempRoot, 'supabase');
  let started = false;

  try {
    cpSync(sourceSupabase, tempSupabase, { recursive: true });
    const plan = writePreparedMigrations({ sourceSupabase, destinationSupabase: tempSupabase, baseline });
    const configPath = path.join(tempSupabase, 'config.toml');
    writeFileSync(configPath, rewriteDisposableSupabaseConfig(readFileSync(configPath, 'utf8'), {
      projectId,
      dbPort: await freePort(),
      shadowPort: await freePort(),
    }), 'utf8');

    const cli = process.env.GITHUB_ACTIONS === 'true' ? 'supabase' : npxCommand;
    const cliPrefix = cli === 'supabase' ? [] : ['supabase'];
    started = true;
    run(cli, [...cliPrefix, 'start', '--workdir', tempRoot, '--yes'], 'Prepared baseline start', repoRoot);
    run(cli, [...cliPrefix, 'test', 'db', path.join(tempSupabase, 'tests', 'database'), '--local', '--workdir', tempRoot], 'Prepared baseline database tests', repoRoot);
    process.stdout.write(`${JSON.stringify({ ok: true, project_id: projectId, migrations: plan.length, first: plan[0], last: plan.at(-1) })}\n`);
  } finally {
    if (started) {
      const cli = process.env.GITHUB_ACTIONS === 'true' ? 'supabase' : npxCommand;
      const cliPrefix = cli === 'supabase' ? [] : ['supabase'];
      run(cli, [...cliPrefix, 'stop', '--project-id', projectId, '--no-backup', '--yes'], 'Prepared baseline cleanup', repoRoot, { allowFailure: true });
    }
    rmSync(tempRoot, { recursive: true, force: true });
  }
}

main().catch(error => {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
});
