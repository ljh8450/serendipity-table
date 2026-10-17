-- FORM-001 source options. No Google response data or operational event fixtures.
create table app_private.intake_schema (
  version text primary key,
  groups jsonb not null,
  active boolean not null default false
);
create unique index intake_schema_current on app_private.intake_schema(active) where active;
insert into app_private.intake_schema(version, groups, active) values ('google-form-v1', '[
 {"key":"gender","label":"성별","multiple":false,"options":[{"id":"male","label":"남"},{"id":"female","label":"여"}]},
 {"key":"interests","label":"나의 요즘 관심사는?","multiple":true,"options":[{"id":"film","label":"영화·드라마"},{"id":"music","label":"음악"},{"id":"books","label":"독서·글쓰기"},{"id":"exercise","label":"운동 (헬스, 러닝, 클라이밍 등)"},{"id":"food","label":"맛집·카페 탐방"},{"id":"travel","label":"여행"},{"id":"photo","label":"사진·영상"},{"id":"art","label":"전시·공연·아트"},{"id":"fashion","label":"패션·뷰티"},{"id":"study","label":"자기계발·공부"}]},
 {"key":"traits","label":"나는 어떤 사람인가요?","multiple":true,"options":[{"id":"calm","label":"잔잔하고 조용한 편"},{"id":"energetic","label":"활기차고 에너지 있는 편"},{"id":"deep","label":"깊은 대화를 좋아함"},{"id":"humor","label":"가볍고 유머 있는 대화를 좋아함"},{"id":"listener","label":"경청을 잘 함"},{"id":"leader","label":"이야기를 이끄는 편"}]},
 {"key":"preferredTraits","label":"어떤 사람을 만나고 싶으신가요?","multiple":true,"options":[{"id":"similar","label":"나와 비슷한 사람"},{"id":"different","label":"나와 다른 자극을 주는 사람"},{"id":"deep","label":"깊은 대화가 되는 사람"},{"id":"humor","label":"편하고 유머 있는 사람"},{"id":"passionate","label":"열정 있는 사람"},{"id":"calm","label":"잔잔하고 안정적인 사람"}]},
 {"key":"mealBudgetBands","label":"식사에 얼마까지 쓸 수 있으신가요?","multiple":true,"options":[{"id":"10_20","label":"10,000~20,000원"},{"id":"20_30","label":"20,000~30,000원"},{"id":"30_plus","label":"30,000원 이상 (상관 없음)"}]},
 {"key":"regions","label":"참석 가능 지역","multiple":true,"options":[{"id":"hongdae","label":"홍대/합정"},{"id":"jamsil","label":"잠실"},{"id":"gangnam","label":"강남/신논현"},{"id":"jongno","label":"을지로/종로"},{"id":"other","label":"기타"}]}
]', true);

create table app_private.intake_members (
 user_id uuid primary key references auth.users(id) on delete cascade,
 identity jsonb,
 onboarding jsonb,
 schema_version text references app_private.intake_schema(version),
 updated_at timestamptz not null default now()
);
create table app_private.intake_event_slots (
 id uuid primary key default gen_random_uuid(),
 starts_at timestamptz not null,
 closes_at timestamptz not null,
 opens_at timestamptz not null,
 region_code text not null,
 region_label text not null,
 published boolean not null default false,
 check(opens_at < closes_at and closes_at <= starts_at)
);
create table app_private.intake_ticket_products (
 code text primary key,
 label text not null,
 amount_krw integer not null check(amount_krw >= 0),
 uses integer not null check(uses > 0),
 validity_months integer,
 active boolean not null default true
);
insert into app_private.intake_ticket_products(code,label,amount_krw,uses,validity_months) values
 ('single','1회권',8000,1,null), ('three','선불 3회권',15000,3,2);
