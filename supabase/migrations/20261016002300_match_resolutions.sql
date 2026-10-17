-- RES-001 / OPS-002: explicit failure choices and cancellation with table repair.
alter table app_private.intake_applications
 add column credit_payment_id uuid references app_private.payment_attempts(id) on delete set null,
 add column credit_stored boolean not null default false,
 add column resolution_reason text check(resolution_reason in ('matching_failure','voluntary','voluntary_late'));
update app_private.intake_applications a set credit_payment_id=p.id
 from app_private.payment_attempts p where p.application_id=a.id and p.outcome='success';
create unique index one_active_payment_credit on app_private.intake_applications(credit_payment_id)
 where application_status='SUBMITTED' and payment_status='PAID';
create table app_private.match_resolutions (
 id uuid primary key default gen_random_uuid(),user_id uuid not null references auth.users(id) on delete cascade,
 application_id uuid not null references app_private.intake_applications(id) on delete cascade,request_key uuid not null,
 action text not null check(action in ('transfer','store','refund','cancel')),
 input jsonb not null,result jsonb not null,created_at timestamptz not null default clock_timestamp(),unique(user_id,request_key)
);
alter table app_private.match_resolutions enable row level security;
revoke all on app_private.match_resolutions from public,anon,authenticated,app_member_api;
create function app_private.payment_credit_link() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.outcome='success' then update app_private.intake_applications set credit_payment_id=new.id where id=new.application_id; end if;
 return new;
end $$;
create trigger payment_credit_link after insert on app_private.payment_attempts for each row execute function app_private.payment_credit_link();

create or replace function app_private.match_financially_eligible(a app_private.intake_applications) returns boolean
language sql stable security definer set search_path='' as $$
 select a.application_status='SUBMITTED' and a.payment_status='PAID' and not a.credit_stored
 and exists(select 1 from app_private.member_accounts where user_id=a.user_id and not restricted)
 and case when a.membership_id is not null then app_private.membership_covers(a.membership_id,a.input->'slotIds')
 else exists(select 1 from app_private.payment_attempts p where p.id=a.credit_payment_id and p.user_id=a.user_id and p.outcome='success'
  and not exists(select 1 from app_private.refund_attempts r where r.payment_id=p.id and r.outcome='success')) end
$$;

