// The OPS Telegram group has cleaners in it: it never shows a guest's amounts or the payment number (Lloyd 2026-10-02; D-306: no booking income of any
// kind in OPS, only expenses and cleaning pay). Finance sees the full text. Pure: no env, no I/O. Used on the text OPS reads only; a guest is never sent masked text.
// D-306 round 5: DENY BY DEFAULT. Every currency amount and every standalone number of 3+ digits is hidden; only the shapes listed in `keep` survive.
// ponytail: a bare 1-2 digit amount ("rate 50") passes; add a rule if one ever shows up. No word lists: nothing here depends on a money word.
const PH = '◼'; // internal placeholder, swapped for the visible text at the very end (so a rule never reads it as a word)
const S0 = '', S1 = ''; // wrap a protected span while the number rules run
const NUM = String.raw`\d{1,3}(?:[ ,]\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?`;
const TAG = String.raw`(?:isa|dalawa|tatlo|apat|lima|anim|pito|walo|siyam|sampu)(?:ng|\sna)?(?:\s?ng)?`; // isang, dalawang, apat na ... libo / daan
const AMOUNT = new RegExp( // a currency amount in any dress: ₱1,780  P 1,780  Php. 1,780  $50  ₱1k  2,000 pesos  1.8k  2 libo  limang daan
  String.raw`(?:₱|(?:US)?\$|\b(?:PHP|USD)(?![a-z])|\bP(?![a-z]))\.?\s?(?:${NUM})(?:\s?k\b)?|\b(?:${NUM})\s?(?:k\s?)?(?:pesos?|piso|php|usd|dollars?)\b`
  + String.raw`|\b\d+(?:\.\d+)?\s?k\b|\b\d+(?:\.\d+)?\s?(?:libo|daan)\b|\b${TAG}\s+(?:libo|daan)\b`, 'gi');
