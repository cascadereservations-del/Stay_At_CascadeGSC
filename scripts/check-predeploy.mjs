// Pre-deploy gate for Edge Functions: `deno check` every function about to be released; any failure exits non-zero.
// Reads only, deploys nothing. Run it BEFORE `supabase functions deploy`, with the same slugs:
//   node scripts/check-predeploy.mjs guest-messages telegram-expense     (or --all for every function)
// Why: cascade-ci only type-checks the test files it runs, and functions deploy from this branch, so a function with no
// tests could ship a type error that crashes live (turnover-verifier, 2026-09-22). functions-typecheck.yml does the same
// check on push; this is the local gate that runs before the deploy itself.
import { existsSync, readdirSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'supabase', 'functions');
const all = readdirSync(root).filter((d) => !d.startsWith('_') && statSync(join(root, d)).isDirectory() && existsSync(join(root, d, 'index.ts'))).sort();
const args = process.argv.slice(2);
const slugs = args.includes('--all') ? all : args.filter((a) => !a.startsWith('--'));
if (!slugs.length) { console.error('usage: node scripts/check-predeploy.mjs <slug...> | --all'); process.exit(2); }
const unknown = slugs.filter((s) => !all.includes(s));
if (unknown.length) { console.error(`unknown function(s): ${unknown.join(', ')}`); process.exit(2); }

const failed = [];
for (const s of slugs) {
  const r = spawnSync('deno', ['check', '--no-lock', '--node-modules-dir=auto', join(root, s, 'index.ts')], { encoding: 'utf8' });
  const ok = r.status === 0;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${s}`);
  if (!ok) { failed.push(s); console.error((r.stderr || r.error?.message || '').split('\n').slice(0, 25).join('\n')); }
}
if (failed.length) { console.error(`\ndeno check failed for ${failed.length}: ${failed.join(', ')}. Do not deploy.`); process.exit(1); }
console.log(`\ndeno check passed for ${slugs.length} function(s).`);
