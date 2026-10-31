// Rewrites the generated VALUES block of the s106 migration from shopsuki-capture.json (no hand-typed values).
// Usage: node docs/s106/gen-item-options-seed.mjs
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const migration = join(here, '..', '..', 'supabase', 'migrations', '20261109000000_s106_item_options.sql');
const ids = {
  'Natural Air': '66c7ec14-b20c-450d-9576-492c56e6d1c1',
  'Tea': '73757510-887b-4a5c-a54b-ab65505392aa',
  'Tissues / Paper Towels': '4f139d96-f1fa-4be6-bbf2-a593a5383202',
  'Liquid Hand Soap (Safeguard)': '0bdd783a-77f8-4211-bf53-e1cbebcc284b',
  'Breeze Fabric Conditioner Liquid': 'e79e4de3-7bfa-4d9d-845c-58f5e038ce03',
  'Garbage Bags (Small)': 'ae72de9a-871d-43ea-b07a-0fd9427bfc9c',
  'Lysol Disinfectant Spray': '691e93b7-0e99-44eb-b1dd-adb70ddd7f9c',
  'Mr Muscle Glass Cleaner (Blue)': '744dcd36-f1b5-4ed9-b8b4-e2564d02675e',
  'Liquid Body Soap (Dove)': '3179e10e-105f-47eb-8955-c2c2111948f8',
  'Ambi Pur': '58d951d1-1455-4157-9820-6b15d02309ff',
  'Garbage Bags (Large)': '360a6b10-c8a7-42e1-885e-98d98f382775',
  'Mr Muscle Mold & Mildew (Orange)': '2137c758-5b95-46d6-8810-2364100b2dda',
  'Baygon Spray': '513ffc56-3f9d-4e58-a061-3747d7c31189',
  'Bottled Water': 'c44552af-014b-46fd-a489-50695ecd465d',
  'Coffee (3-in-1)': 'da50acdc-1107-4574-ac9e-f2ecd951ed5a',
  'Sugar & Creamer Sticks': '837afa3f-ace3-4e30-bc70-c9bc2c90e92c',
  'Shampoo (Palmolive)': 'dfb24285-06a5-4e6d-9e6c-a24b23e73bc8',
  'Dishwashing Liquid (Joy)': '2bfc792f-9520-4ae1-8b20-dd5afa4a2ab5',
  'Toiletries (toothbrush, toothpaste, soap)': '2ec811c2-4ccc-4885-a8a5-3a8002e791b0',
};
const q = (s) => (s == null || s === '' ? 'null' : `'${String(s).replace(/'/g, "''")}'`);
const rows = JSON.parse(readFileSync(join(here, 'shopsuki-capture.json'), 'utf8')).rows;
if (rows.length !== 64) throw new Error(`expected 64 rows, got ${rows.length}`);
const lines = rows.map(([item, usual, title, brand, price, avail, image, handle, pack]) => {
  if (!ids[item]) throw new Error(`no item id for ${item}`);
  if (!/^\d+(\.\d{1,2})?$/.test(price)) throw new Error(`bad price ${price}`);
  return `    ('${ids[item]}'::uuid, ${usual ? 'true' : 'false'}, ${q(title)}, ${q(brand)}, ${price}::numeric, ${avail ? 'true' : 'false'}, ${q(image)}, ${q(handle)}, ${pack == null ? "null" : Number(pack)}::numeric)`;
});
const sql = readFileSync(migration, 'utf8');
const re = /(-- BEGIN GENERATED[^\n]*\n)[\s\S]*?(\n\s*-- END GENERATED)/;
if (!re.test(sql)) throw new Error('markers not found');
writeFileSync(migration, sql.replace(re, (_, a, b) => a + lines.join(',\n') + b));
console.log(`wrote ${lines.length} rows`);