-- Caller holds matching-state fence. Never retain a table that fails live constraints.
create function app_private.cancel_table_repair(app_id uuid,request_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare t app_private.dining_tables%rowtype; e app_private.intake_event_slots%rowtype;
 policy app_private.matching_policy%rowtype; size int; gap int; live_score numeric; valid boolean;
begin
 select dt.* into t from app_private.table_assignments ta join app_private.dining_tables dt on dt.id=ta.table_id where ta.application_id=app_id and ta.active for update of dt;
 if t.id is null then return; end if;
 select * into e from app_private.intake_event_slots where id=t.slot_id for share;
 select * into policy from app_private.matching_policy where active for share;
 update app_private.table_assignments set active=false where application_id=app_id and active;
 select count(*),max((a.onboarding_snapshot->>'birthYear')::int)-min((a.onboarding_snapshot->>'birthYear')::int),
 bool_and(app_private.match_financially_eligible(a) and a.input->'slotIds' ? e.id::text and a.input->'regions' ? e.region_code)
 into size,gap,valid from app_private.table_assignments ta join app_private.intake_applications a on a.id=ta.application_id where ta.table_id=t.id and ta.active;
 select avg(app_private.match_pair_score(a.onboarding_snapshot,b.onboarding_snapshot,policy.weights)) into live_score
 from app_private.table_assignments x join app_private.table_assignments y on x.table_id=y.table_id and x.id<y.id
 join app_private.intake_applications a on a.id=x.application_id join app_private.intake_applications b on b.id=y.application_id
 where x.table_id=t.id and x.active and y.active;
 valid:=coalesce(valid,false) and size between 4 and 6 and gap<=8 and live_score>=policy.minimum_score and e.published and e.starts_at>clock_timestamp()
 and not exists(select 1 from app_private.table_assignments x join app_private.table_assignments y on x.table_id=y.table_id and x.id<y.id
 join app_private.match_relations r on r.user_low=least(x.user_id,y.user_id) and r.user_high=greatest(x.user_id,y.user_id) where x.table_id=t.id and x.active and y.active);
 if valid then
  update app_private.dining_tables set score=live_score,validation=jsonb_build_object('count',size,'ageGap',gap,'policyVersion',policy.version,'validatedAt',clock_timestamp()) where id=t.id;
 else
  update app_private.dining_tables set status='INVALIDATED' where id=t.id;
  update app_private.intake_applications set matching_status='REALLOCATING',match_checked_at=clock_timestamp() where id in(select application_id from app_private.table_assignments where table_id=t.id and active);
  update app_private.table_assignments set active=false where table_id=t.id;
  insert into app_private.match_jobs(job_key,slot_id,due_at) values('cancel:'||request_id,t.slot_id,clock_timestamp());
 end if;
 insert into app_private.match_outbox(event_key,event_type,aggregate_id,payload)
 values('cancel:'||request_id,case when valid then 'TABLE_UPDATED' else 'TABLE_INVALIDATED' end,t.id,jsonb_build_object('tableId',t.id)) on conflict do nothing;
end $$;
alter table app_private.match_outbox drop constraint match_outbox_event_type_check;
alter table app_private.match_outbox add constraint match_outbox_event_type_check check(event_type in ('TABLE_CONFIRMED','TABLE_INVALIDATED','TABLE_UPDATED','ALTERNATIVE_OFFERED'));

create function app_private.match_resolve(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor(); a app_private.intake_applications%rowtype;
 previous app_private.match_resolutions%rowtype; e app_private.intake_event_slots%rowtype; p app_private.payment_attempts%rowtype;
 action text:=payload->>'action'; key uuid; child uuid; result jsonb; failure boolean; cutoff timestamptz; confirmed_start timestamptz;
begin
 if jsonb_typeof(payload) is distinct from 'object' or not payload ?& array['applicationId','requestKey','action']
 or coalesce(action,'') not in ('transfer','store','refund','cancel')
 or (select count(*) from jsonb_object_keys(payload))<>(case when action in ('transfer','refund') then 4 else 3 end)
 or coalesce(payload->>'requestKey','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
 or coalesce(payload->>'applicationId','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
 or (action='transfer' and (not payload ? 'slotId' or jsonb_typeof(payload->'slotId') is distinct from 'string'))
 or (action='refund' and (not payload ? 'outcome' or coalesce(payload->>'outcome','') not in ('success','failure'))) then raise exception 'VALIDATION_ERROR'; end if;
 key:=(payload->>'requestKey')::uuid;
 perform pg_advisory_xact_lock(hashtextextended('matching-state',0));
 perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
 select * into a from app_private.intake_applications where id=(payload->>'applicationId')::uuid and user_id=actor for update;
 if a.id is null then raise exception 'FORBIDDEN'; end if;
 select * into previous from app_private.match_resolutions where user_id=actor and request_key=key;
 if previous.id is not null then
  if previous.input<>payload then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
  return previous.result;
 end if;
 failure:=a.matching_status in ('ALTERNATIVE_OFFERED','NO_MATCH') and coalesce(a.resolution_reason,'matching_failure')='matching_failure';
 if a.matching_status='TRANSFERRED' or (a.application_status='CANCELED' and not a.credit_stored and a.resolution_reason is null) then raise exception 'RESOLUTION_CONFLICT'; end if;
 if a.payment_status not in ('PAID','REFUND_FAILED') then raise exception 'PAYMENT_CONFLICT'; end if;
 if a.membership_id is not null then perform 1 from app_private.memberships where id=a.membership_id for update; end if;
 select * into p from app_private.payment_attempts where id=a.credit_payment_id and user_id=actor and outcome='success' for update;
 if p.id is not null and exists(select 1 from app_private.refund_attempts where payment_id=p.id and outcome='success') then raise exception 'PAYMENT_CONFLICT'; end if;
 perform 1 from app_private.intake_event_slots where a.input->'slotIds' ? id::text order by id for share;
 select min(coalesce(refund_cutoff_at,app_private.refund_cutoff(starts_at))) into cutoff from app_private.intake_event_slots where a.input->'slotIds' ? id::text;
 select s.starts_at into confirmed_start from app_private.table_assignments ta join app_private.dining_tables t on t.id=ta.table_id join app_private.intake_event_slots s on s.id=t.slot_id where ta.application_id=a.id and ta.active;
 if action in ('transfer','store') then
  if not failure or a.payment_status<>'PAID' or not(a.application_status='SUBMITTED' or a.credit_stored) then raise exception 'RESOLUTION_CONFLICT'; end if;
  if action='store' then
   if a.credit_stored then raise exception 'RESOLUTION_CONFLICT'; end if;
   update app_private.intake_applications set application_status='CANCELED',matching_status='NO_MATCH',credit_stored=true,resolution_reason='matching_failure' where id=a.id;
  else
   select * into e from app_private.intake_event_slots where id::text=payload->>'slotId' for share;
   if e.id is null or not e.published or e.opens_at>clock_timestamp() or e.closes_at<=clock_timestamp() or e.matches_at<=clock_timestamp() or e.starts_at<=clock_timestamp() then raise exception 'EVENT_CLOSED'; end if;
   if exists(select 1 from app_private.consent_documents d where d.active and d.required and not exists(select 1 from app_private.member_consents c where c.user_id=actor and c.document_id=d.id))
   or (select count(distinct kind) from app_private.consent_documents where active and required)<2 then raise exception 'CONSENT_REQUIRED'; end if;
   if a.membership_id is not null and not app_private.membership_covers(a.membership_id,jsonb_build_array(e.id)) then raise exception 'MEMBERSHIP_REQUIRED'; end if;
   if a.membership_id is null and p.id is null then raise exception 'PAYMENT_CONFLICT'; end if;
   if exists(select 1 from app_private.intake_applications x where x.user_id=actor and x.id<>a.id and x.application_status='SUBMITTED' and x.input->'slotIds' ? e.id::text)
   or exists(select 1 from app_private.table_assignments ta where ta.user_id=actor and ta.active and ta.occupied_at && tstzrange(e.starts_at,e.starts_at+interval '3 hours','[)')) then raise exception 'DUPLICATE_APPLICATION'; end if;
   child:=gen_random_uuid();
   update app_private.intake_applications set application_status='CANCELED',matching_status='TRANSFERRED',credit_stored=false where id=a.id;
   insert into app_private.intake_applications(id,user_id,request_key,source_id,input,identity_snapshot,onboarding_snapshot,schema_version,consent_snapshot,product_snapshot,payment_status,membership_id,credit_payment_id)
   values(child,actor,key,a.id,a.input||jsonb_build_object('slotIds',jsonb_build_array(e.id),'regions',jsonb_build_array(e.region_code),'otherRegion',''),a.identity_snapshot,a.onboarding_snapshot,a.schema_version,
    (select jsonb_agg(jsonb_build_object('id',d.id,'version',d.version,'kind',d.kind)) from app_private.consent_documents d where d.active and d.required),a.product_snapshot,'PAID',a.membership_id,p.id);
   insert into app_private.match_jobs(job_key,slot_id,due_at) values('transfer:'||child,e.id,e.matches_at);
  end if;
 elsif action='cancel' then
  if a.application_status<>'SUBMITTED' or a.payment_status<>'PAID' or a.matching_status not in ('WAITING','REALLOCATING','CONFIRMED') then raise exception 'RESOLUTION_CONFLICT'; end if;
  if coalesce(confirmed_start,(select min(starts_at) from app_private.intake_event_slots where a.input->'slotIds' ? id::text))<=clock_timestamp() then raise exception 'CANCELLATION_CLOSED'; end if;
  update app_private.intake_applications set application_status='CANCELED',matching_status='NO_MATCH',attendance_status=case when clock_timestamp()<cutoff then 'CANCELED_EARLY' else 'CANCELED_LATE' end,
   resolution_reason=case when clock_timestamp()<cutoff then 'voluntary' else 'voluntary_late' end where id=a.id;
  perform app_private.cancel_table_repair(a.id,key);
 else
  if p.id is null then raise exception 'PAYMENT_CONFLICT'; end if;
  if a.resolution_reason='voluntary_late' then raise exception 'REFUND_CLOSED'; end if;
  if not failure and a.resolution_reason is distinct from 'voluntary' then
   if a.application_status<>'SUBMITTED' or a.matching_status<>'WAITING' then raise exception 'PAYMENT_CONFLICT'; end if;
   if a.payment_status='PAID' and clock_timestamp()>=cutoff then raise exception 'REFUND_CLOSED'; end if;
  end if;
  if a.membership_id is not null and exists(select 1 from app_private.intake_applications x where x.membership_id=a.membership_id and x.id<>a.id) then raise exception 'MEMBERSHIP_IN_USE'; end if;
  insert into app_private.refund_attempts(user_id,application_id,payment_id,request_key,amount_krw,outcome,reason)
  values(actor,a.id,p.id,key,p.amount_krw,payload->>'outcome',case when failure then 'matching_failure' else 'voluntary' end);
  update app_private.intake_applications set payment_status=case when payload->>'outcome'='success' then 'REFUNDED' else 'REFUND_FAILED' end,
   application_status=case when payload->>'outcome'='success' then 'CANCELED' else application_status end,credit_stored=false where id=a.id;
  if a.membership_id is not null then update app_private.memberships set active=false where id=a.membership_id; end if;
 end if;
 result:=jsonb_build_object('applicationId',a.id,'action',action,'newApplicationId',child);
 insert into app_private.match_resolutions(user_id,application_id,request_key,action,input,result) values(actor,a.id,key,action,payload,result);
 insert into app_private.member_audit(actor_id,action) values(actor,'RESOLUTION_'||upper(action)||case when action='refund' then '_'||upper(payload->>'outcome') else '' end);
 return result;
end $$;

-- Existing refund endpoint uses the same state machine and original transaction.
create or replace function app_private.mock_refund(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if jsonb_typeof(payload) is distinct from 'object' or (select count(*) from jsonb_object_keys(payload))<>3 or not payload ?& array['applicationId','requestKey','outcome'] then raise exception 'VALIDATION_ERROR'; end if;
 perform app_private.match_resolve(payload||'{"action":"refund"}');
 return app_private.intake_get();
end $$;

alter function app_private.matching_get() rename to matching_get_v1;
revoke all on function app_private.matching_get_v1() from app_member_api;
create function app_private.matching_get() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor(); dto jsonb;
begin
 dto:=app_private.matching_get_v1();
 return jsonb_build_object('applications',coalesce((select jsonb_agg(item||jsonb_build_object(
  'applicationStatus',a.application_status,'paymentStatus',a.payment_status,'attendanceStatus',a.attendance_status,'stored',a.credit_stored,
  'resolutionReason',a.resolution_reason,
  'canResolve',a.payment_status='PAID' and a.matching_status in ('ALTERNATIVE_OFFERED','NO_MATCH') and (a.application_status='SUBMITTED' or a.credit_stored),
  'canCancel',a.application_status='SUBMITTED' and a.payment_status='PAID' and a.matching_status in ('WAITING','REALLOCATING','CONFIRMED') and (select min(e.starts_at)>clock_timestamp() from app_private.intake_event_slots e where a.input->'slotIds' ? e.id::text),
  'refundCutoffAt',(select min(coalesce(e.refund_cutoff_at,app_private.refund_cutoff(e.starts_at))) from app_private.intake_event_slots e where a.input->'slotIds' ? e.id::text),
  'hasOriginalPayment',a.credit_payment_id is not null,
  'alternatives',case when a.payment_status='PAID' and (a.matching_status='ALTERNATIVE_OFFERED' or a.credit_stored) then coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'startsAt',e.starts_at,'regionLabel',e.region_label)) from (select * from app_private.intake_event_slots e where e.published and e.opens_at<=clock_timestamp() and e.closes_at>clock_timestamp() and e.matches_at>clock_timestamp() and (a.membership_id is null or app_private.membership_covers(a.membership_id,jsonb_build_array(e.id))) order by e.starts_at limit 20) e),'[]'::jsonb) else '[]'::jsonb end
 )) from jsonb_array_elements(dto->'applications') item join app_private.intake_applications a on a.id::text=item->>'id' where a.user_id=actor),'[]'::jsonb));
end $$;
revoke all on function app_private.payment_credit_link(),app_private.cancel_table_repair(uuid,uuid),app_private.match_resolve(jsonb),app_private.matching_get() from public,anon,authenticated,app_member_api;
grant execute on function app_private.match_resolve(jsonb),app_private.matching_get() to app_member_api;
