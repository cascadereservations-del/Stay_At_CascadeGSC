-- admin_audit_feed_v1 was written before staff_details_history and guest_companion_history
-- existed (both shipped later the same session). Their writes are captured correctly in
-- their own tables, just invisible in Settings -> Audit history. Add the two missing branches.
begin;

create or replace function public.admin_audit_feed_v1(p_property_id uuid, p_limit integer default 200)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_fin boolean; v_staff boolean; v_rows jsonb;
begin
  perform public.admin_require('read_operations', p_property_id);
  v_fin := public.current_staff_authorized('read_finance', p_property_id);
  v_staff := public.current_staff_authorized('manage_staff', p_property_id);
  with feed as (
    select a.id, a.created_at at, 'admin' src, a.entity_table, a.entity_id::text entity_id, a.action, a.actor_user_id actor, a.reason, a.before_state before_state, a.after_state after_state,
           (a.action <> 'undo' and not exists (select 1 from public.admin_audit_log u where u.undo_of = a.id)) undoable, a.undo_of
    from public.admin_audit_log a where a.property_id = p_property_id and (v_fin or a.entity_table <> 'transactions')
    union all
    select s.id, s.created_at, 'staff', 'staff_access_profiles', s.target_user_id::text, s.action, s.actor_user_id, s.reason, s.before_state, s.after_state, false, null
    from public.staff_access_audit s where v_staff
    union all
    select e.id, e.created_at, 'booking', 'booking_inquiries', e.booking_id::text, e.event_type, e.actor_user_id, e.reason, e.before_state, e.after_state, false, null
    from public.booking_lifecycle_events e where e.property_id = p_property_id
    union all
    select m.id, m.created_at, 'inventory', 'inventory_items', m.item_id::text, m.kind, m.actor_user_id, m.reason, jsonb_build_object('quantity', m.quantity_before), jsonb_build_object('quantity', m.quantity_after), false, null
    from public.inventory_stock_movements m where m.property_id = p_property_id
    union all
    select j.id, j.posted_at, 'journal', 'acct_journals', j.id::text, case when j.reversal_of is not null then 'reversal' else 'posted' end, j.posted_by, coalesce(j.reversal_reason, j.description), null, jsonb_build_object('journalNo', j.journal_no, 'entryDate', j.entry_date, 'status', j.status), false, null
    from public.acct_journals j where j.property_id = p_property_id and v_fin
    union all
    select r.id, r.reviewed_at, 'readiness', 'cleaning_sessions', r.cleaning_session_id::text, 'readiness_' || r.outcome, r.reviewer_user_id, r.reason, null, jsonb_build_object('forCheckin', r.for_checkin_date), false, null
    from public.readiness_reviews r where r.property_id = p_property_id
    union all
    select v.id, v.reviewed_at, 'evidence', 'cleaning_verification_evidence', v.evidence_id::text, 'evidence_' || v.outcome, v.reviewer_user_id, v.reason, null, null, false, null
    from public.cleaning_verification_reviews v where v.property_id = p_property_id
    union all
    select h.id, h.changed_at, 'guest', 'guests', h.guest_id::text, 'profile_update', h.changed_by, h.reason, h.before_state, h.after_state, false, null
    from public.guest_profile_history h join public.guests g on g.id = h.guest_id where g.property_id = p_property_id
    union all
    select sd.id, sd.changed_at, 'staff_details', 'staff_details', sd.user_id::text, 'staff_details_update', sd.changed_by, sd.reason, sd.before_state, sd.after_state, false, null
    from public.staff_details_history sd where v_staff
    union all
    select ch.id, ch.changed_at, 'companion', 'guest_companions', ch.companion_id::text, 'companion_update', ch.changed_by, ch.reason, ch.before_state, ch.after_state, false, null
    from public.guest_companion_history ch join public.guests g2 on g2.id = ch.guest_id where g2.property_id = p_property_id
  )
  select coalesce(jsonb_agg(to_jsonb(f) order by f.at desc), '[]'::jsonb) into v_rows
  from (select * from feed order by at desc limit least(greatest(coalesce(p_limit, 200), 1), 1000)) f;
  return jsonb_build_object('rows', v_rows, 'financeVisible', v_fin, 'staffVisible', v_staff);
end;
$$;
revoke all on function public.admin_audit_feed_v1(uuid, integer) from public, anon, service_role;
grant execute on function public.admin_audit_feed_v1(uuid, integer) to authenticated;

commit;
