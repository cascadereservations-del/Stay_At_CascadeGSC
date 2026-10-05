// The OPS Telegram group has cleaners in it: it never shows a guest's amounts or the payment number (Lloyd 2026-10-02,
// "keep cleaner fees, hide guest money"; D-306: no booking income of any kind in OPS, only expenses and cleaning pay). Cleaner fee cards are
// not run through this. Finance sees the full text. Pure: no env, no I/O. Used on the text OPS reads only; the text a guest is sent is never passed through it.
// D-306 ruling: a leak is worse than over-masking. ponytail: patterns, not a parser - an amount written in a form not listed here would pass; add its shape.
//   Phone numbers are NOT money (D-305). A bare number is masked within 3 words of a money word (English or Taglish), after = or x, or beside a percent
//   next to occupancy/refund/discount; a standalone number only (ids like HMA1234567 or #12345 stay). 20[2-3]x after a month, "in" or "of" is a year.
//   A 4-digit number is NEVER a time (use 14:00 or 2pm). A count (120 rolls) next to a money word is masked; a count after a placeholder is not.
const PH = '◼'; // internal placeholder: no word characters, so it never reads as a money word to a later rule; swapped for the visible text at the very end
const NUM = String.raw`\d{1,3}(?:[ ,]\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?`; // 1,780 | 1 780 | 1780.50 (never takes a trailing comma)
const TAG_DIGIT = String.raw`(?:isa|dalawa|tatlo|apat|lima|anim|pito|walo|siyam|sampu)(?:ng|\sna)?(?:\s?ng)?`; // isang, dalawang, apat na, lima ng ... + libo/daan
const AMOUNT = new RegExp(
  String.raw`(?:₱|(?:US)?\$|\b(?:PHP|USD)(?![a-z])|\bP(?![a-z]))\.?\s?(?:${NUM})(?:\s?k\b)?` // ₱1,780  P 1,780  Php. 1,780  USD 50  $50  ₱1k
  + String.raw`|\b(?:${NUM})\s?(?:k\s?)?(?:pesos?|php|usd|dollars?)\b` // 2,000 pesos  1 780 pesos  2k pesos  50 USD
  + String.raw`|\b\d+(?:\.\d+)?\s?k\b` // 1.8k
  + String.raw`|\b\d+(?:\.\d+)?\s?(?:libo|daan)\b` // 2 libo, 5 daan
  + String.raw`|\b${TAG_DIGIT}\s+(?:libo|daan)\b`, // isang libo, limang daan
  'gi');
