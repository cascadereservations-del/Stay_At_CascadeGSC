import { createHash } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';

const DISPOSABLE_PROJECT = /^cascade-recovery-[a-z0-9]{4,32}$/;

function normalizedSqlHash(source) {
  return createHash('sha256').update(source.replace(/\r\n/g, '\n')).digest('hex');
}

const LIVE_DATA_ASSERTION_MARKER = '-- Assertions against the live data that motivated the change.';

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, child]) => [key, canonicalize(child)]),
    );
  }
  return value;
}

function canonicalJson(value) {
  return JSON.stringify(canonicalize(value));
}

function firstDifference(left, right, pointer = '$') {
  if (Object.is(left, right)) return null;
  if (typeof left !== typeof right || left === null || right === null) return { pointer, expected: left, actual: right };
  if (Array.isArray(left) || Array.isArray(right)) {
    if (!Array.isArray(left) || !Array.isArray(right)) return { pointer, expected: left, actual: right };
    if (left.length !== right.length) return { pointer: `${pointer}.length`, expected: left.length, actual: right.length };
    for (let index = 0; index < left.length; index += 1) {
      const difference = firstDifference(left[index], right[index], `${pointer}[${index}]`);
      if (difference) return difference;
    }
    return null;
  }
  if (typeof left === 'object') {
    const leftKeys = Object.keys(left).sort();
    const rightKeys = Object.keys(right).sort();
    if (canonicalJson(leftKeys) !== canonicalJson(rightKeys)) return { pointer: `${pointer}.__keys`, expected: leftKeys, actual: rightKeys };
    for (const key of leftKeys) {
      const difference = firstDifference(left[key], right[key], `${pointer}.${key}`);
      if (difference) return difference;
    }
    return null;
  }
  return { pointer, expected: left, actual: right };
}

function replaceExactlyOnce(source, pattern, replacement, label) {
  const matches = [...source.matchAll(pattern)];
  if (matches.length !== 1) throw new Error(`Expected exactly one ${label}; found ${matches.length}.`);
  return source.replace(pattern, replacement);
}

function rewriteSection(source, sectionName, transform) {
  const lines = source.split(/\r?\n/);
  const headerToken = `[${sectionName}]`;
  const indexes = lines.flatMap((line, index) => line.trim() === headerToken ? [index] : []);
  if (indexes.length !== 1) throw new Error(`Expected exactly one [${sectionName}] section; found ${indexes.length}.`);
  const headerIndex = indexes[0];
  let endIndex = lines.length;
  for (let index = headerIndex + 1; index < lines.length; index += 1) {
    if (/^\[[^\r\n]+\]$/.test(lines[index].trim())) { endIndex = index; break; }
  }
  const body = `${lines.slice(headerIndex + 1, endIndex).join('\n')}\n`;
  const rewrittenBody = transform(body).replace(/\n$/, '').split('\n');
  return [...lines.slice(0, headerIndex + 1), ...rewrittenBody, ...lines.slice(endIndex)].join('\n');
}

export function assertDisposableProjectId(projectId) {
  if (!DISPOSABLE_PROJECT.test(projectId)) {
    throw new Error(`Unsafe disposable project ID: ${projectId || '<empty>'}.`);
  }
  return projectId;
}

export async function inventoryWorkflowFiles(directory) {
  const entries = (await readdir(directory, { withFileTypes: true }))
    .filter(entry => entry.isFile() && entry.name.endsWith('.json'))
    .sort((left, right) => left.name.localeCompare(right.name));
  if (entries.length === 0) throw new Error(`No workflow JSON files found in ${directory}.`);

  const workflows = [];
  const names = new Set();
  for (const entry of entries) {
    const file = path.join(directory, entry.name);
    let workflow;
    try {
      workflow = JSON.parse(await readFile(file, 'utf8'));
    } catch (error) {
      throw new Error(`Invalid workflow JSON ${entry.name}: ${error.message}`);
    }
    if (!workflow?.name || typeof workflow.name !== 'string') throw new Error(`Workflow ${entry.name} has no name.`);
    if (workflow.active !== false) throw new Error(`Workflow ${workflow.name} must be inactive.`);
    if (names.has(workflow.name)) throw new Error(`Duplicate workflow name: ${workflow.name}.`);
    names.add(workflow.name);
    workflows.push(workflow);
  }
  return workflows.sort((left, right) => left.name.localeCompare(right.name));
}

