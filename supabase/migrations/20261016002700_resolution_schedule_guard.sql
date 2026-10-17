-- Missing schedule is a domain conflict, never an unschedulable transfer.
create or replace function app_private.match_resolve(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor(); a app_private.intake_applications%rowtype;
 previous app_private.match_resolutions%rowtype; legacy app_private.refund_attempts%rowtype; e app_private.intake_event_slots%rowtype; p app_private.payment_attempts%rowtype;
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
 select * into legacy from app_private.refund_attempts where user_id=actor and request_key=key;
 if legacy.id is not null then
  if action<>'refund' or legacy.application_id<>a.id or legacy.outcome<>payload->>'outcome' then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
  result:=jsonb_build_object('applicationId',a.id,'action',action,'newApplicationId',null);
  insert into app_private.match_resolutions(user_id,application_id,request_key,action,input,result) values(actor,a.id,key,action,payload,result);
  return result;
 end if;
 failure:=a.matching_status in ('ALTERNATIVE_OFFERED','NO_MATCH') and coalesce(a.resolution_reason,'matching_failure')='matching_failure';
 if a.matching_status='TRANSFERRED' then raise exception 'RESOLUTION_CONFLICT'; end if;
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
   if e.id is null or not e.published or e.opens_at>clock_timestamp() or e.closes_at<=clock_timestamp() or e.matches_at is null or e.matches_at<=clock_timestamp() or e.starts_at<=clock_timestamp() then raise exception 'EVENT_CLOSED'; end if;
   if exists(select 1 from app_private.consent_documents d where d.active and d.required and not exists(select 1 from app_private.member_consents c where c.user_id=actor and c.document_id=d.id))
   or (select count(distinct kind) from app_private.consent_documents where active and required)<2 then raise exception 'CONSENT_REQUIRED'; end if;
   if a.membership_id is not null and not app_private.membership_covers(a.membership_id,jsonb_build_array(e.id)) then raise exception 'MEMBERSHIP_REQUIRED'; end if;
   if a.membership_id is null and p.id is null then raise exception 'PAYMENT_CONFLICT'; end if;
   if exists(select 1 from app_private.intake_applications x where x.user_id=actor and x.id<>a.id and x.application_status='SUBMITTED' and x.input->'slotIds' ? e.id::text)
   or exists(select 1 from app_private.table_assignments ta where ta.user_id=actor and ta.active and ta.occupied_at && tstzrange(e.starts_at,e.starts_at+interval '3 hours','[)')) then raise exception 'DUPLICATE_APPLICATION'; end if;
   if exists(select 1 from app_private.intake_applications where user_id=actor and request_key=key) then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
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

