-- PRD11: per-slot business/exception counts, alongside the existing defined rate metrics.
create function app_private.operations_overview_counts(slot uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 with apps as(select * from app_private.intake_applications a where slot is null or a.input->'slotIds' ? slot::text
  or exists(select 1 from app_private.table_assignments ta join app_private.dining_tables t on t.id=ta.table_id where ta.application_id=a.id and t.slot_id=slot)),
 tables as(select * from app_private.dining_tables where slot is null or slot_id=slot),
 exceptions as(select * from app_private.operations_entities e where e.kind='exceptions' and (slot is null or e.slot_id=slot or e.application_id in(select id from apps)))
 select jsonb_build_object(
 'applicants',(select count(distinct user_id) from apps),'applications',(select count(*) from apps),
 'paid',(select count(*) from apps where payment_status='PAID'),
 'waiting',(select count(*) from apps where matching_status in('WAITING','MATCHING')),
 'reallocating',(select count(*) from apps where matching_status='REALLOCATING'),
 'confirmed',(select count(*) from apps where matching_status='CONFIRMED'),
 'reallocatedSucceeded',(select count(*) from apps a where a.matching_status='CONFIRMED' and exists(select 1 from app_private.allocation_attempts h where h.application_id=a.id and h.reason='REALLOCATED')),
 'failedMatching',(select count(*) from apps where matching_status in('ALTERNATIVE_OFFERED','NO_MATCH')),
 'pendingChoice',(select count(*) from apps where matching_status='ALTERNATIVE_OFFERED' and application_status='SUBMITTED' and payment_status='PAID' and not credit_stored),
 'tables',(select count(*) from tables where status='CONFIRMED'),
 'attended',(select count(*) from apps where attendance_status='ATTENDED'),
 'noShows',(select count(*) from apps where attendance_status='NO_SHOW'),
 'refunds',(select count(*) from app_private.refund_attempts where outcome='success' and application_id in(select id from apps)),
 'refundFailures',(select count(*) from apps where payment_status='REFUND_FAILED'),
 'financeFailures',(select count(*) from apps where payment_status in('FAILED','REFUND_FAILED')),
 'exceptions',(select count(*) from exceptions),
 'conditionConflicts',(select count(*) from exceptions where facts->>'domain'='matching'),
 'venueUnavailable',(select count(distinct table_id) from exceptions where facts->>'domain'='venues' and table_id in(select id from tables where status='CONFIRMED')),
 'messageFailures',(select count(*) from exceptions where facts->>'domain' in('content','push')),
 'lateCancellations',(select count(*) from apps where attendance_status='CANCELED_LATE'),
 'sameDayCancellations',(select count(distinct a.id) from apps a join app_private.match_resolutions r on r.application_id=a.id and r.action='cancel' where exists(select 1 from app_private.table_assignments ta join app_private.dining_tables t on t.id=ta.table_id join app_private.intake_event_slots es on es.id=t.slot_id where ta.application_id=a.id and (slot is null or t.slot_id=slot) and (r.created_at at time zone 'Asia/Seoul')::date=(es.starts_at at time zone 'Asia/Seoul')::date)),
 'noShowCandidates',(select count(*) from app_private.attendance_records r join app_private.table_assignments ta on ta.id=r.assignment_id join tables t on t.id=ta.table_id where ta.active and t.status='CONFIRMED' and r.review_status='PENDING'),
 'pendingReports',(select count(*) from app_private.safety_reports r join app_private.table_assignments ta on ta.id=r.assignment_id join tables t on t.id=ta.table_id where r.status='PENDING'))
$$;
create or replace function app_private.operations_overview_get() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor();begin
 insert into app_private.member_audit(actor_id,action) values(actor,'OPERATIONS_OVERVIEW');
 return jsonb_build_object('asOf',clock_timestamp(),'counts',app_private.operations_overview_counts(null),
 'slots',(select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'startsAt',s.starts_at,'regionLabel',s.region_label,'counts',app_private.operations_overview_counts(s.id)) order by s.starts_at desc,s.id),'[]') from(select * from app_private.intake_event_slots order by starts_at desc,id limit 100) s));
end $$;
revoke all on function app_private.operations_overview_counts(uuid) from public,anon,authenticated,app_member_api;
