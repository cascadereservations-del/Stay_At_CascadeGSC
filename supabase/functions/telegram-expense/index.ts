// telegram-expense v45 — strict surface guards, LLM expense/query/edit/void, notifyOps removed (no finance→OPS leak). Builds on v39.
// v40 deploy-fix (2026-05-31): (1) closed unterminated template literal; (2) lastMonthStr YYYY-MM-DD; (3) consumePending atomic.
// v40 deploy-bundle (2026-05-31): (4) errMsg(); (5) tgEdit clears keyboard; (6) null-safe category formatter.
// v40 assistant-bundle: query_stock + query_bookings, /status, help card, brownout-OCR, chunked sends, static cat cache, buildSummaryCard.
// v40 photo-intent gate: advisory keyword → OCR; OPS photo → [Scan]/[Ignore] confirm; Finance default receipt OCR.
// v46 (2026-06-03): Airbnb CSV upload handler (Finance only), inline parser, SHA-256 dedup, batch insert, reconcile.
// v47 (2026-06-03): Formatting pass — showCapabilities, buildWeatherLine, stock, status, summary, confirmMsg, bookingLine.
// v48 (2026-06-04): Markdown parse fix (buildWeatherLine); subMenuKb uniform 2-col grids.
// v49 (2026-06-04): Menu card width normalization — buildMenuHeader with figure-space padding.
// v50 (2026-06-04): Fix Finance menu wrapping. v49 padded the title line; long Finance title
//   ("🏠 Cascade Finance" + 18 spaces) exceeded safe mobile line length → word-wrap. Fix:
//   pad the SUBTITLE line when present; sub-menus pad title conservatively (cap at 28−titleLen).
// v51 (session 24): Fast-entry parser gated on numeric-first token.
//   "void pending 2 receipts" previously matched token `2` as expense amount before LLM dispatch.
//   Fix: parseAmount() only runs when FIRST token starts with a digit or ₱.
//   Non-numeric-leading text is forwarded to telegram-cassy (D-104, 2026-09-13); the v45 dispatch is gone.
// v52 (session I): cleanpayinvoice callback — dashboard "Send Invoice" → OPS card → cleaner tap marks fee_paid_at + fee_acked_at.
//   Stray backslash in deployed v52 caused Deno compilation error; stub v53 was deployed as placeholder.
// v53 (2026-06-06): Stub replacement — deploys the fixed v52 source. Version strings updated in handleStatus and handlePing.
// v108 (session 37, SPEC-16 / D-196): typed-marker replies replaced by telegram_pending awaiting_reply rows;
//   a reply to a bot card that asked nothing is refused and never reaches the expense parser (D-195).
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { withObservability } from '../_shared/observability.ts';
import { VISION_PROVIDER, hasVisionKey, visionExtractText } from '../_shared/cascade-core/vision.ts';
import { notifyMessengerBookingConfirmed } from '../_shared/cascade-core/messenger.ts';
import { templateOf, autoKeyboard } from '../_shared/cascade-core/format.ts'; // session 28: 📨 Copy/Revise taps
import { ackHash } from '../_shared/ack-hash.ts'; // SPEC-11: the vf:ack: button's short name for a finding
import { type Change, type CountItem, GROUP_LABEL, inventoryGroup, parseCountReply, reviewLines, SCOPE_GROUPS } from './count.ts'; // session 33: SPEC-03 /count
// session 37 (SPEC-16, D-196): the bot keeps who it asked, and for what, in telegram_pending ('awaiting_reply').
import { CANCELLED, COUNT_EXPIRED, countCardKeyboard, countCardText, countQtyPrompt, type Flow, NOT_WAITING, parseAmount as parseMoney, parseExpenseAnswer, parseManualClean, parseNamePriceQty, parseQty, refusal, routeText, setChange } from './reply.ts';

const SUPABASE_URL    = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE    = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const TG_TOKEN        = Deno.env.get('TELEGRAM_BOT_TOKEN') ?? '';
const FINANCE_CHAT    = Deno.env.get('TELEGRAM_FINANCE_CHAT_ID') ?? '';
const OPS_CHAT        = Deno.env.get('TELEGRAM_CHAT_ID') ?? '';
// 2026-09-13: CASCADE_GEMINI_BOT_KEY only - the bare GEMINI_BOT_KEY belongs to another project.
const GEMINI_KEY      = Deno.env.get('CASCADE_GEMINI_BOT_KEY') ?? '';
// 2026-09-16: receipt/advisory image reads now go through the same VISION_PROVIDER
// switch as ocr-receipt (D-090) instead of a hardcoded refused model — this file had
// its own separate inline OCR that never got that fix and was silently broken.
// v104 (session 27): that switch now lives in _shared/cascade-core/vision.ts (booking PRD task 2).
const TG_SECRET       = Deno.env.get('TELEGRAM_WEBHOOK_SECRET') ?? '';
const BOT_USERNAME    = (Deno.env.get('TELEGRAM_BOT_USERNAME') ?? '').replace(/^@/,'').toLowerCase();
const WEATHER_KEY     = Deno.env.get('GOOGLE_WEATHER_API_KEY') ?? '';
const GEN_SAN_LAT     = 6.1164;
const GEN_SAN_LNG     = 125.1716;
const PROPERTY_ID     = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
const RECEIPTS_BUCKET = 'expense-receipts';
const DISPATCH_MODEL  = 'gemini-2.5-flash';
const JSON_H          = { 'Content-Type': 'application/json' };

const LARGE_AMOUNT_THRESHOLD = 10_000;
const RECENT_DUP_DAYS        = 7;
const RECENT_DUP_MIN_AMOUNT  = 500;
const STOCKABLE_CATS = new Set(['supplies','cleaning','maintenance','repairs']);
const CASCADE_FEEDER       = '14-3';
const CASCADE_SUBSTATION_RE = /leon\s*ll?[ie]do/i;
const CASCADE_AREA_RE       = /\b(bria|san\s*isidro|conel)\b/i;
const ADVISORY_RE = /\b(brownout|advisor(?:y|ies)|socoteco|ngcp|outage|power\s*interruption|walang\s*kuryente|patay\s*(?:ang\s*)?ilaw)\b/i;
function captionWantsAdvisory(caption: unknown): boolean { const c = String(caption ?? '').trim().toLowerCase(); return c.startsWith('/brownout') || ADVISORY_RE.test(c); }

const isAllowedChat  = (id: unknown) => { const s = String(id??''); return (!!FINANCE_CHAT&&s===FINANCE_CHAT)||(!!OPS_CHAT&&s===OPS_CHAT); };
const isFinanceChat  = (id: unknown) => !!FINANCE_CHAT && String(id??'') === FINANCE_CHAT;

function isBotAddressed(msg: any): boolean {
  const text = String(msg.text ?? msg.caption ?? '');
  if (text.trimStart().startsWith('/')) return true;
  if (msg.reply_to_message?.from?.is_bot) return true;
  if (!BOT_USERNAME) return true;
  return text.toLowerCase().includes(`@${BOT_USERNAME}`);
}

function stripBotMention(text: string): string {
  if (!BOT_USERNAME) return text;
  return text.replace(new RegExp(`@${BOT_USERNAME}`, 'gi'), '').replace(/\s{2,}/g, ' ').trim();
}

async function tgCall(method: string, body: unknown): Promise<any> {
  const r = await fetch(`https://api.telegram.org/bot${TG_TOKEN}/${method}`,
    { method:'POST', headers:JSON_H, body:JSON.stringify(body), signal:AbortSignal.timeout(15_000) }).catch(()=>null);
  return r ? r.json().catch(()=>null) : null;
}
function splitForTelegram(text: string, max = 4000): string[] {
  if (text.length <= max) return [text];
  const out: string[] = []; let buf = '';
  for (const line of text.split('\n')) {
    const piece = line.length > max ? line.match(new RegExp(`.{1,${max}}`,'g')) ?? [line] : [line];
    for (const p of piece) {
      if (buf.length + p.length + 1 > max) { if (buf) out.push(buf); buf = p; }
      else buf = buf ? buf + '\n' + p : p;
    }
  }
  if (buf) out.push(buf);
  return out;
}
const isParseErr = (r: any) => r && r.ok === false && /can't parse|can.t parse|entities|parse_mode/i.test(String(r.description ?? ''));
async function tgSendOne(chatId: any, text: string, extra: Record<string,unknown> = {}): Promise<any> {
  let r = await tgCall('sendMessage', { chat_id:chatId, text, parse_mode:'Markdown', ...extra });
  if (isParseErr(r)) r = await tgCall('sendMessage', { chat_id:chatId, text, ...extra });
  return r;
}
async function tgSend(chatId: any, text: string, extra: Record<string,unknown> = {}): Promise<any> {
  const chunks = splitForTelegram(text); let last: any = null;
  for (let i = 0; i < chunks.length; i++) last = await tgSendOne(chatId, chunks[i], i === 0 ? extra : {});
  return last;
}
const tgReply   = (chatId: any, rid: number, text: string, extra: Record<string,unknown> = {}) => tgSend(chatId, text, { reply_to_message_id:rid, ...extra });
async function tgEdit(chatId: any, mid: number, text: string, rm?: unknown): Promise<any> {
  const t = text.length > 4000 ? text.slice(0,3999) + '\u2026' : text;
  const body: Record<string,unknown> = { chat_id:chatId, message_id:mid, text:t, parse_mode:'Markdown', reply_markup: rm ?? {inline_keyboard:[]} };
  let r = await tgCall('editMessageText', body);
  if (isParseErr(r)) { const { parse_mode, ...rest } = body; r = await tgCall('editMessageText', rest); }
  return r;
}
// v104 (session 27): receipt cards are photos, so a decision edits the caption, not the text.
const tgEditCaption = (chatId: any, mid: number, caption: string, rm?: unknown) => tgCall('editMessageCaption', { chat_id:chatId, message_id:mid, caption:caption.slice(0,1024), reply_markup: rm ?? {inline_keyboard:[]} });
const tgAnswerCB = (id: string, text?: string) => tgCall('answerCallbackQuery', { callback_query_id:id, ...(text?{text,show_alert:false}:{}) });

function notifyOps(_category: string, _loggedBy: string|null, _isPendingOcr: boolean): void {}

const json        = (d: unknown, s=200) => new Response(JSON.stringify(d),{status:s,headers:JSON_H});
const ackTelegram = () => new Response(JSON.stringify({ok:true}),{status:200,headers:JSON_H});

async function alreadyProcessed(db: any, updateId: unknown): Promise<boolean> {
  const id = Number(updateId); if (!Number.isFinite(id)) return false;
  const {data,error} = await db.from('telegram_processed_updates').upsert({update_id:id},{onConflict:'update_id',ignoreDuplicates:true}).select('update_id');
  if (error) { console.warn('alreadyProcessed:',error.message); return false; }
  return !data || data.length===0;
}
function purgeProcessed(db: any) { db.from('telegram_processed_updates').delete().lt('processed_at',new Date(Date.now()-2*86_400_000).toISOString()).then(()=>{}).catch(()=>{}); }

const shortRef     = (id: string) => id.slice(0,8).toUpperCase();
// Inverse of shortRef for uuid columns: the closed range of every uuid starting with the 8-hex ref.
const refRange =(ref: string): [string,string] => { const p=ref.toLowerCase(); return [`${p}-0000-0000-0000-000000000000`,`${p}-ffff-ffff-ffff-ffffffffffff`]; };
const toManilaDate = () => new Date().toLocaleDateString('en-CA',{timeZone:'Asia/Manila'});
function daysDiff(d: string) { return Math.max(0,Math.round((new Date(toManilaDate()+'T00:00:00Z').getTime()-new Date(d+'T00:00:00Z').getTime())/86_400_000)); }

