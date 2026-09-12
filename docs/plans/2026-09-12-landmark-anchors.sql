-- Landmark anchors for the concierge (D-072). The pois table feeds the guide's map AND, since
-- 2026-09-12, the concierge's LANDMARKS block. These rows add the big anchors guests actually ask
-- about; distances match the published FACTS. Hospitals are deliberately NOT included: their
-- distances have not been measured yet - add them from Google Maps (unit -> hospital, driving)
-- before the bot may quote them. Idempotent: skips names that already exist.
-- lat/lng are NOT NULL in pois. The guide's map is a template literal in index.html and does
-- not read this table, so these pins are only reference points for the concierge; S&R and
-- Robinsons come from the guide's own links, the rest are Google Maps approximations (+/- 200 m).
begin;
insert into public.pois (name, category, lat, lng, distance_km, distance_text, note, is_active, sort_order, property_id)
select v.name, v.category, v.lat, v.lng, v.distance_km, v.distance_text, v.note, true, 900 + row_number() over (), (select property_id from public.pois where property_id is not null limit 1)
from (values
  ('SM City General Santos',        'mall',      6.1161400, 125.1811400, 4.1,  '4.1 km', 'about 8-15 min by car or Grab'),
  ('KCC Mall of Gensan / Veranza',  'mall',      6.1126400, 125.1726500, 4.2,  '4.2 km', 'about 12 min by car or Grab'),
  ('Robinsons Place GenSan',        'mall',      6.1215935, 125.1906922, 3.7,  '3.7 km', 'about 10 min by car or Grab'),
  ('S&R Membership Shopping',       'mall',      6.1199805, 125.1851099, 4.5,  '4.5 km', 'about 10-15 min'),
  ('General Santos City Airport',   'transport', 6.1058300, 125.2352800, 15.0, '15 km',  'about 25-35 min by car depending on traffic'),
  ('GenSan Fish Port Complex',      'landmark',  6.0917000, 125.2044000, null, null,     'about 30-40 min by car; best at 5-9 AM'),
  ('Bria Homes main gate',          'landmark',  6.1525000, 125.1830000, 0.3,  '300 m',  'tricycles wait outside the gate')
) as v(name, category, lat, lng, distance_km, distance_text, note)
where not exists (select 1 from public.pois p where lower(p.name) = lower(v.name));
commit;
