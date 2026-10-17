begin;
insert into auth.users(id) values('60000000-0000-4000-8000-000000000001'),('60000000-0000-4000-8000-000000000002');
insert into app_private.member_accounts(user_id,role) values('60000000-0000-4000-8000-000000000001','operator'),('60000000-0000-4000-8000-000000000002','participant');
select set_config('app.actor_id','60000000-0000-4000-8000-000000000002',true);
set local role app_member_api;
do $$ begin
 begin perform app_private.operations_get(); raise exception 'participant operated' using errcode='22023'; exception when raise_exception then if sqlerrm<>'FORBIDDEN' then raise; end if; end;
 begin perform 1 from app_private.memberships; raise exception 'ledger direct access'; exception when insufficient_privilege then null; end;
 begin perform app_private.membership_failure_extend(gen_random_uuid()); raise exception 'participant extended'; exception when insufficient_privilege then null; end;
end $$;
select set_config('app.actor_id','60000000-0000-4000-8000-000000000001',true);
do $$ declare dto jsonb; slot_id text; begin
 dto:=app_private.operations_slot(jsonb_build_object('startsAt',now()+interval '10 days','opensAt',now()-interval '1 day','closesAt',now()+interval '7 days','matchesAt',now()+interval '8 days','regionCode','hongdae','capacity',24));
 select s->>'id' into slot_id from jsonb_array_elements(dto->'slots') s where (s->>'startsAt')::timestamptz=now()+interval '10 days';
 perform app_private.operations_publish(jsonb_build_object('slotId',slot_id,'published',true));
 perform app_private.operations_consent('{"kind":"privacy","version":"membership-test-v1","title":"TEST ONLY","body":"LOCAL TEST ONLY"}');
 perform app_private.operations_consent('{"kind":"operations","version":"membership-test-v1","title":"TEST ONLY","body":"LOCAL TEST ONLY"}');
 begin perform app_private.operations_consent('{"kind":"privacy","version":"membership-test-v1","title":"changed","body":"changed"}'); raise exception 'version mutated' using errcode='22023'; exception when raise_exception then if sqlerrm<>'CONSENT_CHANGED' then raise; end if; end;
end $$;
reset role;
-- Frozen fixture applications keep payment checks focused on domain transitions.
insert into app_private.intake_event_slots(id,starts_at,opens_at,closes_at,region_code,region_label,published) values
 ('62000000-0000-4000-8000-000000000001',now()+interval '5 days',now()-interval '1 day',now()+interval '4 days','hongdae','TEST',true),
 ('62000000-0000-4000-8000-000000000002',now()+interval '12 days',now()-interval '1 day',now()+interval '11 days','hongdae','TEST',true);
insert into app_private.intake_applications(id,user_id,request_key,input,identity_snapshot,onboarding_snapshot,schema_version,consent_snapshot,product_snapshot) values
 ('63000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000002',gen_random_uuid(),'{"slotIds":["62000000-0000-4000-8000-000000000001"]}','{}','{}','google-form-v1','[]','{"code":"membership_1","amountKrw":35000,"validityMonths":1,"kind":"membership","policyVersion":"faq-v1"}'),
 ('63000000-0000-4000-8000-000000000002','60000000-0000-4000-8000-000000000002',gen_random_uuid(),'{"slotIds":["62000000-0000-4000-8000-000000000002"]}','{}','{}','google-form-v1','[]','{"code":"single_v2","amountKrw":9900,"validityMonths":null,"kind":"single","policyVersion":"faq-v1"}');
