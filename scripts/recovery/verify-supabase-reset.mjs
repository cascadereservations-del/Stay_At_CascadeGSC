import { createHash, randomBytes } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { copyFileSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import net from 'node:net';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { parseAppliedMigrationVersions } from '../migrations/release-safety.mjs';
import { prepareCommandSpawn } from './process-runner.mjs';
import {
  assertDisposableProjectId,
  rewriteDisposableSupabaseConfig,
  selectRecoveryMigrationFiles,
  validateRecoveryBaselineManifest,
} from './recovery-contract.mjs';

const ACTIVE_DB_CONTAINER = 'supabase_db_direct-booking';
const EXCLUDED_SERVICES = 'gotrue,realtime,storage-api,imgproxy,kong,mailpit,postgrest,postgres-meta,studio,edge-runtime,logflare,vector,supavisor';
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const npxCommand = process.platform === 'win32' ? 'npx.cmd' : 'npx';

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith('--')) throw new Error(`Unexpected argument: ${argument}.`);
    const value = argv[index + 1];
    if (!value || value.startsWith('--')) throw new Error(`Missing value for ${argument}.`);
    result[argument.slice(2)] = value;
    index += 1;
  }
  return result;
}

function run(command, args, label, { allowFailure = false } = {}) {
  const prepared = prepareCommandSpawn(command, args);
  const result = spawnSync(prepared.command, prepared.args, {
    ...prepared.options,
    cwd: repoRoot,
    encoding: 'utf8',
    windowsHide: true,
  });
  if (!allowFailure && (result.error || result.status !== 0)) {
    const detail = [result.error?.message, result.stdout, result.stderr].filter(Boolean).join('\n').trim();
    throw new Error(`${label} failed${detail ? `: ${detail}` : '.'}`);
  }
  return result;
}

function inspectActiveIdentity() {
  return run('docker', ['inspect', ACTIVE_DB_CONTAINER, '--format', '{{.Id}}|{{.State.StartedAt}}|{{.State.Health.Status}}'], 'Active local Supabase identity')
    .stdout.trim();
}

function identityHash(identity) {
  return createHash('sha256').update(identity).digest('hex');
}

function migrationVersions(directory) {
  return readdirSync(directory)
    .filter(name => /^\d+_.+\.sql$/.test(name))
    .map(name => name.match(/^(\d+)_/)[1])
    .sort();
}