create table app_private.intake_applications (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 request_key uuid not null,
 source_id uuid references app_private.intake_applications(id),
 input jsonb not null,
 identity_snapshot jsonb not null,
 onboarding_snapshot jsonb not null,
 schema_version text not null references app_private.intake_schema(version),
 consent_snapshot jsonb not null,
 product_snapshot jsonb not null,
 application_status text not null default 'SUBMITTED' check(application_status in ('SUBMITTED','CANCELED')),
 payment_status text not null default 'PENDING' check(payment_status in ('PENDING','PAID','FAILED')),
 matching_status text not null default 'WAITING' check(matching_status in ('WAITING','MATCHING','REALLOCATING','CONFIRMED','ALTERNATIVE_OFFERED','TRANSFERRED','NO_MATCH','EXCEPTION')),
 attendance_status text not null default 'SCHEDULED' check(attendance_status in ('SCHEDULED','ATTENDED','CANCELED_EARLY','CANCELED_LATE','NO_SHOW')),
 submitted_at timestamptz not null default now(),
 unique(user_id,request_key)
);
create table app_private.intake_drafts (
 user_id uuid primary key references auth.users(id) on delete cascade,
 input jsonb not null,
 source_id uuid references app_private.intake_applications(id),
 updated_at timestamptz not null default now()
);
alter table app_private.intake_schema enable row level security;
alter table app_private.intake_members enable row level security;
alter table app_private.intake_event_slots enable row level security;
alter table app_private.intake_ticket_products enable row level security;
alter table app_private.intake_applications enable row level security;
alter table app_private.intake_drafts enable row level security;
revoke all on app_private.intake_schema,app_private.intake_members,app_private.intake_event_slots,
 app_private.intake_ticket_products,app_private.intake_applications,app_private.intake_drafts from public,anon,authenticated,app_member_api;

