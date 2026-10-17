begin;
create function pg_temp.match_fixture(label text,num int,year_gap int default 0) returns uuid language plpgsql as $$
declare slot uuid:=md5(label||'slot')::uuid; usr uuid; app uuid; i int;
begin
 insert into app_private.intake_event_slots(id,starts_at,opens_at,closes_at,matches_at,region_code,region_label,published,capacity) values(slot,now()+interval '7 days',now()-interval '1 day',now()-interval '2 minutes',now()-interval '1 minute','hongdae','LOCAL MATCH TEST',true,240);
 for i in 1..num loop
  usr:=md5(label||i||'user')::uuid;app:=md5(label||i||'app')::uuid;
  insert into auth.users(id) values(usr);
  insert into app_private.member_accounts(user_id) values(usr);
  insert into app_private.intake_applications(id,user_id,request_key,input,identity_snapshot,onboarding_snapshot,schema_version,consent_snapshot,product_snapshot,payment_status)
  values(app,usr,gen_random_uuid(),jsonb_build_object('slotIds',jsonb_build_array(slot),'regions',jsonb_build_array('hongdae'),'ticketCode','single_v2','otherRegion',''),'{}',jsonb_build_object('birthYear',1995+case when i=num then year_gap else 0 end,'gender',case when i%2=0 then 'male' else 'female' end,'mbti',jsonb_build_array('INTJ'),'interests',jsonb_build_array('film'),'traits',jsonb_build_array('calm'),'preferredTraits',jsonb_build_array('calm')),'google-form-v1','[]','{"code":"single_v2","kind":"single","amountKrw":9900,"policyVersion":"faq-v1"}','PAID');
  insert into app_private.payment_attempts(user_id,application_id,request_key,outcome,amount_krw) values(usr,app,gen_random_uuid(),'success',9900);
 end loop;
 return slot;
end $$;

-- Entire fixture rolls back; no operating data or external delivery.
update app_private.consent_documents set active=false where active;
insert into app_private.consent_documents(id,kind,version,title,body,active) values
(md5('resprivacy')::uuid,'privacy','res-test','LOCAL','LOCAL TEST',true),
(md5('resoperations')::uuid,'operations','res-test','LOCAL','LOCAL TEST',true);
create function pg_temp.resolve(label text,i int,act text,target uuid default null,outcome text default 'success',req uuid default gen_random_uuid()) returns jsonb language plpgsql as $$
declare payload jsonb;
begin
 perform set_config('app.actor_id',md5(label||i||'user')::uuid::text,true);
 payload:=jsonb_build_object('applicationId',md5(label||i||'app')::uuid,'requestKey',req,'action',act);
 if act='transfer' then payload:=payload||jsonb_build_object('slotId',target);end if;
 if act='refund' then payload:=payload||jsonb_build_object('outcome',outcome);end if;
 return app_private.match_resolve(payload);
end $$;
create function pg_temp.target(label text) returns uuid language plpgsql as $$
declare slot uuid:=md5(label)::uuid;
begin
 insert into app_private.intake_event_slots(id,starts_at,opens_at,closes_at,matches_at,region_code,region_label,published,capacity,refund_cutoff_at)
 values(slot,now()+interval '14 days',now()-interval '1 day',now()+interval '1 day',now()+interval '2 days','gangnam','LOCAL ALTERNATIVE',true,24,now()+interval '1 day');return slot;
