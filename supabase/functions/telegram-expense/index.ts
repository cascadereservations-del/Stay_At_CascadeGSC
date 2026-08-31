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
//   Non-numeric-leading text goes straight to handleConversationalDispatch.
// v52 (session I): cleanpayinvoice callback — dashboard "Send Invoice" → OPS card → cleaner tap marks fee_paid_at + fee_acked_at.
//   Stray backslash in deployed v52 caused Deno compilation error; stub v53 was deployed as placeholder.
// v53 (2026-06-06): Stub replacement — deploys the fixed v52 source. Version strings updated in handleStatus and handlePing.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { withObservability } from '../_shared/observability.ts';

const SUPABASE_URL    = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE    = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const TG_TOKEN        = Deno.env.get('TELEGRAM_BOT_TOKEN') ?? '';
const FINANCE_CHAT    = Deno.env.get('TELEGRAM_FINANCE_CHAT_ID') ?? '';
const OPS_CHAT        = Deno.env.get('TELEGRAM_CHAT_ID') ?? '';
const GEMINI_KEY      = Deno.env.get('GEMINI_BOT_KEY') ?? Deno.env.get('GEMINI_API_KEY') ?? '';
const TG_SECRET       = Deno.env.get('TELEGRAM_WEBHOOK_SECRET') ?? '';
const BOT_USERNAME    = (Deno.env.get('TELEGRAM_BOT_USERNAME') ?? '').replace(/^@/,'').toLowerCase();
const WEATHER_KEY     = Deno.env.get('GOOGLE_WEATHER_API_KEY') ?? '';
const GEN_SAN_LAT     = 6.1164;
const GEN_SAN_LNG     = 125.1716;
const PROPERTY_ID     = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
const RECEIPTS_BUCKET = 'expense-receipts';
const GEMINI_MODEL    = 'gemini-2.5-flash';
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
function numberedList(items: LineItem[]) { return items.map((it,i)=>`\`${i+1}.\` ${mdEsc(it.name)} \u2014 \u20b1${peso(it.unit_price)}${it.qty>1?` \u00d7${it.qty}`:''}`).join('\n'); }
function parseNamePriceQty(tokens: string[]) {
  let qty=1,qtyExplicit=false; const kept:string[]=[];
  for (const t of tokens) { const mq=t.match(/^x(\d+)$/i)||t.match(/^(\d+)x$/i); if(mq){qty=Number(mq[1])||1;qtyExplicit=true;continue;} kept.push(t); }
  let price:number|null=null;
  if (kept.length) { const last=kept[kept.length-1].replace(/[\u20b1,]/g,''); if(/^\d+(\.\d{1,2})?$/.test(last)){price=Number(last);kept.pop();} }
  return {name:kept.join(' ').trim(),price,qty,qtyExplicit};
}
function extractMarkerTxn(prompt:string,marker:string) { const m=prompt.match(new RegExp('`'+marker+'\\|([^`]+)`')); return m?m[1]:null; }
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
async function handleBookingsQuery(db:any,chatId:any,surface:'ops'|'finance',params:any){
  const isFin=surface==='finance';const today=toManilaDate();const when=String(params?.when??'').toLowerCase();
  const cols='guest_name,checkin_date,checkout_date,checkin_time,checkout_time,nights,guest_count,status'+(isFin?',host_payout,payout_amount,payout_date':'');
  let ci=params?.checkin?validDate(params.checkin):null, co=params?.checkout?validDate(params.checkout):null;
  if(!ci&&when==='weekend'){const d=new Date(today+'T00:00:00Z');const sat=(6-d.getUTCDay()+7)%7;ci=addDaysStr(today,sat);co=addDaysStr(ci,2);}
  if(!ci&&when==='this_week'){ci=today;co=addDaysStr(today,7);}
  if(ci&&co){
    const{data}=await db.from('airbnb_reservations').select(cols).eq('property_id',PROPERTY_ID).neq('status','cancelled').lt('checkin_date',co).gt('checkout_date',ci).order('checkin_date');
    const rows=(data??[]) as any[];
    await tgSend(chatId,[`📅 *${ci} → ${co}*  ${rows.length?'🔴 Booked':'🟢 Open'}`,'',...rows.map(r=>bookingLine(r,isFin))].join('\n\n').trim());return;
  }
  if(when==='next'||when===''){
    const{data}=await db.from('airbnb_reservations').select(cols).eq('property_id',PROPERTY_ID).neq('status','cancelled').gte('checkin_date',today).order('checkin_date').limit(3);
    const rows=(data??[]) as any[];
    await tgSend(chatId,rows.length?['📅 *Upcoming Bookings*','',...rows.map(r=>bookingLine(r,isFin))].join('\n\n'):'📅 _No upcoming bookings._');return;
  }
  const dstr=when==='today'?today:when==='tomorrow'?addDaysStr(today,1):validDate(params?.when);
  if(dstr){
    const{data}=await db.from('airbnb_reservations').select(cols).eq('property_id',PROPERTY_ID).neq('status','cancelled').lte('checkin_date',dstr).gt('checkout_date',dstr).order('checkin_date');
    const rows=(data??[]) as any[];
    await tgSend(chatId,rows.length?[`📅 *Bookings — ${dstr}*`,'',...rows.map(r=>bookingLine(r,isFin))].join('\n\n'):`📅 _No one staying on ${dstr}._`);return;
  }
  const{data}=await db.from('airbnb_reservations').select(cols).eq('property_id',PROPERTY_ID).neq('status','cancelled').gte('checkin_date',today).order('checkin_date').limit(3);
  const rows=(data??[]) as any[];
  await tgSend(chatId,rows.length?['📅 *Upcoming Bookings*','',...rows.map(r=>bookingLine(r,isFin))].join('\n\n'):'📅 _No upcoming bookings._');
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
  const res=await geminiFetch(`https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent?key=${GEMINI_KEY}`,{method:'POST',headers:JSON_H,body:JSON.stringify({contents:[{parts:[{text:buildAdvisoryPrompt(toManilaDate())},{inline_data:{mime_type:mime,data:bytesToBase64(bytes)}}]}],generationConfig:{temperature:0,response_mime_type:'application/json'}}),signal:AbortSignal.timeout(55_000)});
  if(!res.ok)throw new Error(`gemini_${res.status}`);
  const data=await res.json();const txt=data?.candidates?.[0]?.content?.parts?.map((p:any)=>p.text).join('')??'';
  return JSON.parse(txt.replace(/^```json\s*|\s*```$/g,'').trim());
}
function advisoryOccLines(occ:any[]):string[]{
  return occ.map((o:any)=>{const t=o.start_time?` ${String(o.start_time).slice(0,5)}`:'';const tail=o.duration_hours?` (${o.duration_hours}h)`:(o.end_time?`–${String(o.end_time).slice(0,5)}`:'');return `⚡ ${o.date}${t}${tail}`;});
}
async function runAdvisoryOcr(db:any,chatId:any,bytes:Uint8Array,mime:string,from:any){
  if(!GEMINI_KEY){await tgSend(chatId,'⚠️ Advisory reading unavailable (GEMINI_BOT_KEY not set).');return;}
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
async function promptManualClean(chatId:any) {
  await tgSend(chatId,['\u270d\ufe0f *Manual cleaning fee*','Reply: `cleaner | date | amount | notes`','','e.g. `Honey | 05-28 | 500 | deep clean bonus`','_Date: today, yesterday, MM-DD or YYYY-MM-DD. Notes optional._','`MANUALCLEAN|`'].join('\n'),{reply_markup:{force_reply:true,input_field_placeholder:'Honey | 05-28 | 500 | notes'}});
}
async function handleManualCleanReply(db:any,chatId:any,msg:any,text:string) {
  const parts=text.split('|').map(s=>s.trim());
  const cleaner=parts[0]??'',dateTok=parts[1]??'',amtTok=(parts[2]??'').replace(/[\u20b1,]/g,''),notes=parts[3]??null;
  if(!cleaner||!dateTok||!amtTok){await tgReply(chatId,msg.message_id,'\u26a0\ufe0f Format: `cleaner | date | amount | notes`\ne.g. `Honey | 05-28 | 500 | deep clean`');return;}
  const amount=Number(amtTok);
  if(!isFinite(amount)||amount<=0){await tgReply(chatId,msg.message_id,'\u26a0\ufe0f Amount must be a number, e.g. `500`.');return;}
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
};
const TIP_BACK:Record<string,string>={fastentry:'log',ocr:'log',void:'commands'};

function mainMenuKb() { return {inline_keyboard:[[{text:'💰 Log Expense',callback_data:'menu:log'},{text:'🧹 Cleaning Fees',callback_data:'menu:cleaning'}],[{text:'📊 Reports',callback_data:'menu:commands'},{text:'📌 OPS Notices',callback_data:'menu:notices'}]]}; }
function opsMenuKb() { return {inline_keyboard:[[{text:'⚡ Brownout',callback_data:'menu:do:nt:brownout'},{text:'📅 Calendar',callback_data:'menu:do:cal'}],[{text:'🌦 Weather now',callback_data:'menu:do:weather'},{text:'🔄 Turnover',callback_data:'menu:do:schedule'}],[{text:'📋 View all notices',callback_data:'menu:do:notices'}]]}; }

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

// ═══════════════════════════════════════════════════════════════════════════
// v45 CONVERSATIONAL DISPATCH — Gemini native function calling + context snapshot
// ═══════════════════════════════════════════════════════════════════════════
const SHARED_TOOLS = [
  { name:'get_weather', description:'Get current weather and forecast for Cascade Hideaway, General Santos City. Call for any weather, temperature, rain, forecast, UV, or humidity question.', parameters:{type:'object',properties:{}} },
  { name:'query_bookings', description:'Check guest bookings, reservations, arrivals, departures. Call when asked who is staying, next guest, any booking on a date, availability, check-in/out schedule.', parameters:{type:'object',properties:{when:{type:'string',description:'today | tomorrow | this_week | weekend | next | YYYY-MM-DD — omit for next upcoming'},checkin:{type:'string',description:'Range start YYYY-MM-DD'},checkout:{type:'string',description:'Range end YYYY-MM-DD'}}} },
  { name:'query_stock', description:'Check inventory stock levels. Call when asked about supplies, what is low, stock counts, last purchase price of an item.', parameters:{type:'object',properties:{filter:{type:'string',description:'low (default) | all'},item:{type:'string',description:'Specific item name to look up'}}} },
  { name:'query_notices', description:'List upcoming scheduled notices. Call when asked about scheduled brownouts, holidays, calendar, events, reminders, or what is coming up.', parameters:{type:'object',properties:{notice_type:{type:'string',description:'brownout | holiday | event | reminder | calendar — omit for all'}}} },
  { name:'create_notice', description:'Save a new notice to the operations board. Call when user wants to post, save, or schedule a brownout, holiday, event, or reminder.', parameters:{type:'object',required:['notice_type','title','effective_date'],properties:{notice_type:{type:'string',enum:['brownout','holiday','event','reminder']},title:{type:'string',description:'Notice title / description'},effective_date:{type:'string',description:'Date YYYY-MM-DD'},effective_time:{type:'string',description:'Time HH:MM:00 (24h) — required for brownouts'},duration_hours:{type:'number',description:'Duration hours — for brownouts'}}} },
  { name:'get_help', description:'Show what the bot can do. Call when user asks for help, capabilities, commands, or "ano magagawa mo?".', parameters:{type:'object',properties:{}} },
];

const FINANCE_ONLY_TOOLS = [
  { name:'log_expense', description:'Record an expense or purchase in the ledger. Call when user describes spending money. Always call this — never just confirm in text.', parameters:{type:'object',required:['amount','category'],properties:{amount:{type:'number',description:'Amount in PHP'},category:{type:'string',enum:['supplies','utilities','cleaning','maintenance','repairs','platform_fees','other']},payee:{type:'string',description:'Vendor or store name'},memo:{type:'string',description:'Additional notes or description'}}} },
  { name:'query_expenses', description:'Query past expenses and spending totals. Call for spending history, monthly totals, category breakdowns, recent transactions.', parameters:{type:'object',properties:{period:{type:'string',enum:['this_month','last_month','recent'],description:'recent = last few transactions'},category:{type:'string',description:'Filter by expense category — omit for all'}}} },
  { name:'void_transaction', description:'Cancel, void, or delete expense transactions. Call for "cancel receipt", "void last upload", "discard expense", "tanggalin yung expense".', parameters:{type:'object',properties:{ref_code:{type:'string',description:'8-character transaction ref code'},recent_n:{type:'number',description:'Void last N transactions (max 5)'},status_filter:{type:'string',enum:['pending_review','confirmed']}}} },
  { name:'void_notice', description:'Cancel or remove a scheduled OPS notice. Call for "cancel the brownout", "remove the holiday notice", "delete that reminder".', parameters:{type:'object',properties:{search_title:{type:'string',description:'Partial title to search'},notice_type:{type:'string',description:'brownout | holiday | event | reminder'},effective_date:{type:'string',description:'YYYY-MM-DD to narrow search'}}} },
  { name:'edit_notice', description:'Update an existing scheduled notice. Call when user wants to change the date, time, duration, or title of a notice.', parameters:{type:'object',required:['search_title'],properties:{search_title:{type:'string'},changes:{type:'object',description:'Fields to update: title, effective_date, effective_time, duration_hours'}}} },
  { name:'get_status', description:'Get property and bot status: pending receipts, unpaid cleans, low stock, next checkout. Call for "status", "kumusta ang bot", "any pending items?".', parameters:{type:'object',properties:{}} },
  { name:'get_finance_summary', description:'Get monthly financial summary: income, expenses, net, category breakdown. Call for "how much did we spend", "finance report", "monthly summary".', parameters:{type:'object',properties:{period:{type:'string',enum:['this_month','last_month']}}} },
];

async function buildContextSnapshot(db:any, surface:'ops'|'finance'): Promise<string> {
  const today = toManilaDate();
  const isFin = surface === 'finance';
  const [bookings, notices, stock, pendingQ, recentQ] = await Promise.all([
    db.from('airbnb_reservations').select('guest_name,checkin_date,checkout_date,status').eq('property_id',PROPERTY_ID).neq('status','cancelled').gte('checkout_date',today).order('checkin_date').limit(5),
    db.from('ops_notices').select('notice_type,title,effective_date,effective_time,duration_hours').eq('property_id',PROPERTY_ID).eq('is_active',true).gte('effective_date',today).order('effective_date').limit(6),
    db.from('inventory_items').select('name,qty_on_hand,reorder_below,unit,unit_cost').eq('property_id',PROPERTY_ID).eq('is_active',true),
    isFin ? db.from('transactions').select('id',{count:'exact',head:true}).eq('property_id',PROPERTY_ID).eq('status','pending_review') : Promise.resolve({count:0}),
    isFin ? db.from('transactions').select('category,gross_amount,transaction_date,payee_name').eq('property_id',PROPERTY_ID).eq('txn_type','expense').eq('status','confirmed').order('created_at',{ascending:false}).limit(4) : Promise.resolve({data:[]}),
  ]);
  const now = new Date().toLocaleString('en-PH',{timeZone:'Asia/Manila',dateStyle:'medium',timeStyle:'short'});
  const lines:string[] = [`Now: ${now}`];
  const bRows = (bookings.data??[]) as any[];
  const active = bRows.filter((b:any)=>b.checkin_date<=today&&b.checkout_date>today);
  const upcoming = bRows.filter((b:any)=>b.checkin_date>today);
  lines.push(active.length?`Active guests: ${active.map((b:any)=>`${b.guest_name||'Guest'} (out ${b.checkout_date})`).join(', ')}`:'Active guests: None (property vacant)');
  if(upcoming.length) lines.push(`Upcoming: ${upcoming.slice(0,3).map((b:any)=>`${b.guest_name||'Guest'} ${b.checkin_date}→${b.checkout_date}`).join(' | ')}`);
  const sRows = (stock.data??[]) as any[];
  const low = sRows.filter((r:any)=>Number(r.qty_on_hand)<=Number(r.reorder_below));
  lines.push(low.length?`Low stock (${low.length}): ${low.map((r:any)=>`${r.name} ${r.qty_on_hand}${r.unit?' '+r.unit:''}${isFin&&Number(r.unit_cost)>0?' @₱'+r.unit_cost:''}`).join(', ')}`:'Stock: All above reorder levels');
  const nRows = (notices.data??[]) as any[];
  if(nRows.length) lines.push(`Notices: ${nRows.map((n:any)=>`[${n.notice_type}] ${n.effective_date}${n.effective_time?' '+String(n.effective_time).slice(0,5):''} — ${n.title}`).join(' | ')}`);
  else lines.push('Notices: None scheduled');
  if(isFin){
    const pc = (pendingQ as any).count??0;
    if(pc>0) lines.push(`Pending receipts: ${pc} awaiting review`);
    const rRows = (recentQ.data??[]) as any[];
    if(rRows.length) lines.push(`Recent expenses: ${rRows.map((e:any)=>`₱${e.gross_amount} ${e.category} ${e.transaction_date}`).join(' | ')}`);
  }
  return lines.join('\n');
}

function buildSystemPrompt(surface:'ops'|'finance', context:string, today:string, tomorrow:string): string {
  const surfaceRule = surface==='ops'
    ? 'SURFACE: OPS — You are talking to operational staff (may include cleaners). STRICT RULE: Never share financial figures — no peso amounts, no expense totals, no unit costs, no payout data. Only operational data (names, dates, stock quantities, notice schedules) is allowed.'
    : 'SURFACE: FINANCE — You are talking to admin (Lloyd or Marifel). All data including financial figures, expense totals, payouts, and unit costs is permitted.';
  return `You are the Cascade Hideaway operations assistant. You manage a boutique Airbnb at Block 47 Lot 39, Bria Homes, Brgy San Isidro, General Santos City, Philippines. Power: SOCOTECO II, Feeder 14-3, Leon Llido Substation.\n\n${surfaceRule}\n\nLIVE PROPERTY CONTEXT:\n${context}\n\nBEHAVIOR:\n- Respond in the user's language: English, Filipino/Tagalog, or Taglish — match their register\n- Be concise and warm. Mobile chat — keep responses short and scannable\n- If the context above already answers the question, respond directly WITHOUT calling a tool\n- Call tools for real-time detail, data entry, or actions the context doesn't cover\n- For casual conversation (greetings, thanks, general chat, unrelated questions) respond naturally — no tools needed\n- When logging expenses, creating notices, or voiding transactions: ALWAYS use the tool, never just confirm in text\n- Today: ${today}. Tomorrow: ${tomorrow}.`;
}

async function getChatHistory(db:any, chatId:string, limit=6): Promise<any[]> {
  try {
    const{data}=await db.from('telegram_chat_history').select('role,parts').eq('chat_id',chatId).order('created_at',{ascending:false}).limit(limit);
    return ((data??[]) as any[]).reverse();
  } catch { return []; }
}

async function saveChatHistory(db:any, chatId:string, turns:{role:string;parts:any[]}[]): Promise<void> {
  try {
    await db.from('telegram_chat_history').insert(turns.map(t=>({chat_id:chatId,role:t.role,parts:t.parts})));
    const{data:old}=await db.from('telegram_chat_history').select('id').eq('chat_id',chatId).order('created_at',{ascending:true});
    const rows=(old??[]) as any[];
    if(rows.length>12) await db.from('telegram_chat_history').delete().in('id',rows.slice(0,rows.length-12).map((r:any)=>r.id));
  } catch(e){ console.warn('saveChatHistory:',String(e)); }
}

async function callGeminiWithTools(systemPrompt:string, history:any[], userMessage:string, tools:any[]): Promise<{type:'text';text:string}|{type:'tool_call';name:string;args:any}|null> {
  if(!GEMINI_KEY) return null;
  const contents = userMessage ? [...history,{role:'user',parts:[{text:userMessage}]}] : history;
  const body:any = { system_instruction:{parts:[{text:systemPrompt}]}, contents, generationConfig:{temperature:0.4,maxOutputTokens:600} };
  if(tools.length){ body.tools=[{functionDeclarations:tools}]; body.tool_config={function_calling_config:{mode:'AUTO'}}; }
  try {
    const res=await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${DISPATCH_MODEL}:generateContent?key=${GEMINI_KEY}`,{method:'POST',headers:JSON_H,body:JSON.stringify(body),signal:AbortSignal.timeout(20_000)});
    if(!res.ok){console.warn('Gemini tools HTTP',res.status);return null;}
    const data=await res.json();
    const parts=data?.candidates?.[0]?.content?.parts??[];
    for(const p of parts){ if(p.functionCall) return{type:'tool_call',name:p.functionCall.name,args:p.functionCall.args??{}}; if(p.text?.trim()) return{type:'text',text:p.text.trim()}; }
    return null;
  } catch(e){console.warn('callGeminiWithTools:',String(e));return null;}
}

type ToolResult = {directResponse?:boolean;needsConfirmation?:boolean;confirmText?:string};

async function executeToolCall(db:any,chatId:any,from:any,toolName:string,args:any,surface:'ops'|'finance'): Promise<ToolResult> {
  switch(toolName) {
    case 'get_weather': await sendWeather(chatId); return{directResponse:true};
    case 'query_bookings': await handleBookingsQuery(db,chatId,surface,args); return{directResponse:true};
    case 'query_stock': await handleStockQuery(db,chatId,surface,args??{}); return{directResponse:true};
    case 'query_notices': {
      const nt=args?.notice_type;
      if(nt&&['brownout','holiday','event','reminder'].includes(nt)) await handleNoticesByType(chatId,db,nt);
      else if(nt==='calendar') await handleCalendarNotices(chatId,db);
      else await handleNoticesList(chatId,db);
      return{directResponse:true};
    }
    case 'create_notice': {
      if(!args.notice_type||!args.title||!args.effective_date){ await tgSend(chatId,'⚠️ Need notice type, title, and date. Try: /brownout tomorrow 8am 4h SOCOTECO maintenance'); return{directResponse:true}; }
      const pid=await createPending(db,chatId,'llm_notice',{params:args,from:{first_name:from?.first_name,username:from?.username,id:from?.id}});
      const icon=NOTICE_ICON[args.notice_type]??'📌';
      const ct=`${icon} Save ${args.notice_type} on ${args.effective_date}${args.effective_time?' at '+String(args.effective_time).slice(0,5):''}${args.duration_hours?' for '+args.duration_hours+'h':''} — ${mdEsc(args.title)}?`;
      await tgSend(chatId,ct,{reply_markup:{inline_keyboard:[[{text:'✅ Save it',callback_data:`llm_confirm:${pid}`},{text:'❌ Cancel',callback_data:`llm_cancel:${pid}`}]]}});
      return{needsConfirmation:true,confirmText:ct};
    }
    case 'get_help': await showCapabilities(chatId,surface); return{directResponse:true};
    case 'log_expense': {
      if(surface!=='finance') return{directResponse:true};
      const amount=Number(args.amount);
      if(!isFinite(amount)||amount<=0){await tgSend(chatId,'⚠️ Need a valid amount to log this expense.');return{directResponse:true};}
      const validCats=new Set(['supplies','utilities','cleaning','maintenance','repairs','platform_fees','other']);
      const cat=validCats.has(String(args.category))?String(args.category):'other';
      const label=await getCategoryLabel(db,cat);
      const payee=args.payee?String(args.payee).slice(0,200):null;
      const memo=args.memo?String(args.memo).slice(0,500):null;
      const loggedBy=whoFrom(from);
      const pid=await createPending(db,chatId,'llm_expense',{amount,category:cat,label,payee,notes:memo??payee,loggedBy});
      const ct=`🧾 ₱${peso(amount)} ${label}${payee?` — ${mdEsc(payee)}`:''}?`;
      await tgSend(chatId,ct,{reply_markup:{inline_keyboard:[[{text:'✅ Log it',callback_data:`llm_expense_confirm:${pid}`},{text:'❌ Cancel',callback_data:`llm_cancel:${pid}`}]]}});
      return{needsConfirmation:true,confirmText:ct};
    }
    case 'query_expenses': if(surface!=='finance') return{directResponse:true}; await handleLLMExpenseQuery(db,chatId,args??{}); return{directResponse:true};
    case 'get_finance_summary': if(surface!=='finance') return{directResponse:true}; await runSummary(db,chatId); return{directResponse:true};
    case 'void_transaction': if(surface!=='finance') return{directResponse:true}; await handleLLMVoidTransaction(db,chatId,args??{},''); return{needsConfirmation:true};
    case 'void_notice': await handleLLMNoticeVoid(db,chatId,args??{},''); return{needsConfirmation:true};
    case 'edit_notice': await handleLLMNoticeEdit(db,chatId,args??{},''); return{needsConfirmation:true};
    case 'get_status': if(surface!=='finance') return{directResponse:true}; await handleStatus(db,chatId); return{directResponse:true};
    default: console.warn('Unknown tool called:',toolName); return{directResponse:false};
  }
}

async function handleConversationalDispatch(db:any,chatId:any,from:any,userText:string,surface:'ops'|'finance'): Promise<boolean> {
  if(!GEMINI_KEY) return false;
  const today=toManilaDate();
  const tomorrow=addDaysStr(today,1);
  const safeText=userText.slice(0,600);
  const[context,history]=await Promise.all([buildContextSnapshot(db,surface).catch(()=>'Context unavailable'),getChatHistory(db,String(chatId))]);
  const systemPrompt=buildSystemPrompt(surface,context,today,tomorrow);
  const tools=surface==='finance'?[...SHARED_TOOLS,...FINANCE_ONLY_TOOLS]:SHARED_TOOLS;
  const result=await callGeminiWithTools(systemPrompt,history,safeText,tools);
  if(!result) return false;
  const userTurn={role:'user',parts:[{text:safeText}]};
  if(result.type==='text'){
    await tgSend(chatId,result.text);
    await saveChatHistory(db,String(chatId),[userTurn,{role:'model',parts:[{text:result.text}]}]);
    return true;
  }
  if(result.type==='tool_call'){
    const toolResult=await executeToolCall(db,chatId,from,result.name,result.args,surface);
    const modelToolTurn={role:'model',parts:[{functionCall:{name:result.name,args:result.args}}]};
    if(toolResult.directResponse){ await saveChatHistory(db,String(chatId),[userTurn,modelToolTurn]); return true; }
    if(toolResult.needsConfirmation){ const confirmText=toolResult.confirmText??`[${result.name} pending]`; await saveChatHistory(db,String(chatId),[userTurn,{role:'model',parts:[{text:confirmText}]}]); return true; }
    return true;
  }
  return false;
}

async function geminiFetch(url:string,init:RequestInit,tries=3):Promise<Response> {
  for(let i=0;i<tries;i++){const res=await fetch(url,init);if(res.ok||(res.status!==429&&res.status!==503))return res;if(i<tries-1)await new Promise(r=>setTimeout(r,800*(i+1)));}
  return fetch(url,init);
}
function buildGeminiPrompt(categoryHint:string) {
  const h=categoryHint?`The user already classified this as "${categoryHint}" — use that as category_hint unless clearly wrong.`:'Infer category_hint from the items.';
  return `You are a receipt data extractor for a Philippine boutique Airbnb expense ledger.\nReturn ONLY a JSON object with these exact keys:\n{"amount":number|null,"currency":"PHP","date":"YYYY-MM-DD"|null,"vendor":string|null,"category_hint":"supplies"|"utilities"|"cleaning"|"maintenance"|"repairs"|"platform_fees"|"other","line_items":[{"name":string,"qty":number,"unit_price":number}],"confidence":number}\n${h}\nRules: amount=total paid. qty=units bought (default 1), unit_price=price per unit. If unreadable set amount null and confidence<0.2. Never invent a vendor.`;
}
function parseGeminiResponse(raw:any,cat:string) { const txt=raw?.candidates?.[0]?.content?.parts?.map((p:any)=>p.text).join('')??'';try{return JSON.parse(txt.replace(/^```json\s*|\s*```$/g,'').trim());}catch{return{amount:null,currency:'PHP',date:null,vendor:null,category_hint:cat||'other',line_items:[],confidence:0};} }
async function geminiExtract(bytes:Uint8Array,mime:string,cat='') {
  const res=await geminiFetch(`https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent?key=${GEMINI_KEY}`,{method:'POST',headers:JSON_H,body:JSON.stringify({contents:[{parts:[{text:buildGeminiPrompt(cat)},{inline_data:{mime_type:mime,data:bytesToBase64(bytes)}}]}],generationConfig:{temperature:0,response_mime_type:'application/json'}}),signal:AbortSignal.timeout(55_000)});
  if(!res.ok)throw new Error(`gemini_${res.status}`);
  return parseGeminiResponse(await res.json(),cat);
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
function expensePromptText(slug:string,label:string,pre:number){const hint=pre>0?`Detected *₱${peso(pre)}* — confirm or type a different amount.`:'Type the amount, and optionally the vendor or notes.';return[`📂 *Category: ${label}*`,hint,`_e.g. \`1706\` or \`1706 SC Johnson Lazada\`_`,`\`EXPENSE|${slug}|${pre}\``].join('\n');}
function extractExpenseState(t:string){const m=t.match(/`EXPENSE\|([^|]+)\|(\d+(?:\.\d+)?)`/);return m?{slug:m[1],preAmount:Number(m[2])}:null;}
function editAmountPromptText(txnId:string){return[`✏️ *Enter the correct total:*`,`_e.g. \`1706\`_`,`\`EDIT_AMOUNT|${txnId}\``].join('\n');}
function extractEditAmountState(t:string){const m=t.match(/`EDIT_AMOUNT\|([^`]+)`/);return m?m[1]:null;}
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
async function createPending(db:any,chatId:any,kind:string,payload:Record<string,unknown>){const{data}=await db.from('telegram_pending').insert({chat_id:chatId,kind,payload}).select('id').single();return data?.id??'';}
async function consumePending(db:any,pid:string){const{data}=await db.from('telegram_pending').delete().eq('id',pid).select('payload,expires_at').maybeSingle();if(!data)return null;if(new Date(data.expires_at)<new Date())return null;return data.payload;}
function purgePending(db:any){db.from('telegram_pending').delete().lt('expires_at',new Date().toISOString()).then(()=>{}).catch(()=>{});}
async function checkRecentDuplicates(db:any,amount:number){const since=new Date(Date.now()-RECENT_DUP_DAYS*86_400_000).toISOString().slice(0,10);const{data}=await db.from('transactions').select('id,gross_amount,category,transaction_date,payee_name,status').eq('property_id',PROPERTY_ID).eq('gross_amount',amount).neq('status','void').gte('transaction_date',since).order('transaction_date',{ascending:false}).limit(5);return data??[];}
function confirmMsg(amount:number,label:string,payee:string|null,id:string){return[`✅ *Expense logged*`,`₱${peso(amount)}  ·  ${label}`,...(payee?[`   ${mdEsc(payee)}`]:[]),`_Ref: ${shortRef(id)}_`].join('\n');}
async function loadReceiptTxn(db:any,txnId:string):Promise<any|null>{const{data}=await db.from('transactions').select('id,gross_amount,category,payee_name,transaction_date,status,ocr_confidence,ocr_raw').eq('id',txnId).maybeSingle();if(!data||data.status!=='pending_review')return null;return data;}
async function persistItems(db:any,txnId:string,ocrRaw:any,items:LineItem[]){const raw=(ocrRaw&&typeof ocrRaw==='object')?{...ocrRaw}:{};raw.line_items=items;await db.from('transactions').update({ocr_raw:raw,updated_at:new Date().toISOString()}).eq('id',txnId);}
async function sendReceiptCard(db:any,chatId:any,txnId:string,note?:string){const txn=await loadReceiptTxn(db,txnId);if(!txn){await tgSend(chatId,'⏰ That receipt is no longer editable.');return;}const catLabel=await getCategoryLabel(db,txn.category);const card=renderReceiptCard(txn,catLabel);await tgSend(chatId,(note?note+'\n\n':'')+card.text,{reply_markup:card.reply_markup});}
async function promptEditItem(db:any,chatId:any,txnId:string){const txn=await loadReceiptTxn(db,txnId);if(!txn){await tgSend(chatId,'⏰ That receipt is no longer editable.');return;}const items=normalizeLineItems(txn.ocr_raw?.line_items);if(!items.length){await tgSend(chatId,'No items to edit yet. Tap ➕ Add item.');return;}await tgSend(chatId,['✏️ *Edit an item*',numberedList(items),'','Reply: `<#> <name> <price>`','e.g. `2 Mr Muscle Glass 250ml 216`',`\`EDIT_ITEM|${txnId}\``].join('\n'),{reply_markup:{force_reply:true,input_field_placeholder:'e.g. 2 Mr Muscle 216'}});}
async function promptAddItem(db:any,chatId:any,txnId:string){const txn=await loadReceiptTxn(db,txnId);if(!txn){await tgSend(chatId,'⏰ That receipt is no longer editable.');return;}await tgSend(chatId,['➕ *Add an item*','Reply: `<name> <price>`  (optional `x<qty>`)','e.g. `Joy Dishwashing Liquid 89`  or  `Tissue 45 x2`',`\`ADD_ITEM|${txnId}\``].join('\n'),{reply_markup:{force_reply:true,input_field_placeholder:'e.g. Joy Dishwashing 89'}});}
async function promptRemoveItem(db:any,chatId:any,txnId:string){const txn=await loadReceiptTxn(db,txnId);if(!txn){await tgSend(chatId,'⏰ That receipt is no longer editable.');return;}const items=normalizeLineItems(txn.ocr_raw?.line_items);if(!items.length){await tgSend(chatId,'No items to remove.');return;}await tgSend(chatId,['🗑️ *Remove an item*',numberedList(items),'','Reply with the item number to remove (e.g. `2`).',`\`REMOVE_ITEM|${txnId}\``].join('\n'),{reply_markup:{force_reply:true,input_field_placeholder:'e.g. 2'}});}
async function handleEditItemReply(db:any,chatId:any,msg:any,prompt:string,text:string){const txnId=extractMarkerTxn(prompt,'EDIT_ITEM');if(!txnId){await tgReply(chatId,msg.message_id,'⚠️ Session lost. Tap ✏️ Edit item again.');return;}const txn=await loadReceiptTxn(db,txnId);if(!txn){await tgReply(chatId,msg.message_id,'⏰ That receipt is no longer editable.');return;}const items=normalizeLineItems(txn.ocr_raw?.line_items);const tokens=text.trim().split(/\s+/);const idx=parseInt(tokens[0],10);if(!Number.isInteger(idx)||idx<1||idx>items.length){await tgReply(chatId,msg.message_id,`⚠️ Item number must be 1–${items.length}.`);return;}const parsed=parseNamePriceQty(tokens.slice(1));if(!parsed.name&&parsed.price===null&&!parsed.qtyExplicit){await tgReply(chatId,msg.message_id,'⚠️ Nothing to change.');return;}const it=items[idx-1];if(parsed.name)it.name=parsed.name;if(parsed.price!==null)it.unit_price=parsed.price;if(parsed.qtyExplicit)it.qty=parsed.qty;await persistItems(db,txnId,txn.ocr_raw,items);await sendReceiptCard(db,chatId,txnId,`✏️ Item ${idx} updated.`);}
async function handleAddItemReply(db:any,chatId:any,msg:any,prompt:string,text:string){const txnId=extractMarkerTxn(prompt,'ADD_ITEM');if(!txnId){await tgReply(chatId,msg.message_id,'⚠️ Session lost.');return;}const txn=await loadReceiptTxn(db,txnId);if(!txn){await tgReply(chatId,msg.message_id,'⏰ That receipt is no longer editable.');return;}const parsed=parseNamePriceQty(text.trim().split(/\s+/));if(!parsed.name){await tgReply(chatId,msg.message_id,'⚠️ Need an item name.');return;}const items=normalizeLineItems(txn.ocr_raw?.line_items);items.push({name:parsed.name,qty:parsed.qty,unit_price:parsed.price??0});await persistItems(db,txnId,txn.ocr_raw,items);await sendReceiptCard(db,chatId,txnId,`➕ Added "${parsed.name}".`);}
async function handleRemoveItemReply(db:any,chatId:any,msg:any,prompt:string,text:string){const txnId=extractMarkerTxn(prompt,'REMOVE_ITEM');if(!txnId){await tgReply(chatId,msg.message_id,'⚠️ Session lost.');return;}const txn=await loadReceiptTxn(db,txnId);if(!txn){await tgReply(chatId,msg.message_id,'⏰ That receipt is no longer editable.');return;}const items=normalizeLineItems(txn.ocr_raw?.line_items);const idx=parseInt(text.trim(),10);if(!Number.isInteger(idx)||idx<1||idx>items.length){await tgReply(chatId,msg.message_id,`⚠️ Item number must be 1–${items.length}.`);return;}const[removed]=items.splice(idx-1,1);await persistItems(db,txnId,txn.ocr_raw,items);await sendReceiptCard(db,chatId,txnId,`🗑️ Removed "${removed?.name??'item'}"`);}
async function maybeOfferInventorySync(db:any,chatId:any,txnId:string){const{data:txn}=await db.from('transactions').select('category,payee_name,transaction_date,ocr_raw').eq('id',txnId).maybeSingle();if(!txn||!STOCKABLE_CATS.has(txn.category))return;const rawItems=Array.isArray(txn.ocr_raw?.line_items)?txn.ocr_raw.line_items:[];if(!rawItems.length)return;const matched:any[]=[],unmatched:string[]=[];for(const it of rawItems){const name=(typeof it==='string'?it:String(it?.name??'')).trim();if(!name)continue;const qty=(typeof it==='object'&&Number(it?.qty)>0)?Number(it.qty):1;const unitPrice=(typeof it==='object'&&Number(it?.unit_price)>0)?Number(it.unit_price):null;const{data:m}=await db.rpc('match_inventory_item',{p_name:name,p_limit:1});const best=Array.isArray(m)&&m.length?m[0]:null;if(best)matched.push({item_id:best.id,item_name:best.name,qty,unit_price:unitPrice});else unmatched.push(name);}if(!matched.length)return;const pid=await createPending(db,chatId,'inventory_sync',{txnId,vendor:txn.payee_name??null,date:txn.transaction_date??null,items:matched});const lines=matched.map((m:any)=>`  • ${mdEsc(m.item_name)}  +${m.qty}`);const tail=unmatched.length?[``,`_Not tracked: ${mdEsc(unmatched.join(', '))}_`]:[];await tgSend(chatId,[`📦 *Update inventory?*`,`${matched.length} item(s) from this receipt match your stock:`,...lines,...tail].join('\n'),{reply_markup:invSyncKeyboard(pid)});}
async function runOcr(db:any,chatId:any,objectPath:string,bytes:Uint8Array,mime:string,loggedBy:string|null,notes:string|null,cat=''){if(!GEMINI_KEY){await tgSend(chatId,'⚠️ GEMINI_BOT_KEY not set. Tap a category:',{reply_markup:categoryKeyboard(0)});return;}let extracted:any;try{extracted=await geminiExtract(bytes,mime,cat);}catch(e){console.warn('OCR:',String(e));await tgSend(chatId,'🧾 Could not read receipt. Tap a category:',{reply_markup:categoryKeyboard(0)});return;}const cats=await getCategories(db);const validSlugs=new Set(cats.map(c=>c.slug));const rawCat=String(extracted.category_hint??'').toLowerCase().trim();const category=cat&&validSlugs.has(cat)?cat:(validSlugs.has(rawCat)?rawCat:'other');const catLabel=cats.find(c=>c.slug===category)?.label??category;const amount=Number(extracted.amount);const grossAmount=isFinite(amount)&&amount>0?amount:0;const confidence=clamp01(extracted.confidence);const txnDate=validDate(extracted.date);const vendor=extracted.vendor?String(extracted.vendor).slice(0,200):null;const itemsText=lineItemsToText(extracted.line_items);const noteParts=[notes,itemsText?`items: ${itemsText}`:null].filter(Boolean);const insertRow:Record<string,unknown>={property_id:PROPERTY_ID,txn_type:'expense',category,status:'pending_review',source:'ocr',gross_amount:grossAmount,payee_name:vendor,receipt_image_path:objectPath,ocr_confidence:confidence,ocr_raw:extracted,logged_by:loggedBy,notes:noteParts.length?noteParts.join(' | '):null};if(txnDate)insertRow.transaction_date=txnDate;const{data:row,error}=await db.from('transactions').insert(insertRow).select('id').single();if(error||!row){await tgSend(chatId,`⚠️ OCR save error: ${errMsg(error?.message)}`);return;}const txnId=row.id;const card=renderReceiptCard({id:txnId,gross_amount:grossAmount,payee_name:vendor,transaction_date:txnDate,ocr_confidence:confidence,ocr_raw:extracted},catLabel);await tgSend(chatId,card.text,{reply_markup:card.reply_markup});notifyOps(category,loggedBy,true);}
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

async function handleLLMVoidTransaction(db:any, chatId:any, params:any, confirmText:string) {
  const recentN = params?.recent_n ? Math.min(Number(params.recent_n)||1, 5) : null;
  const refCode = params?.ref_code ? String(params.ref_code).toUpperCase().slice(0,8) : null;
  const statusFilter = params?.status_filter ?? null;
  if (refCode) {
    const{data:rows}=await db.from('transactions').select('id,gross_amount,category,status').eq('property_id',PROPERTY_ID).ilike('id',`${refCode.toLowerCase()}%`).limit(1);
    const txn=rows?.[0];
    if(!txn){await tgSend(chatId,`⚠️ No transaction with ref \`${refCode}\`.`);return;}
    if(txn.status==='void'){await tgSend(chatId,`ℹ️ \`${refCode}\` is already void.`);return;}
    const pid=await createPending(db,chatId,'llm_void_txn',{txnId:txn.id,refCode,amount:txn.gross_amount,category:txn.category});
    const ct=confirmText||`🗑️ Void ₱${peso(txn.gross_amount)} ${txn.category}? Ref \`${refCode}\``;
    await tgSend(chatId,mdEsc(ct),{reply_markup:{inline_keyboard:[[{text:'✅ Void it',callback_data:`lvt_confirm:${pid}`},{text:'❌ Cancel',callback_data:`llm_cancel:${pid}`}]]}});
    return;
  }
  if (recentN) {
    let q=db.from('transactions').select('id,gross_amount,category,status,transaction_date,payee_name').eq('property_id',PROPERTY_ID).neq('status','void').order('created_at',{ascending:false}).limit(recentN);
    if(statusFilter) q=q.eq('status',statusFilter);
    const{data:rows}=await q;
    const txns=(rows??[]) as any[];
    if(!txns.length){await tgSend(chatId,`⚠️ No${statusFilter==='pending_review'?' pending':''} transactions found.`);return;}
    const lines=txns.map((t:any,i:number)=>`${i+1}. ₱${peso(t.gross_amount)} · ${mdEsc(t.category)}${t.payee_name?` · ${mdEsc(t.payee_name)}`:''} · \`${shortRef(t.id)}\``);
    const pid=await createPending(db,chatId,'llm_void_txns',{txnIds:txns.map((t:any)=>t.id),count:txns.length});
    const ct=confirmText||`🗑️ Void ${txns.length} transaction${txns.length!==1?'s':''}?`;
    await tgSend(chatId,[mdEsc(ct),...lines,'','_This cannot be undone._'].join('\n'),{reply_markup:{inline_keyboard:[[{text:`✅ Void ${txns.length}`,callback_data:`lvts_confirm:${pid}`},{text:'❌ Cancel',callback_data:`llm_cancel:${pid}`}]]}});
    return;
  }
  await tgSend(chatId,'⚠️ Tell me which to void — e.g. "void last 2 uploaded receipts" or use `/void REFCODE`.');
}

async function handleLLMNoticeVoid(db:any,chatId:any,params:any,_confirmText:string){
  const{data:rows}=await db.from('ops_notices').select('id,notice_type,title,effective_date').eq('property_id',PROPERTY_ID).eq('is_active',true).ilike('title',`%${String(params?.search_title??'').slice(0,60)}%`).limit(3);
  const notices=(rows??[]) as any[];
  if(!notices.length){await tgSend(chatId,'⚠️ No matching notice found.');return;}
  const n=notices[0];const icon=NOTICE_ICON[n.notice_type]??'📌';
  const pid=await createPending(db,chatId,'llm_void_notice',{noticeId:n.id});
  await tgSend(chatId,`${icon} Remove: *${mdEsc(n.title)}* on ${n.effective_date}?`,{reply_markup:{inline_keyboard:[[{text:'✅ Remove it',callback_data:`llm_void_confirm:${pid}`},{text:'❌ Cancel',callback_data:`llm_cancel:${pid}`}]]}});
}
async function handleLLMNoticeEdit(db:any,chatId:any,params:any,_confirmText:string){
  const{data:rows}=await db.from('ops_notices').select('id,notice_type,title,effective_date,effective_time,duration_hours').eq('property_id',PROPERTY_ID).eq('is_active',true).ilike('title',`%${String(params?.search_title??'').slice(0,60)}%`).limit(3);
  const notices=(rows??[]) as any[];
  if(!notices.length){await tgSend(chatId,'⚠️ No matching notice found.');return;}
  const n=notices[0];const icon=NOTICE_ICON[n.notice_type]??'📌';const ch=params?.changes??{};
  const pid=await createPending(db,chatId,'llm_edit_notice',{noticeId:n.id,changes:ch});
  const preview=Object.entries(ch).map(([k,v])=>`${k}: ${v}`).join(', ');
  await tgSend(chatId,`${icon} Update *${mdEsc(n.title)}*\n${preview}?`,{reply_markup:{inline_keyboard:[[{text:'✅ Update it',callback_data:`llm_edit_confirm:${pid}`},{text:'❌ Cancel',callback_data:`llm_cancel:${pid}`}]]}});
}
async function handleLLMExpenseQuery(db:any,chatId:any,params:any){
  const period=params?.period??'recent';const catFilter=params?.category??null;
  if(period==='this_month'||period==='last_month'){await runSummary(db,chatId);return;}
  let q=db.from('transactions').select('id,category,gross_amount,transaction_date,payee_name,status').eq('property_id',PROPERTY_ID).eq('txn_type','expense').neq('status','void').order('created_at',{ascending:false}).limit(8);
  if(catFilter)q=q.eq('category',catFilter);
  const{data:rows}=await q;
  const txns=(rows??[]) as any[];
  if(!txns.length){await tgSend(chatId,'No expenses found.');return;}
  const lines=txns.map((t:any)=>`• ₱${peso(t.gross_amount)} · ${mdEsc(t.category)}${t.payee_name?` · ${mdEsc(t.payee_name)}`:''} · ${t.transaction_date} (\`${shortRef(t.id)}\`)`);
  await tgSend(chatId,['📋 *Recent expenses*',''].concat(lines).join('\n'));
}

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
  await tgAnswerCB(cq.id);const firstLine=(cq.message?.text??'').split('\n')[0];

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
  if(data.startsWith('pcedit:')) {await tgSend(chatId,['✏️ *Enter the amount you paid for this clean:*','_e.g. `500`_',`\`PAYCLEAN_EDIT|${data.slice('pcedit:'.length)}\``].join('\n'),{reply_markup:{force_reply:true,input_field_placeholder:'e.g. 500'}});return;}
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
        case 'payclean':    if(isF)await payCleanList(db,chatId);break;
        case 'manualclean': if(isF)await promptManualClean(chatId);break;
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
  if(data.startsWith('cat:'))    {const[,slug,amtStr]=data.split(':');const pre=Number(amtStr)||0;const label=await getCategoryLabel(db,slug);await tgEdit(chatId,msgId,`🧾 *Log an Expense*\n✅ Category: *${label}*`);await tgSend(chatId,expensePromptText(slug,label,pre),{reply_markup:{force_reply:true,input_field_placeholder:pre>0?`${pre} or different amount`:'e.g. 1706 SC Johnson'}});return;}
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
  if(data.startsWith('ocr_edit:')) {await tgEdit(chatId,msgId,firstLine+'\n✏️ _Awaiting total…_');await tgSend(chatId,editAmountPromptText(data.slice('ocr_edit:'.length)),{reply_markup:{force_reply:true,input_field_placeholder:'e.g. 1706'}});return;}
  if(data.startsWith('ocr_void:')) {await db.from('transactions').update({status:'void',notes:'Discarded via Telegram',updated_at:new Date().toISOString()}).eq('id',data.slice('ocr_void:'.length));await tgEdit(chatId,msgId,firstLine+'\n❌ *Discarded*');return;}
  if(data.startsWith('item_edit:'))   {await promptEditItem(db,chatId,data.slice('item_edit:'.length));return;}
  if(data.startsWith('item_add:'))    {await promptAddItem(db,chatId,data.slice('item_add:'.length));return;}
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

async function handleTextMessage(msg:any,db:any){
  const chatId=msg.chat?.id;const from=msg.from??{};
  if(!isBotAddressed(msg))return;
  const text=stripBotMention(String(msg.text??'').trim());if(!text)return;
  const loggedBy=whoFrom(from);
  if(isFinanceChat(chatId)&&msg.reply_to_message?.text){
    const prompt=msg.reply_to_message.text;
    if(prompt.includes('`EDIT_ITEM|'))   {await handleEditItemReply(db,chatId,msg,prompt,text);return;}
    if(prompt.includes('`ADD_ITEM|'))    {await handleAddItemReply(db,chatId,msg,prompt,text);return;}
    if(prompt.includes('`REMOVE_ITEM|')) {await handleRemoveItemReply(db,chatId,msg,prompt,text);return;}
    if(prompt.includes('`MANUALCLEAN|')) {await handleManualCleanReply(db,chatId,msg,text);return;}
    if(prompt.includes('`PAYCLEAN_EDIT|')){
      const m=prompt.match(/`PAYCLEAN_EDIT\|([^`]+)`/);const sid=m?m[1]:null;
      if(!sid){await tgReply(chatId,msg.message_id,'⚠️ Session lost. Run /payclean again.');return;}
      const amount=Number(text.replace(/[\u20b1,]/g,''));
      if(!isFinite(amount)||amount<=0){await tgReply(chatId,msg.message_id,'⚠️ Invalid amount. Enter a number like `500`.');return;}
      const res=await bookCleaningFee(db,sid,amount,loggedBy);
      if(!res.ok){await tgReply(chatId,msg.message_id,`⚠️ Could not book: ${errMsg(res.error)}`);return;}
      if(res.already){await tgReply(chatId,msg.message_id,'ℹ️ That clean was already paid.');return;}
      await tgReply(chatId,msg.message_id,`✅ Paid *${mdEsc(res.cleaner??'cleaner')}* ₱${peso(amount)} for ${res.date}. Booked to ledger.`);return;
    }
    if(prompt.includes('`EXPENSE|')){
      const state=extractExpenseState(prompt);if(!state){await tgReply(chatId,msg.message_id,'⚠️ Session lost. Start again with /log.');return;}
      const tokens=text.split(/\s+/);const fc=tokens[0].replace(/[\u20b1,]/g,'');
      let amount:number|null=null;let vendorTokens=tokens;
      if(/^\d+(\.\d{1,2})?$/.test(fc)){amount=Number(fc);vendorTokens=tokens.slice(1);}else if(state.preAmount>0){amount=state.preAmount;}
      if(!amount||amount<=0){await tgReply(chatId,msg.message_id,'⚠️ I need a valid amount.');return;}
      const label=await getCategoryLabel(db,state.slug);const vendor=vendorTokens.join(' ').trim()||null;
      await validateAndInsert(db,chatId,{category:state.slug,amount,label,payee:vendor,notes:vendor,loggedBy});return;
    }
    if(prompt.includes('`EDIT_AMOUNT|')){
      const txnId=extractEditAmountState(prompt);if(!txnId){await tgReply(chatId,msg.message_id,'⚠️ Could not find transaction.');return;}
      const amount=Number(text.replace(/[\u20b1,]/g,''));if(!isFinite(amount)||amount<=0){await tgReply(chatId,msg.message_id,'⚠️ Invalid amount.');return;}
      await db.from('transactions').update({gross_amount:amount,updated_at:new Date().toISOString()}).eq('id',txnId);
      await sendReceiptCard(db,chatId,txnId,`💵 Total set to ₱${peso(amount)}.`);return;
    }
  }
  if(text.startsWith('/')){
    const[rawCmd,...args]=text.split(/\s+/);const cmd=rawCmd.toLowerCase().replace(/@.*$/,'');
    if(['/brownout','/holiday','/event','/reminder'].includes(cmd)){await handleOpsNoticeCommand(cmd.slice(1),args,chatId,from,db);return;}
    if(cmd==='/notices'){await handleNoticesList(chatId,db);return;}
    if(cmd==='/stock'){await handleStockQuery(db,chatId,isFinanceChat(chatId)?'finance':'ops',{filter:(args[0]??'').toLowerCase()==='all'?'all':'low'});return;}
    if(cmd==='/menu'||cmd==='/help'||cmd==='/start'){await showMenu(chatId);return;}
    if(!isFinanceChat(chatId))return;
    if(cmd==='/status')      {await handleStatus(db,chatId);return;}
    if(cmd==='/ping')        {await handlePing(chatId);return;}
    if(cmd==='/log')         {await tgSend(chatId,'🧾 *Log an Expense*\n\nSelect a category:',{reply_markup:categoryKeyboard(0)});return;}
    if(cmd==='/payclean')    {await payCleanList(db,chatId);return;}
    if(cmd==='/manualclean') {await promptManualClean(chatId);return;}
    if(cmd==='/notifyclean') {await notifyCleanAcks(db,chatId);return;}
    if(cmd==='/summary')     {await runSummary(db,chatId);return;}
    if(cmd==='/datahealth')  {await handleDataHealth(db,chatId);return;}
    if(cmd==='/refund')      {await handleRefundCommand(db,chatId,from,args);return;}
    if(cmd==='/void'){
      const refCode=(args[0]??'').toUpperCase();
      if(refCode.length!==8){await tgSend(chatId,'⚠️ Usage: `/void REFCODE` — e.g. `/void 5EB836FA`');return;}
      const{data:rows}=await db.from('transactions').select('id,gross_amount,category,status').eq('property_id',PROPERTY_ID).ilike('id',`${refCode.toLowerCase()}%`).limit(1);
      const txn=rows?.[0];if(!txn){await tgSend(chatId,`⚠️ No transaction with ref \`${refCode}\`.`);return;}
      if(txn.status==='void'){await tgSend(chatId,`ℹ️ \`${refCode}\` is already void.`);return;}
      await db.from('transactions').update({status:'void',notes:'Voided via /void',updated_at:new Date().toISOString()}).eq('id',txn.id);
      await tgSend(chatId,`✅ Ref \`${refCode}\` (₱${peso(txn.gross_amount)} · ${txn.category}) voided.`);return;
    }
    await showMenu(chatId);return;
  }

  if(!isFinanceChat(chatId)){
    const handled = await handleConversationalDispatch(db,chatId,from,text,'ops');
    if(!handled) await tgSend(chatId,'_Sorry, I couldn\'t connect to the AI right now. Tap /menu to use the command interface._');
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

  const dispatched = await handleConversationalDispatch(db,chatId,from,text,'finance').catch(()=>false);
  if(!dispatched){
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
  if(!isBotAddressed(msg))return;
  if(!isFinanceChat(cid)){
    const fid=largestPhotoId(msg);if(!fid)return;
    const pid=await createPending(db,cid,'advisory_scan',{file_id:fid,from:{first_name:msg.from?.first_name,username:msg.from?.username,id:msg.from?.id}});
    await tgSend(cid,'📸 Is this a *power advisory* to scan?\n_Regular photos (sharing, etc.) don\'t need scanning — just tap Ignore._',{reply_markup:{inline_keyboard:[[{text:'⚡ Scan advisory',callback_data:`adv_scan:${pid}`},{text:'❌ Ignore',callback_data:`adv_ignore:${pid}`}]]}});
    return;
  }
  const chatId=msg.chat?.id;const from=msg.from??{};const loggedBy=whoFrom(from);
  const guidedState=msg.reply_to_message?.text?extractExpenseState(msg.reply_to_message.text):null;
  const cat=guidedState?.slug??'';
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

const OPS_CMDS=[{command:'menu',description:'Open the OPS menu'},{command:'stock',description:'Low-stock check'}];
const FIN_CMDS=[{command:'menu',description:'Open the Finance menu'},{command:'void',description:'Void entry: /void REFCODE'},{command:'summary',description:'Monthly finance summary'},{command:'stock',description:'Low-stock check'},{command:'status',description:'Bot & property status'},{command:'datahealth',description:'Data reconciliation health check'},{command:'refund',description:'Log guest refund: /refund REFCODE AMT RECIPIENT | REF | NOTE'},{command:'ping',description:'Diagnostic: test Gemini + env vars'}];

Deno.serve(withObservability({ functionName: 'telegram-expense', route: 'ops' }, async(req)=>{
  const url=new URL(req.url);
  if(req.method==='GET'&&url.searchParams.has('setup')){
    if(!TG_TOKEN)  return json({error:'TELEGRAM_BOT_TOKEN not set'},500);
    if(!TG_SECRET) return json({error:'TELEGRAM_WEBHOOK_SECRET not set'},500);
    if(url.searchParams.get('setup')!==TG_SECRET)return json({error:'setup secret mismatch'},401);
    const webhookUrl=`${SUPABASE_URL}/functions/v1/telegram-expense`;
    const[setWh,,cmdsOps,cmdsFin]=await Promise.all([fetch(`https://api.telegram.org/bot${TG_TOKEN}/setWebhook`,{method:'POST',headers:JSON_H,body:JSON.stringify({url:webhookUrl,secret_token:TG_SECRET,allowed_updates:['message','callback_query'],drop_pending_updates:true})}).then(r=>r.json()).catch(e=>({ok:false,error:String(e)})),fetch(`https://api.telegram.org/bot${TG_TOKEN}/getWebhookInfo`).then(r=>r.json()).catch(()=>null),tgCall('setMyCommands',{commands:OPS_CMDS,scope:{type:'all_group_chats'}}),FINANCE_CHAT?tgCall('setMyCommands',{commands:FIN_CMDS,scope:{type:'chat',chat_id:Number(FINANCE_CHAT)}}):null]);
    return json({registered_to:webhookUrl,setWebhook:setWh,cmdsOps,cmdsFin});
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
