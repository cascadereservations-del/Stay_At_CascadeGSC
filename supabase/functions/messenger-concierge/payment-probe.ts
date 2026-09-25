// Runs scripted payment conversations through the deployed concierge's probe (nothing is sent to anyone; the probe
// stubs every outward effect and deletes its thread). Writes the turns, with the recorded effects, to payment-probe.json.
const url = Deno.env.get('CASCADE_PROBE_URL')!, secret = Deno.env.get('CASCADE_PROBE_SECRET')!;
type Turn = string | { text?: string; image?: boolean; advance_minutes?: number };
const convos: Record<string, Turn[]> = {
  'pay-fee-en': [
    'Hi, is Oct 9 to 11 available? 2 adults', 'yes', 'Ben Munez', '09171234567 ben@example.com', 'fee',
    'How do I pay? Can I use Maya instead of GCash?', { image: true, advance_minutes: 20 }, { text: 'Paid na po, received niyo na po ba?', advance_minutes: 5 },
  ],
  'pay-full-tl': [
    'Hello po, available po ba ang Oct 13 to 15? 2 kami', 'opo', 'Ben Munez', '09171234567 ben@example.com', 'full',
    { image: true, advance_minutes: 30 },
  ],
  'pay-questions-en': [
    'Hi, how do I pay for a booking? GCash or bank transfer?', 'Is the security deposit refundable?', 'How much is the reservation fee for 2 nights?',
  ],
};
const out: Record<string, unknown> = {};
for (const [id, turns] of Object.entries(convos)) {
  const res = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-cascade-probe': secret },
    body: JSON.stringify({ psid: `probe:${crypto.randomUUID()}`, name: 'Ben', turns }), signal: AbortSignal.timeout(170_000) });
  const j = await res.json().catch(() => null);
  out[id] = { status: res.status, ok: j?.ok, error: j?.error ?? null, turns: (j?.turns ?? []).map((t: any) => ({ guest: t.guest, reply: t.reply, step: t.step, effects: t.effects, lint: t.lint })) };
  console.log(id, res.status, j?.ok, (j?.turns ?? []).map((t: any) => t.step).join(' > '));
}
await Deno.writeTextFile(Deno.args[0] ?? 'payment-probe.json', JSON.stringify(out, null, 2));
