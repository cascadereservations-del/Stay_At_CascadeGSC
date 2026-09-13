-- Admin modernisation, packets P22-P26: balanced accrual accounting beneath
-- simple forms (PRD section 7). Additive. Internal management accounts only;
-- nothing here is a BIR, statutory or IFRS output and no filing is generated.
--
-- Invariants enforced here, not in the client:
--   ACC01 journals balance, reference active property-scoped accounts, land
--         in an open period on/after the accounting start;
--   ACC02 posted journals are immutable (trigger) and corrected by linked
--         reversals;
--   ACC03 one economic event posts once (partial unique index on source) and
--         a reused idempotency key with a different payload is a conflict;
--   ACC06 opening balances are approved only when they balance exactly; the
--         system never inserts a balancing figure.

create table if not exists public.acct_accounts (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id),
  code text not null,
  name text not null,
  class text not null check (class in ('asset','liability','equity','income','expense')),
  subtype text not null,
  is_cash boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (property_id, code)
);

create table if not exists public.acct_settings (
  property_id uuid primary key references public.properties(id),
  accounting_start date check (accounting_start = date_trunc('month', accounting_start)::date),
  opening_batch_id uuid,
  updated_at timestamptz not null default now()
);

create table if not exists public.acct_periods (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id),
  period_start date not null check (period_start = date_trunc('month', period_start)::date),
  status text not null default 'open' check (status in ('open','closed')),
  closed_at timestamptz, closed_by uuid, snapshot_id uuid,
  reopen_reason text, reopened_at timestamptz, reopened_by uuid,
  unique (property_id, period_start)
);

create table if not exists public.acct_journals (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id),
  journal_no bigint generated always as identity,
  entry_date date not null,
  description text not null check (char_length(btrim(description)) between 3 and 500),
  status text not null default 'posted' check (status in ('posted','reversed')),
  source_table text, source_id text, event_kind text, channel text,
  evidence_ref text,
  mapping_version text not null default 'mapping.v1',
  idempotency_key text not null unique check (char_length(idempotency_key) between 16 and 160),
  payload_hash text not null,
  reversal_of uuid references public.acct_journals(id),
  reversed_by uuid references public.acct_journals(id),
  reversal_reason text,
  posted_by uuid not null,
  posted_at timestamptz not null default now()
);
create index if not exists acct_journals_period_idx on public.acct_journals(property_id, entry_date);
create unique index if not exists acct_journals_one_event_idx on public.acct_journals(property_id, source_table, source_id, event_kind) where source_table is not null and reversal_of is null and status = 'posted';

create table if not exists public.acct_journal_lines (
  id uuid primary key default gen_random_uuid(),
  journal_id uuid not null references public.acct_journals(id) on delete restrict,
  line_no integer not null,
  account_id uuid not null references public.acct_accounts(id),
  debit numeric(14,2) not null default 0 check (debit >= 0),
  credit numeric(14,2) not null default 0 check (credit >= 0),
  memo text,
  unique (journal_id, line_no),
  constraint acct_line_one_side check ((debit > 0 and credit = 0) or (credit > 0 and debit = 0))
);
create index if not exists acct_lines_account_idx on public.acct_journal_lines(account_id);

create table if not exists public.acct_opening_balance_batches (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id),
  accounting_start date not null check (accounting_start = date_trunc('month', accounting_start)::date),
  status text not null default 'draft' check (status in ('draft','approved','rejected')),
  lines jsonb not null default '[]'::jsonb,
  reference_notes text,
  prepared_by uuid, prepared_at timestamptz not null default now(),
  reviewed_by uuid, reviewed_at timestamptz, review_note text,
  journal_id uuid references public.acct_journals(id),
  version integer not null default 1
);

create table if not exists public.acct_close_snapshots (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id),
  period_start date not null,
  version integer not null,
  checklist jsonb not null,
  statements jsonb not null,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  unique (property_id, period_start, version)
);

create table if not exists public.acct_fixed_assets (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id),
  name text not null,
  inventory_item_id uuid references public.inventory_items(id),
  classification text not null default 'pending' check (classification in ('pending','capitalised','expensed','not_owned')),
  ownership_note text,
  cost numeric(14,2), in_service_date date, useful_life_months integer check (useful_life_months is null or useful_life_months > 0), residual_value numeric(14,2),
  classified_by uuid, classified_at timestamptz,
  capitalised_journal_id uuid references public.acct_journals(id),
  disposed_at date,
  version integer not null default 1,
  created_at timestamptz not null default now()
);

create table if not exists public.acct_depreciation_runs (
  id uuid primary key default gen_random_uuid(),
  asset_id uuid not null references public.acct_fixed_assets(id),
  period_start date not null,
  amount numeric(14,2) not null,
  journal_id uuid not null references public.acct_journals(id),
  unique (asset_id, period_start)
);

create table if not exists public.acct_stock_valuations (
  item_id uuid primary key references public.inventory_items(id),
  property_id uuid not null references public.properties(id),
  status text not null default 'unresolved' check (status in ('unresolved','reviewed')),
  cutover_date date,
  opening_qty numeric(12,2), opening_unit_cost numeric(14,4),
  note text, reviewed_by uuid, reviewed_at timestamptz,
  version integer not null default 1
);

alter table public.acct_accounts enable row level security;
alter table public.acct_settings enable row level security;
alter table public.acct_periods enable row level security;
alter table public.acct_journals enable row level security;
alter table public.acct_journal_lines enable row level security;
alter table public.acct_opening_balance_batches enable row level security;
alter table public.acct_close_snapshots enable row level security;
alter table public.acct_fixed_assets enable row level security;
alter table public.acct_depreciation_runs enable row level security;
alter table public.acct_stock_valuations enable row level security;
revoke all on public.acct_accounts, public.acct_settings, public.acct_periods, public.acct_journals, public.acct_journal_lines, public.acct_opening_balance_batches, public.acct_close_snapshots, public.acct_fixed_assets, public.acct_depreciation_runs, public.acct_stock_valuations from public, anon, authenticated, service_role;
grant select on public.acct_accounts, public.acct_settings, public.acct_periods, public.acct_journals, public.acct_journal_lines, public.acct_opening_balance_batches, public.acct_close_snapshots, public.acct_fixed_assets, public.acct_depreciation_runs, public.acct_stock_valuations to authenticated;
create policy acct_accounts_fin on public.acct_accounts for select to authenticated using (public.finance_human_authorized(property_id));
create policy acct_settings_fin on public.acct_settings for select to authenticated using (public.finance_human_authorized(property_id));
create policy acct_periods_fin on public.acct_periods for select to authenticated using (public.finance_human_authorized(property_id));
create policy acct_journals_fin on public.acct_journals for select to authenticated using (public.finance_human_authorized(property_id));
create policy acct_lines_fin on public.acct_journal_lines for select to authenticated using (exists (select 1 from public.acct_journals j where j.id = journal_id and public.finance_human_authorized(j.property_id)));
create policy acct_obb_fin on public.acct_opening_balance_batches for select to authenticated using (public.finance_human_authorized(property_id));
create policy acct_snap_fin on public.acct_close_snapshots for select to authenticated using (public.finance_human_authorized(property_id));
create policy acct_assets_fin on public.acct_fixed_assets for select to authenticated using (public.finance_human_authorized(property_id));
create policy acct_dep_fin on public.acct_depreciation_runs for select to authenticated using (exists (select 1 from public.acct_fixed_assets a where a.id = asset_id and public.finance_human_authorized(a.property_id)));
create policy acct_val_fin on public.acct_stock_valuations for select to authenticated using (public.finance_human_authorized(property_id));

