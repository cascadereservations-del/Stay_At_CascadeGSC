// deno test supabase/functions/_shared/cascade-core/house.test.ts
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { fillPlaceholders, houseBlock, matchHouse, teachArgs, type HouseRow } from './house.ts';

// Keywords as seeded (stay-site 20260929010000_house_facts.sql).
const R = (topic: string, tier: HouseRow['tier'], keywords: string[]): HouseRow => ({ topic, title: topic, body: `${topic} body`, keywords, tier });
const ROWS: HouseRow[] = [
  R('wifi', 'guest', ['wifi', 'wi-fi', 'password', 'ssid', 'wifi password', 'wi-fi password', 'network name', 'wifi name', 'qr card']),
  R('wifi-name', 'public', ['wifi', 'wi-fi', 'internet', 'wifi speed', 'internet speed', 'work from home', 'video call', 'zoom', 'remote work', 'fast internet', 'fibre', 'fiber']),
  R('aircon', 'public', ['aircon', 'ac', 'air con', 'remote', 'cold', 'temperature', 'malamig']),
  R('tv', 'public', ['tv', 'netflix', 'remote', 'viu']),
  R('smart-lock', 'guest', ['door code', 'passcode', 'pin code', 'keypad', 'smart lock', 'unlock', 'open the door', 'pinto']),
  R('smart-lock-prospect', 'public', ['self check-in', 'self check in', 'late arrival', 'keyless', 'smart lock', 'door lock']),
  R('key-card', 'guest', ['key card', 'keycard', 'lanyard', 'keychain', 'remotes', 'lost card', 'lost key', 'replacement card']),
  R('parking', 'public', ['parking', 'car', 'security', 'guard']),
  R('address-staff', 'staff', ['address', 'block', 'lot', 'location', 'exact address']),
];

Deno.test('a prospect asking "is there wifi?" is answered from the public row, not locked', () => {
  const m = matchHouse(ROWS, 'Hi, is there wifi and parking?', 'public');
  assertEquals(m.locked, null);
  assert(m.rows.some((r) => r.topic === 'wifi-name'));
  assert(!m.rows.some((r) => r.tier !== 'public'));
});

Deno.test('the wifi password is locked for an unverified reader and answered once verified', () => {
  assertEquals(matchHouse(ROWS, "What's the wifi password?", 'public').locked?.topic, 'wifi');
  const v = matchHouse(ROWS, "What's the wifi password?", 'guest');
  assertEquals(v.locked, null);
  assertEquals(v.rows[0].topic, 'wifi');
});

Deno.test('the aircon remote is public: a prospect gets it', () => {
  const m = matchHouse(ROWS, 'how do we use the aircon remote?', 'public');
  assertEquals(m.locked, null);
  assertEquals(m.rows[0].topic, 'aircon');
});

Deno.test('whole words only, multiword phrases match, and common words do not lock', () => {
  assertEquals(matchHouse(ROWS, 'what is the nearest place to eat?', 'public').rows.length, 0); // "ac" is not in "place"
  assertEquals(matchHouse(ROWS, 'Can you send the pin location and a promo code?', 'public').locked, null);
  assertEquals(matchHouse(ROWS, 'what is the door code', 'public').locked?.topic, 'smart-lock');
  assertEquals(matchHouse(ROWS, 'how does the smart lock work?', 'public').locked, null); // tie -> the prospect row
});

Deno.test('staff rows never reach Messenger; Telegram reads every tier', () => {
  assertEquals(matchHouse(ROWS, 'what is the exact address, block and lot?', 'guest').rows.length, 0);
  assertEquals(matchHouse(ROWS, 'what is the exact address, block and lot?', 'guest').locked, null);
  assertEquals(matchHouse(ROWS, 'exact address', 'staff').rows[0].topic, 'address-staff');
});

Deno.test('placeholders fill from app_settings, with a safe wording when a value is missing', () => {
  const s = [{ key: 'wifi_ssid', value: 'NetA' }, { key: 'wifi_password', value: 'pw1' }, { key: 'onground_name', value: 'Honey' }, { key: 'onground_phone', value: '0991 853 8269' }];
  assertEquals(fillPlaceholders('{{WIFI_SSID}} / {{WIFI_PASSWORD}} / call {{ONGROUND}}', s), 'NetA / pw1 / call Honey (0991 853 8269)');
  assertEquals(fillPlaceholders('password {{WIFI_PASSWORD}}', []), 'password on the card in the unit');
  assert(!fillPlaceholders('{{ONGROUND}}', []).includes('{{'));
});

Deno.test('the HOUSE block says so when nothing matched', () => {
  assert(houseBlock([]).startsWith('HOUSE: none'));
  assert(houseBlock([ROWS[2]]).includes('- aircon: aircon body'));
});

Deno.test('teach: the slug is cleaned, an unknown tier falls to staff, keywords default from the title', () => {
  const t = teachArgs({ topic: 'Aircon Cleaning Supplier', title: 'Aircon cleaning service', body: 'Call us.', tier: 'secret' }, 'Lloyd');
  assert(!('error' in t));
  if (!('error' in t)) { assertEquals(t.topic, 'aircon-cleaning-supplier'); assertEquals(t.tier, 'staff'); assertEquals(t.keywords, ['aircon', 'cleaning', 'service']); }
  assertEquals(teachArgs({ topic: 'x1', title: 'X' }, 'L'), { error: 'need body' });
  assert(!('error' in teachArgs({ topic: 'wifi', title: 'Wi-Fi', retire: true }, 'L')));
});
