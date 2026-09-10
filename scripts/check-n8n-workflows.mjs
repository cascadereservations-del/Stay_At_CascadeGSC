import { readFile, readdir } from 'node:fs/promises';

// Validates the n8n workflow exports in automation/n8n/workflows/.
//
// The original version of this script enforced the *stub template* — it required
// every workflow to contain nodes literally named "idempotency" and "callback".
// Real workflows do not look like that: CH-S01 enforces idempotency through the
// outbox's idempotency_key and the server-side claim/ack protocol, and its
// acknowledgement nodes are named "Ack ...", not "callback". CH-W07 makes no
// callback at all, deliberately (D-053) — an n8n failure is exactly the case
// where the outbox path may itself be broken. So both real workflows failed a
// check that was only ever describing a placeholder.
//
// This version enforces what actually matters, and treats stubs as drafts.
//
// Run: node scripts/check-n8n-workflows.mjs

const DIR = 'automation/n8n/workflows';

// Workflows whose provider nodes Lloyd has explicitly approved for sending.
// A provider node enabled in any other export is a hard failure: the standing
// rule is that no provider node goes live without a per-workflow approval, and
// this is where that rule stops being a convention and becomes a gate.
const PROVIDER_SEND_APPROVED = new Map([
  ['CH-S01 Host Alert Router', 'D-053 — Lloyd approved 2026-09-10, proven on fixture 4'],
]);

// The error workflow itself cannot reference an error workflow.
const ERROR_WORKFLOW_ID = 'SAm8geADy5x8hz0y';
const ERROR_WORKFLOW_NAME = 'CH-W07 Error Handler';

const PROVIDER_TYPE = /telegram|whatsapp|gmail|emailSend|slack|twilio|sendGrid/i;
const TRIGGER_TYPE = /trigger|webhook|cron/i;
const SECRET_LIKE = /(api[_-]?key|bearer\s+[A-Za-z0-9._-]{8,}|password|service_role|"token"\s*:\s*"[^"]{8,})/i;

const problems = [];
const fail = (file, message) => problems.push(`${file}: ${message}`);

/** A stub is an unauthored placeholder: the generated "Configuration gate" body. */
const isStub = (nodes) =>
  nodes.some((node) => node.name === 'Configuration gate') &&
  nodes.some((node) => node.name === 'Callback delivery result');

/** Node names reachable by following main connections out of any trigger node. */
function reachableFromTrigger(nodes, connections) {
  const seen = new Set(nodes.filter((n) => TRIGGER_TYPE.test(n.type ?? '')).map((n) => n.name));
  const queue = [...seen];
  while (queue.length > 0) {
    const current = queue.shift();
    for (const branch of connections[current]?.main ?? []) {
      for (const edge of branch ?? []) {
        if (edge?.node && !seen.has(edge.node)) { seen.add(edge.node); queue.push(edge.node); }
      }
    }
  }
  return seen;
}

const files = (await readdir(DIR)).filter((f) => f.endsWith('.json')).sort();
if (files.length === 0) throw new Error(`No n8n workflow exports found in ${DIR}`);

let stubCount = 0;
let realCount = 0;

for (const name of files) {
  const file = `${DIR}/${name}`;
  const raw = await readFile(file, 'utf8');

  // --- Applies to every export, stub or real -------------------------------
  if (SECRET_LIKE.test(raw)) { fail(file, 'possible secret in the export'); continue; }

  let workflow;
  try { workflow = JSON.parse(raw); } catch (error) { fail(file, `invalid JSON — ${error.message}`); continue; }

  if (workflow.active !== false) fail(file, 'must be exported inactive; activation is a deliberate action on the stack, never a repo state');
  if (!workflow.name?.startsWith('CH-')) fail(file, `workflow name ${JSON.stringify(workflow.name)} must start with "CH-"`);

  const nodes = workflow.nodes ?? [];
  const connections = workflow.connections ?? {};
  if (nodes.length === 0) { fail(file, 'no nodes'); continue; }

  const nodeNames = new Set(nodes.map((node) => node.name));
  if (nodeNames.size !== nodes.length) fail(file, 'duplicate node names');

  for (const [from, outputs] of Object.entries(connections)) {
    if (!nodeNames.has(from)) fail(file, `connection source "${from}" does not exist`);
    for (const branch of outputs.main ?? []) {
      for (const edge of branch ?? []) {
        if (!nodeNames.has(edge?.node)) fail(file, `connection target "${edge?.node}" does not exist`);
      }
    }
  }

  if (!nodes.some((node) => TRIGGER_TYPE.test(node.type ?? ''))) fail(file, 'no trigger node — nothing can start this workflow');

  const reachable = reachableFromTrigger(nodes, connections);
  for (const node of nodes) {
    if (!reachable.has(node.name)) fail(file, `node "${node.name}" is unreachable from any trigger`);
  }

  // Guards that predate this rewrite and still hold.
  if (nodes.some((node) => /whatsapp/i.test(node.type ?? '') && /browser|selenium|playwright/i.test(JSON.stringify(node)))) {
    fail(file, 'unsupported WhatsApp browser automation');
  }
  if (nodes.some((node) => /googleCalendar/i.test(node.type ?? '') && /availability|calendar_events/i.test(JSON.stringify(node)))) {
    fail(file, 'Google Calendar must not write availability');
  }

  if (isStub(nodes)) { stubCount += 1; continue; }
  realCount += 1;

  // --- Applies only to authored workflows ----------------------------------

  // Provider sends are the outward-facing risk. Anything not explicitly
  // approved must ship disabled, so importing an export can never start
  // messaging real people.
  const approval = PROVIDER_SEND_APPROVED.get(workflow.name);
  for (const node of nodes) {
    if (!PROVIDER_TYPE.test(node.type ?? '')) continue;
    if (node.disabled !== true && !approval) {
      fail(file, `provider node "${node.name}" (${node.type}) is enabled but ${workflow.name} has no recorded send approval — add it to PROVIDER_SEND_APPROVED with its decision id, or export it disabled`);
    }
  }

  // Every authored workflow routes its failures to CH-W07, which is the whole
  // point of having an error workflow. W07 itself is exempt.
  if (workflow.name !== ERROR_WORKFLOW_NAME) {
    const linked = workflow.settings?.errorWorkflow;
    if (linked !== ERROR_WORKFLOW_ID) {
      fail(file, `settings.errorWorkflow must be "${ERROR_WORKFLOW_ID}" (CH-W07); found ${JSON.stringify(linked)}`);
    }
  }

  // Credentials are referenced by id and name only. A credential object
  // carrying anything else is a literal value that never belongs in the repo.
  for (const node of nodes) {
    for (const [type, credential] of Object.entries(node.credentials ?? {})) {
      if (!credential?.id || !credential?.name) fail(file, `node "${node.name}" credential ${type} must carry both id and name`);
      for (const key of Object.keys(credential ?? {})) {
        if (!['id', 'name'].includes(key)) fail(file, `node "${node.name}" credential ${type} carries unexpected field "${key}"`);
      }
    }
  }
}

if (problems.length > 0) {
  for (const problem of problems) console.error(`  x ${problem}`);
  console.error(`\n${problems.length} problem(s) across ${files.length} export(s).`);
  process.exit(1);
}

console.log(`Validated ${files.length} n8n workflow exports — ${realCount} authored, ${stubCount} still stubs.`);
for (const [name, why] of PROVIDER_SEND_APPROVED) console.log(`  provider sends approved: ${name} (${why})`);