-- ACC02: posted journals and their lines never change. Only the linkage
-- columns written by reverse_journal_v1 may be set, once.
create or replace function public.acct_journal_immutable()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then raise exception using errcode = '55000', message = 'posted journals cannot be deleted; post a reversal'; end if;
  if new.id <> old.id or new.property_id <> old.property_id or new.entry_date <> old.entry_date or new.description <> old.description
     or new.payload_hash <> old.payload_hash or new.idempotency_key <> old.idempotency_key
     or new.posted_by <> old.posted_by or new.posted_at <> old.posted_at or new.source_table is distinct from old.source_table
     or new.source_id is distinct from old.source_id or new.event_kind is distinct from old.event_kind then
    raise exception using errcode = '55000', message = 'posted journals are immutable; post a reversal';
  end if;
  if old.reversed_by is not null and new.reversed_by is distinct from old.reversed_by then
    raise exception using errcode = '55000', message = 'journal already reversed';
  end if;
  if old.reversal_of is not null and new.reversal_of is distinct from old.reversal_of then
    raise exception using errcode = '55000', message = 'reversal linkage is fixed';
  end if;
  return new;
end;
$$;
drop trigger if exists acct_journals_immutable on public.acct_journals;
create trigger acct_journals_immutable before update or delete on public.acct_journals for each row execute function public.acct_journal_immutable();

create or replace function public.acct_lines_immutable()
returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception using errcode = '55000', message = 'journal lines are immutable; post a reversal';
end;
$$;
drop trigger if exists acct_journal_lines_immutable on public.acct_journal_lines;
create trigger acct_journal_lines_immutable before update or delete on public.acct_journal_lines for each row execute function public.acct_lines_immutable();

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function public.acct_require_post(p_property_id uuid)
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  if not public.current_staff_authorized('approve_payment', p_property_id) then
    raise exception using errcode = '42501', message = 'posting requires finance approval rights with a two-factor session';
  end if;
end;
$$;
revoke all on function public.acct_require_post(uuid) from public, anon, service_role;
grant execute on function public.acct_require_post(uuid) to authenticated;

create or replace function public.acct_period_status_v1(p_property_id uuid, p_date date)
returns text language sql stable security definer set search_path = '' as $$
  select case
    when (select accounting_start from public.acct_settings where property_id = p_property_id) is null then 'no_accounting_start'
    when p_date < (select accounting_start from public.acct_settings where property_id = p_property_id) then 'before_start'
    when exists (select 1 from public.acct_periods p where p.property_id = p_property_id and p.period_start = date_trunc('month', p_date)::date and p.status = 'closed') then 'closed'
    else 'open' end;
$$;
revoke all on function public.acct_period_status_v1(uuid, date) from public, anon, service_role;
grant execute on function public.acct_period_status_v1(uuid, date) to authenticated;

-- Compact chart of accounts (PRD section 7). Idempotent; categories only,
-- never balances.
create or replace function public.acct_seed_chart_v1(p_property_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  perform public.acct_require_post(p_property_id);
  insert into public.acct_accounts(property_id, code, name, class, subtype, is_cash) values
    (p_property_id, '1000', 'Cash on hand', 'asset', 'cash', true),
    (p_property_id, '1010', 'UnionBank', 'asset', 'bank', true),
    (p_property_id, '1020', 'GCash', 'asset', 'wallet', true),
    (p_property_id, '1100', 'Airbnb clearing / receivable', 'asset', 'channel_clearing', false),
    (p_property_id, '1110', 'Guest receivables', 'asset', 'receivable', false),
    (p_property_id, '1200', 'Prepayments', 'asset', 'prepayment', false),
    (p_property_id, '1300', 'Supplies inventory', 'asset', 'supplies', false),
    (p_property_id, '1500', 'Fixed assets', 'asset', 'fixed_asset', false),
    (p_property_id, '1590', 'Accumulated depreciation', 'asset', 'accumulated_depreciation', false),
    (p_property_id, '2000', 'Supplier payables', 'liability', 'payable', false),
    (p_property_id, '2010', 'Cleaner payables', 'liability', 'cleaner_payable', false),
    (p_property_id, '2100', 'Guest advances', 'liability', 'guest_advance', false),
    (p_property_id, '2110', 'Refundable deposits', 'liability', 'deposit', false),
    (p_property_id, '2500', 'Owner loans', 'liability', 'owner_loan', false),
    (p_property_id, '2900', 'Other liabilities', 'liability', 'other_liability', false),
    (p_property_id, '3000', 'Owner capital', 'equity', 'owner_capital', false),
    (p_property_id, '3100', 'Owner drawings', 'equity', 'drawings', false),
    (p_property_id, '3900', 'Accumulated earnings', 'equity', 'retained_earnings', false),
    (p_property_id, '4000', 'Accommodation revenue', 'income', 'accommodation', false),
    (p_property_id, '4100', 'Cancellation and no-show charges', 'income', 'cancellation_income', false),
    (p_property_id, '4900', 'Other service income', 'income', 'other_income', false),
    (p_property_id, '5000', 'Channel and co-host fees', 'expense', 'channel_fee', false),
    (p_property_id, '5100', 'Cleaning', 'expense', 'cleaning', false),
    (p_property_id, '5200', 'Utilities', 'expense', 'utilities', false),
    (p_property_id, '5300', 'Consumables', 'expense', 'consumables', false),
    (p_property_id, '5400', 'Maintenance', 'expense', 'maintenance', false),
    (p_property_id, '5500', 'Software and subscriptions', 'expense', 'software', false),
    (p_property_id, '5600', 'Depreciation', 'expense', 'depreciation', false),
    (p_property_id, '5900', 'Other approved expenses', 'expense', 'other_expense', false)
  on conflict (property_id, code) do nothing;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'inserted', n);
