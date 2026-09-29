-- 20260929030000_concierge_turn_stats.sql
-- Session 62, D-285 (DESIGN-weekly-quality-line-2026-09-29): release concierge_turn_stats_20260929.
--   concierge_turn_stats   one row per guest turn written by messenger-concierge (advisory insert after the thread upsert).
--                          No psid, no guest name, no full text: the voice-lint rules of the reply sent, whether the house
--                          reference answered a how-to question, up to 3 redacted words when it did not, and the route.
--                          concierge_threads.history is capped at 32 entries, so a week cannot be counted from it.
--   cassy_week_v1(since)   the Monday Finance card's two Cassy lines (daily-digest); probe rows never count.
-- Service role only, like house_facts. ponytail: no retention job; add a monthly 90-day delete past 100k rows.

begin;

create table if not exists public.concierge_turn_stats (
  id    bigint generated always as identity primary key,
  at    timestamptz not null default now(),
  probe boolean not null default false,
  lint  text[] not null default '{}',
  house text check (house in ('hit', 'miss', 'locked')),
  miss  text,
  re    text,
  jev   text,
  up    boolean
);
create index if not exists concierge_turn_stats_at_idx on public.concierge_turn_stats (at);

alter table public.concierge_turn_stats enable row level security;
-- No policy for anon or authenticated: Edge Functions (service role) only.
revoke all on table public.concierge_turn_stats from public, anon, authenticated;
grant select, insert on table public.concierge_turn_stats to service_role;

create or replace function public.cassy_week_v1(p_since timestamptz)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'turns',  (select count(*) from concierge_turn_stats where at >= p_since and not probe),
    'linted', (select count(*) from concierge_turn_stats where at >= p_since and not probe and cardinality(lint) > 0),
    'rules',  coalesce((select jsonb_agg(jsonb_build_object('rule', r, 'n', n) order by n desc, r)
                from (select r, count(*) n from concierge_turn_stats, unnest(lint) r
                      where at >= p_since and not probe group by r order by n desc, r limit 2) x), '[]'::jsonb),
    'misses', (select count(*) from concierge_turn_stats where at >= p_since and not probe and house = 'miss'),
    'teach',  coalesce((select jsonb_agg(jsonb_build_object('words', miss, 'n', n) order by n desc, miss)
                from (select miss, count(*) n from concierge_turn_stats
                      where at >= p_since and not probe and house = 'miss' and coalesce(miss, '') <> ''
                      group by miss order by n desc, miss limit 3) x), '[]'::jsonb)
  );
$$;
revoke all on function public.cassy_week_v1(timestamptz) from public, anon, authenticated;
grant execute on function public.cassy_week_v1(timestamptz) to service_role;

commit;
