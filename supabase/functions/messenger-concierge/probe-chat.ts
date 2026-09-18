// Type your own conversation at the DEPLOYED Concierge on a fresh thread and read what it answers (Lloyd 2026-09-18:
// "simulate the environment for first time messenger and follow up messages"). The live thread carries months of test
// turns and the model copies them, so a live read there measures the history, not the bot.
//   deno run --allow-net --allow-env probe-chat.ts "Hi, is Nov 17 to 19 available? 2 adults" ["and is there wifi?" ...]
//   --gap 3        minutes between turns (default 3: a follow-up. Over 360 = a new first contact, protocol's own rule)
//   --name Ben     the Facebook first name (--name "" for a guest whose name we do not hold)
//   --lang en|tl|bis, --score   score each reply with the golden rubric
//   --json         raw JSON instead of the readable transcript
// env: CASCADE_PROBE_URL (defaults to the Cascade function URL), CASCADE_PROBE_SECRET.
// Sends nothing to anyone: every outward effect is recorded, and the probe: thread is deleted on the next run.
import { SITE_URL } from '../_shared/cascade-core/facts.ts';
import { failures, heldFrom, type Reg, scoreReply } from './golden-score.ts';

const args = [...Deno.args];
const opt = (k: string, d = '') => { const i = args.indexOf(k); if (i < 0) return d; const v = args[i + 1] ?? d; args.splice(i, 2); return v; };
const flag = (k: string) => { const i = args.indexOf(k); if (i < 0) return false; args.splice(i, 1); return true; };
const gap = Number(opt('--gap', '3')), name = opt('--name', 'Ben'), lang = opt('--lang', 'en') as Reg;
const score = flag('--score'), raw = flag('--json');
const turns = args.filter((a) => !a.startsWith('--'));
const url = Deno.env.get('CASCADE_PROBE_URL') ?? 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/messenger-concierge';
const secret = Deno.env.get('CASCADE_PROBE_SECRET') ?? '';
if (!turns.length || !secret) {
  console.error(turns.length ? 'Set CASCADE_PROBE_SECRET.' : 'Give at least one message, e.g. probe-chat.ts "Hi, is Nov 17 to 19 available? 2 adults"');
  Deno.exit(2);
}

const res = await fetch(url, {
  method: 'POST', headers: { 'Content-Type': 'application/json', 'x-cascade-probe': secret },
  body: JSON.stringify({ psid: `probe:${crypto.randomUUID()}`, name: name || null, turns: turns.map((t) => ({ text: t, advance_minutes: gap })) }),
});
const j = await res.json().catch(() => null) as { ok?: boolean; turns?: Array<Record<string, any>>; error?: string } | null;
if (!res.ok || !j?.ok) { console.error(`probe failed: HTTP ${res.status} ${JSON.stringify(j).slice(0, 300)}`); Deno.exit(1); }
if (raw) { console.log(JSON.stringify(j, null, 2)); Deno.exit(0); }

console.log(`Fresh thread · name ${name || '(unknown)'} · ${gap} min between turns${gap > 360 ? ' (each turn reads as a new first contact)' : ''}\n`);
const said: string[] = [];
let prev: string | null = null;
for (const [i, t] of (j.turns ?? []).entries()) {
  said.push(turns[i]);
  console.log(`GUEST: ${turns[i]}`);
  console.log(`CASSY: ${t.reply || '(nothing sent)'}`);
  const meta = [t.step && `step ${t.step}`, t.risk && t.risk !== 'routine' && `risk ${t.risk}`, t.lint?.length && `lint ${t.lint.join(', ')}`,
    t.effects?.length && `effects ${t.effects.map((e: any) => e.fx).join(', ')}`, `${t.ms} ms`].filter(Boolean);
  if (score) {
    const s = scoreReply({ guest: turns[i], reply: t.reply, prevReply: prev, kind: t.step ? 'flow' : 'model', lang, firstTurn: i === 0, siteUrl: SITE_URL,
      name: name || null, held: heldFrom(said, name || null), guestUsedPo: /\bpo\b/i.test(turns[i]) });
    const bad = failures(s);
    meta.push(bad.length ? `FAILS ${bad.join('; ')}` : 'rubric ok');
  }
  console.log(`       [${meta.join(' · ')}]\n`);
  prev = t.reply;
}
