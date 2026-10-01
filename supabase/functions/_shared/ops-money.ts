// The OPS Telegram group has cleaners in it: it never shows a guest's amounts or the payment number (Lloyd 2026-10-02,
// "keep cleaner fees, hide guest money"). Cleaner fee cards are not run through this. Finance sees the full text.
// Pure: no env, no I/O. Used on the text OPS reads only; the text a guest is sent is never passed through it.
// ponytail: patterns, not a parser - a payment number written in a form not listed here would pass; add its shape.
const AMOUNT = /(?:₱|\bPHP|\bP(?=\d))\s?\d[\d,]*(?:\.\d+)?|\b\d[\d,]*(?:\.\d+)?\s?(?:pesos?|php)\b/gi;
const PAY_NO = /(?:\+?63[\s-]?|0)956[\s-]?011[\s-]?5744/g;
const ACCOUNT_NO = /\b(g-?cash|maya|paymaya|bdo|bpi|unionbank|landbank|metrobank|rcbc|account|acct)\b([^\n\d]{0,30})\d[\d\s-]{7,}\d/gi;

export function maskMoney(text: string): string {
  return String(text ?? '').replace(PAY_NO, '[number hidden]').replace(ACCOUNT_NO, '$1$2[number hidden]').replace(AMOUNT, '[amount hidden]');
}
export const hasMoney = (text: string): boolean => maskMoney(text) !== String(text ?? '');
