-- RET-003: read-only suggestions from the caller's own valid attendance and choices.
create function app_private.return_recommendations_get() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor(); source_input jsonb; items jsonb;
begin
 perform pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));
 perform pg_advisory_xact_lock(hashtextextended('attendance-state',0));
 if not app_private.safety_allowed(actor) then
  return jsonb_build_object('status','RESTRICTED','items','[]'::jsonb);
 end if;
 select a.input into source_input from app_private.table_assignments ta
 join app_private.intake_applications a on a.id=ta.application_id
 join app_private.dining_tables t on t.id=ta.table_id
 join app_private.intake_event_slots s on s.id=t.slot_id
 where ta.user_id=actor and app_private.feedback_eligible(ta.id,actor)
 order by s.starts_at desc,ta.id limit 1;
 if source_input is null then return jsonb_build_object('status','NO_HISTORY','items','[]'::jsonb);end if;
 select coalesce(jsonb_agg(q.item order by q.positive desc,q.starts_at,q.id),'[]'::jsonb) into items from (
  select s.id,s.starts_at,p.positive,jsonb_build_object('id',s.id,'startsAt',s.starts_at,'closesAt',s.closes_at,
   'regionCode',s.region_code,'regionLabel',s.region_label,
   'reason',case when p.positive then 'POSITIVE_EXPERIENCE' else 'PREVIOUS_REGION' end) item
  from app_private.intake_event_slots s
  cross join lateral (select exists(select 1 from app_private.table_assignments ta
   join app_private.dining_tables t on t.id=ta.table_id join app_private.intake_event_slots old on old.id=t.slot_id
   join app_private.event_feedback f on f.assignment_id=ta.id and f.user_id=actor
   where ta.user_id=actor and old.region_code=s.region_code and f.ratings->'revisit'='true'::jsonb
   and app_private.feedback_eligible(ta.id,actor)) positive) p
  where s.published and s.opens_at<=clock_timestamp() and s.closes_at>clock_timestamp() and s.starts_at>clock_timestamp()
   and source_input->'regions' ? s.region_code
   and not exists(select 1 from app_private.intake_applications a where a.user_id=actor and a.application_status='SUBMITTED' and a.input->'slotIds' ? s.id::text)
   and not exists(select 1 from app_private.table_assignments ta where ta.user_id=actor and ta.active
    and ta.occupied_at && tstzrange(s.starts_at,s.starts_at+make_interval(hours=>(select duration_hours from app_private.matching_policy where active)),'[)'))
  order by p.positive desc,s.starts_at,s.id limit 5
 ) q;
 return jsonb_build_object('status',case when jsonb_array_length(items)>0 then 'AVAILABLE' else 'NO_OPEN_SLOTS' end,'items',items);
end $$;
revoke all on function app_private.return_recommendations_get() from public,anon,authenticated;
grant execute on function app_private.return_recommendations_get() to app_member_api;
