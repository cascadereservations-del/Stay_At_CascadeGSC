-- 20261119000000_s119_staying.sql
-- Session 119, lane Q (SQL): release s119_staying_20261119. "Who is staying" on the Staff Today card (spec Cascade/docs/s118/SPEC-staying-facts.md).
-- (1) public.stay_staying: one row per stay, keyed (property_id, stay_uid) where stay_uid = calendar_events.uid. names (<= 300 chars, trimmed, nullable),
--     source in (admin, staff), suggestion + suggestion_at + suggestion_status (pending / dismissed) filled only by Cassy, version, updated_by, updated_at.
--     public.stay_staying_history keeps before/after per change (like guest_companion_history) and the idempotency key of the write. RLS on, no grants to anyone:
--     every read and write goes through the functions below.
-- (2) set_stay_staying_v1: a person types the names. Gate: current_staff_authorized('submit_cleaning', property) = owner, admin, inspector, cleaner (the roles on
--     site; finance, laundry and maintenance read the names but cannot type them). source 'admin' needs manage_operations (owner/admin), 'staff' is open to the gate.
--     Why not manage_operations (save_guest_companion_v1's gate): that is owner/admin only and cleaners must be able to type who arrived. No other staff write on the
--     guest card exists yet, so submit_cleaning is the narrowest existing permission that covers the people at the door. Stay must exist (confirmed) in calendar_events.
--     Optimistic lock: expected version must equal the stored one (0 = no row yet), else 40001. Idempotency: a key is required; the same key with the same names
--     returns the first result (replay), the same key with other names is 22023. Typing names clears a pending suggestion (a blank save does not). Names with a phone, e-mail or money amount are refused (names_contact, 22023).
-- (3) confirm_stay_staying_suggestion_v1: a person accepts (suggestion becomes names, source by role) or rejects (status dismissed). Never automatic.
-- (4) set_stay_staying_suggestion_v1: Cassy only (service_role). Writes suggestion fields only, never names; refuses while names are set; one pending per stay
--     (a newer suggestion replaces the pending one); the same text the person dismissed is not offered again.
-- (5) staff_home_v1: current_guest and next_guest gain `staying` {names, source, version[, suggestion]} (suggestion only for the same roles that can type).
--     Cut by patching the LIVE body (pg_get_functiondef, each anchor must occur exactly once) after an md5 guard: the s91 body, md5 fdacbd271486a3b71e11818dc691cda4
--     (read live 2026-11-18). The diff is the two `|| jsonb_build_object('staying', ...)` lines and nothing else.
-- Guards (md5 of prosrc, CR stripped, else 55000, nothing changes): staff_home_v1, staff_current_next_stays_v1 and staff_guest_card_v1 are the bodies this was cut from.
-- Everything below the guards is single shot. To undo apply supabase/rollbacks/20261119_s119_staying.sql (DATA LOSS by design: every typed name).

begin;

do $$
declare v_got text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.staff_home_v1(uuid)');
  if v_got is distinct from 'fdacbd271486a3b71e11818dc691cda4' then
    raise exception 's119 staying: staff_home_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', v_got using errcode = '55000';
  end if;
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.staff_current_next_stays_v1(uuid)');
  if v_got is distinct from '080806f4343f6df3a195b0dd2c5e8681' then
    raise exception 's119 staying: staff_current_next_stays_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', v_got using errcode = '55000';
  end if;
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.staff_guest_card_v1(uuid,uuid,date)');
  if v_got is distinct from '8b40e8c8533f8c8960094365aba034ac' then
    raise exception 's119 staying: staff_guest_card_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', v_got using errcode = '55000';
  end if;
end $$;

-- 1. tables ---------------------------------------------------------------------------------------------------------------------------------
create table public.stay_staying (
  property_id uuid not null references public.properties(id) on delete cascade,
  stay_uid text not null check (btrim(stay_uid) <> ''),
  names text check (names is null or (names = btrim(names, E' \t\r\n') and char_length(names) between 1 and 300)),
  source text check (source in ('admin', 'staff')),
  suggestion text check (suggestion is null or (suggestion = btrim(suggestion, E' \t\r\n') and char_length(suggestion) between 1 and 300)),
  suggestion_at timestamptz,
  suggestion_status text check (suggestion_status in ('pending', 'dismissed')),
  version integer not null default 1,
  updated_by uuid,
  updated_at timestamptz not null default now(),
  primary key (property_id, stay_uid),
  constraint stay_staying_names_source check ((names is null) = (source is null)),
  constraint stay_staying_suggestion_shape check ((suggestion is null) = (suggestion_status is null) and (suggestion is null) = (suggestion_at is null))
);
comment on table public.stay_staying is 'S119: who is staying, per stay (calendar_events.uid). names are typed by a person (source admin/staff); Cassy only fills suggestion, a person confirms it. No direct grants: use set_stay_staying_v1 / confirm_stay_staying_suggestion_v1 / set_stay_staying_suggestion_v1.';

create table public.stay_staying_history (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null,
  stay_uid text not null,
  action text not null check (action in ('set', 'accept', 'reject', 'suggest')),
  before_state jsonb,
  after_state jsonb,
  changed_by uuid,
  reason text,
  idempotency_key text,
  changed_at timestamptz not null default now()
);
create unique index stay_staying_history_key_uq on public.stay_staying_history (property_id, stay_uid, idempotency_key) where idempotency_key is not null;
create index stay_staying_history_stay_idx on public.stay_staying_history (property_id, stay_uid, changed_at);

alter table public.stay_staying enable row level security;
alter table public.stay_staying_history enable row level security;
revoke all on public.stay_staying, public.stay_staying_history from public, anon, authenticated, service_role;

-- 2. person types the names -----------------------------------------------------------------------------------------------------------------
create or replace function public.set_stay_staying_v1(p_property uuid, p_uid text, p_names text, p_source text, p_expected_version integer, p_reason text, p_idempotency_key text)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_names text := nullif(btrim(p_names, E' \t\r\n'), '');
  v_key text := btrim(p_idempotency_key);
  v_row public.stay_staying%rowtype;
  v_before jsonb;
  v_hist public.stay_staying_history%rowtype;
begin
  if auth.uid() is null or p_property is null or not public.current_staff_authorized('submit_cleaning', p_property) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_source is null or p_source not in ('admin', 'staff') then raise exception 'source_invalid' using errcode = '22023'; end if;
  if p_source = 'admin' and not public.current_staff_authorized('manage_operations', p_property) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_uid is null or btrim(p_uid) = '' then raise exception 'uid_required' using errcode = '22023'; end if;
  if v_key is null or v_key = '' or char_length(v_key) > 100 then raise exception 'idempotency_key_invalid' using errcode = '22023'; end if;
  if v_names is not null and char_length(v_names) > 300 then raise exception 'names_too_long' using errcode = '22023'; end if;
  -- D-289: staff never see a phone, e-mail or money; refuse it at write rather than store a redacted version.
  if v_names is not null and public.staff_redact_v1(v_names) is distinct from v_names then raise exception 'names_contact' using errcode = '22023'; end if;
  if p_reason is not null and char_length(p_reason) > 500 then raise exception 'reason_too_long' using errcode = '22023'; end if;
  if not exists (select 1 from public.calendar_events e where e.property_id = p_property and e.uid = p_uid and e.status = 'confirmed') then
    raise exception 'stay_not_found' using errcode = 'P0002';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_property::text || '/' || p_uid, 0));

  select * into v_hist from public.stay_staying_history h where h.property_id = p_property and h.stay_uid = p_uid and h.idempotency_key = v_key;
  if found then
    if v_hist.after_state ->> 'names' is distinct from v_names then
      raise exception 'idempotency_key_reused' using errcode = '22023';
    end if;
    return jsonb_build_object('ok', true, 'replay', true, 'version', (v_hist.after_state ->> 'version')::integer,
                              'names', v_hist.after_state ->> 'names', 'source', v_hist.after_state ->> 'source');
  end if;

  select * into v_row from public.stay_staying s where s.property_id = p_property and s.stay_uid = p_uid for update;
  if coalesce(p_expected_version, -1) <> case when found then v_row.version else 0 end then
    raise exception 'stale version: the names changed since they were loaded' using errcode = '40001';
  end if;

  if v_row.stay_uid is null then
    v_before := null;
    insert into public.stay_staying(property_id, stay_uid, names, source, version, updated_by)
    values (p_property, p_uid, v_names, case when v_names is null then null else p_source end, 1, auth.uid())
    returning * into v_row;
  else
    v_before := to_jsonb(v_row);
    update public.stay_staying set
      names = v_names,
      source = case when v_names is null then null else p_source end,
      -- typing names settles a pending suggestion (a blank save does not); a dismissed one stays so Cassy does not offer the same text again.
      suggestion = case when v_names is not null and suggestion_status = 'pending' then null else suggestion end,
      suggestion_at = case when v_names is not null and suggestion_status = 'pending' then null else suggestion_at end,
      suggestion_status = case when v_names is not null and suggestion_status = 'pending' then null else suggestion_status end,
      version = version + 1, updated_by = auth.uid(), updated_at = now()
    where property_id = p_property and stay_uid = p_uid
    returning * into v_row;
  end if;
  insert into public.stay_staying_history(property_id, stay_uid, action, before_state, after_state, changed_by, reason, idempotency_key)
  values (p_property, p_uid, 'set', v_before, to_jsonb(v_row), auth.uid(), p_reason, v_key);
  return jsonb_build_object('ok', true, 'replay', false, 'version', v_row.version, 'names', v_row.names, 'source', v_row.source);
