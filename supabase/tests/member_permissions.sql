begin;
update app_private.consent_documents set active = false where active;
insert into auth.users(id) values
 ('10000000-0000-4000-8000-000000000001'),
 ('10000000-0000-4000-8000-000000000002'),
 ('10000000-0000-4000-8000-000000000003');
insert into app_private.member_accounts(user_id, restricted) values('10000000-0000-4000-8000-000000000003', true);
insert into app_private.member_accounts(user_id, role) values('10000000-0000-4000-8000-000000000002', 'operator');
insert into app_private.consent_documents(id, kind, version, title, body, active) values
 ('20000000-0000-4000-8000-000000000001', 'privacy', 'test-v1', 'TEST ONLY', 'Not a real policy', true);

set local role authenticated;
do $$ begin
  begin perform app_private.member_get(); raise exception 'authenticated invoked private API';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
set local role anon;
do $$ begin
  begin perform app_private.member_get(); raise exception 'anon invoked private API';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
set local role app_member_api;
do $$ begin
  begin perform app_private.member_get(); raise exception 'missing actor accepted';
  exception when invalid_authorization_specification then null; end;
  begin perform 1 from app_private.member_profiles; raise exception 'direct table read allowed';
  exception when insufficient_privilege then null; end;
  begin update app_private.member_accounts set role = 'operator'; raise exception 'role mutation allowed';
  exception when insufficient_privilege then null; end;
end $$;
select set_config('app.actor_id', '10000000-0000-4000-8000-000000000001', true);
do $$ declare profile jsonb := '{"name":"Fixture","contact":"test-contact","birthYear":1995,"gender":"test","occupation":"test","mbti":["INTJ"],"interests":["food"],"traits":[],"preferredTraits":[],"mealBudgetMin":10000,"mealBudgetMax":30000,"avoidedFoods":[],"allergies":[]}'; dto jsonb;
begin
  dto := app_private.member_profile_save(profile);
  if dto->>'role' <> 'participant' or dto->'profile'->>'name' <> 'Fixture' then raise exception 'wrong profile DTO'; end if;
  begin perform app_private.member_profile_save(profile || '{"role":"operator"}'); raise exception 'unknown fields accepted';
  exception when invalid_parameter_value then null; end;
  begin perform app_private.member_profile_save(profile || '{"birthYear":9999}'); raise exception 'future year accepted';
  exception when invalid_parameter_value then null; end;
  begin perform app_private.member_profile_save(profile || '{"mealBudgetMin":40000}'); raise exception 'invalid budget accepted';
  exception when invalid_parameter_value then null; end;
  perform app_private.member_consents_accept('{"documents":[{"id":"20000000-0000-4000-8000-000000000001","version":"test-v1"}]}');
  perform app_private.member_consents_accept('{"documents":[{"id":"20000000-0000-4000-8000-000000000001","version":"test-v1"}]}');
  if jsonb_array_length(app_private.member_get()->'acceptedConsents') <> 1 then raise exception 'duplicate consent'; end if;
  begin
    perform app_private.member_consents_accept('{"documents":[{"id":"20000000-0000-4000-8000-000000000001","version":"old"}]}');
    raise exception 'old consent accepted' using errcode = '22023';
  exception when raise_exception then
    if sqlerrm <> 'CONSENT_CHANGED' then raise; end if;
  end;
end $$;
select set_config('app.actor_id', '10000000-0000-4000-8000-000000000002', true);
do $$ begin
  if app_private.member_get()->>'role' <> 'operator' then raise exception 'server operator role missing'; end if;
  if app_private.member_get()->'profile' <> 'null'::jsonb then raise exception 'other profile leaked'; end if;
  if jsonb_array_length(app_private.member_get()->'acceptedConsents') <> 0 then raise exception 'other consent leaked'; end if;
end $$;
select set_config('app.actor_id', '10000000-0000-4000-8000-000000000003', true);
do $$ begin
  begin perform app_private.member_get(); raise exception 'restricted actor accepted';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
update app_private.member_profiles set profile = profile || '{"privateInternalField":"hidden"}'
  where user_id = '10000000-0000-4000-8000-000000000001';
set local role app_member_api;
select set_config('app.actor_id', '10000000-0000-4000-8000-000000000001', true);
do $$ begin
  if app_private.member_get()->'profile' ? 'privateInternalField' then raise exception 'internal field exposed'; end if;
end $$;
reset role;
do $$ begin
  if (select count(*) from app_private.member_consents where user_id = '10000000-0000-4000-8000-000000000001') <> 1 then raise exception 'consent not idempotent'; end if;
end $$;
rollback;
