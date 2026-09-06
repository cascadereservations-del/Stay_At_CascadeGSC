// Compare an n8n workflow export directory with the reviewed source and print
// the semantic SHA-256. Usage:
//   node infrastructure/cascade-n8n/p4/semantic-compare.mjs --source automation/n8n/workflows --export <dir>
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { compareWorkflowSets, inventoryWorkflowFiles } from '../../../scripts/recovery/recovery-contract.mjs';

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) => {
  if (a.startsWith('--')) acc.push([a.slice(2), all[i + 1]]);
  return acc;
}, []));
if (!args.source || !args.export) {
  console.error('Usage: --source <dir> --export <dir>');
  process.exit(2);
}
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const expected = await inventoryWorkflowFiles(path.resolve(repoRoot, args.source));
const actual = await inventoryWorkflowFiles(path.resolve(args.export));
const result = compareWorkflowSets(expected, actual);
console.log(JSON.stringify({ count: result.count, semantic_sha256: result.semantic_sha256 }));
