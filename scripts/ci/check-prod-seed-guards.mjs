// Static guard for the disposable recovery database (it has no production rows): a forward migration's top-level
// `insert into public.<t>` that names the production property or reads an owner out of staff_access_profiles must be
// guarded by `exists (select 1 from public.properties ...)`, or be listed in baseline.json recovery_statement_omissions
// (or sit in an excluded migration). Statements inside function bodies and DO blocks are dollar-quoted and ignored.
import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const PROPERTY_ID = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';

// Splits SQL into top-level statements. Returns [{ raw, code }]: raw keeps comments, code has comments blanked and
// every string / dollar-quoted body replaced by spaces of equal length except that quoted text is kept in `literal`.
export function splitStatements(sql) {
  const out = [];
  let raw = '';
  let code = '';
  let i = 0;
  const n = sql.length;
  const push = (text, keepCode) => { raw += text; code += keepCode ? text : text.replace(/[^\n]/g, ' '); };
  while (i < n) {
    const c = sql[i];
    if (c === '-' && sql[i + 1] === '-') {
      let j = sql.indexOf('\n', i);
      if (j < 0) j = n;
      push(sql.slice(i, j), false);
      i = j;
    } else if (c === '/' && sql[i + 1] === '*') {
      let j = sql.indexOf('*/', i + 2);
      j = j < 0 ? n : j + 2;
      push(sql.slice(i, j), false);
      i = j;
    } else if (c === "'") {
      let j = i + 1;
      while (j < n) {
        if (sql[j] === "'") { if (sql[j + 1] === "'") { j += 2; continue; } break; }
        j += 1;
      }
      // Literals are kept in `code` so a property id inside a literal still counts as naming the property.
      push(sql.slice(i, j + 1), true);
      i = j + 1;
    } else if (c === '$') {
      const tag = /^\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$/.exec(sql.slice(i, i + 40));
      if (tag) {
        let j = sql.indexOf(tag[0], i + tag[0].length);
        j = j < 0 ? n : j + tag[0].length;
        // A dollar-quoted body is opaque: blanked out of `code`, so statements inside it are never inspected.
        push(sql.slice(i, j), false);
        i = j;
      } else { push(c, true); i += 1; }
    } else if (c === ';') {
      raw += c; code += c;
      out.push({ raw, code });
      raw = ''; code = '';
      i += 1;
    } else { push(c, true); i += 1; }
  }
  if (raw.trim()) out.push({ raw, code });
  return out;
}

const INSERT_RE = /^\s*insert\s+into\s+public\.[a-z_][a-z0-9_]*/i;
const GUARD_RE = /(?<!not\s+)exists\s*\(\s*select\s+1\s+from\s+public\.properties\b[^;]*?6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/i;

// Returns the unguarded production-seed statements of one migration as [{ firstLine, text }].
export function findUnguardedSeeds(sql) {
  const found = [];
  for (const { raw, code } of splitStatements(sql)) {
    if (!INSERT_RE.test(code)) continue;
    const touchesProduction = code.toLowerCase().includes(PROPERTY_ID) || /staff_access_profiles\b[^;]*\brole\b/i.test(code);
    if (!touchesProduction || GUARD_RE.test(code)) continue;
    const firstLine = raw.split('\n').map(line => line.replace(/\r$/, '')).find(line => INSERT_RE.test(line)) ?? '';
    found.push({ firstLine, text: raw.trim() });
  }
  return found;
}

// files: [{ name, sql }]; omissions: manifest.recovery_statement_omissions. Returns [{ file, firstLine }] violations.
export function checkProdSeedGuards(files, manifest) {
  const floor = manifest.forward_migrations_from;
  const excluded = new Set(manifest.recovery_excluded_migrations ?? []);
  const omissions = manifest.recovery_statement_omissions ?? {};
  const violations = [];
  for (const { name, sql } of files) {
    if (name.slice(0, 14) < floor || excluded.has(name)) continue;
    const listed = new Set((omissions[name] ?? []).map(entry => entry.first_line));
    for (const seed of findUnguardedSeeds(sql)) {
      if (!listed.has(seed.firstLine)) violations.push({ file: name, firstLine: seed.firstLine });
    }
  }
  return violations;
}

export function loadMigrationFiles(sourceSupabase = path.join(repoRoot, 'supabase')) {
  const directory = path.join(sourceSupabase, 'migrations');
  return readdirSync(directory).filter(name => /^\d{14}_.+\.sql$/.test(name)).sort()
    .map(name => ({ name, sql: readFileSync(path.join(directory, name), 'utf8') }));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const sourceSupabase = path.join(repoRoot, 'supabase');
  const manifest = JSON.parse(readFileSync(path.join(sourceSupabase, 'recovery', 'baseline.json'), 'utf8'));
  const violations = checkProdSeedGuards(loadMigrationFiles(sourceSupabase), manifest);
  if (violations.length) {
    for (const v of violations) {
      process.stderr.write(`${v.file}: unguarded production seed "${v.firstLine}" (guard it with exists (select 1 from public.properties ...) or list it in recovery_statement_omissions)\n`);
    }
    process.exitCode = 1;
  } else {
    process.stdout.write('check-prod-seed-guards: 0 unguarded production seeds\n');
  }
}