function getFreePort() {
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

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const projectId = assertDisposableProjectId(args['project-id'] ?? `cascade-recovery-${randomBytes(6).toString('hex')}`);
  const sourceSupabase = path.resolve(args.source ?? path.join(repoRoot, 'supabase'));
  if (!existsSync(sourceSupabase) || !statSync(sourceSupabase).isDirectory()) {
    throw new Error(`Supabase source directory does not exist: ${sourceSupabase}.`);
  }
  const sourceMigrationDirectory = path.join(sourceSupabase, 'migrations');
  const sourceMigrationFiles = readdirSync(sourceMigrationDirectory).filter(name => name.endsWith('.sql'));
  const manifest = JSON.parse(readFileSync(path.join(sourceSupabase, 'recovery', 'baseline.json'), 'utf8'));
  const baselinePath = path.join(sourceSupabase, ...manifest.baseline_source.split('/'));
  const prerequisitePath = path.join(sourceSupabase, ...manifest.prerequisite_source.split('/'));
  const compatibilityPath = path.join(sourceSupabase, ...manifest.compatibility_source.split('/'));
  const baselineSql = readFileSync(baselinePath, 'utf8');
  const prerequisiteSql = readFileSync(prerequisitePath, 'utf8');
  const compatibilitySql = readFileSync(compatibilityPath, 'utf8');
  const validatedBaseline = validateRecoveryBaselineManifest(manifest, { baselineSql, prerequisiteSql, compatibilitySql });
  const forwardMigrationFiles = selectRecoveryMigrationFiles(sourceMigrationFiles, validatedBaseline.forward_migrations_from);
  const sourceVersions = [
    validatedBaseline.prerequisite_migration_version,
    validatedBaseline.baseline_migration_version,
    validatedBaseline.compatibility_migration_version,
    ...forwardMigrationFiles.map(name => name.match(/^(\d+)_/)[1]),
  ];
  const activeBefore = inspectActiveIdentity();
  const tempRoot = mkdtempSync(path.join(tmpdir(), `${projectId}-`));
  const tempSupabase = path.join(tempRoot, 'supabase');
  const dbPort = args['db-port'] ? Number(args['db-port']) : await getFreePort();
  const shadowPort = args['shadow-port'] ? Number(args['shadow-port']) : await getFreePort();
  let disposableStarted = false;
  let primaryError;

  try {
    cpSync(sourceSupabase, tempSupabase, {
      recursive: true,
      filter: source => !source.split(path.sep).includes('.temp'),
    });
    const tempMigrationDirectory = path.join(tempSupabase, 'migrations');
    rmSync(tempMigrationDirectory, { recursive: true, force: true });
    mkdirSync(tempMigrationDirectory, { recursive: true });
    copyFileSync(
      prerequisitePath,
      path.join(tempMigrationDirectory, `${validatedBaseline.prerequisite_migration_version}_recovery_prerequisites.sql`),
    );
    copyFileSync(
      baselinePath,
      path.join(tempMigrationDirectory, `${validatedBaseline.baseline_migration_version}_recovered_production_baseline.sql`),
    );
    copyFileSync(
      compatibilityPath,
      path.join(tempMigrationDirectory, `${validatedBaseline.compatibility_migration_version}_pre_forward_compat.sql`),
    );
    for (const migrationFile of forwardMigrationFiles) {
      copyFileSync(path.join(sourceMigrationDirectory, migrationFile), path.join(tempMigrationDirectory, migrationFile));
    }
    const configPath = path.join(tempSupabase, 'config.toml');
    const config = rewriteDisposableSupabaseConfig(readFileSync(configPath, 'utf8'), { projectId, dbPort, shadowPort });
    writeFileSync(configPath, config, 'utf8');

    run(npxCommand, ['supabase', 'start', '--workdir', tempRoot, '--exclude', EXCLUDED_SERVICES, '--yes'], 'Disposable Supabase database start');
    disposableStarted = true;
    run(npxCommand, ['supabase', 'db', 'reset', '--local', '--no-seed', '--workdir', tempRoot, '--yes'], 'Disposable Supabase migration reset');
    const databaseTestDirectory = path.join(tempSupabase, 'tests', 'database');
    const databaseTestFiles = readdirSync(databaseTestDirectory).filter(name => name.endsWith('.sql')).length;
    run(
      npxCommand,
      ['supabase', 'test', 'db', databaseTestDirectory, '--local', '--workdir', tempRoot],
      'Disposable Supabase pgTAP suite',
    );
    const ledgerOutput = run(npxCommand, ['supabase', 'migration', 'list', '--local', '--workdir', tempRoot], 'Disposable Supabase migration ledger').stdout;
    const appliedVersions = [...parseAppliedMigrationVersions(ledgerOutput)].sort();
    const missing = sourceVersions.filter(version => !appliedVersions.includes(version));
    const unexpected = appliedVersions.filter(version => !sourceVersions.includes(version));
    if (missing.length || unexpected.length) {
      throw new Error(`Disposable migration ledger mismatch. Missing [${missing.join(', ')}], unexpected [${unexpected.join(', ')}].`);
    }
    const activeAfterReset = inspectActiveIdentity();
    if (activeAfterReset !== activeBefore) throw new Error('Active direct-booking database identity changed during disposable reset.');
    const disposableImage = run('docker', ['inspect', `supabase_db_${projectId}`, '--format', '{{.Config.Image}}'], 'Disposable Supabase image').stdout.trim();
    const cliVersion = run(npxCommand, ['supabase', '--version'], 'Supabase CLI version').stdout.trim();
    const evidence = {
      ok: true,
      checked_at: new Date().toISOString(),
      project_id: projectId,
      supabase_cli: cliVersion,
      database_image: disposableImage,
      recovery_prerequisite_sha256: validatedBaseline.prerequisite_sha256,
      recovery_baseline_sha256: validatedBaseline.baseline_sha256,
      recovery_compatibility_sha256: validatedBaseline.compatibility_sha256,
      baseline_includes_through: validatedBaseline.includes_through,
      historical_migrations_replaced_by_baseline: sourceMigrationFiles.length - forwardMigrationFiles.length,
      forward_migrations: forwardMigrationFiles.length,
      source_migrations: sourceVersions.length,
      applied_migrations: appliedVersions.length,
      database_test_files: databaseTestFiles,
      first_migration: sourceVersions.at(0),
      last_migration: sourceVersions.at(-1),
      active_database_identity_sha256: identityHash(activeBefore),
      active_database_unchanged: true,
      production_connection_used: false,
    };
    if (args.output) {
      const output = path.resolve(args.output);
      writeFileSync(output, `${JSON.stringify(evidence, null, 2)}\n`, 'utf8');
    }
    process.stdout.write(`${JSON.stringify(evidence)}\n`);
  } catch (error) {
    primaryError = error;
    throw error;
  } finally {
    assertDisposableProjectId(projectId);
    run(npxCommand, ['supabase', 'stop', '--project-id', projectId, '--no-backup', '--yes'], 'Disposable Supabase cleanup', { allowFailure: !disposableStarted });
    const leftovers = run('docker', ['ps', '-a', '--filter', `name=${projectId}`, '--format', '{{.Names}}'], 'Disposable Supabase cleanup verification').stdout.trim();
    if (leftovers && !primaryError) throw new Error(`Disposable Supabase cleanup left containers: ${leftovers}.`);
    const activeAfterCleanup = inspectActiveIdentity();
    if (activeAfterCleanup !== activeBefore && !primaryError) throw new Error('Active direct-booking database identity changed during disposable cleanup.');
    const resolvedTemp = path.resolve(tempRoot);
    const resolvedSystemTemp = path.resolve(tmpdir());
    if (!resolvedTemp.startsWith(`${resolvedSystemTemp}${path.sep}`) || !path.basename(resolvedTemp).startsWith(`${projectId}-`)) {
      throw new Error(`Unsafe disposable Supabase temporary path: ${resolvedTemp}.`);
    }
    rmSync(resolvedTemp, { recursive: true, force: true });
  }
}

main().catch(error => {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
});
