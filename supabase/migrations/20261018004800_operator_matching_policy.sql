-- PRD 7.0/17: immutable global policies; completed runs retain their snapshots.
create function app_private.operations_policy_get() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 perform app_private.operator_actor();
 return (select jsonb_build_object('version',version,'minimumScore',minimum_score,'weights',weights) from app_private.matching_policy where active);
end $$;
create function app_private.operations_policy_save(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor(); old app_private.matching_policy; w jsonb:=payload->'weights'; score numeric; total numeric;
begin
 if jsonb_typeof(payload) is distinct from 'object' or not payload ?& array['expectedVersion','minimumScore','weights'] or (payload-array['expectedVersion','minimumScore','weights'])<>'{}'::jsonb
 or jsonb_typeof(payload->'expectedVersion') is distinct from 'string' or jsonb_typeof(payload->'minimumScore') is distinct from 'number'
 or jsonb_typeof(w) is distinct from 'object' then raise exception 'VALIDATION_ERROR';end if;
 if not w ?& array['age','gender','mbti','interests','traits'] or (w-array['age','gender','mbti','interests','traits'])<>'{}'::jsonb
 or exists(select 1 from jsonb_each(w) where jsonb_typeof(value)<>'number') then raise exception 'VALIDATION_ERROR';end if;
 select sum(value::text::numeric) into total from jsonb_each(w);
 score:=(payload->>'minimumScore')::numeric;
 if score not between 0 and 100 or total<>100 or exists(select 1 from jsonb_each(w) where value::text::numeric not between 0 and 100) then raise exception 'VALIDATION_ERROR';end if;
 perform pg_advisory_xact_lock(hashtextextended('matching-state',0));
 perform pg_advisory_xact_lock(hashtextextended('matching-policy',0));
 select * into old from app_private.matching_policy where active for update;
 if old.version is distinct from payload->>'expectedVersion' then raise exception 'JOB_CONFLICT';end if;
 if old.minimum_score=score and old.weights=w then return app_private.operations_policy_get();end if;
 update app_private.matching_policy set active=false where version=old.version;
 insert into app_private.matching_policy values('match-'||gen_random_uuid()::text,score,old.batch_size,old.beam_width,old.duration_hours,true,w);
 insert into app_private.member_audit(actor_id,action) values(actor,'MATCHING_POLICY_PUBLISH');
 return app_private.operations_policy_get();
end $$;
revoke all on function app_private.operations_policy_get(),app_private.operations_policy_save(jsonb) from public,anon,authenticated;
grant execute on function app_private.operations_policy_get(),app_private.operations_policy_save(jsonb) to app_member_api;
