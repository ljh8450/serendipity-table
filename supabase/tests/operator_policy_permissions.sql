begin;
insert into auth.users(id) values(md5('policy-op')::uuid),(md5('policy-member')::uuid);
insert into app_private.member_accounts(user_id,role) values(md5('policy-op')::uuid,'operator'),(md5('policy-member')::uuid,'participant');
set local role app_member_api;
select set_config('app.actor_id',md5('policy-member')::uuid::text,true);
do $$ begin
 begin perform app_private.operations_policy_get();raise exception 'participant allowed';exception when raise_exception then if sqlerrm<>'FORBIDDEN' then raise;end if;end;
end $$;
select set_config('app.actor_id',md5('policy-op')::uuid::text,true);
do $$ declare old jsonb;new jsonb;p jsonb;begin
 old:=app_private.operations_policy_get();
 p:=jsonb_build_object('expectedVersion',old->>'version','minimumScore',36,'weights',old->'weights');
 new:=app_private.operations_policy_save(p);
 if new->>'version'=old->>'version' or (new->>'minimumScore')::numeric<>36 then raise exception 'version not published';end if;
 begin perform app_private.operations_policy_save(p);raise exception 'stale accepted';exception when raise_exception then if sqlerrm<>'JOB_CONFLICT' then raise;end if;end;
 begin perform app_private.operations_policy_save(p||jsonb_build_object('expectedVersion',new->>'version','weights','{"age":100,"gender":100,"mbti":0,"interests":0,"traits":0}'::jsonb));raise exception 'invalid sum';exception when raise_exception then if sqlerrm<>'VALIDATION_ERROR' then raise;end if;end;
 if app_private.operations_policy_save(p||jsonb_build_object('expectedVersion',new->>'version'))<>new then raise exception 'identical update changed policy';end if;
end $$;
reset role;
do $$ begin
 if (select count(*) from app_private.matching_policy where active)<>1 or not exists(select 1 from app_private.matching_policy where version='match-v1') then raise exception 'history lost';end if;
 if not exists(select 1 from app_private.member_audit where actor_id=md5('policy-op')::uuid and action='MATCHING_POLICY_PUBLISH') then raise exception 'audit missing';end if;
end $$;
rollback;