end $$;
revoke all on function public.set_stay_staying_v1(uuid, text, text, text, integer, text, text) from public, anon, service_role;
grant execute on function public.set_stay_staying_v1(uuid, text, text, text, integer, text, text) to authenticated;

-- 3. person accepts or rejects Cassy's suggestion ---------------------------------------------------------------------------------------------
create or replace function public.confirm_stay_staying_suggestion_v1(p_property uuid, p_uid text, p_accept boolean, p_expected_version integer, p_reason text)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_row public.stay_staying%rowtype;
  v_before jsonb;
begin
  if auth.uid() is null or p_property is null or not public.current_staff_authorized('submit_cleaning', p_property) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_uid is null or btrim(p_uid) = '' then raise exception 'uid_required' using errcode = '22023'; end if;
  if p_accept is null then raise exception 'accept_required' using errcode = '22023'; end if;
  if p_reason is not null and char_length(p_reason) > 500 then raise exception 'reason_too_long' using errcode = '22023'; end if;

  perform pg_advisory_xact_lock(hashtextextended(p_property::text || '/' || p_uid, 0));
  select * into v_row from public.stay_staying s where s.property_id = p_property and s.stay_uid = p_uid for update;
  if not found or v_row.suggestion_status is distinct from 'pending' then
    -- nothing to confirm: hand back the current state so the app can reconcile (v_row is all null when there is no row).
    return jsonb_build_object('ok', false, 'error', 'no_pending_suggestion', 'names', public.staff_redact_v1(v_row.names), 'version', coalesce(v_row.version, 0));
  end if;
  if p_expected_version is distinct from v_row.version then
    raise exception 'stale version: the suggestion changed since it was loaded' using errcode = '40001';
  end if;
  v_before := to_jsonb(v_row);
  if p_accept then
    update public.stay_staying set
      names = suggestion,
      source = case when public.current_staff_authorized('manage_operations', p_property) then 'admin' else 'staff' end,
      suggestion = null, suggestion_at = null, suggestion_status = null,
      version = version + 1, updated_by = auth.uid(), updated_at = now()
    where property_id = p_property and stay_uid = p_uid returning * into v_row;
  else
    update public.stay_staying set suggestion_status = 'dismissed', version = version + 1, updated_by = auth.uid(), updated_at = now()
    where property_id = p_property and stay_uid = p_uid returning * into v_row;
  end if;
  insert into public.stay_staying_history(property_id, stay_uid, action, before_state, after_state, changed_by, reason)
  values (p_property, p_uid, case when p_accept then 'accept' else 'reject' end, v_before, to_jsonb(v_row), auth.uid(), p_reason);
  return jsonb_build_object('ok', true, 'accepted', p_accept, 'version', v_row.version, 'names', v_row.names, 'source', v_row.source);
