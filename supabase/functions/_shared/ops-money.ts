// The OPS Telegram group has cleaners in it: it never shows a guest's amounts or the payment number (Lloyd 2026-10-02; D-306: no booking income of any
// kind in OPS, only expenses and cleaning pay). Finance sees the full text. Pure: no env, no I/O. Used on the text OPS reads only; a guest is never sent masked text.
// D-306 rounds 5-8: DENY BY DEFAULT. Every currency amount and every standalone number of 3+ digits is hidden; only the shapes marked "keep" below survive,
// and every keep needs a positive cue AND no money context.
// ponytail: a bare 1-2 digit amount ("rate 50") passes; add a rule if one ever shows up. The keeps are shapes (dates, ids, units), not a list of money words.
const PH = '◼'; // internal placeholder, swapped for the visible text at the very end (so a rule never reads it as a word)
const S0 = String.fromCharCode(0xe000), S1 = String.fromCharCode(0xe001); // wrap a protected span while the number rules run
const NUM = String.raw`\d{1,3}(?:[ ,]\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?`;
const TAG = String.raw`(?:isa|dalawa|tatlo|apat|lima|anim|pito|walo|siyam|sampu)(?:ng|\sna)?(?:\s?ng)?`; // isang, dalawang, apat na ... libo / daan
const BIS = String.raw`(?:usa|duha|tulo|upat|lima|unom|pito|walo|siyam|napulo)\s+ka`; // Bisaya: usa ka libo, pito ka gatos
const ONES = 'one|two|three|four|five|six|seven|eight|nine', TENS = 'twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety';
const ENG = String.raw`(?:a|${ONES}|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|(?:${TENS})(?:[- ](?:${ONES}))?)`; // English: one thousand, seventy hundred
const AMOUNT = new RegExp( // a currency amount in any dress: ₱1,780  P-1,780  Php. 1,780  DP-890  $50  ₱1k  2,000 pesos  1.8k  2 libo  limang daan  usa ka libo  dos mil  one thousand  2.5 thousand
  String.raw`(?:₱|(?:US)?\$|\b(?:PHP|USD|DP)(?![a-z])|\bP(?![a-z]))[.:-]?\s?(?:${NUM})(?:\s?k\b)?|\b(?:${NUM})\s?(?:k\s?)?(?:pesos?|piso|php|usd|dollars?)\b`
  + String.raw`|\b\d+(?:\.\d+)?\s?k\b|\b\d+(?:\.\d+)?\s?(?:libo|daan|gatos|thousand)\b|\b(?:${TAG}|${BIS})\s+(?:libo|daan|gatos)\b|\b${ENG}\s+(?:hundred|thousand)\b`
  + String.raw`|\b(?:uno|dos|tres|kwatro|singko|sais|siyete|otso|nuwebe|diyes)\s+mil\b`, 'gi');
