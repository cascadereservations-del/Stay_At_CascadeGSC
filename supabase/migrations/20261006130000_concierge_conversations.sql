-- Session 72, lane L6: release concierge_conversations_20261006. SPEC-42 section 7 (Conversations panel, H4).
-- The host reads every Cassy thread and its handoffs in one dashboard page. concierge_threads stays service-role only (no client
-- grant, no policy); these two definer RPCs are the only way the dashboard reads it, and both refuse anyone who is not an active
-- owner or admin (same gate as the concierge_handoffs read policy). Sending a reply is NOT here: it is the host-reply Edge Function.
--   concierge_conversations_v1(p_limit)  one row per thread, open handoffs first, then newest. psid is returned because the thread
--                                         RPC and host-reply key on it; psid_short (8 chars of its md5) is the display handle.
--   concierge_thread_v1(p_psid)           one thread: history ({role,text,at,route?}) and its handoffs, or null when there is none.
-- Expand only: two new functions, no table, column or data change.

begin;

create or replace function public.concierge_conversations_v1(p_limit int default 30)
returns table (
  psid text, psid_short text, guest_name text, updated_at timestamptz,
  last_role text, last_text text, last_guest_at timestamptz,
  open_handoffs int, human_until timestamptz, last_risk text
)
language plpgsql stable security definer set search_path to '' as $$
begin
  if not public.current_staff_active(array['owner', 'admin']) then
    raise exception 'only an owner or admin can read conversations' using errcode = '42501';
  end if;
  return query
  select t.psid, left(md5(t.psid), 8), t.guest_name, t.updated_at,
         (t.history -> -1) ->> 'role',
         left((t.history -> -1) ->> 'text', 160),
         (select max(case when e ->> 'at' ~ '^\d{4}-\d{2}-\d{2}T' then (e ->> 'at')::timestamptz end)
            from jsonb_array_elements(t.history) e where e ->> 'role' = 'guest'),
         oh.n, t.human_until, t.last_risk
    from public.concierge_threads t
    cross join lateral (select count(*)::int as n from public.concierge_handoffs h where h.psid = t.psid and h.status = 'open') oh
   where jsonb_typeof(t.history) = 'array'
   order by (oh.n > 0) desc, t.updated_at desc
   limit greatest(1, least(coalesce(p_limit, 30), 100));
end;
$$;

create or replace function public.concierge_thread_v1(p_psid text)
returns jsonb
language plpgsql stable security definer set search_path to '' as $$
declare v jsonb;
begin
  if not public.current_staff_active(array['owner', 'admin']) then
    raise exception 'only an owner or admin can read conversations' using errcode = '42501';
  end if;
  select jsonb_build_object(
           'psid', t.psid, 'psid_short', left(md5(t.psid), 8), 'guest_name', t.guest_name,
           'updated_at', t.updated_at, 'human_until', t.human_until, 'last_risk', t.last_risk,
           'history', case when jsonb_typeof(t.history) = 'array' then t.history else '[]'::jsonb end,
           'handoffs', coalesce((select jsonb_agg(jsonb_build_object(
                'id', h.id, 'status', h.status, 'risk', h.risk, 'guest_text', h.guest_text, 'sent_text', h.sent_text,
                'resolved_by', h.resolved_by, 'resolved_at', h.resolved_at, 'created_at', h.created_at) order by h.created_at)
              from public.concierge_handoffs h where h.psid = t.psid), '[]'::jsonb))
    into v
    from public.concierge_threads t
   where t.psid = p_psid;
  return v;
end;
$$;

revoke all on function public.concierge_conversations_v1(int) from public, anon;
revoke all on function public.concierge_thread_v1(text) from public, anon;
grant execute on function public.concierge_conversations_v1(int) to authenticated;
grant execute on function public.concierge_thread_v1(text) to authenticated;

comment on function public.concierge_conversations_v1(int) is
  'SPEC-42 s7: Conversations panel list. Owner/admin only (42501 otherwise). One row per Cassy thread, open handoffs first then newest; last_guest_at drives the 7-day HUMAN_AGENT reply window.';
comment on function public.concierge_thread_v1(text) is
  'SPEC-42 s7: one Cassy thread with its history and handoffs for the Conversations panel. Owner/admin only (42501 otherwise); null when the thread does not exist.';

commit;
