create role app_member_api nologin;
grant app_member_api to postgres;
grant usage on schema app_private to app_member_api;

create table app_private.member_accounts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'participant' check (role in ('participant', 'operator')),
  restricted boolean not null default false
);
create table app_private.member_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  profile jsonb not null check (jsonb_typeof(profile) = 'object'),
  updated_at timestamptz not null default now()
);
create table app_private.consent_documents (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('privacy', 'operations')),
  version text not null,
  title text not null,
  body text not null,
  required boolean not null default true,
  active boolean not null default false,
  unique(kind, version)
);
create unique index consent_current_kind on app_private.consent_documents(kind) where active;
create table app_private.member_consents (
  user_id uuid not null references auth.users(id) on delete cascade,
  document_id uuid not null references app_private.consent_documents(id),
  accepted_at timestamptz not null default now(),
  primary key(user_id, document_id)
);
create table app_private.member_audit (
  id bigint generated always as identity primary key,
  actor_id uuid not null,
  action text not null,
  occurred_at timestamptz not null default now()
);
alter table app_private.member_accounts enable row level security;
alter table app_private.member_profiles enable row level security;
alter table app_private.consent_documents enable row level security;
alter table app_private.member_consents enable row level security;
alter table app_private.member_audit enable row level security;
revoke all on app_private.member_accounts, app_private.member_profiles,
  app_private.consent_documents, app_private.member_consents, app_private.member_audit
  from public, anon, authenticated, app_member_api;

-- Actor is set only by the trusted Edge transaction, never by a request body.
create function app_private.member_actor() returns uuid
language plpgsql security definer set search_path = '' as $$
declare actor uuid := nullif(current_setting('app.actor_id', true), '')::uuid;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor) then
    raise exception 'UNAUTHENTICATED' using errcode = '28000';
  end if;
  insert into app_private.member_accounts(user_id) values(actor) on conflict do nothing;
  if (select restricted from app_private.member_accounts where user_id = actor) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return actor;
end $$;

create function app_private.member_get() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := app_private.member_actor(); result jsonb;
begin
  select jsonb_build_object(
    'userId', actor,
    'role', a.role,
    'profile', p.profile,
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

create function app_private.member_profile_save(payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := app_private.member_actor(); key text; item jsonb;
  scalar_keys text[] := array['name','contact','gender','occupation'];
  array_keys text[] := array['mbti','interests','traits','preferredTraits','avoidedFoods','allergies'];
begin
  if jsonb_typeof(payload) is distinct from 'object' or
    (select count(*) from jsonb_object_keys(payload)) <> 13 or
    not payload ?& (scalar_keys || array_keys || array['birthYear','mealBudgetMin','mealBudgetMax']) then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  foreach key in array scalar_keys loop
    if jsonb_typeof(payload->key) is distinct from 'string' or
      length(btrim(payload->>key)) not between 1 and 100 then
      raise exception 'VALIDATION_ERROR' using errcode = '22023';
    end if;
  end loop;
  foreach key in array array_keys loop
    if jsonb_typeof(payload->key) is distinct from 'array' or jsonb_array_length(payload->key) > 20 then
      raise exception 'VALIDATION_ERROR' using errcode = '22023';
    end if;
    for item in select value from jsonb_array_elements(payload->key) loop
      if jsonb_typeof(item) is distinct from 'string' or length(btrim(item #>> '{}')) not between 1 and 100 then
        raise exception 'VALIDATION_ERROR' using errcode = '22023';
      end if;
      if key = 'mbti' and (item #>> '{}') !~ '^[EI][NS][FT][JP]$' then
        raise exception 'VALIDATION_ERROR' using errcode = '22023';
      end if;
    end loop;
  end loop;
  foreach key in array array['birthYear','mealBudgetMin','mealBudgetMax'] loop
    if jsonb_typeof(payload->key) is distinct from 'number' or (payload->>key) !~ '^[0-9]{1,9}$' then
      raise exception 'VALIDATION_ERROR' using errcode = '22023';
    end if;
  end loop;
  if (payload->>'birthYear')::integer not between 1900 and extract(year from now() at time zone 'Asia/Seoul')::integer
    or (payload->>'mealBudgetMin')::integer > (payload->>'mealBudgetMax')::integer then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  insert into app_private.member_profiles(user_id, profile) values(actor, payload)
    on conflict(user_id) do update set profile = excluded.profile, updated_at = now();
  insert into app_private.member_audit(actor_id, action) values(actor, 'PROFILE_SAVED');
  return app_private.member_get();
end $$;

create function app_private.member_consents_accept(payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := app_private.member_actor(); doc jsonb; found_id uuid;
begin
  if jsonb_typeof(payload) is distinct from 'object' or not payload ? 'documents' or
    (select count(*) from jsonb_object_keys(payload)) <> 1 or
    jsonb_typeof(payload->'documents') is distinct from 'array' then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  if jsonb_array_length(payload->'documents') not between 1 and 2 then
    raise exception 'VALIDATION_ERROR' using errcode = '22023';
  end if;
  for doc in select value from jsonb_array_elements(payload->'documents') loop
    if jsonb_typeof(doc) is distinct from 'object' or not doc ?& array['id','version'] or
      (select count(*) from jsonb_object_keys(doc)) <> 2 then
      raise exception 'VALIDATION_ERROR' using errcode = '22023';
    end if;
    select id into found_id from app_private.consent_documents
      where id::text = doc->>'id' and version = doc->>'version' and active and required for share;
    if found_id is null then raise exception 'CONSENT_CHANGED' using errcode = 'P0001'; end if;
    insert into app_private.member_consents(user_id, document_id) values(actor, found_id) on conflict do nothing;
  end loop;
  insert into app_private.member_audit(actor_id, action) values(actor, 'CONSENTS_ACCEPTED');
  return app_private.member_get();
end $$;

revoke all on function app_private.member_actor(), app_private.member_get(),
  app_private.member_profile_save(jsonb), app_private.member_consents_accept(jsonb)
  from public, anon, authenticated;
grant execute on function app_private.member_get(), app_private.member_profile_save(jsonb),
  app_private.member_consents_accept(jsonb) to app_member_api;
