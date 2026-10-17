-- Prevent a concurrent tab from silently replacing the draft being submitted.
alter table app_private.intake_drafts add column revision uuid not null default gen_random_uuid();
alter table app_private.intake_applications add column draft_revision uuid;

create or replace function app_private.intake_get() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := app_private.member_actor(); result jsonb;
begin
 select jsonb_build_object(
  'schemaVersion',s.version,'groups',s.groups,
  'identity',m.identity,'onboarding',m.onboarding,'savedSchemaVersion',m.schema_version,
  'draft',case when d.user_id is null then null else jsonb_build_object('input',d.input,'sourceId',d.source_id,'revision',d.revision) end,
  'slots',coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'startsAt',e.starts_at,'closesAt',e.closes_at,'regionCode',e.region_code,'regionLabel',e.region_label) order by e.starts_at,e.region_label)
   from app_private.intake_event_slots e where e.published and e.opens_at <= now() and e.closes_at > now()),'[]'::jsonb),
  'products',coalesce((select jsonb_agg(jsonb_build_object('code',p.code,'label',p.label,'amountKrw',p.amount_krw,'uses',p.uses,'validityMonths',p.validity_months) order by p.uses)
   from app_private.intake_ticket_products p where p.active),'[]'::jsonb),
  'applications',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'submittedAt',a.submitted_at,'input',a.input,
   'identitySnapshot',a.identity_snapshot,'onboardingSnapshot',a.onboarding_snapshot,
   'applicationStatus',a.application_status,'paymentStatus',a.payment_status,'matchingStatus',a.matching_status,'attendanceStatus',a.attendance_status) order by a.submitted_at desc)
   from (select * from app_private.intake_applications where user_id=actor order by submitted_at desc limit 20) a),'[]'::jsonb)
 ) into result from app_private.intake_schema s
 left join app_private.intake_members m on m.user_id=actor
 left join app_private.intake_drafts d on d.user_id=actor where s.active;
 return result;
end $$;