end $$;
do $$ declare s uuid; dest uuid; child uuid; response jsonb; payload jsonb; key uuid:=gen_random_uuid(); before_count int; t uuid; label text; n int;
begin
 s:=pg_temp.match_fixture('res-fail',3);perform app_private.matching_tick();
 if (select matching_status from app_private.intake_applications where id=md5('res-fail1app')::uuid)<>'ALTERNATIVE_OFFERED' then raise exception 'failure fixture';end if;
 dest:=pg_temp.target('res-target');
 insert into app_private.member_consents(user_id,document_id) select user_id,d.id from app_private.member_accounts cross join app_private.consent_documents d where d.active on conflict do nothing;
 response:=pg_temp.resolve('res-fail',1,'store',null,'success',key);
 if pg_temp.resolve('res-fail',1,'store',null,'success',key)<>response then raise exception 'store replay';end if;
 begin perform pg_temp.resolve('res-fail',1,'transfer',dest,'success',key);raise exception 'accepted changed idem';exception when others then if sqlerrm<>'IDEMPOTENCY_CONFLICT' then raise;end if;end;
 if (select app_private.match_financially_eligible(a) from app_private.intake_applications a where id=md5('res-fail1app')::uuid) then raise exception 'stored matches';end if;
 response:=pg_temp.resolve('res-fail',1,'transfer',dest);child:=(response->>'newApplicationId')::uuid;
 if not(select app_private.match_financially_eligible(a) from app_private.intake_applications a where id=child) then raise exception 'transferred credit unavailable';end if;
 if (select count(*) from app_private.payment_attempts where user_id=md5('res-fail1user')::uuid)<>1 then raise exception 'transfer recharged';end if;
 if (select source_id from app_private.intake_applications where id=child)<>md5('res-fail1app')::uuid then raise exception 'lineage lost';end if;
 begin perform pg_temp.resolve('res-fail',1,'refund');raise exception 'original refunded after transfer';exception when others then if sqlerrm<>'RESOLUTION_CONFLICT' then raise;end if;end;
 perform set_config('app.actor_id',md5('res-fail1user')::uuid::text,true);
 payload:=jsonb_build_object('applicationId',child,'requestKey',gen_random_uuid(),'action','refund','outcome','failure');perform app_private.match_resolve(payload);
 if (select app_private.match_financially_eligible(a) from app_private.intake_applications a where id=child) then raise exception 'refund failure eligible';end if;
 payload:=payload||jsonb_build_object('requestKey',gen_random_uuid(),'outcome','success');perform app_private.match_resolve(payload);perform app_private.match_resolve(payload);
 if (select count(*) from app_private.refund_attempts where payment_id=(select credit_payment_id from app_private.intake_applications where id=child) and outcome='success')<>1 then raise exception 'duplicate refund';end if;
 delete from app_private.match_resolutions where request_key=(payload->>'requestKey')::uuid;
 perform app_private.mock_refund(payload-'action');
 if (select amount_krw from app_private.refund_attempts where request_key=(payload->>'requestKey')::uuid)<>9900 then raise exception 'wrong original amount';end if;
 begin perform pg_temp.resolve('res-fail',2,'transfer',s);raise exception 'closed target accepted';exception when others then if sqlerrm<>'EVENT_CLOSED' then raise;end if;end;
 update app_private.intake_event_slots set matches_at=null where id=dest;
 begin perform pg_temp.resolve('res-fail',2,'transfer',dest);raise exception 'unscheduled target allowed';exception when others then if sqlerrm<>'EVENT_CLOSED' then raise;end if;end;
 update app_private.intake_event_slots set matches_at=now()+interval '2 days' where id=dest;
 delete from app_private.member_consents where user_id=md5('res-fail2user')::uuid;
 begin perform pg_temp.resolve('res-fail',2,'transfer',dest);raise exception 'missing consent accepted';exception when others then if sqlerrm<>'CONSENT_REQUIRED' then raise;end if;end;
 perform pg_temp.resolve('res-fail',2,'store');perform pg_temp.resolve('res-fail',2,'refund');
 -- Cancel a confirmed group: 5->4 remains valid; 4->3 is never confirmed.
 for n in 4..5 loop
  label:='res-cancel'||n;s:=pg_temp.match_fixture(label,n);perform app_private.matching_tick();
  select id into t from app_private.dining_tables where slot_id=s and status='CONFIRMED';
  if t is null then raise exception 'confirm fixture failed';end if;
  update app_private.intake_event_slots set refund_cutoff_at=now()-interval '1 minute' where id=s;
  perform pg_temp.resolve(label,1,'cancel');
  if (select attendance_status from app_private.intake_applications where id=md5(label||'1app')::uuid)<>'CANCELED_LATE' then raise exception 'late cancellation lost';end if;
  begin perform pg_temp.resolve(label,1,'refund');raise exception 'late refund allowed';exception when others then if sqlerrm<>'REFUND_CLOSED' then raise;end if;end;
  if n=4 then
   if (select status from app_private.dining_tables where id=t)<>'INVALIDATED' or exists(select 1 from app_private.table_assignments where table_id=t and active) then raise exception 'three remain confirmed';end if;
   if (select count(*) from app_private.intake_applications where input->'slotIds' ? s::text and matching_status='REALLOCATING')<>3 then raise exception 'survivors not queued';end if;
   perform app_private.matching_tick();
   if (select count(*) from app_private.intake_applications where input->'slotIds' ? s::text and matching_status='ALTERNATIVE_OFFERED')<>3 then raise exception 'repair failed to offer choices';end if;
  else
   if (select status from app_private.dining_tables where id=t)<>'CONFIRMED' or (select count(*) from app_private.table_assignments where table_id=t and active)<>4 then raise exception 'valid four dissolved';end if;
   if not exists(select 1 from app_private.match_outbox where aggregate_id=t and event_type='TABLE_UPDATED') then raise exception 'update event missing';end if;
  end if;
 end loop;
 s:=pg_temp.match_fixture('res-early',4);perform app_private.matching_tick();update app_private.intake_event_slots set refund_cutoff_at=now()+interval '1 day' where id=s;
 perform pg_temp.resolve('res-early',1,'cancel');perform pg_temp.resolve('res-early',1,'refund');
 if (select attendance_status from app_private.intake_applications where id=md5('res-early1app')::uuid)<>'CANCELED_EARLY' then raise exception 'early status';end if;
 s:=pg_temp.match_fixture('res-started',4);perform app_private.matching_tick();
 update app_private.intake_event_slots set starts_at=now()-interval '1 second' where id=s;
 begin perform pg_temp.resolve('res-started',1,'cancel');raise exception 'started cancel allowed';exception when others then if sqlerrm<>'CANCELLATION_CLOSED' then raise;end if;end;
 -- Actor cannot resolve someone else's application; unknown keys cannot inject state/amount.
 perform set_config('app.actor_id',md5('res-fail2user')::uuid::text,true);
 begin perform app_private.match_resolve(jsonb_build_object('applicationId',md5('res-fail3app')::uuid,'requestKey',gen_random_uuid(),'action','store'));raise exception 'unowned allowed';exception when others then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 begin perform app_private.match_resolve(jsonb_build_object('applicationId',md5('res-fail3app')::uuid,'requestKey',gen_random_uuid(),'action','store','amount',1));raise exception 'unknown input allowed';exception when others then if sqlerrm<>'VALIDATION_ERROR' then raise;end if;end;
 if has_table_privilege('app_member_api','app_private.match_resolutions','INSERT') or has_function_privilege('app_member_api','app_private.cancel_table_repair(uuid,uuid)','EXECUTE') or has_function_privilege('authenticated','app_private.match_resolve(jsonb)','EXECUTE') then raise exception 'private grant leak';end if;
 if not has_function_privilege('app_member_api','app_private.match_resolve(jsonb)','EXECUTE') then raise exception 'missing command grant';end if;
