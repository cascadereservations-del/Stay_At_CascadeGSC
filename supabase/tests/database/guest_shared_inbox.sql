begin;
select plan(31);

select has_table('public','guest_conversations','conversation queue exists');
select has_table('public','guest_conversation_messages','encrypted timeline exists');
select has_table('public','guest_reply_drafts','reply drafts exist');
select has_table('public','guest_conversation_audit','conversation audit exists');
select has_function('public','ingest_guest_message',array['uuid','uuid','uuid','text','text','text','text','text','text','timestamp with time zone','text','text'],'guarded inbound ingestion exists');
select has_function('public','propose_guest_reply',array['uuid','text','text','text','text'],'advisory draft RPC exists');
select has_function('public','manage_guest_conversation',array['uuid','text','uuid','text','text'],'human conversation command exists');
select has_function('public','review_guest_reply_draft',array['uuid','text','text','text'],'human draft review exists');
select ok(has_function_privilege('service_role','public.ingest_guest_message(uuid,uuid,uuid,text,text,text,text,text,text,timestamp with time zone,text,text)','execute'),'integration may ingest through RPC');
select ok(has_function_privilege('service_role','public.propose_guest_reply(uuid,text,text,text,text)','execute'),'assistant may propose a draft');
select ok(not has_function_privilege('service_role','public.review_guest_reply_draft(uuid,text,text,text)','execute'),'service cannot approve a draft');
select ok(not has_table_privilege('service_role','public.guest_conversation_messages','select'),'service cannot browse guest messages');
select ok(not has_table_privilege('authenticated','public.guest_reply_drafts','update'),'staff cannot bypass review RPC');

insert into public.properties(id,name,is_active)
values('a1000000-0000-4000-8000-000000000001','Synthetic Inbox Property',true)
on conflict(id) do nothing;
insert into auth.users(id) values
 ('a2000000-0000-4000-8000-000000000001'),
 ('a2000000-0000-4000-8000-000000000002') on conflict(id) do nothing;
insert into public.staff_access_profiles(user_id,role,disabled_at,sessions_revoked_after) values
 ('a2000000-0000-4000-8000-000000000001','admin',null,null),
 ('a2000000-0000-4000-8000-000000000002','cleaner',null,null)
on conflict(user_id) do update set role=excluded.role,disabled_at=null,sessions_revoked_after=null;
insert into public.staff_property_access(user_id,property_id) values
 ('a2000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000001'),
 ('a2000000-0000-4000-8000-000000000002','a1000000-0000-4000-8000-000000000001') on conflict do nothing;

set local role service_role;
select set_config('cascade.w2_conversation',(public.ingest_guest_message(
 'a1000000-0000-4000-8000-000000000001',null,null,'direct_web',repeat('a',64),
 'encrypted-body-value-00000001','Routine arrival question',repeat('b',64),repeat('c',64),now(),null,
 'wave2-message-ingest-0001'
)->>'conversation_id'),true);
select is(public.ingest_guest_message(
 'a1000000-0000-4000-8000-000000000001',null,null,'direct_web',repeat('a',64),
 'encrypted-body-value-00000001','Routine arrival question',repeat('b',64),repeat('c',64),now(),null,
 'wave2-message-ingest-0001'
)->>'already_processed','true','inbound retry is idempotent');
select is(public.ingest_guest_message(
 'a1000000-0000-4000-8000-000000000001',null,null,'direct_web',repeat('a',64),
 'encrypted-body-value-00000002','Refund requested',repeat('d',64),repeat('e',64),now(),'refund',
 'wave2-message-ingest-0002'
)->>'escalated','true','refund message escalates deterministically');
select set_config('cascade.w2_draft',public.propose_guest_reply(
 current_setting('cascade.w2_conversation')::uuid,'encrypted-draft-value-0000001','Draft requires review','refund',
 'wave2-reply-draft-000001'
)::text,true);
select is(public.propose_guest_reply(
 current_setting('cascade.w2_conversation')::uuid,'encrypted-draft-value-0000001','Draft requires review','refund',
 'wave2-reply-draft-000001'
),current_setting('cascade.w2_draft')::uuid,'draft retry is idempotent');
select throws_ok(
 $$select public.ingest_guest_message(
   'a1000000-0000-4000-8000-000000000001',null,null,'email',repeat('f',64),
   'encrypted-body-value-00000003','guest@example.invalid',repeat('1',64),repeat('2',64),now(),null,
   'wave2-unredacted-message-1')$$,
 '22023',null,'unredacted contact preview is rejected');
