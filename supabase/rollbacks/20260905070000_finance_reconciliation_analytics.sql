-- Local compensating rollback. Preserve reconciled facts and target audit before an approved release rollback.
begin;
drop function public.get_management_metrics(uuid,date,date);
drop function public.publish_management_target(uuid,text,numeric,text,date,date,text,text);
drop function public.review_finance_reconciliation(uuid,text,numeric,text,text);
drop function public.record_finance_reconciliation(uuid,text,date,text,text,text,text,text,text,numeric,text,text,text,numeric,text);
drop table public.management_target_versions;
drop table public.finance_reconciled_facts;
drop table public.finance_reconciliation_reviews;
drop table public.finance_reconciliation_candidates;
drop function public.management_owner_authorized(uuid);
drop function public.finance_human_authorized(uuid);
commit;
