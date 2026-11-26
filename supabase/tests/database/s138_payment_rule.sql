-- s138 payment rule: 20261208000000 (rate card deposit_pct 50 -> 100) and 20261208000100 (house_facts PIN wording), with their rollbacks. Everything rolls back.
-- Fix round 1 (review F9, F10): the suite now RUNS the guard blocks and the update statements of both migrations and both rollbacks (verbatim copies held in the temp table
-- s138_sql; the release JSON pins the file hashes, so a file edited without this copy changing is caught at the restamp). It sets the live rows into each state it needs inside the
-- transaction (the property and the three house_facts topics exist from the migrations that seed them); on a database with no production rows the fixture block below supplies the property and one live rate version.
-- NOT RUN here (no database in the build session): run it on a rehearsal restore before release.
begin;
select plan(30);

-- Fixture for a database with no production rows (CI applies the migrations to an empty database, so the seed insert of 20260926020000_rate_card.sql is omitted there).
-- Runs only when the property has no live or scheduled rate version; on a production copy (one live row) it does nothing. Rolled back with the transaction.
do $f$
begin
  if not exists (select 1 from public.booking_rate_policy_versions
                  where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
                    and (effective_to is null or effective_to >= (now() at time zone 'Asia/Manila')::date)) then
    insert into public.properties(id, name, is_active) values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Synthetic s138 Property', true) on conflict (id) do nothing;
    insert into auth.users(id) values ('e2000000-0000-4000-8000-000000000138') on conflict (id) do nothing;
    insert into public.booking_rate_policy_versions (property_id, effective_from, effective_to, nightly_rate, currency, terms, approved_by, idempotency_key)
    values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '2025-01-01', null, 1780, 'PHP',
            '{"tiers":[{"min_nights":2,"pct":5}],"deposit_pct":50}'::jsonb,
            'e2000000-0000-4000-8000-000000000138', 'test:s138-payment-rule-fixture');
  end if;
end $f$;

