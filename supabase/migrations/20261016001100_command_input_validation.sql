-- Tighten malformed command input before any cast or mutation.
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
create or replace function app_private.operations_slot(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor(); starts timestamptz; closes timestamptz; opens timestamptz; matches timestamptz; cap int; slot uuid;
begin
 if jsonb_typeof(payload) is distinct from 'object' or not payload ?& array['startsAt','opensAt','closesAt','matchesAt','regionCode','capacity'] or (select count(*) from jsonb_object_keys(payload))<>6
  or coalesce(payload->>'regionCode','') not in ('hongdae','jamsil','gangnam','jongno') or coalesce(payload->>'capacity','') !~ '^[0-9]{1,3}$' then raise exception 'VALIDATION_ERROR'; end if;
 if exists(select 1 from unnest(array['startsAt','opensAt','closesAt','matchesAt']) k where jsonb_typeof(payload->k) is distinct from 'string' or payload->>k !~ '(Z|[+-][0-9]{2}:[0-9]{2})$') then raise exception 'VALIDATION_ERROR'; end if;
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
