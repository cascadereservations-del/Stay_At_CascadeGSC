-- Session 67 (D-290): the first power-watch v2 run (2026-10-02 11:37Z) recorded the Oct 8 and Oct 15 brownout cards as
-- sent, but neither appeared in OPS. Re-queue both so the next run (every 15 min) sends them again with the new
-- delivery log (power_watch_tg: http, ok, message_id, chat_type, chat_tail). Blocks are untouched. Idempotent.
begin;

update public.app_settings
   set value = (value - 'cardAt') || jsonb_build_object('card', jsonb_build_object('kind', 'new')),
       updated_at = now()
 where key in ('power_watch_notice:2026-10-08', 'power_watch_notice:2026-10-15')
   and value->>'status' = 'active';

select key, value->'card' as card, value ? 'cardAt' as has_card_at
  from public.app_settings
 where key like 'power_watch_notice:%'
 order by key;

commit;
