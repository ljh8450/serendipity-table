-- FAQ-001 / PAY-004~007. Preserve existing migrations and historical snapshots.
alter table app_private.intake_ticket_products add column kind text not null default 'single' check(kind in ('single','membership','membership_use','legacy'));
alter table app_private.intake_ticket_products add column policy_version text not null default 'legacy-form-v1';
update app_private.intake_ticket_products set active=false,kind='legacy';
insert into app_private.intake_ticket_products(code,label,amount_krw,uses,validity_months,kind,policy_version) values
 ('single_v2','1회권',9900,1,null,'single','faq-v1'),
 ('membership_1','1개월 멤버십',35000,1,1,'membership','faq-v1'),
 ('membership_3','3개월 멤버십',75000,1,3,'membership','faq-v1'),
 ('membership_6','6개월 멤버십',120000,1,6,'membership','faq-v1'),
 ('membership_use','보유 멤버십 사용',0,1,null,'membership_use','faq-v1');

alter table app_private.intake_event_slots add column capacity integer not null default 24 check(capacity between 4 and 240);
alter table app_private.intake_event_slots add column matches_at timestamptz;
alter table app_private.intake_event_slots add column refund_cutoff_at timestamptz;
alter table app_private.consent_documents add column published_at timestamptz;
-- Publication is immutable through the command interface; history is never rewritten.
update app_private.consent_documents set published_at=now() where active;

create function app_private.refund_cutoff(starts timestamptz) returns timestamptz
language sql immutable set search_path='' as $$
 select (date_trunc('week',starts at time zone 'Asia/Seoul') + interval '2 days'
   - case when extract(isodow from starts at time zone 'Asia/Seoul') < 3 then interval '7 days' else interval '0 days' end) at time zone 'Asia/Seoul'
$$;

create table app_private.memberships (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
 starts_at timestamptz not null, ends_at timestamptz not null, active boolean not null default true,
 product_code text not null references app_private.intake_ticket_products(code), check(starts_at < ends_at)
);
create table app_private.payment_attempts (
 id uuid primary key default gen_random_uuid(),user_id uuid not null references auth.users(id) on delete cascade,
 application_id uuid not null references app_private.intake_applications(id),request_key uuid not null,
 outcome text not null check(outcome in ('success','failure')),amount_krw integer not null check(amount_krw>0),
 created_at timestamptz not null default now(),unique(user_id,request_key)
);
create unique index payment_one_success on app_private.payment_attempts(application_id) where outcome='success';
create table app_private.membership_extensions (
 application_id uuid primary key references app_private.intake_applications(id),
 membership_id uuid not null references app_private.memberships(id),days integer not null check(days=7),
 created_at timestamptz not null default now()
);
alter table app_private.intake_applications add column membership_id uuid references app_private.memberships(id);
alter table app_private.memberships enable row level security;
alter table app_private.payment_attempts enable row level security;
alter table app_private.membership_extensions enable row level security;
revoke all on app_private.memberships,app_private.payment_attempts,app_private.membership_extensions from public,anon,authenticated,app_member_api;

create function app_private.membership_covers(member_id uuid, slots jsonb) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.memberships m where m.id=member_id and m.active and m.starts_at<=now() and m.ends_at>now()
  and jsonb_array_length(slots)>0 and not exists(select 1 from jsonb_array_elements_text(slots) s
    where not exists(select 1 from app_private.intake_event_slots e where e.id::text=s and e.starts_at>=m.starts_at and e.starts_at<m.ends_at)))
$$;

