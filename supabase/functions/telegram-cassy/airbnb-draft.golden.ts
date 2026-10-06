// SPEC-39 section 6: the smart golden test for Marifel's Airbnb register. Calls the draft prompt directly (modelDraft) on six
// synthetic guests, three runs each, and scores every draft with airbnbTone plus the case's own checks. Nothing is sent to
// anyone and no Messenger or Telegram call is made.
//   deno run --allow-net --allow-env telegram-cassy/airbnb-draft.golden.ts [--runs 3]
// env: CASCADE_OPENROUTER_PROBE_KEY (the probe budget, never the guests', D-254). The rate card and contact fall back to the
// seed values (no database is opened). Pass bar: 18/18. Exit 1 on any failure.
import { setProviderKey } from '../_shared/cascade-core/providers.ts';
import { classify } from '../messenger-concierge/policy.ts';
import { airbnbTone, calmMoment, modelDraft } from './draft.ts';

type Case = { id: string; guest: string; name: string; must: RegExp[]; mustNot: RegExp[] };
const SIGNED = /Marifel & The Cascade Team\s*\n\s*Hotel Comfort\. Home Warmth\.\s*$/, OFF = /https?:\/\/|\bgcash\b|\bqr\b|(?:\+63|\b0)9\d{2}[\s-]?\d{3}/i;
export const CASES: Case[] = [
  { id: 'inquiry-tl', guest: 'Available po ba Oct 20-22? 2 kami', name: 'Dale', must: [/^Hi \w+!/, /\bpo\b/, SIGNED], mustNot: [OFF] },
  { id: 'inquiry-en', guest: 'Is Oct 20-22 free for 2?', name: 'Emma', must: [/^Hi \w+!/, SIGNED], mustNot: [/\bpo\b/, OFF] },
  { id: 'complaint-calm', guest: "The aircon stopped working, it's so hot", name: 'Mark', must: [/sorry|understand/i, SIGNED], mustNot: [/!/, /[\p{Extended_Pictographic}]/u] },
  { id: 'our-mistake-calm', guest: "I don't have to check out today do I", name: 'Joseph', must: [/check|confirm|(?:don'?t|do not) (?:need|have) to|no need to/i, /understanding/i, SIGNED], mustNot: [/!/, /\b(?:is|are) (?:indeed )?(?:scheduled|set) for (?:today|tomorrow)|\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.? \d{1,2}/i] }, // s74: no booking data, so no asserted date
  { id: 'discount-ask', guest: 'Can you give a discount for 5 nights?', name: 'Ana', must: [/check|listing|confirm/i, SIGNED], mustNot: [/discount of|we can offer|PHP \d|₱\d/i] },
  { id: 'late-checkout-ask', guest: 'Can we check out at 3 PM on Sunday?', name: 'Rico', must: [/check|confirm/i, SIGNED], mustNot: [/yes,? you can|(?<!make )\bsure\b/i] }, // s74: "we'll make sure" is not a yes
];

if (import.meta.main) {
  const key = Deno.env.get('CASCADE_OPENROUTER_PROBE_KEY') ?? '';
  if (!key) { console.error('Set CASCADE_OPENROUTER_PROBE_KEY.'); Deno.exit(2); }
  setProviderKey(key);
  const i = Deno.args.indexOf('--runs'), runs = i >= 0 ? Number(Deno.args[i + 1]) || 3 : 3;
  const db = { rpc: () => Promise.reject(new Error('no db')), from: () => { throw new Error('no db'); } }; // seed card and contact
  let pass = 0, total = 0;
  for (const c of CASES) for (let r = 1; r <= runs; r++) {
    total++;
    const calm = calmMoment(c.guest, classify(c.guest, { hasBooking: true }));
    const draft = await modelDraft(db, c.guest, c.name, [], true, '', calm).catch((e) => `DRAFT FAILED: ${String(e).slice(0, 120)}`);
    const fails = [...airbnbTone(draft, calm), ...c.must.filter((re) => !re.test(draft)).map((re) => `expected ${re}`), ...c.mustNot.filter((re) => re.test(draft)).map((re) => `must not match ${re}`)];
    if (!fails.length) pass++;
    console.log(`${fails.length ? 'FAIL' : 'ok  '} ${c.id} run ${r}${calm ? ' (calm)' : ''}${fails.length ? `: ${fails.join('; ')}` : ''}\n${draft.replace(/^/gm, '    ')}`);
  }
  console.log(`${pass}/${total} drafts pass`);
  setProviderKey(null);
  Deno.exit(pass === total ? 0 : 1);
}
