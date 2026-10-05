// The OPS Telegram group has cleaners in it: it never shows a guest's amounts or the payment number (Lloyd 2026-10-02,
// "keep cleaner fees, hide guest money"; D-306: no booking income of any kind in OPS). Cleaner fee cards are not run through this.
// Finance sees the full text. Pure: no env, no I/O. Used on the text OPS reads only; the text a guest is sent is never passed through it.
// ponytail: patterns, not a parser - a payment number or amount written in a form not listed here would pass; add its shape.
//   Phone numbers are NOT money (D-305). A bare number is masked only within 3 words of a money word; 20[2-3]x after a month, "in" or "of" is a year.
const NUM = String.raw`\d{1,3}(?:[ ,]\d{3})+(?:\.\d+)?|\d[\d,]*(?:\.\d+)?`; // 1,780 | 1 780 | 1780.50
const AMOUNT = new RegExp(
  String.raw`(?:₱|(?:US)?\$|\b(?:PHP|USD)(?![a-z])|\bP(?![a-z]))\.?\s?(?:${NUM})` // ₱1,780  P 1,780  Php. 1,780  USD 50  $50
  + String.raw`|\b(?:${NUM})\s?(?:k\s?)?(?:pesos?|php|usd|dollars?)\b` // 2,000 pesos  1 780 pesos  2k pesos  50 USD
  + String.raw`|\b\d+(?:\.\d+)?\s?k\b`, // 1.8k
  'gi');
const PAY_NO = /(?:\+?63[\s-]?|0)956[\s-]?011[\s-]?5744/g;
const ACCOUNT_NO = /\b(g-?cash|maya|paymaya|bdo|bpi|unionbank|landbank|metrobank|rcbc|account|acct)\b([^\n\d]{0,30})\d[\d\s-]{7,}\d/gi;
const WORD = String.raw`(?:rates?|nights?|totals?|balances?|deposits?|fees?|pay(?:s|ment|ments|ing)?|paid|sent|prices?|budget|refunds?|down\s?payment|dp)`;
// a bare 3+ digit number, not part of a date, time, phone, long id or decimal
const BARE = String.raw`(?<![\d,.\-/:+]|\d[ -])(?:\d{1,3}(?:,\d{3})+|\d{3,7})(?!\d|[ -]\d{3,4}\b|[.,]\d|[\-/:]\d)`;
const GAP = String.raw`(?:[^\w\n]+\w+){0,3}?[^\w\n]+`;
const AFTER_WORD = new RegExp(String.raw`\b(${WORD})\b(${GAP})(${BARE})`, 'gi'); // "rate is 1780", "paid: 1,780"
const BEFORE_WORD = new RegExp(String.raw`(${BARE})(?=${GAP}${WORD}\b)`, 'gi'); // "1780 a night", "1,780 total"
const YEAR = /^20[2-3]\d$/;
const YEAR_CUE = /(?:\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(?:\d{1,2}(?:st|nd|rd|th)?,?\s+)?|\b(?:in|of)\s+)$/i;
const bare = (num: string, whole: string, at: number) => (YEAR.test(num) && YEAR_CUE.test(whole.slice(0, at)) ? num : '[amount hidden]');

export function maskMoney(text: string): string {
  return String(text ?? '').replace(PAY_NO, '[number hidden]').replace(ACCOUNT_NO, '$1$2[number hidden]').replace(AMOUNT, '[amount hidden]')
    .replace(AFTER_WORD, (m: string, kw: string, gap: string, num: string, off: number, s: string) => kw + gap + bare(num, s, off + kw.length + gap.length))
    .replace(BEFORE_WORD, (_m: string, num: string, off: number, s: string) => bare(num, s, off));
}
export const hasMoney = (text: string): boolean => maskMoney(text) !== String(text ?? '');