reset role;

select is((select status from public.guest_conversations where id=current_setting('cascade.w2_conversation')::uuid),'escalated','conversation remains escalated');
select is((select count(*) from public.guest_conversation_messages where conversation_id=current_setting('cascade.w2_conversation')::uuid),2::bigint,'timeline stores each inbound message once');

set local role authenticated;
set local request.jwt.claims='{"sub":"a2000000-0000-4000-8000-000000000002","aal":"aal2"}';
select is((select count(*) from public.guest_conversations),0::bigint,'OPS cleaner sees no guest inbox rows');
select throws_ok(
 $$select public.manage_guest_conversation(current_setting('cascade.w2_conversation')::uuid,'resolve',null,'Cleaner attempted resolve','wave2-cleaner-resolve-001')$$,
 '42501',null,'OPS cleaner cannot manage guest conversation');
select throws_ok(
 $$select public.review_guest_reply_draft(current_setting('cascade.w2_draft')::uuid,'approved','Cleaner attempted approval','wave2-cleaner-review-0001')$$,
 '42501',null,'OPS cleaner cannot approve a reply');

set local request.jwt.claims='{"sub":"a2000000-0000-4000-8000-0000000000ff","aal":"aal1"}';
select throws_ok(
 $$select public.review_guest_reply_draft(current_setting('cascade.w2_draft')::uuid,'approved','AAL1 attempted approval','wave2-aal1-review-000001')$$,
 '42501',null,'unknown user cannot review a reply (aal no longer gates, D-094)');

set local request.jwt.claims='{"sub":"a2000000-0000-4000-8000-000000000001","aal":"aal2"}';
select is(public.manage_guest_conversation(
 current_setting('cascade.w2_conversation')::uuid,'assign','a2000000-0000-4000-8000-000000000001',
 'Assign to guest support owner','wave2-admin-assign-000001'
)->>'already_processed','false','authorized admin assigns conversation');
select is(public.manage_guest_conversation(
 current_setting('cascade.w2_conversation')::uuid,'assign','a2000000-0000-4000-8000-000000000001',
 'Assign to guest support owner','wave2-admin-assign-000001'
)->>'already_processed','true','assignment retry is idempotent');
select is(public.review_guest_reply_draft(
 current_setting('cascade.w2_draft')::uuid,'approved','Reviewed exact draft content','wave2-admin-review-000001'
)->>'send_authorized','false','approval does not authorize provider sending');
select is(public.review_guest_reply_draft(
 current_setting('cascade.w2_draft')::uuid,'approved','Reviewed exact draft content','wave2-admin-review-000001'
)->>'already_processed','true','review retry is idempotent');
reset role;

select is((select reviewer_user_id from public.guest_reply_drafts where id=current_setting('cascade.w2_draft')::uuid),
 'a2000000-0000-4000-8000-000000000001'::uuid,'draft records named human reviewer');
select is((select assigned_to from public.guest_conversations where id=current_setting('cascade.w2_conversation')::uuid),
 'a2000000-0000-4000-8000-000000000001'::uuid,'assignment records named staff identity');
select is((select count(*) from public.automation_outbox where aggregate_id=current_setting('cascade.w2_conversation')::uuid),0::bigint,'inbox approval queues no delivery');
select ok((select count(*)>=5 from public.guest_conversation_audit),'timeline actions retain immutable audit history');

select * from finish();
rollback;
