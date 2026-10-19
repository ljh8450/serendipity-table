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
do $$ declare s uuid;actor uuid:=md5('gap-main1user')::uuid;d jsonb;ts jsonb;old uuid;message_id uuid;before_body text;table_uuid uuid;begin
 s:=pg_temp.match_fixture('gap-main',4);
 perform app_private.matching_tick();
 perform set_config('app.actor_id',actor::text,true);
 d:=app_private.matching_get();
 if d#>>'{applications,0,explanation,checks,size}'<>'true' or d#>>'{applications,0,explanation,checks,exclusions}'<>'true'
 or (d#>>'{applications,0,explanation,preferredTraitsMatchedPeers}')::int<>3
 or d#>>'{applications,0,explanation,ageMin}' is null then raise exception 'explanation missing';end if;
 if d::text like '%preferredTraits"%' or d::text like '%birthYear%' or d::text like '%onboarding_snapshot%' then raise exception 'private explanation leak';end if;
 insert into app_private.encounters(user_low,user_high,source_key,occurred_at) select least(actor,md5('gap-main2user')::uuid),greatest(actor,md5('gap-main2user')::uuid),'gap-current',starts_at from app_private.intake_event_slots where id=s;
 d:=app_private.matching_get();
 if (d#>>'{applications,0,explanation,previouslyMetPeers}')::int<>0 then raise exception 'current meeting counted as past';end if;
 update app_private.encounters set occurred_at=occurred_at-interval '1 day' where source_key='gap-current';
 d:=app_private.matching_get();
 if (d#>>'{applications,0,explanation,previouslyMetPeers}')::int<>1 then raise exception 'past meeting missing';end if;
 begin perform app_private.matching_explanation(md5('gap-main2app')::uuid,actor);raise exception 'other explanation allowed';exception when raise_exception then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 begin perform app_private.operations_templates_get();raise exception 'member templates allowed';exception when raise_exception then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 update app_private.member_accounts set role='operator' where user_id=actor;
 ts:=app_private.operations_templates_get();
 select version into old from app_private.message_templates where kind='ALTERNATIVE' and active;
 perform app_private.operations_templates_save(jsonb_build_object('kind','ALTERNATIVE','expectedVersion',old,'body','LOCAL TEMPLATE FIRST'));
 insert into app_private.member_notifications(user_id,event_key,kind,application_id) values(actor,'gap-template','ALTERNATIVE_OFFERED',md5('gap-main1app')::uuid) returning id into message_id;
 select template_snapshot->>'body' into before_body from app_private.member_notifications where id=message_id;
 update app_private.intake_applications set matching_status='ALTERNATIVE_OFFERED' where id=md5('gap-main1app')::uuid;
 if not exists(select 1 from jsonb_array_elements(app_private.notifications_get()->'notifications') n where n->>'id'=message_id::text and n->>'body'='LOCAL TEMPLATE FIRST') then raise exception 'alternative template DTO missing';end if;
 update app_private.intake_applications set matching_status='CONFIRMED' where id=md5('gap-main1app')::uuid;
 select version into old from app_private.message_templates where kind='ALTERNATIVE' and active;
 perform app_private.operations_templates_save(jsonb_build_object('kind','ALTERNATIVE','expectedVersion',old,'body','LOCAL TEMPLATE SECOND'));
 if before_body<>'LOCAL TEMPLATE FIRST' or (select template_snapshot->>'body' from app_private.member_notifications where id=message_id)<>before_body then raise exception 'sent snapshot mutated';end if;
 begin perform app_private.operations_templates_save(jsonb_build_object('kind','ALTERNATIVE','expectedVersion',old,'body','STALE'));raise exception 'stale template allowed';exception when raise_exception then if sqlerrm<>'JOB_CONFLICT' then raise;end if;end;
 begin perform app_private.operations_templates_save('{"kind":"GUIDE","expectedVersion":"x","body":" "}');raise exception 'empty template allowed';exception when raise_exception then if sqlerrm<>'VALIDATION_ERROR' then raise;end if;end;
 d:=app_private.operations_explore(jsonb_build_object('kind','applications','id',md5('gap-main1app')::uuid));
 if jsonb_array_length(d#>'{items,0,facts,ledger}')<>1 or d#>>'{items,0,facts,ageBand}' is null then raise exception 'ledger/profile missing';end if;
 if d::text like '%preferredTraits%' or d::text like '%birthYear%' or d::text like '%request_key%' then raise exception 'operator privacy leak';end if;
 update app_private.intake_applications set payment_status='REFUND_FAILED' where id=md5('gap-main1app')::uuid;
 d:=app_private.operations_explore('{"kind":"exceptions","domain":"finance"}');
 if not exists(select 1 from jsonb_array_elements(d->'items') x where x->>'applicationId'=md5('gap-main1app')::uuid::text) then raise exception 'finance exception missing';end if;
 select table_id into table_uuid from app_private.table_assignments where application_id=md5('gap-main1app')::uuid;
 d:=app_private.operations_explore(jsonb_build_object('kind','tables','id',table_uuid));
 if d#>>'{items,0,facts,tableExplanation,checks,size}'<>'true' or d#>'{items,0,facts,tableExplanation}' ? 'preferredTraitsMatchedPeers' then raise exception 'operator table summary privacy';end if;
 d:=app_private.operations_overview_get();
 if (select (x#>>'{counts,applications}')::int from jsonb_array_elements(d->'slots') x where x->>'id'=s::text)<>4 then raise exception 'slot overview mismatch';end if;
 if (d#>>'{counts,financeFailures}')::int<1 then raise exception 'finance count missing';end if;
end $$;
set local role app_member_api;
select set_config('app.actor_id',md5('gap-main2user')::uuid::text,true);
do $$ begin
 begin perform app_private.operations_overview_get();raise exception 'member overview allowed';exception when raise_exception then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
 begin perform app_private.matching_explanation(md5('gap-main1app')::uuid,md5('gap-main1user')::uuid);raise exception 'internal helper granted';exception when insufficient_privilege then null;end;
end $$;
rollback;
