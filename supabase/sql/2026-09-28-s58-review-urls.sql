-- 2026-09-28 (session 58): fill the two empty review links message 5.2 (after_departure) reads. Both verified live in the
-- in-app browser 2026-09-28: the Facebook page's Reviews tab is on (1 review), and the Google listing "Cascade Hideaway"
-- (Homestay, 5.0) shows "Write a review" - its short link is the one the guide and vault already use.
-- Guarded: only the two keys, only while still empty; anything unexpected rolls everything back.
-- Run with scripts/migrations/run-sql-on-host.sh from stay-site.
begin;
do $$
declare n integer;
begin
  update public.app_settings set value = to_jsonb('https://www.facebook.com/CascadesHideaway/reviews/'::text)
   where key = 'review_facebook_url' and value = to_jsonb(''::text);
  get diagnostics n = row_count; if n <> 1 then raise exception 'review_facebook_url not empty or missing (%); nothing changed', n; end if;
  update public.app_settings set value = to_jsonb('https://maps.app.goo.gl/9vn8KyDwNrXPmJqT9'::text)
   where key = 'review_google_url' and value = to_jsonb(''::text);
  get diagnostics n = row_count; if n <> 1 then raise exception 'review_google_url not empty or missing (%); nothing changed', n; end if;
end $$;
commit;
-- Forward checks (all true):
-- select value #>> '{}' = 'https://www.facebook.com/CascadesHideaway/reviews/' from public.app_settings where key = 'review_facebook_url';
-- select value #>> '{}' = 'https://maps.app.goo.gl/9vn8KyDwNrXPmJqT9' from public.app_settings where key = 'review_google_url';
