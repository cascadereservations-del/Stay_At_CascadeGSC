-- SPEC-06 section 4: the dedup column. Additive and nullable, so the only things worth asserting are
-- that it exists with the right type, that an existing row reads null, and that a write round-trips.
begin;
select plan(5);

select has_column('public','concierge_threads','last_mid','the dedup column exists');
select col_type_is('public','concierge_threads','last_mid','text','it is text, matching Meta mids');
select col_is_null('public','concierge_threads','last_mid','it is nullable, so existing threads are untouched');

insert into public.concierge_threads (psid, bot_turns, history, updated_at)
values ('probe:pgtap-last-mid', 0, '[]'::jsonb, now());
select is((select last_mid from public.concierge_threads where psid='probe:pgtap-last-mid'), null,
  'a thread created without one reads null, so the guard cannot fire on it');

update public.concierge_threads set last_mid='m_AAAA1234' where psid='probe:pgtap-last-mid';
select is((select last_mid from public.concierge_threads where psid='probe:pgtap-last-mid'), 'm_AAAA1234',
  'a mid round-trips');

select * from finish();
rollback;