create temp table s138_sql (name text primary key, body text not null) on commit drop;
insert into s138_sql values
('dep_guard', $t$
do $g$
declare n_open int; n_50 int; n_other int; n_bad int;
begin
  select count(*),
         count(*) filter (where pct = 50),
         count(*) filter (where pct is not null and pct not in (50, 100)),
         count(*) filter (where pct is null)
    into n_open, n_50, n_other, n_bad
    from (select case when terms -> 'deposit_pct' is null then 50
                      when jsonb_typeof(terms -> 'deposit_pct') = 'number' then (terms ->> 'deposit_pct')::numeric end as pct
            from public.booking_rate_policy_versions
           where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
             and (effective_to is null or effective_to >= (now() at time zone 'Asia/Manila')::date)) v;
  if n_open = 0 then
    raise exception 's138 deposit_pct: no live or scheduled rate version for the property' using errcode = '55000';
  end if;
  if n_bad > 0 then
    raise exception 's138 deposit_pct: % live/scheduled version(s) hold a deposit_pct that is not a number: fix the card by hand, then re-cut', n_bad using errcode = '55000';
  end if;
  if n_other > 0 then
    raise exception 's138 deposit_pct: % live/scheduled version(s) hold a deposit_pct other than 50 or 100: re-cut from the live card', n_other using errcode = '55000';
  end if;
  if n_50 = 0 then
    raise exception 's138 deposit_pct: already applied (no live/scheduled version holds 50)' using errcode = '55000';
  end if;
end $g$;
$t$),
('dep_update', $t$
update public.booking_rate_policy_versions
   set terms = jsonb_set(jsonb_set(terms, '{deposit_pct}', '100'::jsonb, true), '{s138_prev_deposit_pct}', '50'::jsonb, true)
 where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
   and (effective_to is null or effective_to >= (now() at time zone 'Asia/Manila')::date)
   and case when terms -> 'deposit_pct' is null then 50
            when jsonb_typeof(terms -> 'deposit_pct') = 'number' then (terms ->> 'deposit_pct')::numeric end = 50;
do $r$
begin
  if exists (select 1 from public.booking_rate_policy_versions
              where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
                and (effective_to is null or effective_to >= (now() at time zone 'Asia/Manila')::date)
                and coalesce(case when jsonb_typeof(terms -> 'deposit_pct') = 'number' then (terms ->> 'deposit_pct')::numeric end, -1) <> 100) then
    raise exception 's138 deposit_pct: read-back failed, a live or scheduled version is not at 100' using errcode = '55000';
  end if;
end $r$;
$t$),
('dep_rb_guard', $t$
do $g$
declare n_marked int; n_changed int;
begin
  select count(*),
         count(*) filter (where case when jsonb_typeof(terms -> 'deposit_pct') = 'number' and jsonb_typeof(terms -> 's138_prev_deposit_pct') = 'number'
                                     then (terms ->> 'deposit_pct')::numeric <> 100
                                     else true end)
    into n_marked, n_changed
    from public.booking_rate_policy_versions
   where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
     and terms ? 's138_prev_deposit_pct';
  if n_marked = 0 then
    raise exception 's138 deposit_pct rollback: no version carries the s138 marker, nothing to roll back' using errcode = '55000';
  end if;
  if n_changed > 0 then
    raise exception 's138 deposit_pct rollback: % marked version(s) were edited since (not a number, or no longer 100)', n_changed using errcode = '55000';
  end if;
end $g$;
$t$),
('dep_rb_update', $t$
update public.booking_rate_policy_versions
   set terms = jsonb_set(terms, '{deposit_pct}', terms -> 's138_prev_deposit_pct', true) - 's138_prev_deposit_pct'
 where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
   and terms ? 's138_prev_deposit_pct'
   and jsonb_typeof(terms -> 's138_prev_deposit_pct') = 'number';
$t$),
('hf_guard', $t$
do $g$
declare v_p text; v_s text; v_g text;
begin
  select body into v_p from public.house_facts where topic = 'smart-lock-prospect';
  select body into v_s from public.house_facts where topic = 'smart-lock-staff';
  select body into v_g from public.house_facts where topic = 'smart-lock';
  if v_p is null or v_s is null or v_g is null then
    raise exception 's138 house_facts: smart-lock-prospect, smart-lock-staff or smart-lock is missing' using errcode = '55000';
  end if;
  if v_p is distinct from 'Check-in is self-service by smart lock, so a late arrival is easy. Your personal door code is sent at least a day before arrival, once IDs and the balance are in, and the door locks itself behind you. Check-in opens at 2:00 PM.' then
    raise exception 's138 house_facts: smart-lock-prospect is not the seeded text (edited since): re-cut' using errcode = '55000';
  end if;
  if v_s is distinct from 'The lock is TTLock; guest codes are issued from the TTLock app by the host once IDs and the balance are in, at least 24 hours before arrival. The code itself is never written into Cassy or the manual.' then
    raise exception 's138 house_facts: smart-lock-staff is not the seeded text (edited since): re-cut' using errcode = '55000';
  end if;
  if v_g is distinct from 'Tap the keypad to wake it, enter your code and press #. The door locks itself when it closes, so pull it firmly shut whenever you leave. Your key card, kept with the remotes inside, also opens the door with a tap on the keypad. Your personal code reaches you at least a day before arrival, once your IDs and the balance are in. Should the keypad not respond, message us here or call {{ONGROUND}} and we will get you in.'
     and v_g is distinct from 'Tap the keypad to wake it, enter your code and press #. The door locks itself when it closes, so pull it firmly shut whenever you leave. Your key card, kept with the remotes on the wooden tray on the TV cabinet, also opens the door with a tap on the keypad. Your personal code reaches you at least a day before arrival, once your IDs and the balance are in. Should the keypad not respond, message us here or call {{ONGROUND}} and we will get you in.' then
    raise exception 's138 house_facts: smart-lock is neither the seeded text nor the seed with the remote-tray edit (edited since): re-cut' using errcode = '55000';
  end if;
end $g$;
$t$),
('hf_update', $t$
update public.house_facts
   set body = 'Check-in is self-service by smart lock, so a late arrival is easy. Your personal door code is sent at least a day before arrival, once your payment, your IDs and the PHP 800 refundable security deposit are in, and the door locks itself behind you. Check-in opens at 2:00 PM.',
       updated_by = 's138 pay-in-full', updated_at = now()
 where topic = 'smart-lock-prospect';
update public.house_facts
   set body = 'The lock is TTLock; guest codes are issued from the TTLock app by the host once the full payment, the IDs and the PHP 800 refundable security deposit are in, at least 24 hours before arrival. The code itself is never written into Cassy or the manual.',
       updated_by = 's138 pay-in-full', updated_at = now()
 where topic = 'smart-lock-staff';
update public.house_facts
   set body = replace(body, 'once your IDs and the balance are in.', 'once your payment, your IDs and the PHP 800 refundable security deposit are in.'),
       updated_by = 's138 pay-in-full', updated_at = now()
 where topic = 'smart-lock';
do $r$
begin
  if (select count(*) from public.house_facts where topic in ('smart-lock-prospect', 'smart-lock-staff', 'smart-lock') and body like '%PHP 800%' and body not like '%the balance%') <> 3 then
    raise exception 's138 house_facts: read-back failed' using errcode = '55000';
  end if;
end $r$;
$t$),
('hf_rb_guard', $t$
do $g$
declare v_p text; v_s text; v_g text;
begin
  select body into v_p from public.house_facts where topic = 'smart-lock-prospect';
  select body into v_s from public.house_facts where topic = 'smart-lock-staff';
  select body into v_g from public.house_facts where topic = 'smart-lock';
  if v_p is null or v_s is null or v_g is null then raise exception 's138 house_facts rollback: a row is missing' using errcode = '55000'; end if;
  if v_p not like '%PHP 800 refundable security deposit are in%' and v_p not like '%once IDs and the balance are in%' then
    raise exception 's138 house_facts rollback: smart-lock-prospect is neither this release nor the seed' using errcode = '55000';
  end if;
  if v_s not like '%PHP 800 refundable security deposit are in%' and v_s not like '%once IDs and the balance are in%' then
    raise exception 's138 house_facts rollback: smart-lock-staff is neither this release nor the seed' using errcode = '55000';
  end if;
  if v_g not like '%once your payment, your IDs and the PHP 800 refundable security deposit are in.%' and v_g not like '%once your IDs and the balance are in.%' then
    raise exception 's138 house_facts rollback: smart-lock is neither this release nor the seed wording' using errcode = '55000';
  end if;
end $g$;
$t$),
('hf_rb_update', $t$
update public.house_facts
   set body = $b$Check-in is self-service by smart lock, so a late arrival is easy. Your personal door code is sent at least a day before arrival, once IDs and the balance are in, and the door locks itself behind you. Check-in opens at 2:00 PM.$b$,
       updated_by = 'seed 2026-09-29', updated_at = now()
 where topic = 'smart-lock-prospect' and body like '%PHP 800%';
update public.house_facts
   set body = $b$The lock is TTLock; guest codes are issued from the TTLock app by the host once IDs and the balance are in, at least 24 hours before arrival. The code itself is never written into Cassy or the manual.$b$,
       updated_by = 'seed 2026-09-29', updated_at = now()
 where topic = 'smart-lock-staff' and body like '%PHP 800%';
update public.house_facts
   set body = replace(body, 'once your payment, your IDs and the PHP 800 refundable security deposit are in.', 'once your IDs and the balance are in.'),
       updated_by = 's138 rollback', updated_at = now()
 where topic = 'smart-lock' and body like '%once your payment, your IDs and the PHP 800 refundable security deposit are in.%';
$t$);

