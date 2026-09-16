-- Session 27 (2026-09-17): Honey's second turnover of 16 Sep (session fe81722c, Queenie Gonzales)
-- stored electric_prev / water_prev = 0 because the checklist loaded "previous" before her first
-- submission (13:01 UTC, James Rebaya: 3899 kWh / 73.516 m3) had landed. The readings she typed
-- (3914 / 73.714) are right; only the previous side and the derived deltas are wrong, and the
-- 3914 kWh "delta" tripped the utility-anomaly card. nights_stayed = 1, so per-night = delta.
begin;
update public.meter_readings
   set electric_prev  = 3899,
       electric_delta = 3914 - 3899,
       kwh_per_night  = 3914 - 3899,
       water_prev     = 73.516,
       water_delta    = round(73.714 - 73.516, 4),
       m3_per_night   = round(73.714 - 73.516, 4)
 where id = '43706dc8-6992-4fd9-ae74-7b140dfa6b8d'
   and electric_prev = 0 and water_prev = 0;
commit;
-- forward check (expect 3899 / 3914 / 15 / 73.516 / 73.714 / 0.198)
select electric_prev, electric_curr, electric_delta, water_prev, water_curr, water_delta, kwh_per_night, m3_per_night
  from public.meter_readings where id = '43706dc8-6992-4fd9-ae74-7b140dfa6b8d';
