// Voice close-out (2026-09-17): runs the golden conversations through the DEPLOYED function's probe and scores them.
//   deno run --allow-net --allow-env --allow-write golden-run.ts [--runs 3] [--only <group|id>] [--out GOLDEN-RUN.md] [--pause 4000]
// env: CASCADE_PROBE_URL (the function URL), CASCADE_PROBE_SECRET, optional GOLDEN_BOOKED="Oct 3 to 5".
// Sends nothing to anyone: the probe stubs every outward effect and deletes its probe: thread. Exit 1 on any failure.
import { SITE_URL } from '../_shared/cascade-core/facts.ts';
import { goldenCases } from './golden.ts';
import { failures, heldFrom, RUBRIC, scoreReply } from './golden-score.ts';

const arg = (k: string, d = '') => { const i = Deno.args.indexOf(k); return i >= 0 ? Deno.args[i + 1] ?? d : d; };
const url = Deno.env.get('CASCADE_PROBE_URL') ?? '', secret = Deno.env.get('CASCADE_PROBE_SECRET') ?? '';
if (!url || !secret) { console.error('Set CASCADE_PROBE_URL and CASCADE_PROBE_SECRET.'); Deno.exit(2); }
const runs = Number(arg('--runs', '3')), only = arg('--only'), pause = Number(arg('--pause', '4000')), outPath = arg('--out');
const NAME = 'Ben';
const cases = goldenCases(new Date(), Deno.env.get('GOLDEN_BOOKED') ?? null).filter((c) => !only || c.group === only || c.id === only);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

type Row = { id: string; run: number; turn: number; guest: string; reply: string; fails: string[]; step: string | null; ms: number };
const rows: Row[] = [];
let compactChars = 0;
for (const c of cases) {
  for (let run = 1; run <= runs; run++) {
    const res = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-cascade-probe': secret },
      body: JSON.stringify({ psid: `probe:${crypto.randomUUID()}`, name: NAME, turns: c.turns.map((t) => (t.image ? { text: t.say, image: true } : t.say)) }) });
    const j = await res.json().catch(() => null);
    if (!res.ok || !j?.ok) { rows.push({ id: c.id, run, turn: 0, guest: '-', reply: '', fails: [`probe failed: HTTP ${res.status} ${JSON.stringify(j).slice(0, 200)}`], step: null, ms: 0 }); continue; }
    compactChars = j.voice_compact_chars;
    let prev: string | null = null;
    const said: string[] = [];
    for (const [i, t] of c.turns.entries()) {
      const got = j.turns[i] ?? { reply: '', step: null, ms: 0 };
      said.push(t.say);
      const score = scoreReply({ guest: t.say, reply: got.reply, prevReply: prev, kind: t.kind, lang: t.lang, firstTurn: i === 0, siteUrl: SITE_URL, name: NAME,
        held: heldFrom(said, NAME), noInvite: t.noInvite, guestUsedPo: /\bpo\b/i.test(t.say), must: t.must, mustNot: t.mustNot });
      rows.push({ id: c.id, run, turn: i + 1, guest: t.say, reply: got.reply, fails: failures(score), step: got.step, ms: got.ms });
      prev = got.reply;
    }
    await sleep(pause); // free-tier pacing
  }
}

const caseOk = (id: string) => rows.filter((r) => r.id === id).every((r) => !r.fails.length);
const passed = cases.filter((c) => caseOk(c.id)).length;
const byRule = Object.fromEntries(RUBRIC.map((k) => [k, rows.filter((r) => r.fails.some((f) => f.startsWith(k + ':'))).length]));
const cell = (s: string) => s.replace(/\|/g, '\\|').replace(/\n/g, '<br>');
const md = [
  `# Golden run ${new Date().toISOString().slice(0, 16)}Z`, '',
  `**${passed} / ${cases.length} conversations pass ×${runs}** · follow-up prompt ${compactChars} chars · failing replies by rule: ${RUBRIC.map((k) => `${k} ${byRule[k]}`).join(' · ')}`, '',
  '| Conversation | Run | Turn | Guest | Reply | Result |', '|---|---|---|---|---|---|',
  ...rows.map((r) => `| ${r.id} | ${r.run} | ${r.turn} | ${cell(r.guest)} | ${cell(r.reply)} | ${r.fails.length ? '❌ ' + cell(r.fails.join('; ')) : '✅'} |`),
].join('\n');
if (outPath) await Deno.writeTextFile(outPath, md);
console.log(outPath ? `${passed}/${cases.length} pass x${runs}; table written to ${outPath}` : md);
for (const [k, n] of Object.entries(byRule)) if (n) console.log(`${k}: ${n} failing replies`);
Deno.exit(passed === cases.length ? 0 : 1);