alter function app_private.intake_get() rename to intake_get_v1;
revoke all on function app_private.intake_get_v1() from app_member_api;
create function app_private.intake_get() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor(); dto jsonb;
begin
 dto:=app_private.intake_get_v1();
 return dto || jsonb_build_object(
 'products',coalesce((select jsonb_agg(jsonb_build_object('code',p.code,'label',p.label,'amountKrw',p.amount_krw,'kind',p.kind,'validityMonths',p.validity_months,'policyVersion',p.policy_version) order by p.amount_krw) from app_private.intake_ticket_products p where p.active),'[]'::jsonb),
 'memberships',coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'startsAt',m.starts_at,'endsAt',m.ends_at,'active',m.active,'extensionDays',coalesce((select sum(x.days) from app_private.membership_extensions x where x.membership_id=m.id),0))) from app_private.memberships m where m.user_id=actor),'[]'::jsonb),
 'slots',coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'startsAt',e.starts_at,'closesAt',e.closes_at,'regionCode',e.region_code,'regionLabel',e.region_label,'matchesAt',e.matches_at,'refundCutoffAt',coalesce(e.refund_cutoff_at,app_private.refund_cutoff(e.starts_at))) order by e.starts_at) from app_private.intake_event_slots e where e.published and e.opens_at<=now() and e.closes_at>now()),'[]'::jsonb),
 'applications',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'submittedAt',a.submitted_at,'input',a.input,'identitySnapshot',a.identity_snapshot,'onboardingSnapshot',a.onboarding_snapshot,'productSnapshot',a.product_snapshot,'applicationStatus',a.application_status,'paymentStatus',a.payment_status,'matchingStatus',a.matching_status,'attendanceStatus',a.attendance_status,'eligible',a.application_status='SUBMITTED' and a.payment_status='PAID' and (a.membership_id is null or app_private.membership_covers(a.membership_id,a.input->'slotIds'))) order by a.submitted_at desc) from (select * from app_private.intake_applications where user_id=actor order by submitted_at desc limit 20) a),'[]'::jsonb));
