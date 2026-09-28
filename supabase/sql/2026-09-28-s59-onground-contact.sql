-- 2026-09-28 (session 59): the on-ground contact guests are given (Lloyd: "the number provided is the number of the on
-- ground partner - Honey which should also be an editable option in the dashboard ... sync across all").
-- (1) Seed app_settings onground_name / onground_phone - the one source contact.ts (waves 18a7a13) reads for FACTS, the
--     door-ask line, the scheduled guest messages and Cassy. Public on purpose: the number is on the Facebook page and in
--     the confirmation e-mail, and the welcome guide reads it with the anon key.
-- (2) fn_direct_booking_cascade's confirmEmail payload gains 'onground_phone' read at send time, so the relay's e-mail
--     footer can follow the dashboard. A guarded in-place replace of the live definition (md5-pinned, one anchor), so
--     nothing else in the function is retyped. CREATE OR REPLACE keeps owner, grants and SECURITY DEFINER.
-- Guarded: rows only if absent; the function only if unchanged since 2026-09-28. Anything unexpected rolls back.
-- Run with scripts/migrations/run-sql-on-host.sh from stay-site.
begin;
do $$
declare
  n integer;
  d text := pg_get_functiondef('public.fn_direct_booking_cascade'::regproc);
  anchor constant text := $a$'receipt_url', coalesce(v_bk.receipt_image_path, '')$a$;
begin
  insert into public.app_settings (key, value) values
    ('onground_name',  to_jsonb('Honey'::text)),
    ('onground_phone', to_jsonb('0991 853 8269'::text))
  on conflict (key) do nothing;
  get diagnostics n = row_count; if n <> 2 then raise exception 'onground rows already present (% inserted); nothing changed', n; end if;

  if md5(d) <> '3f9bedef6ebe558de60ae2d0d57a8a6d' then raise exception 'fn_direct_booking_cascade changed since 2026-09-28; nothing changed'; end if;
  if (length(d) - length(replace(d, anchor, ''))) / length(anchor) <> 1 then raise exception 'anchor not found exactly once; nothing changed'; end if;
  execute replace(d, anchor, anchor || $b$,
                         'onground_phone', coalesce((select value #>> '{}' from public.app_settings where key = 'onground_phone'), '0991 853 8269')$b$);
end $$;
commit;
-- Forward checks (all true):
-- select value #>> '{}' = 'Honey' from public.app_settings where key = 'onground_name';
-- select value #>> '{}' = '0991 853 8269' from public.app_settings where key = 'onground_phone';
-- select position('onground_phone' in pg_get_functiondef('public.fn_direct_booking_cascade'::regproc)) > 0;