function mdEsc(s: unknown): string { return String(s??'').replace(/([_*`\[])/g,'\\$1'); }
function errMsg(m: unknown): string { return mdEsc(String(m ?? 'unknown error').slice(0,150)); }
function peso(n: unknown): string { const x=Number(n); return (isFinite(x)?x:0).toLocaleString(); }
type LineItem = {name:string;qty:number;unit_price:number};
function normalizeLineItems(raw: any): LineItem[] {
  if (!Array.isArray(raw)) return [];
  return raw.map((it:any):LineItem=>{ if(typeof it==='string') return {name:it.trim(),qty:1,unit_price:0}; const q=Number(it?.qty),u=Number(it?.unit_price); return {name:String(it?.name??'').trim(),qty:isFinite(q)&&q>0?q:1,unit_price:isFinite(u)&&u>=0?u:0}; }).filter(it=>it.name.length>0);
}
function lineTotal(it: LineItem) { return (Number(it.qty)||1)*(Number(it.unit_price)||0); }
function itemsSubtotal(items: LineItem[]) { return items.reduce((s,it)=>s+lineTotal(it),0); }
function bytesToBase64(bytes:Uint8Array) { let bin=''; const c=0x8000; for(let i=0;i<bytes.length;i+=c) bin+=String.fromCharCode(...bytes.subarray(i,i+c)); return btoa(bin); }
function clamp01(n:unknown) { const x=Number(n); return isFinite(x)?Math.max(0,Math.min(1,x)):0; }
function validDate(d:unknown) { const s=String(d??''); if(!/^\d{4}-\d{2}-\d{2}$/.test(s)) return null; const t=new Date(s+'T00:00:00Z').getTime(); if(isNaN(t)||t>Date.now()+2*86_400_000||t<new Date('2020-01-01').getTime()) return null; return s; }
function lineItemsToText(items:any) { if(!Array.isArray(items)||!items.length) return ''; return items.map((it:any)=>typeof it==='string'?it:`${it?.name??'?'}${Number(it?.qty)?` x${it.qty}`:''}`).join(', ').slice(0,300); }

async function cleaningFeeFor(db:any,cleaningType:string,dateStr:string) {
  const {data}=await db.from('cleaner_rate_schedule').select('regular_rate,general_rate').lte('effective_from',dateStr).order('effective_from',{ascending:false}).limit(1).maybeSingle();
  return cleaningType==='deep_clean'?(Number(data?.general_rate)||500):(Number(data?.regular_rate)||500);
}
function sessionDate(s:any) { return s.checkout_date??s.checkin_date??(s.cleaned_at?String(s.cleaned_at).slice(0,10):toManilaDate()); }
function typeLabelOf(t:string|null|undefined) { return t==='deep_clean'?'Deep Clean':'Turnover'; }
function whoFrom(from:any) { return [from?.first_name,from?.username?`@${from.username}`:null,from?.id].filter(Boolean).join(' '); }

// ============ ASSISTANT CAPABILITIES (stock · bookings · status · help · brownout-OCR) ============
function feederRangeCoversCascade(s:string):boolean{
  const t=String(s).toLowerCase().replace(/feeder/g,'').trim();
  if(/(^|[^\d])14\s*-\s*3([^\d]|$)/.test(t)) return true;
  const m=t.match(/14\s*-\s*(\d+)\s*(?:to|-|–|—|until|\u2013)\s*14\s*-\s*(\d+)/);
  if(m){const lo=Number(m[1]),hi=Number(m[2]);return isFinite(lo)&&isFinite(hi)&&lo<=3&&3<=hi;}
  return false;
}
function advisoryAffectsCascade(affected:any):boolean{
  const fe=Array.isArray(affected?.feeders)?affected.feeders.map(String):[];
  const su=Array.isArray(affected?.substations)?affected.substations.map(String):[];
  const ar=Array.isArray(affected?.areas)?affected.areas.map(String):[];
  if(fe.some((f:string)=>feederRangeCoversCascade(f))) return true;
  if(su.some((s:string)=>feederRangeCoversCascade(s))) return true;
  if(su.some((s:string)=>CASCADE_SUBSTATION_RE.test(s))) return true;
  if(ar.some((a:string)=>CASCADE_AREA_RE.test(a))) return true;
  return false;
}
async function fetchPhotoBytesByFileId(fileId:string):Promise<{bytes:Uint8Array;mime:string}|null>{
  const fileMeta=await tgCall('getFile',{file_id:fileId});const filePath=fileMeta?.result?.file_path;
  if(!filePath)return null;
  const bytes=new Uint8Array((await fetch(`https://api.telegram.org/file/bot${TG_TOKEN}/${filePath}`).then(r=>r.arrayBuffer())) as ArrayBuffer);
  const ext=(filePath.split('.').pop()||'jpg').toLowerCase();
  return {bytes,mime:`image/${ext==='jpg'?'jpeg':ext}`};
}
function largestPhotoId(msg:any):string|null{const p=Array.isArray(msg.photo)?msg.photo:[];return p.length?p[p.length-1].file_id:null;}
async function fetchPhotoBytes(msg:any):Promise<{bytes:Uint8Array;mime:string}|null>{const id=largestPhotoId(msg);return id?fetchPhotoBytesByFileId(id):null;}
async function handleStockQuery(db:any,chatId:any,surface:'ops'|'finance',params:any){
  const filter=String(params?.filter??'low');const item=params?.item?String(params.item).trim().toLowerCase():null;const isFin=surface==='finance';
  const{data}=await db.from('inventory_items').select('name,qty_on_hand,reorder_below,unit,is_consumable,consumption_per_booking,unit_cost,sort_order').eq('property_id',PROPERTY_ID).eq('is_active',true).order('sort_order');
  let allRows=(data??[]) as any[];
  if(item) allRows=allRows.filter(r=>String(r.name??'').toLowerCase().includes(item));

  const isLowFn=(r:any)=>Number(r.qty_on_hand)<=Number(r.reorder_below);
  const isShortFn=(r:any)=>r.is_consumable&&Number(r.consumption_per_booking)>0&&Number(r.qty_on_hand)<Number(r.consumption_per_booking);
  const byRunway=(a:any,b:any)=>(Number(a.qty_on_hand)-Number(a.reorder_below))-(Number(b.qty_on_hand)-Number(b.reorder_below));

  const rowLine=(r:any,isLow:boolean):string=>{
    const qty=Number(r.qty_on_hand);const unit=r.unit?` ${mdEsc(r.unit)}`:'';
    const icon=isLow?'🔴':'✅';
    const urgency=isLow?(qty===0?'  _order today_':`  _(≤${peso(r.reorder_below)})_`):'';
    const shortNote=isShortFn(r)?'\n   _↳ May run short before next booking_':'';
    const costNote=isFin&&Number(r.unit_cost)>0?`  ·  ₱${peso(r.unit_cost)}/${mdEsc(r.unit||'unit')}`:'' ;
    return `${icon} ${mdEsc(r.name)}  —  ${peso(qty)}${unit}${urgency}${costNote}${shortNote}`;
  };

  if(filter==='all'||item){
    if(!allRows.length){await tgSend(chatId,'📦 No matching items.');return;}
    const lowRows=allRows.filter(isLowFn).sort(byRunway);
    const okRows=allRows.filter(r=>!isLowFn(r));
    const lines:string[]=['📦 *Stock*'];
    if(lowRows.length){lines.push('','*Needs restocking*');lowRows.forEach(r=>lines.push(rowLine(r,true)));}
    if(okRows.length){lines.push('','_Adequate_');okRows.forEach(r=>lines.push(rowLine(r,false)));}
    await tgSend(chatId,lines.join('\n'));
  }else{
    const lowRows=allRows.filter(isLowFn).sort(byRunway);
    if(!lowRows.length){await tgSend(chatId,'✅ All stock above reorder levels.');return;}
    const lines:string[]=['📦 *Low Stock*',''];
    lowRows.forEach(r=>lines.push(rowLine(r,true)));
    await tgSend(chatId,lines.join('\n'));
  }
}
function bookingLine(r:any,withPayout:boolean):string{
  const g=String(r.guest_name??'').trim();const name=(!g||g.toLowerCase()==='reserved')?'Guest':g;
  const inT=r.checkin_time?`  ·  from ${formatTime12(r.checkin_time)}`:'';
  const outT=r.checkout_time?`  ·  by ${formatTime12(r.checkout_time)}`:'';
  const nights=r.nights?`  ·  ${r.nights} night${r.nights!==1?'s':''}`:'' ;
  const pax=r.guest_count?`  ·  ${r.guest_count} guest${r.guest_count!==1?'s':''}`:'' ;
  let line=`*${mdEsc(name)}*\n   ${r.checkin_date}${inT} → ${r.checkout_date}${outT}${nights}${pax}`;
  const payout=Number(r.payout_amount||r.host_payout||0);
  if(withPayout&&payout>0)line+=`\n   💰 ₱${peso(payout)}${r.payout_date?`  ·  paid ${r.payout_date}`:''}`;
  return line;
}
async function handleStatus(db:any,chatId:any){
  const today=toManilaDate();
  const[pend,unpaid,low,nextCo,sync]=await Promise.all([
    db.from('transactions').select('id',{count:'exact',head:true}).eq('property_id',PROPERTY_ID).eq('status','pending_review'),
    db.from('cleaning_sessions').select('id',{count:'exact',head:true}).eq('property_id',PROPERTY_ID).is('fee_paid_at',null),
    db.from('inventory_items').select('qty_on_hand,reorder_below').eq('property_id',PROPERTY_ID).eq('is_active',true),
    db.from('airbnb_reservations').select('guest_name,checkout_date').eq('property_id',PROPERTY_ID).neq('status','cancelled').gte('checkout_date',today).order('checkout_date').limit(1),
    db.from('calendar_sync_log').select('created_at').order('created_at',{ascending:false}).limit(1),
  ]);
  const lowCount=((low.data??[]) as any[]).filter((r:any)=>Number(r.qty_on_hand)<=Number(r.reorder_below)).length;
  const co=(nextCo.data??[])[0];const lastSync=(sync.data??[])[0]?.created_at;
  await tgSend(chatId,[
    '🩺 *Cascade Status*',
    '',
    `Pending receipts   ${pend.count??0}`,
    `Unpaid cleans      ${unpaid.count??0}`,
    `Low-stock items    ${lowCount}`,
    '',
    co?`📤 Next checkout  ·  *${mdEsc(co.guest_name||'Guest')}*  ·  ${co.checkout_date}`:'📤 Next checkout  ·  none',
    lastSync?`🔄 Last sync  ·  ${String(lastSync).slice(0,16).replace('T',' ')} UTC`:'🔄 Last sync  ·  unknown',
    '',
    '_telegram-expense v56_',
  ].join('\n'));
}
function showCapabilities(chatId:any,surface:'ops'|'finance'){
  const ops=[
    '🏠 *What I can do — OPS*',
    '',
    '📌 *Post Notices*',
    '`/brownout`  `/holiday`  `/event`  `/reminder`',
    '_or just describe it_',
    '',
    '⚡ *Send Advisory*',
    'Send a SOCOTECO/NGCP power interruption photo',
    '_I\'ll flag if Feeder 14-3 is affected and log the brownout_',
    '',
    '📋 *Quick Actions*',
    '`/notices`  ·  Calendar  ·  `/weather`  ·  Turnover',
    '`/stock`  ·  _"what\'s low on stock?"_',
    '`/bookings`  ·  _"who\'s in this weekend?", "next guest"_',
    '',
    '_Type_ `/menu` _anytime._',
  ];
  const fin=[
    '💰 *What I can do — Finance*',
    '',
    '🧾 *Log Expenses*',
    'Type `250 supplies Puregold`, send a receipt photo,',
    'or just describe the expense',
    '',
    '📊 *Reports*',
    '`/summary`  ·  _"how much did we spend last month?"_',
    '',
    '🧹 *Cleaning Fees*',
    '`/payclean`  ·  `/manualclean`  ·  `/notifyclean`',
    '',
    '📦 *Stock & Bookings*',
    '`/stock`  ·  _"what\'s low?"_',
    '`/bookings`  ·  _"next guest", "free this weekend?"_  _(payouts shown here)_',
    '',
    '📂 *Airbnb Sync*',
    'Send your Airbnb CSV to import earnings',
    '',
    '`/status`  ·  `/void REFCODE`  ·  `/datahealth`',
    '',
    '_Type_ `/menu` _anytime._',
  ];
  return tgSend(chatId,(surface==='finance'?fin:ops).join('\n'));
}
function buildAdvisoryPrompt(today:string):string{
  return `You are reading a Philippine electric-cooperative power-interruption advisory image (SOCOTECO II or NGCP) for General Santos City. Today is ${today}.\nReturn ONLY a JSON object, no markdown:\n{"is_advisory":boolean,"source":"SOCOTECO"|"NGCP"|null,"purpose":string,"occurrences":[{"date":"YYYY-MM-DD","start_time":"HH:MM:00"|null,"end_time":"HH:MM:00"|null,"duration_hours":number|null}],"affected":{"feeders":string[],"substations":string[],"areas":string[]},"confidence":number}\nRules:\n- is_advisory=false if the image is not a power-interruption advisory; set confidence below 0.3.\n- Ignore any schedule marked RESCHEDULED, struck-through, or cancelled. Return only the ACTIVE schedule.\n- Each distinct time window is its OWN occurrence (a morning AND an evening window on the same day = two occurrences).\n- feeders e.g. ["7-2"] or a range string ["14-1 to 14-4"]. substations e.g. ["Leon Llido"]. areas = barangay/subdivision names if listed instead of feeders.\n- Convert "8am" / "12:00NN" / "6:00 PM" to 24h HH:MM:00. duration_hours from the stated duration or end minus start.\n- purpose: short phrase, e.g. "metering equipment replacement at NGCP Gensan".`;
}
async function geminiExtractAdvisory(bytes:Uint8Array,mime:string):Promise<any>{
  const txt=await visionExtractText(buildAdvisoryPrompt(toManilaDate()),bytes,mime);
  return JSON.parse(txt.replace(/^```json\s*|\s*```$/g,'').trim());
}
function advisoryOccLines(occ:any[]):string[]{
  return occ.map((o:any)=>{const t=o.start_time?` ${String(o.start_time).slice(0,5)}`:'';const tail=o.duration_hours?` (${o.duration_hours}h)`:(o.end_time?`–${String(o.end_time).slice(0,5)}`:'');return `⚡ ${o.date}${t}${tail}`;});
}
async function runAdvisoryOcr(db:any,chatId:any,bytes:Uint8Array,mime:string,from:any){
  if(!hasVisionKey()){await tgSend(chatId,`⚠️ Advisory reading unavailable (no key for VISION_PROVIDER=${VISION_PROVIDER}).`);return;}
  await tgSend(chatId,'📸 Reading the advisory…');
  let adv:any;try{adv=await geminiExtractAdvisory(bytes,mime);}catch(e){console.warn('advisory OCR:',String(e));await tgSend(chatId,'⚠️ Could not read this image.');return;}
  const occ=Array.isArray(adv?.occurrences)?adv.occurrences.filter((o:any)=>validDate(o?.date)):[];
  if(!adv?.is_advisory||Number(adv?.confidence)<0.4||!occ.length){await tgSend(chatId,'⚠️ Couldn\'t find a valid power-interruption schedule in this image.');return;}
  const affects=advisoryAffectsCascade(adv.affected);const src=adv.source==='NGCP'?'NGCP':'SOCOTECO II';
  const pid=await createPending(db,chatId,'advisory_notice',{occurrences:occ,purpose:String(adv.purpose??'').slice(0,200),source:src,from:{first_name:from?.first_name,username:from?.username,id:from?.id}});
  const body=[affects?'⚡ *Power interruption affecting Cascade*':'ℹ️ *This advisory does not list Feeder 14-3 / Leon Llido*',mdEsc(src)+(adv.purpose?` — ${mdEsc(String(adv.purpose).slice(0,120))}`:''),'', ...advisoryOccLines(occ)].join('\n');
  const saveBtn={text:affects?`✅ Save ${occ.length} brownout notice${occ.length!==1?'s':''}`:'Save anyway',callback_data:`adv_confirm:${pid}`};
  await tgSend(chatId,body,{reply_markup:{inline_keyboard:[[saveBtn],[{text:'❌ Cancel',callback_data:`llm_cancel:${pid}`}]]}});
}

async function payCleanList(db:any,chatId:any) {
  const {data}=await db.from('cleaning_sessions').select('id,cleaner_name,cleaning_type,checkin_date,checkout_date,cleaned_at').eq('property_id',PROPERTY_ID).is('fee_paid_at',null).order('cleaned_at',{ascending:false}).limit(10);
  const sessions=(data??[]) as any[];
  if (!sessions.length){await tgSend(chatId,'\u2705 No unpaid cleans. All settled.');return;}
  const rows:any[][]=[];
  for (const s of sessions){const d=sessionDate(s);const fee=await cleaningFeeFor(db,s.cleaning_type??'turnover',d);rows.push([{text:`${s.cleaner_name??'Cleaner'} \u00b7 ${d.slice(5)} \u00b7 ${typeLabelOf(s.cleaning_type)} \u00b7 \u20b1${peso(fee)}`,callback_data:`pcsel:${s.id}`}]);}
  await tgSend(chatId,'\uD83E\uDDF9 *Pay Cleaning Fees*\nTap a clean you have already paid for:',{reply_markup:{inline_keyboard:rows}});
}
async function paySessionCard(db:any,chatId:any,msgId:number|null,sessionId:string) {
  const {data:s}=await db.from('cleaning_sessions').select('id,cleaner_name,cleaning_type,checkin_date,checkout_date,cleaned_at,fee_paid_at').eq('id',sessionId).maybeSingle();
  if(!s){await tgSend(chatId,'\u26a0\ufe0f Clean not found.');return;}
  if(s.fee_paid_at){const txt='\u2139\ufe0f That clean is already marked paid.';if(msgId)await tgEdit(chatId,msgId,txt);else await tgSend(chatId,txt);return;}
  const d=sessionDate(s);const fee=await cleaningFeeFor(db,s.cleaning_type??'turnover',d);
  const text=[`\uD83E\uDDF9 *Pay cleaning fee*`,`\uD83D\uDC64 ${mdEsc(s.cleaner_name??'Cleaner')}`,`\uD83D\uDCC5 ${d} \u00b7 ${typeLabelOf(s.cleaning_type)}`,`\uD83D\uDCB5 Fee: *\u20b1${peso(fee)}*`,``,`Confirm the amount you paid, or edit it.`].join('\n');
  const kb={inline_keyboard:[[{text:`\u2705 Mark Paid \u20b1${peso(fee)}`,callback_data:`pcpay:${s.id}:${fee}`}],[{text:'\u270f\ufe0f Edit amount',callback_data:`pcedit:${s.id}`},{text:'\u274c Cancel',callback_data:'pccancel'}]]};
  if(msgId)await tgEdit(chatId,msgId,text,kb);else await tgSend(chatId,text,{reply_markup:kb});
}
async function bookCleaningFee(db:any,sessionId:string,amount:number,loggedBy:string|null):Promise<{ok:boolean;already?:boolean;cleaner?:string;date?:string;error?:string}> {
  const {data:s}=await db.from('cleaning_sessions').select('id,cleaner_name,cleaning_type,checkin_date,checkout_date,cleaned_at,fee_paid_at').eq('id',sessionId).maybeSingle();
  if(!s) return {ok:false,error:'not_found'};
  if(s.fee_paid_at) return {ok:true,already:true,cleaner:s.cleaner_name,date:sessionDate(s)};
  const d=sessionDate(s);
  const {data:row,error}=await db.from('transactions').insert({property_id:PROPERTY_ID,txn_type:'expense',category:'cleaning',status:'confirmed',source:'cleaner_fee',gross_amount:amount,payee_name:s.cleaner_name??null,transaction_date:d,external_ref:`cleanfee:${s.id}`,notes:`Cleaning fee \u2014 ${s.cleaner_name??'cleaner'}, ${d}, ${typeLabelOf(s.cleaning_type)}. Session ${shortRef(s.id)}.`,logged_by:loggedBy}).select('id').single();
  let txnId:string|null=null;
  if(error){if(error.code==='23505'){const {data:ex}=await db.from('transactions').select('id').eq('external_ref',`cleanfee:${s.id}`).maybeSingle();txnId=ex?.id??null;}else return {ok:false,error:error.message};}
  else txnId=row.id;
  await db.from('cleaning_sessions').update({fee_amount:amount,fee_paid_at:new Date().toISOString(),fee_txn_id:txnId}).eq('id',s.id).is('fee_paid_at',null);
  return {ok:true,cleaner:s.cleaner_name??'cleaner',date:d};
}
async function bookManualCleaningFee(db:any,cleaner:string,dateStr:string,amount:number,notes:string|null,loggedBy:string|null):Promise<{ok:boolean;already?:boolean;cleaner?:string;date?:string;error?:string}> {
  const submissionId=`manual-${Date.now()}-${Math.floor(Math.random()*1e6)}`;
  const {data:sess,error:sErr}=await db.from('cleaning_sessions').insert({submission_id:submissionId,property_id:PROPERTY_ID,cleaner_name:cleaner,cleaning_type:'turnover',checkout_date:dateStr,cleaned_at:new Date().toISOString(),notes}).select('id').single();
  if(sErr||!sess) return {ok:false,error:sErr?.message??'session_insert_failed'};
  return await bookCleaningFee(db,sess.id,amount,loggedBy);
}
async function promptManualClean(db:any,chatId:any,fromId:unknown) {
  await ask(db,chatId,fromId,'manual_clean',{},'\u270d\ufe0f Manual cleaning fee\nType: cleaner, date, amount \u2014 like  Honey, 05-28, 500\nDate can be today or yesterday. Add a note after another comma.');
}
async function handleManualCleanAnswer(db:any,chatId:any,msg:any,m:{cleaner:string;dateTok:string;amount:number;notes:string|null}) {
  const{cleaner,dateTok,amount,notes}=m;
  const res=await bookManualCleaningFee(db,cleaner,resolveDate(dateTok),amount,notes,whoFrom(msg.from??{}));
  if(!res.ok){await tgReply(chatId,msg.message_id,`\u26a0\ufe0f Could not save: ${errMsg(res.error)}`);return;}
  await tgReply(chatId,msg.message_id,[`\u2705 *Manual cleaning fee recorded*`,`\uD83D\uDC64 ${mdEsc(cleaner)} \u00b7 \uD83D\uDCC5 ${resolveDate(dateTok)} \u00b7 \uD83D\uDCB5 \u20b1${peso(amount)}`,...(notes?[`\uD83D\uDCDD ${mdEsc(notes)}`]:[]),`_Booked to ledger + clean history. Run /notifyclean to send the ack card._`].join('\n'));
}
async function notifyCleanAcks(db:any,chatId:any) {
  if(!OPS_CHAT){await tgSend(chatId,'\u26a0\ufe0f OPS group not configured.');return;}
  const {data}=await db.from('cleaning_sessions').select('id,cleaner_name,cleaning_type,checkin_date,checkout_date,cleaned_at,fee_amount').eq('property_id',PROPERTY_ID).not('fee_paid_at','is',null).is('fee_acked_at',null).order('cleaned_at',{ascending:true});
  const sessions=(data??[]) as any[];
  if(!sessions.length){await tgSend(chatId,'\u2705 Nothing awaiting acknowledgement.');return;}
  const byCleaner=new Map<string,any[]>();
  for(const s of sessions){const c=s.cleaner_name??'Cleaner';if(!byCleaner.has(c))byCleaner.set(c,[]);byCleaner.get(c)!.push(s);}
  let sent=0;
  for(const [cleaner,items] of byCleaner){
    const total=items.reduce((sum,it)=>sum+Number(it.fee_amount??0),0);
    await tgSend(OPS_CHAT,[`\uD83E\uDDF9 *Cleaning Fees Settled*`,`\uD83D\uDC64 ${mdEsc(cleaner)}`,`\uD83D\uDCB5 Total paid: *\u20b1${peso(total)}* (${items.length} clean${items.length!==1?'s':''})`,``,...items.map(it=>`  \u2022 ${sessionDate(it)} \u00b7 ${typeLabelOf(it.cleaning_type)} \u00b7 \u20b1${peso(it.fee_amount)}`),``,`_Tap to acknowledge you received this payment._`].join('\n'),{reply_markup:{inline_keyboard:[[{text:'\u2705 Acknowledge Payment',callback_data:`cleanerack:${encodeURIComponent(cleaner)}`}]]}});
    sent++;
  }
  await tgSend(chatId,`\uD83D\uDCE8 Sent ${sent} acknowledgement card${sent!==1?'s':''} to OPS.`);
}

interface RainWindow {startHour:number;endHour:number;peakProb:number;}
interface TomorrowWx {description:string;high:number;low:number;feelsLikeHigh:number;rainProb:number;thunderProb:number;}
interface WeatherData {temp:number;apparent:number;rainProb:number;uvIndex:number;description:string;humidity:number;thunderProb:number;rainWindow?:RainWindow;tomorrow?:TomorrowWx;sunrise?:string;sunset?:string;}
function descToEmoji(desc:string) {
  const d=(desc??'').toLowerCase();
  if(d.includes('heavy thunder')||d.includes('strong thunder')) return '\u26c8\ufe0f';
  if(d.includes('thunder')||d.includes('storm')) return '\u26c8\ufe0f';
  if(d.includes('heavy rain')) return '\uD83C\uDF27\ufe0f';
  if(d.includes('rain')||d.includes('shower')||d.includes('drizzle')) return '\uD83C\uDF26\ufe0f';
  if(d.includes('fog')||d.includes('mist')||d.includes('haze')) return '\uD83C\uDF2b\ufe0f';
  if(d.includes('mostly cloudy')) return '\uD83C\uDF25\ufe0f';
  if(d.includes('partly cloudy')) return '\u26c5';
  if(d.includes('cloudy')||d.includes('overcast')) return '\u2601\ufe0f';
  if(d.includes('clear')||d.includes('sunny')) return '\u2600\ufe0f';
  return '\uD83C\uDF24\ufe0f';
}
function uvLabel(uv:number) { if(uv<=2)return'Low';if(uv<=5)return'Moderate';if(uv<=7)return'High';if(uv<=10)return'Very High';return'Extreme'; }
function fmtHour(h:number) { return `${h===0?12:h>12?h-12:h}:00 ${h>=12?'PM':'AM'}`; }
function utcToManilaTime(s:string) { if(!s)return''; try{return new Date(s).toLocaleTimeString('en-US',{timeZone:'Asia/Manila',hour:'numeric',minute:'2-digit',hour12:true}).replace(':00 ',' ');}catch{return'';} }
async function fetchWeather():Promise<WeatherData|null> {
  if(!WEATHER_KEY) return null;
  try{
    const base='https://weather.googleapis.com/v1',loc=`location.latitude=${GEN_SAN_LAT}&location.longitude=${GEN_SAN_LNG}`,k=`key=${WEATHER_KEY}`;
    const today=toManilaDate();const[todayY,todayM,todayD]=today.split('-').map(Number);
    const[curRes,hrRes,dayRes]=await Promise.all([fetch(`${base}/currentConditions:lookup?${k}&${loc}`,{signal:AbortSignal.timeout(8_000)}),fetch(`${base}/forecast/hours:lookup?${k}&${loc}&hours=24`,{signal:AbortSignal.timeout(8_000)}),fetch(`${base}/forecast/days:lookup?${k}&${loc}&days=2`,{signal:AbortSignal.timeout(8_000)})]);
    if(!curRes.ok) return null;
    const cur=await curRes.json(),hr=hrRes.ok?await hrRes.json():null,day=dayRes.ok?await dayRes.json():null;
    const allH=(hr?.forecastHours??[]) as any[];
    const todH=allH.filter((h:any)=>h.displayDateTime?.year===todayY&&h.displayDateTime?.month===todayM&&h.displayDateTime?.day===todayD);
    const rh=todH.map((h:any)=>({hour:Number(h.displayDateTime?.hours??0),prob:Number(h.precipitation?.probability?.percent??0)})).filter(x=>x.prob>=40);
    const rainWindow:RainWindow|undefined=rh.length>0?{startHour:rh[0].hour,endHour:rh[rh.length-1].hour,peakProb:Math.max(...rh.map(x=>x.prob))}:undefined;
    const thunderProb=todH.length?Math.max(0,...todH.map((h:any)=>Number(h.thunderstormProbability??0))):Math.round(Number(cur.thunderstormProbability??0));
    const td=(day?.forecastDays??[])[0];
    const sunrise=td?.sunEvents?.sunriseTime?utcToManilaTime(td.sunEvents.sunriseTime):undefined;
    const sunset=td?.sunEvents?.sunsetTime?utcToManilaTime(td.sunEvents.sunsetTime):undefined;
    const tmr=(day?.forecastDays??[])[1];
    const tomorrow:TomorrowWx|undefined=tmr?{description:String(tmr.daytimeForecast?.weatherCondition?.description?.text??''),high:Math.round(Number(tmr.maxTemperature?.degrees??0)),low:Math.round(Number(tmr.minTemperature?.degrees??0)),feelsLikeHigh:Math.round(Number(tmr.feelsLikeMaxTemperature?.degrees??0)),rainProb:Math.round(Number(tmr.daytimeForecast?.precipitation?.probability?.percent??0)),thunderProb:Math.round(Number(tmr.daytimeForecast?.thunderstormProbability??0))}:undefined;
    return{temp:Math.round(Number(cur.temperature?.degrees??0)),apparent:Math.round(Number(cur.feelsLikeTemperature?.degrees??0)),rainProb:Math.round(Number(cur.precipitation?.probability?.percent??0)),uvIndex:Math.round(Number(cur.uvIndex??0)),description:String(cur.weatherCondition?.description?.text??''),humidity:Math.round(Number(cur.relativeHumidity??0)),thunderProb,rainWindow,tomorrow,sunrise,sunset};
  }catch(err){console.warn('fetchWeather:',String(err));return null;}
}
function buildWeatherLine(w:WeatherData|null) {
  if(!w) return '';
  const emoji=descToEmoji(w.description);
  const lines:string[]=[];

  lines.push(`${emoji} *Weather — General Santos City*`);

  const heatTag=w.apparent>=38?' · Extreme heat':w.apparent>=35?' · Very hot':w.apparent>=32?' · Hot and humid':'';
  lines.push(`${w.description} · ${w.temp}°C (feels ${w.apparent}°C)${heatTag}`);

  lines.push(`UV ${w.uvIndex} ${uvLabel(w.uvIndex)} · Humidity ${w.humidity}%`);

  if(w.sunrise&&w.sunset) lines.push(`🌅 ${w.sunrise} · 🌇 ${w.sunset}`);

  if(w.thunderProb>=40){
    const sev=w.thunderProb>=70?' · secure outdoor items':'';
    lines.push(`⚡ Thunderstorm ${w.thunderProb}%${sev}`);
  }
  if(w.rainWindow){
    const{startHour,endHour,peakProb}=w.rainWindow;
    const dur=Math.max(1,endHour-startHour+1);
    const range=startHour===endHour?`around ${fmtHour(startHour)}`:`${fmtHour(startHour)}–${fmtHour(endHour)}`;
    lines.push(`🌧 Rain ${range} · ~${dur}h · peak ${peakProb}%`);
  }else if(w.rainProb>=40){
    lines.push(`🌧 Rain possible (${w.rainProb}%)`);
  }

  if(w.tomorrow){
    const tw=w.tomorrow;const tEmoji=descToEmoji(tw.description);
    const tRain=tw.rainProb>=40?` · ${tw.rainProb}% rain`:'';
    const tThund=tw.thunderProb>=40?' ⚡':'';
    lines.push(`— Tomorrow: ${tEmoji} ${tw.description} · ${tw.low}–${tw.high}°C${tRain}${tThund}`);
  }

  return lines.join('\n');
}
async function sendWeather(chatId:any) { const w=await fetchWeather(); if(!w){await tgSend(chatId,'\u26a0\ufe0f Weather unavailable right now.');return;} const t=buildWeatherLine(w); if(t) await tgSend(chatId,t); }

function addDaysStr(dateStr:string,n:number) { const d=new Date(dateStr+'T00:00:00Z');d.setUTCDate(d.getUTCDate()+n);return d.toISOString().slice(0,10); }
function formatTime12(t:string|null|undefined) { if(!t)return'';const[hh,mm]=String(t).split(':');const h=parseInt(hh,10);return`${h===0?12:h>12?h-12:h}:${mm} ${h>=12?'PM':'AM'}`; }
function formatDayHeader(dateStr:string,label:string|null) { const f=new Date(dateStr+'T00:00:00Z').toLocaleDateString('en-PH',{timeZone:'UTC',weekday:'short',day:'numeric',month:'short'});return label?`${label}, ${f}`:f; }
function guestDisplaySched(row:any,resolved?:string) { if(resolved)return mdEsc(resolved);const n=String(row.guest_name??'').trim();if(n)return mdEsc(n);const s=String(row.raw_summary??'').trim();if(s&&s.toLowerCase()!=='reserved')return mdEsc(s);return'Airbnb Guest'; }
async function sendSchedule(chatId:any,db:any) {
  const today=toManilaDate();const days=[today,addDaysStr(today,1),addDaysStr(today,2)];
  const [{data:arrData},{data:depData},{data:resData}]=await Promise.all([db.from('calendar_events').select('guest_name,raw_summary,checkin_date,checkin_time,nights,source').eq('property_id',PROPERTY_ID).eq('status','confirmed').in('checkin_date',days),db.from('calendar_events').select('guest_name,raw_summary,checkout_date,checkout_time,source').eq('property_id',PROPERTY_ID).eq('status','confirmed').in('checkout_date',days),db.from('airbnb_reservations').select('guest_name,checkin_date,checkout_date').or(`checkin_date.in.(${days.join(',')}),checkout_date.in.(${days.join(',')})`).not('guest_name','is',null)]);
  const arrivals=(arrData??[]) as any[];const departures=(depData??[]) as any[];
  const rcIn=new Map<string,string>();const rcOut=new Map<string,string>();
  for(const r of ((resData??[]) as any[])){if(r.guest_name){if(r.checkin_date)rcIn.set(String(r.checkin_date),r.guest_name);if(r.checkout_date)rcOut.set(String(r.checkout_date),r.guest_name);}}
  const parts:string[]=['\uD83D\uDD04 *Turnover Schedule*'];
  for(let i=0;i<3;i++){
    const day=days[i];const dayArr=arrivals.filter(r=>String(r.checkin_date)===day);const dayDep=departures.filter(r=>String(r.checkout_date)===day);
    const lines:string[]=[`\uD83D\uDCC5 *${formatDayHeader(day,(['Today','Tomorrow',null] as any)[i])}*`];
    for(const r of dayDep){const g=guestDisplaySched(r,rcOut.get(day));lines.push(`   \uD83D\uDCE4 *${g}* checks out${r.checkout_time?` \u00b7 by ${formatTime12(r.checkout_time)}`:''}`);}
    for(const r of dayArr){const g=guestDisplaySched(r,rcIn.get(day));lines.push(`   \uD83D\uDCE5 *${g}* checks in${r.nights?` \u00b7 ${r.nights} night${r.nights!==1?'s':''}`:''} ${r.checkin_time?` \u00b7 from ${formatTime12(r.checkin_time)}`:''}`.trimEnd());}
    if(dayArr.length>0&&dayDep.length>0) lines.push(`   \u26a1 Same-day turnover \u2014 coordinate cleaning window`);
    if(dayArr.length===0&&dayDep.length===0) lines.push(`   _No activity_`);
    parts.push(lines.join('\n'));
  }
  await tgSend(chatId,parts.join('\n\n'));
}

const MENU_MAIN='🏠 *Cascade Finance*\n\nSelect a section:';
const OPS_MENU_TEXT='📌 *Cascade OPS*\n\nWhat do you need?';
const MENU_TIPS:Record<string,string>={
  fastentry:['💡 *Fast entry*','Type `<amount> <category>` — amount must be first.','','e.g. `250 supplies Puregold`','e.g. `1500 electricity`','','_Category is auto-detected from keywords._'].join('\n'),
  ocr:['📸 *Receipt photo (OCR)*','Send any photo directly to this chat.','The bot reads it automatically, then you review each item before confirming.'].join('\n'),
  void:['❌ *Void an entry*','Type `/void REFCODE` to discard a transaction.','','e.g. `/void 28DCABC7`','','_Ref code is shown when the expense is logged._'].join('\n'),
  cassy:['🤖 *Ask Cassy*','Type `/cassy` and your question. A message that *starts* with `Cassy` works too.','Anything else in this chat she never sees.','','e.g. `/cassy when did Ashley Abutazil stay with us?`','e.g. `Cassy, who arrives this week?`','e.g. `/deep …` for the deeper model','','_She reads bookings, guests, stock and the ledger. She never writes without a tap._'].join('\n'),
  draft:['✍️ *Draft a guest reply*','`/draft <what the guest wrote>` or `cassy reply: …`','Or send a chat screenshot captioned `cassy draft`.','','_You get a reply to copy, in our voice, with a risk flag. Nothing is sent._'].join('\n'),
};
const TIP_BACK:Record<string,string>={fastentry:'log',ocr:'inventory',void:'commands',cassy:'cassy',draft:'cassy'};

function mainMenuKb() { return {inline_keyboard:[[{text:'💰 Log Expense',callback_data:'menu:log'},{text:'🧹 Cleaning Fees',callback_data:'menu:cleaning'}],[{text:'📊 Reports',callback_data:'menu:commands'},{text:'📌 OPS Notices',callback_data:'menu:notices'}],[{text:'📦 Inventory',callback_data:'menu:inventory'},{text:'🤖 Cassy',callback_data:'menu:cassy'}]]}; }
function opsMenuKb() { return {inline_keyboard:[[{text:'⚡ Brownout',callback_data:'menu:do:nt:brownout'},{text:'📅 Calendar',callback_data:'menu:do:cal'}],[{text:'🌦 Weather now',callback_data:'menu:do:weather'},{text:'🔄 Turnover',callback_data:'menu:do:schedule'}],[{text:'📦 Stock check',callback_data:'menu:do:stock'},{text:'📋 Full inventory',callback_data:'menu:do:inventory'}],[{text:'🤖 Ask Cassy',callback_data:'menu:tip:cassy'},{text:'✍️ Draft a reply',callback_data:'menu:tip:draft'}],[{text:'📋 View all notices',callback_data:'menu:do:notices'}]]}; }

// Lloyd, 2026-09-22: "instead of the / button it should be like a symbol or something that will
// show the full buttons". A persistent reply keyboard sits above the message box and Telegram gives
// it its own toggle symbol beside the input - tapping that shows or hides the whole grid, with no
// command to remember (the check-the-user-POV rule: buttons, not remembered syntax).
//
// A reply-keyboard button sends its LABEL as ordinary text, so each label is translated straight
// back into a slash command that already exists. That is the whole implementation: no new dispatch,
// and no second source of truth for what a button does.
//
// Only commands that work with NO arguments are on here. /brownout and /draft both need arguments,
// so they stay behind the Menu button rather than firing an incomplete command from a tap.
const KB_LABEL_CMD: Record<string,string> = {
  '📦 Stock check':'/stock', '📋 Full inventory':'/inventory', '📋 Notices':'/notices',
  '🤖 Ask Cassy':'/cassy', '☰ Menu':'/menu',
  '💰 Log Expense':'/log', '📊 Summary':'/summary', '📌 Notices':'/notices',
  '🧾 Status':'/status', '🤖 Cassy':'/cassy',
};
const opsReplyKb = () => ({keyboard:[[{text:'📦 Stock check'},{text:'📋 Full inventory'}],[{text:'📋 Notices'},{text:'🤖 Ask Cassy'}],[{text:'☰ Menu'}]],is_persistent:true,resize_keyboard:true});
const finReplyKb = () => ({keyboard:[[{text:'💰 Log Expense'},{text:'📦 Stock check'}],[{text:'📊 Summary'},{text:'📌 Notices'}],[{text:'🧾 Status'},{text:'☰ Menu'}]],is_persistent:true,resize_keyboard:true});

function buildMenuHeader(title:string, subtitle:string, keyboard:{text:string}[][]): string {
  const longestRow = keyboard.length
    ? Math.max(...keyboard.map(row => row.reduce((sum,btn) => sum + btn.text.length, 0)))
    : 0;

  if (subtitle) {
    const padLen = Math.min(Math.max(0, longestRow - subtitle.length), 20);
    const pad = '\u2007'.repeat(padLen);
    return `${title}\n\n${subtitle}${pad}`;
  }

  const visibleLen = title.replace(/[*_`]/g,'').length;
  const padLen = Math.min(Math.max(0, longestRow - visibleLen), Math.max(0, 28 - visibleLen));
  const pad = '\u2007'.repeat(padLen);
  return `${title}${pad}`;
}

function subMenuKb(group:string):{text:string;kb:object} {
  const back={text:'← Back',callback_data:'menu:main'};
  switch(group){
    case 'log':{
      const rows=[[{text:'📋 Guided  /log',callback_data:'menu:do:log'},{text:'💡 Fast entry',callback_data:'menu:tip:fastentry'}],[{text:'📸 Receipt OCR',callback_data:'menu:tip:ocr'},back]];
      return{text:buildMenuHeader('💰 *Log Expense*','',rows),kb:{inline_keyboard:rows}};
    }
    case 'cleaning':{
      const rows=[[{text:'💵 Mark paid',callback_data:'menu:do:payclean'},{text:'✍️ Manual entry',callback_data:'menu:do:manualclean'}],[{text:'📢 OPS ack card',callback_data:'menu:do:notifyclean'},back]];
      return{text:buildMenuHeader('🧹 *Cleaning Fees*','',rows),kb:{inline_keyboard:rows}};
    }
    case 'commands':{
      const rows=[[{text:'📈 Summary',callback_data:'menu:do:summary'},{text:'❌ Void entry',callback_data:'menu:tip:void'}],[back]];
      return{text:buildMenuHeader('📊 *Reports*','',rows),kb:{inline_keyboard:rows}};
    }
    case 'notices':{
      const rows=[[{text:'⚡ Brownout',callback_data:'menu:do:nt:brownout'},{text:'📅 Calendar',callback_data:'menu:do:cal'}],[{text:'📋 All notices',callback_data:'menu:do:notices'},{text:'🌦 Weather',callback_data:'menu:do:weather'}],[{text:'🔄 Turnover',callback_data:'menu:do:schedule'},back]];
      return{text:buildMenuHeader('📌 *OPS Notices*','',rows),kb:{inline_keyboard:rows}};
    }
    case 'inventory':{ // session 28
      const rows=[[{text:'📦 Low stock  /stock',callback_data:'menu:do:stock'},{text:'📋 Full list  /inventory',callback_data:'menu:do:inventory'}],[{text:'📝 Update counts',callback_data:'menu:do:count'},{text:'📸 Purchase receipt',callback_data:'menu:tip:ocr'}],[{text:'🖥 Open dashboard',url:'https://cascadereservations-del.github.io/cascade-admin-dashboard/#/inventory'}],[back]];
      return{text:buildMenuHeader('📦 *Inventory*','',rows),kb:{inline_keyboard:rows}};
    }
    case 'cassy':{ // session 28
      const rows=[[{text:'🤖 How to ask',callback_data:'menu:tip:cassy'},{text:'✍️ Draft a guest reply',callback_data:'menu:tip:draft'}],[back]];
      return{text:buildMenuHeader('🤖 *Cassy*','',rows),kb:{inline_keyboard:rows}};
    }
    default:{const kb=mainMenuKb();return{text:buildMenuHeader('🏠 *Cascade Finance*','Select a section:',kb.inline_keyboard),kb};}
  }
}
async function showMenu(chatId:any,msgId?:number) {
  const isF=isFinanceChat(chatId);
  const kb=isF?mainMenuKb():opsMenuKb();
  const text=isF
    ? buildMenuHeader('🏠 *Cascade Finance*','Select a section:',kb.inline_keyboard)
    : buildMenuHeader('📌 *Cascade OPS*','What do you need?',kb.inline_keyboard);
  if(msgId)await tgEdit(chatId,msgId,text,kb);else await tgSend(chatId,text,{reply_markup:kb});
}

function isDateLike(t:string) { return ['today','tomorrow','yesterday'].includes(t.toLowerCase())||/^\d{4}-\d{2}-\d{2}$/.test(t)||/^\d{1,2}-\d{1,2}$/.test(t); }
function resolveDate(token?:string) {
  const today=toManilaDate();if(!token)return today;
  const t=token.toLowerCase();
  if(t==='today')return today;
  if(t==='yesterday'){const d=new Date(today+'T00:00:00Z');d.setUTCDate(d.getUTCDate()-1);return d.toISOString().slice(0,10);}
  if(t==='tomorrow'){const d=new Date(today+'T00:00:00Z');d.setUTCDate(d.getUTCDate()+1);return d.toISOString().slice(0,10);}
  if(/^\d{4}-\d{2}-\d{2}$/.test(token))return token;
  const m=token.match(/^(\d{1,2})-(\d{1,2})$/);
  if(m)return`${today.slice(0,4)}-${m[1].padStart(2,'0')}-${m[2].padStart(2,'0')}`;
  return today;
}
function resolveTime(token?:string):string|null {
  if(!token)return null;const t=token.toLowerCase();
  const ampm=t.match(/^(\d{1,2})(?::(\d{2}))?(am|pm)$/);
  if(ampm){let h=Number(ampm[1]);const min=Number(ampm[2]??0);if(ampm[3]==='pm'&&h<12)h+=12;if(ampm[3]==='am'&&h===12)h=0;return`${String(h).padStart(2,'0')}:${String(min).padStart(2,'0')}:00`;}
  const hm=t.match(/^(\d{1,2}):(\d{2})$/);
  if(hm){const h=Number(hm[1]),min=Number(hm[2]);if(h<=23&&min<=59)return`${String(h).padStart(2,'0')}:${String(min).padStart(2,'0')}:00`;}
  return null;
}
function resolveDuration(token?:string):number|null { if(!token)return null;const m=token.match(/^(\d+(?:\.\d+)?)h?$/i);if(m){const n=Number(m[1]);return isFinite(n)&&n>0?n:null;}return null; }
const NOTICE_ICON:Record<string,string>={brownout:'⚡',holiday:'🏖',event:'📅',reminder:'🔔'};

async function handleOpsNoticeCommand(noticeType:string,args:string[],chatId:any,from:any,db:any) {
  let idx=0,effectiveDate=toManilaDate(),effectiveTime:string|null=null,durationHours:number|null=null;
  if(args[idx]&&isDateLike(args[idx]))effectiveDate=resolveDate(args[idx++]);
  if(noticeType==='brownout'){
    if(args[idx]&&!resolveTime(args[idx])&&args[idx+1]&&['am','pm'].includes(args[idx+1].toLowerCase())){args.splice(idx,2,args[idx]+args[idx+1]);}
    if(args[idx]){const t=resolveTime(args[idx]);if(t){effectiveTime=t;idx++;}}
    if(args[idx]){const d=resolveDuration(args[idx]);if(d!==null){durationHours=d;idx++;}}
  }
  const title=args.slice(idx).join(' ').trim();
  if(!title){const eg=noticeType==='brownout'?`/${noticeType} tomorrow 8am 4h SOCOTECO maintenance`:`/${noticeType} tomorrow Eid al-Adha`;await tgSend(chatId,`⚠️ Need a title.\n_e.g. ${eg}_`);return;}
  const postedBy=[from.first_name,from.username?`@${from.username}`:null].filter(Boolean).join(' ');
  const {error}=await db.from('ops_notices').insert({property_id:PROPERTY_ID,notice_type:noticeType,title,effective_date:effectiveDate,effective_time:effectiveTime,duration_hours:durationHours,feeder:noticeType==='brownout'?'Feeder 14-3':null,posted_by_chat_id:from.id??null,posted_by_name:postedBy});
  if(error){await tgSend(chatId,`⚠️ Could not save: ${errMsg(error.message)}`);return;}
  const icon=NOTICE_ICON[noticeType]??'📌';
  await tgSend(chatId,`${icon} *Notice saved*\nDate: ${effectiveDate}${effectiveTime?` at ${effectiveTime.slice(0,5)}`:''}${durationHours?` for ${durationHours}h`:''}\n${mdEsc(title)}\n_Will appear in tomorrow's digest._`);
}
async function handleNoticesList(chatId:any,db:any) {
  const today=toManilaDate();const{data}=await db.from('ops_notices').select('notice_type,title,effective_date,effective_time,is_active').eq('property_id',PROPERTY_ID).eq('is_active',true).gte('effective_date',today).order('effective_date').limit(15);
  const rows=(data??[]) as any[];if(!rows.length){await tgSend(chatId,'📌 No upcoming notices.');return;}
  const lines=['📌 *Upcoming Notices*',''];
  rows.forEach((n:any)=>{const icon=NOTICE_ICON[n.notice_type]??'📌';const time=n.effective_time?` ${String(n.effective_time).slice(0,5)}`:'';lines.push(`${icon} *${n.effective_date}*${time} \u2014 ${mdEsc(n.title)}`);});
  await tgSend(chatId,lines.join('\n'));
}
async function handleNoticesByType(chatId:any,db:any,type:string) {
  const today=toManilaDate();const{data}=await db.from('ops_notices').select('title,effective_date,effective_time,duration_hours').eq('property_id',PROPERTY_ID).eq('is_active',true).eq('notice_type',type).gte('effective_date',today).order('effective_date').order('effective_time',{nullsFirst:true}).limit(10);
  const rows=(data??[]) as any[];const icon=NOTICE_ICON[type]??'📌';
  const label=({brownout:'brownout',holiday:'holiday',event:'event',reminder:'reminder'} as Record<string,string>)[type]??type;
  const lines:string[]=[];
  if(!rows.length)lines.push(`${icon} No scheduled ${label}.`);
  else{lines.push(`${icon} *Upcoming ${label}${rows.length>1?'s':''}*`,'');for(const n of rows){const t=n.effective_time?` ${String(n.effective_time).slice(0,5)}`:'';const dur=n.duration_hours?` (${n.duration_hours}h)`:'';lines.push(`${n.effective_date}${t}${dur} \u2014 ${mdEsc(n.title)}`);}}
  const eg=type==='brownout'?'/brownout tomorrow 8am 4h SOCOTECO maintenance':type==='holiday'?'/holiday 06-12 Independence Day':type==='event'?'/event tomorrow Property inspection':'/reminder tomorrow Pay Honey';
  lines.push('',`_Add one: ${eg}_`);await tgSend(chatId,lines.join('\n'));
}
async function handleCalendarNotices(chatId:any,db:any) {
  const today=toManilaDate();const{data}=await db.from('ops_notices').select('notice_type,title,effective_date,effective_time').eq('property_id',PROPERTY_ID).eq('is_active',true).in('notice_type',['holiday','event','reminder']).gte('effective_date',today).order('effective_date').order('effective_time',{nullsFirst:true}).limit(20);
  const rows=(data??[]) as any[];const lines:string[]=[];
  if(!rows.length)lines.push('📅 No upcoming holidays, events, or reminders.');
  else{lines.push('📅 *Calendar \u2014 upcoming*','');for(const n of rows){const icon=NOTICE_ICON[n.notice_type]??'📌';const time=n.effective_time?` ${String(n.effective_time).slice(0,5)}`:'';lines.push(`${icon} *${n.effective_date}*${time} \u2014 ${mdEsc(n.title)}`);}}
  lines.push('','_Add: /holiday 06-12 Independence Day · /event tomorrow Property inspection · /reminder tomorrow Pay Honey_');
  await tgSend(chatId,lines.join('\n'));
}

async function geminiFetch(url:string,init:RequestInit,tries=3):Promise<Response> {
  for(let i=0;i<tries;i++){const res=await fetch(url,init);if(res.ok||(res.status!==429&&res.status!==503))return res;if(i<tries-1)await new Promise(r=>setTimeout(r,800*(i+1)));}
  return fetch(url,init);
}
function buildGeminiPrompt(categoryHint:string) {
  const h=categoryHint?`The user already classified this as "${categoryHint}" — use that as category_hint unless clearly wrong.`:'Infer category_hint from the items.';
  return `You are a receipt data extractor for a Philippine boutique Airbnb expense ledger.\nReturn ONLY a JSON object with these exact keys:\n{"amount":number|null,"currency":"PHP","date":"YYYY-MM-DD"|null,"vendor":string|null,"category_hint":"supplies"|"utilities"|"cleaning"|"maintenance"|"repairs"|"platform_fees"|"other","line_items":[{"name":string,"qty":number,"unit_price":number}],"confidence":number}\n${h}\nRules: amount=total paid. qty=units bought (default 1), unit_price=price per unit. If unreadable set amount null and confidence<0.2. Never invent a vendor.`;
}
function parseGeminiResponse(text:string,cat:string) { try{return JSON.parse(String(text).replace(/^```json\s*|\s*```$/g,'').trim());}catch{return{amount:null,currency:'PHP',date:null,vendor:null,category_hint:cat||'other',line_items:[],confidence:0};} }
async function geminiExtract(bytes:Uint8Array,mime:string,cat='') {
  const txt=await visionExtractText(buildGeminiPrompt(cat),bytes,mime);
  return parseGeminiResponse(txt,cat);
}
function categoryKeyboard(pre:number){const cats=[['🛒 Supplies','supplies'],['⚡ Utilities','utilities'],['🧹 Cleaning','cleaning'],['🔧 Maintenance','maintenance'],['🔨 Repairs','repairs'],['💼 Platform Fees','platform_fees'],['📌 Other','other']];const rows:any[][]=[];for(let i=0;i<cats.length;i+=2)rows.push(cats.slice(i,i+2).map(([l,s])=>({text:l,callback_data:`cat:${s}:${pre}`})));return{inline_keyboard:rows};}
function receiptEditKeyboard(txnId:string,amount:number){const rows:any[][]=[];if(amount>0)rows.push([{text:`✅ Confirm  ₱${peso(amount)}`,callback_data:`ocr_ok:${txnId}`}]);else rows.push([{text:'💵 Enter total',callback_data:`ocr_edit:${txnId}`}]);rows.push([{text:'✏️ Edit item',callback_data:`item_edit:${txnId}`},{text:'➕ Add item',callback_data:`item_add:${txnId}`}]);const r3:any[]=[{text:'🗑️ Remove item',callback_data:`item_remove:${txnId}`}];if(amount>0)r3.push({text:'💵 Edit total',callback_data:`ocr_edit:${txnId}`});rows.push(r3);rows.push([{text:'❌ Discard',callback_data:`ocr_void:${txnId}`}]);return{inline_keyboard:rows};}
function renderReceiptCard(txn:any,catLabel:string):{text:string;reply_markup:any}{
  const items=normalizeLineItems(txn.ocr_raw?.line_items);const total=Number(txn.gross_amount)||0;const sub=itemsSubtotal(items);const pct=Math.round(clamp01(txn.ocr_confidence)*100);
  const lines:string[]=['🧾 *Receipt — pending review*'];
  if(txn.payee_name)lines.push(`🏷️ ${mdEsc(txn.payee_name)}`);if(txn.transaction_date)lines.push(`📅 ${txn.transaction_date}`);
  lines.push(`📂 ${mdEsc(catLabel)}`,'');
  if(items.length){lines.push('📋 *Items*');items.forEach((it,i)=>{if(it.qty>1)lines.push(`\`${i+1}.\` ${mdEsc(it.name)} — ₱${peso(lineTotal(it))}  _(×${it.qty} @ ₱${peso(it.unit_price)})_`);else lines.push(`\`${i+1}.\` ${mdEsc(it.name)} — ₱${peso(it.unit_price)}`);});lines.push('',`🧮 Items subtotal: ₱${peso(sub)}`);}
  else lines.push('_No line items yet — tap ➕ Add item_');
  lines.push(`💵 *Total paid: ₱${peso(total)}*`);
  if(items.length&&Math.abs(sub-total)>=1)lines.push(`   _Δ ₱${peso(Math.abs(sub-total))} ${sub>total?'discount/voucher':'fees/shipping/tax'}_`);
  lines.push(total>0?(pct<60?'⚠️ Low confidence — verify carefully':`🎯 Confidence: ${pct}%`):'⚠️ Total unreadable — set it before confirming');
  lines.push(`🔖 Ref: ${shortRef(txn.id)}`);
  return{text:lines.join('\n'),reply_markup:receiptEditKeyboard(txn.id,total)};
}
function pendingKeyboard(pid:string,label="✅ Yes, it's a new entry"){return{inline_keyboard:[[{text:label,callback_data:`dup_ok:${pid}`}],[{text:'❌ Cancel',callback_data:`dup_cancel:${pid}`}]]};}
function photoDupKeyboard(pid:string){return{inline_keyboard:[[{text:"✅ Different receipt — process it",callback_data:`continue_ocr:${pid}`}],[{text:'❌ Already logged — skip',callback_data:`dup_cancel:${pid}`}]]};}
function invSyncKeyboard(pid:string){return{inline_keyboard:[[{text:'✅ Update stock',callback_data:`invsync_ok:${pid}`},{text:'⏭️ Skip',callback_data:`invsync_skip:${pid}`}]]};}
type Category={slug:string;label:string;keywords:string[];sort_order:number};
function parseAmount(tokens:string[]):{amount:number|null;idx:number}{for(let i=0;i<Math.min(tokens.length,2);i++){const c=tokens[i].replace(/[\u20b1,]/g,'');if(/^\d+(\.\d{1,2})?$/.test(c)){const n=Number(c);if(n>0)return{amount:n,idx:i};}}return{amount:null,idx:-1};}
function detectAmountAnywhere(text:string){const m=text.match(/₱?\s*(\d[\d,]*(?:\.\d{1,2})?)/);if(!m)return 0;const n=Number(m[1].replace(/,/g,''));return isFinite(n)&&n>0?n:0;}
function classify(remainder:string,cats:Category[]):{slug:string;label:string;matched:string|null}{const hay=` ${remainder.toLowerCase()} `;for(const c of cats){if(c.slug==='other')continue;for(const kw of c.keywords){const k=kw.toLowerCase();if(new RegExp(`(^|\\W)${k.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')}(\\W|$)`).test(hay))return{slug:c.slug,label:c.label,matched:k};}}return{slug:'other',label:cats.find(c=>c.slug==='other')?.label??'Other',matched:null};}
function expensePromptText(label:string,pre:number){return pre>0?`📂 ${mdEsc(label)}\nDetected ₱${peso(pre)} — type a different amount, or the shop name to keep it.`:`📂 ${mdEsc(label)}\nType the amount, and the shop if you like: 1706  or  1706 Lazada`;}
type InsertOpts={category:string;amount:number;label?:string;payee?:string|null;notes?:string|null;loggedBy?:string|null};
async function insertExpense(db:any,opts:InsertOpts){const result=await db.from('transactions').insert({property_id:PROPERTY_ID,txn_type:'expense',category:opts.category,status:'confirmed',source:'telegram',gross_amount:opts.amount,payee_name:opts.payee??null,notes:opts.notes??null,logged_by:opts.loggedBy??null}).select('id').single();notifyOps(opts.category,opts.loggedBy??null,false);return result;}
let _catCache: { ts: number; data: Category[] } | null = null;
async function getCategories(db:any):Promise<Category[]>{
  if(_catCache && Date.now()-_catCache.ts < 60_000) return _catCache.data;
  const{data}=await db.from('expense_categories').select('slug,label,keywords,sort_order').eq('property_id',PROPERTY_ID).eq('is_active',true).order('sort_order');
  const cats=(data??[]) as Category[];
  if(cats.length) _catCache={ts:Date.now(),data:cats};
  return cats;
}
async function getCategoryLabel(db:any,slug:string){const cats=await getCategories(db);return cats.find(c=>c.slug===slug)?.label??slug;}
async function createPending(db:any,chatId:any,kind:string,payload:Record<string,unknown>,ttlMinutes?:number){const row:Record<string,unknown>={chat_id:chatId,kind,payload};if(ttlMinutes)row.expires_at=new Date(Date.now()+ttlMinutes*60_000).toISOString();const{data}=await db.from('telegram_pending').insert(row).select('id').single();return data?.id??'';}
// SPEC-16: one open question per person per chat. A fresh tap deletes that person's previous question first.
async function awaiting(db:any,chatId:any,fromId:unknown,flow:Flow,refs:Record<string,unknown>){
  await db.from('telegram_pending').delete().eq('chat_id',chatId).eq('kind','awaiting_reply').eq('payload->>from_id',String(fromId));
  return createPending(db,chatId,'awaiting_reply',{flow,from_id:fromId,...refs},10);
}
async function findAwaiting(db:any,chatId:any,fromId:unknown):Promise<{id:string;payload:any}|null>{
  if(fromId==null)return null;
  const{data}=await db.from('telegram_pending').select('id,payload').eq('chat_id',chatId).eq('kind','awaiting_reply').eq('payload->>from_id',String(fromId)).gt('expires_at',new Date().toISOString()).order('created_at',{ascending:false}).limit(1).maybeSingle();
  return data??null;
}
const hasAwaiting=async(db:any,chatId:any,fromId:unknown)=>!!(await findAwaiting(db,chatId,fromId));
const cancelKb=(pid:string)=>({inline_keyboard:[[{text:'❌ Cancel',callback_data:`x:${pid}`}]]});
/** Ask one person one question: the row first, then the prompt (with Cancel), then the prompt's id on the row. */
async function ask(db:any,chatId:any,fromId:unknown,flow:Flow,refs:Record<string,unknown>,text:string,buttons:Array<{text:string;callback_data:string}>=[]){
  const pid=fromId==null?'':await awaiting(db,chatId,fromId,flow,refs);
  if(!pid){await tgSend(chatId,'⚠️ Could not open that question, so nothing was saved. Try again in a minute.');return;}
  const r=await tgSend(chatId,text,{reply_markup:{inline_keyboard:[[...buttons,{text:'❌ Cancel',callback_data:`x:${pid}`}]]}});
  const mid=r?.result?.message_id;
  if(mid)await db.from('telegram_pending').update({payload:{flow,from_id:fromId,...refs,prompt_mid:mid}}).eq('id',pid);
}
async function consumePending(db:any,pid:string){const{data}=await db.from('telegram_pending').delete().eq('id',pid).select('payload,expires_at').maybeSingle();if(!data)return null;if(new Date(data.expires_at)<new Date())return null;return data.payload;}
function purgePending(db:any){db.from('telegram_pending').delete().lt('expires_at',new Date().toISOString()).then(()=>{}).catch(()=>{});}
async function checkRecentDuplicates(db:any,amount:number){const since=new Date(Date.now()-RECENT_DUP_DAYS*86_400_000).toISOString().slice(0,10);const{data}=await db.from('transactions').select('id,gross_amount,category,transaction_date,payee_name,status').eq('property_id',PROPERTY_ID).eq('gross_amount',amount).neq('status','void').gte('transaction_date',since).order('transaction_date',{ascending:false}).limit(5);return data??[];}
function confirmMsg(amount:number,label:string,payee:string|null,id:string){return[`✅ *Expense logged*`,`₱${peso(amount)}  ·  ${label}`,...(payee?[`   ${mdEsc(payee)}`]:[]),`_Ref: ${shortRef(id)}_`].join('\n');}
async function loadReceiptTxn(db:any,txnId:string):Promise<any|null>{const{data}=await db.from('transactions').select('id,gross_amount,category,payee_name,transaction_date,status,ocr_confidence,ocr_raw').eq('id',txnId).maybeSingle();if(!data||data.status!=='pending_review')return null;return data;}
async function persistItems(db:any,txnId:string,ocrRaw:any,items:LineItem[]){const raw=(ocrRaw&&typeof ocrRaw==='object')?{...ocrRaw}:{};raw.line_items=items;await db.from('transactions').update({ocr_raw:raw,updated_at:new Date().toISOString()}).eq('id',txnId);}
async function sendReceiptCard(db:any,chatId:any,txnId:string,note?:string){const txn=await loadReceiptTxn(db,txnId);if(!txn){await tgSend(chatId,'⏰ That receipt is no longer editable.');return;}const catLabel=await getCategoryLabel(db,txn.category);const card=renderReceiptCard(txn,catLabel);await tgSend(chatId,(note?note+'\n\n':'')+card.text,{reply_markup:card.reply_markup});}
// SPEC-16: an item is chosen by tapping it. Only the price (or name and price) is typed; removal is a tap.
function itemButtons(items:LineItem[],prefix:string,txnId:string){return[...items.map((it,i)=>[{text:`${i+1} · ${it.name.slice(0,28)} · ₱${peso(it.unit_price)}`,callback_data:`${prefix}:${txnId}:${i+1}`}]),[{text:'❌ Cancel',callback_data:'xx'}]];}
async function promptEditItem(db:any,chatId:any,txnId:string){const txn=await loadReceiptTxn(db,txnId);if(!txn){await tgSend(chatId,'⏰ That receipt is no longer editable.');return;}const items=normalizeLineItems(txn.ocr_raw?.line_items);if(!items.length){await tgSend(chatId,'No items to edit yet. Tap ➕ Add item.');return;}await tgSend(chatId,'✏️ Tap the item to edit.',{reply_markup:{inline_keyboard:itemButtons(items,'item_ed',txnId)}});}
async function promptRemoveItem(db:any,chatId:any,txnId:string){const txn=await loadReceiptTxn(db,txnId);if(!txn){await tgSend(chatId,'⏰ That receipt is no longer editable.');return;}const items=normalizeLineItems(txn.ocr_raw?.line_items);if(!items.length){await tgSend(chatId,'No items to remove.');return;}await tgSend(chatId,'🗑️ Tap the item to remove.',{reply_markup:{inline_keyboard:itemButtons(items,'item_rm',txnId)}});}
async function handleItemEditAnswer(db:any,chatId:any,msg:any,txn:any,index:number,parsed:ReturnType<typeof parseNamePriceQty>){const items=normalizeLineItems(txn.ocr_raw?.line_items);const it=items[index-1];if(!it){await tgReply(chatId,msg.message_id,'⚠️ That item is no longer on the receipt. Tap ✏️ Edit item again.');return;}if(parsed.name)it.name=parsed.name;it.unit_price=parsed.price!;if(parsed.qtyExplicit)it.qty=parsed.qty;await persistItems(db,txn.id,txn.ocr_raw,items);await sendReceiptCard(db,chatId,txn.id,`✏️ Item ${index} updated.`);}
async function handleItemAddAnswer(db:any,chatId:any,txn:any,parsed:ReturnType<typeof parseNamePriceQty>){const items=normalizeLineItems(txn.ocr_raw?.line_items);items.push({name:parsed.name,qty:parsed.qty,unit_price:parsed.price!});await persistItems(db,txn.id,txn.ocr_raw,items);await sendReceiptCard(db,chatId,txn.id,`➕ Added "${mdEsc(parsed.name)}".`);}
async function maybeOfferInventorySync(db:any,chatId:any,txnId:string){const{data:txn}=await db.from('transactions').select('category,payee_name,transaction_date,ocr_raw').eq('id',txnId).maybeSingle();if(!txn||!STOCKABLE_CATS.has(txn.category))return;const rawItems=Array.isArray(txn.ocr_raw?.line_items)?txn.ocr_raw.line_items:[];if(!rawItems.length)return;const matched:any[]=[],unmatched:string[]=[];for(const it of rawItems){const name=(typeof it==='string'?it:String(it?.name??'')).trim();if(!name)continue;const qty=(typeof it==='object'&&Number(it?.qty)>0)?Number(it.qty):1;const unitPrice=(typeof it==='object'&&Number(it?.unit_price)>0)?Number(it.unit_price):null;const{data:m}=await db.rpc('match_inventory_item',{p_name:name,p_limit:1});const best=Array.isArray(m)&&m.length?m[0]:null;if(best)matched.push({item_id:best.id,item_name:best.name,qty,unit_price:unitPrice});else unmatched.push(name);}if(!matched.length)return;const pid=await createPending(db,chatId,'inventory_sync',{txnId,vendor:txn.payee_name??null,date:txn.transaction_date??null,items:matched});const lines=matched.map((m:any)=>`  • ${mdEsc(m.item_name)}  +${m.qty}`);const tail=unmatched.length?[``,`_Not tracked: ${mdEsc(unmatched.join(', '))}_`]:[];await tgSend(chatId,[`📦 *Update inventory?*`,`${matched.length} item(s) from this receipt match your stock:`,...lines,...tail].join('\n'),{reply_markup:invSyncKeyboard(pid)});}
/* SPEC-03 (session 33), SPEC-16 (session 37): /count sends one card of item buttons; a tap asks for that item's
   new count, the card redraws with the change, and Apply writes it. Anyone in Finance may start and type a count;
   authorisation happens at the Apply tap, in the database, exactly like the booking Confirm. */
function countScopeKeyboard(counts:Record<string,number>){
  return {inline_keyboard:[[
    {text:`1 · Consumables (${counts.consumables})`,callback_data:'inv:grp:1'},
    {text:`2 · Stores (${counts.stores})`,callback_data:'inv:grp:2'},
  ],[
    {text:`3 · All groups (${counts.consumables+counts.appliances+counts.stores})`,callback_data:'inv:grp:3'},
  ]]};
}
async function loadCountItems(db:any){
  const{data}=await db.from('inventory_items')
    .select('id,name,unit,qty_on_hand,reorder_below,is_consumable,category,movement_controlled_at')
    .eq('property_id',PROPERTY_ID).eq('is_active',true).order('sort_order');
  return (data??[]) as any[];
}
async function promptCountScope(db:any,chatId:any){
  const rows=await loadCountItems(db);
  if(!rows.length){await tgSend(chatId,'📦 No active inventory items to count.');return;}
  const counts={consumables:0,appliances:0,stores:0} as Record<string,number>;
  for(const r of rows) counts[inventoryGroup(r)]++;
  await tgSend(chatId,'📦 *Update counts* — which group?',{reply_markup:countScopeKeyboard(counts)});
}
async function sendCountList(db:any,chatId:any,scope:'1'|'2'|'3'){
  const rows=await loadCountItems(db);
  const wanted=SCOPE_GROUPS[scope];
  // Movement-controlled items are refused by the RPC, so they are never offered for counting.
  const chosen=rows.filter(r=>wanted.includes(inventoryGroup(r))&&!r.movement_controlled_at);
  if(!chosen.length){await tgSend(chatId,'📦 Nothing to count in that group.');return;}
  const ordered=wanted.flatMap(g=>chosen.filter(r=>inventoryGroup(r)===g));
  const items:CountItem[]=ordered.map(r=>({id:r.id,name:r.name,unit:r.unit,qty:Number(r.qty_on_hand),reorder:r.reorder_below===null?null:Number(r.reorder_below)}));
  const label=wanted.length===1?GROUP_LABEL[wanted[0]]:'All groups';
  // SPEC-16: one card of item buttons, alive for an hour (a count takes longer than the 10-minute default).
  const pid=await createPending(db,chatId,'inventory_count',{scope,label,items},60);
  if(!pid){await tgSend(chatId,'⚠️ Could not start a count. Try again in a minute.');return;}
  const r=await tgSend(chatId,countCardText(label,items.length,0),{reply_markup:countCardKeyboard(pid,items,[])});
  const mid=r?.result?.message_id;
  if(mid)await db.from('telegram_pending').update({payload:{scope,label,items,card_mid:mid}}).eq('id',pid);
}
async function findCountCard(db:any,chatId:any,replyMid:unknown):Promise<{id:string;payload:any;expires_at:string}|null>{
  if(!replyMid)return null;
  const{data}=await db.from('telegram_pending').select('id,payload,expires_at').eq('chat_id',chatId).eq('kind','inventory_count').eq('payload->>card_mid',String(replyMid)).maybeSingle();
  return data??null;
}
/** One item's new count onto the card: store it, tick the prompt, redraw card A in place. */
async function applyCountQty(db:any,chatId:any,countPid:string,index:number,counted:number,promptMid?:number):Promise<boolean>{
  // ponytail: read-modify-write on one row; two people tapping the same card in the same second can lose one figure.
  const{data:row}=await db.from('telegram_pending').select('payload,expires_at').eq('id',countPid).maybeSingle();
  if(!row||new Date(row.expires_at)<new Date())return false;
  const items=(row.payload?.items??[]) as CountItem[];const it=items[index-1];if(!it)return false;
  const changes=setChange(items,(row.payload?.changes??[]) as Change[],index,counted);
  await db.from('telegram_pending').update({payload:{...row.payload,changes}}).eq('id',countPid);
  if(promptMid)await tgEdit(chatId,promptMid,it.qty===counted?`✔ ${mdEsc(it.name)}: ${counted} ${it.unit}, no change`:`✔ ${mdEsc(it.name)}: ${it.qty} → ${counted} ${it.unit}`);
  if(row.payload?.card_mid)await tgEdit(chatId,row.payload.card_mid,countCardText(row.payload.label??'Count',items.length,changes.length),countCardKeyboard(countPid,items,changes));
  return true;
}
/** Power path (SPEC-03, kept): a reply to card A itself, many `<#> <count>` lines at once. Keyed by card_mid, never by text. */
async function handleCountReply(db:any,chatId:any,msg:any,card:{id:string;payload:any;expires_at:string},text:string){
  if(new Date(card.expires_at)<new Date()){await tgReply(chatId,msg.message_id,COUNT_EXPIRED);return;}
  const items=(card.payload?.items??[]) as CountItem[];
  const parsed=parseCountReply(text,items.length);
  const gripes=[
    parsed.outOfRange.length?`could not use: ${parsed.outOfRange.join(', ')} (the list has ${items.length})`:'',
    parsed.unreadable.length?`could not read: ${parsed.unreadable.join(' · ')}`:'',
  ].filter(Boolean);
  if(!parsed.changes.length){
    await tgReply(chatId,msg.message_id,['⚠️ Nothing to change, so nothing was saved.',..._italic(gripes),'','Tap an item on the card, then type its new count.'].join('\n'));return;
  }
  let changes=(card.payload?.changes??[]) as Change[];
  for(const{index,counted}of parsed.changes)changes=setChange(items,changes,index,counted);
  await db.from('telegram_pending').update({payload:{...card.payload,changes}}).eq('id',card.id);
  await tgEdit(chatId,card.payload.card_mid,countCardText(card.payload.label??'Count',items.length,changes.length),countCardKeyboard(card.id,items,changes));
  await tgReply(chatId,msg.message_id,[`✔ The card now shows ${changes.length} change${changes.length===1?'':'s'}. Nothing is saved until Apply.`,...(gripes.length?['',..._italic(gripes)]:[])].join('\n'));
}
const _italic=(ls:string[])=>ls.map(l=>`_${mdEsc(l)}_`);

async function runOcr(db:any,chatId:any,objectPath:string,bytes:Uint8Array,mime:string,loggedBy:string|null,notes:string|null,cat=''){if(!hasVisionKey()){await tgSend(chatId,`⚠️ No key for VISION_PROVIDER=${VISION_PROVIDER}. Tap a category:`,{reply_markup:categoryKeyboard(0)});return;}let extracted:any;try{extracted=await geminiExtract(bytes,mime,cat);}catch(e){console.warn('OCR:',String(e));await tgSend(chatId,'🧾 Could not read receipt. Tap a category:',{reply_markup:categoryKeyboard(0)});return;}const cats=await getCategories(db);const validSlugs=new Set(cats.map(c=>c.slug));const rawCat=String(extracted.category_hint??'').toLowerCase().trim();const category=cat&&validSlugs.has(cat)?cat:(validSlugs.has(rawCat)?rawCat:'other');const catLabel=cats.find(c=>c.slug===category)?.label??category;const amount=Number(extracted.amount);const grossAmount=isFinite(amount)&&amount>0?amount:0;const confidence=clamp01(extracted.confidence);const txnDate=validDate(extracted.date);const vendor=extracted.vendor?String(extracted.vendor).slice(0,200):null;const itemsText=lineItemsToText(extracted.line_items);const noteParts=[notes,itemsText?`items: ${itemsText}`:null].filter(Boolean);const insertRow:Record<string,unknown>={property_id:PROPERTY_ID,txn_type:'expense',category,status:'pending_review',source:'ocr',gross_amount:grossAmount,payee_name:vendor,receipt_image_path:objectPath,ocr_confidence:confidence,ocr_raw:extracted,logged_by:loggedBy,notes:noteParts.length?noteParts.join(' | '):null};if(txnDate)insertRow.transaction_date=txnDate;const{data:row,error}=await db.from('transactions').insert(insertRow).select('id').single();if(error||!row){await tgSend(chatId,`⚠️ OCR save error: ${errMsg(error?.message)}`);return;}const txnId=row.id;const card=renderReceiptCard({id:txnId,gross_amount:grossAmount,payee_name:vendor,transaction_date:txnDate,ocr_confidence:confidence,ocr_raw:extracted},catLabel);await tgSend(chatId,card.text,{reply_markup:card.reply_markup});notifyOps(category,loggedBy,true);}
async function validateAndInsert(db:any,chatId:any,opts:InsertOpts){purgePending(db);const{amount,category:slug,label,payee,notes,loggedBy}=opts;const today=toManilaDate();const dupes=await checkRecentDuplicates(db,amount);const exactDupe=dupes.find((d:any)=>d.category===slug&&d.transaction_date===today);const recentDupe=!exactDupe&&amount>=RECENT_DUP_MIN_AMOUNT?dupes[0]:null;const isLarge=!exactDupe&&!recentDupe&&amount>=LARGE_AMOUNT_THRESHOLD;if(exactDupe){const pid=await createPending(db,chatId,'duplicate',{amount,category:slug,label,payee,notes,loggedBy});await tgSend(chatId,[`⚠️ *Possible duplicate detected*`,`₱${peso(amount)} · ${label??slug} already logged *today* (Ref: \`${shortRef(exactDupe.id)}\`).`,``,`Is this a *new* transaction?`].join('\n'),{reply_markup:pendingKeyboard(pid)});return;}if(recentDupe){const pid=await createPending(db,chatId,'duplicate',{amount,category:slug,label,payee,notes,loggedBy});await tgSend(chatId,[`⚠️ *Similar recent entry*`,`₱${peso(amount)} · ${recentDupe.category} logged *${daysDiff(recentDupe.transaction_date)} day(s) ago* (Ref: \`${shortRef(recentDupe.id)}\`).`,``,`Is this a *new* transaction?`].join('\n'),{reply_markup:pendingKeyboard(pid)});return;}if(isLarge){const pid=await createPending(db,chatId,'large_amount',{amount,category:slug,label,payee,notes,loggedBy});await tgSend(chatId,[`💰 *Large expense: ₱${peso(amount)}*`,`${label??slug}${payee?` · ${mdEsc(payee)}`:''}`,`Confirm this entry?`].join('\n'),{reply_markup:pendingKeyboard(pid,'✅ Confirm')});return;}const{data:row,error}=await insertExpense(db,opts);if(error||!row){await tgSend(chatId,`⚠️ Could not save: ${errMsg(error?.message)}`);return;}await tgSend(chatId,confirmMsg(amount,label??slug,payee??null,row.id));}
function buildSummaryCard(s:any):string{
  const topCats=(s.by_category??[]).filter((c:any)=>c.txn_type==='expense').slice(0,5).map((c:any)=>`   • ${mdEsc(c.label)}  —  ₱${peso(c.total)}`).join('\n');
  const lines=[
    `📊 *Finance — ${s.month}*`,
    '',
    `Income      ₱${peso(s.income)}`,
    `Expenses    ₱${peso(s.expenses)}`,
    `Net         ₱${peso(s.net)}`,
  ];
  if(topCats){lines.push('','*Top expenses*',topCats);}
  if(s.pending_review){lines.push('',`⏳ ${s.pending_review} receipt${s.pending_review!==1?'s':''} pending review`);}
  return lines.join('\n');
}
async function runSummary(db:any,chatId:any){const{data:s,error}=await db.rpc('get_finance_summary');if(error||!s){await tgSend(chatId,'⚠️ Could not load summary.');return;}await tgSend(chatId,buildSummaryCard(s));}

// ═══════════════════════════════════════════════════════════════════════════
// v46: AIRBNB CSV IMPORT — Finance only
// ═══════════════════════════════════════════════════════════════════════════

interface AirbnbRow {
  txn_date: string | null;
  arriving_by_date: string | null;
  row_type: string | null;
  confirmation_code: string | null;
  booking_date: string | null;
  start_date: string | null;
  end_date: string | null;
  nights: number | null;
  guest_name: string | null;
  listing: string | null;
  details: string | null;
  reference_code: string | null;
  currency: string | null;
  amount: number | null;
  paid_out: number | null;
  service_fee: number | null;
  fast_pay_fee: number | null;
  cleaning_fee: number | null;
  gross_earnings: number | null;
  airbnb_remitted_tax: number | null;
  earnings_year: number | null;
}

function parseCSVLine(line: string): string[] {
  const result: string[] = [];
  let field = '';
  let inQuotes = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    const next = line[i + 1];
    if (inQuotes) {
      if (c === '"' && next === '"') { field += '"'; i++; }
      else if (c === '"') { inQuotes = false; }
      else { field += c; }
    } else {
      if (c === '"') { inQuotes = true; }
      else if (c === ',') { result.push(field); field = ''; }
      else { field += c; }
    }
  }
  result.push(field);
  return result;
}

function parseAirbnbDate(s: string): string | null {
  if (!s?.trim()) return null;
  const parts = s.trim().split('/');
  if (parts.length !== 3) return null;
  const [m, d, y] = parts;
  if (!y || !m || !d) return null;
  return `${y}-${m.padStart(2, '0')}-${d.padStart(2, '0')}`;
}

function parseAirbnbAmount(s: string): number | null {
  if (!s?.trim()) return null;
  const n = Number(s.trim().replace(/,/g, ''));
  return isFinite(n) ? n : null;
}

const AIRBNB_ROW_TYPE_MAP: Record<string, string> = {
  'reservation':     'reservation',
  'payout':          'payout',
  'co-host payout':  'cohost_payout',
  'adjustment':      'adjustment',
};

function parseAirbnbCsv(text: string): AirbnbRow[] {
  const lines = text.split(/\r?\n/).filter(l => l.trim());
  if (lines.length < 2) return [];

  const headerFields = parseCSVLine(lines[0]).map(h => h.trim().toLowerCase().replace(/\s+/g, '_'));
  const col = (name: string): number => headerFields.indexOf(name);

  const dateIdx      = col('date');
  const arrivingIdx  = col('arriving_by_date');
  const typeIdx      = col('type');
  const codeIdx      = col('confirmation_code');
  const bookingIdx   = col('booking_date');
  const startIdx     = col('start_date');
  const endIdx       = col('end_date');
  const nightsIdx    = col('nights');
  const guestIdx     = col('guest');
  const listingIdx   = col('listing');
  const detailsIdx   = col('details');
  const refIdx       = col('reference_code');
  const currIdx      = col('currency');
  const amtIdx       = col('amount');
  const paidIdx      = col('paid_out');
  const svcIdx       = col('service_fee');
  const fpIdx        = col('fast_pay_fee');
  const cleanIdx     = col('cleaning_fee');
  const grossIdx     = col('gross_earnings');
  const taxIdx       = col('airbnb_remitted_tax');
  const yearIdx      = col('earnings_year');

  const rows: AirbnbRow[] = [];

  for (let i = 1; i < lines.length; i++) {
    const f = parseCSVLine(lines[i]);
    const get = (idx: number): string => (idx >= 0 && idx < f.length) ? f[idx].trim() : '';

    const rawType = get(typeIdx).toLowerCase();
    const row_type = AIRBNB_ROW_TYPE_MAP[rawType] ?? null;
    const txn_date = parseAirbnbDate(get(dateIdx));

    if (!txn_date && !row_type) continue;

    const nightsRaw = get(nightsIdx);
    const yearRaw   = get(yearIdx);

    rows.push({
      txn_date,
      arriving_by_date:    parseAirbnbDate(get(arrivingIdx)),
      row_type,
      confirmation_code:   get(codeIdx)    || null,
      booking_date:        parseAirbnbDate(get(bookingIdx)),
      start_date:          parseAirbnbDate(get(startIdx)),
      end_date:            parseAirbnbDate(get(endIdx)),
      nights:              nightsRaw ? (Number(nightsRaw) || null) : null,
      guest_name:          get(guestIdx)   || null,
      listing:             get(listingIdx) || null,
      details:             get(detailsIdx) || null,
      reference_code:      get(refIdx)     || null,
      currency:            get(currIdx)    || null,
      amount:              parseAirbnbAmount(get(amtIdx)),
      paid_out:            parseAirbnbAmount(get(paidIdx)),
      service_fee:         parseAirbnbAmount(get(svcIdx)),
      fast_pay_fee:        parseAirbnbAmount(get(fpIdx)),
      cleaning_fee:        parseAirbnbAmount(get(cleanIdx)),
      gross_earnings:      parseAirbnbAmount(get(grossIdx)),
      airbnb_remitted_tax: parseAirbnbAmount(get(taxIdx)),
      earnings_year:       yearRaw ? (Number(yearRaw) || null) : null,
    });
  }

  return rows;
}

async function csvRowHash(row: AirbnbRow): Promise<string> {
  const input = [
    row.txn_date       ?? '',
    row.row_type       ?? '',
    row.confirmation_code ?? '',
    String(row.amount  ?? ''),
    String(row.paid_out ?? ''),
    String(row.gross_earnings ?? ''),
  ].join('|');
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(input));
  return Array.from(new Uint8Array(buf)).map(b => b.toString(16).padStart(2, '0')).join('');
}

async function handleDocumentMessage(msg: any, db: any): Promise<void> {
  const chatId = msg.chat?.id;

  if (!isFinanceChat(chatId)) return;
  if (msg.from?.is_bot) return;

  const doc = msg.document;
  const filename = String(doc?.file_name ?? '');

  if (!filename.toLowerCase().endsWith('.csv')) {
    await tgSend(chatId, '📎 _Send the CSV exported from Airbnb → Finance → Transaction History → Download._');
    return;
  }

  const waitMsg = await tgSend(chatId, '📥 _Reading CSV… please wait._');
  const waitMsgId: number | null = (waitMsg?.result?.message_id as number) ?? null;

  const reply = async (text: string) => {
    if (waitMsgId) await tgEdit(chatId, waitMsgId, text);
    else await tgSend(chatId, text);
  };

  try {
    const fileMeta = await tgCall('getFile', { file_id: doc.file_id });
    const filePath = fileMeta?.result?.file_path as string | undefined;
    if (!filePath) { await reply('⚠️ Could not fetch the file.'); return; }

    const rawBytes = await fetch(`https://api.telegram.org/file/bot${TG_TOKEN}/${filePath}`)
      .then(r => r.arrayBuffer());
    const csvText = new TextDecoder('utf-8').decode(new Uint8Array(rawBytes)).replace(/^\uFEFF/, '');

    const rows = parseAirbnbCsv(csvText);

    if (rows.length === 0) {
      await reply('⚠️ Could not parse this file. Send the CSV exported from Airbnb → Finance → Transaction History → Download.');
      return;
    }

    const hashes = await Promise.all(rows.map(row => csvRowHash(row)));

    const { data: existingHashRows } = await db
      .from('airbnb_transactions')
      .select('row_hash')
      .in('row_hash', hashes);
    const existingSet = new Set(((existingHashRows ?? []) as any[]).map((r: any) => r.row_hash));

    const newEntries = rows
      .map((row, i) => ({ row, hash: hashes[i] }))
      .filter(({ hash }) => !existingSet.has(hash));

    const skipped  = rows.length - newEntries.length;
    const inserted = newEntries.length;

    if (inserted > 0) {
      const payload = newEntries.map(({ row, hash }) => ({
        property_id:         PROPERTY_ID,
        source_file:         filename || 'telegram_upload',
        row_hash:            hash,
        row_type:            row.row_type,
        txn_date:            row.txn_date,
        arriving_by_date:    row.arriving_by_date,
        confirmation_code:   row.confirmation_code,
        booking_date:        row.booking_date,
        start_date:          row.start_date,
        end_date:            row.end_date,
        nights:              row.nights,
        guest_name:          row.guest_name,
        listing:             row.listing,
        details:             row.details,
        reference_code:      row.reference_code,
        currency:            row.currency,
        amount:              row.amount,
        paid_out:            row.paid_out,
        service_fee:         row.service_fee,
        fast_pay_fee:        row.fast_pay_fee,
        cleaning_fee:        row.cleaning_fee,
        gross_earnings:      row.gross_earnings,
        airbnb_remitted_tax: row.airbnb_remitted_tax,
        earnings_year:       row.earnings_year,
      }));

      const { error: insertError } = await db.from('airbnb_transactions').insert(payload);
      if (insertError) {
        await reply(`⚠️ Import failed: ${errMsg(insertError.message)}`);
        return;
      }
    }

    const { data: reconResult } = await db.rpc('reconcile_all_completed_reservations');

    const newDates = newEntries.map(({ row }) => row.txn_date).filter(Boolean) as string[];
    const minDate  = newDates.length ? newDates.reduce((a, b) => (a < b ? a : b)) : null;
    const maxDate  = newDates.length ? newDates.reduce((a, b) => (a > b ? a : b)) : null;
    const reconCount = (reconResult as any)?.reconciled ?? 0;

    const lines = [
      `📊 *Airbnb CSV imported*`,
      `📁 ${mdEsc(filename)}`,
      `──────────────────`,
      `✅ New rows: ${inserted}`,
      `⏭️ Already in DB: ${skipped} (skipped)`,
      `──────────────────`,
      `🔄 Bookings reconciled: ${reconCount}`,
    ];
    if (minDate && maxDate) lines.push(`📅 Coverage: ${minDate} → ${maxDate}`);

    await reply(lines.join('\n'));

  } catch (e) {
    await reply(`⚠️ CSV import error: ${errMsg(e)}`);
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// v56: REFUND COMMAND — /refund REFCODE AMT RECIPIENT | REF | NOTE
// ═══════════════════════════════════════════════════════════════════════════

async function handleRefundCommand(db: any, chatId: any, from: any, args: string[]): Promise<void> {
  const fullText = args.join(' ').trim();
  let refundRail: 'offplatform' | 'resolution_center' = 'offplatform';
  let workText = fullText;
  if (/\brc\s*$/i.test(workText)) {
    refundRail = 'resolution_center';
    workText = workText.replace(/\brc\s*$/i, '').trim();
  }
  const pipes     = workText.split('|').map((s: string) => s.trim());
  const mainPart  = pipes[0] ?? '';
  const refundRef = pipes[1]?.trim() || null;
  const notePipe  = pipes[2]?.trim() || null;
  const mainTokens = mainPart.split(/\s+/).filter(Boolean);
  if (mainTokens.length < 3) {
    await tgSend(chatId,
      '\u26a0\ufe0f Usage: `/refund REFCODE AMOUNT RECIPIENT | REFERENCE | NOTE`\n' +
      '_e.g._ `/refund HMSHFR4NRD 3640 Fyonah Pulalon | InstaPay-539388 | 2 unused nights`'
    );
    return;
  }
  const refCode   = mainTokens[0].toUpperCase();
  const amtRaw    = mainTokens[1].replace(/[\u20b1,]/g, '');
  const amount    = Number(amtRaw);
  const recipient = mainTokens.slice(2).join(' ').trim();
  if (!isFinite(amount) || amount <= 0) {
    await tgSend(chatId, `\u26a0\ufe0f Invalid amount: \`${mainTokens[1]}\`. Must be a positive number.`);
    return;
  }
  if (!recipient) {
    await tgSend(chatId, '\u26a0\ufe0f Recipient name is required after the amount.');
    return;
  }
  const [{ data: resvRow }, { data: incomeRow }] = await Promise.all([
    db.from('airbnb_reservations')
      .select('guest_name,host_payout,checkin_date,checkout_date')
      .eq('confirmation_code', refCode)
      .maybeSingle(),
    db.from('transactions')
      .select('gross_amount,transaction_date')
      .eq('external_ref', refCode)
      .eq('txn_type', 'income')
      .eq('source', 'airbnb_payout_email')
      .eq('status', 'confirmed')
      .maybeSingle(),
  ]);
  const guestName  = resvRow?.guest_name ?? null;
  const origPayout = incomeRow
    ? Number(incomeRow.gross_amount)
    : (resvRow ? Number(resvRow.host_payout ?? 0) : null);
  const netAfter   = origPayout != null ? origPayout - amount : null;
  const notFound   = !resvRow;
  const notes = notePipe
    ? notePipe
    : `Guest refund \u2014 ${refCode}${guestName ? ` (${guestName})` : ''}. Paid to ${recipient}.`;
  const pid = await createPending(db, chatId, 'refund_confirm', {
    refCode, amount, recipient,
    refundRef, notes, refundRail,
    loggedBy: whoFrom(from), notFound,
  });
  const railLabel = refundRail === 'resolution_center'
    ? 'Resolution Center (Airbnb nets from next payout)'
    : 'Off-platform (GCash / bank transfer)';
  const lines: string[] = [
    `\uD83D\uDCB8 *Refund Confirmation*`, ``,
    `Booking:   \`${refCode}\`${guestName ? `  \u00b7  ${mdEsc(guestName)}` : ''}`,
    `Refund to: ${mdEsc(recipient)}`,
    `Amount:    \u20b1${peso(amount)}`,
    origPayout != null ? `Orig payout: \u20b1${peso(origPayout)}` : `Orig payout: _not yet received_`,
    netAfter   != null ? `Net after:   \u20b1${peso(netAfter)}`   : `Net after:   _pending payout_`,
    `Rail: ${mdEsc(railLabel)}`,
    refundRef  ? `Ref: ${mdEsc(refundRef)}` : `Ref: _none_`,
    notes      ? `Note: ${mdEsc(notes.slice(0, 120))}` : '',
    notFound   ? `\n\u26a0\ufe0f Booking not found in DB \u2014 refund will be logged; verify REFCODE manually.` : '',
  ].filter(l => l !== '');
  await tgSend(chatId, lines.join('\n'), {
    reply_markup: { inline_keyboard: [[
      { text: '\u2705 Confirm Refund', callback_data: `refund_ok:${pid}` },
      { text: '\u274c Cancel',         callback_data: `llm_cancel:${pid}` },
    ]] },
  });
}

async function executeRefund(
  db: any, chatId: any, msgId: number, firstLine: string, payload: any
): Promise<void> {
  const { refCode, amount, recipient, refundRef, notes, refundRail, loggedBy } = payload;
  const { data: row, error } = await db.from('transactions').insert({
    property_id:      PROPERTY_ID,
    txn_type:         'expense',
    category:         'guest_refund',
    status:           'confirmed',
    source:           'refund',
    transaction_date: toManilaDate(),
    gross_amount:     amount,
    currency:         'PHP',
    external_ref:     refCode,
    payee_name:       recipient,
    notes:            notes ?? null,
    refund_rail:      refundRail,
    refund_ref:       refundRef ?? null,
    logged_by:        loggedBy ?? null,
  }).select('id').single();
  if (error || !row) {
    await tgEdit(chatId, msgId, firstLine + `\n\u26a0\ufe0f Could not log refund: ${errMsg(error?.message)}`);
    return;
  }
  const railNote = refundRail === 'resolution_center'
    ? '_Rail: Resolution Center \u2014 Airbnb will net from next payout._'
    : '_Rail: Off-platform \u2014 manually transferred._';
  await tgEdit(chatId, msgId, [
    `\u2705 *Refund logged*`,
    `\u20b1${peso(amount)}  \u00b7  ${mdEsc(recipient)}`,
    `Booking: \`${refCode}\``,
    refundRef ? `Ref: ${mdEsc(refundRef)}` : '',
    railNote,
    `_Ledger ref: ${shortRef(row.id)}_`,
  ].filter(Boolean).join('\n'));
}

// ═══════════════════════════════════════════════════════════════════════════
// CALLBACK QUERY HANDLER
// ═══════════════════════════════════════════════════════════════════════════

async function handleCallbackQuery(cq:any,db:any){
  const chatId=cq.message?.chat?.id;const msgId=cq.message?.message_id;const data=String(cq.data??'');
  // SPEC-16: these taps answer for themselves, so a refused tap can explain itself in the toast.
  if(!/^(inv:item:|inv:qty:|x:)/.test(data))await tgAnswerCB(cq.id);const firstLine=(cq.message?.text??'').split('\n')[0];

  if(data==='xx'){await tgEdit(chatId,msgId,CANCELLED);return;}
  if(data.startsWith('x:')){
    const pid=data.slice(2);
    const{data:row}=await db.from('telegram_pending').select('payload').eq('id',pid).eq('kind','awaiting_reply').maybeSingle();
    if(!row){await tgAnswerCB(cq.id,'That question is already closed.');return;}
    if(String(row.payload?.from_id)!==String(cq.from?.id)){await tgAnswerCB(cq.id,'That question is for someone else. Nothing changed.');return;}
    await db.from('telegram_pending').delete().eq('id',pid);
    await tgAnswerCB(cq.id);await tgEdit(chatId,msgId,CANCELLED);return;
  }
  if(data.startsWith('inv:item:')){
    const[,,pid,ns]=data.split(':');const n=Number(ns);
    const{data:row}=await db.from('telegram_pending').select('payload,expires_at').eq('id',pid).maybeSingle();
    if(!row||new Date(row.expires_at)<new Date()){await tgAnswerCB(cq.id,COUNT_EXPIRED);await tgEdit(chatId,msgId,COUNT_EXPIRED);return;}
    const items=(row.payload?.items??[]) as CountItem[];const it=items[n-1];
    if(!it){await tgAnswerCB(cq.id,COUNT_EXPIRED);return;}
    await tgAnswerCB(cq.id);
    await ask(db,chatId,cq.from?.id,'count_qty',{count_pid:pid,index:n},countQtyPrompt({...it,name:mdEsc(it.name)}),[{text:'0 — none left',callback_data:`inv:qty:${pid}:${n}`}]);
    return;
  }
  if(data.startsWith('inv:qty:')){
    const[,,pid,ns]=data.split(':');const n=Number(ns);
    const aw=await findAwaiting(db,chatId,cq.from?.id);
    if(!aw||aw.payload?.flow!=='count_qty'||aw.payload?.count_pid!==pid||Number(aw.payload?.index)!==n){await tgAnswerCB(cq.id,'That question is not open for you. Nothing changed.');return;}
    await db.from('telegram_pending').delete().eq('id',aw.id);
    const ok=await applyCountQty(db,chatId,pid,n,0,msgId);
    await tgAnswerCB(cq.id,ok?undefined:COUNT_EXPIRED);
    if(!ok)await tgEdit(chatId,msgId,COUNT_EXPIRED);
    return;
  }
  if(data.startsWith('item_ed:')){
    const[,txnId,ns]=data.split(':');const n=Number(ns);
    const txn=await loadReceiptTxn(db,txnId);if(!txn){await tgEdit(chatId,msgId,'⏰ That receipt is no longer editable.');return;}
    const it=normalizeLineItems(txn.ocr_raw?.line_items)[n-1];if(!it){await tgEdit(chatId,msgId,'⚠️ That item is no longer on the receipt. Tap ✏️ Edit item again.');return;}
    await tgEdit(chatId,msgId,`✏️ Editing item ${n}.`);
    await ask(db,chatId,cq.from?.id,'receipt_item_edit',{txnId,index:n},`✏️ ${mdEsc(it.name)} — ₱${peso(it.unit_price)}\nType the new price, like 216 — or name and price, like Mr Muscle 216.`);
    return;
  }
  if(data.startsWith('item_rm:')){
    const[,txnId,ns]=data.split(':');const n=Number(ns);
    const txn=await loadReceiptTxn(db,txnId);if(!txn){await tgEdit(chatId,msgId,'⏰ That receipt is no longer editable.');return;}
    const items=normalizeLineItems(txn.ocr_raw?.line_items);if(!items[n-1]){await tgEdit(chatId,msgId,'⚠️ That item is no longer on the receipt. Tap 🗑️ Remove item again.');return;}
    const[removed]=items.splice(n-1,1);await persistItems(db,txnId,txn.ocr_raw,items);
    await tgEdit(chatId,msgId,`🗑️ Removed "${mdEsc(removed.name)}".`);
    await sendReceiptCard(db,chatId,txnId);return;
  }

  // Session 28 (Lloyd's ask 2): 📋 Copy sends the card's 📨 text alone as monospace (long-press copies it;
  // Telegram has no copy-on-tap); ✏️ Revise hands the same text plus the card head to Cassy (telegram-cassy
  // "revise:"). Stateless: the tapped message carries the text.
  if(data==='tpl:copy'||data==='tpl:revise'){
    const cardText=String(cq.message?.text??cq.message?.caption??'');const tpl=templateOf(cardText);
    if(!tpl){await tgSend(chatId,'⚠️ No message text on that card.');return;}
    if(data==='tpl:copy'){await tgSend(chatId,'```\n'+tpl.replace(/```/g,"'''")+'\n```');return;}
    const head=cardText.split('\n').filter(Boolean).slice(0,4).join('\n');
    const synthetic={update_id:Number(cq.id)||Date.now(),message:{message_id:msgId,date:Math.floor(Date.now()/1000),chat:cq.message?.chat,from:cq.from,text:`cassy revise: ${tpl} ||| ${head}`}};
    await fetch(`${SUPABASE_URL}/functions/v1/telegram-cassy`,{method:'POST',headers:{'Content-Type':'application/json','X-Telegram-Bot-Api-Secret-Token':TG_SECRET},body:JSON.stringify(synthetic),signal:AbortSignal.timeout(20_000)}).catch(e=>console.error('cassy revise forward failed:',String(e)));
    return;
  }

  // v105 (SPEC-11 session 2, 2026-09-21): [🙈 Known, stop reminding] on a system-verifier card.
  // Telegram allows 64 bytes of callback data and a V1 key is two uuids, so the button carries
  // ackHash(key) and the key is found by hashing the findings that are still live. The table is a
  // handful of rows; when it is not, this is the line to revisit.
  // The RPC decides WHO may silence a finding (owner or admin) - this only decides WHICH one.
  if(data.startsWith('vf:ack:')){
    const want=data.slice('vf:ack:'.length);const who=cq.from?.first_name??'staff';
    // v106: this lookup used to fail SILENTLY - it returned without touching the card, so a broken
    // tap looked exactly like a tap that did nothing. Lloyd tapped on 2026-09-21 and saw no change at
    // all, which is how the silence was found. Every path below now writes on the card.
    const{data:rows,error:fErr}=await db.from('verifier_findings').select('key').in('status',['open','acknowledged']);
    if(fErr){await tgEdit(chatId,msgId,`${cq.message?.text??''}\n\n⚠️ Could not read the findings: ${String(fErr.message??fErr).slice(0,140)}`,cq.message?.reply_markup);return;}
    let key='';for(const r of (rows??[]) as Array<{key:string}>){if(await ackHash(r.key)===want){key=r.key;break;}}
    // No match means the finding resolved itself between the card being sent and the tap, which is
    // the good outcome. The count is on the line because "no match" and "no rows" are different
    // faults and the card is the only place anybody will look.
    if(!key){await tgEdit(chatId,msgId,`${cq.message?.text??''}\n\n✅ Closed on its own before you got here. (${(rows??[]).length} live findings checked)`);return;}
    const{data:r,error}=await db.rpc('telegram_ack_verifier_finding_v1',{p_telegram_user_id:cq.from?.id,p_key:key});
    let line:string,keep=false;
    if(error){keep=true;line=/does not exist|not found|could not find/i.test(error.message)?'⚠️ The acknowledge button is not switched on yet.':`⚠️ ${String(error.message).slice(0,150)}`;}
    else if(!r?.ok){const k=String(r?.reason??'');keep=['unmapped_telegram_user','not_authorized'].includes(k);
      line=({unmapped_telegram_user:`⛔ ${who}, your Telegram account is not mapped to a staff profile — ask Lloyd to map it.`,not_authorized:`⛔ ${who} is not allowed to silence a system finding.`,not_open:'ℹ️ Already acknowledged, or it has closed by itself.'} as Record<string,string>)[k]??`⚠️ ${k||'unknown result'}`;}
    else line=`🙈 Noted by ${who}. This stops reminding until something about it changes.`;
    await tgAnswerCB(cq.id);
    await tgEdit(chatId,msgId,`${cq.message?.text??''}\n\n${line}`,keep?cq.message?.reply_markup:undefined);
    return;
  }

  // v104 (session 27, booking PRD C2 / D-160 #3): Finance taps on the receipt card. The definer RPC maps
  // cq.from.id to staff_access_profiles.telegram_user_id, records the named review and decides the booking;
  // an unmapped or unauthorized tapper is refused and the buttons stay for someone who is.
  if(data.startsWith('bk_ok:')||data.startsWith('bk_no:')){
    const action=data.startsWith('bk_ok:')?'confirm':'decline';const cmpId=data.slice(6);const who=cq.from?.first_name??'staff';
    const{data:r,error}=await db.rpc('telegram_finance_decide_booking_v1',{p_telegram_user_id:cq.from?.id,p_comparison_id:cmpId,p_action:action,p_reason:`Telegram tap by ${whoFrom(cq.from)}`});
    let line:string,keep=false;
    if(error){keep=true;line=/does not exist|not found|could not find/i.test(error.message)?'⚠️ Telegram confirm is not switched on yet — use the Review link.':`⚠️ ${String(error.message).slice(0,150)}`;}
    else if(!r?.ok){const k=String(r?.reason??r?.outcome??'');keep=['unmapped_telegram_user','not_authorized','comparison_not_found'].includes(k);
      line=({unmapped_telegram_user:`⛔ ${who}, your Telegram account is not mapped to a Finance profile — ask Lloyd to map it.`,not_authorized:`⛔ ${who} is not authorized to approve payments.`,already_reviewed:`ℹ️ Already reviewed (${r?.outcome}).`,conflict:'⚠️ Those dates are no longer available — NOT confirmed.',invalid_state:'ℹ️ This request is no longer pending.'} as Record<string,string>)[k]??`⚠️ ${k||'unknown result'}`;}
    else line=action==='confirm'?`✅ Confirmed by ${who} — booking confirmed, calendar updated, guest e-mailed.`:`❌ Declined by ${who} — request cancelled, ledger row voided.`;
    await tgEditCaption(chatId,msgId,`${cq.message?.caption??''}\n\n${line}`,keep?cq.message?.reply_markup:undefined);
    if(r?.ok&&action==='confirm')await notifyMessengerBookingConfirmed(db,String(r.booking_id??'')).catch((e:unknown)=>console.error('messenger confirm:',String(e)));
    if(r?.ok&&action==='confirm'&&OPS_CHAT)await tgSend(OPS_CHAT,`🏠 CONFIRMED · Direct ${String(r.booking_id??'').slice(0,8).toUpperCase()}\n\nDirect booking confirmed by ${who}. Calendar is updated; turnover follows the usual schedule.`);
    return;
  }
  if(data.startsWith('inv:ok:')||data.startsWith('inv:no:')){
    const pid=data.slice(7);const who=cq.from?.first_name??'staff';
    // SPEC-16: the card's open item questions go with it, whoever was asked.
    await db.from('telegram_pending').delete().eq('chat_id',chatId).eq('kind','awaiting_reply').eq('payload->>count_pid',pid);
    if(data.startsWith('inv:no:')){
      await db.from('telegram_pending').delete().eq('id',pid);
      await tgEdit(chatId,msgId,`${firstLine}\n\n❌ Cancelled by ${who}, stock unchanged.`);return;
    }
    const payload=await consumePending(db,pid);
    if(!payload){await tgEdit(chatId,msgId,`${cq.message?.text??firstLine}\n\n⏰ That count expired. Run /count again.`);return;}
    const changes=(payload.changes??[]) as any[];
    const p_rows=changes.map(c=>({item_id:c.item_id,counted:c.counted,expected_before:c.before}));
    const{data:r,error}=await db.rpc('telegram_apply_inventory_count_v1',{p_telegram_user_id:cq.from?.id,p_rows,p_note:`Telegram count by ${whoFrom(cq.from)}`});
    let line:string,keep=false;
    if(error){keep=true;line=/does not exist|not found|could not find/i.test(error.message)?'⚠️ Telegram counts are not switched on yet — the count release is not applied.':`⚠️ ${String(error.message).slice(0,150)}`;}
    else if(!r?.ok){const k=String(r?.reason??'');
      // Keep the buttons where a DIFFERENT person could still legitimately tap Apply.
      keep=['unmapped_telegram_user','not_authorized'].includes(k);
      line=({unmapped_telegram_user:`⛔ ${who}, your Telegram account is not mapped to a staff profile — ask Lloyd to map it.`,
             not_authorized:`⛔ ${who} is not authorized to update stock.`,
             stock_changed:`⚠️ Stock moved since this list (${mdEsc(String(r?.item??''))}). Nothing was saved — run /count again.`,
             movement_controlled:`⚠️ ${mdEsc(String(r?.item??''))} is movement-controlled and must be counted through the ledger.`,
             duplicate_item:'⚠️ The same item appeared twice — run /count again.',
             bad_count:'⚠️ A count was negative or had more than two decimals.',
             bad_row_count:'⚠️ That count had no usable lines.',
             item_not_found:'⚠️ An item on that list no longer exists — run /count again.'} as Record<string,string>)[k]??`⚠️ ${k||'unknown result'}`;}
    else line=`✅ Applied by ${who} · ${r.updated} item${r.updated===1?'':'s'} updated · dashboard is current`;
    // A refused count must stay tappable, so the card (and its pending row) go back.
    if(keep&&!data.startsWith('inv:no:')&&payload) await db.from('telegram_pending').insert({id:pid,chat_id:chatId,kind:'inventory_count',payload,expires_at:new Date(Date.now()+60*60_000).toISOString()});
    const result=keep?`${cq.message?.text??firstLine}\n\n${line}`:[`📦 Count · ${payload.label??'Count'}`,...reviewLines(changes),'',line].join('\n');
    await tgEdit(chatId,msgId,result,keep?cq.message?.reply_markup:undefined);
    return;
  }
  if(data.startsWith('inv:grp:')){
    const scope=data.slice('inv:grp:'.length);
    if(!isFinanceChat(chatId))return;
    if(scope!=='1'&&scope!=='2'&&scope!=='3')return;
    await sendCountList(db,chatId,scope);return;
  }
  if(data.startsWith('refund_ok:')){
    const payload=await consumePending(db,data.slice('refund_ok:'.length));
    if(!payload){await tgEdit(chatId,msgId,firstLine+'\n\u23f0 _Expired._');return;}
    await tgEdit(chatId,msgId,firstLine+'\n_Logging refund\u2026_');
    await executeRefund(db,chatId,msgId,firstLine,payload);return;
  }
  if(data.startsWith('adv_scan:')){
    const payload=await consumePending(db,data.slice('adv_scan:'.length));
    if(!payload){await tgEdit(chatId,msgId,firstLine+'\n⏰ _Expired — re-send the photo._');return;}
    await tgEdit(chatId,msgId,'📸 _Scanning…_');
    const ph=payload.file_id?await fetchPhotoBytesByFileId(String(payload.file_id)):null;
    if(!ph){await tgSend(chatId,'⚠️ Could not fetch the image. Re-send it.');return;}
    await runAdvisoryOcr(db,chatId,ph.bytes,ph.mime,payload.from??{});return;
  }
  if(data.startsWith('adv_ignore:')){await db.from('telegram_pending').delete().eq('id',data.slice('adv_ignore:'.length));await tgEdit(chatId,msgId,'👍 _Ignored — not scanned._');return;}
  if(data.startsWith('adv_confirm:')){
    const payload=await consumePending(db,data.slice('adv_confirm:'.length));
    if(!payload){await tgEdit(chatId,msgId,firstLine+'\n⏰ _Expired._');return;}
    const occ=Array.isArray(payload.occurrences)?payload.occurrences:[];
    const postedBy=[payload.from?.first_name,payload.from?.username?`@${payload.from.username}`:null].filter(Boolean).join(' ');
    let saved=0;
    for(const o of occ){
      let dur=o.duration_hours;
      if(dur==null&&o.start_time&&o.end_time){const sh=Number(String(o.start_time).slice(0,2))+Number(String(o.start_time).slice(3,5))/60;const eh=Number(String(o.end_time).slice(0,2))+Number(String(o.end_time).slice(3,5))/60;dur=eh>sh?eh-sh:null;}
      const{error}=await db.from('ops_notices').insert({property_id:PROPERTY_ID,notice_type:'brownout',title:`${payload.source} power interruption`,description:payload.purpose||null,effective_date:o.date,effective_time:o.start_time??null,duration_hours:(dur!=null&&isFinite(dur))?Number(Number(dur).toFixed(1)):null,feeder:`Feeder ${CASCADE_FEEDER}`,posted_by_chat_id:payload.from?.id??null,posted_by_name:postedBy});
      if(!error)saved++;
    }
    await tgEdit(chatId,msgId,firstLine+`\n⚡ *Saved ${saved} brownout notice${saved!==1?'s':''}.*`);return;
  }
  if(data.startsWith('llm_expense_confirm:')){
    const payload=await consumePending(db,data.slice('llm_expense_confirm:'.length));
    if(!payload){await tgEdit(chatId,msgId,firstLine+'\n⏰ _Expired — please try again._');return;}
    await tgEdit(chatId,msgId,firstLine+'\n_Saving…_');
    const{data:row,error}=await insertExpense(db,payload);
    if(error||!row){await tgEdit(chatId,msgId,'⚠️ Could not save.');return;}
    await tgEdit(chatId,msgId,confirmMsg(payload.amount,payload.label??payload.category,payload.payee??null,row.id));
    return;
  }
  if(data.startsWith('llm_void_confirm:')){
    const payload=await consumePending(db,data.slice('llm_void_confirm:'.length));
    if(!payload){await tgEdit(chatId,msgId,firstLine+'\n⏰ _Expired._');return;}
    await db.from('ops_notices').update({is_active:false,updated_at:new Date().toISOString()}).eq('id',payload.noticeId);
    await tgEdit(chatId,msgId,firstLine+'\n🗑️ *Notice removed.*');
    return;
  }
  if(data.startsWith('llm_edit_confirm:')){
    const payload=await consumePending(db,data.slice('llm_edit_confirm:'.length));
    if(!payload){await tgEdit(chatId,msgId,firstLine+'\n⏰ _Expired._');return;}
    const ch:Record<string,unknown>={updated_at:new Date().toISOString()};
    const c=payload.changes??{};
    if(c.title)          ch.title=c.title;
    if(c.effective_date) ch.effective_date=c.effective_date;
    if(c.effective_time) ch.effective_time=c.effective_time;
    if(c.duration_hours!==undefined) ch.duration_hours=c.duration_hours;
    await db.from('ops_notices').update(ch).eq('id',payload.noticeId);
    await tgEdit(chatId,msgId,firstLine+'\n✅ *Notice updated.*');
    return;
  }
  if(data.startsWith('llm_confirm:')){
    const payload=await consumePending(db,data.slice('llm_confirm:'.length));
    if(!payload){await tgEdit(chatId,msgId,firstLine+'\n⏰ _Expired — please try again._');return;}
    await tgEdit(chatId,msgId,firstLine+'\n_Saving…_');
    await executeNoticeFromLLM(db,payload.params,chatId,payload.from);return;
  }
  if(data.startsWith('llm_cancel:')){
    await db.from('telegram_pending').delete().eq('id',data.slice('llm_cancel:'.length));
    await tgEdit(chatId,msgId,firstLine+'\n❌ _Cancelled._');return;
  }
  if(data.startsWith('lvt_confirm:')){
    const payload=await consumePending(db,data.slice('lvt_confirm:'.length));
    if(!payload){await tgEdit(chatId,msgId,firstLine+'\n⏰ _Expired._');return;}
    await db.from('transactions').update({status:'void',notes:'Voided via Telegram NL',updated_at:new Date().toISOString()}).eq('id',payload.txnId);
    await tgEdit(chatId,msgId,firstLine+`\n✅ Ref \`${payload.refCode}\` voided.`);return;
  }
  if(data.startsWith('lvts_confirm:')){
    const payload=await consumePending(db,data.slice('lvts_confirm:'.length));
    if(!payload){await tgEdit(chatId,msgId,firstLine+'\n⏰ _Expired._');return;}
    const ids=Array.isArray(payload.txnIds)?payload.txnIds:[];
    await db.from('transactions').update({status:'void',notes:'Voided via Telegram NL',updated_at:new Date().toISOString()}).in('id',ids);
    await tgEdit(chatId,msgId,firstLine+`\n✅ ${ids.length} transaction${ids.length!==1?'s':''} voided.`);return;
  }
  if(data.startsWith('cleanerack:')){
    const cleaner=decodeURIComponent(data.slice('cleanerack:'.length));
    const ackerName=whoFrom(cq.from).split(' ').slice(0,2).join(' ')||'Team';
    const mt=new Date().toLocaleTimeString('en-PH',{timeZone:'Asia/Manila',hour:'2-digit',minute:'2-digit'});
    await db.from('cleaning_sessions').update({fee_acked_at:new Date().toISOString()}).eq('property_id',PROPERTY_ID).eq('cleaner_name',cleaner).not('fee_paid_at','is',null).is('fee_acked_at',null);
    await tgEdit(chatId,msgId,`${cq.message?.text??'🧹 Cleaning Fees Settled'}\n\n✅ Acknowledged by ${ackerName} at ${mt}`);return;
  }
  // ── v52: Dashboard "Send Invoice" → cleaner acknowledgement ──
  if(data.startsWith('cleanpayinvoice:')){
    const payload=await consumePending(db,data.slice('cleanpayinvoice:'.length));
    if(!payload){await tgEdit(chatId,msgId,firstLine+'\n⏰ _Expired._');return;}
    const ackerName=whoFrom(cq.from).split(' ').slice(0,2).join(' ')||'Team';
    const res=await bookCleaningFee(db,String(payload.sessionId),Number(payload.feeAmount),ackerName);
    if(!res.ok&&!res.already){await tgEdit(chatId,msgId,firstLine+`\n⚠️ Could not record payment: ${errMsg(res.error)}`);return;}
    const mt=new Date().toLocaleTimeString('en-PH',{timeZone:'Asia/Manila',hour:'2-digit',minute:'2-digit'});
    await db.from('cleaning_sessions').update({fee_acked_at:new Date().toISOString()}).eq('id',String(payload.sessionId)).is('fee_acked_at',null);
    await tgEdit(chatId,msgId,firstLine+`\n\n✅ *Received* — confirmed by ${ackerName} at ${mt}`);
    return;
  }
  if(data.startsWith('pcsel:'))  {await paySessionCard(db,chatId,msgId,data.slice('pcsel:'.length));return;}
  if(data.startsWith('pcpay:'))  {const[,sid,fs]=data.split(':');const fee=Number(fs)||0;const res=await bookCleaningFee(db,sid,fee,whoFrom(cq.from));if(!res.ok){await tgEdit(chatId,msgId,`⚠️ Could not book: ${errMsg(res.error)}`);return;}if(res.already){await tgEdit(chatId,msgId,'ℹ️ That clean was already paid.');return;}await tgEdit(chatId,msgId,`✅ *Paid ${mdEsc(res.cleaner??'cleaner')} ₱${peso(fee)}* for ${res.date}\nBooked to ledger.\n_Run /notifyclean to send the acknowledgement card._`);return;}
  if(data.startsWith('pcedit:')) {await ask(db,chatId,cq.from?.id,'payclean_amount',{sid:data.slice('pcedit:'.length)},'💵 Type the amount you paid for this clean, like 500.');return;}
  if(data==='pccancel'){await tgEdit(chatId,msgId,'❌ Cancelled.');return;}
  if(data.startsWith('menu:')){
    const rest=data.slice(5);const isF=isFinanceChat(chatId);
    if(rest==='main'){
      const kb=isF?mainMenuKb():opsMenuKb();
      const text=isF
        ? buildMenuHeader('🏠 *Cascade Finance*','Select a section:',kb.inline_keyboard)
        : buildMenuHeader('📌 *Cascade OPS*','What do you need?',kb.inline_keyboard);
      await tgEdit(chatId,msgId,text,kb);return;
    }
    if(rest.startsWith('tip:')){
      const tk=rest.slice(4);const bc=isF?`menu:${TIP_BACK[tk]??'main'}`:'menu:main';
      await tgEdit(chatId,msgId,MENU_TIPS[tk]??'_No tip available._',{inline_keyboard:[[{text:'← Back',callback_data:bc}]]});return;
    }
    if(rest.startsWith('do:')){
      const cmd=rest.slice(3);
      if(cmd.startsWith('nt:'))    {await handleNoticesByType(chatId,db,cmd.slice(3));return;}
      switch(cmd){
        case 'log':         await tgSend(chatId,'🧾 *Log an Expense*\n\nSelect a category:',{reply_markup:categoryKeyboard(0)});break;
        case 'inventory':   await handleStockQuery(db,chatId,isF?'finance':'ops',{filter:'all'});break; // session 28: [/inventory] button
        case 'stock':       await handleStockQuery(db,chatId,isF?'finance':'ops',{filter:'low'});break;
        case 'count':       if(isF)await promptCountScope(db,chatId);else await tgSend(chatId,'Counts are updated from the Finance group.');break; // session 33: SPEC-03
        case 'payclean':    if(isF)await payCleanList(db,chatId);break;
        case 'manualclean': if(isF)await promptManualClean(db,chatId,cq.from?.id);break;
        case 'notifyclean': if(isF)await notifyCleanAcks(db,chatId);break;
        case 'summary':     if(isF)await runSummary(db,chatId);break;
        case 'notices':     await handleNoticesList(chatId,db);break;
        case 'cal':         await handleCalendarNotices(chatId,db);break;
        case 'weather':     await sendWeather(chatId);break;
        case 'schedule':    await sendSchedule(chatId,db);break;
      }
      return;
    }
    if(isF){const{text,kb}=subMenuKb(rest);await tgEdit(chatId,msgId,text,kb);}else{const kb=opsMenuKb();await tgEdit(chatId,msgId,buildMenuHeader('📌 *Cascade OPS*','What do you need?',kb.inline_keyboard),kb);}
    return;
  }
  if(data.startsWith('cat:'))    {const[,slug,amtStr]=data.split(':');const pre=Number(amtStr)||0;const label=await getCategoryLabel(db,slug);await tgEdit(chatId,msgId,`🧾 *Log an Expense*\n✅ Category: *${label}*`);await ask(db,chatId,cq.from?.id,'expense',{slug,pre},expensePromptText(label,pre));return;}
  if(data.startsWith('dup_ok:')) {const payload=await consumePending(db,data.slice('dup_ok:'.length));if(!payload){await tgEdit(chatId,msgId,firstLine+'\n⏰ _Expired._');return;}const{data:row,error}=await insertExpense(db,payload);if(error||!row){await tgEdit(chatId,msgId,'⚠️ Could not save.');return;}await tgEdit(chatId,msgId,confirmMsg(payload.amount,payload.label??payload.category,payload.payee,row.id));return;}
  if(data.startsWith('dup_cancel:')){await db.from('telegram_pending').delete().eq('id',data.slice('dup_cancel:'.length));await tgEdit(chatId,msgId,firstLine+'\n❌ _Cancelled._');return;}
  if(data.startsWith('continue_ocr:')){
    const payload=await consumePending(db,data.slice('continue_ocr:'.length));if(!payload){await tgEdit(chatId,msgId,'⏰ _Expired._');return;}
    await tgEdit(chatId,msgId,'📸 _Processing receipt…_');
    const{data:blob,error:dlErr}=await db.storage.from(RECEIPTS_BUCKET).download(payload.objectPath);
    if(dlErr||!blob){await tgSend(chatId,'⚠️ Could not retrieve image. Please re-send.');return;}
    await runOcr(db,chatId,payload.objectPath,new Uint8Array(await blob.arrayBuffer()),blob.type||'image/jpeg',payload.loggedBy,payload.notes,payload.categoryHint??'');return;
  }
  if(data.startsWith('ocr_ok:'))   {const txnId=data.slice('ocr_ok:'.length);await db.from('transactions').update({status:'confirmed',updated_at:new Date().toISOString()}).eq('id',txnId);await tgEdit(chatId,msgId,firstLine+`\n✅ *Confirmed — added to ledger*\n🔖 Ref: ${shortRef(txnId)}`);await maybeOfferInventorySync(db,chatId,txnId);return;}
  if(data.startsWith('ocr_edit:')) {await ask(db,chatId,cq.from?.id,'edit_amount',{txnId:data.slice('ocr_edit:'.length)},'💵 Type the correct total, like 1706.');return;}
  if(data.startsWith('ocr_void:')) {await db.from('transactions').update({status:'void',notes:'Discarded via Telegram',updated_at:new Date().toISOString()}).eq('id',data.slice('ocr_void:'.length));await tgEdit(chatId,msgId,firstLine+'\n❌ *Discarded*');return;}
  if(data.startsWith('item_edit:'))   {await promptEditItem(db,chatId,data.slice('item_edit:'.length));return;}
  if(data.startsWith('item_add:'))    {const txnId=data.slice('item_add:'.length);if(!await loadReceiptTxn(db,txnId)){await tgSend(chatId,'⏰ That receipt is no longer editable.');return;}await ask(db,chatId,cq.from?.id,'receipt_item_add',{txnId},'➕ Type the item and its price, like Joy Dishwashing 89. Add x2 for quantity.');return;}
  if(data.startsWith('item_remove:')) {await promptRemoveItem(db,chatId,data.slice('item_remove:'.length));return;}
  if(data.startsWith('invsync_ok:')){
    const payload=await consumePending(db,data.slice('invsync_ok:'.length));if(!payload){await tgEdit(chatId,msgId,firstLine+'\n⏰ _Expired._');return;}
    const results:string[]=[];for(const it of (payload.items??[])){const{data:r,error}=await db.rpc('apply_inventory_purchase',{p_item_id:it.item_id,p_qty:it.qty,p_unit_cost:it.unit_price??null,p_supplier:payload.vendor??null,p_purchased_at:payload.date??null,p_txn_id:payload.txnId??null});if(!error&&r?.ok)results.push(`  • ${mdEsc(r.name)}: ${Number(r.qty_before)} → ${Number(r.qty_after)}`);else results.push(`  • ${mdEsc(it.item_name)}: ⚠️ failed`);}
    await tgEdit(chatId,msgId,[`📦 *Inventory updated*`,...results].join('\n'));return;
  }
  if(data.startsWith('invsync_skip:')){await db.from('telegram_pending').delete().eq('id',data.slice('invsync_skip:'.length));await tgEdit(chatId,msgId,firstLine+'\n⏭️ _Stock unchanged._');return;}
}

async function executeNoticeFromLLM(db:any,params:any,chatId:any,from:any){
  if(!params?.notice_type||!params?.title||!params?.effective_date){await tgSend(chatId,'⚠️ Notice data incomplete.');return;}
  const postedBy=[from?.first_name,from?.username?`@${from.username}`:null].filter(Boolean).join(' ');
  const{error}=await db.from('ops_notices').insert({property_id:PROPERTY_ID,notice_type:params.notice_type,title:params.title,effective_date:params.effective_date,effective_time:params.effective_time??null,duration_hours:params.duration_hours??null,feeder:params.notice_type==='brownout'?'Feeder 14-3':null,posted_by_chat_id:from?.id??null,posted_by_name:postedBy});
  const icon=NOTICE_ICON[params.notice_type]??'📌';
  if(error){await tgSend(chatId,`⚠️ Could not save: ${errMsg(error.message)}`);return;}
  await tgSend(chatId,`${icon} *Notice saved* — ${mdEsc(params.title)} on ${params.effective_date}`);
}

/** SPEC-16: the text is the answer to the question this person was asked. A bad answer keeps the question open. */
async function handleAnswer(db:any,chatId:any,msg:any,aw:{id:string;payload:any},text:string,loggedBy:string){
  const p=aw.payload??{};const flow=p.flow as Flow;
  const bad=()=>tgReply(chatId,msg.message_id,refusal(flow),{reply_markup:cancelKb(aw.id)});
  const done=()=>db.from('telegram_pending').delete().eq('id',aw.id);
  const gone=async()=>{await done();await tgReply(chatId,msg.message_id,'⏰ That receipt is no longer editable, so nothing was saved.');};
  switch(flow){
    case 'count_qty':{
      const q=parseQty(text);if(q===null){await bad();return;}
      await done();
      if(!await applyCountQty(db,chatId,String(p.count_pid),Number(p.index),q,p.prompt_mid))await tgReply(chatId,msg.message_id,COUNT_EXPIRED);
      return;
    }
    case 'expense':{
      const a=parseExpenseAnswer(text,Number(p.pre)||0);if(!a){await bad();return;}
      await done();const label=await getCategoryLabel(db,String(p.slug));
      await validateAndInsert(db,chatId,{category:String(p.slug),amount:a.amount,label,payee:a.vendor,notes:a.vendor,loggedBy});return;
    }
    case 'edit_amount':{
      const amount=parseMoney(text);if(amount===null){await bad();return;}
      if(!await loadReceiptTxn(db,String(p.txnId))){await gone();return;}
      await done();
      await db.from('transactions').update({gross_amount:amount,updated_at:new Date().toISOString()}).eq('id',p.txnId);
      await sendReceiptCard(db,chatId,String(p.txnId),`💵 Total set to ₱${peso(amount)}.`);return;
    }
    case 'payclean_amount':{
      const amount=parseMoney(text);if(amount===null){await bad();return;}
      await done();
      const res=await bookCleaningFee(db,String(p.sid),amount,loggedBy);
      if(!res.ok){await tgReply(chatId,msg.message_id,`⚠️ Could not book: ${errMsg(res.error)}`);return;}
      if(res.already){await tgReply(chatId,msg.message_id,'ℹ️ That clean was already paid.');return;}
      await tgReply(chatId,msg.message_id,`✅ Paid *${mdEsc(res.cleaner??'cleaner')}* ₱${peso(amount)} for ${res.date}. Booked to ledger.`);return;
    }
    case 'receipt_item_edit':{
      const parsed=parseNamePriceQty(text.trim().split(/\s+/));if(parsed.price===null){await bad();return;}
      const txn=await loadReceiptTxn(db,String(p.txnId));if(!txn){await gone();return;}
      await done();await handleItemEditAnswer(db,chatId,msg,txn,Number(p.index),parsed);return;
    }
    case 'receipt_item_add':{
      const parsed=parseNamePriceQty(text.trim().split(/\s+/));if(!parsed.name||parsed.price===null){await bad();return;}
      const txn=await loadReceiptTxn(db,String(p.txnId));if(!txn){await gone();return;}
      await done();await handleItemAddAnswer(db,chatId,txn,parsed);return;
    }
    case 'manual_clean':{
      const m=parseManualClean(text);if(!m){await bad();return;}
      await done();await handleManualCleanAnswer(db,chatId,msg,m);return;
    }
    default: await done(); await tgReply(chatId,msg.message_id,NOT_WAITING);
  }
}

async function handleTextMessage(msg:any,db:any){
  const chatId=msg.chat?.id;const from=msg.from??{};
  const loggedBy=whoFrom(from);
  // SPEC-16 (D-196): in Finance the answer is routed by WHO typed it, so this runs before the @mention gate
  // and Reply is optional. Step 3 is the D-195 guard: a reply to a bot card that asked nothing never books.
  if(isFinanceChat(chatId)){
    const text=stripBotMention(String(msg.text??'').trim());if(!text)return;
    const aw=await findAwaiting(db,chatId,from.id);
    const card=aw?null:await findCountCard(db,chatId,msg.reply_to_message?.message_id);
    const route=routeText({awaiting:!!aw,replyToCountCard:!!card,replyToBot:!!msg.reply_to_message?.from?.is_bot,text});
    if(route.kind==='flow'){await handleAnswer(db,chatId,msg,aw!,text,loggedBy);return;}
    if(route.kind==='count_lines'){await handleCountReply(db,chatId,msg,card!,text);return;}
    if(route.kind==='refuse'){await tgReply(chatId,msg.message_id,NOT_WAITING);return;}
  }
  // A reply-keyboard tap arrives as the button's LABEL - no slash, no @mention - so it has to be
  // recognised BEFORE the addressed-the-bot gate, which would otherwise drop it. Tapping a button
  // the bot itself put on the keyboard IS addressing the bot. (Found live: /keyboard worked because
  // it starts with a slash, and the buttons it installed then did nothing at all.)
  const tapped=stripBotMention(String(msg.text??'').trim());if(!tapped)return;
  const kbCmd=KB_LABEL_CMD[tapped];
  if(!kbCmd&&!isBotAddressed(msg))return;
  const text=kbCmd??tapped;
  if(text.startsWith('/')){
    if(text==='/keyboard'||text==='/buttons'){
      await tgSend(chatId,'Tap the keyboard symbol beside the message box to show or hide these buttons.',{reply_markup:isFinanceChat(chatId)?finReplyKb():opsReplyKb()});
      return;
    }
    const[rawCmd,...args]=text.split(/\s+/);const cmd=rawCmd.toLowerCase().replace(/@.*$/,'');
    if(['/brownout','/holiday','/event','/reminder'].includes(cmd)){await handleOpsNoticeCommand(cmd.slice(1),args,chatId,from,db);return;}
    if(cmd==='/notices'){await handleNoticesList(chatId,db);return;}
    if(cmd==='/stock'){await handleStockQuery(db,chatId,isFinanceChat(chatId)?'finance':'ops',{filter:(args[0]??'').toLowerCase()==='all'?'all':'low'});return;}
    if(cmd==='/inventory'){await handleStockQuery(db,chatId,isFinanceChat(chatId)?'finance':'ops',{filter:'all'});return;}
    if(cmd==='/count'){if(!isFinanceChat(chatId)){await tgSend(chatId,'Counts are updated from the Finance group.');return;}await promptCountScope(db,chatId);return;}
    if(cmd==='/menu'||cmd==='/help'||cmd==='/start'){await showMenu(chatId);return;}
    if(!isFinanceChat(chatId))return;
    if(cmd==='/purchase')    {await tgSend(chatId,'📸 Send me the receipt photo and I\'ll read it, then offer to update stock for any matched items.');return;}
    if(cmd==='/status')      {await handleStatus(db,chatId);return;}
    if(cmd==='/ping')        {await handlePing(chatId);return;}
    if(cmd==='/log')         {await tgSend(chatId,'🧾 *Log an Expense*\n\nSelect a category:',{reply_markup:categoryKeyboard(0)});return;}
    if(cmd==='/payclean')    {await payCleanList(db,chatId);return;}
    if(cmd==='/manualclean') {await promptManualClean(db,chatId,from.id);return;}
    if(cmd==='/notifyclean') {await notifyCleanAcks(db,chatId);return;}
    if(cmd==='/summary')     {await runSummary(db,chatId);return;}
    if(cmd==='/datahealth')  {await handleDataHealth(db,chatId);return;}
    if(cmd==='/refund')      {await handleRefundCommand(db,chatId,from,args);return;}
    if(cmd==='/void'){
      const refCode=(args[0]??'').toUpperCase();
      if(!/^[0-9A-F]{8}$/.test(refCode)){await tgSend(chatId,'⚠️ Usage: `/void REFCODE` — e.g. `/void 5EB836FA`');return;}
      // id is uuid: ilike never matches. uuid sorts bytewise, so a prefix is the range [ref-0000…, ref-ffff…].
      const[lo,hi]=refRange(refCode);
      const{data:rows}=await db.from('transactions').select('id,gross_amount,category,status').eq('property_id',PROPERTY_ID).gte('id',lo).lte('id',hi).limit(1);
      const txn=rows?.[0];if(!txn){await tgSend(chatId,`⚠️ No transaction with ref \`${refCode}\`.`);return;}
      if(txn.status==='void'){await tgSend(chatId,`ℹ️ \`${refCode}\` is already void.`);return;}
      await db.from('transactions').update({status:'void',notes:'Voided via /void',updated_at:new Date().toISOString()}).eq('id',txn.id);
      await tgSend(chatId,`✅ Ref \`${refCode}\` (₱${peso(txn.gross_amount)} · ${txn.category}) voided.`);return;
    }
    await showMenu(chatId);return;
  }

  // Free text is Cassy's (telegram-cassy, D-104); only replies to bot prompts and numeric text reach here.
  if(!isFinanceChat(chatId)){
    await tgSend(chatId,'_Ask Cassy by name, e.g. "Cassy, what is low in stock?" — or tap /menu._');
    return;
  }

  // v51: Fast-entry parser — only fires when FIRST token is numeric (starts with digit or ₱).
  // Non-numeric-leading inputs (e.g. "void pending 2 receipts") bypass the amount parser
  // and go straight to LLM dispatch, preventing misrouting.
  const tokens=text.split(/\s+/);
  const firstTok=(tokens[0]??'').replace(/[₱,]/g,'');
  const{amount,idx}=/^\d+(\.\d{1,2})?$/.test(firstTok)?parseAmount(tokens):{amount:null,idx:-1};
  if(amount!==null){
    const cats=await getCategories(db);const remTokens=tokens.filter((_,i)=>i!==idx);const remainder=remTokens.join(' ').trim();
    const{slug,label,matched}=classify(remainder,cats);
    const stripped=matched?remTokens.filter(t=>t.toLowerCase()!==matched).join(' ').trim():remainder;
    await validateAndInsert(db,chatId,{category:slug,amount,label,payee:stripped||null,notes:remainder||null,loggedBy});return;
  }

  {
    const det=detectAmountAnywhere(text);
    await tgSend(chatId,`🧾 *Log an Expense*\n${det>0?`💡 Detected *₱${peso(det)}* — select a category:`:'Select a category to log an expense:'}`,{reply_markup:categoryKeyboard(det)});
  }
}

async function handlePhotoMessage(msg:any,db:any){
  const cid=msg.chat?.id;
  if(!isAllowedChat(cid))return;
  if(msg.from?.is_bot)return;
  const wantsAdvisory=captionWantsAdvisory(msg.caption);
  if(wantsAdvisory){const ph=await fetchPhotoBytes(msg);if(!ph){await tgSend(cid,'⚠️ Could not fetch the image. Try again.');return;}await runAdvisoryOcr(db,cid,ph.bytes,ph.mime,msg.from??{});return;}
  if(!isFinanceChat(cid)){
    // Ops chat: require bot-addressing before offering the advisory-scan prompt,
    // so a random shared photo doesn't trigger a confirm card. Finance chat skips
    // this gate below — its own help text (MENU_TIPS.ocr) already promises any
    // photo sent there is read automatically, no @mention needed.
    if(!isBotAddressed(msg))return;
    const fid=largestPhotoId(msg);if(!fid)return;
    const pid=await createPending(db,cid,'advisory_scan',{file_id:fid,from:{first_name:msg.from?.first_name,username:msg.from?.username,id:msg.from?.id}});
    await tgSend(cid,'📸 Is this a *power advisory* to scan?\n_Regular photos (sharing, etc.) don\'t need scanning — just tap Ignore._',{reply_markup:{inline_keyboard:[[{text:'⚡ Scan advisory',callback_data:`adv_scan:${pid}`},{text:'❌ Ignore',callback_data:`adv_ignore:${pid}`}]]}});
    return;
  }
  const chatId=msg.chat?.id;const from=msg.from??{};const loggedBy=whoFrom(from);
  // SPEC-16: a receipt photo sent while this person is being asked for an expense takes that category.
  const aw=await findAwaiting(db,chatId,from.id);
  const cat=aw?.payload?.flow==='expense'?String(aw.payload.slug??''):'';
  if(cat)await db.from('telegram_pending').delete().eq('id',aw!.id);
  try{
    const best=msg.photo[msg.photo.length-1];
    const fileMeta=await tgCall('getFile',{file_id:best.file_id});const filePath=fileMeta?.result?.file_path;
    if(!filePath){await tgSend(chatId,'⚠️ Could not fetch photo. Try again.');return;}
    const bytes=new Uint8Array((await fetch(`https://api.telegram.org/file/bot${TG_TOKEN}/${filePath}`).then(r=>r.arrayBuffer())) as ArrayBuffer);
    const ext=(filePath.split('.').pop()||'jpg').toLowerCase();
    const objectPath=`receipts/${chatId}/${best.file_unique_id}.${ext}`;
    const mime=`image/${ext==='jpg'?'jpeg':ext}`;
    const{data:existing}=await db.from('transactions').select('id,gross_amount,category,status').eq('receipt_image_path',objectPath).neq('status','void').maybeSingle();
    if(existing){const pid=await createPending(db,chatId,'photo_dup',{objectPath,loggedBy,notes:msg.caption?String(msg.caption).trim():null,categoryHint:cat});await tgSend(chatId,[`⚠️ *Receipt already logged*`,`₱${peso(existing.gross_amount)} · ${existing.category} — Ref: \`${shortRef(existing.id)}\``,``,`This looks like the same receipt. Is it a different one?`].join('\n'),{reply_markup:photoDupKeyboard(pid)});return;}
    const{error:upErr}=await db.storage.from(RECEIPTS_BUCKET).upload(objectPath,bytes,{contentType:mime,upsert:true});
    if(upErr){await tgSend(chatId,`⚠️ Upload failed: ${errMsg(upErr.message)}`);return;}
    await tgSend(chatId,'📸 Receipt received — reading it now…');
    await runOcr(db,chatId,objectPath,bytes,mime,loggedBy,msg.caption?String(msg.caption).trim():null,cat);
  }catch(e){await tgSend(chatId,`⚠️ Photo error: ${errMsg(e)}`);}
}

// ═══════════════════════════════════════════════════════════════════════════
// /datahealth — Finance-only data reconciliation health check (v51)
// ═══════════════════════════════════════════════════════════════════════════
async function handleDataHealth(db:any, chatId:any): Promise<void> {
  await tgSend(chatId, '🔍 _Running data health check…_');

  const { data: resRows } = await db
    .from('airbnb_reservations')
    .select('confirmation_code,guest_name,checkin_date,checkout_date,host_payout,payout_amount')
    .eq('property_id', PROPERTY_ID)
    .eq('status', 'completed')
    .order('checkin_date', { ascending: false });
  const reservations = (resRows ?? []) as any[];

  const { data: csvRows } = await db
    .from('airbnb_transactions')
    .select('confirmation_code,row_type,paid_out,gross_earnings,txn_date')
    .eq('property_id', PROPERTY_ID)
    .in('row_type', ['payout', 'reservation']);
  const csvByCode = new Map<string, any[]>();
  for (const row of ((csvRows ?? []) as any[])) {
    const code = String(row.confirmation_code ?? '');
    if (!code) continue;
    if (!csvByCode.has(code)) csvByCode.set(code, []);
    csvByCode.get(code)!.push(row);
  }

  const TOLERANCE = 5;
  const missing: string[]  = [];
  const mismatches: string[] = [];
  let reconciled = 0;

  for (const res of reservations) {
    const code = String(res.confirmation_code ?? '');
    if (!code) continue;
    const csvEntries = csvByCode.get(code) ?? [];
    const csvPayout  = csvEntries.find((r:any) => r.row_type === 'payout' || r.row_type === 'reservation');

    if (!csvPayout) {
      missing.push(code);
      continue;
    }

    const csvAmount = Number(csvPayout.paid_out ?? csvPayout.gross_earnings ?? 0);
    const resAmount = Number(res.host_payout ?? res.payout_amount ?? 0);

    if (resAmount > 0 && Math.abs(csvAmount - resAmount) > TOLERANCE) {
      mismatches.push(
        `${code} — CSV ₱${peso(csvAmount)} vs email ₱${peso(resAmount)}`
      );
    } else {
      reconciled++;
    }
  }

  const resCodes = new Set(reservations.map((r:any) => String(r.confirmation_code ?? '')).filter(Boolean));
  const orphaned: string[] = [];
  for (const [code] of csvByCode) {
    if (code && !resCodes.has(code)) orphaned.push(code);
  }

  const total = reservations.length;
  const lines: string[] = [
    '🔍 *Data Health Check*',
    `_as of ${toManilaDate()}_`,
    '───────────────────',
    `✅ Reconciled:       ${reconciled} / ${total}`,
    `⚠️ Amount mismatch:  ${mismatches.length}`,
    `❌ Missing payout:   ${missing.length}`,
    `📋 Orphaned CSV rows: ${orphaned.length}`,
    '───────────────────',
  ];

  if (mismatches.length > 0) {
    lines.push('', '*Amount mismatches*');
    mismatches.slice(0, 10).forEach(m => lines.push(`  • ${mdEsc(m)}`));
    if (mismatches.length > 10) lines.push(`  _…and ${mismatches.length - 10} more_`);
  }

  if (missing.length > 0) {
    lines.push('', '*Missing CSV payout*');
    missing.slice(0, 10).forEach(c => lines.push(`  • \`${c}\``));
    if (missing.length > 10) lines.push(`  _…and ${missing.length - 10} more_`);
  }

  if (orphaned.length > 0) {
    lines.push('', '*Orphaned CSV rows (no reservation match)*');
    orphaned.slice(0, 5).forEach(c => lines.push(`  • \`${c}\``));
    if (orphaned.length > 5) lines.push(`  _…and ${orphaned.length - 5} more_`);
  }

  if (missing.length === 0 && mismatches.length === 0 && orphaned.length === 0) {
    lines.push('', '✅ _All data is fully reconciled. No issues found._');
  }

  await tgSend(chatId, lines.join('\n'));
}

async function handlePing(chatId: any) {
  const lines = [
    '🩺 *Bot Diagnostic — v56*', '',
    `GEMINI\\_BOT\\_KEY: ${GEMINI_KEY ? '✅ set' : '❌ missing (LLM disabled)'}`,
    `BOT\\_USERNAME: ${BOT_USERNAME ? `✅ ${BOT_USERNAME}` : '⚠️ not set (mention-strip disabled)'}`,
    `WEATHER\\_KEY: ${WEATHER_KEY ? '✅ set' : '❌ missing (weather disabled)'}`,
    `FINANCE\\_CHAT: ${FINANCE_CHAT ? '✅ set' : '❌ missing'}`,
    `OPS\\_CHAT: ${OPS_CHAT ? '✅ set' : '❌ missing'}`,
    '',
  ];
  if (!GEMINI_KEY) { await tgSend(chatId, lines.join('\n') + '\n❌ Cannot test Gemini — key missing.'); return; }
  lines.push('_Testing Gemini dispatch model…_');
  await tgSend(chatId, lines.join('\n'));
  try {
    const res = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${DISPATCH_MODEL}:generateContent?key=${GEMINI_KEY}`,
      { method:'POST', headers:JSON_H,
        body:JSON.stringify({contents:[{parts:[{text:'Reply with exactly: {"status":"ok"}'}]}],generationConfig:{temperature:0,response_mime_type:'application/json'}}),
        signal:AbortSignal.timeout(15_000) }
    );
    if (res.ok) {
      const d = await res.json();
      const txt = (d?.candidates?.[0]?.content?.parts?.map((p:any)=>p.text).join('')??'').slice(0,120);
      await tgSend(chatId, `✅ Gemini *${DISPATCH_MODEL}* responded:\n\`${txt}\``);
    } else {
      const body = await res.text().catch(()=>'');
      await tgSend(chatId, `❌ Gemini HTTP *${res.status}*:\n${errMsg(body.slice(0,300))}`);
    }
  } catch(e) { await tgSend(chatId, `❌ Gemini error: ${errMsg(e)}`); }
}

// Session 28: every feature has a command, so the ☰ menu button (setChatMenuButton, commands) lists them all.
const OPS_CMDS=[{command:'menu',description:'Open the OPS menu'},{command:'keyboard',description:'Show the always-on button grid'},{command:'cassy',description:'Ask Cassy: /cassy who arrives this week?'},{command:'draft',description:'Draft a guest reply: /draft <what they wrote>'},{command:'stock',description:'Low-stock check'},{command:'inventory',description:'Full stock report'},{command:'notices',description:'Active brownouts, holidays, events, reminders'},{command:'brownout',description:'Add a brownout: /brownout <date> <time> <hours>'},{command:'deep',description:'Ask Cassy with the deeper model'}];
const FIN_CMDS=[{command:'menu',description:'Open the Finance menu'},{command:'keyboard',description:'Show the always-on button grid'},{command:'log',description:'Log an expense (guided)'},{command:'cassy',description:'Ask Cassy: /cassy what did we spend this month?'},{command:'draft',description:'Draft a guest reply: /draft <what they wrote>'},{command:'purchase',description:'Log a purchase from a receipt photo'},{command:'payclean',description:'Mark a cleaning fee paid'},{command:'summary',description:'Monthly finance summary'},{command:'stock',description:'Low-stock check'},{command:'inventory',description:'Full stock report'},{command:'count',description:'Update stock counts by group'},{command:'notices',description:'Active OPS notices'},{command:'refund',description:'Log guest refund: /refund REFCODE AMT RECIPIENT | REF | NOTE'},{command:'void',description:'Void entry: /void REFCODE'},{command:'status',description:'Bot & property status'},{command:'datahealth',description:'Data reconciliation health check'},{command:'deep',description:'Ask Cassy with the deeper model'},{command:'ping',description:'Diagnostic: test the model + env vars'}];

Deno.serve(withObservability({ functionName: 'telegram-expense', route: 'ops' }, async(req)=>{
  const url=new URL(req.url);
  if(req.method==='GET'&&url.searchParams.has('setup')){
    if(!TG_TOKEN)  return json({error:'TELEGRAM_BOT_TOKEN not set'},500);
    if(!TG_SECRET) return json({error:'TELEGRAM_WEBHOOK_SECRET not set'},500);
    if(url.searchParams.get('setup')!==TG_SECRET)return json({error:'setup secret mismatch'},401);
    const webhookUrl=`${SUPABASE_URL}/functions/v1/telegram-expense`;
    const[setWh,,cmdsOps,cmdsFin]=await Promise.all([fetch(`https://api.telegram.org/bot${TG_TOKEN}/setWebhook`,{method:'POST',headers:JSON_H,body:JSON.stringify({url:webhookUrl,secret_token:TG_SECRET,allowed_updates:['message','callback_query'],drop_pending_updates:true})}).then(r=>r.json()).catch(e=>({ok:false,error:String(e)})),fetch(`https://api.telegram.org/bot${TG_TOKEN}/getWebhookInfo`).then(r=>r.json()).catch(()=>null),tgCall('setMyCommands',{commands:OPS_CMDS,scope:{type:'all_group_chats'}}),FINANCE_CHAT?tgCall('setMyCommands',{commands:FIN_CMDS,scope:{type:'chat',chat_id:Number(FINANCE_CHAT)}}):null]);
    // session 28: the ☰ menu button beside the input box lists the commands (Hermis pattern), so a first-time member sees every feature.
    // Default only: setChatMenuButton with a chat_id accepts private chats alone (groups -> 400 invalid chat_id, live 2026-09-17).
    const menuBtn=await tgCall('setChatMenuButton',{menu_button:{type:'commands'}});
    return json({registered_to:webhookUrl,setWebhook:setWh,cmdsOps,cmdsFin,menuBtn});
  }
  if(req.method!=='POST')return json({error:'method_not_allowed'},405);
  const got=req.headers.get('X-Telegram-Bot-Api-Secret-Token')??'';
  if(!TG_SECRET||got!==TG_SECRET)return json({error:'unauthorized'},401);
  let update:any;try{update=await req.json();}catch{return ackTelegram();}
  const db=createClient(SUPABASE_URL,SERVICE_ROLE);
  const work=async()=>{
    try{
      if(await alreadyProcessed(db,update?.update_id))return;
      purgeProcessed(db);
      // Concierge handoff cards (2026-09-12): button taps `ch:...` and replies to a `#CH-` card
      // belong to messenger-concierge; forward the raw update there with the same webhook secret.
      const chReply=/#CH-[0-9a-f]{8}/.test(String(update?.message?.reply_to_message?.text??''));
      if((update.callback_query?.data??'').startsWith('ch:')||chReply){
        if(!isAllowedChat((update.callback_query?.message??update.message)?.chat?.id))return;
        await fetch(`${SUPABASE_URL}/functions/v1/messenger-concierge?ops=1`,{method:'POST',headers:{'Content-Type':'application/json','X-Telegram-Bot-Api-Secret-Token':TG_SECRET},body:JSON.stringify(update),signal:AbortSignal.timeout(20_000)}).catch(e=>console.error('concierge forward failed:',String(e)));
        return;
      }
      // Cassy (D-104, deploy 2, 2026-09-13): plain text addressed to "cassy" belongs to telegram-cassy,
      // forwarded raw with the same webhook secret. Replies to bot prompts stay here (expense flows).
      // Deploy 3: every bot-addressed free text goes to Cassy too, except commands, replies to the bot's
      // own prompts (expense/notice flows) and numeric fast entry ("500 supplies"), which stay here.
      {
        const m=update?.message; const t=String(m?.text??m?.caption??''); // v107: a photo captioned "cassy …" is a draft request (Telegram plan §3)
        // session 28: /cassy <q> and /draft <guest text> are the same requests as "cassy …" / "cassy reply: …"
        if(m&&typeof m.text==='string'&&/^\s*\/(cassy|draft)(@\w+)?\b/i.test(m.text)) m.text=m.text.replace(/^\s*\/cassy(@\w+)?\s*/i,'cassy ').replace(/^\s*\/draft(@\w+)?\s*/i,'cassy reply: ');
        const named=/^\s*@?cassy\b/i.test(String(m?.text??t))||/^\s*\/deep\b/i.test(t);
        let free=t&&!m?.from?.is_bot&&!m?.reply_to_message&&!t.trimStart().startsWith('/')&&!/^\s*[₱\d]/.test(stripBotMention(t.trim()))&&isBotAddressed(m);
        // SPEC-16: someone who is being asked a question is answering it (e.g. "Joy Dishwashing 89"), not asking Cassy.
        if(free&&await hasAwaiting(db,m?.chat?.id,m?.from?.id))free=false;
        if(named||free){
          if(!isAllowedChat(m?.chat?.id))return;
          await fetch(`${SUPABASE_URL}/functions/v1/telegram-cassy${named?'':'?any=1'}`,{method:'POST',headers:{'Content-Type':'application/json','X-Telegram-Bot-Api-Secret-Token':TG_SECRET},body:JSON.stringify(update),signal:AbortSignal.timeout(20_000)}).catch(e=>console.error('cassy forward failed:',String(e)));
          return;
        }
      }
      if(update.callback_query){const cq=update.callback_query;if(!isAllowedChat(cq.message?.chat?.id)){await tgAnswerCB(cq.id);return;}await handleCallbackQuery(cq,db);return;}
      const msg=update?.message;if(!msg)return;
      if(!isAllowedChat(msg.chat?.id))return;
      if(msg.from?.is_bot)return;
      if(Array.isArray(msg.photo)&&msg.photo.length) await handlePhotoMessage(msg,db);
      else if(msg.document)                           await handleDocumentMessage(msg,db);
      else                                            await handleTextMessage(msg,db);
    }catch(e){console.error('work() error:',String(e));}
  };
  // @ts-ignore EdgeRuntime provided by Supabase
  if(typeof EdgeRuntime!=='undefined'&&EdgeRuntime?.waitUntil)EdgeRuntime.waitUntil(work());else await work();
  return ackTelegram();
}));
