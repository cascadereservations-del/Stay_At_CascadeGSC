-- P2 #12 — damaged/missing resolution columns
alter table inventory_items
  add column if not exists resolved_at timestamptz,
  add column if not exists resolution_note text;

-- P2 #11 — auto low-stock email throttle + P2 #10 — track last low set
insert into app_settings (key, value) values
  ('last_lowstock_email_at', 'null'::jsonb)
on conflict (key) do nothing;

-- P1 #7 — expose airbnb_ical_url as a writeable setting for anon (inventory app)
-- (already exists with value ""; the anon update policy already covers all non-hash keys)
;