end;
$$;
revoke all on function public.acct_seed_chart_v1(uuid) from public, anon, service_role;
grant execute on function public.acct_seed_chart_v1(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Posting engine
-- ---------------------------------------------------------------------------

-- p_lines: [{"account_code":"1010","debit":"6000.00","credit":"0","memo":"..."}]
create or replace function public.post_journal_v1(p_property_id uuid, p_entry_date date, p_description text, p_lines jsonb, p_source_table text, p_source_id text, p_event_kind text, p_evidence_ref text, p_idempotency_key text, p_channel text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_hash text; v_existing public.acct_journals%rowtype; v_id uuid; v_line jsonb; v_no integer := 0; v_acct uuid;
  v_debit numeric := 0; v_credit numeric := 0; v_d numeric; v_c numeric; v_status text;
begin
  perform public.acct_require_post(p_property_id);
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then raise exception using errcode = '22023', message = 'idempotency key required'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then raise exception using errcode = '22023', message = 'a journal needs at least two lines'; end if;
  v_hash := encode(extensions.digest(p_property_id::text || '|' || p_entry_date::text || '|' || coalesce(p_description, '') || '|' || p_lines::text || '|' || coalesce(p_source_table, '') || '|' || coalesce(p_source_id, '') || '|' || coalesce(p_event_kind, ''), 'sha256'), 'hex');
  select * into v_existing from public.acct_journals where idempotency_key = p_idempotency_key;
  if found then
    if v_existing.payload_hash <> v_hash then raise exception using errcode = '23505', message = 'idempotency conflict: this key was used with a different payload'; end if;
    return jsonb_build_object('ok', true, 'journalId', v_existing.id, 'journalNo', v_existing.journal_no, 'replayed', true);
  end if;
  v_status := public.acct_period_status_v1(p_property_id, p_entry_date);
  if v_status = 'no_accounting_start' then raise exception using errcode = '22023', message = 'accounting start date is not set; complete opening balances first'; end if;
  if v_status = 'before_start' then raise exception using errcode = '22023', message = 'entry date is before the accounting start; earlier records stay historical operational data'; end if;
  if v_status = 'closed' then raise exception using errcode = '22023', message = 'period is closed; reopen it with a reason or post a correction in an open period'; end if;
  if (p_source_table is null) <> (p_source_id is null) then raise exception using errcode = '22023', message = 'source table and id go together'; end if;
  if p_source_table is not null and exists (select 1 from public.acct_journals j where j.property_id = p_property_id and j.source_table = p_source_table and j.source_id = p_source_id and j.event_kind is not distinct from p_event_kind and j.reversal_of is null and j.status = 'posted') then
    raise exception using errcode = '23505', message = 'this economic event is already posted; reverse it before posting again';
  end if;

  for v_line in select value from jsonb_array_elements(p_lines) loop
    v_d := coalesce(nullif(v_line->>'debit', '')::numeric, 0); v_c := coalesce(nullif(v_line->>'credit', '')::numeric, 0);
    if v_d < 0 or v_c < 0 or (v_d > 0 and v_c > 0) or (v_d = 0 and v_c = 0) or v_d <> round(v_d, 2) or v_c <> round(v_c, 2) then
      raise exception using errcode = '22023', message = 'each line carries exactly one positive side with at most two decimals';
    end if;
    select id into v_acct from public.acct_accounts a where a.property_id = p_property_id and a.code = v_line->>'account_code' and a.active;
    if v_acct is null then raise exception using errcode = '22023', message = format('unknown or inactive account %s', v_line->>'account_code'); end if;
    v_debit := v_debit + v_d; v_credit := v_credit + v_c;
  end loop;
  if v_debit <> v_credit then raise exception using errcode = '22023', message = format('journal does not balance: debits %s, credits %s', v_debit, v_credit); end if;

  insert into public.acct_journals(property_id, entry_date, description, source_table, source_id, event_kind, channel, evidence_ref, idempotency_key, payload_hash, posted_by)
  values (p_property_id, p_entry_date, btrim(p_description), p_source_table, p_source_id, p_event_kind, p_channel, p_evidence_ref, p_idempotency_key, v_hash, auth.uid()) returning id into v_id;
  for v_line in select value from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    select id into v_acct from public.acct_accounts a where a.property_id = p_property_id and a.code = v_line->>'account_code';
    insert into public.acct_journal_lines(journal_id, line_no, account_id, debit, credit, memo)
    values (v_id, v_no, v_acct, coalesce(nullif(v_line->>'debit', '')::numeric, 0), coalesce(nullif(v_line->>'credit', '')::numeric, 0), v_line->>'memo');
  end loop;
  return jsonb_build_object('ok', true, 'journalId', v_id, 'journalNo', (select journal_no from public.acct_journals where id = v_id), 'postedAt', now(), 'debits', v_debit, 'credits', v_credit);
end;
$$;
revoke all on function public.post_journal_v1(uuid, date, text, jsonb, text, text, text, text, text, text) from public, anon, service_role;
grant execute on function public.post_journal_v1(uuid, date, text, jsonb, text, text, text, text, text, text) to authenticated;

create or replace function public.reverse_journal_v1(p_journal_id uuid, p_reason text, p_entry_date date, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare j public.acct_journals%rowtype; v_lines jsonb; v_res jsonb; v_date date;
begin
  select * into j from public.acct_journals where id = p_journal_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'journal not found'; end if;
  perform public.acct_require_post(j.property_id);
  if p_reason is null or char_length(btrim(p_reason)) < 3 then raise exception using errcode = '22023', message = 'a reversal reason is required'; end if;
  if j.reversed_by is not null then return jsonb_build_object('ok', true, 'journalId', j.reversed_by, 'replayed', true); end if;
  v_date := coalesce(p_entry_date, greatest(j.entry_date, public.manila_today()));
  select jsonb_agg(jsonb_build_object('account_code', a.code, 'debit', l.credit, 'credit', l.debit, 'memo', 'Reversal: ' || coalesce(l.memo, '')) order by l.line_no) into v_lines
  from public.acct_journal_lines l join public.acct_accounts a on a.id = l.account_id where l.journal_id = j.id;
  v_res := public.post_journal_v1(j.property_id, v_date, 'Reversal of #' || j.journal_no::text || ': ' || btrim(p_reason), v_lines, null, null, null, j.evidence_ref, p_idempotency_key, j.channel);
  update public.acct_journals set reversal_of = j.id, reversal_reason = btrim(p_reason) where id = (v_res->>'journalId')::uuid;
  update public.acct_journals set reversed_by = (v_res->>'journalId')::uuid, status = 'reversed' where id = j.id;
  return v_res || jsonb_build_object('reversalOf', j.id);
end;
$$;
revoke all on function public.reverse_journal_v1(uuid, text, date, text) from public, anon, service_role;
grant execute on function public.reverse_journal_v1(uuid, text, date, text) to authenticated;

create or replace function public.acct_line_v1(p_code text, p_debit numeric, p_credit numeric, p_memo text)
returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_object('account_code', p_code, 'debit', round(p_debit, 2)::text, 'credit', round(p_credit, 2)::text, 'memo', p_memo);
$$;
grant execute on function public.acct_line_v1(text, numeric, numeric, text) to authenticated;

-- Simple forms (PRD section 7): the server prepares balanced lines; Finance
-- reviews and posts them with post_journal_v1. Stable, writes nothing.
-- p_payload keys per kind (amounts as decimal strings):
--   expense: amount, expense_code (5xxx), paid_from (1000/1010/1020 or '2000' for unpaid bill), payee
--   supplier_bill: amount, expense_code, supplier   |  pay_supplier: amount, paid_from
--   guest_deposit: amount, paid_into               |  accommodation_earned: amount, channel ('airbnb'|'direct'), host_fee
--   payout_match: amount, paid_into                |  refund: amount, paid_from, earned (bool)
--   owner_contribution: amount, paid_into          |  owner_withdrawal: amount, paid_from
--   transfer: amount, from_code, to_code           |  asset_purchase: amount, paid_from (or '2000')
--   cleaner_fee_accrual: amount                    |  cleaner_fee_payment: amount, paid_from
--   consumable_usage: amount
create or replace function public.prepare_simple_entry_v1(p_property_id uuid, p_kind text, p_payload jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare a numeric; fee numeric; l jsonb := '[]'::jsonb; d text; w text[] := '{}'; src jsonb := null; ch text := null; n_cash integer;
begin
  if not public.finance_human_authorized(p_property_id) then raise exception using errcode = '42501', message = 'finance access required'; end if;
  a := nullif(p_payload->>'amount', '')::numeric;
  if a is null or a <= 0 then raise exception using errcode = '22023', message = 'amount must be a positive number'; end if;
  case p_kind
    when 'expense' then
      d := 'Expense: ' || coalesce(p_payload->>'payee', 'unspecified payee');
      l := l || public.acct_line_v1(p_payload->>'expense_code', a, 0, p_payload->>'payee') || public.acct_line_v1(coalesce(p_payload->>'paid_from', '1000'), 0, a, 'Paid');
    when 'supplier_bill' then
      d := 'Supplier bill: ' || coalesce(p_payload->>'supplier', 'supplier');
      l := l || public.acct_line_v1(p_payload->>'expense_code', a, 0, p_payload->>'supplier') || public.acct_line_v1('2000', 0, a, 'Payable to ' || coalesce(p_payload->>'supplier', 'supplier'));
    when 'pay_supplier' then
      d := 'Supplier payment'; l := l || public.acct_line_v1('2000', a, 0, 'Settle payable') || public.acct_line_v1(coalesce(p_payload->>'paid_from', '1010'), 0, a, 'Paid');
    when 'guest_deposit' then
      d := 'Guest payment before stay'; l := l || public.acct_line_v1(coalesce(p_payload->>'paid_into', '1020'), a, 0, 'Received') || public.acct_line_v1('2100', 0, a, 'Guest advance (unearned)');
    when 'accommodation_earned' then
      ch := coalesce(p_payload->>'channel', 'direct'); fee := coalesce(nullif(p_payload->>'host_fee', '')::numeric, 0);
      d := 'Accommodation earned (' || ch || ')';
      if ch = 'airbnb' then
        l := l || public.acct_line_v1('1100', a, 0, 'Airbnb clearing (gross)') || public.acct_line_v1('4000', 0, a, 'Accommodation revenue');
        if fee > 0 then l := l || public.acct_line_v1('5000', fee, 0, 'Host service fee') || public.acct_line_v1('1100', 0, fee, 'Fee netted by Airbnb'); end if;
      else
        l := l || public.acct_line_v1('2100', a, 0, 'Advance recognised') || public.acct_line_v1('4000', 0, a, 'Accommodation revenue');
      end if;
    when 'payout_match' then
      ch := 'airbnb'; d := 'Airbnb payout received'; l := l || public.acct_line_v1(coalesce(p_payload->>'paid_into', '1010'), a, 0, 'Payout') || public.acct_line_v1('1100', 0, a, 'Settles Airbnb clearing');
    when 'refund' then
      d := 'Guest refund';
      if coalesce((p_payload->>'earned')::boolean, false) then l := l || public.acct_line_v1('4000', a, 0, 'Revenue reversed by refund'); else l := l || public.acct_line_v1('2100', a, 0, 'Advance returned'); end if;
      l := l || public.acct_line_v1(coalesce(p_payload->>'paid_from', '1020'), 0, a, 'Refunded');
    when 'owner_contribution' then
      d := 'Owner contribution'; l := l || public.acct_line_v1(coalesce(p_payload->>'paid_into', '1010'), a, 0, 'Received') || public.acct_line_v1('3000', 0, a, 'Owner capital');
    when 'owner_withdrawal' then
      d := 'Owner withdrawal'; l := l || public.acct_line_v1('3100', a, 0, 'Drawings') || public.acct_line_v1(coalesce(p_payload->>'paid_from', '1010'), 0, a, 'Paid to owner');
    when 'transfer' then
      d := 'Transfer between accounts'; l := l || public.acct_line_v1(p_payload->>'to_code', a, 0, 'Transfer in') || public.acct_line_v1(p_payload->>'from_code', 0, a, 'Transfer out');
      select count(*) into n_cash from public.acct_accounts x where x.property_id = p_property_id and x.code in (p_payload->>'to_code', p_payload->>'from_code') and x.is_cash;
      if n_cash <> 2 then w := w || 'Both transfer accounts must be cash, bank or wallet accounts.'; end if;
    when 'asset_purchase' then
      d := 'Asset purchase (pending Finance classification)'; l := l || public.acct_line_v1('1500', a, 0, coalesce(p_payload->>'description', 'Asset')) || public.acct_line_v1(coalesce(p_payload->>'paid_from', '1010'), 0, a, 'Paid');
      w := w || 'Depreciation starts only after useful life, residual value and in-service date are entered on the asset record.';
    when 'cleaner_fee_accrual' then
      d := 'Cleaning fee accrued'; l := l || public.acct_line_v1('5100', a, 0, 'Cleaning') || public.acct_line_v1('2010', 0, a, 'Owed to cleaner');
    when 'cleaner_fee_payment' then
      d := 'Cleaning fee paid'; l := l || public.acct_line_v1('2010', a, 0, 'Settle cleaner payable') || public.acct_line_v1(coalesce(p_payload->>'paid_from', '1020'), 0, a, 'Paid');
    when 'consumable_usage' then
      d := 'Consumables used'; l := l || public.acct_line_v1('5300', a, 0, 'Consumable expense') || public.acct_line_v1('1300', 0, a, 'Supplies issued');
    else
      raise exception using errcode = '22023', message = 'unknown simple entry kind';
  end case;
  if p_payload ? 'source_table' then src := jsonb_build_object('source_table', p_payload->>'source_table', 'source_id', p_payload->>'source_id', 'event_kind', coalesce(p_payload->>'event_kind', p_kind)); end if;
  return jsonb_build_object('kind', p_kind, 'description', d, 'lines', l, 'channel', ch, 'source', src, 'warnings', to_jsonb(w), 'balanced', (select sum((x->>'debit')::numeric) = sum((x->>'credit')::numeric) from jsonb_array_elements(l) x));
end;
$$;
revoke all on function public.prepare_simple_entry_v1(uuid, text, jsonb) from public, anon, service_role;
grant execute on function public.prepare_simple_entry_v1(uuid, text, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- Opening balances (ACC06)
-- ---------------------------------------------------------------------------

create or replace function public.save_opening_balance_batch_v1(p_property_id uuid, p_batch jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_row public.acct_opening_balance_batches%rowtype; v_debit numeric; v_credit numeric;
begin
  perform public.acct_require_post(p_property_id);
  v_id := nullif(p_batch->>'id', '')::uuid;
  if v_id is null then
    insert into public.acct_opening_balance_batches(property_id, accounting_start, lines, reference_notes, prepared_by)
    values (p_property_id, (p_batch->>'accounting_start')::date, coalesce(p_batch->'lines', '[]'::jsonb), p_batch->>'reference_notes', auth.uid()) returning * into v_row;
  else
    select * into v_row from public.acct_opening_balance_batches where id = v_id and property_id = p_property_id for update;
    if not found then raise exception using errcode = 'P0002', message = 'batch not found'; end if;
    if v_row.status = 'approved' then raise exception using errcode = '55000', message = 'an approved opening balance batch cannot be edited'; end if;
    if nullif(p_batch->>'expected_version', '')::integer is distinct from v_row.version then raise exception using errcode = '40001', message = 'stale version'; end if;
    update public.acct_opening_balance_batches set accounting_start = coalesce((p_batch->>'accounting_start')::date, accounting_start), lines = coalesce(p_batch->'lines', lines), reference_notes = coalesce(p_batch->>'reference_notes', reference_notes), version = version + 1 where id = v_id returning * into v_row;
  end if;
  select coalesce(sum(coalesce(nullif(x->>'debit', '')::numeric, 0)), 0), coalesce(sum(coalesce(nullif(x->>'credit', '')::numeric, 0)), 0) into v_debit, v_credit from jsonb_array_elements(v_row.lines) x;
  return jsonb_build_object('ok', true, 'id', v_row.id, 'version', v_row.version, 'status', v_row.status, 'debits', v_debit, 'credits', v_credit, 'difference', v_debit - v_credit);
end;
$$;
revoke all on function public.save_opening_balance_batch_v1(uuid, jsonb) from public, anon, service_role;
grant execute on function public.save_opening_balance_batch_v1(uuid, jsonb) to authenticated;

create or replace function public.approve_opening_balances_v1(p_batch_id uuid, p_review_note text, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare b public.acct_opening_balance_batches%rowtype; v_debit numeric; v_credit numeric; v_res jsonb; v_lines jsonb;
begin
  select * into b from public.acct_opening_balance_batches where id = p_batch_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'batch not found'; end if;
  perform public.acct_require_post(b.property_id);
  if b.status = 'approved' then return jsonb_build_object('ok', true, 'replayed', true, 'journalId', b.journal_id); end if;
  if exists (select 1 from public.acct_settings s where s.property_id = b.property_id and s.opening_batch_id is not null) then raise exception using errcode = '23505', message = 'opening balances are already approved for this property'; end if;
  if nullif(btrim(coalesce(b.reference_notes, '')), '') is null then raise exception using errcode = '22023', message = 'supporting references are required before approval'; end if;
  select coalesce(sum(coalesce(nullif(x->>'debit', '')::numeric, 0)), 0), coalesce(sum(coalesce(nullif(x->>'credit', '')::numeric, 0)), 0) into v_debit, v_credit from jsonb_array_elements(b.lines) x;
  if v_debit = 0 and v_credit = 0 then raise exception using errcode = '22023', message = 'no balances entered'; end if;
  if v_debit <> v_credit then raise exception using errcode = '22023', message = format('opening balances do not balance (difference %s); resolve it, the system will not invent a balancing figure', v_debit - v_credit); end if;
  insert into public.acct_settings(property_id, accounting_start) values (b.property_id, b.accounting_start) on conflict (property_id) do update set accounting_start = excluded.accounting_start, updated_at = now();
  insert into public.acct_periods(property_id, period_start) values (b.property_id, b.accounting_start) on conflict do nothing;
  select jsonb_agg((x - 'memo') || jsonb_build_object('memo', 'Opening balance: ' || coalesce(x->>'memo', ''))) into v_lines from jsonb_array_elements(b.lines) x where coalesce(nullif(x->>'debit', '')::numeric, 0) > 0 or coalesce(nullif(x->>'credit', '')::numeric, 0) > 0;
  v_res := public.post_journal_v1(b.property_id, b.accounting_start, 'Opening balances as at ' || b.accounting_start::text, v_lines, 'acct_opening_balance_batches', b.id::text, 'opening_balance', b.reference_notes, p_idempotency_key, null);
  update public.acct_opening_balance_batches set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(), review_note = p_review_note, journal_id = (v_res->>'journalId')::uuid, version = version + 1 where id = b.id;
  update public.acct_settings set opening_batch_id = b.id where property_id = b.property_id;
  return v_res || jsonb_build_object('batchId', b.id, 'accountingStart', b.accounting_start);
end;
$$;
revoke all on function public.approve_opening_balances_v1(uuid, text, text) from public, anon, service_role;
grant execute on function public.approve_opening_balances_v1(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Statements (ACC07) from posted journals or a close snapshot
-- ---------------------------------------------------------------------------

create or replace function public.acct_balances_v1(p_property_id uuid, p_from date, p_to_exclusive date)
returns table (account_id uuid, code text, name text, class text, subtype text, is_cash boolean, opening numeric, debits numeric, credits numeric, closing numeric)
language sql stable security definer set search_path = '' as $$
  with l as (
    -- The approved opening-balance journal is dated on accounting_start; it is a
    -- position, not activity, so it always counts as opening, never as movement.
    select jl.account_id, case when j.event_kind = 'opening_balance' then least(j.entry_date, p_from) - 1 else j.entry_date end entry_date, jl.debit, jl.credit
    from public.acct_journal_lines jl join public.acct_journals j on j.id = jl.journal_id
    where j.property_id = p_property_id
  )
  select a.id, a.code, a.name, a.class, a.subtype, a.is_cash,
    coalesce(sum(case when l.entry_date < p_from then l.debit - l.credit end), 0) * case when a.class in ('asset','expense') then 1 else -1 end,
    coalesce(sum(case when l.entry_date >= p_from and l.entry_date < p_to_exclusive then l.debit end), 0),
    coalesce(sum(case when l.entry_date >= p_from and l.entry_date < p_to_exclusive then l.credit end), 0),
    coalesce(sum(case when l.entry_date < p_to_exclusive then l.debit - l.credit end), 0) * case when a.class in ('asset','expense') then 1 else -1 end
  from public.acct_accounts a left join l on l.account_id = a.id
  where a.property_id = p_property_id
  group by a.id, a.code, a.name, a.class, a.subtype, a.is_cash
  order by a.code;
$$;
revoke all on function public.acct_balances_v1(uuid, date, date) from public, anon, service_role;
grant execute on function public.acct_balances_v1(uuid, date, date) to authenticated;

create or replace function public.get_financial_statement_v1(p_property_id uuid, p_statement text, p_start date, p_end_exclusive date, p_snapshot_id uuid default null, p_account_code text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_meta jsonb; v_body jsonb; v_acc_start date; v_snap public.acct_close_snapshots%rowtype;
  v_assets numeric; v_liab numeric; v_equity numeric; v_income numeric; v_expense numeric; v_open_cash numeric; v_close_cash numeric; v_op numeric;
  v_open_equity numeric; v_contrib numeric; v_draw numeric; v_retained numeric;
begin
  if not public.finance_human_authorized(p_property_id) then raise exception using errcode = '42501', message = 'finance access required'; end if;
  if p_snapshot_id is not null then
    select * into v_snap from public.acct_close_snapshots where id = p_snapshot_id and property_id = p_property_id;
    if not found then raise exception using errcode = 'P0002', message = 'snapshot not found'; end if;
    return jsonb_build_object('meta', jsonb_build_object('snapshotId', v_snap.id, 'periodStart', v_snap.period_start, 'version', v_snap.version, 'basis', 'accrual', 'currency', 'PHP', 'internalManagementOnly', true, 'statutoryOrTaxCompliant', false, 'generatedAt', v_snap.created_at, 'source', 'close_snapshot'), 'body', v_snap.statements -> p_statement, 'all', v_snap.statements);
  end if;
  if p_start is null or p_end_exclusive is null or p_end_exclusive <= p_start then raise exception using errcode = '22023', message = 'invalid statement period'; end if;
  select accounting_start into v_acc_start from public.acct_settings where property_id = p_property_id;
  v_meta := jsonb_build_object('propertyId', p_property_id, 'periodStart', p_start, 'periodEndExclusive', p_end_exclusive, 'basis', 'accrual', 'currency', 'PHP', 'internalManagementOnly', true, 'statutoryOrTaxCompliant', false,
    'generatedAt', now(), 'source', 'posted_journals', 'accountingStart', v_acc_start,
    'completeness', jsonb_build_object(
      'openingBalancesApproved', v_acc_start is not null,
      'journalCount', (select count(*) from public.acct_journals j where j.property_id = p_property_id and j.entry_date >= p_start and j.entry_date < p_end_exclusive),
      'unpostedLedgerRows', (select count(*) from public.transactions t where t.property_id = p_property_id and t.status = 'confirmed' and t.transaction_date >= greatest(p_start, coalesce(v_acc_start, p_start)) and t.transaction_date < p_end_exclusive and not exists (select 1 from public.acct_journals j where j.source_table = 'transactions' and j.source_id = t.id::text and j.status = 'posted')),
      'pendingReviewRows', (select count(*) from public.transactions t where t.property_id = p_property_id and t.status = 'pending_review' and t.transaction_date >= p_start and t.transaction_date < p_end_exclusive),
      'periodStatus', public.acct_period_status_v1(p_property_id, p_start)));

  select coalesce(sum(closing) filter (where class = 'asset'), 0), coalesce(sum(closing) filter (where class = 'liability'), 0), coalesce(sum(closing) filter (where class = 'equity'), 0),
         coalesce(sum(credits - debits) filter (where class = 'income'), 0), coalesce(sum(debits - credits) filter (where class = 'expense'), 0),
         coalesce(sum(closing) filter (where class = 'income'), 0) - coalesce(sum(closing) filter (where class = 'expense'), 0)
    into v_assets, v_liab, v_equity, v_income, v_expense, v_retained
  from public.acct_balances_v1(p_property_id, p_start, p_end_exclusive);

  case p_statement
    when 'trial_balance' then
      select jsonb_build_object('rows', coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'class', class, 'opening', opening::text, 'debits', debits::text, 'credits', credits::text, 'closing', closing::text) order by code), '[]'::jsonb),
        'totalDebits', coalesce(sum(debits), 0)::text, 'totalCredits', coalesce(sum(credits), 0)::text, 'balanced', coalesce(sum(debits), 0) = coalesce(sum(credits), 0)) into v_body
      from public.acct_balances_v1(p_property_id, p_start, p_end_exclusive);
    when 'pnl' then
      select jsonb_build_object(
        'income', coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'amount', (credits - debits)::text) order by code) filter (where class = 'income'), '[]'::jsonb),
        'expenses', coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'amount', (debits - credits)::text) order by code) filter (where class = 'expense'), '[]'::jsonb),
        'totalIncome', v_income::text, 'totalExpenses', v_expense::text, 'netProfit', (v_income - v_expense)::text) into v_body
      from public.acct_balances_v1(p_property_id, p_start, p_end_exclusive);
    when 'balance_sheet' then
      select jsonb_build_object(
        'assets', coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'amount', closing::text) order by code) filter (where class = 'asset'), '[]'::jsonb),
        'liabilities', coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'amount', closing::text) order by code) filter (where class = 'liability'), '[]'::jsonb),
        'equity', coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'amount', closing::text) order by code) filter (where class = 'equity'), '[]'::jsonb) || jsonb_build_array(jsonb_build_object('code', '3999', 'name', 'Current and accumulated earnings (unclosed)', 'amount', v_retained::text)),
        'totalAssets', v_assets::text, 'totalLiabilities', v_liab::text, 'totalEquity', (v_equity + v_retained)::text, 'identityHolds', round(v_assets, 2) = round(v_liab + v_equity + v_retained, 2), 'asAt', p_end_exclusive) into v_body
      from public.acct_balances_v1(p_property_id, p_start, p_end_exclusive);
    when 'cash_flow' then
      -- Direct method: cash-account lines classified by the counterpart account subtype.
      with cash_lines as (
        select j.id journal_id, jl.debit - jl.credit delta
        from public.acct_journal_lines jl join public.acct_accounts a on a.id = jl.account_id join public.acct_journals j on j.id = jl.journal_id
        where j.property_id = p_property_id and a.is_cash and j.entry_date >= p_start and j.entry_date < p_end_exclusive
          and j.event_kind is distinct from 'opening_balance'
      ), cp as (
        select c.delta, (select string_agg(distinct b.subtype, ',') from public.acct_journal_lines x join public.acct_accounts b on b.id = x.account_id where x.journal_id = c.journal_id and not b.is_cash) counterpart
        from cash_lines c
      ), cls as (
        select delta, case when counterpart is null then 'transfer' when counterpart ~ 'fixed_asset' then 'investing' when counterpart ~ '(owner_capital|drawings|owner_loan)' then 'financing' else 'operating' end kind from cp
      )
      select jsonb_build_object('operating', coalesce(sum(delta) filter (where kind = 'operating'), 0)::text, 'investing', coalesce(sum(delta) filter (where kind = 'investing'), 0)::text, 'financing', coalesce(sum(delta) filter (where kind = 'financing'), 0)::text, 'netChange', coalesce(sum(delta) filter (where kind <> 'transfer'), 0)::text) into v_body from cls;
      select coalesce(sum(opening), 0), coalesce(sum(closing), 0) into v_open_cash, v_close_cash from public.acct_balances_v1(p_property_id, p_start, p_end_exclusive) where is_cash;
      v_body := v_body || jsonb_build_object('openingCash', v_open_cash::text, 'closingCash', v_close_cash::text, 'reconciles', round(v_open_cash + (v_body->>'netChange')::numeric, 2) = round(v_close_cash, 2), 'note', 'Transfers between owned cash accounts are excluded from all three sections.');
    when 'equity' then
      select coalesce(sum(opening) filter (where class = 'equity'), 0), coalesce(sum(credits - debits) filter (where subtype = 'owner_capital'), 0), coalesce(sum(debits - credits) filter (where subtype = 'drawings'), 0),
             coalesce(sum(opening) filter (where class = 'income'), 0) - coalesce(sum(opening) filter (where class = 'expense'), 0)
        into v_open_equity, v_contrib, v_draw, v_op from public.acct_balances_v1(p_property_id, p_start, p_end_exclusive);
      v_body := jsonb_build_object('openingEquity', (v_open_equity + v_op)::text, 'contributions', v_contrib::text, 'drawings', v_draw::text, 'profitForPeriod', (v_income - v_expense)::text, 'closingEquity', (v_open_equity + v_op + v_contrib - v_draw + v_income - v_expense)::text, 'identityHolds', round(v_open_equity + v_op + v_contrib - v_draw + v_income - v_expense, 2) = round(v_equity + v_retained, 2));
    when 'ledger' then
      select jsonb_build_object('accountCode', p_account_code, 'rows', coalesce(jsonb_agg(jsonb_build_object('journalId', j.id, 'journalNo', j.journal_no, 'date', j.entry_date, 'description', j.description, 'code', a.code, 'debit', jl.debit::text, 'credit', jl.credit::text, 'memo', jl.memo, 'status', j.status, 'source', j.source_table, 'sourceId', j.source_id) order by j.entry_date, j.journal_no, jl.line_no), '[]'::jsonb)) into v_body
      from public.acct_journal_lines jl join public.acct_journals j on j.id = jl.journal_id join public.acct_accounts a on a.id = jl.account_id
      where j.property_id = p_property_id and j.entry_date >= p_start and j.entry_date < p_end_exclusive and (p_account_code is null or a.code = p_account_code);
    when 'ageing' then
      with open as (
        select a.class, a.name, j.source_table, j.source_id, min(j.entry_date) first_date, sum(case when a.class = 'asset' then jl.debit - jl.credit else jl.credit - jl.debit end) balance
        from public.acct_journal_lines jl join public.acct_accounts a on a.id = jl.account_id join public.acct_journals j on j.id = jl.journal_id
        where j.property_id = p_property_id and a.subtype in ('receivable','channel_clearing','payable','cleaner_payable') and j.entry_date < p_end_exclusive
        group by a.class, a.name, j.source_table, j.source_id having sum(case when a.class = 'asset' then jl.debit - jl.credit else jl.credit - jl.debit end) <> 0
      )
      select jsonb_build_object('rows', coalesce(jsonb_agg(jsonb_build_object('side', case when class = 'asset' then 'receivable' else 'payable' end, 'account', name, 'source', source_table, 'sourceId', source_id, 'since', first_date, 'ageDays', p_end_exclusive - first_date, 'bucket', case when p_end_exclusive - first_date <= 30 then '0-30' when p_end_exclusive - first_date <= 60 then '31-60' when p_end_exclusive - first_date <= 90 then '61-90' else '90+' end, 'balance', balance::text) order by first_date), '[]'::jsonb)) into v_body from open;
    when 'budget_vs_actual' then
      select jsonb_build_object('rows', coalesce(jsonb_agg(jsonb_build_object('code', b.code, 'name', b.name, 'actual', (b.debits - b.credits)::text, 'budget', t.target_value::text, 'variance', case when t.target_value is not null then (t.target_value - (b.debits - b.credits))::text end, 'budgetEffectiveFrom', t.effective_from) order by b.code), '[]'::jsonb), 'note', 'Budgets come from management_target_versions rows whose target_kind is budget:<account code>.') into v_body
      from public.acct_balances_v1(p_property_id, p_start, p_end_exclusive) b
      left join lateral (select target_value, effective_from from public.management_target_versions m where m.property_id = p_property_id and m.target_kind = 'budget:' || b.code and m.effective_from <= p_start and (m.effective_to is null or m.effective_to >= p_start) order by m.effective_from desc, m.approved_at desc limit 1) t on true
      where b.class = 'expense';
    when 'channel' then
      select jsonb_build_object('rows', coalesce(jsonb_agg(row_to_json(c)), '[]'::jsonb)) into v_body from (
        select coalesce(j.channel, 'unassigned') channel,
          coalesce(sum(case when a.subtype = 'accommodation' then jl.credit - jl.debit end), 0)::text accommodation,
          coalesce(sum(case when a.subtype = 'channel_fee' then jl.debit - jl.credit end), 0)::text "channelFees",
          coalesce(sum(case when a.subtype = 'cleaning' then jl.debit - jl.credit end), 0)::text cleaning,
          coalesce(sum(case when a.subtype = 'consumables' then jl.debit - jl.credit end), 0)::text consumables,
          (coalesce(sum(case when a.subtype = 'accommodation' then jl.credit - jl.debit end), 0) - coalesce(sum(case when a.subtype in ('channel_fee','cleaning','consumables') then jl.debit - jl.credit end), 0))::text contribution
        from public.acct_journals j join public.acct_journal_lines jl on jl.journal_id = j.id join public.acct_accounts a on a.id = jl.account_id
        where j.property_id = p_property_id and j.entry_date >= p_start and j.entry_date < p_end_exclusive
        group by coalesce(j.channel, 'unassigned') order by 1) c;
    else
      raise exception using errcode = '22023', message = 'unknown statement';
  end case;
  return jsonb_build_object('meta', v_meta, 'body', v_body);
