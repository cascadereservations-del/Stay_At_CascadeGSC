import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const VERSIONED_MIGRATION = /^\d{14}_[a-z0-9_]+\.sql$/;
const COMMIT_SHA = /^[0-9a-f]{40}$/;

function isReadOnlyVerificationQuery(query) {
  const normalized = String(query ?? '')
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/--[^\r\n]*/g, ' ')
    .trim();
  const withoutTrailingSemicolon = normalized.replace(/;\s*$/, '');
  if (!/^(select|with)\b/i.test(withoutTrailingSemicolon)) return false;
  if (withoutTrailingSemicolon.includes(';')) return false;
  const keywordScan = withoutTrailingSemicolon.replace(/'(?:''|[^'])*'/g, "''");
  return !/\b(insert|update|delete|merge|alter|drop|create|truncate|grant|revoke|copy|call|do|execute)\b/i.test(keywordScan);
}

export function validateReleaseContract(contract) {
  const errors = [];
  if (!contract || typeof contract !== 'object') return ['release contract must be an object'];
  if (contract.schema_version !== 1) errors.push('schema_version must equal 1');
  if (!/^[a-z0-9][a-z0-9_-]{2,79}$/.test(contract.release_id ?? '')) errors.push('release_id is invalid');
  if (!['expand', 'backfill', 'verify', 'contract'].includes(contract.phase)) errors.push('phase must be expand, backfill, verify, or contract');
  if (!contract.source?.branch) errors.push('source.branch is required');
  if (!COMMIT_SHA.test(contract.source?.commit ?? '')) errors.push('source.commit must be a 40-character commit SHA');

  if (!Array.isArray(contract.migrations) || contract.migrations.length === 0) {
    errors.push('migrations must contain at least one filename');
  } else {
    if (contract.migrations.some(name => !VERSIONED_MIGRATION.test(name))) errors.push('migrations contain an invalid filename');
    const sorted = [...contract.migrations].sort();
    if (new Set(contract.migrations).size !== contract.migrations.length) errors.push('migrations must be unique');
    if (JSON.stringify(sorted) !== JSON.stringify(contract.migrations)) errors.push('migrations must be ordered by version');
  }
  if (!contract.migration_sha256 || typeof contract.migration_sha256 !== 'object') {
    errors.push('migration_sha256 map is required');
  } else {
    for (const filename of contract.migrations ?? []) {
      if (!/^[0-9a-f]{64}$/.test(contract.migration_sha256[filename] ?? '')) errors.push(`migration_sha256 is missing or invalid for ${filename}`);
    }
    for (const filename of Object.keys(contract.migration_sha256)) {
      if (!(contract.migrations ?? []).includes(filename)) errors.push(`migration_sha256 contains unreferenced file: ${filename}`);
    }
  }

  if (contract.backup?.required !== true) errors.push('backup.required must be true');
  if (!contract.backup?.restore_point) errors.push('backup.restore_point is required');
  if (!contract.backup?.verified_at || Number.isNaN(Date.parse(contract.backup.verified_at))) errors.push('backup.verified_at must be an ISO timestamp');
  if (!Array.isArray(contract.forward_verification) || contract.forward_verification.length === 0) errors.push('forward_verification must not be empty');
  for (const check of contract.forward_verification ?? []) {
    if (!check?.name || !check?.query || !Object.hasOwn(check, 'expect')) errors.push('forward_verification entries require name, query, and expect');
    else if (!isReadOnlyVerificationQuery(check.query)) errors.push(`forward_verification ${check.name} must be one read-only SELECT/WITH query`);
  }
  if (contract.rollback?.strategy !== 'compensating') errors.push('rollback.strategy must be compensating');
  if (!contract.rollback?.safe_until) errors.push('rollback.safe_until is required');
  if (!Array.isArray(contract.rollback?.steps) || contract.rollback.steps.length === 0) errors.push('rollback.steps must not be empty');
  if (!Array.isArray(contract.feature_flags) || contract.feature_flags.length === 0) errors.push('feature_flags must not be empty');
  if (contract.approvals?.production_required !== true) errors.push('approvals.production_required must be true');
  if (!Array.isArray(contract.stop_conditions) || contract.stop_conditions.length === 0) errors.push('stop_conditions must not be empty');
  if (contract.phase === 'contract' && contract.compatibility?.verified !== true) errors.push('compatibility.verified must be true for contract phase');
  return errors;
}