create temp table s138_past on commit drop as
  select id, terms from public.booking_rate_policy_versions
   where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_to < (now() at time zone 'Asia/Manila')::date;

-- ---- deposit_pct: guard, update, read-back ------------------------------------------------------------------------------------
select ok(exists (select 1 from public.booking_rate_policy_versions where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and (effective_to is null or effective_to >= (now() at time zone 'Asia/Manila')::date)),
  'precondition: the property has a live or scheduled rate version');
update public.booking_rate_policy_versions set terms = jsonb_set(terms, '{deposit_pct}', '50'::jsonb, true) - 's138_prev_deposit_pct'
 where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and (effective_to is null or effective_to >= (now() at time zone 'Asia/Manila')::date);

select lives_ok((select body from s138_sql where name = 'dep_guard'), 'guard passes when every live/scheduled version reads 50');
select lives_ok((select body from s138_sql where name = 'dep_update'), 'update and read-back run on the 50 state');
select is((select count(*)::int from public.booking_rate_policy_versions
            where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and (effective_to is null or effective_to >= (now() at time zone 'Asia/Manila')::date)
              and terms ->> 'deposit_pct' = '100' and terms ->> 's138_prev_deposit_pct' = '50'),
          (select count(*)::int from public.booking_rate_policy_versions
            where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and (effective_to is null or effective_to >= (now() at time zone 'Asia/Manila')::date)),
          'every live and scheduled version reads 100 and carries the 50 marker');