end;
$$;
revoke all on function public.get_financial_statement_v1(uuid, text, date, date, uuid, text) from public, anon, service_role;
grant execute on function public.get_financial_statement_v1(uuid, text, date, date, uuid, text) to authenticated;
comment on function public.get_financial_statement_v1(uuid, text, date, date, uuid, text) is 'Internal management statements from posted journals or an immutable close snapshot. Not BIR, statutory or IFRS compliant; generates no filing.';

-- ---------------------------------------------------------------------------
-- Monthly close (ACC08)
-- ---------------------------------------------------------------------------

create or replace function public.close_accounting_period_v1(p_property_id uuid, p_period_start date, p_checklist jsonb, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_end date; v_tb jsonb; v_bs jsonb; v_cf jsonb; v_eq jsonb; v_pl jsonb; v_ver integer; v_snap uuid; v_period public.acct_periods%rowtype; v_step text;
begin
  perform public.acct_require_post(p_property_id);
  if p_period_start <> date_trunc('month', p_period_start)::date then raise exception using errcode = '22023', message = 'period must start on the first of a month'; end if;
  if public.acct_period_status_v1(p_property_id, p_period_start) in ('no_accounting_start','before_start') then raise exception using errcode = '22023', message = 'period is before the accounting start'; end if;
  insert into public.acct_periods(property_id, period_start) values (p_property_id, p_period_start) on conflict do nothing;
  select * into v_period from public.acct_periods where property_id = p_property_id and period_start = p_period_start for update;
  if v_period.status = 'closed' then return jsonb_build_object('ok', true, 'replayed', true, 'snapshotId', v_period.snapshot_id); end if;
  if exists (select 1 from public.acct_periods p where p.property_id = p_property_id and p.period_start < p_period_start and p.status = 'open') then
    raise exception using errcode = '22023', message = 'an earlier period is still open; close periods in order';
  end if;
  foreach v_step in array array['ingestion_verified','cash_and_settlements_reconciled','duplicates_and_classifications_resolved','obligations_deposits_refunds_reviewed','stock_and_depreciation_reviewed','statement_identities_verified'] loop
    if coalesce((p_checklist->>v_step)::boolean, false) = false then raise exception using errcode = '22023', message = format('close checklist item %s is not confirmed', v_step); end if;
  end loop;
  v_end := (p_period_start + interval '1 month')::date;
  v_tb := public.get_financial_statement_v1(p_property_id, 'trial_balance', p_period_start, v_end);
  v_bs := public.get_financial_statement_v1(p_property_id, 'balance_sheet', p_period_start, v_end);
  v_cf := public.get_financial_statement_v1(p_property_id, 'cash_flow', p_period_start, v_end);
  v_eq := public.get_financial_statement_v1(p_property_id, 'equity', p_period_start, v_end);
  v_pl := public.get_financial_statement_v1(p_property_id, 'pnl', p_period_start, v_end);
  if not (v_tb->'body'->>'balanced')::boolean then raise exception using errcode = '22023', message = 'trial balance does not balance'; end if;
  if not (v_bs->'body'->>'identityHolds')::boolean then raise exception using errcode = '22023', message = 'balance sheet identity fails'; end if;
  if not (v_cf->'body'->>'reconciles')::boolean then raise exception using errcode = '22023', message = 'cash flow does not reconcile opening to closing cash'; end if;
  if not (v_eq->'body'->>'identityHolds')::boolean then raise exception using errcode = '22023', message = 'equity statement identity fails'; end if;
  select coalesce(max(version), 0) + 1 into v_ver from public.acct_close_snapshots where property_id = p_property_id and period_start = p_period_start;
  insert into public.acct_close_snapshots(property_id, period_start, version, checklist, statements, created_by)
  values (p_property_id, p_period_start, v_ver, p_checklist || jsonb_build_object('idempotency_key', p_idempotency_key), jsonb_build_object('trial_balance', v_tb->'body', 'balance_sheet', v_bs->'body', 'cash_flow', v_cf->'body', 'equity', v_eq->'body', 'pnl', v_pl->'body', 'meta', v_tb->'meta'), auth.uid())
  returning id into v_snap;
  update public.acct_periods set status = 'closed', closed_at = now(), closed_by = auth.uid(), snapshot_id = v_snap where id = v_period.id;
  insert into public.acct_periods(property_id, period_start) values (p_property_id, v_end) on conflict do nothing;
  return jsonb_build_object('ok', true, 'snapshotId', v_snap, 'version', v_ver, 'periodStart', p_period_start, 'closedAt', now());
end;
$$;
revoke all on function public.close_accounting_period_v1(uuid, date, jsonb, text) from public, anon, service_role;
grant execute on function public.close_accounting_period_v1(uuid, date, jsonb, text) to authenticated;

create or replace function public.reopen_accounting_period_v1(p_property_id uuid, p_period_start date, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not public.management_owner_authorized(p_property_id) then raise exception using errcode = '42501', message = 'reopening a closed period requires the owner with a two-factor session'; end if;
  if p_reason is null or char_length(btrim(p_reason)) < 5 then raise exception using errcode = '22023', message = 'a reason is required to reopen'; end if;
  update public.acct_periods set status = 'open', reopen_reason = btrim(p_reason), reopened_at = now(), reopened_by = auth.uid()
  where property_id = p_property_id and period_start = p_period_start and status = 'closed';
  if not found then raise exception using errcode = 'P0002', message = 'no closed period for that month'; end if;
  return jsonb_build_object('ok', true, 'periodStart', p_period_start, 'reopenedAt', now(), 'note', 'Previous close snapshots remain available; the next close creates a new version.');
end;
$$;
revoke all on function public.reopen_accounting_period_v1(uuid, date, text) from public, anon, service_role;
grant execute on function public.reopen_accounting_period_v1(uuid, date, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Fixed assets and depreciation (ACC05)
-- ---------------------------------------------------------------------------

create or replace function public.save_fixed_asset_v1(p_property_id uuid, p_asset jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_row public.acct_fixed_assets%rowtype;
begin
  perform public.acct_require_post(p_property_id);
  v_id := nullif(p_asset->>'id', '')::uuid;
  if v_id is null then
    insert into public.acct_fixed_assets(property_id, name, inventory_item_id, ownership_note) values (p_property_id, p_asset->>'name', nullif(p_asset->>'inventory_item_id', '')::uuid, p_asset->>'ownership_note') returning * into v_row;
  else
    select * into v_row from public.acct_fixed_assets where id = v_id and property_id = p_property_id for update;
    if not found then raise exception using errcode = 'P0002', message = 'asset not found'; end if;
    if nullif(p_asset->>'expected_version', '')::integer is distinct from v_row.version then raise exception using errcode = '40001', message = 'stale version'; end if;
    if p_asset->>'classification' = 'capitalised' and coalesce(nullif(p_asset->>'cost', '')::numeric, v_row.cost) is null then
      raise exception using errcode = '22023', message = 'capitalising requires a verified cost';
    end if;
    update public.acct_fixed_assets set
      name = coalesce(nullif(p_asset->>'name', ''), name), ownership_note = coalesce(p_asset->>'ownership_note', ownership_note),
      classification = coalesce(p_asset->>'classification', classification), classified_by = case when p_asset ? 'classification' then auth.uid() else classified_by end, classified_at = case when p_asset ? 'classification' then now() else classified_at end,
      cost = coalesce(nullif(p_asset->>'cost', '')::numeric, cost), in_service_date = coalesce(nullif(p_asset->>'in_service_date', '')::date, in_service_date),
      useful_life_months = coalesce(nullif(p_asset->>'useful_life_months', '')::integer, useful_life_months), residual_value = coalesce(nullif(p_asset->>'residual_value', '')::numeric, residual_value),
      capitalised_journal_id = coalesce(nullif(p_asset->>'capitalised_journal_id', '')::uuid, capitalised_journal_id), version = version + 1
    where id = v_id returning * into v_row;
  end if;
  return jsonb_build_object('ok', true, 'id', v_row.id, 'version', v_row.version, 'classification', v_row.classification);
end;
$$;
revoke all on function public.save_fixed_asset_v1(uuid, jsonb) from public, anon, service_role;
grant execute on function public.save_fixed_asset_v1(uuid, jsonb) to authenticated;

-- Straight-line monthly depreciation. Assets missing any input are skipped
-- and reported; the function never invents a life, residual or date.
create or replace function public.run_depreciation_v1(p_property_id uuid, p_period_start date, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare a record; v_amount numeric; v_posted jsonb := '[]'::jsonb; v_skipped jsonb := '[]'::jsonb; v_res jsonb; v_months_done integer; v_remaining numeric;
begin
  perform public.acct_require_post(p_property_id);
  if p_period_start <> date_trunc('month', p_period_start)::date then raise exception using errcode = '22023', message = 'period must start on the first of a month'; end if;
  for a in select * from public.acct_fixed_assets f where f.property_id = p_property_id and f.disposed_at is null loop
    if a.classification <> 'capitalised' then v_skipped := v_skipped || jsonb_build_object('assetId', a.id, 'name', a.name, 'reason', 'not classified as capitalised'); continue; end if;
    if a.cost is null or a.in_service_date is null or a.useful_life_months is null or a.residual_value is null then
      v_skipped := v_skipped || jsonb_build_object('assetId', a.id, 'name', a.name, 'reason', 'missing cost, in-service date, useful life or residual value'); continue;
    end if;
    if a.in_service_date > (p_period_start + interval '1 month' - interval '1 day')::date then v_skipped := v_skipped || jsonb_build_object('assetId', a.id, 'name', a.name, 'reason', 'not yet in service'); continue; end if;
    if exists (select 1 from public.acct_depreciation_runs r where r.asset_id = a.id and r.period_start = p_period_start) then v_skipped := v_skipped || jsonb_build_object('assetId', a.id, 'name', a.name, 'reason', 'already depreciated for this period'); continue; end if;
    select count(*) into v_months_done from public.acct_depreciation_runs r where r.asset_id = a.id;
    if v_months_done >= a.useful_life_months then v_skipped := v_skipped || jsonb_build_object('assetId', a.id, 'name', a.name, 'reason', 'fully depreciated'); continue; end if;
    v_remaining := a.cost - a.residual_value - coalesce((select sum(amount) from public.acct_depreciation_runs r where r.asset_id = a.id), 0);
    v_amount := least(round((a.cost - a.residual_value) / a.useful_life_months, 2), v_remaining);
    if v_amount <= 0 then v_skipped := v_skipped || jsonb_build_object('assetId', a.id, 'name', a.name, 'reason', 'nothing left to depreciate'); continue; end if;
    v_res := public.post_journal_v1(p_property_id, (p_period_start + interval '1 month' - interval '1 day')::date, 'Depreciation ' || to_char(p_period_start, 'Mon YYYY') || ': ' || a.name,
      jsonb_build_array(jsonb_build_object('account_code', '5600', 'debit', v_amount::text, 'credit', '0', 'memo', a.name), jsonb_build_object('account_code', '1590', 'debit', '0', 'credit', v_amount::text, 'memo', a.name)),
      'acct_fixed_assets', a.id::text, 'depreciation:' || p_period_start::text, null, left(p_idempotency_key || '-' || a.id::text, 160), null);
    insert into public.acct_depreciation_runs(asset_id, period_start, amount, journal_id) values (a.id, p_period_start, v_amount, (v_res->>'journalId')::uuid);
    v_posted := v_posted || jsonb_build_object('assetId', a.id, 'name', a.name, 'amount', v_amount::text, 'journalId', v_res->>'journalId');
  end loop;
  return jsonb_build_object('ok', true, 'posted', v_posted, 'skipped', v_skipped);
end;
$$;
revoke all on function public.run_depreciation_v1(uuid, date, text) from public, anon, service_role;
grant execute on function public.run_depreciation_v1(uuid, date, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Consumable stock valuation (ACC05): weighted average from the cutover.
-- ---------------------------------------------------------------------------

create or replace function public.review_stock_valuation_v1(p_item_id uuid, p_cutover_date date, p_opening_qty numeric, p_opening_unit_cost numeric, p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_prop uuid;
begin
  select property_id into v_prop from public.inventory_items where id = p_item_id;
  if v_prop is null then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  perform public.acct_require_post(v_prop);
  if p_opening_qty is null or p_opening_qty < 0 or p_opening_unit_cost is null or p_opening_unit_cost < 0 then raise exception using errcode = '22023', message = 'opening quantity and unit cost are required; missing costs stay unresolved, not zero'; end if;
  insert into public.acct_stock_valuations(item_id, property_id, status, cutover_date, opening_qty, opening_unit_cost, note, reviewed_by, reviewed_at)
  values (p_item_id, v_prop, 'reviewed', p_cutover_date, p_opening_qty, p_opening_unit_cost, p_note, auth.uid(), now())
  on conflict (item_id) do update set status = 'reviewed', cutover_date = excluded.cutover_date, opening_qty = excluded.opening_qty, opening_unit_cost = excluded.opening_unit_cost, note = excluded.note, reviewed_by = auth.uid(), reviewed_at = now(), version = public.acct_stock_valuations.version + 1;
  return jsonb_build_object('ok', true, 'itemId', p_item_id, 'openingValue', round(p_opening_qty * p_opening_unit_cost, 2));
end;
$$;
revoke all on function public.review_stock_valuation_v1(uuid, date, numeric, numeric, text) from public, anon, service_role;
grant execute on function public.review_stock_valuation_v1(uuid, date, numeric, numeric, text) to authenticated;

-- Weighted-average unit cost as at a date: (opening value + receipts value) / (opening qty + receipts qty) since cutover.
create or replace function public.stock_wa_cost_v1(p_item_id uuid, p_as_of date)
returns numeric language sql stable security definer set search_path = '' as $$
  select case when (v.opening_qty + coalesce(r.qty, 0)) > 0 then round((v.opening_qty * v.opening_unit_cost + coalesce(r.value, 0)) / (v.opening_qty + coalesce(r.qty, 0)), 4) end
  from public.acct_stock_valuations v
  left join lateral (select sum(qty) qty, sum(qty * unit_cost) value from public.inventory_purchases p where p.item_id = v.item_id and p.purchased_at >= v.cutover_date and p.purchased_at < p_as_of and p.unit_cost is not null) r on true
  where v.item_id = p_item_id and v.status = 'reviewed';
$$;
revoke all on function public.stock_wa_cost_v1(uuid, date) from public, anon, service_role;
grant execute on function public.stock_wa_cost_v1(uuid, date) to authenticated;

-- Posts consumable expense for recorded usage in a period at weighted-average cost. Items without a reviewed valuation are reported, never valued at zero.
create or replace function public.post_consumable_usage_v1(p_property_id uuid, p_start date, p_end_exclusive date, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r record; v_total numeric := 0; v_lines jsonb; v_unvalued jsonb := '[]'::jsonb; v_res jsonb;
begin
  perform public.acct_require_post(p_property_id);
  for r in
    select i.id, i.name, sum(u.used_qty) qty, public.stock_wa_cost_v1(i.id, p_end_exclusive) cost
    from public.inventory_usage u join public.inventory_items i on i.id = u.item_id
    where i.property_id = p_property_id and i.is_consumable and u.session_date >= p_start and u.session_date < p_end_exclusive
    group by i.id, i.name
  loop
    if r.cost is null then v_unvalued := v_unvalued || jsonb_build_object('itemId', r.id, 'name', r.name, 'qty', r.qty, 'reason', 'no reviewed stock valuation');
    else v_total := v_total + round(r.qty * r.cost, 2); end if;
  end loop;
  if v_total = 0 then return jsonb_build_object('ok', true, 'posted', false, 'amount', '0.00', 'unvalued', v_unvalued); end if;
  v_lines := jsonb_build_array(jsonb_build_object('account_code', '5300', 'debit', v_total::text, 'credit', '0', 'memo', 'Usage ' || p_start::text || ' to ' || p_end_exclusive::text), jsonb_build_object('account_code', '1300', 'debit', '0', 'credit', v_total::text, 'memo', 'Supplies issued'));
  v_res := public.post_journal_v1(p_property_id, (p_end_exclusive - 1), 'Consumables used ' || p_start::text || ' to ' || p_end_exclusive::text, v_lines, 'inventory_usage', p_start::text || '..' || p_end_exclusive::text, 'consumable_usage', null, p_idempotency_key, null);
  return v_res || jsonb_build_object('amount', v_total::text, 'unvalued', v_unvalued);
end;
$$;
revoke all on function public.post_consumable_usage_v1(uuid, date, date, text) from public, anon, service_role;
grant execute on function public.post_consumable_usage_v1(uuid, date, date, text) to authenticated;
