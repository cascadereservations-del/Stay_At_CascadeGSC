// SPEC-06 section 5. Code-checked regressions through the DEPLOYED probe, complementing golden-run.ts.
//   deno run --allow-net --allow-env probe-matrix.ts [--only <id>] [--pause 1500]
//   env: CASCADE_PROBE_URL, CASCADE_PROBE_SECRET
// Sends nothing: the probe stubs every outward effect and deletes its probe: thread. Exit 1 on failure.
//
// WHY THIS IS NOT THE PLAN'S 44 CASES. The plan's matrix was written before the golden set existed.
// golden.ts now holds 39 conversations covering the openers in three registers, the Bisaya ladder, the
// pay branches, the no-model turns and the whole gate group, and golden-run.ts scores them against the
// rubric. Re-listing those here would be two harnesses drifting apart. This file holds ONLY what the
// golden set does not reach, and asserts it as CODE rather than by rubric: slot parsing, the receipt
// turn, time-gap hygiene, address redaction and the correction path.
// ponytail: if a case here ever needs rubric scoring, move it into golden.ts instead of growing this.

const url = Deno.env.get('CASCADE_PROBE_URL') ?? '', secret = Deno.env.get('CASCADE_PROBE_SECRET') ?? '';
if (!url || !secret) { console.error('Set CASCADE_PROBE_URL and CASCADE_PROBE_SECRET.'); Deno.exit(2); }
const arg = (k: string, dflt = '') => { const i = Deno.args.indexOf(k); return i >= 0 ? Deno.args[i + 1] ?? dflt : dflt; };
const only = arg('--only'), pause = Number(arg('--pause', '1500'));
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

type Turn = {
  guest: string; reply: string; step: string | null; flow_lang: string | null; risk: string | null;
  lint: string[]; effects: Array<{ fx: string; [k: string]: unknown }>; ms: number;
};
type Check = (t: Turn[]) => string | null;
type Case = { id: string; turns: Array<string | Record<string, unknown>>; name?: string; checks: Check[] };

// Dates are computed, so the matrix does not rot.
const day = (plus: number) => new Date(Date.now() + plus * 864e5);
const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const md = (x: Date) => `${MON[x.getUTCMonth()]} ${x.getUTCDate()}`;
const IN = md(day(30)), OUT = md(day(32)), IN2 = md(day(35)), OUT2 = md(day(37));

/* Shared checks. Every case asserts lint = [] on every turn: that is the one rule the plan puts on all
   44 cases, and a lint failure is a voice defect wherever it turns up. */
const lintClean: Check = (t) => {
  const bad = t.map((x, i) => (x.lint.length ? `turn ${i + 1} lint ${x.lint.join(',')}` : '')).filter(Boolean);
  return bad.length ? bad.join('; ') : null;
};
const last = (t: Turn[]) => t[t.length - 1];
const replyHas = (re: RegExp, why: string): Check => (t) => (re.test(last(t).reply) ? null : `last reply lacks ${why}`);
const replyLacks = (re: RegExp, why: string): Check => (t) => (re.test(last(t).reply) ? `last reply contains ${why}` : null);
const noEffect = (fx: string): Check => (t) => (last(t).effects.some((e) => e.fx === fx) ? `unexpected ${fx} effect` : null);
const GREETING = /thank you for reaching out|salamat sa pag-message|salamat sa imong pag-message/i;