create or replace function app_private.intake_draft_save(payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := app_private.member_actor(); data jsonb := payload->'input'; value jsonb; source uuid;
begin
 if jsonb_typeof(payload) is distinct from 'object' or not payload ?& array['input','sourceId'] or
  (select count(*) from jsonb_object_keys(payload)) <> 2 or jsonb_typeof(data) is distinct from 'object' or
  not data ?& array['slotIds','regions','otherRegion','ticketCode'] or (select count(*) from jsonb_object_keys(data)) <> 4 then raise exception 'VALIDATION_ERROR'; end if;
 if jsonb_typeof(data->'slotIds') is distinct from 'array' or jsonb_array_length(data->'slotIds') > 30 or
  jsonb_typeof(data->'regions') is distinct from 'array' or jsonb_array_length(data->'regions') > 5 or
  jsonb_typeof(data->'otherRegion') is distinct from 'string' or length(data->>'otherRegion') > 200 or
  jsonb_typeof(data->'ticketCode') is distinct from 'string' then raise exception 'VALIDATION_ERROR'; end if;
 for value in select v from jsonb_array_elements(data->'slotIds') v loop
  if jsonb_typeof(value) is distinct from 'string' or not exists(select 1 from app_private.intake_event_slots where id::text=value #>> '{}') then raise exception 'VALIDATION_ERROR'; end if;
 end loop;
 for value in select v from jsonb_array_elements(data->'regions') v loop
  if jsonb_typeof(value) is distinct from 'string' or not exists(select 1 from app_private.intake_schema s,jsonb_array_elements(s.groups) g,jsonb_array_elements(g->'options') o where s.active and g->>'key'='regions' and o->>'id'=value #>> '{}') then raise exception 'VALIDATION_ERROR'; end if;
 end loop;
 if data->>'ticketCode' not in ('','single','three','use_three') then raise exception 'VALIDATION_ERROR'; end if;
 if payload->'sourceId' <> 'null'::jsonb then
  select id into source from app_private.intake_applications where user_id=actor and id::text=payload->>'sourceId';
  if source is null then raise exception 'FORBIDDEN'; end if;
 end if;
 insert into app_private.intake_drafts(user_id,input,source_id) values(actor,data,source)
  on conflict(user_id) do update set input=excluded.input,source_id=excluded.source_id,updated_at=now(), revision=case when app_private.intake_drafts.input is distinct from excluded.input or app_private.intake_drafts.source_id is distinct from excluded.source_id then gen_random_uuid() else app_private.intake_drafts.revision end;
 return app_private.intake_get();
end $$;

create or replace function app_private.intake_submit(payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := app_private.member_actor(); draft app_private.intake_drafts%rowtype;
 member app_private.intake_members%rowtype; product app_private.intake_ticket_products%rowtype;
 current_version text; consent_ids jsonb; request_id uuid; previous app_private.intake_applications%rowtype;
begin
 if jsonb_typeof(payload) is distinct from 'object' or not payload ?& array['requestKey','draftRevision'] or
  (select count(*) from jsonb_object_keys(payload)) <> 2 or jsonb_typeof(payload->'requestKey') is distinct from 'string' or jsonb_typeof(payload->'draftRevision') is distinct from 'string' or (payload->>'requestKey') !~ '^[0-9a-fA-F-]{36}$' then raise exception 'VALIDATION_ERROR'; end if;
 request_id := (payload->>'requestKey')::uuid;
 perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
 select * into draft from app_private.intake_drafts where user_id=actor for update;
 select * into previous from app_private.intake_applications where user_id=actor and request_key=request_id;
 if previous.id is not null then
  if payload->>'draftRevision' is distinct from previous.draft_revision::text then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
  return app_private.intake_get();
 end if;
 if draft.revision::text is distinct from payload->>'draftRevision' then raise exception 'DRAFT_CHANGED'; end if;
 select * into member from app_private.intake_members where user_id=actor for share;
 select version into current_version from app_private.intake_schema where active for share;
 if member.identity is null or member.onboarding is null or member.schema_version is distinct from current_version then raise exception 'PROFILE_REQUIRED'; end if;
 if draft.user_id is null or jsonb_array_length(draft.input->'regions')=0 or jsonb_array_length(draft.input->'slotIds')=0 then raise exception 'VALIDATION_ERROR'; end if;
 if draft.input->'regions' ? 'other' and length(btrim(draft.input->>'otherRegion'))=0 then raise exception 'VALIDATION_ERROR'; end if;
 if (select count(distinct value) from jsonb_array_elements(draft.input->'slotIds')) <> jsonb_array_length(draft.input->'slotIds') then raise exception 'VALIDATION_ERROR'; end if;
 perform 1 from app_private.intake_event_slots where id::text in (select jsonb_array_elements_text(draft.input->'slotIds')) order by id for share;
 if exists(select 1 from jsonb_array_elements_text(draft.input->'slotIds') selected
  where not exists(select 1 from app_private.intake_event_slots e where e.id::text=selected and e.published and e.opens_at<=now() and e.closes_at>now() and draft.input->'regions' ? e.region_code)) then raise exception 'EVENT_CLOSED'; end if;
 -- Server-verified credit redemption belongs to PAY: never grant it from a checkbox.
 if draft.input->>'ticketCode'='use_three' then raise exception 'TICKET_UNAVAILABLE'; end if;
 select * into product from app_private.intake_ticket_products where code=draft.input->>'ticketCode' and active for share;
 if product.code is null then raise exception 'TICKET_UNAVAILABLE'; end if;
 perform 1 from app_private.consent_documents where active and required order by id for share;
 if (select count(distinct kind) from app_private.consent_documents where active and required) <> 2 or
  exists(select 1 from app_private.consent_documents d where d.active and d.required and not exists(select 1 from app_private.member_consents c where c.user_id=actor and c.document_id=d.id)) then raise exception 'CONSENT_REQUIRED'; end if;
 select jsonb_agg(jsonb_build_object('id',id,'version',version)) into consent_ids from app_private.consent_documents where active and required;
 -- Same account cannot submit overlapping active choices using a different request key.
 if exists(select 1 from app_private.intake_applications a where a.user_id=actor and a.application_status='SUBMITTED' and
  exists(select 1 from jsonb_array_elements_text(a.input->'slotIds') old_slot join jsonb_array_elements_text(draft.input->'slotIds') new_slot on old_slot=new_slot)) then raise exception 'DUPLICATE_APPLICATION'; end if;
 insert into app_private.intake_applications(user_id,request_key,source_id,input,identity_snapshot,onboarding_snapshot,schema_version,consent_snapshot,product_snapshot,draft_revision)
 values(actor,request_id,draft.source_id,draft.input,member.identity,member.onboarding,current_version,consent_ids,
  jsonb_build_object('code',product.code,'amountKrw',product.amount_krw,'uses',product.uses,'validityMonths',product.validity_months),draft.revision);
 insert into app_private.member_audit(actor_id,action) values(actor,'APPLICATION_SUBMITTED');
 return app_private.intake_get();
end $$;