end $$;
create or replace function app_private.intake_draft_save(payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := app_private.member_actor(); data jsonb := payload->'input'; selected_item jsonb; source uuid;
begin
 if jsonb_typeof(payload) is distinct from 'object' or not payload ?& array['input','sourceId'] or
  (select count(*) from jsonb_object_keys(payload)) <> 2 or jsonb_typeof(data) is distinct from 'object' or
  not data ?& array['slotIds','regions','otherRegion','ticketCode'] or (select count(*) from jsonb_object_keys(data)) <> 4 then raise exception 'VALIDATION_ERROR'; end if;
 if jsonb_typeof(data->'slotIds') is distinct from 'array' or jsonb_array_length(data->'slotIds') > 30 or
  jsonb_typeof(data->'regions') is distinct from 'array' or jsonb_array_length(data->'regions') > 5 or
  jsonb_typeof(data->'otherRegion') is distinct from 'string' or length(data->>'otherRegion') > 200 or
  jsonb_typeof(data->'ticketCode') is distinct from 'string' then raise exception 'VALIDATION_ERROR'; end if;
 for selected_item in select v from jsonb_array_elements(data->'slotIds') v loop
  if jsonb_typeof(selected_item) is distinct from 'string' or not exists(select 1 from app_private.intake_event_slots where id::text=selected_item #>> '{}') then raise exception 'VALIDATION_ERROR'; end if;
 end loop;
 for selected_item in select v from jsonb_array_elements(data->'regions') v loop
  if jsonb_typeof(selected_item) is distinct from 'string' or not exists(select 1 from app_private.intake_schema s,jsonb_array_elements(s.groups) g,jsonb_array_elements(g->'options') o where s.active and g->>'key'='regions' and o->>'id'=selected_item #>> '{}') then raise exception 'VALIDATION_ERROR'; end if;
 end loop;
 if data->>'ticketCode' <> '' and data->>'ticketCode' not in ('single','three','use_three') and not exists(select 1 from app_private.intake_ticket_products where code=data->>'ticketCode' and active) then raise exception 'TICKET_UNAVAILABLE'; end if;
 if payload->'sourceId' <> 'null'::jsonb then
  select id into source from app_private.intake_applications where user_id=actor and id::text=payload->>'sourceId';
  if source is null then raise exception 'FORBIDDEN'; end if;
 end if;
 insert into app_private.intake_drafts(user_id,input,source_id) values(actor,data,source)
  on conflict(user_id) do update set input=excluded.input,source_id=excluded.source_id,updated_at=now(), revision=case when app_private.intake_drafts.input is distinct from excluded.input or app_private.intake_drafts.source_id is distinct from excluded.source_id then gen_random_uuid() else app_private.intake_drafts.revision end;
 return app_private.intake_get();
end $$;

alter function app_private.intake_submit(jsonb) rename to intake_submit_v1;
revoke all on function app_private.intake_submit_v1(jsonb) from app_member_api;
create function app_private.intake_submit(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor(); draft app_private.intake_drafts%rowtype; product app_private.intake_ticket_products%rowtype;
 membership uuid; app uuid;
begin
 perform pg_advisory_xact_lock(hashtextextended('intake-publication',0));
 perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
 -- Existing request keys retain their immutable snapshot and idempotent result.
 if exists(select 1 from app_private.intake_applications where user_id=actor and request_key::text=payload->>'requestKey') then
  perform app_private.intake_submit_v1(payload); return app_private.intake_get();
 end if;
 select * into draft from app_private.intake_drafts where user_id=actor for update;
 select * into product from app_private.intake_ticket_products where code=draft.input->>'ticketCode' and active for share;
 if product.code is null then raise exception 'TICKET_UNAVAILABLE'; end if;
 if product.kind='membership_use' then
  select m.id into membership from app_private.memberships m where m.user_id=actor and app_private.membership_covers(m.id,draft.input->'slotIds') order by m.ends_at desc limit 1 for update;
  if membership is null then raise exception 'MEMBERSHIP_REQUIRED'; end if;
 end if;
 perform app_private.intake_submit_v1(payload);
 select id into app from app_private.intake_applications where user_id=actor and request_key::text=payload->>'requestKey';
 update app_private.intake_applications set product_snapshot=product_snapshot || jsonb_build_object('kind',product.kind,'policyVersion',product.policy_version),
 membership_id=membership,payment_status=case when membership is null then 'PENDING' else 'PAID' end where id=app;
 return app_private.intake_get();
end $$;

create function app_private.mock_payment(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor(); a app_private.intake_applications%rowtype; previous app_private.payment_attempts%rowtype;
 months int; expiry timestamptz; member_id uuid; key uuid;
begin
 if jsonb_typeof(payload) is distinct from 'object' or not payload ?& array['applicationId','requestKey','outcome'] or (select count(*) from jsonb_object_keys(payload))<>3
  or payload->>'outcome' not in ('success','failure') or jsonb_typeof(payload->'outcome') is distinct from 'string'
  or coalesce(payload->>'requestKey','') !~ '^[0-9a-fA-F-]{36}$' then raise exception 'VALIDATION_ERROR'; end if;
 key:=(payload->>'requestKey')::uuid;
 perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
 select * into a from app_private.intake_applications where id::text=payload->>'applicationId' and user_id=actor for update;
 if a.id is null then raise exception 'FORBIDDEN'; end if;
 select * into previous from app_private.payment_attempts where user_id=actor and request_key=key;
 if previous.id is not null then
  if previous.application_id<>a.id or previous.outcome<>payload->>'outcome' then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
  return app_private.intake_get();
 end if;
 if a.application_status<>'SUBMITTED' or a.payment_status='PAID' or a.matching_status<>'WAITING' then raise exception 'PAYMENT_CONFLICT'; end if;
 if a.product_snapshot->>'policyVersion' is distinct from 'faq-v1' or a.product_snapshot->>'kind' not in ('single','membership') then raise exception 'TICKET_UNAVAILABLE'; end if;
 perform 1 from app_private.intake_event_slots where id::text in (select jsonb_array_elements_text(a.input->'slotIds')) order by id for share;
 if exists(select 1 from jsonb_array_elements_text(a.input->'slotIds') s where not exists(select 1 from app_private.intake_event_slots e where e.id::text=s and e.published and e.closes_at>now() and e.starts_at>now())) then raise exception 'EVENT_CLOSED'; end if;
 if payload->>'outcome'='success' and a.product_snapshot->>'kind'='membership' then
  if exists(select 1 from app_private.memberships where user_id=actor and active and ends_at>now()) then raise exception 'MEMBERSHIP_ACTIVE'; end if;
  months:=(a.product_snapshot->>'validityMonths')::int;
  expiry:=((now() at time zone 'Asia/Seoul')+make_interval(months=>months)) at time zone 'Asia/Seoul';
  if exists(select 1 from app_private.intake_event_slots e where a.input->'slotIds' ? e.id::text and e.starts_at>=expiry) then raise exception 'MEMBERSHIP_REQUIRED'; end if;
  insert into app_private.memberships(user_id,starts_at,ends_at,product_code) values(actor,now(),expiry,a.product_snapshot->>'code') returning id into member_id;
 end if;
 insert into app_private.payment_attempts(user_id,application_id,request_key,outcome,amount_krw) values(actor,a.id,key,payload->>'outcome',(a.product_snapshot->>'amountKrw')::int);
 update app_private.intake_applications set payment_status=case when payload->>'outcome'='success' then 'PAID' else 'FAILED' end,membership_id=member_id where id=a.id;
 insert into app_private.member_audit(actor_id,action) values(actor,case when payload->>'outcome'='success' then 'MOCK_PAYMENT_SUCCEEDED' else 'MOCK_PAYMENT_FAILED' end);
 return app_private.intake_get();
end $$;

-- Internal matching completion command. No member or operator EXECUTE grant.
create function app_private.membership_failure_extend(app_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare a app_private.intake_applications%rowtype;
begin
 select * into a from app_private.intake_applications where id=app_id;
 if a.id is null then raise exception 'VALIDATION_ERROR'; end if;
 perform pg_advisory_xact_lock(hashtextextended(a.user_id::text,0));
 select * into a from app_private.intake_applications where id=app_id for update;
 if a.payment_status<>'PAID' or a.membership_id is null or a.matching_status not in ('ALTERNATIVE_OFFERED','NO_MATCH') then raise exception 'PAYMENT_CONFLICT'; end if;
 perform 1 from app_private.memberships where id=a.membership_id for update;
 insert into app_private.membership_extensions(application_id,membership_id,days) values(a.id,a.membership_id,7) on conflict do nothing;
 if found then
  update app_private.memberships set ends_at=ends_at+interval '7 days' where id=a.membership_id;
  insert into app_private.member_audit(actor_id,action) values(a.user_id,'MEMBERSHIP_FAILURE_EXTENDED');
 end if;
end $$;

create function app_private.operator_actor() returns uuid
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor();
begin
 if not exists(select 1 from app_private.member_accounts where user_id=actor and role='operator') then raise exception 'FORBIDDEN'; end if;
 return actor;
end $$;
create function app_private.operations_get() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor();
begin
 return jsonb_build_object('slots',coalesce((select jsonb_agg(jsonb_build_object('id',id,'startsAt',starts_at,'opensAt',opens_at,'closesAt',closes_at,'matchesAt',matches_at,'refundCutoffAt',refund_cutoff_at,'regionCode',region_code,'regionLabel',region_label,'capacity',capacity,'published',published) order by starts_at) from (select * from app_private.intake_event_slots order by starts_at desc limit 100) e),'[]'::jsonb),
 'documents',coalesce((select jsonb_agg(jsonb_build_object('id',id,'kind',kind,'version',version,'title',title,'body',body,'required',required,'active',active,'publishedAt',published_at)) from (select * from app_private.consent_documents order by published_at desc nulls last limit 100) d),'[]'::jsonb));
end $$;
create function app_private.operations_slot(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor(); starts timestamptz; closes timestamptz; opens timestamptz; matches timestamptz; cap int; slot uuid;
begin
 if jsonb_typeof(payload) is distinct from 'object' or not payload ?& array['startsAt','opensAt','closesAt','matchesAt','regionCode','capacity'] or (select count(*) from jsonb_object_keys(payload))<>6
  or coalesce(payload->>'regionCode','') not in ('hongdae','jamsil','gangnam','jongno') or coalesce(payload->>'capacity','') !~ '^[0-9]{1,3}$' then raise exception 'VALIDATION_ERROR'; end if;
 begin
  starts:=(payload->>'startsAt')::timestamptz; opens:=(payload->>'opensAt')::timestamptz; closes:=(payload->>'closesAt')::timestamptz; matches:=(payload->>'matchesAt')::timestamptz; cap:=(payload->>'capacity')::int;
 exception when others then raise exception 'VALIDATION_ERROR'; end;
 if starts is null or opens is null or closes is null or matches is null or not(opens<closes and closes<=matches and matches<starts and starts>now() and cap between 4 and 240) then raise exception 'VALIDATION_ERROR'; end if;
 perform pg_advisory_xact_lock(hashtextextended('intake-publication',0));
 insert into app_private.intake_event_slots(starts_at,opens_at,closes_at,matches_at,refund_cutoff_at,region_code,region_label,capacity,published)
 values(starts,opens,closes,matches,app_private.refund_cutoff(starts),payload->>'regionCode',case payload->>'regionCode' when 'hongdae' then '홍대' when 'jamsil' then '잠실' when 'gangnam' then '강남' else '을지로' end,cap,false) returning id into slot;
 insert into app_private.member_audit(actor_id,action) values(actor,'EVENT_DRAFT_CREATED');
 return app_private.operations_get();
end $$;
create function app_private.operations_publish(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor(); e app_private.intake_event_slots%rowtype;
begin
 if jsonb_typeof(payload) is distinct from 'object' or not payload ?& array['slotId','published'] or (select count(*) from jsonb_object_keys(payload))<>2 or jsonb_typeof(payload->'published') is distinct from 'boolean' then raise exception 'VALIDATION_ERROR'; end if;
 perform pg_advisory_xact_lock(hashtextextended('intake-publication',0));
 select * into e from app_private.intake_event_slots where id::text=payload->>'slotId' for update;
 if e.id is null or ((payload->>'published')::boolean and (e.matches_at is null or e.refund_cutoff_at is null or e.closes_at<=now())) then raise exception 'VALIDATION_ERROR'; end if;
 update app_private.intake_event_slots set published=(payload->>'published')::boolean where id=e.id;
 insert into app_private.member_audit(actor_id,action) values(actor,'EVENT_PUBLICATION_CHANGED');
 return app_private.operations_get();
end $$;
create function app_private.operations_consent(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor(); k text:=payload->>'kind';
begin
 if jsonb_typeof(payload) is distinct from 'object' or not payload ?& array['kind','version','title','body'] or (select count(*) from jsonb_object_keys(payload))<>4
  or coalesce(k,'') not in ('privacy','operations') or coalesce(length(btrim(payload->>'version')),0) not between 1 and 80
  or coalesce(length(btrim(payload->>'title')),0) not between 1 and 100 or coalesce(length(btrim(payload->>'body')),0) not between 1 and 10000
  or jsonb_typeof(payload->'body') is distinct from 'string' or jsonb_typeof(payload->'version') is distinct from 'string' or jsonb_typeof(payload->'title') is distinct from 'string' then raise exception 'VALIDATION_ERROR'; end if;
 perform pg_advisory_xact_lock(hashtextextended('intake-publication',0));
 if exists(select 1 from app_private.consent_documents where kind=k and version=payload->>'version') then raise exception 'CONSENT_CHANGED'; end if;
 update app_private.consent_documents set active=false where kind=k and active;
 insert into app_private.consent_documents(kind,version,title,body,required,active,published_at) values(k,payload->>'version',payload->>'title',payload->>'body',true,true,now());
 insert into app_private.member_audit(actor_id,action) values(actor,'CONSENT_VERSION_PUBLISHED');
 return app_private.operations_get();
end $$;
revoke all on function app_private.refund_cutoff(timestamptz) from public,anon,authenticated,app_member_api;
revoke all on function app_private.membership_covers(uuid,jsonb) from public,anon,authenticated,app_member_api;
revoke all on function app_private.intake_get() from public,anon,authenticated,app_member_api;
revoke all on function app_private.intake_submit(jsonb) from public,anon,authenticated,app_member_api;
revoke all on function app_private.mock_payment(jsonb) from public,anon,authenticated,app_member_api;
revoke all on function app_private.membership_failure_extend(uuid) from public,anon,authenticated,app_member_api;
revoke all on function app_private.operator_actor() from public,anon,authenticated,app_member_api;
revoke all on function app_private.operations_get() from public,anon,authenticated,app_member_api;
revoke all on function app_private.operations_slot(jsonb) from public,anon,authenticated,app_member_api;
revoke all on function app_private.operations_publish(jsonb) from public,anon,authenticated,app_member_api;
revoke all on function app_private.operations_consent(jsonb) from public,anon,authenticated,app_member_api;
grant execute on function app_private.intake_get() to app_member_api;
grant execute on function app_private.intake_submit(jsonb) to app_member_api;
grant execute on function app_private.mock_payment(jsonb) to app_member_api;
grant execute on function app_private.operations_get() to app_member_api;
grant execute on function app_private.operations_slot(jsonb) to app_member_api;
grant execute on function app_private.operations_publish(jsonb) to app_member_api;
grant execute on function app_private.operations_consent(jsonb) to app_member_api;