end $$;
revoke all on function public.confirm_stay_staying_suggestion_v1(uuid, text, boolean, integer, text) from public, anon, service_role;
grant execute on function public.confirm_stay_staying_suggestion_v1(uuid, text, boolean, integer, text) to authenticated;

-- 4. Cassy suggests (service_role only; never touches names) ----------------------------------------------------------------------------------
create or replace function public.set_stay_staying_suggestion_v1(p_property uuid, p_uid text, p_suggestion text)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_sug text := nullif(btrim(p_suggestion, E' \t\r\n'), '');
  v_row public.stay_staying%rowtype;
  v_before jsonb;
begin
  if p_property is null or p_uid is null or btrim(p_uid) = '' then raise exception 'uid_required' using errcode = '22023'; end if;
  if v_sug is null or char_length(v_sug) > 300 then raise exception 'suggestion_invalid' using errcode = '22023'; end if;
  if public.staff_redact_v1(v_sug) is distinct from v_sug then return jsonb_build_object('ok', false, 'error', 'contact'); end if;
  if not exists (select 1 from public.calendar_events e where e.property_id = p_property and e.uid = p_uid and e.status = 'confirmed') then
    return jsonb_build_object('ok', false, 'error', 'stay_not_found');
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_property::text || '/' || p_uid, 0));
  select * into v_row from public.stay_staying s where s.property_id = p_property and s.stay_uid = p_uid for update;
  if found then
    if v_row.names is not null then return jsonb_build_object('ok', false, 'error', 'names_set'); end if;
    if v_row.suggestion_status = 'dismissed' and lower(v_row.suggestion) = lower(v_sug) then return jsonb_build_object('ok', false, 'error', 'dismissed'); end if;
    if v_row.suggestion_status = 'pending' and v_row.suggestion = v_sug then
      return jsonb_build_object('ok', true, 'unchanged', true, 'version', v_row.version);
    end if;
    v_before := to_jsonb(v_row);
    update public.stay_staying set suggestion = v_sug, suggestion_at = now(), suggestion_status = 'pending', version = version + 1, updated_at = now()
    where property_id = p_property and stay_uid = p_uid returning * into v_row;
  else
    insert into public.stay_staying(property_id, stay_uid, suggestion, suggestion_at, suggestion_status, version)
    values (p_property, p_uid, v_sug, now(), 'pending', 1) returning * into v_row;
  end if;
  insert into public.stay_staying_history(property_id, stay_uid, action, before_state, after_state, reason)
  values (p_property, p_uid, 'suggest', v_before, to_jsonb(v_row), 'cassy suggestion');
  return jsonb_build_object('ok', true, 'unchanged', false, 'version', v_row.version);
