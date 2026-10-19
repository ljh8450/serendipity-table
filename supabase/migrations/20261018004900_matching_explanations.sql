-- PRD 7.2: aggregates and caller-only condition evaluation, never peer preferences.
create function app_private.match_pair_met_before(a uuid,b uuid,before_at timestamptz) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from app_private.encounters where user_low=least(a,b) and user_high=greatest(a,b) and occurred_at<before_at)
 or exists(select 1 from app_private.actual_meetings where user_low=least(a,b) and user_high=greatest(a,b) and occurred_at<before_at)
$$;
revoke all on function app_private.match_pair_met_before(uuid,uuid,timestamptz) from public,anon,authenticated,app_member_api;
create function app_private.matching_explanation(application_uuid uuid,actor uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a app_private.intake_applications;t app_private.dining_tables;s app_private.intake_event_slots; result jsonb;begin
 select * into a from app_private.intake_applications where id=application_uuid and user_id=actor;
 if a.id is null then raise exception 'FORBIDDEN';end if;
 select dt.* into t from app_private.table_assignments ta join app_private.dining_tables dt on dt.id=ta.table_id
 where ta.application_id=a.id and ta.active and dt.status='CONFIRMED';
 result:=jsonb_build_object('reallocationCount',(select count(*) from app_private.allocation_attempts where application_id=a.id and reason='REALLOCATED'),
 'finalReason',(select reason from app_private.allocation_attempts where application_id=a.id order by id desc limit 1),'confirmedAt',t.created_at,'failedAt',(select max(created_at) from app_private.allocation_attempts where application_id=a.id and reason='ALTERNATIVE_OFFERED'));
 if t.id is null then return result;end if;
 select * into s from app_private.intake_event_slots where id=t.slot_id;
 with peers as(select ta.user_id,ap.input choices,row_number() over(order by ta.id) participant_no,ap.onboarding_snapshot p from app_private.table_assignments ta join app_private.intake_applications ap on ap.id=ta.application_id where ta.table_id=t.id and ta.active),
 interests as(select interest,count(distinct user_id) n from peers cross join lateral jsonb_array_elements_text(coalesce(p->'interests','[]'::jsonb)) interest group by interest having count(distinct user_id)>=2)
 select result||jsonb_build_object('ageMin',extract(year from s.starts_at at time zone 'Asia/Seoul')::int-max((p->>'birthYear')::int),
 'ageMax',extract(year from s.starts_at at time zone 'Asia/Seoul')::int-min((p->>'birthYear')::int),
 'genderComposition',(select coalesce(jsonb_object_agg(g,n),'{}') from(select p->>'gender' g,count(*) n from peers where p->>'gender' is not null group by p->>'gender') q),
 'mbtiComposition',(select coalesce(jsonb_object_agg(m,n),'{}') from(select m,count(*) n from peers cross join lateral jsonb_array_elements_text(coalesce(p->'mbti','[]'::jsonb)) m group by m) q),
 'participantConditions',(select jsonb_agg(jsonb_build_object('participantNo',participant_no,'isMe',user_id=actor,'selectedSlot',choices->'slotIds' ? s.id::text,'selectedRegion',choices->'regions' ? s.region_code) order by participant_no) from peers),
 'commonInterests',(select coalesce(jsonb_agg(interest order by n desc,interest),'[]') from interests),
 'preferredTraitsMatchedPeers',count(*) filter(where user_id<>actor and exists(select 1 from jsonb_array_elements_text(coalesce(a.onboarding_snapshot->'preferredTraits','[]'::jsonb)) x where p->'traits' ? x)),
 'peerCount',count(*) filter(where user_id<>actor),
 'previouslyMetPeers',count(*) filter(where user_id<>actor and app_private.match_pair_met_before(actor,user_id,s.starts_at)),
 'checks',jsonb_build_object('minimumScore',t.score>=(select minimum_score from app_private.matching_policy where version=coalesce(t.validation->>'policyVersion',(select policy_version from app_private.match_runs where id=t.run_id))),'size',count(*) between 4 and 6,'ageGap',max((p->>'birthYear')::int)-min((p->>'birthYear')::int)<=8,
 'selectedSlot',a.input->'slotIds' ? s.id::text,'selectedRegion',a.input->'regions' ? s.region_code,
 'exclusions',not exists(select 1 from peers x join peers y on x.user_id<y.user_id where app_private.match_pair_blocked(x.user_id,y.user_id))),
 'policyVersion',(select policy_version from app_private.match_runs where id=t.run_id)) into result from peers;
 return result;
end $$;
alter function app_private.matching_get() rename to matching_get_before_explanations;
revoke all on function app_private.matching_get_before_explanations() from app_member_api;
create function app_private.matching_get() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor();dto jsonb;begin
 perform pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));
 dto:=app_private.matching_get_before_explanations();
 return jsonb_set(dto,'{applications}',(select coalesce(jsonb_agg(item||jsonb_build_object('explanation',app_private.matching_explanation((item->>'id')::uuid,actor)) order by ordinal),'[]') from jsonb_array_elements(dto->'applications') with ordinality q(item,ordinal)));
end $$;
revoke all on function app_private.matching_explanation(uuid,uuid),app_private.matching_get() from public,anon,authenticated,app_member_api;
grant execute on function app_private.matching_get() to app_member_api;