const PAY_NO = /(?:\+?63[\s-]?|0)956[\s-]?011[\s-]?5744/g;
const ACCOUNT_NO = /\b(g-?cash|maya|paymaya|bdo|bpi|unionbank|landbank|metrobank|rcbc|account|acct)\b([^\n\d]{0,30})\d[\d\s-]{7,}\d/gi;
// money words (English and Taglish) used only as CONTEXT that cancels a keep, never to find an amount
const MWL = 'totals?|rates?|fees?|prices?|balance|deposits?|paid|due|payments?|per|nights?|nyt|gabi|kada|kulang|sobra|utang|remaining|short|off|cash|gcash|dp|downpayment|bayad|collected|received|owed?|natanggap|lang|lamang|only|singil|nightly|weekly|monthly|weekend|including|settle|pay|breakfast|overnight|tonight|pa|po|plus|x\\d|good\\s+for|for\\s+the\\s+stay|all\\s+in';
const MONEY_POST = String.raw`(?:${MWL})\b`;
const CTX_POST = String.raw`(?:[^\w\n]+\w+){0,3}?[^\w\n]+(?:${MWL}|extra|each|lang|only|lamang|x\d)\b`; // money within 3 words after
const CTX_PRE = String.raw`\b(?:${MWL}|extra|each|pay\w*|bal|cost|amount|sales)\b(?:[^\w\n]+\w+){0,3}?[^\w\n]*`; // money within 3 words before
// keep, step 1 (before amounts): urls, e-mails, uuids, #ids and 3-4 phone shapes with a phone cue (neither with money context), phone numbers (+63..., 09xx-xxx-xxxx, (083) 552-3162)
const KEEP1 = [/\b(?:https?:\/\/|www\.)[^\s<>"')]+/gi, /[\w.+-]+@[\w-]+(?:\.[\w-]+)+/g, /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi,
  new RegExp(String.raw`(?<!${CTX_PRE})#(?!\d+${CTX_POST.replace('+(?:', '*(?:')}|\d+\s?/|\d+\s+a\s+night)\w+`, 'gi'), /\+(?:63|1|44|61|65|81|82|86|91|852|971|49|33)[\s-]?\(?\d{1,4}\)?(?:[\s-]?\d{2,4}){2,3}/g,
  /\(?\b0\d{1,3}\)?[\s-]?\d{3,4}[\s-]?\d{4}\b/g,
  new RegExp(String.raw`(?<=\b(?:tel|call|phone|contact|hotline|landline|cp|mobile|number|cdrrmo|office|hospital|clinic|police|fire)\b[^\d\n]{0,12})(?<!${CTX_PRE})\b\d{3}-\d{4}\b(?!${CTX_POST}|\s*(?:\/|a\s+night))`, 'gi')];
// keep, step 2 (after amounts): dates (a year is 2020-2039; May only capitalised, with a day; none with money after), colon and hour-only am/pm times, 24-hour / D-306 compounds,
// ids with no 3-digit run or an all-caps 8+ ref (HMA1234567, 00A49C5E); anything else mixing letters and 3+ digits (Maria1780, 1780balance) goes to the number rules
const DAY = String.raw`(?:0?[1-9]|[12]\d|3[01])(?:st|nd|rd|th)?`, YR = String.raw`20[2-3]\d`;
const DATE_END = String.raw`\b(?![,.]\d)(?!(?:[^\w\n]+\w+){0,3}?[^\w\n]+(?:totals?|rates?|fees?|prices?|balance|deposits?|paid|pay\w*|due|payments?|cash|gcash|dp|downpayment|bayad|collected|received|owed?|utang|kulang|bal|cost|amount|sales|per|a\s+night|nyt|gabi)\b)`;
const dates = (mon: string, flags: string) => [new RegExp(String.raw`\b${mon}\.?\s+${DAY}(?:,?\s+${YR})?${DATE_END}`, flags), new RegExp(String.raw`\b${DAY}\s+${mon}\.?(?:,?\s+${YR})?${DATE_END}`, flags), new RegExp(String.raw`\b${mon}\.?\s+${YR}${DATE_END}`, flags)];
const KEEP2 = [/\b\d{4}-\d{2}-\d{2}\b/g, /\b\d{1,2}\/\d{1,2}(?:\/\d{2,4})?\b/g,
  ...dates('(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)', 'gi'), ...dates('May', 'g'),
  /\b\d{1,2}:\d{2}(?!\d)(?::\d{2})?(?:\s?[ap]\.?m\b\.?)?/gi, /\b(?:1[0-2]|0?[1-9])\s?[ap]\.?m\b/gi, /\b\d{1,2}-[a-z]+\b/gi, /\b(?:[A-Z]-\d{1,3}|[A-Z]{2,8}-\d{1,2})\b/g,
  /\b(?=[A-Za-z0-9]*\d)(?=[A-Za-z0-9]*[A-Za-z])(?:(?![A-Za-z0-9]*\d{3})[A-Za-z0-9]{3,}|(?=[A-Z0-9]{8,}\b)(?![A-Z0-9]*(?:TOTAL|BAL|RATE|PRICE|FEE|PAY|PAID|DP|NIGHT|ONLY|LANG|LAMANG|GCASH|CASH|DEPOSIT|PER|KADA|GABI|NYT|EACH|EXTRA|DUE)[A-Z0-9]*\b)[A-Z0-9]+)\b/g];
const GAP = String.raw`(?:[^\w\n]+\w+){0,3}?[^\w\n]+`;
const PCT_WORD = String.raw`\b(?:refund|occupancy|discount|deposit|payout|revenue|rate)\w*`; // a percent beside these is money; any other percent is a measure
const PCT = String.raw`\d{1,3}(?:\.\d+)?\s?(?:%|percent\b|pct\b)`;
const PCT_AFTER = new RegExp(String.raw`(${PCT_WORD})(${GAP})(${PCT})`, 'gi'), PCT_BEFORE = new RegExp(String.raw`(${PCT})(?=${GAP}${PCT_WORD})`, 'gi');
const NUMBER = /(?<!\d)(?<!\d[.,])(?:\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d{1,3}(?: \d{3})+(?:\.\d+)?|\d{1,3}(?:\.\d{3})+|\d{3,}(?:\.\d+)?)(?!\d)/g;
// a remaining number is kept only with a positive cue AND no money context: after code/pin/ref/password... (any digits), after room/unit/lot/block (1-3 digits),
// as a hotline after a rescue word, as a 4-digit postcode after zip/postal, with a leading zero, or before a measure / small supply count
const CUE = String.raw`(?:\s+(?:no\.?|number|is|ay))?\s*[:#-]?\s*$`; // code is 4829, ang code ay 4829, door code: 4829
const ID_ANY = new RegExp(String.raw`\b(?:code|pin|passcode|ref|lockbox|lock|password|pw|reading|meter)${CUE}`, 'i');
const ID_SMALL = /\b(?:room|unit|lot|block)(?:\s+(?:no\.?|number))?\s*#?\s*$/i; // no "is" / ":" for these: "the room is 950", "Room: 950" are prices
const ID_MONEY = new RegExp(String.raw`^(?:[^\w\n]+\w+){0,3}?[^\w\n]+${MONEY_POST}|^[^\w\n]*each\b`, 'i');
const ID_MONEY_SMALL = new RegExp(String.raw`^(?:[^\w\n]+\w+){0,3}?[^\w\n]+(?:${MWL}|lang|only|lamang|tonight|for)\b|^[^\w\n]*each\b`, 'i');
const ID_PAY = /\b(?:gcash|maya|bank|transfer|payment|paid|deposit|receipt)\b[^.\n]*$/i; // "GCash ref 1780" is an amount, "Door code 4829 sent" is a code
const POST_CUE = /\b(?:zip|postal(?:\s+code)?|postcode)[:,]?\s*$/i;
const HOT_CUE = /\b(?:call|pakicall|dial|tawag|hotline|bfp|pnp|police|fire|ambulance|emergency|red\s+cross|rescue)\b(?:[^\w\n]+\w+){0,3}?[^\w\n]*$/i;
const MEASURE = /^\s?(?:%|(?:ml|kg|sqm)\b(?!\/))/i, MEASURE_SMALL = /^\s?(?:g|l)\b(?!\/)/i; // 500 ml, 2 kg; g and l only up to 3 digits
const WATT = /^ ?(?:kWh|Wh|kW|W)(?![A-Za-z/])(?!\s+(?!(?:in|at|for|of|and|or|when|on|to|max|continuous|output|total|peak)\b)[A-Za-z])/; // 300 W, 300W (capital, not "1780 w breakfast")
const COUNT = /^\s?(?:rolls|towels|sheets|hangers|pillows|pillowcases|blankets|bottles|packs|sachets|pcs?|pieces|bars|cans|boxes|kits|sets)\b/i; // 120 rolls (1-3 digits)
const PEOPLE = /^\s?(?:guests|pax|persons|people)\b/i; // a head count, never 3+ digits
const MONEY_BEFORE = /\b(?:rates?|totals?|price|paid|pay\w*|fees?|costs?|amount|balance|deposits?|bayad|refunds?|payouts?|revenue|nightly|dp|downpayment|gcash|cash|collected|received|owed?|utang|bal)\b[^\w\n]*(?:\w+[^\w\n]+)?$/i; // "rate 1780 pax", "DP ref 1780"
const keepNumber = (num: string, pre: string, post: string) => {
  const d = num.replace(/\D/g, '').length, paid = ID_PAY.test(pre) || MONEY_BEFORE.test(pre), money = ID_MONEY.test(post) || paid;
  return (/^0\d/.test(num) && !money) || (!money && ID_ANY.test(pre)) || (d <= 3 && !paid && !ID_MONEY_SMALL.test(post) && ID_SMALL.test(pre))
    || (/^(?:911|117|143|160|166)$/.test(num) && !money && HOT_CUE.test(pre)) || (d === 4 && !money && POST_CUE.test(pre))
    || (!MONEY_BEFORE.test(pre) && (MEASURE.test(post) || WATT.test(post) || (d <= 3 && (MEASURE_SMALL.test(post) || COUNT.test(post) || (d <= 2 && PEOPLE.test(post))))));
};

export function maskMoney(text: string): string {
  const kept = new Map<string, string>(); // protected span -> its original text
  const keep = (t: string, re: RegExp) => t.replace(re, (m) => { const k = S0 + 'x'.repeat(kept.size + 1) + S1; kept.set(k, m); return k; });
  let t = String(text ?? '').replace(/\[amount hidden\]/g, PH).replace(PAY_NO, '[number hidden]').replace(ACCOUNT_NO, '$1$2[number hidden]');
  for (const re of KEEP1) t = keep(t, re);
  t = t.replace(AMOUNT, PH);
  for (const re of KEEP2) t = keep(t, re);
  t = t.replace(PCT_AFTER, (_m: string, kw: string, gap: string) => kw + gap + PH).replace(PCT_BEFORE, PH)
    .replace(NUMBER, (m: string, off: number, s: string) => (keepNumber(m, s.slice(0, off), s.slice(off + m.length)) ? m : PH));
  return t.replace(new RegExp(S0 + 'x+' + S1, 'g'), (k) => kept.get(k) ?? k).replaceAll(PH, '[amount hidden]');
}
export const hasMoney = (text: string): boolean => maskMoney(text) !== String(text ?? '');

// D-306: a title stays whole only with exactly ONE currency amount, nothing else masked, a cleaning / expense / staff-pay word, no booking word, and an amount at
// cleaning-pay scale. Everything else is maskMoney. "Pay <Name>" counts as a staff word only when that is all the title says. 'nights' and 'gabi' are booking words.
// ponytail: the cap is a stand-in for "is <Name> staff?" (no staff list is read): any title amount over 1,500 is masked, an expense that big is read in Finance.
const CAP = 1500;
const STAFF = /\b(?:clean\w*|linis|laundry|labada|transport|pamasahe|supplies|expenses?|gastos|bili|sweldo|sahod|bayad\s+kay)\b/i;
const BOOKING = /\b(?:guests?|stay|booking|reservation|deposits?|dp|balance|payouts?|refunds?|revenue|airbnb|rates?|totals?|paid|sales|kita|kinita|benta|earned|transfer|payments?|nightly|back|cancel\w*|income|occupancy|collect|charged?|from|singil|pet|late|early|checkout|check-in|extra)\b/i;
const peso = (m: string) => { let n = m.replace(/[^\d.]/g, ''); if (/^\d{1,3}(?:\.\d{3})+$/.test(n)) n = n.replace(/\./g, ''); return parseFloat(n) * (/k\b/i.test(m) ? 1000 : 1); }; // 3.560 is 3,560
export function maskTitle(title: unknown): string {
  const s = String(title ?? ''), masked = maskMoney(s), one = s.match(AMOUNT) ?? [];
  const who = STAFF.test(s) || /^[Pp]ay\s+[A-Z][a-z]+[\s:.–-]*$/.test(s.replace(AMOUNT, '').trim());
  const ok = one.length === 1 && peso(one[0]) <= CAP && (masked.match(/\[amount hidden\]/g) ?? []).length === 1 && who && !BOOKING.test(s) && !(/\b(?:nights?|gabi)\b/i.test(s) && !STAFF.test(s));
  return ok ? s.replace(PAY_NO, '[number hidden]').replace(ACCOUNT_NO, '$1$2[number hidden]') : masked;
}
