import { readFile, readdir } from 'node:fs/promises';

const files = (await readdir('automation/n8n/workflows')).filter((file) => file.endsWith('.json')).map((file) => `automation/n8n/workflows/${file}`);
if (files.length === 0) throw new Error('No n8n workflow exports found.');
for (const file of files) {
  const raw = await readFile(file, 'utf8');
  if (/(api[_-]?key|bearer\s+|password|service_role|token)\s*[:=]/i.test(raw)) throw new Error(`${file}: possible secret`);
  const workflow = JSON.parse(raw);
  if (workflow.active !== false) throw new Error(`${file}: must be inactive on import`);
  if (!workflow.name?.startsWith('CH-')) throw new Error(`${file}: invalid workflow name`);
  const nodes = workflow.nodes ?? [];
  if (!nodes.some((node) => /idempotency/i.test(node.name ?? ''))) throw new Error(`${file}: missing idempotency node`);
  if (!nodes.some((node) => /callback/i.test(node.name ?? ''))) throw new Error(`${file}: missing callback node`);
  if (nodes.some((node) => /whatsapp/i.test(node.type ?? '') && /browser|selenium|playwright/i.test(JSON.stringify(node)))) throw new Error(`${file}: unsupported WhatsApp browser automation`);
  if (nodes.some((node) => /googlecalendar/i.test(node.type ?? '') && /availability|calendar_events/i.test(JSON.stringify(node)))) throw new Error(`${file}: Google Calendar must not write availability`);
}
console.log(`Validated ${files.length} inactive n8n workflow exports.`);
