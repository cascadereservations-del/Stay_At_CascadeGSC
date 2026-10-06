// Voice close-out (2026-09-17): runs the golden conversations through the DEPLOYED function's probe and scores them.
//   deno run --allow-net --allow-env --allow-write --allow-read golden-run.ts [--runs 1|3] [--only <group|id>] [--out GOLDEN-RUN.md] [--pause 4000]
//        [--concurrency 4] [--failed-from GOLDEN-RUN-x.md] [--max-convs N] [--budget-usd X]
//   --concurrency N  N conversations in flight at once (default 4; --pause is per worker). Rows still print in case order, then run.
//   --failed-from F  run only the conversations that have any failing (red cross) row in a previous GOLDEN-RUN*.md table (with --only: the overlap).
//                    No file or no failures: exit 0.
//   --max-convs N    stop launching after N conversations and mark the table "(stopped at max-convs)".
//   --budget-usd X   stop launching once the summed cost_usd the probe reports (index.ts runProbe, S74) reaches X; the table says "(stopped at budget-usd)".
//                    Conversations already in flight finish, so the total can pass X by up to --concurrency conversations.
//   The end line and the table header print the total cost and the cache-hit share (cached prompt tokens / prompt tokens).
//   Policy: x1 for routine releases (~USD 1.1 on 3.6-flash); x3 only before voice releases; --failed-from to confirm fixes.
// env: CASCADE_PROBE_URL (the function URL), CASCADE_PROBE_SECRET, optional GOLDEN_BOOKED="Oct 3 to 5", GOLDEN_TURNOVER="Oct 5",
//      GOLDEN_OPEN_FROM="2026-11-02" (first of 15 open nights; without it the open-date cases start at today + 40),
//      GOLDEN_SOON="Sep 20 to 21" (an OPEN one-night stay inside 5 days of check-in; without it the case is skipped).
// Sends nothing to anyone: the probe stubs every outward effect and deletes its probe: thread. Exit 1 on any failure.
import { SITE_URL } from '../_shared/cascade-core/facts.ts';
import { goldenCases } from './golden.ts';
import { failedIds, failures, heldFrom, RUBRIC, scoreReply } from './golden-score.ts';

const arg = (k: string, d = '') => { const i = Deno.args.indexOf(k); return i >= 0 ? Deno.args[i + 1] ?? d : d; };
const url = Deno.env.get('CASCADE_PROBE_URL') ?? '', secret = Deno.env.get('CASCADE_PROBE_SECRET') ?? '';
if (!url || !secret) { console.error('Set CASCADE_PROBE_URL and CASCADE_PROBE_SECRET.'); Deno.exit(2); }
const runs = Number(arg('--runs', '1')) /* one pass by default: 43 calls, USD 0.10 on 2.5-flash (measured 2026-09-24); --runs 3 before a voice release */, only = arg('--only'), pause = Number(arg('--pause', '1500')), outPath = arg('--out'), conc = Math.max(1, Number(arg('--concurrency', '4'))), failedFrom = arg('--failed-from'), maxConvs = Number(arg('--max-convs', '0')), budget = Number(arg('--budget-usd', '0'));
const NAME = 'Ben';
let failedSet: Set<string> | null = null;
if (failedFrom) {
  const ids = failedIds(await Deno.readTextFile(failedFrom).catch(() => ''));
  if (!ids.length) { console.log(`${failedFrom}: missing or no failing conversations; nothing to run.`); Deno.exit(0); }
  failedSet = new Set(ids);
}
/** s73 F8: the calendar's taken nights, from the site's public availability endpoint (read-only), so the promo flow cases pick
 *  open nights or step aside. The publishable key is the site's own (index.html). Unreadable: null, the cases run as before. */
async function bookedNights(): Promise<Set<string> | null> {
  try {
    const key = Deno.env.get('SUPABASE_ANON_KEY') ?? /SUPABASE_ANON\s*=\s*'([^']+)'/.exec(await Deno.readTextFile(new URL('../../../index.html', import.meta.url)))?.[1];
    const res = await fetch(url.replace(/\/functions\/v1\/.*$/, '/functions/v1/availability'), { headers: { apikey: key ?? '', Authorization: `Bearer ${key ?? ''}` } });
    const rows: Array<{ checkin_date: string; checkout_date: string }> = await res.json();
    const out = new Set<string>();
    for (const r of rows) for (let d = r.checkin_date; d < r.checkout_date; d = new Date(Date.parse(d + 'T00:00:00Z') + 86_400_000).toISOString().slice(0, 10)) out.add(d);
    return out;
  } catch (e) { console.warn(`Calendar not read (${String(e).slice(0, 120)}); the promo flow cases keep their fixed nights.`); return null; }
}
let cases = goldenCases(new Date(), Deno.env.get('GOLDEN_BOOKED') ?? null, Deno.env.get('GOLDEN_TURNOVER') ?? null, Deno.env.get('GOLDEN_OPEN_FROM') ? new Date(Deno.env.get('GOLDEN_OPEN_FROM') + 'T00:00:00Z') : null, Deno.env.get('GOLDEN_SOON') ?? null, await bookedNights()).filter((c) => !only || only.split(',').some((o) => c.group === o.trim() || c.id === o.trim())).filter((c) => !failedSet || failedSet.has(c.id)); // --only a,b,c (2026-09-24)
if (failedSet) console.log(`--failed-from: ${cases.length} of ${failedSet.size} failing conversations selected.`);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

