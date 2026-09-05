begin;
drop function public.crm_marketing_eligible(uuid);drop function public.record_crm_retention(uuid,text,date,text,text);drop function public.record_crm_lifecycle(uuid,text,text,text,uuid,boolean,timestamptz,text,text);drop function public.record_crm_consent(uuid,text,text,text,timestamptz,text,text);drop function public.resolve_crm_identity(uuid,text,text);drop function public.create_crm_profile(uuid,text,text,text);
drop table public.crm_retention_decisions;drop table public.crm_lifecycle_events;drop table public.crm_consent_events;drop table public.crm_guest_profiles;drop function public.crm_human_authorized(uuid);
commit;