select is((select count(*)::int from s138_past p join public.booking_rate_policy_versions v using (id) where p.terms is distinct from v.terms), 0, 'past versions are untouched');
select throws_ok((select body from s138_sql where name = 'dep_guard'), '55000', null::text, 'guard stops a second run (55000)');
select throws_like((select body from s138_sql where name = 'dep_guard'), '%already applied%', 'the second-run stop says already applied');

-- a non numeric deposit_pct stops with the guard's message, not a cast error (review F9)
update public.booking_rate_policy_versions set terms = jsonb_set(terms, '{deposit_pct}', '"abc"'::jsonb, true)
 where id = (select id from public.booking_rate_policy_versions where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and (effective_to is null or effective_to >= (now() at time zone 'Asia/Manila')::date) order by id limit 1);
select throws_ok((select body from s138_sql where name = 'dep_guard'), '55000', null::text, 'a non numeric deposit_pct stops with 55000, not 22P02');
select throws_like((select body from s138_sql where name = 'dep_guard'), '%not a number%', 'the stop names the non numeric value');
-- an unexpected number stops
update public.booking_rate_policy_versions set terms = jsonb_set(terms, '{deposit_pct}', '30'::jsonb, true)
 where id = (select id from public.booking_rate_policy_versions where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and (effective_to is null or effective_to >= (now() at time zone 'Asia/Manila')::date) order by id limit 1);
select throws_like((select body from s138_sql where name = 'dep_guard'), '%other than 50 or 100%', 'a value of 30 stops the guard');

-- ---- deposit_pct rollback: only the marked rows come back, whatever their dates --------------------------------------------------
update public.booking_rate_policy_versions set terms = jsonb_set(terms, '{deposit_pct}', '50'::jsonb, true) - 's138_prev_deposit_pct'
 where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and (effective_to is null or effective_to >= (now() at time zone 'Asia/Manila')::date);
select lives_ok((select body from s138_sql where name = 'dep_update'), 're-run the migration on a clean 50 state');
select lives_ok((select body from s138_sql where name = 'dep_rb_guard'), 'rollback guard passes on the migrated rows');
select lives_ok((select body from s138_sql where name = 'dep_rb_update'), 'rollback update runs');
select is((select count(*)::int from public.booking_rate_policy_versions
            where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and terms ->> 'deposit_pct' = '50' and not (terms ? 's138_prev_deposit_pct')
              and (effective_to is null or effective_to >= (now() at time zone 'Asia/Manila')::date)),
          (select count(*)::int from public.booking_rate_policy_versions
            where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and (effective_to is null or effective_to >= (now() at time zone 'Asia/Manila')::date)),
          'rollback restores 50 on the marked rows and removes the marker');
-- a row that was already 100 before the migration (no marker) is not reverted, and with no marked row at all the rollback stops
update public.booking_rate_policy_versions set terms = jsonb_set(terms, '{deposit_pct}', '100'::jsonb, true)
 where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and (effective_to is null or effective_to >= (now() at time zone 'Asia/Manila')::date);
select throws_like((select body from s138_sql where name = 'dep_rb_guard'), '%nothing to roll back%', 'rows already at 100 with no marker are not rolled back (the rollback stops)');
update public.booking_rate_policy_versions set terms = jsonb_set(jsonb_set(terms, '{deposit_pct}', '30'::jsonb, true), '{s138_prev_deposit_pct}', '50'::jsonb, true)
 where id = (select id from public.booking_rate_policy_versions where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and (effective_to is null or effective_to >= (now() at time zone 'Asia/Manila')::date) order by id limit 1);
select throws_like((select body from s138_sql where name = 'dep_rb_guard'), '%edited since%', 'a marked row edited after the migration stops the rollback');

-- R2-7: a marked row edited to a string stops the rollback guard with 55000 (the CASE keeps the numeric cast off non numbers), not a cast error
update public.booking_rate_policy_versions set terms = jsonb_set(terms, '{deposit_pct}', '"abc"'::jsonb, true)
 where id = (select id from public.booking_rate_policy_versions where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and terms ? 's138_prev_deposit_pct' order by id limit 1);
select throws_ok((select body from s138_sql where name = 'dep_rb_guard'), '55000', null::text, 'a marked row edited to a string stops the rollback guard with 55000, not 22P02');
select throws_like((select body from s138_sql where name = 'dep_rb_guard'), '%edited since%', 'the rollback stop for a string value says edited since');