end $$;

do $$ declare s uuid; m uuid:=gen_random_uuid(); dest uuid; far_slot uuid; response jsonb; child uuid; expiry timestamptz;
begin
 s:=pg_temp.match_fixture('res-member',3);
 insert into app_private.memberships(id,user_id,starts_at,ends_at,product_code) values(m,md5('res-member1user')::uuid,now()-interval '1 day',now()+interval '30 days','membership_1');
 update app_private.intake_applications set membership_id=m,product_snapshot=product_snapshot||'{"kind":"membership"}' where id=md5('res-member1app')::uuid;
 perform app_private.matching_tick();select ends_at into expiry from app_private.memberships where id=m;
 if (select count(*) from app_private.membership_extensions where membership_id=m)<>1 then raise exception 'failure extension missing';end if;
 perform pg_temp.resolve('res-member',1,'store');
 if (select ends_at from app_private.memberships where id=m)<>expiry then raise exception 'storage changed membership period';end if;
 dest:=pg_temp.target('res-member-target');far_slot:=pg_temp.target('res-member-too-far');update app_private.intake_event_slots set starts_at=now()+interval '90 days' where id=far_slot;
 insert into app_private.member_consents(user_id,document_id) select md5('res-member1user')::uuid,id from app_private.consent_documents where active;
 begin perform pg_temp.resolve('res-member',1,'transfer',far_slot);raise exception 'expired period target allowed';exception when others then if sqlerrm<>'MEMBERSHIP_REQUIRED' then raise;end if;end;
 perform app_private.membership_failure_extend(md5('res-member1app')::uuid);
 response:=pg_temp.resolve('res-member',1,'transfer',dest);child:=(response->>'newApplicationId')::uuid;
 if (select membership_id from app_private.intake_applications where id=child)<>m then raise exception 'membership lost';end if;
 if (select ends_at from app_private.memberships where id=m)<>expiry then raise exception 'original failure duplicate extension';end if;
 perform set_config('app.actor_id',md5('res-member1user')::uuid::text,true);
 begin perform app_private.match_resolve(jsonb_build_object('applicationId',child,'requestKey',gen_random_uuid(),'action','refund','outcome','success'));raise exception 'used membership full refund allowed';exception when others then if sqlerrm<>'MEMBERSHIP_IN_USE' then raise;end if;end;
 if (app_private.matching_get()->'applications'->0->>'canRefund')::boolean then raise exception 'used membership refund UI capability';end if;
end $$;
set local role app_member_api;
select set_config('app.actor_id',md5('res-fail3user')::uuid::text,true);
do $$ declare dto jsonb; begin
 dto:=app_private.matching_get();
 if jsonb_array_length(dto->'applications')<>1 or dto->'applications'->0->>'id'<>md5('res-fail3app')::uuid::text then raise exception 'own DTO scope';end if;
 if dto::text ~ 'birthYear|credit_payment_id|pair_snapshot|user_low' then raise exception 'private resolution data leak';end if;
 perform app_private.match_resolve(jsonb_build_object('applicationId',md5('res-fail3app')::uuid,'requestKey',gen_random_uuid(),'action','store'));
end $$;
reset role;

rollback;