const PAY_NO = /(?:\+?63[\s-]?|0)956[\s-]?011[\s-]?5744/g;
const ACCOUNT_NO = /\b(g-?cash|maya|paymaya|bdo|bpi|unionbank|landbank|metrobank|rcbc|account|acct)\b([^\n\d]{0,30})\d[\d\s-]{7,}\d/gi;
const MON = String.raw`(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?`;
// keep, step 1 (before amounts): urls, e-mails, uuids, #ids, phone numbers (+63..., 09xx-xxx-xxxx, (083) 552-3162, 552-3162)
const KEEP1 = [/\b(?:https?:\/\/|www\.)[^\s<>"')]+/gi, /[\w.+-]+@[\w-]+(?:\.[\w-]+)+/g, /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, /#\w+/g,
  /\+\d{1,3}[\s-]?\(?\d{1,4}\)?(?:[\s-]?\d{2,4}){2,3}/g, /\(?\b0\d{1,3}\)?[\s-]?\d{3,4}[\s-]?\d{4}\b/g, /\b\d{3}-\d{4}\b/g];
// keep, step 2 (after amounts): dates, colon and am/pm times, 24-hour / D-306 compounds, tokens that mix letters and digits (HMA1234567, 00A49C5E, 300W)
const KEEP2 = [/\b\d{4}-\d{2}-\d{2}\b/g, /\b\d{1,2}\/\d{1,2}(?:\/\d{2,4})?\b/g, new RegExp(String.raw`\b${MON}\s+\d{1,2}(?:st|nd|rd|th)?(?:,?\s+\d{4})?\b`, 'gi'),
  new RegExp(String.raw`\b\d{1,2}(?:st|nd|rd|th)?\s+${MON}(?:,?\s+\d{4})?\b`, 'gi'), new RegExp(String.raw`\b${MON}\s+\d{4}\b`, 'gi'),
  /\b\d{1,2}:\d{2}(?::\d{2})?(?:\s?[ap]\.?m\b\.?)?/gi, /\b\d{1,4}\s?[ap]\.?m\b/gi, /\b\d+-[a-z]+\b/gi, /\b[A-Z]{1,8}-\d+\b/g,
  /\b(?!\d+x\d+\b)(?=[A-Za-z0-9]*\d)(?=[A-Za-z0-9]*[A-Za-z])[A-Za-z0-9]{3,}\b/g];
const GAP = String.raw`(?:[^\w\n]+\w+){0,3}?[^\w\n]+`;
const PCT_WORD = String.raw`\b(?:refund|occupancy|discount|deposit|payout|revenue|rate)\w*`; // a percent beside these is money; any other percent is a measure
const PCT = String.raw`\d{1,3}(?:\.\d+)?\s?(?:%|percent\b|pct\b)`;
const PCT_AFTER = new RegExp(String.raw`(${PCT_WORD})(${GAP})(${PCT})`, 'gi'), PCT_BEFORE = new RegExp(String.raw`(${PCT})(?=${GAP}${PCT_WORD})`, 'gi');
const NUMBER = /(?<!\d)(?<!\d[.,])(?:\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d{1,3}(?: \d{3})+(?:\.\d+)?|\d{1,3}(?:\.\d{3})+|\d{3,}(?:\.\d+)?)(?!\d)/g;
// a remaining number is kept after code/pin/room/unit/ref..., as a 3-digit hotline after hotline/call/BFP/police/fire, or when a unit or plural thing follows it
const ID_CUE = /\b(?:code|pin|passcode|room|unit|lot|block|order|ticket|ref)\s*(?:no\.?|number)?\s*[:-]?\s*$/i;
const ID_MONEY = /^(?:[^\w\n]+\w+){0,3}?[^\w\n]+(?:totals?|rates?|fees?|prices?|balance|deposits?|paid|due|payments?)\b/i;
const ID_PAY = /\b(?:gcash|maya|bank|transfer|payment|paid|deposit|receipt)\b[^.\n]*$/i; // "GCash ref 1780" is an amount, "Door code 4829 sent" is a code
const HOT_CUE =/\b(?:hotline|call|dial|tel|911|bfp|police|fire)\b[^\w\n]*(?:\w+[^\w\n]+){0,2}$/i;
const UNIT = /^\s?(?:%|(?:w|wh|kwh|kw|ml|l|g|kg|pcs?|sqm)\b|x\b(?!\s?\d)|(?!(?:this|thus|plus|yes|was|has|its|always|perhaps|thanks|unless|across|besides|towards|sometimes|nights|days|hours|hrs|mins|minutes|weeks|months|years|costs?|fees|rates|prices|totals|amounts|payments|deposits|charges|balances|bills|sales|payouts|refunds|earnings|tips)\b)[a-z]+[a-rt-z]s\b)/i;
const MONEY_BEFORE = /\b(?:rates?|totals?|price|paid|pay\w*|fees?|costs?|amount|balance|deposits?|bayad|refunds?|payouts?|revenue|nightly)\b[^\w\n]*(?:\w+[^\w\n]+)?$/i; // "rate 1780 pax" is still a rate
const keepNumber = (num: string, pre: string, post: string) =>
  /^0\d/.test(num) || (ID_CUE.test(pre) && !ID_MONEY.test(post) && !ID_PAY.test(pre)) || (/^\d{3}$/.test(num) && HOT_CUE.test(pre)) || (UNIT.test(post) && !MONEY_BEFORE.test(pre));

export function maskMoney(text: string): string {
  const kept = new Map<string, string>(); // protected span -> its original text
  const keep = (t: string, re: RegExp) => t.replace(re, (m) => { const k = S0 + 'x'.repeat(kept.size + 1) + S1; kept.set(k, m); return k; });
  let t = String(text ?? '').replace(/\[amount hidden\]/g, PH).replace(PAY_NO, '[number hidden]').replace(ACCOUNT_NO, '$1$2[number hidden]');
  for (const re of KEEP1) t = keep(t, re);
  t = t.replace(AMOUNT, PH);
  for (const re of KEEP2) t = keep(t, re);
  t = t.replace(PCT_AFTER, (_m: string, kw: string, gap: string) => kw + gap + PH).replace(PCT_BEFORE, PH)
    .replace(NUMBER, (m: string, off: number, s: string) => (keepNumber(m, s.slice(0, off), s.slice(off + m.length)) ? m : PH));
  return t.replace(/x+/g, (k) => kept.get(k) ?? k).replaceAll(PH, '[amount hidden]');
}
export const hasMoney = (text: string): boolean => maskMoney(text) !== String(text ?? '');

// D-306: a title with exactly ONE currency amount, a cleaning / expense / staff-pay word, no other masked number and no booking word stays whole.
// Everything else is maskMoney. 'pay <Name>' alone does not excuse 'nights' (it may be a guest).
const STAFF = /\b(?:clean\w*|linis|laundry|labada|transport|pamasahe|supplies|expenses?|gastos|bili|sweldo|sahod|bayad\s+kay)\b/i, PAY_NAME = /\b[Pp]ay\s+[A-Z][a-z]+/;
const BOOKING = /\b(?:guests?|stay|booking|reservation|deposits?|dp|balance|payouts?|refunds?|revenue|airbnb|rates?|totals?|paid|sales|kita|kinita|benta|earned|transfer|payments?|nightly|back|cancel\w*|income|occupancy)\b/i;
export function maskTitle(title: unknown): string {
  const s = String(title ?? ''), masked = maskMoney(s);
  const ok = (s.match(AMOUNT) ?? []).length === 1 && (masked.match(/\[amount hidden\]/g) ?? []).length === 1 && (STAFF.test(s) || PAY_NAME.test(s))
    && !BOOKING.test(s) && !(/\bnights?\b/i.test(s) && !STAFF.test(s));
  return ok ? s.replace(PAY_NO, '[number hidden]').replace(ACCOUNT_NO, '$1$2[number hidden]') : masked;
}
