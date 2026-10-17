-- Do not cancel confirmed tables before their repair domain is implemented.
create or replace function app_private.mock_refund(payload jsonb) returns jsonb
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
 if reason='voluntary' and a.matching_status<>'WAITING' then raise exception 'PAYMENT_CONFLICT'; end if;
 insert into app_private.refund_attempts(user_id,application_id,payment_id,request_key,amount_krw,outcome,reason) values(actor,a.id,p.id,key,p.amount_krw,payload->>'outcome',reason);
 update app_private.intake_applications set payment_status=case when payload->>'outcome'='success' then 'REFUNDED' else 'REFUND_FAILED' end,
 application_status=case when payload->>'outcome'='success' then 'CANCELED' else application_status end where id=a.id;
 if a.membership_id is not null then update app_private.memberships set active=false where id=a.membership_id; end if;
 insert into app_private.member_audit(actor_id,action) values(actor,case when payload->>'outcome'='success' then 'MOCK_REFUND_SUCCEEDED' else 'MOCK_REFUND_FAILED' end);
 return app_private.intake_get();
end $$;