create function app_private.intake_get() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := app_private.member_actor(); result jsonb;
begin
 select jsonb_build_object(
  'schemaVersion',s.version,'groups',s.groups,
  'identity',m.identity,'onboarding',m.onboarding,'savedSchemaVersion',m.schema_version,
  'draft',case when d.user_id is null then null else jsonb_build_object('input',d.input,'sourceId',d.source_id) end,
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

-- Reject unknown fields and stale schemas, including direct DB command calls.
create function app_private.intake_profile_save(payload jsonb, basic boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := app_private.member_actor(); data jsonb := payload->'data'; current_version text;
 expected text[]; key text; value jsonb; allowed jsonb;
begin
 select version into current_version from app_private.intake_schema where active for share;
 if payload->>'schemaVersion' is distinct from current_version then raise exception 'SCHEMA_CHANGED'; end if;
 if jsonb_typeof(payload) is distinct from 'object' or not payload ?& array['schemaVersion','data'] or
  (select count(*) from jsonb_object_keys(payload)) <> 2 or jsonb_typeof(data) is distinct from 'object' then raise exception 'VALIDATION_ERROR'; end if;
 expected := case when basic then array['name','contact'] else array['instagram','birthYear','gender','occupation','mbti','interests','traits','preferredTraits','mealBudgetBands','avoidedFoods','allergies'] end;
 if not data ?& expected or (select count(*) from jsonb_object_keys(data)) <> cardinality(expected) then raise exception 'VALIDATION_ERROR'; end if;
 foreach key in array case when basic then array['name','contact'] else array['instagram','gender','occupation','avoidedFoods','allergies'] end loop
  if jsonb_typeof(data->key) is distinct from 'string' or length(data->>key) > 500 or
   (key not in ('avoidedFoods','allergies') and length(btrim(data->>key))=0) then raise exception 'VALIDATION_ERROR'; end if;
 end loop;
 if not basic then
  if jsonb_typeof(data->'birthYear') is distinct from 'number' or (data->>'birthYear') !~ '^[0-9]{4}$' or
   (data->>'birthYear')::int not between 1900 and extract(year from now() at time zone 'Asia/Seoul')::int then raise exception 'VALIDATION_ERROR'; end if;
  if data->>'gender' not in ('male','female') then raise exception 'VALIDATION_ERROR'; end if;
  foreach key in array array['mbti','interests','traits','preferredTraits','mealBudgetBands'] loop
   if jsonb_typeof(data->key) is distinct from 'array' or jsonb_array_length(data->key) not between 1 and 16 then raise exception 'VALIDATION_ERROR'; end if;
   if (select count(distinct value) from jsonb_array_elements(data->key)) <> jsonb_array_length(data->key) then raise exception 'VALIDATION_ERROR'; end if;
   for value in select v from jsonb_array_elements(data->key) v loop
    if jsonb_typeof(value) is distinct from 'string' then raise exception 'VALIDATION_ERROR'; end if;
    if key='mbti' then
     if (value #>> '{}') !~ '^[EI][NS][FT][JP]$' then raise exception 'VALIDATION_ERROR'; end if;
    else
     select g->'options' into allowed from app_private.intake_schema s, jsonb_array_elements(s.groups) g where s.active and g->>'key'=key;
     if not exists(select 1 from jsonb_array_elements(allowed) o where o->>'id'=value #>> '{}') then raise exception 'VALIDATION_ERROR'; end if;
    end if;
   end loop;
  end loop;
 end if;
 if basic then
  insert into app_private.intake_members(user_id,identity) values(actor,data) on conflict(user_id) do update set identity=excluded.identity,updated_at=now();
 else
  insert into app_private.intake_members(user_id,onboarding,schema_version) values(actor,data,current_version)
   on conflict(user_id) do update set onboarding=excluded.onboarding,schema_version=excluded.schema_version,updated_at=now();
 end if;
 insert into app_private.member_audit(actor_id,action) values(actor,case when basic then 'IDENTITY_SAVED' else 'ONBOARDING_SAVED' end);
 return app_private.intake_get();
end $$;

create function app_private.intake_draft_save(payload jsonb) returns jsonb
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
  on conflict(user_id) do update set input=excluded.input,source_id=excluded.source_id,updated_at=now();
 return app_private.intake_get();
end $$;

create function app_private.intake_reuse(payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := app_private.member_actor(); source app_private.intake_applications%rowtype;
begin
 if jsonb_typeof(payload) is distinct from 'object' or not payload ? 'sourceId' or
  (select count(*) from jsonb_object_keys(payload)) <> 1 then raise exception 'VALIDATION_ERROR'; end if;
 select * into source from app_private.intake_applications where user_id=actor and id::text=payload->>'sourceId';
 if source.id is null then raise exception 'FORBIDDEN'; end if;
 -- Require explicit new event choices; never copy payment, matching, attendance or request key.
 return app_private.intake_draft_save(jsonb_build_object('sourceId',source.id,'input',source.input || '{"slotIds":[]}'::jsonb));
end $$;

create function app_private.intake_submit(payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := app_private.member_actor(); draft app_private.intake_drafts%rowtype;
 member app_private.intake_members%rowtype; product app_private.intake_ticket_products%rowtype;
 current_version text; consent_ids jsonb; request_id uuid; previous app_private.intake_applications%rowtype;
begin
 if jsonb_typeof(payload) is distinct from 'object' or not payload ? 'requestKey' or
  (select count(*) from jsonb_object_keys(payload)) <> 1 or (payload->>'requestKey') !~ '^[0-9a-fA-F-]{36}$' then raise exception 'VALIDATION_ERROR'; end if;
 request_id := (payload->>'requestKey')::uuid;
 perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
 select * into draft from app_private.intake_drafts where user_id=actor for update;
 select * into previous from app_private.intake_applications where user_id=actor and request_key=request_id;
 if previous.id is not null then
  if draft.input is distinct from previous.input or draft.source_id is distinct from previous.source_id then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
  return app_private.intake_get();
 end if;
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
 insert into app_private.intake_applications(user_id,request_key,source_id,input,identity_snapshot,onboarding_snapshot,schema_version,consent_snapshot,product_snapshot)
 values(actor,request_id,draft.source_id,draft.input,member.identity,member.onboarding,current_version,consent_ids,
  jsonb_build_object('code',product.code,'amountKrw',product.amount_krw,'uses',product.uses,'validityMonths',product.validity_months));
 insert into app_private.member_audit(actor_id,action) values(actor,'APPLICATION_SUBMITTED');
 return app_private.intake_get();
end $$;

revoke all on function app_private.intake_get(),app_private.intake_profile_save(jsonb,boolean),app_private.intake_draft_save(jsonb),app_private.intake_reuse(jsonb),app_private.intake_submit(jsonb) from public,anon,authenticated;
grant execute on function app_private.intake_get(),app_private.intake_profile_save(jsonb,boolean),app_private.intake_draft_save(jsonb),app_private.intake_reuse(jsonb),app_private.intake_submit(jsonb) to app_member_api;
