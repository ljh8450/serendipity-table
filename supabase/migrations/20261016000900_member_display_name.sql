alter table app_private.member_accounts add column display_name text check(display_name is null or length(display_name) between 1 and 100);
create or replace function app_private.member_get() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := app_private.member_actor(); result jsonb;
begin
  select jsonb_build_object(
    'userId', actor, 'role', a.role, 'username', a.username, 'displayName', a.display_name,
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