end $$;
revoke all on function public.set_stay_staying_suggestion_v1(uuid, text, text) from public, anon, authenticated;
grant execute on function public.set_stay_staying_suggestion_v1(uuid, text, text) to service_role;

-- 5. staff_home_v1: `staying` on the current and next guest -------------------------------------------------------------------------------------
-- helper: the object staff_home_v1 embeds; names and suggestion pass through staff_redact_v1 like every free text staff read (D-289). The suggestion key exists only for the roles that can type names and only while it is pending.
-- Not granted to any API role: staff_home_v1 (security definer, same owner) is the only caller.
create or replace function public.stay_staying_json_v1(p_property uuid, p_uid text)
returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('names', public.staff_redact_v1(s.names), 'source', s.source, 'version', coalesce(s.version, 0))
         || case when public.current_staff_authorized('submit_cleaning', p_property)
                 then jsonb_build_object('suggestion', case when s.suggestion_status = 'pending' then public.staff_redact_v1(s.suggestion) end)
                 else '{}'::jsonb end
    from (select 1) o
    left join public.stay_staying s on s.property_id = p_property and s.stay_uid = p_uid;
$$;
revoke all on function public.stay_staying_json_v1(uuid, text) from public, anon, authenticated, service_role;

do $$
declare v_def text; v_a text; v_to text; v_slot text; v_var text; v_got text;
begin
  v_def := replace(pg_get_functiondef(to_regprocedure('public.staff_home_v1(uuid)')), chr(13), '');
  foreach v_slot in array array['current', 'next'] loop
    v_var := case v_slot when 'current' then 'v_cur' else 'v_next' end;
    v_a := '    into ' || v_var || ' from public.staff_current_next_stays_v1(p_property_id) s where s.slot = ''' || v_slot || ''';';
    if (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a) <> 1 then
      raise exception 's119 staying: the % anchor in staff_home_v1 was not found exactly once; re-cut from the live body', v_slot using errcode = '55000';
    end if;
    v_to := '         || jsonb_build_object(''staying'', public.stay_staying_json_v1(p_property_id, s.uid))' || chr(10) || v_a;
    v_def := replace(v_def, v_a, v_to);
  end loop;
  execute v_def;
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.staff_home_v1(uuid)');
  if v_got is distinct from '18f5723d01ce20788d6fb2f114129ed8' then
    raise exception 's119 staying: staff_home_v1 after the patch has md5 %, expected 18f5723d01ce20788d6fb2f114129ed8', v_got using errcode = '55000';
  end if;
end $$;

-- 6. grants: state the end state ------------------------------------------------------------------------------------------------------------------
revoke all on function public.staff_home_v1(uuid) from public, anon;
grant execute on function public.staff_home_v1(uuid) to authenticated, service_role;

comment on function public.set_stay_staying_v1(uuid, text, text, text, integer, text, text) is 'S119: owner/admin/inspector/cleaner (submit_cleaning) type who is staying. Optimistic lock on version (0 = no row yet, else 40001); idempotency key required (same key + same names = replay). source admin needs manage_operations.';
comment on function public.confirm_stay_staying_suggestion_v1(uuid, text, boolean, integer, text) is 'S119: submit_cleaning roles accept (suggestion becomes names) or reject (dismissed) a pending suggestion. {ok:false,error:no_pending_suggestion,names,version} when none.';
comment on function public.set_stay_staying_suggestion_v1(uuid, text, text) is 'S119: Cassy (service_role) writes the suggestion fields only. {ok:false,error:names_set|dismissed|stay_not_found|contact}; never writes names.';

commit;
