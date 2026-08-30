import { readFileSync, readdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validateMigrationFiles, validateReleaseContract } from './release-safety.mjs';

function option(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : null;
}

export function resolveReleasePath(root, explicit = null) {
  if (explicit) return resolve(explicit);
  const directory = resolve(root, 'supabase', 'releases');
  const matches = readdirSync(directory).filter(name => name.endsWith('.release.json'));
  if (matches.length !== 1) throw new Error(`expected exactly one release contract, found ${matches.length}; pass --release`);
  return resolve(directory, matches[0]);
}

export function verify(root, path) {
  const contract = JSON.parse(readFileSync(path, 'utf8'));
  return {
    contract,
    errors: [...validateReleaseContract(contract), ...validateMigrationFiles(contract, root)],
  };
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
  try {
    const root = resolve(option('--root') ?? process.cwd());
    const path = resolveReleasePath(root, option('--release'));
    const result = verify(root, path);
    if (result.errors.length) {
      for (const error of result.errors) console.error(error);
      process.exitCode = 1;
    } else {
      console.log(JSON.stringify({ ok: true, release_id: result.contract.release_id, phase: result.contract.phase, migrations: result.contract.migrations.length }));
    }
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
