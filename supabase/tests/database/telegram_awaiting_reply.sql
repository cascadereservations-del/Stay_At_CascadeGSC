-- SPEC-16: the 'awaiting_reply' pending kind. The widened CHECK must accept the new kind, keep every
-- existing one, and still refuse an unknown kind.
begin;
select plan(5);

select ok((select pg_get_constraintdef(oid) like '%awaiting_reply%' from pg_constraint
            where conrelid = 'public.telegram_pending'::regclass and conname = 'telegram_pending_kind_check'),
  'the kind CHECK names awaiting_reply');

select lives_ok($$insert into public.telegram_pending(chat_id,kind,payload)
  values (-900000001,'awaiting_reply','{"flow":"count_qty","from_id":9000000001}'::jsonb)$$,
  'an awaiting_reply row is accepted');

select lives_ok($$insert into public.telegram_pending(chat_id,kind,payload)
  values (-900000001,'inventory_count','{"items":[]}'::jsonb)$$,
  'an existing kind (inventory_count) is still accepted');

select throws_ok($$insert into public.telegram_pending(chat_id,kind,payload)
  values (-900000001,'no_such_kind','{}'::jsonb)$$,
  '23514', null, 'an unknown kind is still refused');

-- The bot finds a person's open question by chat, kind and payload->>from_id.
select is((select payload->>'flow' from public.telegram_pending
            where chat_id=-900000001 and kind='awaiting_reply' and payload->>'from_id'='9000000001'),
  'count_qty', 'an open question is found by chat and person');

select * from finish();
rollback;
