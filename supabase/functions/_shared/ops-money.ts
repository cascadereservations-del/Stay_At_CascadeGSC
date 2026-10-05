// The OPS Telegram group has cleaners in it: it never shows a guest's amounts or the payment number (Lloyd 2026-10-02; D-306: no booking income of any
// kind in OPS, only expenses and cleaning pay). Finance sees the full text. Pure: no env, no I/O. Used on the text OPS reads only; a guest is never sent masked text.
// D-306 rounds 5-9: DENY BY DEFAULT. Every currency amount and every standalone number of 3+ digits is hidden; only the shapes marked "keep" below survive,
// and every keep needs a positive cue AND no money context.
// ponytail: a bare 1-2 digit amount ("rate 50") passes; add a rule if one ever shows up. The keeps are shapes (dates, ids, units), not a list of money words.
const PH = '◼'; // internal placeholder, swapped for the visible text at the very end (so a rule never reads it as a word)
const S0 = String.fromCharCode(0xe000), S1 = String.fromCharCode(0xe001); // wrap a protected span while the number rules run
const NUM = String.raw`\d{1,3}(?:[ ,]\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?`;
const TAG = String.raw`(?:isa|dalawa|tatlo|apat|lima|anim|pito|walo|siyam|sampu)(?:ng|\sna)?(?:\s?ng)?`; // isang, dalawang, apat na ... libo / daan
const BIS = String.raw`(?:usa|duha|tulo|upat|lima|unom|pito|walo|siyam|napulo)\s+ka`; // Bisaya: usa ka libo, pito ka gatos
const SPN = 'uno|dos|tres|kwatro|kuwatro|kuatro|singko|sinko|sais|siyete|syete|otso|nuwebe|nuebe|diyes|dyes|onse|dose|trese|katorse|kinse|beinte|bente|trenta|traynta|kwarenta|singkwenta|singkuwenta|sisenta|setenta|otsenta|nobenta';
const BIG = String.raw`mil|milyon|million|(?:dos|tres|kwatro|kuwatro|kuatro|singko|sais|siyete|syete|otso|nuwebe|nuebe)?\s*(?:si?y?entos?|cientos?)|[a-z]*cientos|[kq]u?ini?y?entos`; // mil, siyentos, doscientos, quinientos
const SPANISH = String.raw`\b(?:(?:${SPN})[\s-]+)*(?:${BIG})(?:[\s-]+(?:${SPN}|${BIG}))*\b`; // the whole phrase: beinte mil, mil kwatro syentos, dos syentos singkuwenta
const ONES = 'one|two|three|four|five|six|seven|eight|nine', TENS = 'twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety';
const ENG = String.raw`(?:a|${ONES}|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|(?:${TENS})(?:[- ](?:${ONES}))?)`; // English: one thousand, seventy hundred
const AMOUNT = new RegExp( // a currency amount in any dress: ₱1,780  P-1,780  Php. 1,780  DP-890  $50  ₱1k  2,000 pesos  1.8k  2 libo  limang daan  usa ka libo  dos mil  one thousand  2.5 thousand
  String.raw`(?:₱|(?:US)?\$|\b(?:PHP|USD|DP)(?![a-z])|\bP(?![a-z]))[.:-]?\s?(?:${NUM})(?:\s?k\b)?|\b(?:${NUM})\s?(?:k\s?)?(?:pesos?|piso|php|usd|dollars?)\b`
  + String.raw`|\b\d+(?:\.\d+)?\s?k\b|\b\d+(?:\.\d+)?\s?(?:libo|daan|gatos|thousand|million|milyon)\b|\b(?:${TAG}|${BIS})\s+(?:libo|daan|gatos|milyon)\b|\b${ENG}\s+(?:hundred|thousand|million)\b`
  + String.raw`|${SPANISH}|\bsang?[\s-]?(?:libo|daan)\w*`, 'gi'); // dos mil, mil kwatro syentos, singko siyentos, sanlibo, sang libo, sandaan
