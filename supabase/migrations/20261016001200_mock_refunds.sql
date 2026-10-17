-- PAY-008: full original-transaction mock refund, explicit retry and eligibility lockout.
alter table app_private.intake_applications drop constraint intake_applications_payment_status_check;
alter table app_private.intake_applications add constraint intake_applications_payment_status_check check(payment_status in ('PENDING','PAID','FAILED','REFUND_AVAILABLE','REFUND_REQUESTED','REFUND_PROCESSING','REFUNDED','REFUND_FAILED'));
create table app_private.refund_attempts (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
 application_id uuid not null references app_private.intake_applications(id),
 payment_id uuid not null references app_private.payment_attempts(id),request_key uuid not null,
 amount_krw integer not null check(amount_krw>0),outcome text not null check(outcome in ('success','failure')),
 reason text not null check(reason in ('voluntary','matching_failure')),created_at timestamptz not null default now(),unique(user_id,request_key)
);
create unique index refund_one_success on app_private.refund_attempts(payment_id) where outcome='success';
alter table app_private.refund_attempts enable row level security;
revoke all on app_private.refund_attempts from public,anon,authenticated,app_member_api;
create function app_private.mock_refund(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor(); a app_private.intake_applications%rowtype; p app_private.payment_attempts%rowtype;
 old app_private.refund_attempts%rowtype; reason text; key uuid;
begin
 if jsonb_typeof(payload) is distinct from 'object' or not payload ?& array['applicationId','requestKey','outcome'] or (select count(*) from jsonb_object_keys(payload))<>3
 or coalesce(payload->>'outcome','') not in ('success','failure') or jsonb_typeof(payload->'outcome') is distinct from 'string'
 or coalesce(payload->>'requestKey','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then raise exception 'VALIDATION_ERROR'; end if;
 key:=(payload->>'requestKey')::uuid;
 perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
 select * into a from app_private.intake_applications where id::text=payload->>'applicationId' and user_id=actor for update;
 if a.id is null then raise exception 'FORBIDDEN'; end if;
 select * into old from app_private.refund_attempts where user_id=actor and request_key=key;
 if old.id is not null then
  if old.application_id<>a.id or old.outcome<>payload->>'outcome' then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
  return app_private.intake_get();
 end if;
 if a.application_status<>'SUBMITTED' or a.payment_status not in ('PAID','REFUND_FAILED') then raise exception 'PAYMENT_CONFLICT'; end if;
 select * into p from app_private.payment_attempts where application_id=a.id and outcome='success' for update;
 if p.id is null then raise exception 'PAYMENT_CONFLICT'; end if;
 if a.membership_id is not null then
  perform 1 from app_private.memberships where id=a.membership_id for update;
  if exists(select 1 from app_private.intake_applications where membership_id=a.membership_id and id<>a.id and application_status='SUBMITTED' and payment_status='PAID') then raise exception 'MEMBERSHIP_IN_USE'; end if;
 end if;
 reason:=case when a.matching_status in ('ALTERNATIVE_OFFERED','NO_MATCH') then 'matching_failure' else 'voluntary' end;
 perform 1 from app_private.intake_event_slots where id::text in(select jsonb_array_elements_text(a.input->'slotIds')) order by id for share;
 if reason='voluntary' and a.payment_status='PAID' and exists(select 1 from app_private.intake_event_slots where a.input->'slotIds' ? id::text and now()>=coalesce(refund_cutoff_at,app_private.refund_cutoff(starts_at))) then raise exception 'REFUND_CLOSED'; end if;
 if reason='voluntary' and a.matching_status not in ('WAITING','CONFIRMED') then raise exception 'PAYMENT_CONFLICT'; end if;
 insert into app_private.refund_attempts(user_id,application_id,payment_id,request_key,amount_krw,outcome,reason) values(actor,a.id,p.id,key,p.amount_krw,payload->>'outcome',reason);
 update app_private.intake_applications set payment_status=case when payload->>'outcome'='success' then 'REFUNDED' else 'REFUND_FAILED' end,
 application_status=case when payload->>'outcome'='success' then 'CANCELED' else application_status end where id=a.id;
 if a.membership_id is not null then update app_private.memberships set active=false where id=a.membership_id; end if;
 insert into app_private.member_audit(actor_id,action) values(actor,case when payload->>'outcome'='success' then 'MOCK_REFUND_SUCCEEDED' else 'MOCK_REFUND_FAILED' end);
 return app_private.intake_get();
end $$;
revoke all on function app_private.mock_refund(jsonb) from public,anon,authenticated;
grant execute on function app_private.mock_refund(jsonb) to app_member_api;

create or replace function app_private.mock_payment(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor(); a app_private.intake_applications%rowtype; previous app_private.payment_attempts%rowtype;
 months int; expiry timestamptz; member_id uuid; key uuid;
begin
 if jsonb_typeof(payload) is distinct from 'object' or not payload ?& array['applicationId','requestKey','outcome'] or (select count(*) from jsonb_object_keys(payload))<>3
  or coalesce(payload->>'outcome','') not in ('success','failure') or jsonb_typeof(payload->'outcome') is distinct from 'string'
  or coalesce(payload->>'requestKey','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' or coalesce(payload->>'applicationId','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then raise exception 'VALIDATION_ERROR'; end if;
 key:=(payload->>'requestKey')::uuid;
 perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
 select * into a from app_private.intake_applications where id::text=payload->>'applicationId' and user_id=actor for update;
 if a.id is null then raise exception 'FORBIDDEN'; end if;
 select * into previous from app_private.payment_attempts where user_id=actor and request_key=key;
 if previous.id is not null then
  if previous.application_id<>a.id or previous.outcome<>payload->>'outcome' then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
  return app_private.intake_get();
 end if;
 if a.application_status<>'SUBMITTED' or a.payment_status not in ('PENDING','FAILED') or a.matching_status<>'WAITING' then raise exception 'PAYMENT_CONFLICT'; end if;
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
