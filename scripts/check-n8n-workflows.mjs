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
  if (!workflow.connections || Object.keys(workflow.connections).length === 0) throw new Error(`${file}: disconnected workflow graph`);
  const nodeNames = new Set(nodes.map((node) => node.name));
  const incoming = new Set();
  const outgoing = new Set();
  for (const [from, outputs] of Object.entries(workflow.connections)) {
    if (!nodeNames.has(from)) throw new Error(`${file}: connection source ${from} does not exist`);
    for (const branch of outputs.main ?? []) for (const edge of branch ?? []) {
      if (!nodeNames.has(edge.node)) throw new Error(`${file}: connection target ${edge.node} does not exist`);
      outgoing.add(from); incoming.add(edge.node);
    }
  }
  for (const node of nodes) {
    const trigger = /trigger|webhook|cron/i.test(node.type ?? '');
    if (!trigger && !incoming.has(node.name)) throw new Error(`${file}: ${node.name} is disconnected from input`);
    if (!/callback/i.test(node.name ?? '') && !outgoing.has(node.name)) throw new Error(`${file}: ${node.name} is disconnected from output`);
  }
  if (nodes.some((node) => /whatsapp/i.test(node.type ?? '') && /browser|selenium|playwright/i.test(JSON.stringify(node)))) throw new Error(`${file}: unsupported WhatsApp browser automation`);
  if (nodes.some((node) => /googlecalendar/i.test(node.type ?? '') && /availability|calendar_events/i.test(JSON.stringify(node)))) throw new Error(`${file}: Google Calendar must not write availability`);
}
console.log(`Validated ${files.length} inactive n8n workflow exports.`);
