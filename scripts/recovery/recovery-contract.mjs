import { createHash } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';

const DISPOSABLE_PROJECT = /^cascade-recovery-[a-z0-9]{4,32}$/;

function normalizedSqlHash(source) {
  return createHash('sha256').update(source.replace(/\r\n/g, '\n')).digest('hex');
}

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

export function validateRecoveryBaselineManifest(manifest, { baselineSql, prerequisiteSql, compatibilitySql }) {
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

export function selectRecoveryMigrationFiles(fileNames, forwardFrom) {
  if (!/^\d{14}$/.test(forwardFrom ?? '')) throw new Error('Recovery forward migration boundary is invalid.');
  const migrations = fileNames
    .filter(name => /^\d{14}_.+\.sql$/.test(name))
    .sort((left, right) => left.localeCompare(right));
  if (!migrations.some(name => name.startsWith(`${forwardFrom}_`))) {
    throw new Error(`Recovery forward migration boundary is missing: ${forwardFrom}.`);
  }
  return migrations.filter(name => name.slice(0, 14) >= forwardFrom);
}

export function buildRecoveryMigrationPlan(manifest, sourceMigrationFiles) {
  const forward = selectRecoveryMigrationFiles(sourceMigrationFiles, manifest?.forward_migrations_from);
  return [
    `${manifest.prerequisite_migration_version}_recovery_prerequisites.sql`,
    `${manifest.baseline_migration_version}_recovered_production_baseline.sql`,
    `${manifest.compatibility_migration_version}_pre_forward_compat.sql`,
    ...forward,
  ];
}