export function normalizeWorkflow(workflow) {
  const normalized = {
    name: workflow?.name,
    active: workflow?.active,
    nodes: (workflow?.nodes ?? []).map(({ id: _generatedNodeId, ...node }) => node),
    connections: workflow?.connections ?? {},
    settings: workflow?.settings ?? {},
    tags: workflow?.tags ?? [],
  };
  for (const optional of ['meta', 'pinData', 'staticData']) {
    if (workflow?.[optional] !== undefined && workflow[optional] !== null) normalized[optional] = workflow[optional];
  }
  return canonicalize(normalized);
}

export function compareWorkflowSets(expected, actual) {
  const left = expected.map(normalizeWorkflow).sort((a, b) => a.name.localeCompare(b.name));
  const right = actual.map(normalizeWorkflow).sort((a, b) => a.name.localeCompare(b.name));
  const leftJson = canonicalJson(left);
  const rightJson = canonicalJson(right);
  if (leftJson !== rightJson) {
    const expectedNames = left.map(item => item.name).join(', ');
    const actualNames = right.map(item => item.name).join(', ');
    const difference = firstDifference(left, right);
    throw new Error(`Workflow round-trip mismatch at ${difference?.pointer ?? '<unknown>'}: expected ${JSON.stringify(difference?.expected)}, actual ${JSON.stringify(difference?.actual)}. Expected names [${expectedNames}], actual names [${actualNames}].`);
  }
  return {
    count: left.length,
    names: left.map(item => item.name),
    semantic_sha256: createHash('sha256').update(leftJson).digest('hex'),
  };
}

export function rewriteDisposableSupabaseConfig(source, { projectId, dbPort, shadowPort }) {
  assertDisposableProjectId(projectId);
  if (!Number.isInteger(dbPort) || !Number.isInteger(shadowPort) || dbPort === shadowPort) {
    throw new Error('Disposable database ports must be distinct integers.');
  }

  let rewritten = replaceExactlyOnce(
    source,
    /^project_id\s*=\s*"[^"]+"\s*$/gm,
    `project_id = "${projectId}"`,
    'project ID',
  );
  rewritten = rewriteSection(rewritten, 'db', section => {
    let result = replaceExactlyOnce(section, /^port\s*=\s*\d+\s*$/gm, `port = ${dbPort}`, 'database port');
    result = replaceExactlyOnce(result, /^shadow_port\s*=\s*\d+\s*$/gm, `shadow_port = ${shadowPort}`, 'database shadow port');
    return result;
  });
  rewritten = rewriteSection(rewritten, 'db.seed', section => (
    replaceExactlyOnce(section, /^enabled\s*=\s*(?:true|false)\s*$/gm, 'enabled = false', 'seed enabled setting')
  ));
  return rewritten;
}

