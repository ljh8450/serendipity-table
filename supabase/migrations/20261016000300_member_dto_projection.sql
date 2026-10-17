-- Keep response fields explicit even if private profile storage grows later.
create or replace function app_private.member_get() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := app_private.member_actor(); result jsonb;
begin
  select jsonb_build_object(
    'userId', actor, 'role', a.role,
    'profile', case when p.user_id is null then null else jsonb_build_object(
      'name', p.profile->'name', 'contact', p.profile->'contact', 'birthYear', p.profile->'birthYear',
      'gender', p.profile->'gender', 'occupation', p.profile->'occupation',
      'mbti', p.profile->'mbti', 'interests', p.profile->'interests', 'traits', p.profile->'traits',
      'preferredTraits', p.profile->'preferredTraits', 'mealBudgetMin', p.profile->'mealBudgetMin',
      'mealBudgetMax', p.profile->'mealBudgetMax', 'avoidedFoods', p.profile->'avoidedFoods', 'allergies', p.profile->'allergies'
    ) end,
    'consentDocuments', coalesce((select jsonb_agg(jsonb_build_object(
      'id', d.id, 'kind', d.kind, 'version', d.version, 'title', d.title,
      'body', d.body, 'required', d.required) order by d.kind)
      from app_private.consent_documents d where d.active), '[]'::jsonb),
    'acceptedConsents', coalesce((select jsonb_agg(jsonb_build_object(
      'id', d.id, 'version', d.version)) from app_private.member_consents c
      join app_private.consent_documents d on d.id = c.document_id
      where c.user_id = actor and d.active), '[]'::jsonb)
  ) into result from app_private.member_accounts a
    left join app_private.member_profiles p on p.user_id = a.user_id where a.user_id = actor;
  return result;
end $$;

-- Lock account state while executing domain commands, serializing with restriction changes.
create or replace function app_private.member_actor() returns uuid
language plpgsql security definer set search_path = '' as $$
declare actor uuid := nullif(current_setting('app.actor_id', true), '')::uuid; is_restricted boolean;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor) then
    raise exception 'UNAUTHENTICATED' using errcode = '28000';
  end if;
  insert into app_private.member_accounts(user_id) values(actor) on conflict do nothing;
  select restricted into is_restricted from app_private.member_accounts where user_id = actor for share;
  if is_restricted then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return actor;
end $$;
