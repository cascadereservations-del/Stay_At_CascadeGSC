import { readdirSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export function checkEdgeAuth(root = process.cwd()) {
  const contract = JSON.parse(readFileSync(`${root}/docs/architecture/production-contract.json`, 'utf8'));
  const manifest = JSON.parse(readFileSync(`${root}/docs/architecture/edge-auth-manifest.json`, 'utf8'));
  const local = readdirSync(`${root}/supabase/functions`, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && !entry.name.startsWith('_'))
    .filter((entry) => {
      try { return readFileSync(`${root}/supabase/functions/${entry.name}/index.ts`, 'utf8').length > 0; }
      catch { return false; }
    }).map((entry) => entry.name);
  const expected = new Set([...contract.functions.map((fn) => fn.slug), ...local]);
  const bySlug = new Map(manifest.entries.map((entry) => [entry.slug, entry]));
  const errors = [];

  for (const slug of expected) {
    const entry = bySlug.get(slug);
    if (!entry) { errors.push(`${slug}: missing manifest entry`); continue; }
    if (!['public', 'jwt', 'signed', 'migration_blocked'].includes(entry.mode)) errors.push(`${slug}: invalid mode`);
    if (!Array.isArray(entry.controls) || entry.controls.length === 0) errors.push(`${slug}: compensating controls missing`);
    if (!entry.owner) errors.push(`${slug}: owner missing`);
  }
  for (const slug of bySlug.keys()) if (!expected.has(slug)) errors.push(`${slug}: stale manifest entry`);
  for (const fn of contract.functions) {
    const entry = bySlug.get(fn.slug);
    if (fn.verify_jwt && entry?.mode !== 'jwt') errors.push(`${fn.slug}: deployed JWT setting conflicts with manifest`);
    if (!fn.verify_jwt && entry?.mode === 'jwt') errors.push(`${fn.slug}: manifest relies on JWT but deployment has verification disabled`);
  }
  return { errors, entries: bySlug.size, blocked: manifest.entries.filter((entry) => entry.mode === 'migration_blocked').map((entry) => entry.slug) };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const result = checkEdgeAuth();
  if (result.errors.length) {
    console.error(JSON.stringify({ ok: false, ...result }, null, 2));
    process.exitCode = 1;
  } else {
    console.log(`Edge auth manifest passed: ${result.entries} endpoints; deployment-blocked: ${result.blocked.join(', ') || 'none'}.`);
  }
}
