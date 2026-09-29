-- D-282: the 'llm_house' pending kind (Cassy's teach card). The widened CHECK must accept it, keep every existing kind,
-- and still refuse an unknown one.
begin;
select plan(4);

select ok((select pg_get_constraintdef(oid) like '%llm_house%' from pg_constraint
            where conrelid = 'public.telegram_pending'::regclass and conname = 'telegram_pending_kind_check'),
  'the kind CHECK names llm_house');

select lives_ok($$insert into public.telegram_pending(chat_id,kind,payload)
  values (-900000002,'llm_house','{"topic":"zz-synthetic","title":"x","body":"x","tier":"staff","keywords":[],"retire":false,"by":"t"}'::jsonb)$$,
  'an llm_house row is accepted');

select lives_ok($$insert into public.telegram_pending(chat_id,kind,payload)
  values (-900000002,'awaiting_reply','{"flow":"count_qty","from_id":9000000002}'::jsonb)$$,
  'an existing kind (awaiting_reply) is still accepted');

select throws_ok($$insert into public.telegram_pending(chat_id,kind,payload)
  values (-900000002,'no_such_kind','{}'::jsonb)$$,
  '23514', null, 'an unknown kind is still refused');

select * from finish();
rollback;