export function validateRecoveryBaselineManifest(manifest, { baselineSql, prerequisiteSql, compatibilitySql, bridgeSql }) {
  if (manifest?.schema_version !== 1) throw new Error('Recovery baseline schema_version must be 1.');
  for (const field of ['prerequisite_migration_version', 'baseline_migration_version', 'compatibility_migration_version', 'includes_through', 'forward_migrations_from']) {
    if (!/^\d{14}$/.test(manifest?.[field] ?? '')) throw new Error(`Recovery baseline ${field} must be a 14-digit migration version.`);
  }
  if (!/^recovery\/[A-Za-z0-9._/-]+\.sql$/.test(manifest?.prerequisite_source ?? '')) {
    throw new Error('Recovery prerequisite_source must be a safe SQL path under recovery/.');
  }
  if (!/^schemas\/[A-Za-z0-9._/-]+\.sql$/.test(manifest?.baseline_source ?? '')) {
    throw new Error('Recovery baseline_source must be a safe SQL path under schemas/.');
  }
  if (!/^recovery\/[A-Za-z0-9._/-]+\.sql$/.test(manifest?.compatibility_source ?? '')) {
    throw new Error('Recovery compatibility_source must be a safe SQL path under recovery/.');
  }
  if (!(manifest.includes_through < manifest.prerequisite_migration_version
    && manifest.prerequisite_migration_version < manifest.baseline_migration_version
    && manifest.baseline_migration_version < manifest.compatibility_migration_version
    && manifest.compatibility_migration_version < manifest.forward_migrations_from)) {
    throw new Error('Recovery baseline versions must satisfy includes_through < prerequisites < baseline < compatibility < forward boundary.');
  }
  if (manifest.recovery_excluded_migrations !== undefined) {
    if (!Array.isArray(manifest.recovery_excluded_migrations) || manifest.recovery_excluded_migrations.length === 0) {
      throw new Error('Recovery excluded migrations must be a non-empty array when provided.');
    }
    const names = new Set();
    for (const fileName of manifest.recovery_excluded_migrations) {
      if (!/^\d{14}_[A-Za-z0-9._-]+\.sql$/.test(fileName) || names.has(fileName)) {
        throw new Error('Recovery excluded migrations must be unique, filename-shaped SQL migrations.');
      }
      names.add(fileName);
    }
  }
  if (manifest.recovery_assertion_only_migrations !== undefined) {
    if (!Array.isArray(manifest.recovery_assertion_only_migrations) || manifest.recovery_assertion_only_migrations.length === 0) {
      throw new Error('Recovery assertion-only migrations must be a non-empty array when provided.');
    }
    const excluded = new Set(manifest.recovery_excluded_migrations ?? []);
    const names = new Set();
    for (const fileName of manifest.recovery_assertion_only_migrations) {
      if (!/^\d{14}_[A-Za-z0-9._-]+\.sql$/.test(fileName) || names.has(fileName) || excluded.has(fileName)) {
        throw new Error('Recovery assertion-only migrations must be unique filename-shaped SQL migrations that are not excluded.');
      }
      names.add(fileName);
    }
  }
  if (manifest.recovery_bridge_migrations !== undefined) {
    if (!Array.isArray(manifest.recovery_bridge_migrations) || manifest.recovery_bridge_migrations.length === 0) {
      throw new Error('Recovery bridge migrations must be a non-empty array when provided.');
    }
    const pins = manifest.recovery_bridge_sha256;
    if (!pins || typeof pins !== 'object' || Array.isArray(pins)) {
      throw new Error('Recovery bridge migrations require a recovery_bridge_sha256 map.');
    }
    const names = new Set();
    for (const fileName of manifest.recovery_bridge_migrations) {
      if (!/^\d{14}_[A-Za-z0-9._-]+\.sql$/.test(fileName) || names.has(fileName)) {
        throw new Error('Recovery bridge migrations must be unique, filename-shaped SQL files.');
      }
      names.add(fileName);
      if (fileName.slice(0, 14) < manifest.forward_migrations_from) {
        throw new Error(`Recovery bridge version must be >= forward_migrations_from: ${fileName}.`);
      }
      if (!/^[0-9a-f]{64}$/.test(pins[fileName] ?? '')) throw new Error(`Recovery bridge has no sha256 pin: ${fileName}.`);
      const source = bridgeSql?.[fileName];
      if (typeof source !== 'string') throw new Error(`Recovery bridge source was not provided: ${fileName}.`);
      const bridgeHash = normalizedSqlHash(source);
      if (pins[fileName] !== bridgeHash) {
        throw new Error(`Recovery bridge hash mismatch for ${fileName}: expected ${pins[fileName]}, actual ${bridgeHash}.`);
      }
    }
    if (Object.keys(pins).some(name => !names.has(name))) throw new Error('Recovery bridge sha256 map names an unlisted file.');
  }
  if (manifest.recovery_statement_omissions !== undefined) {
    const omissions = manifest.recovery_statement_omissions;
    if (!omissions || typeof omissions !== 'object' || Array.isArray(omissions) || Object.keys(omissions).length === 0) {
      throw new Error('Recovery statement omissions must be a non-empty object keyed by migration file.');
    }
    const excluded = new Set(manifest.recovery_excluded_migrations ?? []);
    const bridges = new Set(manifest.recovery_bridge_migrations ?? []);
    for (const [fileName, entries] of Object.entries(omissions)) {
      if (!/^\d{14}_[A-Za-z0-9._-]+\.sql$/.test(fileName)) throw new Error(`Recovery statement omission file is not filename-shaped: ${fileName}.`);
      if (fileName.slice(0, 14) < manifest.forward_migrations_from) throw new Error(`Recovery statement omission must name a forward migration: ${fileName}.`);
      if (excluded.has(fileName)) throw new Error(`Recovery statement omission names an excluded migration: ${fileName}.`);
      if (bridges.has(fileName)) throw new Error(`Recovery statement omission names a bridge: ${fileName}.`);
      if (!Array.isArray(entries) || entries.length === 0) throw new Error(`Recovery statement omissions must be a non-empty array: ${fileName}.`);
      for (const entry of entries) {
        if (typeof entry?.first_line !== 'string' || entry.first_line.trim() === '' || !/^[0-9a-f]{64}$/.test(entry?.sha256 ?? '')) {
          throw new Error(`Recovery statement omission needs first_line and a sha256 hex pin: ${fileName}.`);
        }
      }
    }
  }
  const prerequisiteHash = normalizedSqlHash(prerequisiteSql);
  if (manifest.prerequisite_sha256 !== prerequisiteHash) {
    throw new Error(`Recovery prerequisite hash mismatch: expected ${manifest.prerequisite_sha256}, actual ${prerequisiteHash}.`);
  }
  const actualHash = normalizedSqlHash(baselineSql);
  if (manifest.baseline_sha256 !== actualHash) {
    throw new Error(`Recovery baseline hash mismatch: expected ${manifest.baseline_sha256}, actual ${actualHash}.`);
  }
  const compatibilityHash = normalizedSqlHash(compatibilitySql);
  if (manifest.compatibility_sha256 !== compatibilityHash) {
    throw new Error(`Recovery compatibility hash mismatch: expected ${manifest.compatibility_sha256}, actual ${compatibilityHash}.`);
  }
  return { ...manifest };
}

