-- Avoid collisions with the implicit value column of jsonb_array_elements.
create or replace function app_private.intake_profile_save(payload jsonb, basic boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := app_private.member_actor(); data jsonb := payload->'data'; current_version text;
 expected text[]; key text; selected_item jsonb; allowed jsonb;
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
   if (select count(distinct value) from jsonb_array_elements(data->key)) <> jsonb_array_length(data->key) then raise exception 'VALIDATION_ERROR'; end if;
   for selected_item in select v from jsonb_array_elements(data->key) v loop
    if jsonb_typeof(selected_item) is distinct from 'string' then raise exception 'VALIDATION_ERROR'; end if;
    if key='mbti' then
     if (selected_item #>> '{}') !~ '^[EI][NS][FT][JP]$' then raise exception 'VALIDATION_ERROR'; end if;
    else
     select g->'options' into allowed from app_private.intake_schema s, jsonb_array_elements(s.groups) g where s.active and g->>'key'=key;
     if not exists(select 1 from jsonb_array_elements(allowed) o where o->>'id'=selected_item #>> '{}') then raise exception 'VALIDATION_ERROR'; end if;
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

create or replace function app_private.intake_draft_save(payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := app_private.member_actor(); data jsonb := payload->'input'; selected_item jsonb; source uuid;
begin
 if jsonb_typeof(payload) is distinct from 'object' or not payload ?& array['input','sourceId'] or
  (select count(*) from jsonb_object_keys(payload)) <> 2 or jsonb_typeof(data) is distinct from 'object' or
  not data ?& array['slotIds','regions','otherRegion','ticketCode'] or (select count(*) from jsonb_object_keys(data)) <> 4 then raise exception 'VALIDATION_ERROR'; end if;
 if jsonb_typeof(data->'slotIds') is distinct from 'array' or jsonb_array_length(data->'slotIds') > 30 or
  jsonb_typeof(data->'regions') is distinct from 'array' or jsonb_array_length(data->'regions') > 5 or
  jsonb_typeof(data->'otherRegion') is distinct from 'string' or length(data->>'otherRegion') > 200 or
  jsonb_typeof(data->'ticketCode') is distinct from 'string' then raise exception 'VALIDATION_ERROR'; end if;
 for selected_item in select v from jsonb_array_elements(data->'slotIds') v loop
  if jsonb_typeof(selected_item) is distinct from 'string' or not exists(select 1 from app_private.intake_event_slots where id::text=selected_item #>> '{}') then raise exception 'VALIDATION_ERROR'; end if;
 end loop;
 for selected_item in select v from jsonb_array_elements(data->'regions') v loop
  if jsonb_typeof(selected_item) is distinct from 'string' or not exists(select 1 from app_private.intake_schema s,jsonb_array_elements(s.groups) g,jsonb_array_elements(g->'options') o where s.active and g->>'key'='regions' and o->>'id'=selected_item #>> '{}') then raise exception 'VALIDATION_ERROR'; end if;
 end loop;
 if data->>'ticketCode' not in ('','single','three','use_three') then raise exception 'VALIDATION_ERROR'; end if;
 if payload->'sourceId' <> 'null'::jsonb then
  select id into source from app_private.intake_applications where user_id=actor and id::text=payload->>'sourceId';
  if source is null then raise exception 'FORBIDDEN'; end if;
 end if;
 insert into app_private.intake_drafts(user_id,input,source_id) values(actor,data,source)
  on conflict(user_id) do update set input=excluded.input,source_id=excluded.source_id,updated_at=now(), revision=case when app_private.intake_drafts.input is distinct from excluded.input or app_private.intake_drafts.source_id is distinct from excluded.source_id then gen_random_uuid() else app_private.intake_drafts.revision end;
 return app_private.intake_get();
end $$;
