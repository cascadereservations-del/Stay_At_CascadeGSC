-- D-291 fix: the /guest pending kinds. The widened CHECK must accept guest_pick and guest_save, keep every existing kind,
-- and still refuse an unknown one.
begin;
select plan(5);

select ok((select pg_get_constraintdef(oid) like '%guest_pick%' and pg_get_constraintdef(oid) like '%guest_save%' from pg_constraint
            where conrelid = 'public.telegram_pending'::regclass and conname = 'telegram_pending_kind_check'),
  'the kind CHECK names guest_pick and guest_save');

select lives_ok($$insert into public.telegram_pending(chat_id,kind,payload)
  values (-900000003,'guest_pick','{"from_id":9000000003,"from_name":"zz-synthetic","file_id":"x","src_mid":1,"candidates":[]}'::jsonb)$$,
  'a guest_pick row is accepted');

select lives_ok($$insert into public.telegram_pending(chat_id,kind,payload)
  values (-900000003,'guest_save','{"from_id":9000000003,"guest_id":"00000000-0000-0000-0000-000000000000"}'::jsonb)$$,
  'a guest_save row is accepted');

select lives_ok($$insert into public.telegram_pending(chat_id,kind,payload)
  values (-900000003,'llm_house','{"topic":"zz-synthetic","title":"x","body":"x","tier":"staff","keywords":[],"retire":false,"by":"t"}'::jsonb)$$,
  'an existing kind (llm_house) is still accepted');

select throws_ok($$insert into public.telegram_pending(chat_id,kind,payload)
  values (-900000003,'no_such_kind','{}'::jsonb)$$,
  '23514', null, 'an unknown kind is still refused');

select * from finish();
rollback;
