// Stamp the newest COMPLETE backup set into release contracts right before an apply.
// Refuses a set older than 60 minutes (the contracts' "restore point is older than one hour" stop condition).
// Usage: node scripts/migrations/fill-restore-point.mjs <backup-root> <release.json> [...]
import { readdirSync, readFileSync, statSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const [root, ...releases] = process.argv.slice(2);
if (!root || releases.length === 0) { console.error('usage: fill-restore-point.mjs <backup-root> <release.json> [...]'); process.exit(2); }
const sets = readdirSync(root).filter((n) => /^cascade-supabase-\d{8}T\d{6}Z$/.test(n) && existsSync(join(root, n, 'COMPLETE'))).sort();
const name = sets.at(-1);
if (!name) { console.error('no COMPLETE backup set'); process.exit(3); }
const m = name.match(/(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/);
const takenAt = new Date(`${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:${m[6]}Z`);
const ageMin = (Date.now() - takenAt.getTime()) / 60000;
if (ageMin > 60 || ageMin < -5) { console.error(`newest set ${name} is ${ageMin.toFixed(0)} min old - take a fresh backup`); process.exit(4); }
const verifiedAt = statSync(join(root, name, 'COMPLETE')).mtime.toISOString();
for (const f of releases) {
  const raw = readFileSync(f, 'utf8');
  const c = JSON.parse(raw);
  c.backup.restore_point = `C:/Cascade-Backups/${name}`;
  c.backup.verified_at = verifiedAt;
  writeFileSync(f, JSON.stringify(c, null, 2) + (raw.endsWith('\n') ? '\n' : ''));
  console.log(`${f}: restore_point ${name} (${ageMin.toFixed(0)} min old)`);
}
