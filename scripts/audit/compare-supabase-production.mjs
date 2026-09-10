import { createHash } from 'node:crypto';
import { access, readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SAFE_TOP_LEVEL_FIELDS = new Set([
  'project_ref',
  'captured_at',
  'capture_method',
  'functions',
  'recovered_slugs',
  'database',
  'cron',
  'storage',
]);

const SAFE_FUNCTION_FIELDS = new Set([
  'slug',
  'version',
  'status',
  'verify_jwt',
  'updated_at',
  'deployment_sha256',
  'critical',
]);

const UNSAFE_FIELD = /(^id$|entrypoint|token|secret|password|credential|authorization|database_url|raw_body|command)/i;

function assertNoUnsafeFields(value, trail = 'snapshot') {
  if (Array.isArray(value)) {
    value.forEach((item, index) => assertNoUnsafeFields(item, `${trail}[${index}]`));
    return;
  }
  if (!value || typeof value !== 'object') return;

  for (const [key, nested] of Object.entries(value)) {
    if (UNSAFE_FIELD.test(key)) {
      throw new Error(`Unsafe production snapshot field: ${trail}.${key}`);
    }
    assertNoUnsafeFields(nested, `${trail}.${key}`);
  }
}

export function validateSafeSnapshot(snapshot) {
  if (!snapshot || typeof snapshot !== 'object' || Array.isArray(snapshot)) {
    throw new TypeError('Production snapshot must be an object');
  }
  assertNoUnsafeFields(snapshot);

  for (const key of Object.keys(snapshot)) {
    if (!SAFE_TOP_LEVEL_FIELDS.has(key)) {
      throw new Error(`Unsafe production snapshot field: snapshot.${key}`);
    }
  }
  if (typeof snapshot.project_ref !== 'string' || snapshot.project_ref.length < 3) {
    throw new Error('Production snapshot requires a project_ref');
  }
  if (!Array.isArray(snapshot.functions)) {
    throw new Error('Production snapshot requires a functions array');
  }

  const slugs = new Set();
  for (const [index, fn] of snapshot.functions.entries()) {
    for (const key of Object.keys(fn)) {
      if (!SAFE_FUNCTION_FIELDS.has(key)) {
        throw new Error(`Unsafe production snapshot field: snapshot.functions[${index}].${key}`);
      }
    }
    if (!/^[a-z0-9-]+$/.test(fn.slug ?? '')) {
      throw new Error(`Invalid function slug at snapshot.functions[${index}]`);
    }
    if (slugs.has(fn.slug)) throw new Error(`Duplicate deployed function slug: ${fn.slug}`);
    slugs.add(fn.slug);
    if (!Number.isInteger(fn.version) || fn.version < 1) {
      throw new Error(`Invalid function version for ${fn.slug}`);
    }
    if (typeof fn.verify_jwt !== 'boolean' || typeof fn.critical !== 'boolean') {
      throw new Error(`Function ${fn.slug} must declare verify_jwt and critical`);
    }
    if (!/^[a-f0-9]{64}$/.test(fn.deployment_sha256 ?? '')) {
      throw new Error(`Invalid deployment hash for ${fn.slug}`);
    }
  }
  return snapshot;
}

async function exists(file) {
  try {
    await access(file);
    return true;
  } catch {
    return false;
  }
}

async function localFunctionSlugs(root) {
  const functionsRoot = path.join(root, 'supabase', 'functions');
  if (!(await exists(functionsRoot))) return [];
  const entries = await readdir(functionsRoot, { withFileTypes: true });
  const slugs = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name.startsWith('_')) continue;
    if (await exists(path.join(functionsRoot, entry.name, 'index.ts'))) slugs.push(entry.name);
  }
  return slugs.sort();
}

async function evaluateDatabaseSnapshot(root, database, errors) {
  if (!database) return null;
  const snapshotPath = path.join(root, database.schema_snapshot);
  if (!(await exists(snapshotPath))) {
    errors.push(`Schema snapshot is missing: ${database.schema_snapshot}`);
    return { ...database, available: false };
  }
  const source = await readFile(snapshotPath);
  const actualHash = createHash('sha256').update(source.toString('utf8').replace(/\r\n/g, '\n')).digest('hex');
  if (actualHash !== database.schema_snapshot_sha256) {
    errors.push(`Schema snapshot hash differs: ${database.schema_snapshot}`);
  }
  const sql = source.toString('utf8');
  return {
    ...database,
    available: true,
    table_count: (sql.match(/^CREATE TABLE/gimu) ?? []).length,
    policy_count: (sql.match(/^CREATE POLICY/gimu) ?? []).length,
    rls_table_count: (sql.match(/^ALTER TABLE .* ENABLE ROW LEVEL SECURITY;/gimu) ?? []).length,
  };
}

export async function evaluateProductionContract({ root, snapshot }) {
  validateSafeSnapshot(snapshot);
  const localSlugs = await localFunctionSlugs(root);
  const localSet = new Set(localSlugs);
  const deployedSet = new Set(snapshot.functions.map((fn) => fn.slug));
  const recoveredSet = new Set(snapshot.recovered_slugs ?? []);
  const errors = [];

  const functions = snapshot.functions
    .map((fn) => {
      const hasSource = localSet.has(fn.slug);
      const sourceStatus = hasSource
        ? (recoveredSet.has(fn.slug) ? 'recovered' : 'versioned')
        : 'missing-source';
      if (!hasSource && fn.critical) {
        errors.push(`${fn.slug}: critical deployed function is missing local source`);
      }
      return { ...fn, source_status: sourceStatus };
    })
    .sort((left, right) => left.slug.localeCompare(right.slug));

  const localOnly = localSlugs.filter((slug) => !deployedSet.has(slug));
  const database = await evaluateDatabaseSnapshot(root, snapshot.database, errors);

  return {
    project_ref: snapshot.project_ref,
    captured_at: snapshot.captured_at ?? null,
    functions,
    local_only: localOnly,
    database,
    cron: snapshot.cron ?? [],
    storage: snapshot.storage ?? null,
    errors,
  };
}

async function runCli() {
  const scriptFile = fileURLToPath(import.meta.url);
  const root = path.resolve(path.dirname(scriptFile), '..', '..');
  const snapshotFile = path.join(root, 'docs', 'architecture', 'production-contract.json');
  const snapshot = JSON.parse(await readFile(snapshotFile, 'utf8'));
  const result = await evaluateProductionContract({ root, snapshot });
  const counts = result.functions.reduce((summary, fn) => {
    summary[fn.source_status] = (summary[fn.source_status] ?? 0) + 1;
    return summary;
  }, {});

  console.log(`Project: ${result.project_ref}`);
  console.log(`Deployed functions: ${result.functions.length}`);
  console.log(`Source status: ${JSON.stringify(counts)}`);
  console.log(`Local-only functions: ${result.local_only.join(', ') || 'none'}`);
  if (result.database?.available) {
    console.log(`Schema snapshot: ${result.database.table_count} tables, ${result.database.policy_count} policies, ${result.database.rls_table_count} RLS tables`);
  }

  if (result.errors.length > 0) {
    for (const error of result.errors) console.error(`BLOCK: ${error}`);
    if (process.argv.includes('--check')) process.exitCode = 1;
  }
}

const invokedDirectly = process.argv[1]
  && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));
if (invokedDirectly) await runCli();