export function selectRecoveryMigrationFiles(fileNames, forwardFrom, excludedFiles = []) {
  if (!/^\d{14}$/.test(forwardFrom ?? '')) throw new Error('Recovery forward migration boundary is invalid.');
  if (!Array.isArray(excludedFiles)) throw new Error('Recovery excluded migrations must be an array.');
  const migrations = fileNames
    .filter(name => /^\d{14}_.+\.sql$/.test(name))
    .sort((left, right) => left.localeCompare(right));
  if (!migrations.some(name => name.startsWith(`${forwardFrom}_`))) {
    throw new Error(`Recovery forward migration boundary is missing: ${forwardFrom}.`);
  }
  const forward = migrations.filter(name => name.slice(0, 14) >= forwardFrom);
  for (const excluded of excludedFiles) {
    if (!forward.includes(excluded)) throw new Error(`Recovery excluded migration is not a forward migration: ${excluded}.`);
  }
  const excluded = new Set(excludedFiles);
  return forward.filter(name => !excluded.has(name));
}

// Removes one production-data seed statement: from the line equal to first_line through the first later line ending
// in ';'. The removed text (LF-normalized, trailing newline included) must match the pinned sha256.
export function omitRecoveryStatement(fileName, source, { first_line: firstLine, sha256 }) {
  const lines = source.split('\n');
  const bare = line => line.replace(/\r$/, '');
  const starts = [];
  lines.forEach((line, index) => { if (bare(line) === firstLine) starts.push(index); });
  if (starts.length !== 1) {
    throw new Error(`Recovery statement omission first_line must match exactly one line in ${fileName} (found ${starts.length}): ${firstLine}`);
  }
  let end = -1;
  for (let index = starts[0]; index < lines.length; index += 1) {
    if (bare(lines[index]).endsWith(';')) { end = index; break; }
  }
  if (end < 0) throw new Error(`Recovery statement omission has no terminating ';' line in ${fileName}: ${firstLine}`);
  const removed = `${lines.slice(starts[0], end + 1).map(bare).join('\n')}\n`;
  const actual = createHash('sha256').update(removed).digest('hex');
  if (actual !== sha256) {
    throw new Error(`Recovery statement omission hash mismatch for ${fileName}: expected ${sha256}, actual ${actual}.`);
  }
  const marker = `-- recovery: omitted production-data seed (sha256 ${actual.slice(0, 12)})`;
  return [...lines.slice(0, starts[0]), marker, ...lines.slice(end + 1)].join('\n');
}

