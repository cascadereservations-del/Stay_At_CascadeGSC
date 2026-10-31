// Rewrites the generated blocks of the s107 migration and pgTAP test from preferred-picks.json (no hand-typed values), and prints the md5 of the s106
// function bodies the migration guards on (prosrc = text between the $$ delimiters, CR removed).
// Usage: node docs/s107/gen-preferred-picks.mjs [--md5]
import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..');
const mig = join(root, 'supabase', 'migrations', '20261110000000_s107_preferred_picks.sql');
const test = join(root, 'supabase', 'tests', 'database', 's107_preferred_picks.sql');
const s106 = readFileSync(join(root, 'supabase', 'migrations', '20261109000000_s106_item_options.sql'), 'utf8').replace(/\r/g, '');

if (process.argv.includes('--md5')) {
  for (const fn of ['inventory_item_options_v1', 'inventory_item_option_set_usual_v1']) {
    const start = s106.indexOf(`create or replace function public.${fn}(`);
    const a = s106.indexOf('$$', start) + 2;
    const b = s106.indexOf('$$', a);
    console.log(fn, createHash('md5').update(s106.slice(a, b), 'utf8').digest('hex'));
  }
  process.exit(0);
}

const ids = {
  'Natural Air': '66c7ec14-b20c-450d-9576-492c56e6d1c1',
  'Baygon Spray': '513ffc56-3f9d-4e58-a061-3747d7c31189',
  'Breeze Fabric Conditioner Liquid': 'e79e4de3-7bfa-4d9d-845c-58f5e038ce03',
  'Liquid Hand Soap (Safeguard)': '0bdd783a-77f8-4211-bf53-e1cbebcc284b',
  'Liquid Body Soap (Dove)': '3179e10e-105f-47eb-8955-c2c2111948f8',
  'Mr Muscle Mold & Mildew (Orange)': '2137c758-5b95-46d6-8810-2364100b2dda',
  'Toiletries (toothbrush, toothpaste, soap)': '2ec811c2-4ccc-4885-a8a5-3a8002e791b0',
  'Coffee (3-in-1)': 'da50acdc-1107-4574-ac9e-f2ecd951ed5a',
  'Shampoo (Palmolive)': 'dfb24285-06a5-4e6d-9e6c-a24b23e73bc8',
  'Tissues / Paper Towels': '4f139d96-f1fa-4be6-bbf2-a593a5383202',
  'All-Purpose Cleaner (Mr Muscle)': null, // created by the data function; matched by name
};
const q = (s) => (s == null || s === '' ? 'null' : `'${String(s).replace(/'/g, "''")}'`);
const picks = JSON.parse(readFileSync(join(here, 'preferred-picks.json'), 'utf8')).picks;
if (picks.length !== 19) throw new Error(`expected 19 picks, got ${picks.length}`);
const rows = picks.map(([item, order, store, title, brand, price, avail, image, url, pack]) => {
  if (!(item in ids)) throw new Error(`no item id for ${item}`);
  if (!/^\d+(\.\d{1,2})?$/.test(price)) throw new Error(`bad price ${price}`);
  if (store !== 'shopsuki' && store !== 'shopee') throw new Error(`bad store ${store}`);
  return { item, id: ids[item], order, store, title, brand, price, avail, image, url, pack };
});
const picksSql = rows.map((r) => `    (${r.id ? `'${r.id}'::uuid` : 'null::uuid'}, ${q(r.item)}, ${r.order}, ${q(r.store)}, ${q(r.title)}, ${q(r.brand)}, ${r.price}::numeric, ${r.avail ? 'true' : 'false'}, ${q(r.image)}, ${q(r.url)}, ${r.pack == null ? 'null' : Number(r.pack)}::numeric)`).join(',\n');
const expSql = rows.filter((r) => r.order === 1).map((r) => `    (${r.id ? `'${r.id}'::uuid` : 'null::uuid'}, ${q(r.item)}, ${q(r.url)}, ${q(r.store)}, ${r.price}::numeric)`).join(',\n');
const allSql = rows.map((r) => `    (${r.id ? `'${r.id}'::uuid` : 'null::uuid'}, ${q(r.item)}, ${q(r.url)})`).join(',\n');

function fill(file, tag, body) {
  const sql = readFileSync(file, 'utf8');
  const re = new RegExp(String.raw`(-- BEGIN GENERATED ${tag}[^\n]*\r?\n)[\s\S]*?(\s*-- END GENERATED ${tag})`);
  if (!re.test(sql)) throw new Error(`markers ${tag} not found in ${file}`);
  writeFileSync(file, sql.replace(re, (_, a, b) => a + body + '\n    ' + b.trimStart()));
}
fill(mig, 'picks', picksSql);
fill(test, 'usual', expSql);
fill(test, 'all', allSql);
console.log('ok', rows.length, 'picks');
