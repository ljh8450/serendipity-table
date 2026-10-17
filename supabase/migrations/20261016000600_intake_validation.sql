-- Qualify JSON array columns separately from PL/pgSQL variables.
create or replace function app_private.intake_profile_save(payload jsonb, basic boolean) returns jsonb
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
   if (select count(distinct element.value) from jsonb_array_elements(data->key) element) <> jsonb_array_length(data->key) then raise exception 'VALIDATION_ERROR'; end if;
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