select set_config('app.actor_id','60000000-0000-4000-8000-000000000002',true);
set local role app_member_api;
do $$ declare payload jsonb:='{"applicationId":"63000000-0000-4000-8000-000000000001","requestKey":"64000000-0000-4000-8000-000000000001","outcome":"failure"}'; dto jsonb; begin
 if exists(select 1 from jsonb_array_elements(app_private.intake_get()->'products') p where p->>'code' in ('single','three')) then raise exception 'old catalog active'; end if;
 begin perform app_private.mock_payment(payload || '{"outcome":null}'); raise exception 'null outcome accepted' using errcode='22023'; exception when raise_exception then if sqlerrm<>'VALIDATION_ERROR' then raise; end if; end;
 dto:=app_private.mock_payment(payload);
 dto:=app_private.mock_payment(payload);
 if jsonb_array_length(dto->'memberships')<>0 then raise exception 'failed payment granted membership'; end if;
 begin perform app_private.mock_payment(payload || '{"outcome":"success"}'); raise exception 'idempotency mutated' using errcode='22023'; exception when raise_exception then if sqlerrm<>'IDEMPOTENCY_CONFLICT' then raise; end if; end;
 begin perform app_private.mock_payment(payload || '{"amount":1}'); raise exception 'client amount accepted' using errcode='22023'; exception when raise_exception then if sqlerrm<>'VALIDATION_ERROR' then raise; end if; end;
 dto:=app_private.mock_payment(payload || '{"requestKey":"64000000-0000-4000-8000-000000000002","outcome":"success"}');
 dto:=app_private.mock_payment(payload || '{"requestKey":"64000000-0000-4000-8000-000000000002","outcome":"success"}');
 if jsonb_array_length(dto->'memberships')<>1 then raise exception 'duplicate membership'; end if;
 begin perform app_private.mock_payment(payload || '{"requestKey":"64000000-0000-4000-8000-000000000003","outcome":"success"}'); raise exception 'duplicate charge' using errcode='22023'; exception when raise_exception then if sqlerrm<>'PAYMENT_CONFLICT' then raise; end if; end;
 if not exists(select 1 from jsonb_array_elements(dto->'applications') a where a->>'id'='63000000-0000-4000-8000-000000000001' and (a->>'eligible')::boolean) then raise exception 'paid membership not eligible'; end if;
 perform set_config('app.actor_id','60000000-0000-4000-8000-000000000001',true);
 begin perform app_private.mock_payment(payload); raise exception 'other payment accessed' using errcode='22023'; exception when raise_exception then if sqlerrm<>'FORBIDDEN' then raise; end if; end;
 perform set_config('app.actor_id','60000000-0000-4000-8000-000000000002',true);
end $$;
reset role;
do $$ declare m app_private.memberships%rowtype; original timestamptz; begin
 select * into m from app_private.memberships where user_id='60000000-0000-4000-8000-000000000002';
 original:=m.ends_at;
 if (select count(*) from app_private.payment_attempts where application_id='63000000-0000-4000-8000-000000000001' and outcome='success')<>1 then raise exception 'duplicate successful charge'; end if;
 if original is distinct from ((now() at time zone 'Asia/Seoul')+interval '1 month') at time zone 'Asia/Seoul' then raise exception 'calendar month wrong'; end if;
 update app_private.intake_event_slots set starts_at=original where id='62000000-0000-4000-8000-000000000001';
 if app_private.membership_covers(m.id,'["62000000-0000-4000-8000-000000000001"]') then raise exception 'expiry inclusive'; end if;
 update app_private.intake_applications set matching_status='ALTERNATIVE_OFFERED' where id='63000000-0000-4000-8000-000000000001';
 perform app_private.membership_failure_extend('63000000-0000-4000-8000-000000000001');
 perform app_private.membership_failure_extend('63000000-0000-4000-8000-000000000001');
 if (select ends_at from app_private.memberships where id=m.id)<>original+interval '7 days' then raise exception 'extension doubled'; end if;
 if not app_private.membership_covers(m.id,'["62000000-0000-4000-8000-000000000001"]') then raise exception 'extension not usable'; end if;
 update app_private.intake_applications set membership_id=m.id,payment_status='PAID',matching_status='NO_MATCH' where id='63000000-0000-4000-8000-000000000002';
 perform app_private.membership_failure_extend('63000000-0000-4000-8000-000000000002');
 if (select ends_at from app_private.memberships where id=m.id)<>original+interval '14 days' then raise exception 'distinct failure not accumulated'; end if;
 if app_private.refund_cutoff('2026-10-17T18:00:00+09:00')<>'2026-10-14T00:00:00+09:00'::timestamptz then raise exception 'cutoff wrong'; end if;
 if app_private.refund_cutoff('2026-10-19T18:00:00+09:00')<>'2026-10-14T00:00:00+09:00'::timestamptz then raise exception 'Monday cutoff wrong'; end if;
