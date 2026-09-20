-- SPEC-10 (fraud design control 11): the Monday Finance roll-up says who decided what this week.
--
-- SPEC-10 assumed payment_finance_reviews could simply be joined to staff names. It cannot: names
-- live in auth.users.raw_user_meta_data->>'display_name', which no public table exposes
-- (staff_access_profiles carries user_id, role and telegram_user_id, no name). get_checklist_staff_names
-- already solves exactly this for the cleaners checklist, so this follows that shape: one definer
-- function reaching into auth.users, service_role only, returning the display name and nothing else
-- about the user.
--
-- Additive: one new function. No column, row, policy, grant or existing function is changed.
begin;

create or replace function public.finance_decisions_week_v1(p_property_id uuid, p_since timestamptz)
returns table (reviewer text, approved integer, rejected integer)
language sql
security definer
stable
set search_path to ''
as $function$
  select coalesce(nullif(btrim(coalesce(u.raw_user_meta_data->>'display_name', '')), ''), 'a teammate') as reviewer,
         count(*) filter (where r.outcome = 'approved')::integer as approved,
         count(*) filter (where r.outcome = 'rejected')::integer as rejected
  from public.payment_finance_reviews r
  left join auth.users u on u.id = r.reviewer_user_id
  where r.property_id = p_property_id
    and r.reviewed_at >= p_since
    and r.outcome in ('approved', 'rejected')
  group by 1
  order by 2 desc, 1;
$function$;

-- Restated in full: a rehearsal restores --no-acl, where the original revoke is missing.
revoke all on function public.finance_decisions_week_v1(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.finance_decisions_week_v1(uuid, timestamptz) to service_role;

comment on function public.finance_decisions_week_v1(uuid, timestamptz) is
  'SPEC-10: confirm/decline counts per reviewer since p_since, for the weekly Finance roll-up. needs_follow_up is not a decision and is excluded. Returns the display name only.';

commit;
