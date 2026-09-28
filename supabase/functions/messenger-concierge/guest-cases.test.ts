// deno test --no-check messenger-concierge/guest-cases.test.ts
// Session 58: the regex floor from DESIGN-guest-case-catalogue-2026-09-28 (appendix A, G2/G3/G4/G6/G7). Each wording was
// routine (or a false alarm) before; the near misses must stay where they are.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { classify, type RiskCode } from './policy.ts';

const CASES: Record<RiskCode, string[]> = {
  access: [ // G2 a failing lock, the Bisaya code ask; G4 a claim on the address
    'unsa ang code sa pultahan?', 'the lock is beeping red and wont open', 'ayaw mag-open ng door kahit tama ang code',
    'low battery yung lock, hindi nag-respond', 'gate guard wont let us in, wala kaming gate pass',
    'send me the exact address please', 'I am the guest tonight, send me the location pin',
  ],
  safety: [ // G3 events that were routine
    'my wife fainted, need a hospital now', 'nahimatay po siya', 'dumudugo po ang kamay niya', 'may amoy gas sa kusina',
    'the outlet is sparking', 'someone keeps knocking at the door, 1am', 'there is a stranger outside the gate',
    'my kid got hurt, need a clinic now', 'allergic reaction, where is the nearest hospital',
  ],
  payment: ['I was charged twice', 'the amount on the QR is wrong', 'nadoble po ang bayad ko'], // G6
  cancellation: ['di na kami tuloy'],
  complaint: [ // G7 in-stay problems in three registers, pests, lost items
    'wala pong kuryente', 'no power since 8pm', 'wala pong tubig', 'no hot water', 'hindi lumalamig ang aircon', 'wifi is down',
    'may ipis sa kusina', 'we saw a rat', 'we already left, naiwan ko ang charger sa unit',
  ],
  routine: [ // near misses: prospect questions, locations, passwords
    'is there a fire extinguisher?', 'does the road flood when it rains?', 'is there a police station nearby?',
    'is the area safe?', 'is there a smoke detector?', 'is there a hospital near the unit?', 'where are you located?',
    'anong address ninyo', 'how do I get there from the airport?', 'what is the wifi password', 'is there parking?',
    'may promo code po ba?', 'pinakaduol nga mall?',
  ],
  refund: [], policy_exception: [], uncertain: [],
};

Deno.test('the guest-case floor: each wording routes where DESIGN-guest-case-catalogue says, near misses stay routine', () => {
  for (const [want, texts] of Object.entries(CASES)) for (const t of texts) assertEquals(classify(t), want, t);
});