end $$;
-- Refund attempts are capped at the original payment and retry safely after cutoff.
insert into app_private.intake_applications(id,user_id,request_key,input,identity_snapshot,onboarding_snapshot,schema_version,consent_snapshot,product_snapshot) values
 ('63000000-0000-4000-8000-000000000003','60000000-0000-4000-8000-000000000002',gen_random_uuid(),'{"slotIds":["62000000-0000-4000-8000-000000000002"]}','{}','{}','google-form-v1','[]','{"code":"single_v2","amountKrw":9900,"kind":"single","policyVersion":"faq-v1"}');
update app_private.intake_event_slots set refund_cutoff_at=now() where id='62000000-0000-4000-8000-000000000002';
set local role app_member_api;
select app_private.mock_payment('{"applicationId":"63000000-0000-4000-8000-000000000003","requestKey":"64000000-0000-4000-8000-000000000010","outcome":"success"}') is not null as paid;
do $$ begin
 begin perform app_private.mock_refund('{"applicationId":"63000000-0000-4000-8000-000000000003","requestKey":"64000000-0000-4000-8000-000000000011","outcome":"success"}'); raise exception 'cutoff inclusive refund' using errcode='22023'; exception when raise_exception then if sqlerrm<>'REFUND_CLOSED' then raise; end if; end;
 begin perform app_private.mock_refund('{"applicationId":"63000000-0000-4000-8000-000000000001","requestKey":"64000000-0000-4000-8000-000000000012","outcome":"success"}'); raise exception 'used membership refunded' using errcode='22023'; exception when raise_exception then if sqlerrm<>'MEMBERSHIP_IN_USE' then raise; end if; end;
end $$;
reset role;
update app_private.intake_event_slots set refund_cutoff_at=now()+interval '1 hour' where id='62000000-0000-4000-8000-000000000002';
update app_private.intake_applications set matching_status='CONFIRMED' where id='63000000-0000-4000-8000-000000000003';
set local role app_member_api;
do $$ begin
 begin perform app_private.mock_refund('{"applicationId":"63000000-0000-4000-8000-000000000003","requestKey":"64000000-0000-4000-8000-000000000016","outcome":"success"}'); raise exception 'confirmed table bypassed repair' using errcode='22023'; exception when raise_exception then if sqlerrm<>'PAYMENT_CONFLICT' then raise; end if; end;
end $$;
reset role;
update app_private.intake_applications set matching_status='WAITING' where id='63000000-0000-4000-8000-000000000003';
set local role app_member_api;
select app_private.mock_refund('{"applicationId":"63000000-0000-4000-8000-000000000003","requestKey":"64000000-0000-4000-8000-000000000013","outcome":"failure"}') is not null as retryable_failure;
reset role;
update app_private.intake_event_slots set refund_cutoff_at=now() where id='62000000-0000-4000-8000-000000000002';
set local role app_member_api;
do $$ declare state jsonb; payload jsonb:='{"applicationId":"63000000-0000-4000-8000-000000000003","requestKey":"64000000-0000-4000-8000-000000000014","outcome":"success"}'; begin
 state:=app_private.mock_refund(payload); state:=app_private.mock_refund(payload);
 if not exists(select 1 from jsonb_array_elements(state->'applications') a where a->>'id'='63000000-0000-4000-8000-000000000003' and a->>'paymentStatus'='REFUNDED' and a->>'applicationStatus'='CANCELED' and not (a->>'eligible')::boolean) then raise exception 'refund status/eligibility wrong'; end if;
 begin perform app_private.mock_refund(payload || '{"requestKey":"64000000-0000-4000-8000-000000000015"}'); raise exception 'double refund' using errcode='22023'; exception when raise_exception then if sqlerrm<>'PAYMENT_CONFLICT' then raise; end if; end;
end $$;
reset role;
do $$ begin
 if (select sum(amount_krw) from app_private.refund_attempts where application_id='63000000-0000-4000-8000-000000000003' and outcome='success')<>9900 then raise exception 'refund amount wrong'; end if;
end $$;
set local role authenticated;
do $$ begin begin perform app_private.mock_payment('{}'); raise exception 'Data API command access'; exception when insufficient_privilege then null; end; end $$;
reset role;
rollback;