type Row = { id: string; ci: number; run: number; turn: number; guest: string; reply: string; fails: string[]; step: string | null; ms: number };
const rows: Row[] = [];
let compactChars = 0, done = 0, cost = 0, cachedTok = 0, inputTok = 0;
console.log(`${cases.length} conversations x ${runs} runs, ${conc} at a time. One line per conversation; nothing is sent to anyone.`);
const jobs = cases.flatMap((c, ci) => Array.from({ length: runs }, (_, k) => ({ c, ci, run: k + 1 })));
let next = 0, stopped = '';
async function conv({ c, ci, run }: (typeof jobs)[number]) {
  const res = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-cascade-probe': secret },
    body: JSON.stringify({ psid: `probe:${crypto.randomUUID()}`, name: NAME, golden: true, turns: c.turns.map((t) => (t.image || t.advance_minutes ? { text: t.say || undefined, image: t.image, advance_minutes: t.advance_minutes } : t.say)) }) });
  const j = await res.json().catch(() => null);
  if (!res.ok || !j?.ok) { rows.push({ id: c.id, ci, run, turn: 0, guest: '-', reply: '', fails: [`probe failed: HTTP ${res.status} ${JSON.stringify(j).slice(0, 200)}`], step: null, ms: 0 }); return; }
  compactChars = j.voice_compact_chars; cost += Number(j.cost_usd) || 0; cachedTok += Number(j.cached_tokens) || 0; inputTok += Number(j.input_tokens) || 0;
  let prev: string | null = null;
  const said: string[] = [], mine: Row[] = [];
  for (const [i, t] of c.turns.entries()) {
    const got = j.turns[i] ?? { reply: '', step: null, ms: 0 };
    said.push(t.say);
    const score = scoreReply({ guest: t.say, reply: got.reply, prevReply: prev, kind: t.kind, lang: t.lang, firstTurn: i === 0, siteUrl: SITE_URL, name: NAME,
      held: heldFrom(said, NAME), noInvite: t.noInvite, guestUsedPo: /\bpo\b/i.test(t.say), must: t.must, mustNot: t.mustNot,
      effects: t.effects, effectsText: JSON.stringify(got.effects ?? []) });
    mine.push({ id: c.id, ci, run, turn: i + 1, guest: t.say, reply: got.reply, fails: failures(score), step: got.step, ms: got.ms });
    prev = got.reply;
  }
  rows.push(...mine);
  const bad = mine.filter((r) => r.fails.length).length;
  console.log(`[${++done}/${jobs.length}] ${c.id} run ${run}: ${bad ? bad + ' failing repl' + (bad > 1 ? 'ies' : 'y') : 'ok'}`);
}
async function worker() {
  while (next < jobs.length && !stopped) {
    if (maxConvs && next >= maxConvs) { stopped = 'max-convs'; break; }
    if (budget && cost >= budget) { stopped = 'budget-usd'; break; }
    await conv(jobs[next++]);
    await sleep(pause); // free-tier pacing, per worker
  }
}
await Promise.all(Array.from({ length: Math.min(conc, jobs.length) }, worker));
rows.sort((a, b) => a.ci - b.ci || a.run - b.run); // stable: turns stay in order; the table does not depend on which worker finished first
if (stopped) { cases = cases.filter((c) => rows.some((r) => r.id === c.id)); console.log(`Stopped at --${stopped} ${stopped === 'budget-usd' ? budget : maxConvs}: ${done} of ${jobs.length} conversations ran.`); }
const spend = `cost USD ${cost.toFixed(4)} · cache hit ${inputTok ? Math.round(100 * cachedTok / inputTok) : 0}% (${cachedTok} of ${inputTok} prompt tokens)`;

const caseOk = (id: string) => rows.filter((r) => r.id === id).every((r) => !r.fails.length);
const passed = cases.filter((c) => caseOk(c.id)).length;
const byRule = Object.fromEntries(RUBRIC.map((k) => [k, rows.filter((r) => r.fails.some((f) => f.startsWith(k + ':'))).length]));
const cell = (s: string) => s.replace(/\|/g, '\\|').replace(/\n/g, '<br>');
const md = [
  `# Golden run ${new Date().toISOString().slice(0, 16)}Z${stopped ? ` (stopped at ${stopped})` : ''}`, '',
  `**${passed} / ${cases.length} conversations pass ×${runs}${stopped ? ` (stopped at ${stopped} ${stopped === 'budget-usd' ? budget : maxConvs})` : ''}** · ${spend} · follow-up prompt ${compactChars} chars · failing replies by rule: ${RUBRIC.map((k) => `${k} ${byRule[k]}`).join(' · ')}`, '',
  '| Conversation | Run | Turn | Guest | Reply | Result |', '|---|---|---|---|---|---|',
  ...rows.map((r) => `| ${r.id} | ${r.run} | ${r.turn} | ${cell(r.guest)} | ${cell(r.reply)} | ${r.fails.length ? '❌ ' + cell(r.fails.join('; ')) : '✅'} |`),
].join('\n');
if (outPath) await Deno.writeTextFile(outPath, md);
console.log(outPath ? `${passed}/${cases.length} pass x${runs}; ${spend}; table written to ${outPath}` : md);
for (const [k, n] of Object.entries(byRule)) if (n) console.log(`${k}: ${n} failing replies`);
Deno.exit(passed === cases.length ? 0 : 1);