const PAY_NO = /(?:\+?63[\s-]?|0)956[\s-]?011[\s-]?5744/g;
const ACCOUNT_NO = /\b(g-?cash|maya|paymaya|bdo|bpi|unionbank|landbank|metrobank|rcbc|account|acct)\b([^\n\d]{0,30})\d[\d\s-]{7,}\d/gi;
// Money words by where the number sits. BOTH: a number before or after. AFTERNUM: a number that comes first ("1780 gabi", "200/hour"; "Oct 15 gabi 1900" is not money).
// BEFORENUM: a number it directly precedes, and not a counted thing ("send 120 rolls", "lahat ng 150 hangers").
const WORD_BOTH = String.raw`(?:rates?|totals?|balances?|deposits?|fees?|pay(?:s|ment|ments|ing)?|paid|sent|prices?|budget|refunds?|down\s?payment|dp|amounts?|payouts?|revenue|income|adr|discounts?|costs?|bayad|singil|presyo|halaga|kabuuan|sukli|dagdag|gcash|sales|kita|kinita|benta|earned|transfer|nights?|owes?|owed|utang|nagbayad|binayad|nabayaran|naghulog|hulog|pinadala|received|collect(?:ed)?|natanggap|net|gross|profit|tubo|earnings?|cash|booking|reservation|airbnb|stay|nightly|revpar|(?:per|kada|each)\s+(?:pax|head|person|hour|night|gabi|nyt|nite|guest))`;
const WORD_CHARGE = String.raw`(?:charges?|charged)`; // kept apart: "Charge the EcoFlow to 100%" is a measure, so these respect the unit rule
const WORD_AFTERNUM = String.raw`(?:each|per|gabi|nyt|nites?|kada|hour|lahat|extra|additional|due)`;
const WORD_BEFORENUM = String.raw`(?:extra|send|kulang|lahat|due|additional|each|nyt)`;
const PWORD = String.raw`(?:occupancy|vacancy|discounts?|refunds?|deposits?|fees?|payouts?|revenue|income|adr|revpar|rates?|balance|down\s?payment|dp|totals?|price)`;
// a bare 3+ digit number (optionally .00 or a range 1500-2000), not part of a date, time, phone, id, long number, url
const CORE = String.raw`(?:\d{1,3}(?:,\d{3})+|\d{1,3}(?: \d{3})+|\d{1,3}(?:\.\d{3})+|\d{3,7})(?:[.,]\d{1,2}(?!\d))?`; // 1,780 | 1 780 | 1.780 | 1780 | each with .00
const LB = String.raw`(?<![\w,.\-/:+#]|\d[ -])`;
const T0 = String.raw`\d|[ -]\d{3,4}\b|[.,]\d|[\-/:]\d`;
const UNIT = String.raw`\s?(?:%|(?:wh?|ml|g|kg|kwh|pcs|rolls|pax|hrs?|mins?)(?![\w/]))`; // 100%, 300 W, 120 rolls: a measure, unless a money word comes first
const THING = String.raw`\s?(?!(?:always|thanks|perhaps|sometimes|besides|towards|across|unless)\b)[a-z]{4,}s\b`; // a plural thing: 150 hangers, 120 towels (not 'this month')
const COUNTED = String.raw`\s?(?!(?:nights?|guests?|pax|persons?|heads?|days?|pcs|rolls|hrs?|mins?|hours?|pesos?)\b)(?!(?:always|thanks|perhaps|sometimes|besides|towards|across|unless)\b)[a-z]{4,}s\b`; // as THING, but nights, pax, rolls etc. still read as money after a money word
const RANGE = String.raw`(?:\s?[-–]\s?${CORE})?`;
const BARE = String.raw`${LB}${CORE}${RANGE}(?!${T0}|${UNIT})`; // number before a money word
const BARE_AFTER = String.raw`${LB}${CORE}${RANGE}(?!${T0}|${COUNTED})`; // number after a money word: units do not protect it, a counted noun does
const BARE_BN = String.raw`${LB}${CORE}${RANGE}(?!${T0}|${UNIT}|${THING})`; // after send/extra/kulang: a measure or a plural thing is a count
const BARE_CHARGE = String.raw`${LB}${CORE}${RANGE}(?!${T0}|${UNIT})`;
const GAP = String.raw`(?:[^\w\n]+\w+){0,3}?[^\w\n]+`;
const LIGHT = String.raw`(?:[^\w\n]+(?:ng|na|of|is|are|ko|po|lang|just|only|nang|sa|the|a|pa|siya|sila|niya|daw|raw|pala))*[^\w\n]+`;
const PCT = String.raw`\d{1,3}(?:\.\d+)?\s?(?:%|percent\b|pct\b)`;
const AFTER_PCT = new RegExp(String.raw`\b(${PWORD})\b(${GAP})(${PCT})`, 'gi'); // "refund 50%", "occupancy is 73%"
const BEFORE_PCT = new RegExp(String.raw`(${PCT})(?=${GAP}${PWORD}\b)`, 'gi'); // "50% refund", "73% occupancy"
const AFTER_WORD = new RegExp(String.raw`\b(${WORD_BOTH})\b(${GAP})(${BARE_AFTER})`, 'gi'); // "rate is 1780", "paid: 1,780", "bayad 2500", "kada gabi 1780"
const AFTER_CHARGE = new RegExp(String.raw`\b(${WORD_CHARGE})\b(${GAP})(${BARE_CHARGE})`, 'gi');
const AFTER_BN = new RegExp(String.raw`\b(${WORD_BEFORENUM})\b(${LIGHT})(${BARE_BN})`, 'gi'); // "extra 500", "send ko 1780", "kulang pa 1780", "each 1780"
const BEFORE_WORD = new RegExp(String.raw`(${BARE})(?=${GAP}(?:${WORD_BOTH}|${WORD_AFTERNUM}|${WORD_CHARGE})\b)`, 'gi'); // "1780 a night", "1,780/nyt", "2500 kada gabi"
const OP = String.raw`(?<=[\d\s])(?:x|[=×*])\s?`; // "2 nights x 1,780 = 3,560", "P1780 x2 = 3560"
const AFTER_OP = new RegExp(String.raw`(${OP})(${CORE})(?!\d|[.,]\d|[\-/:]\d)`, 'gi');
const BEFORE_OP = new RegExp(String.raw`(${BARE})(?=\s?(?:[=×*]|x\s?\d))`, 'gi'); // "3,560 = 2 x 1,780"
const YEAR = /^20[2-3]\d$/;
const YEAR_CUE = /(?:\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(?:\d{1,2}(?:st|nd|rd|th)?,?\s+)?|\b(?:in|of)\s+)$/i;
// a code, pin or room number is not money, unless a money word follows it within 3 words ("unit 1780 rate", "Code 1780, total"; "Door code 4829 sent" stays)
const ID_CUE = /\b(?:code|pin|passcode|room|unit|ref|lot|block|ticket|order)\s*(?:no\.?|number|#)?\s*[:#-]?\s*$/i;
const ID_FOLLOW = new RegExp(String.raw`^(?:[^\w\n]+\w+){0,3}?[^\w\n]+(?:rates?|totals?|balances?|deposits?|fees?|prices?|amounts?|payouts?|revenue|income|paid|payments?|due|refunds?|dp|pesos?|nightly|(?:per|each|kada)\s+(?:night|gabi))\b`, 'i');
const bare = (num: string, whole: string, at: number) => {
  const pre = whole.slice(0, at);
  return (YEAR.test(num) && YEAR_CUE.test(pre)) || (ID_CUE.test(pre) && !ID_FOLLOW.test(whole.slice(at + num.length))) ? num : PH;
};
const MONEYISH_BEFORE_X = /^(?:nights|rates|totals|fees|deposits|prices|payments|guests|pax|persons|heads)$/i;

export function maskMoney(text: string): string {
  return String(text ?? '').replace(/\[amount hidden\]/g, PH).replace(PAY_NO, '[number hidden]').replace(ACCOUNT_NO, '$1$2[number hidden]').replace(AMOUNT, PH)
    .replace(AFTER_PCT, (_m: string, kw: string, gap: string) => kw + gap + PH)
    .replace(BEFORE_PCT, PH)
    .replace(AFTER_WORD, (_m: string, kw: string, gap: string, num: string, off: number, s: string) => kw + gap + bare(num, s, off + kw.length + gap.length))
    .replace(AFTER_CHARGE, (_m: string, kw: string, gap: string, num: string, off: number, s: string) => kw + gap + bare(num, s, off + kw.length + gap.length))
    .replace(AFTER_BN, (_m: string, kw: string, gap: string, num: string, off: number, s: string) => kw + gap + bare(num, s, off + kw.length + gap.length))
    .replace(BEFORE_WORD, (_m: string, num: string, off: number, s: string) => bare(num, s, off))
    .replace(AFTER_OP, (m: string, op: string, _num: string, off: number, s: string) => {
      if (/^x/i.test(op)) { // "towels x 120" and "x 120 rolls" are counts
        const w = /([A-Za-z]+)\s*$/.exec(s.slice(0, off));
        if ((w && w[1].length >= 4 && /s$/i.test(w[1]) && !MONEYISH_BEFORE_X.test(w[1])) || /^\s?[a-z]{2,}/i.test(s.slice(off + m.length))) return m;
      }
      return op + PH;
    })
    .replace(BEFORE_OP, PH)
    .replaceAll(PH, '[amount hidden]');
}
export const hasMoney = (text: string): boolean => maskMoney(text) !== String(text ?? '');

// D-306: a notice or work-order title about cleaning pay or an expense is allowed in OPS, so it stays whole unless it also names booking income, carries
// two or more amounts, or (a bare "Pay <Name>" with no cleaning or expense word, which may be a guest) has an amount without a peso sign.
// The payment number is hidden either way. ponytail: word lists, not a classifier; 'pay' + a capitalised name stands in for "pay <staff name>".
const EXPENSE_WORD = /\b(?:clean|cleaning|cleaner|cleaners|linis|labada|laundry|transport|pamasahe|supplies|expense|expenses|gastos|bili|sweldo|sahod|bayad\s+kay)\b/i;
const PAY_NAME = /\b[Pp]ay\s+[A-Z][a-z]+/; // case-sensitive on purpose: a capitalised name
const BOOKING_INCOME = /\b(?:rates?|booking|guests?|deposits?|dp|balance|payouts?|refunds?|revenue|reservation|income|occupancy|airbnb|paid|payments?|totals?|sales|kita|kinita|benta|earned|transfer|nightly|stay|back|cancel\w*)\b/i;
// every standalone 3+ digit number (dates, times with a colon, phones, ids and codes stay), used when a title is masked: a leak is worse than over-masking
const STANDALONE = new RegExp(String.raw`${LB}${CORE}${RANGE}(?!${T0}|${UNIT}|${THING})`, 'g');
const strict = (s: string) => maskMoney(s).replace(STANDALONE, (m: string, off: number, whole: string) => bare(m, whole, off)).replaceAll(PH, '[amount hidden]');
const hits = (s: string) => (s.match(/\[amount hidden\]/g) ?? []).length;
export function maskTitle(title: unknown): string {
  const s = String(title ?? '');
  const staff = EXPENSE_WORD.test(s), named = PAY_NAME.test(s);
  if (!(staff || named) || BOOKING_INCOME.test(s)) return strict(s);
  const marked = (s.match(AMOUNT) ?? []).length; // ₱500, 500 pesos
  const unmarked = hits(strict(s.replace(AMOUNT, ''))); // any other amount, however it is written
  if (marked + unmarked > 1 || (!staff && unmarked > 0)) return strict(s);
  return s.replace(PAY_NO, '[number hidden]').replace(ACCOUNT_NO, '$1$2[number hidden]');
}