const CASES: Case[] = [
  // --- Slots: the parsing the golden set never exercises directly -------------------------------
  {
    id: 'slots-pax-bisaya',
    turns: [`Naa bay bakante ${IN} to ${OUT}?`, '3 mi'],
    checks: [lintClean, (t) => (/\b3\b|three|tatlo|tulo/i.test(last(t).reply) ? null : 'pax 3 is not reflected back')],
  },
  {
    id: 'slots-pax-tagalog',
    turns: [`Available po ba ${IN} to ${OUT}?`, 'kaming tatlo'],
    checks: [lintClean, (t) => (/\b3\b|tatlo|three/i.test(last(t).reply) ? null : 'pax 3 is not reflected back')],
  },
  {
    id: 'slots-contact-one-turn',
    turns: [`Is ${IN} to ${OUT} open for 2 adults?`, 'yes please', 'Ben Munez 09171234567 ben@example.com'],
    checks: [
      lintClean,
      (t) => (['confirm', 'await_receipt', 'contact'].includes(last(t).step ?? '') ? null : `step ${last(t).step}`),
    ],
  },

  // --- Correction mid-flow ----------------------------------------------------------------------
  {
    id: 'confirm-correction',
    turns: [`Is ${IN} to ${OUT} open for 2?`, 'yes', `actually make it ${IN2} to ${OUT2}`],
    checks: [lintClean, replyHas(new RegExp(IN2.replace(' ', '\\s')), 'the corrected date')],
  },

  // --- The receipt turn -------------------------------------------------------------------------
  {
    id: 'receipt-image-no-flow',
    turns: [{ image: true }],
    checks: [
      lintClean,
      noEffect('receipt'),
      (t) => (last(t).reply.trim() ? null : 'an image with no open flow got no reply at all'),
    ],
  },

  // --- Follow-up hygiene: the greeting is a function of the GAP, not the turn number -------------
  {
    id: 'hygiene-no-second-greeting',
    turns: ['Hello, do you have wifi?', { text: 'and parking?', advance_minutes: 5 }],
    checks: [lintClean, (t) => (GREETING.test(t[1].reply) ? 'greeted twice 5 minutes apart' : null)],
  },
  {
    id: 'hygiene-greeting-returns-after-hours',
    turns: ['Hello, do you have wifi?', { text: 'hi again, is there parking?', advance_minutes: 420 }],
    checks: [lintClean, (t) => (GREETING.test(t[1].reply) ? null : 'no greeting after a 7 hour gap')],
  },

  // --- Address redaction ------------------------------------------------------------------------
  {
    id: 'address-redacted-before-confirmation',
    turns: ['What is the exact address?'],
    checks: [lintClean, replyLacks(/\b(block|blk\.?)\s*\d+|\blot\s*\d+/i, 'a block or lot number')],
  },
];

const wanted = only ? CASES.filter((c) => c.id === only) : CASES;
if (!wanted.length) { console.error(`No case named ${only}.`); Deno.exit(2); }

console.log(`${wanted.length} cases. Nothing is sent to anyone.\n`);
let failed = 0;
for (const c of wanted) {
  const psid = `probe:${crypto.randomUUID()}`;
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-cascade-probe': secret },
    body: JSON.stringify({ psid, name: c.name ?? 'Ben', turns: c.turns }),
  }).catch((e) => { console.error(`${c.id}: request failed ${e}`); return null; });

  if (!res || !res.ok) { console.log(`FAIL  ${c.id}  HTTP ${res?.status ?? 'none'}`); failed++; await sleep(pause); continue; }
  const body = await res.json();
  const turns: Turn[] = body.turns ?? [];
  if (!turns.length) { console.log(`FAIL  ${c.id}  no turns returned`); failed++; await sleep(pause); continue; }

  const problems = c.checks.map((f) => f(turns)).filter((x): x is string => !!x);
  const ms = turns.reduce((a, t) => a + t.ms, 0);
  if (problems.length) {
    failed++;
    console.log(`FAIL  ${c.id}  (${ms} ms)`);
    for (const p of problems) console.log(`        ${p}`);
    console.log(`        last reply: ${JSON.stringify(last(turns).reply.slice(0, 160))}`);
  } else {
    console.log(`ok    ${c.id}  (${ms} ms)`);
  }
  await sleep(pause);
}

/* Not covered here, and why, so nobody re-derives it: "the 31st bot turn hands off" needs a
   conversation longer than the probe accepts (12 turns, no seed_history). Widening the probe is the
   prerequisite, and that is a change to index.ts, not to this file. */
console.log(`\n${wanted.length - failed}/${wanted.length} passed.`);
if (failed) Deno.exit(1);