export function findUnsafeExpandSql(sql) {
  const commentsRemoved = sql
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/--[^\r\n]*/g, ' ');
  const dynamic = /\bexecute\s+(?:format\s*\()?['$][\s\S]{0,500}?\b(drop\s+(?:table|schema|type)|truncate|delete\s+from|alter\s+table[\s\S]*?drop\s+column)\b/i.test(commentsRemoved)
    ? ['destructive dynamic SQL']
    : [];
  const normalized = commentsRemoved
    .replace(/'(?:''|[^'])*'/g, "''")
    .toLowerCase();
  const rules = [
    [/\bdrop\s+(table|schema|type)\b/, 'DROP TABLE/SCHEMA/TYPE'],
    [/\balter\s+table\b[\s\S]*?\bdrop\s+column\b/, 'DROP COLUMN'],
    [/\btruncate\b/, 'TRUNCATE'],
    [/\bdelete\s+from\b/, 'DELETE FROM'],
    [/\balter\s+table\b[\s\S]*?\balter\s+column\b[\s\S]*?\btype\b/, 'ALTER COLUMN TYPE'],
    [/\balter\s+table\b[\s\S]*?\brename\s+(column|to)\b/, 'RENAME TABLE/COLUMN'],
  ];
  return [...dynamic, ...rules.filter(([pattern]) => pattern.test(normalized)).map(([, label]) => label)];
}

export function validateMigrationFiles(contract, root) {
  const errors = [];
  for (const filename of contract.migrations ?? []) {
    const path = join(root, 'supabase', 'migrations', filename);
    if (!existsSync(path)) {
      errors.push(`migration file missing: ${filename}`);
      continue;
    }
    const sql = readFileSync(path, 'utf8');
    const actualHash = createHash('sha256').update(sql.replace(/\r\n/g, '\n')).digest('hex');
    if (contract.migration_sha256?.[filename] !== actualHash) errors.push(`${filename}: SHA-256 mismatch from reviewed release contract`);
    if (contract.phase === 'expand') {
      const unsafe = findUnsafeExpandSql(sql);
      if (unsafe.length) errors.push(`${filename}: destructive SQL is not allowed in expand phase (${unsafe.join(', ')})`);
    }
  }
  return errors;
}

export function validateSourceState(contract, root) {
  const cwd = root instanceof URL ? fileURLToPath(root) : root;
  const result = spawnSync('git', ['-c', `safe.directory=${cwd}`, 'merge-base', '--is-ancestor', contract.source?.commit ?? '', 'HEAD'], {
    cwd,
    encoding: 'utf8',
  });
  if (result.status !== 0) return [`source.commit is not an ancestor of HEAD: ${contract.source?.commit ?? '(missing)'}`];
  return [];
}

export function parseAppliedMigrationVersions(output) {
  try {
    const parsed = JSON.parse(output);
    if (Array.isArray(parsed?.migrations)) {
      return new Set(parsed.migrations.filter(row => row.local && row.remote).map(row => String(row.local)));
    }
  } catch { /* table output fallback */ }
  const versions = new Set();
  for (const line of String(output).split(/\r?\n/)) {
    const match = line.match(/\b(\d{14})\s*\|\s*\1\b/);
    if (match) versions.add(match[1]);
  }
  return versions;
}

export function migrationVersions(contract) {
  return (contract.migrations ?? []).map(filename => filename.slice(0, 14));
}
