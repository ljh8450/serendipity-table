-- PRD 11: scoped profile/history, finance ledger and actionable failure queue.
alter view app_private.operations_entities rename to operations_entities_before_finance;
create view app_private.operations_entities as
select * from app_private.operations_entities_before_finance
union all
select 'exceptions',a.id,'결제·환불 확인','EXCEPTION',a.user_id,null,ta.table_id,a.id,a.submitted_at,
 jsonb_build_object('domain','finance','paymentStatus',a.payment_status,'nextAction','연결 신청의 거래 이력 확인 후 본인의 결제·환불 재시도 안내. 운영자가 대신 결제하지 않음')
from app_private.intake_applications a left join app_private.table_assignments ta on ta.application_id=a.id and ta.active
where a.payment_status in('FAILED','REFUND_FAILED');
revoke all on app_private.operations_entities from public,anon,authenticated,app_member_api;
alter function app_private.operations_explore(jsonb) rename to operations_explore_before_details;
revoke all on function app_private.operations_explore_before_details(jsonb) from app_member_api;
create function app_private.operations_explore(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor();dto jsonb;item jsonb;profile jsonb;target uuid;app uuid;extra jsonb;begin
 dto:=app_private.operations_explore_before_details(payload);
 if not payload ? 'id' or payload->>'kind' not in('members','applications','tables') then return dto;end if;
 item:=dto#>'{items,0}';
 if payload->>'kind'='tables' then
  select ta.application_id,ta.user_id into app,target from app_private.table_assignments ta where ta.table_id=(item->>'id')::uuid and ta.active order by ta.id limit 1;
  if app is null then return dto;end if;
  extra:=app_private.matching_explanation(app,target)-array['preferredTraitsMatchedPeers','peerCount','previouslyMetPeers','participantConditions'];
  extra:=extra||jsonb_build_object('previousMeetingPairs',(select count(*) from app_private.table_assignments x join app_private.table_assignments y on y.table_id=x.table_id and x.user_id<y.user_id join app_private.dining_tables t on t.id=x.table_id join app_private.intake_event_slots es on es.id=t.slot_id where t.id=(item->>'id')::uuid and x.active and y.active and app_private.match_pair_met_before(x.user_id,y.user_id,es.starts_at)));
  return jsonb_set(dto,'{items,0,facts}',(item->'facts')||jsonb_build_object('tableExplanation',extra));
 end if;
 target:=(item->>'memberId')::uuid;app:=(item->>'applicationId')::uuid;
 if app is not null then select onboarding_snapshot into profile from app_private.intake_applications where id=app;
 else select onboarding_snapshot into profile from app_private.intake_applications where user_id=target order by submitted_at desc,id limit 1;end if;
 extra:=jsonb_build_object('gender',profile->>'gender','ageBand',case when (profile->>'birthYear') ~ '^[0-9]{4}$' then ((extract(year from clock_timestamp() at time zone 'Asia/Seoul')::int-(profile->>'birthYear')::int)/10*10)::text||'대' else null end,
 'mbti',profile->'mbti','interests',profile->'interests',
 'attendedCount',(select count(*) from app_private.intake_applications where user_id=target and attendance_status='ATTENDED'),
 'confirmedNoShowCount',(select count(*) from app_private.intake_applications where user_id=target and attendance_status='NO_SHOW'),
 'lateCancellationCount',(select count(*) from app_private.intake_applications where user_id=target and attendance_status='CANCELED_LATE'),
 'participationAllowed',app_private.safety_allowed(target));
 if app is not null then
  extra:=extra||(select jsonb_build_object('ticketType',a.product_snapshot->>'kind','ticketCode',a.product_snapshot->>'code','creditStored',a.credit_stored,'carriedPaymentId',a.credit_payment_id,'membershipExpiresAt',(select ends_at from app_private.memberships where id=a.membership_id)) from app_private.intake_applications a where a.id=app);
  extra:=extra||jsonb_build_object('ledger',(select coalesce(jsonb_agg(entry order by stamp,id),'[]') from (
   select p.created_at stamp,p.id,jsonb_build_object('kind','PAYMENT','id',p.id,'amountKrw',p.amount_krw,'outcome',p.outcome,'at',p.created_at) entry from app_private.payment_attempts p where p.application_id=app
   union all
   select r.created_at,r.id,jsonb_build_object('kind','REFUND','id',r.id,'paymentId',r.payment_id,'amountKrw',r.amount_krw,'outcome',r.outcome,'reason',r.reason,'at',r.created_at) from app_private.refund_attempts r where r.application_id=app
  ) entries));
 end if;
 return jsonb_set(dto,'{items,0,facts}',(item->'facts')||extra);
end $$;
create function app_private.operations_overview_get() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor();begin
 insert into app_private.member_audit(actor_id,action) values(actor,'OPERATIONS_OVERVIEW');
 return jsonb_build_object('asOf',clock_timestamp(),'counts',jsonb_build_object(
 'applicants',(select count(distinct user_id) from app_private.intake_applications),
 'applications',(select count(*) from app_private.intake_applications),
 'paid',(select count(*) from app_private.intake_applications where payment_status='PAID'),
 'waiting',(select count(*) from app_private.intake_applications where matching_status in('WAITING','MATCHING')),
 'reallocating',(select count(*) from app_private.intake_applications where matching_status='REALLOCATING'),
 'confirmed',(select count(*) from app_private.intake_applications where matching_status='CONFIRMED'),
 'failedMatching',(select count(*) from app_private.intake_applications where matching_status in('ALTERNATIVE_OFFERED','NO_MATCH')),
 'tables',(select count(*) from app_private.dining_tables where status='CONFIRMED'),
 'attended',(select count(*) from app_private.intake_applications where attendance_status='ATTENDED'),
 'noShows',(select count(*) from app_private.intake_applications where attendance_status='NO_SHOW'),
 'refunds',(select count(*) from app_private.refund_attempts where outcome='success'),
 'financeFailures',(select count(*) from app_private.intake_applications where payment_status in('FAILED','REFUND_FAILED')),
 'exceptions',(select count(*) from app_private.operations_entities where kind='exceptions')));
end $$;
revoke all on function app_private.operations_explore(jsonb),app_private.operations_overview_get() from public,anon,authenticated;
grant execute on function app_private.operations_explore(jsonb),app_private.operations_overview_get() to app_member_api;
