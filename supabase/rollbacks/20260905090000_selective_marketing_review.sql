begin;
drop function public.review_marketing_draft(uuid,text,text,boolean,boolean,boolean,text,text);
drop function public.create_marketing_draft(uuid,text,text,text,text,text,text,text,text,boolean,text,boolean,text,text);
drop table public.marketing_draft_reviews;
drop table public.marketing_drafts;
commit;
