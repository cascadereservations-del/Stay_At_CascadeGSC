-- Compensating rollback for release retire_rate_orphans_20260927: the two retired app_settings rows, as they stood
-- (nightly_rate_php 1780, deposit_percent 50, read 2026-09-27). Nothing reads them; this only restores the rows.
begin;
insert into public.app_settings (key, value) values
  ('nightly_rate_php', to_jsonb(1780)),
  ('deposit_percent', to_jsonb(50))
on conflict (key) do nothing;
commit;
