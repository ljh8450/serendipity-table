begin;
update app_private.consent_documents set active=false where active;
insert into auth.users(id) values('40000000-0000-4000-8000-000000000001'),('40000000-0000-4000-8000-000000000002');
insert into app_private.consent_documents(id,kind,version,title,body,active) values
 ('41000000-0000-4000-8000-000000000001','privacy','test','TEST','TEST',true),
 ('41000000-0000-4000-8000-000000000002','operations','test','TEST','TEST',true);
insert into app_private.intake_event_slots(id,starts_at,opens_at,closes_at,region_code,region_label,published) values
 ('42000000-0000-4000-8000-000000000001',now()+interval '5 days',now()-interval '1 day',now()+interval '4 days','hongdae','TEST 홍대',true),
 ('42000000-0000-4000-8000-000000000002',now()+interval '12 days',now()-interval '1 day',now()+interval '11 days','hongdae','TEST 홍대',true),
 ('42000000-0000-4000-8000-000000000003',now()-interval '1 day',now()-interval '3 days',now()-interval '2 days','hongdae','TEST 마감',true);
set local role authenticated;
do $$ begin
 begin perform app_private.intake_get(); raise exception 'Data API invoked private command'; exception when insufficient_privilege then null; end;
end $$;
reset role;
set local role app_member_api;
select set_config('app.actor_id','40000000-0000-4000-8000-000000000001',true);
do $$ declare onboarding jsonb := '{"instagram":"fixture_only","birthYear":1995,"gender":"female","occupation":"fixture","mbti":["INTJ"],"interests":["film"],"traits":["calm"],"preferredTraits":["deep"],"mealBudgetBands":["10_20","30_plus"],"avoidedFoods":"","allergies":""}'; state jsonb; revision text; app_id text;
begin
 begin perform 1 from app_private.intake_applications; raise exception 'direct table access'; exception when insufficient_privilege then null; end;
 perform app_private.intake_profile_save('{"schemaVersion":"google-form-v1","data":{"name":"Fixture","contact":"fixture-contact"}}',true);
 state := app_private.intake_profile_save(jsonb_build_object('schemaVersion','google-form-v1','data',onboarding),false);
 if state->'onboarding'->'mealBudgetBands' <> '["10_20","30_plus"]'::jsonb then raise exception 'budget broadened'; end if;
 begin
  perform app_private.intake_profile_save(jsonb_build_object('schemaVersion','google-form-v1','data',onboarding || '{"interests":[]}'),false);
  raise exception 'missing required options accepted' using errcode='22023';
 exception when raise_exception then if sqlerrm <> 'VALIDATION_ERROR' then raise; end if; end;
 begin
  perform app_private.intake_profile_save(jsonb_build_object('schemaVersion','old','data',onboarding),false);
  raise exception 'old schema accepted' using errcode='22023';
 exception when raise_exception then if sqlerrm <> 'SCHEMA_CHANGED' then raise; end if; end;
 state := app_private.intake_draft_save('{"sourceId":null,"input":{"regions":["hongdae"],"slotIds":["42000000-0000-4000-8000-000000000001"],"otherRegion":"","ticketCode":"single_v2"}}');
 revision := state->'draft'->>'revision';
 begin
  perform app_private.intake_submit(jsonb_build_object('requestKey','43000000-0000-4000-8000-000000000001','draftRevision',revision));
  raise exception 'missing consent accepted' using errcode='22023';
 exception when raise_exception then if sqlerrm <> 'CONSENT_REQUIRED' then raise; end if; end;
 perform app_private.member_consents_accept('{"documents":[{"id":"41000000-0000-4000-8000-000000000001","version":"test"},{"id":"41000000-0000-4000-8000-000000000002","version":"test"}]}');
 state := app_private.intake_submit(jsonb_build_object('requestKey','43000000-0000-4000-8000-000000000001','draftRevision',revision));
 state := app_private.intake_submit(jsonb_build_object('requestKey','43000000-0000-4000-8000-000000000001','draftRevision',revision));
 if jsonb_array_length(state->'applications') <> 1 or state->'applications'->0->>'paymentStatus' <> 'PENDING' or state->'applications'->0->>'matchingStatus' <> 'WAITING' then raise exception 'invalid status or duplicate submit'; end if;
 app_id := state->'applications'->0->>'id';
 state := app_private.intake_profile_save('{"schemaVersion":"google-form-v1","data":{"name":"Changed current profile","contact":"fixture-contact"}}',true);
 if state->'applications'->0->'identitySnapshot'->>'name' <> 'Fixture' then raise exception 'original snapshot changed'; end if;
 begin
  perform app_private.intake_submit(jsonb_build_object('requestKey','43000000-0000-4000-8000-000000000002','draftRevision',revision));
  raise exception 'overlap accepted' using errcode='22023';
 exception when raise_exception then if sqlerrm <> 'DUPLICATE_APPLICATION' then raise; end if; end;
 state := app_private.intake_reuse(jsonb_build_object('sourceId',app_id));
 if state->'draft'->'input'->'slotIds' <> '[]'::jsonb or state->'draft'->>'sourceId' <> app_id then raise exception 'reuse failed'; end if;
 begin
  perform app_private.intake_submit(jsonb_build_object('requestKey','43000000-0000-4000-8000-000000000003','draftRevision',revision));
  raise exception 'stale draft accepted' using errcode='22023';
 exception when raise_exception then if sqlerrm <> 'DRAFT_CHANGED' then raise; end if; end;
 state := app_private.intake_draft_save('{"sourceId":null,"input":{"regions":["hongdae"],"slotIds":["42000000-0000-4000-8000-000000000003"],"otherRegion":"","ticketCode":"single_v2"}}');
 begin
  perform app_private.intake_submit(jsonb_build_object('requestKey','43000000-0000-4000-8000-000000000003','draftRevision',state->'draft'->>'revision'));
  raise exception 'closed slot accepted' using errcode='22023';
 exception when raise_exception then if sqlerrm <> 'EVENT_CLOSED' then raise; end if; end;
 state := app_private.intake_draft_save('{"sourceId":null,"input":{"regions":["hongdae"],"slotIds":["42000000-0000-4000-8000-000000000002"],"otherRegion":"","ticketCode":"use_three"}}');
 begin
  perform app_private.intake_submit(jsonb_build_object('requestKey','43000000-0000-4000-8000-000000000004','draftRevision',state->'draft'->>'revision'));
  raise exception 'unverified credit accepted' using errcode='22023';
 exception when raise_exception then if sqlerrm <> 'TICKET_UNAVAILABLE' then raise; end if; end;
 perform set_config('app.actor_id','40000000-0000-4000-8000-000000000002',true);
 if jsonb_array_length(app_private.intake_get()->'applications') <> 0 then raise exception 'other applications leaked'; end if;
 begin
  perform app_private.intake_reuse(jsonb_build_object('sourceId',app_id));
  raise exception 'other application copied' using errcode='22023';
 exception when raise_exception then if sqlerrm <> 'FORBIDDEN' then raise; end if; end;
end $$;
reset role;
rollback;
