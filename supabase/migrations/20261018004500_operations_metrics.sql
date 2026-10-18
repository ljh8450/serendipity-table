-- OP-04. New instrumentation has an explicit start; never backfill guessed operator time.
create table app_private.operations_measurement_config(id boolean primary key default true check(id),since timestamptz not null default clock_timestamp());
insert into app_private.operations_measurement_config(id) values(true);
create table app_private.intake_starts(
 user_id uuid not null references auth.users(id) on delete cascade,request_key uuid not null,
 slot_ids jsonb not null default '[]',started_at timestamptz not null default clock_timestamp(),primary key(user_id,request_key));
create table app_private.operations_interventions(
 audit_id bigint primary key,actor_id uuid not null,command text not null,slot_id uuid,application_id uuid,at timestamptz not null default clock_timestamp());
create table app_private.operations_work_sessions(
 id uuid primary key default gen_random_uuid(),actor_id uuid not null,slot_id uuid not null references app_private.intake_event_slots(id),
 start_key uuid not null,stop_key uuid,started_at timestamptz not null default clock_timestamp(),ended_at timestamptz,
 unique(actor_id,start_key),unique(actor_id,stop_key),check(ended_at is null or ended_at>=started_at));
create unique index operations_one_open_session on app_private.operations_work_sessions(actor_id) where ended_at is null;
do $$ declare n text;begin foreach n in array array['operations_measurement_config','intake_starts','operations_interventions','operations_work_sessions'] loop
 execute format('alter table app_private.%I enable row level security',n);
 execute format('revoke all on app_private.%I from public,anon,authenticated,app_member_api',n);end loop;end $$;

