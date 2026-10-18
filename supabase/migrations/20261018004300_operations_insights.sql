-- OP-02: scoped aggregates and cases; report text stays behind safety_reviewer().
create or replace function app_private.operations_insights(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor();slot uuid;tbl uuid;pg int;result jsonb;
begin
 if jsonb_typeof(payload) is distinct from 'object' or (payload-array['slotId','tableId','page'])<>'{}'::jsonb
 or not (payload ? 'slotId' or payload ? 'tableId')
 or exists(select 1 from jsonb_each(payload) x where (x.key='page' and jsonb_typeof(x.value) not in('string','number')) or (x.key<>'page' and jsonb_typeof(x.value)<>'string'))
 or coalesce(payload->>'page','0')!~'^(0|[1-9][0-9]{0,3})$' then raise exception 'VALIDATION_ERROR';end if;
 begin slot:=(payload->>'slotId')::uuid;tbl:=(payload->>'tableId')::uuid;pg:=coalesce(payload->>'page','0')::int;
 exception when invalid_text_representation then raise exception 'VALIDATION_ERROR';end;
 if (slot is not null and not exists(select 1 from app_private.intake_event_slots where id=slot))
 or (tbl is not null and not exists(select 1 from app_private.dining_tables where id=tbl and (slot is null or slot_id=slot))) then raise exception 'VALIDATION_ERROR';end if;
 with scope as (
 select a.id assignment_id,a.application_id,a.user_id,a.active,t.status table_status,s.starts_at,i.application_status,i.payment_status,i.matching_status,i.attendance_status,
 coalesce(r.review_status,'NONE') review_status,r.closed_at,t.id table_id,t.slot_id
 from app_private.table_assignments a join app_private.dining_tables t on t.id=a.table_id
 join app_private.intake_event_slots s on s.id=t.slot_id join app_private.intake_applications i on i.id=a.application_id
 left join app_private.attendance_records r on r.assignment_id=a.id
 where (slot is null or t.slot_id=slot) and (tbl is null or t.id=tbl)
 ), current_attendance as (
 select * from scope where active and table_status='CONFIRMED' and application_status='SUBMITTED' and matching_status='CONFIRMED'
 ), feedback as (
 select f.ratings from scope s join app_private.event_feedback f on f.assignment_id=s.assignment_id
 where app_private.feedback_eligible(s.assignment_id,s.user_id)
 ), cases as (
 select 'REPORT'::text case_type,r.id case_id,r.category kind,r.status,r.created_at at,s.table_id,null::uuid application_id
 from app_private.safety_reports r join scope s on s.assignment_id=r.assignment_id
 union all
 select 'ATTENDANCE',s.assignment_id,'NO_SHOW',case when s.review_status='PENDING' then 'CANDIDATE' when s.review_status='NO_SHOW' and s.attendance_status='NO_SHOW' then 'NO_SHOW' else 'CORRECTED' end,
 s.closed_at,s.table_id,s.application_id from scope s where s.review_status in('PENDING','NO_SHOW')
 or exists(select 1 from app_private.safety_actions h where h.case_type='ATTENDANCE' and h.case_id=s.assignment_id)
 union all
 select distinct 'CANCELLATION',s.application_id,'CANCELED_LATE',case when s.attendance_status='CANCELED_LATE' then 'REVIEW' else 'CORRECTED' end,
 (select max(r.created_at) from app_private.match_resolutions r where r.application_id=s.application_id and r.action='cancel'),s.table_id,s.application_id
 from scope s where s.attendance_status='CANCELED_LATE' or exists(select 1 from app_private.safety_actions h where h.case_type='CANCELLATION' and h.case_id=s.application_id)
 ), page_cases as(select * from cases order by at desc nulls last,case_type,case_id limit 25 offset pg*25)
 select jsonb_build_object('attendance',jsonb_build_object(
 'assigned',(select count(*) from current_attendance),
 'attended',(select count(*) from current_attendance where attendance_status='ATTENDED'),
 'noShowCandidates',(select count(*) from current_attendance where review_status='PENDING'),
 'confirmedNoShows',(select count(*) from current_attendance where review_status='NO_SHOW' and attendance_status='NO_SHOW'),
 'lateCancellations',(select count(distinct application_id) from scope where attendance_status='CANCELED_LATE')),
 'feedback',jsonb_build_object('eligible',(select count(*) from scope s where app_private.feedback_eligible(s.assignment_id,s.user_id)),
 'responses',(select count(*) from feedback),'atmosphere',(select avg((ratings->>'atmosphere')::numeric) from feedback),
 'conversation',(select avg((ratings->>'conversation')::numeric) from feedback),'venue',(select avg((ratings->>'venue')::numeric) from feedback),
 'revisitYes',(select count(*) from feedback where ratings->>'revisit'='true'),'recommendYes',(select count(*) from feedback where ratings->>'recommend'='true')),
 'canReviewSafety',exists(select 1 from app_private.safety_reviewers where user_id=actor),
 'cases',coalesce((select jsonb_agg(jsonb_build_object('caseType',case_type,'caseId',case_id,'kind',kind,'status',status,'at',at,'tableId',table_id,'applicationId',application_id) order by at desc nulls last,case_type,case_id) from page_cases),'[]'::jsonb),
 'page',pg,'totalCases',(select count(*) from cases),'pageSize',25) into result;
 insert into app_private.member_audit(actor_id,action) values(actor,'OPERATIONS_INSIGHTS_READ');
 return result;
end $$;
revoke all on function app_private.operations_insights(jsonb) from public,anon,authenticated,app_member_api;
grant execute on function app_private.operations_insights(jsonb) to app_member_api;