const MILLION = /\b\d+(?:\.\d+)?\s?M\b/g; // 2M, 1.5M (capital only: "200 m away" is a distance)
const PAY_NO = /(?:\+?63[\s-]?|0)956[\s-]?011[\s-]?5744/g;
const ACCOUNT_NO = /\b(g-?cash|maya|paymaya|bdo|bpi|unionbank|landbank|metrobank|rcbc|account|acct)\b([^\n\d]{0,30})\d[\d\s-]{7,}\d/gi;
// money words (English and Taglish) used only as CONTEXT that cancels a keep, never to find an amount
const MWL = 'totals?|rates?|fees?|prices?|balance|deposits?|paid|due|payments?|per|nights?|nyt|gabi|kada|kulang|sobra|utang|remaining|short|off|cash|gcash|dp|downpayment|bayad|collected|received|owed?|natanggap|lang|lamang|only|singil|nightly|weekly|monthly|weekend|including|settle|pay|breakfast|overnight|tonight|pa|po|plus|x\\d|good\\s+for|for\\s+the\\s+stay|all\\s+in';
const MONEY_POST = String.raw`(?:${MWL})\b`;
const CTX_POST = String.raw`(?:[^\w\n]+\w+){0,3}?[^\w\n]+(?:${MWL}|extra|each|lang|only|lamang|x\d)\b`; // money within 3 words after
const CTX_PRE = String.raw`\b(?:${MWL}|extra|each|pay\w*|bal|cost|amount|sales)\b(?:[^\w\n]+\w+){0,3}?[^\w\n]*`; // money within 3 words before
// keep, step 1 (before amounts): urls, e-mails, uuids, #ids after booking/order/ticket and 3-4 phone shapes with a phone cue (neither with money context), phone numbers (+63..., 09xx-xxx-xxxx, (083) 552-3162)
const KEEP1 = [/\b(?:https?:\/\/|www\.)[^\s<>"')]+/gi, /[\w.+-]+@[\w-]+(?:\.[\w-]+)+/g, /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi,
  new RegExp(String.raw`(?<=\b(?:booking|reservation|order|ticket|case|issue|job|confirmation)\s*(?:no\.?\s*)?)(?<!${CTX_PRE})#(?!\d+${CTX_POST.replace('+(?:', '*(?:')}|\d+\s?/|\d+\s+a\s+night)\w+`, 'gi'), /\+(?:63|1|44|61|65|81|82|86|91|852|971|49|33)[\s-]?\(?\d{1,4}\)?(?:[\s-]?\d{2,4}){2,3}/g,
  /\(?\b0\d{1,3}\)?[\s-]?\d{3,4}[\s-]?\d{4}\b/g,
  new RegExp(String.raw`(?<=\b(?:tel|call|phone|contact|hotline|landline|cp|mobile|number|cdrrmo|office|hospital|clinic|police|fire)\b[^\d\n]{0,12})(?<!${CTX_PRE})\b\d{3}-\d{4}\b(?!${CTX_POST}|\s*(?:\/|a\s+night))`, 'gi')];
// keep, step 2 (after amounts): dates (a year is 2020-2039; May only capitalised, with a day; none with money before or after), colon and hour-only am/pm times, 24-hour / D-306 compounds,
// ids with no 3-digit run, an Airbnb HM code (HMA1234567) or a direct-booking ref (8 hex, no 3-letter run: 4F123A9C); anything else mixing letters and 3+ digits
// (Maria1780, MARIA1780, ANA1780PHP, 1780balance) goes to the number rules
const DAY = String.raw`(?:0?[1-9]|[12]\d|3[01])(?:st|nd|rd|th)?`, YR = String.raw`20[2-3]\d`;
const DATE_MW = String.raw`totals?|rates?|fees?|prices?|balance|deposits?|paid|pay\w*|due|payments?|cash|gcash|dp|downpayment|bayad|collected|received|owed?|utang|kulang|bal|cost|amount|sales|per|a\s+night|nyt|gabi|refunds?|revenue|sent|transfer\w*|kita|natanggap|payouts?|income|earn\w*|benta|remit\w*|settled|nagpadala|padala|binayaran|deposited|charged|billed|collect|owes|profit|net|sukli|singil|presyo|halaga|remaining`
  .replace(/(?<!\\)[a-z]/g, (c) => `[${c}${c.toUpperCase()}]`); // any case, so the capital-only May rule still reads "Paid"
const DATE_PRE = String.raw`(?<!\b(?:${DATE_MW})\b(?:[^\w\n]+\w+){0,3}?[^\w\n]+)`; // "Paid Oct 2030", "Received Oct 15, 2030" are amounts
const DATE_END = String.raw`\b(?![,.]\d)(?!(?:[^\w\n]+\w+){0,3}?[^\w\n]+(?:${DATE_MW})\b)`;
const dates = (mon: string, flags: string) => [new RegExp(String.raw`${DATE_PRE}\b${mon}\.?\s+${DAY}(?:,?\s+${YR})?${DATE_END}`, flags), new RegExp(String.raw`${DATE_PRE}\b${DAY}\s+${mon}\.?(?:,?\s+${YR})?${DATE_END}`, flags), new RegExp(String.raw`${DATE_PRE}\b${mon}\.?\s+${YR}${DATE_END}`, flags),
  // with money before, the day and month still read as one word (so "Paid Oct 15, 950 pcs" stays money context) and the year goes to the number rules
  new RegExp(String.raw`\b${mon}\.?\s+${DAY}(?!\d)${DATE_END}`, flags), new RegExp(String.raw`\b${DAY}\s+${mon}\b\.?${DATE_END}`, flags)];
const KEEP2 = [/\b\d{4}-\d{2}-\d{2}\b/g, /\b\d{1,2}\/\d{1,2}(?:\/\d{2,4})?\b/g,
  ...dates('(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)', 'gi'), ...dates('May', 'g'),
  /\b\d{1,2}:\d{2}(?!\d)(?::\d{2})?(?:\s?[ap]\.?m\b\.?)?/gi, /\b(?:1[0-2]|0?[1-9])\s?[ap]\.?m\b/gi, /\b\d{1,2}-[a-z]+\b/gi, /\b(?:[A-Z]-\d{1,3}|[A-Z]{2,8}-\d{1,2})\b/g,
  /\b(?=[A-Za-z0-9]*\d)(?=[A-Za-z0-9]*[A-Za-z])(?:(?![A-Za-z0-9]*\d{3})[A-Za-z0-9]{3,}|HM(?![A-Z0-9]*(?:PHP|TOTAL|BAL|RATE|PRICE|FEE|PAY|PAID|DP|NIGHT|ONLY|LANG|LAMANG|GCASH|CASH|DEPOSIT|PER|KADA|GABI|NYT|EACH|EXTRA|DUE|BAYAD|UTANG|KULANG|SINGIL|SALES|KITA|BENTA|COST|SENT))[A-Z0-9]{8}|(?![A-F0-9]*[A-F]{3})[A-F0-9]{8})\b/g];
const GAP = String.raw`(?:[^\w\n]+\w+){0,3}?[^\w\n]+`;
const PCT_WORD = String.raw`\b(?:refund|occupancy|discount|deposit|payout|revenue|rate)\w*`; // a percent beside these is money; any other percent is a measure
const PCT = String.raw`\d{1,3}(?:\.\d+)?\s?(?:%|percent\b|pct\b)`;
const PCT_AFTER = new RegExp(String.raw`(${PCT_WORD})(${GAP})(${PCT})`, 'gi'), PCT_BEFORE = new RegExp(String.raw`(${PCT})(?=${GAP}${PCT_WORD})`, 'gi');
const NUMBER = /(?<!\d)(?<!\d[.,])(?:\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d{1,3}(?: \d{3})+(?:\.\d+)?|\d{1,3}(?:\.\d{3})+|\d{3,}(?:\.\d+)?)(?!\d)/g;
// a remaining number is kept only with a positive cue AND no money context: after code/pin/ref/password... (any digits), after room/unit/lot/block (1-3 digits),
// as a hotline after a rescue word, as a 4-digit postcode after zip/postal, or before a measure / small supply count (a leading zero is no cue)
const CUE = String.raw`(?:\s+(?:no\.?|number|is|ay))?\s*[:#-]?\s*$`; // code is 4829, ang code ay 4829, door code: 4829
const ID_ANY = new RegExp(String.raw`\b(?:code|pin|passcode|lockbox|lock|password|pw|reading|meter)${CUE}`, 'i');
const ID_REF = new RegExp(String.raw`\bref${CUE}`, 'i'); // a ref keeps 6+ digits only: "ref 5012345" stays, "ref 1780" and "ref #1780" are amounts
const ID_SMALL = /\b(?:room|unit|lot|block)(?:\s+(?:no\.?|number))?\s*#?\s*$/i; // no "is" / ":" for these: "the room is 950", "Room: 950" are prices
const ID_MONEY = new RegExp(String.raw`^(?:[^\w\n]+\w+){0,3}?[^\w\n]+${MONEY_POST}|^[^\w\n]*each\b`, 'i');
const ID_MONEY_SMALL = new RegExp(String.raw`^(?:[^\w\n]+\w+){0,3}?[^\w\n]+(?:${MWL}|lang|only|lamang|tonight|for)\b|^[^\w\n]*each\b`, 'i');
const ID_PAY = /\b(?:gcash|maya|bank|transfer|payment|paid|deposit|receipt)\b[^.\n]*$/i; // "GCash ref 1780" is an amount, "Door code 4829 sent" is a code
const POST_CUE = /\b(?:zip|postal(?:\s+code)?|postcode)[:,]?\s*$/i;
const HOT_CUE = /\b(?:call|pakicall|dial|tawag|hotline|bfp|pnp|police|fire|ambulance|emergency|red\s+cross|rescue)\b(?:[^\w\n]+\w+){0,3}?[^\w\n]*$/i;
const MEASURE = /^\s?(?:%|(?:ml|kg|sqm|g|l)\b(?!\/))/i; // 500 ml, 100%: up to 3 digits ("Maria 1780 ml" is an amount)
const WATT = /^ ?(?:kWh|Wh|kW|W)(?![A-Za-z/])(?!\s+(?!(?:in|at|of|and|or|when|on|to|max|continuous|output|peak)\b)[A-Za-z0-9])/; // 300 W, 300W (capital, not "1780 w breakfast", "300 W for 2 nights", "300 W 2 nights")
// 4+ digit watts need a device word RIGHT before the number ("EcoFlow 1800 W", "max output 1800 W"; not "EcoFlow Maria 1780 W")
const DEVICE = /\b(?:ecoflow|power\s*station|inverter|batter(?:y|ies)|generator|solar|aircon|fridge|refrigerator|heater|kettle|microwave|charger|appliance|capacity|rated|output|max)[^\w\n]*$/i;
const COUNT = /^\s?(?:rolls|towels|sheets|hangers|pillows|pillowcases|blankets|bottles|packs|sachets|pcs?|pieces|bars|cans|boxes|kits|sets)\b/i; // 120 rolls (1-3 digits)
const PEOPLE = /^\s?(?:guests|pax|persons|people)\b/i; // a head count, never 3+ digits
const MONEY_W = String.raw`rates?|totals?|price|paid|pay\w*|fees?|costs?|amount|balance|deposits?|bayad|refunds?|payouts?|revenue|nightly|dp|downpayment|gcash|cash|collected|received|owed?|utang|bal`;
const MONEY_BEFORE = new RegExp(String.raw`\b(?:${MONEY_W})\b[^\w\n]*(?:\w+[^\w\n]+)?$`, 'i'); // "rate 1780 pax", "DP ref 1780"
const MONEY_NEAR = new RegExp(String.raw`\b(?:${MONEY_W})\b[^\w\n]*(?:\w+[^\w\n]+){0,4}$`, 'i'); // units: a whole date + 1 word back ("Received Oct 15, 2026 950 pcs")
const keepNumber = (num: string, pre: string, post: string) => {
  const d = num.replace(/\D/g, '').length, paid = ID_PAY.test(pre) || MONEY_BEFORE.test(pre), money = ID_MONEY.test(post) || paid;
  return (!money && (ID_ANY.test(pre) || (d >= 6 && ID_REF.test(pre)))) || (d <= 3 && !paid && !ID_MONEY_SMALL.test(post) && ID_SMALL.test(pre))
    || (/^(?:911|117|143|160|166)$/.test(num) && !money && HOT_CUE.test(pre)) || (d === 4 && !money && POST_CUE.test(pre))
    || (!paid && !MONEY_NEAR.test(pre) && ((WATT.test(post) && (d <= 3 || DEVICE.test(pre))) || (d <= 3 && (MEASURE.test(post) || COUNT.test(post) || (d <= 2 && PEOPLE.test(post))))));
};

export function maskMoney(text: string): string {
  const kept = new Map<string, string>(); // protected span -> its original text
  const keep = (t: string, re: RegExp) => t.replace(re, (m) => { const k = S0 + 'x'.repeat(kept.size + 1) + S1; kept.set(k, m); return k; });
  let t = String(text ?? '').replace(/\[amount hidden\]/g, PH).replace(PAY_NO, '[number hidden]').replace(ACCOUNT_NO, '$1$2[number hidden]');
  for (const re of KEEP1) t = keep(t, re);
  t = t.replace(AMOUNT, PH).replace(MILLION, PH);
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