create function app_private.intake_start(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor();begin
 if jsonb_typeof(payload) is distinct from 'object' or (payload-array['requestKey','slotIds'])<>'{}'::jsonb
 or coalesce(payload->>'requestKey','')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 or jsonb_typeof(payload->'slotIds') is distinct from 'array' then raise exception 'VALIDATION_ERROR';end if;
 if jsonb_array_length(payload->'slotIds')>20 or exists(select 1 from jsonb_array_elements(payload->'slotIds')v where jsonb_typeof(v)<>'string')
 or exists(select 1 from jsonb_array_elements_text(payload->'slotIds')v where not exists(select 1 from app_private.intake_event_slots s where s.id::text=v)) then raise exception 'VALIDATION_ERROR';end if;
 if not exists(select 1 from app_private.member_accounts where user_id=actor and role='participant') then return jsonb_build_object('recorded',false);end if;
 insert into app_private.intake_starts(user_id,request_key,slot_ids) values(actor,(payload->>'requestKey')::uuid,payload->'slotIds')
 on conflict(user_id,request_key) do update set slot_ids=excluded.slot_ids;
 return jsonb_build_object('recorded',true);
end $$;

-- Observe only successful, audited commands dispatched by the trusted Edge. An idempotent
-- domain replay emits no new audit, so it creates no duplicate intervention.
create function app_private.operations_observe_audit() returns trigger language plpgsql security definer set search_path='' as $$
declare command text:=current_setting('app.operation_name',true);p jsonb;slot uuid;app uuid;tbl uuid;
begin
 if command is null or command not in('matching-retry','venue-retry','chat-retry','content-retry','push-retry','feedback-retry','attendance-review','safety-review')
 or not exists(select 1 from app_private.member_accounts where user_id=new.actor_id and role='operator') then return new;end if;
 p:=current_setting('app.operation_payload',true)::jsonb;
 if command='matching-retry' then select slot_id into slot from app_private.match_jobs where id::text=p->>'jobId';
 elsif command in('venue-retry','chat-retry') then select aggregate_id into tbl from app_private.match_outbox where id::text=p->>'eventId';
 elsif command='content-retry' then select table_id into tbl from app_private.content_jobs where id::text=p->>'jobId';
 elsif command='feedback-retry' then select a.table_id,a.application_id into tbl,app from app_private.feedback_jobs j join app_private.table_assignments a on a.id=j.assignment_id where j.id::text=p->>'jobId';
 elsif command='push-retry' then select n.table_id,n.application_id into tbl,app from app_private.push_jobs j join app_private.member_notifications n on n.id=j.notification_id where j.id::text=p->>'jobId';
 elsif command='attendance-review' then select table_id,application_id into tbl,app from app_private.table_assignments where id::text=p->>'assignmentId';
 elsif command='safety-review' then
  if p->>'caseType'='REPORT' then select a.table_id into tbl from app_private.safety_reports r join app_private.table_assignments a on a.id=r.assignment_id where r.id::text=p->>'caseId';
  elsif p->>'caseType'='ATTENDANCE' then select table_id,application_id into tbl,app from app_private.table_assignments where id::text=p->>'caseId';
  else select a.table_id,a.application_id into tbl,app from app_private.table_assignments a where a.application_id::text=p->>'caseId' order by a.active desc,a.id limit 1;end if;
 end if;
 if tbl is not null then select slot_id into slot from app_private.dining_tables where id=tbl;end if;
 insert into app_private.operations_interventions(audit_id,actor_id,command,slot_id,application_id) values(new.id,new.actor_id,command,slot,app) on conflict do nothing;
 return new;
end $$;
create trigger operations_observe_audit after insert on app_private.member_audit for each row execute function app_private.operations_observe_audit();

create function app_private.operations_work(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor();s app_private.operations_work_sessions;key uuid;slot uuid;sid uuid;
begin
 if jsonb_typeof(payload) is distinct from 'object' or (payload-array['action','slotId','sessionId','requestKey'])<>'{}'::jsonb
 or coalesce(payload->>'action','') not in('start','stop') or coalesce(payload->>'requestKey','')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception 'VALIDATION_ERROR';end if;
 begin key:=(payload->>'requestKey')::uuid;slot:=(payload->>'slotId')::uuid;sid:=(payload->>'sessionId')::uuid;
 exception when invalid_text_representation then raise exception 'VALIDATION_ERROR';end;
 perform pg_advisory_xact_lock(hashtextextended('operations-work:'||actor::text,0));
 if payload->>'action'='start' then
  if sid is not null or slot is null or not exists(select 1 from app_private.intake_event_slots where id=slot) then raise exception 'VALIDATION_ERROR';end if;
  select * into s from app_private.operations_work_sessions where actor_id=actor and start_key=key;
  if s.id is not null then if s.slot_id<>slot then raise exception 'IDEMPOTENCY_CONFLICT';end if;
  else
   if exists(select 1 from app_private.operations_work_sessions where actor_id=actor and ended_at is null) then raise exception 'WORK_CONFLICT';end if;
   insert into app_private.operations_work_sessions(actor_id,slot_id,start_key) values(actor,slot,key) returning * into s;
   insert into app_private.member_audit(actor_id,action) values(actor,'OPERATIONS_WORK_STARTED');
  end if;
 else
  if slot is not null or sid is null then raise exception 'VALIDATION_ERROR';end if;
  select * into s from app_private.operations_work_sessions where id=sid and actor_id=actor for update;
  if s.id is null then raise exception 'FORBIDDEN';end if;
  if s.ended_at is not null then if s.stop_key<>key then raise exception 'WORK_CONFLICT';end if;
  else
   if exists(select 1 from app_private.operations_work_sessions where actor_id=actor and stop_key=key and id<>sid) then raise exception 'IDEMPOTENCY_CONFLICT';end if;
   update app_private.operations_work_sessions set ended_at=clock_timestamp(),stop_key=key where id=sid returning * into s;
   insert into app_private.member_audit(actor_id,action) values(actor,'OPERATIONS_WORK_STOPPED');
  end if;
 end if;
 return jsonb_build_object('id',s.id,'slotId',s.slot_id,'startedAt',s.started_at,'endedAt',s.ended_at);
end $$;

create function app_private.operations_metric(code text,title text,n numeric,d numeric,unit text,note text,coverage text default 'COMPLETE') returns jsonb
language sql immutable set search_path='' as $$
 select jsonb_build_object('id',code,'label',title,'numerator',n,'denominator',d,'value',case when d>0 then n/d end,'unit',unit,'note',note,'coverage',coverage)
$$;

create or replace function app_private.operations_metrics(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor();from_at timestamptz;to_at timestamptz;slot uuid;since_at timestamptz;result jsonb;
begin
 if jsonb_typeof(payload) is distinct from 'object' or (payload-array['from','to','slotId'])<>'{}'::jsonb or not(payload ?& array['from','to'])
 or exists(select 1 from jsonb_each(payload)v where jsonb_typeof(v.value)<>'string') then raise exception 'VALIDATION_ERROR';end if;
 perform app_private.operations_explore(jsonb_build_object('kind','slots','from',payload->>'from','to',payload->>'to'));
 from_at:=(payload->>'from')::timestamptz;to_at:=(payload->>'to')::timestamptz;
 begin slot:=(payload->>'slotId')::uuid;exception when invalid_text_representation then raise exception 'VALIDATION_ERROR';end;
 if slot is not null and not exists(select 1 from app_private.intake_event_slots where id=slot) then raise exception 'VALIDATION_ERROR';end if;
 select since into since_at from app_private.operations_measurement_config where id;
 with apps as(select * from app_private.intake_applications a where a.submitted_at>=from_at and a.submitted_at<to_at and (slot is null or a.input->'slotIds' ? slot::text)),
 paid as(select * from apps a where exists(select 1 from app_private.payment_attempts p where p.application_id=a.id and p.outcome='success') or a.membership_id is not null or a.credit_payment_id is not null),
 confirmed as(select distinct a.user_id,a.id from apps a join app_private.table_assignments ta on ta.application_id=a.id),
 live_confirmed as(select distinct a.user_id,a.id from paid a join app_private.table_assignments ta on ta.application_id=a.id and ta.active join app_private.dining_tables t on t.id=ta.table_id and t.status='CONFIRMED'),
 attended as(select distinct a.user_id,a.id,ta.id assignment_id,s.starts_at from apps a join app_private.table_assignments ta on ta.application_id=a.id and ta.active join app_private.dining_tables t on t.id=ta.table_id and t.status='CONFIRMED' join app_private.intake_event_slots s on s.id=t.slot_id where a.attendance_status='ATTENDED' and s.starts_at+interval '3 hours'<=clock_timestamp()),
 tables as(select * from app_private.dining_tables t where t.created_at>=from_at and t.created_at<to_at and t.status='CONFIRMED' and (slot is null or t.slot_id=slot)),
 failures as(select distinct a.id from apps a where exists(select 1 from app_private.allocation_attempts h where h.application_id=a.id and h.reason in('SOURCE_REPLANNED','REALLOCATED','ALTERNATIVE_OFFERED')) or exists(select 1 from app_private.table_assignments old join app_private.dining_tables dt on dt.id=old.table_id where old.application_id=a.id and dt.status='INVALIDATED')),
 alternatives as(select distinct a.id from apps a join app_private.allocation_attempts h on h.application_id=a.id where h.reason='ALTERNATIVE_OFFERED'),
 refunds as(select distinct a.id from apps a join app_private.refund_attempts r on r.application_id=a.id),
 starts as(select * from app_private.intake_starts s where started_at>=from_at and started_at<to_at and (slot is null or s.slot_ids ? slot::text)),
 interventions as(select * from app_private.operations_interventions i where i.at>=since_at),
 work as(select * from app_private.operations_work_sessions w where w.started_at>=from_at and w.started_at<to_at and (slot is null or w.slot_id=slot))
 select jsonb_build_object('from',from_at,'to',to_at,'asOf',clock_timestamp(),'instrumentationSince',since_at,
 'metrics',jsonb_build_array(
 app_private.operations_metric('applicationCompletion','신청 완료율',(select count(distinct s.user_id) from starts s where exists(select 1 from app_private.intake_applications a where a.user_id=s.user_id and a.request_key=s.request_key)),(select count(distinct user_id) from starts),'ratio','회차 신청 단계에 진입한 고유 사용자 중 같은 작성 키로 제출한 사용자. 시작 수집 이전은 미계측.',case when from_at<since_at then 'PARTIAL' else 'COMPLETE' end),
 app_private.operations_metric('paymentConversion','결제 전환율',(select count(distinct user_id) from paid),(select count(distinct user_id) from apps),'ratio','기간 내 제출한 고유 사용자 중 원결제/멤버십/이동 자격이 확인된 사용자.'),
 app_private.operations_metric('matchingSuccess','매칭 성공률',(select count(distinct user_id) from live_confirmed),(select count(distinct user_id) from paid),'ratio','결제 자격 사용자 중 현재 유효 확정 테이블이 있는 사용자. 취소·정정 반영.'),
 app_private.operations_metric('automaticConfirmation','자동 확정률',(select count(*) from tables t where t.created_at>=since_at and not exists(select 1 from interventions i where i.slot_id=t.slot_id and i.at<=t.created_at)),(select count(*) from tables where created_at>=since_at),'ratio','기간 내 생성된 현재 확정 테이블 중 생성 전 해당 회차 예외 개입이 없는 테이블. 수집 시작 이후만 측정.',case when exists(select 1 from tables where created_at<since_at) then 'PARTIAL' else 'COMPLETE' end),
 app_private.operations_metric('reallocationSuccess','자동 재배치 성공률',(select count(distinct f.id) from failures f join app_private.table_assignments ta on ta.application_id=f.id and ta.active join app_private.dining_tables t on t.id=ta.table_id and t.status='CONFIRMED' where exists(select 1 from app_private.allocation_attempts h where h.application_id=f.id and h.step>0 and h.reason='REALLOCATED') or exists(select 1 from app_private.table_assignments old join app_private.dining_tables dt on dt.id=old.table_id where old.application_id=f.id and dt.status='INVALIDATED' and dt.id<>t.id)),(select count(*) from failures),'ratio','최초 실패/재계획/무효 테이블 이력이 있는 신청 중 다른 유효 테이블에 자동 배치된 신청. 선택 일정 이동 단계와 같은 회차의 무효 테이블 복구를 포함.'),
 app_private.operations_metric('alternativeConversion','대체 일정 전환율',(select count(distinct a.id) from alternatives a join app_private.match_resolutions r on r.application_id=a.id and r.action='transfer'),(select count(*) from alternatives),'ratio','최종 대안 제시 이력이 있는 신청 중 명시 이동을 완료한 신청. 재시도는 신청별 한 번.'),
 app_private.operations_metric('automaticRefund','자동 환불 완료율',(select count(*) from refunds a where exists(select 1 from app_private.refund_attempts r where r.application_id=a.id and r.outcome='success') and not exists(select 1 from interventions i where i.application_id=a.id and i.command like '%refund%')),(select count(*) from refunds),'ratio','환불 선택 신청 중 모의 환불 성공 신청. 현재 환불 API는 본인 선택 자동 처리이며 운영자 환불 명령은 없음. 실제 PG가 아님.'),
 app_private.operations_metric('attendanceConversion','실제 참가 전환율',(select count(distinct user_id) from attended),(select count(distinct user_id) from apps),'ratio','기간 내 신청 고유 사용자 중 종료 식탁 참석이 확인된 사용자. 미래 회차는 아직 미참석.'),
 app_private.operations_metric('noShow','노쇼율',(select count(distinct a.user_id) from apps a join app_private.table_assignments ta on ta.application_id=a.id join app_private.attendance_records r on r.assignment_id=ta.id where a.attendance_status='NO_SHOW' and r.review_status='NO_SHOW'),(select count(distinct user_id) from confirmed),'ratio','배정 이력이 있는 고유 사용자 중 현재 확인 노쇼 사용자. 미확정 후보는 제외.'),
 app_private.operations_metric('returnVisit','재방문율',(select count(distinct a.user_id) from attended a where exists(select 1 from app_private.intake_applications later where later.user_id=a.user_id and later.submitted_at>a.starts_at+interval '3 hours' and later.id<>a.id)),(select count(distinct user_id) from attended),'ratio','종료 참석 고유 사용자 중 행사 종료 후 다른 신청을 제출한 사용자. 후속 신청은 조회 현재까지 확인.'),
 app_private.operations_metric('feedbackResponse','피드백 응답률',(select count(distinct a.user_id) from attended a join app_private.event_feedback f on f.assignment_id=a.assignment_id),(select count(distinct user_id) from attended),'ratio','종료 참석 고유 사용자 중 일반 식탁 평가를 제출한 사용자. 참석 정정 시 다시 계산.'),
 app_private.operations_metric('operatorIntervention','운영자 개입률',(select count(distinct a.id) from apps a where a.submitted_at>=since_at and exists(select 1 from interventions i where i.application_id=a.id or (i.slot_id is not null and (a.input->'slotIds' ? i.slot_id::text or exists(select 1 from app_private.table_assignments ta join app_private.dining_tables t on t.id=ta.table_id where ta.application_id=a.id and t.slot_id=i.slot_id))))),(select count(*) from apps where submitted_at>=since_at),'ratio','수집 시작 이후 신청 중 성공한 운영 예외 명령의 신청 또는 회차 범위에 속한 신청. 회차 작업은 영향 신청 전체에 연결. 반복 명령은 신청별 중복 제외.',case when from_at<since_at then 'PARTIAL' else 'COMPLETE' end),
 app_private.operations_metric('operatingTime','회차 운영 시간',(select sum(extract(epoch from(ended_at-started_at))) from work where ended_at is not null),(select count(distinct slot_id) from work where ended_at is not null),'secondsPerSlot','서버 시작/종료로 기록한 완료 세션의 초 합계 ÷ 실제 측정된 회차 수. 미종료/미계측 시간은 0으로 추정하지 않음.',case when not exists(select 1 from work where ended_at is not null) then 'UNMEASURED' else 'PARTIAL' end)),
 'openSessions',(select count(*) from work where ended_at is null),'completedSessions',(select count(*) from work where ended_at is not null),
 'myActiveSession',(select jsonb_build_object('id',id,'slotId',slot_id,'startedAt',started_at) from app_private.operations_work_sessions where actor_id=actor and ended_at is null)) into result;
 insert into app_private.member_audit(actor_id,action) values(actor,'OPERATIONS_METRICS_READ');return result;
end $$;
revoke all on function app_private.intake_start(jsonb),app_private.operations_observe_audit(),app_private.operations_work(jsonb),app_private.operations_metric(text,text,numeric,numeric,text,text,text),app_private.operations_metrics(jsonb) from public,anon,authenticated,app_member_api;
grant execute on function app_private.intake_start(jsonb),app_private.operations_work(jsonb),app_private.operations_metrics(jsonb) to app_member_api;