export function prepareRecoveryMigrationContent(fileName, source, assertionOnlyFiles = [], statementOmissions = {}) {
  if (!Array.isArray(assertionOnlyFiles)) throw new Error('Recovery assertion-only migrations must be an array.');
  if (!statementOmissions || typeof statementOmissions !== 'object' || Array.isArray(statementOmissions)) {
    throw new Error('Recovery statement omissions must be an object.');
  }
  let content = source;
  for (const entry of statementOmissions[fileName] ?? []) content = omitRecoveryStatement(fileName, content, entry);
  if (!assertionOnlyFiles.includes(fileName)) return content;
  const markerIndex = content.indexOf(LIVE_DATA_ASSERTION_MARKER);
  if (markerIndex < 0 || content.indexOf(LIVE_DATA_ASSERTION_MARKER, markerIndex + LIVE_DATA_ASSERTION_MARKER.length) >= 0) {
    throw new Error(`Recovery assertion-only migration must contain exactly one live-data assertion marker: ${fileName}.`);
  }
  return `${content.slice(0, markerIndex).trimEnd()}

-- Production-data assertions intentionally omitted from the disposable recovery copy.
`;
}

export function buildRecoveryMigrationPlan(manifest, sourceMigrationFiles) {
  const forward = selectRecoveryMigrationFiles(
    sourceMigrationFiles,
    manifest?.forward_migrations_from,
    manifest?.recovery_excluded_migrations,
  );
  const bridges = manifest?.recovery_bridge_migrations ?? [];
  if (!Array.isArray(bridges)) throw new Error('Recovery bridge migrations must be an array.');
  const versions = new Set(sourceMigrationFiles.filter(name => /^\d{14}_.+\.sql$/.test(name)).map(name => name.slice(0, 14)));
  for (const bridge of bridges) {
    if (!/^\d{14}_.+\.sql$/.test(bridge)) throw new Error(`Recovery bridge is not filename-shaped: ${bridge}.`);
    const version = bridge.slice(0, 14);
    if (version < manifest.forward_migrations_from) throw new Error(`Recovery bridge version must be >= forward_migrations_from: ${bridge}.`);
    if (versions.has(version)) throw new Error(`Recovery bridge version collides with a migration version: ${bridge}.`);
  }
  for (const fileName of Object.keys(manifest?.recovery_statement_omissions ?? {})) {
    if (!forward.includes(fileName)) throw new Error(`Recovery statement omission is not a forward migration in the plan: ${fileName}.`);
  }
  const merged = [...forward, ...bridges].sort((left, right) => left.slice(0, 14).localeCompare(right.slice(0, 14)));
  return [
    `${manifest.prerequisite_migration_version}_recovery_prerequisites.sql`,
    `${manifest.baseline_migration_version}_recovered_production_baseline.sql`,
    `${manifest.compatibility_migration_version}_pre_forward_compat.sql`,
    ...merged,
  ];
}