-- ---- house_facts: guard, update, read-back, rollback ------------------------------------------------------------------------------
select ok((select count(*) = 3 from public.house_facts where topic in ('smart-lock-prospect', 'smart-lock-staff', 'smart-lock')), 'precondition: the three smart-lock topics exist');
update public.house_facts set body = 'Check-in is self-service by smart lock, so a late arrival is easy. Your personal door code is sent at least a day before arrival, once IDs and the balance are in, and the door locks itself behind you. Check-in opens at 2:00 PM.' where topic = 'smart-lock-prospect';
update public.house_facts set body = 'The lock is TTLock; guest codes are issued from the TTLock app by the host once IDs and the balance are in, at least 24 hours before arrival. The code itself is never written into Cassy or the manual.' where topic = 'smart-lock-staff';
update public.house_facts set body = 'Tap the keypad to wake it, enter your code and press #. The door locks itself when it closes, so pull it firmly shut whenever you leave. Your key card, kept with the remotes on the wooden tray on the TV cabinet, also opens the door with a tap on the keypad. Your personal code reaches you at least a day before arrival, once your IDs and the balance are in. Should the keypad not respond, message us here or call {{ONGROUND}} and we will get you in.' where topic = 'smart-lock';
select lives_ok((select body from s138_sql where name = 'hf_guard'), 'guard passes on the seeded rows, smart-lock with the remote-tray edit');
update public.house_facts set body = 'Edited since the seed.' where topic = 'smart-lock';
select throws_like((select body from s138_sql where name = 'hf_guard'), '%smart-lock is neither the seeded text%', 'an edited smart-lock row stops the guard');
update public.house_facts set body = 'Tap the keypad to wake it, enter your code and press #. The door locks itself when it closes, so pull it firmly shut whenever you leave. Your key card, kept with the remotes on the wooden tray on the TV cabinet, also opens the door with a tap on the keypad. Your personal code reaches you at least a day before arrival, once your IDs and the balance are in. Should the keypad not respond, message us here or call {{ONGROUND}} and we will get you in.' where topic = 'smart-lock';
select lives_ok((select body from s138_sql where name = 'hf_update'), 'update and read-back run; all three rows name the PHP 800 deposit and no balance');
select ok((select body like '%wooden tray on the TV cabinet%' and body like '%{{ONGROUND}} and we will get you in.' from public.house_facts where topic = 'smart-lock'), 'smart-lock keeps the tray edit and the rest of its text');
-- R2-8: the rollback guard and the three restores (the copies are the rollback file's own statements)
select lives_ok((select body from s138_sql where name = 'hf_rb_guard'), 'rollback guard passes on the rows this release wrote');
update public.house_facts set body = 'Edited after the release.' where topic = 'smart-lock-prospect';
select throws_like((select body from s138_sql where name = 'hf_rb_guard'), '%smart-lock-prospect is neither this release nor the seed%', 'an edited smart-lock-prospect row stops the rollback guard');
update public.house_facts set body = 'Check-in is self-service by smart lock, so a late arrival is easy. Your personal door code is sent at least a day before arrival, once your payment, your IDs and the PHP 800 refundable security deposit are in, and the door locks itself behind you. Check-in opens at 2:00 PM.' where topic = 'smart-lock-prospect';
select lives_ok((select body from s138_sql where name = 'hf_rb_update'), 'rollback of the three rows runs');
select ok((select body like '%once your IDs and the balance are in.%' and body like '%wooden tray on the TV cabinet%' from public.house_facts where topic = 'smart-lock'), 'rollback reverses only the one smart-lock sentence');
select is((select body || '|' || updated_by from public.house_facts where topic = 'smart-lock-prospect'),
  'Check-in is self-service by smart lock, so a late arrival is easy. Your personal door code is sent at least a day before arrival, once IDs and the balance are in, and the door locks itself behind you. Check-in opens at 2:00 PM.|seed 2026-09-29', 'rollback restores the seeded smart-lock-prospect body and updated_by');
select is((select body || '|' || updated_by from public.house_facts where topic = 'smart-lock-staff'),
  'The lock is TTLock; guest codes are issued from the TTLock app by the host once IDs and the balance are in, at least 24 hours before arrival. The code itself is never written into Cassy or the manual.|seed 2026-09-29', 'rollback restores the seeded smart-lock-staff body and updated_by');
update public.house_facts set body = 'Edited after the rollback.' where topic = 'smart-lock';
select throws_like((select body from s138_sql where name = 'hf_rb_guard'), '%smart-lock is neither this release nor the seed wording%', 'an edited smart-lock row stops the rollback guard');

select * from finish();
rollback;
