// The OPS Telegram group has cleaners in it: it never shows a guest's amounts or the payment number (Lloyd 2026-10-02,
// "keep cleaner fees, hide guest money"; D-306: no booking income of any kind in OPS, only expenses and cleaning pay). Cleaner fee cards are
// not run through this. Finance sees the full text. Pure: no env, no I/O. Used on the text OPS reads only; the text a guest is sent is never passed through it.
// ponytail: patterns, not a parser - a payment number or amount written in a form not listed here would pass; add its shape.
//   Phone numbers are NOT money (D-305). A bare number is masked only within 3 words of a money word (English or Taglish), after = or x, or beside a
//   percent next to occupancy/refund/discount; a standalone number only (ids like HMA1234567 or #12345 stay). 20[2-3]x after a month, "in" or "of" is a year.
const NUM = String.raw`\d{1,3}(?:[ ,]\d{3})+(?:\.\d+)?|\d[\d,]*(?:\.\d+)?`; // 1,780 | 1 780 | 1780.50
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
const WORD = String.raw`(?:rates?|nights?|nyt|nites?|gabi|totals?|balances?|deposits?|fees?|pay(?:s|ment|ments|ing)?|paid|sent|send|prices?|budget|refunds?|down\s?payment|dp|amounts?|due|payouts?|revenue|income|adr|each|per|extra|additional|discounts?|costs?|charges?|charged|bayad|singil|presyo|halaga|kabuuan|lahat|kada|kulang|sukli|dagdag|gcash)`;
const PWORD = String.raw`(?:occupancy|vacancy|discounts?|refunds?|deposits?|fees?|payouts?|revenue|income|adr|revpar|rates?|balance|down\s?payment|dp|totals?|price)`;
// a bare 3+ digit number (optionally .00 or a range 1500-2000), not part of a date, time, phone, id, long number or url
const CORE = String.raw`(?:\d{1,3}(?:,\d{3})+|\d{3,7})(?:\.\d{1,2})?`;
const TAIL = String.raw`(?!\d|[ -]\d{3,4}\b|[.,]\d|[\-/:]\d)`;
const BARE = String.raw`(?<![\w,.\-/:+#]|\d[ -])${CORE}(?:\s?[-–]\s?${CORE})?${TAIL}`;
const GAP = String.raw`(?:[^\w\n]+\w+){0,3}?[^\w\n]+`;
const PCT = String.raw`\d{1,3}(?:\.\d+)?\s?(?:%|percent\b|pct\b)`;
const AFTER_PCT = new RegExp(String.raw`\b(${PWORD})\b(${GAP})(${PCT})`, 'gi'); // "refund 50%", "occupancy is 73%"
const BEFORE_PCT = new RegExp(String.raw`(${PCT})(?=${GAP}${PWORD}\b)`, 'gi'); // "50% refund", "73% occupancy"
const AFTER_WORD = new RegExp(String.raw`\b(${WORD})\b(${GAP})(${BARE})`, 'gi'); // "rate is 1780", "paid: 1,780", "bayad 2500"
const BEFORE_WORD = new RegExp(String.raw`(${BARE})(?=${GAP}${WORD}\b)`, 'gi'); // "1780 a night", "1,780/nyt", "2500 kada gabi"
const OP = String.raw`(?<=[\d\s])(?:x|[=×*])\s?`; // "2 nights x 1,780 = 3,560", "P1780 x2 = 3560"
const AFTER_OP = new RegExp(String.raw`(${OP})(${CORE})(?!\d|[.,]\d|[\-/:]\d)`, 'gi');
const BEFORE_OP = new RegExp(String.raw`(${BARE})(?=\s?(?:[=×*]|x\s?\d))`, 'gi'); // "3,560 = 2 x 1,780"
const YEAR = /^20[2-3]\d$/;
const YEAR_CUE = /(?:\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(?:\d{1,2}(?:st|nd|rd|th)?,?\s+)?|\b(?:in|of)\s+)$/i;
const bare = (num: string, whole: string, at: number) => (YEAR.test(num) && YEAR_CUE.test(whole.slice(0, at)) ? num : '[amount hidden]');

export function maskMoney(text: string): string {
  return String(text ?? '').replace(PAY_NO, '[number hidden]').replace(ACCOUNT_NO, '$1$2[number hidden]').replace(AMOUNT, '[amount hidden]')
    .replace(AFTER_PCT, (_m: string, kw: string, gap: string) => kw + gap + '[amount hidden]')
    .replace(BEFORE_PCT, '[amount hidden]')
    .replace(AFTER_WORD, (_m: string, kw: string, gap: string, num: string, off: number, s: string) => kw + gap + bare(num, s, off + kw.length + gap.length))
    .replace(BEFORE_WORD, (_m: string, num: string, off: number, s: string) => bare(num, s, off))
    .replace(AFTER_OP, (_m: string, op: string) => op + '[amount hidden]')
    .replace(BEFORE_OP, '[amount hidden]');
}
export const hasMoney = (text: string): boolean => maskMoney(text) !== String(text ?? '');

// D-306: a notice or work-order title about cleaning pay or an expense is allowed in OPS, so it stays whole unless it also names booking income.
// The payment number is hidden either way. ponytail: word lists, not a classifier; 'pay' + a capitalised name stands in for "pay <staff name>".
const EXPENSE_WORD = /\b(?:clean|cleaning|cleaner|cleaners|linis|labada|laundry|transport|pamasahe|supplies|expense|expenses|gastos|bili)\b/i;
const PAY_NAME = /\b[Pp]ay\s+[A-Z][a-z]+/; // case-sensitive on purpose: a capitalised name
const BOOKING_INCOME = /\b(?:rates?|nights?|booking|guests?|deposits?|dp|balance|payouts?|refunds?|revenue|reservation|income|occupancy|airbnb)\b/i;
export function maskTitle(title: unknown): string {
  const s = String(title ?? '');
  return (EXPENSE_WORD.test(s) || PAY_NAME.test(s)) && !BOOKING_INCOME.test(s) ? s.replace(PAY_NO, '[number hidden]').replace(ACCOUNT_NO, '$1$2[number hidden]') : maskMoney(s);
}
