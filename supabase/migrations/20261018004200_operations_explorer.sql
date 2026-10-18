-- OP-01: allowlisted, audited read model. No domain state transitions.
create or replace view app_private.operations_entities as
select 'members'::text kind,m.user_id id,coalesce(m.username,'회원') label,
 case when m.restricted then 'RESTRICTED' else 'ACTIVE' end status,
 m.user_id member_id,null::uuid slot_id,null::uuid table_id,null::uuid application_id,
 null::timestamptz at,
 jsonb_build_object('role',m.role) facts
from app_private.member_accounts m
union all
select 'applications',a.id,coalesce(m.username,'회원'),a.application_status,a.user_id,null,ta.table_id,a.id,a.submitted_at,
 jsonb_build_object('applicationStatus',a.application_status,'paymentStatus',a.payment_status,
 'matchingStatus',a.matching_status,'attendanceStatus',a.attendance_status,
 'selectedSlotIds',a.input->'slotIds','selectedRegions',a.input->'regions')
from app_private.intake_applications a left join app_private.member_accounts m on m.user_id=a.user_id
left join app_private.table_assignments ta on ta.application_id=a.id and ta.active
union all
select 'slots',s.id,s.region_label,case when s.published then 'PUBLISHED' else 'DRAFT' end,null,s.id,null,null,s.starts_at,
 jsonb_build_object('closesAt',s.closes_at,'matchesAt',s.matches_at,'capacity',s.capacity,
 'tableCount',(select count(*) from app_private.dining_tables t where t.slot_id=s.id),
 'selectedApplicationCount',(select count(*) from app_private.intake_applications a where a.input->'slotIds' ? s.id::text))
from app_private.intake_event_slots s
union all
select 'tables',t.id,s.region_label,t.status,null,t.slot_id,t.id,null,s.starts_at,
 jsonb_build_object('activeCount',(select count(*) from app_private.table_assignments a where a.table_id=t.id and a.active),
 'venueName',(select v.name from app_private.venue_allocations a join app_private.venue_inventory v on v.id=a.inventory_id where a.table_id=t.id and a.active),
 'roomStatus',(select r.status from app_private.chat_rooms r where r.table_id=t.id))
from app_private.dining_tables t join app_private.intake_event_slots s on s.id=t.slot_id
union all
select 'exceptions',j.id,'매칭 작업','EXCEPTION',null,j.slot_id,null,null,j.due_at,
 jsonb_build_object('domain','matching','attempts',j.attempts,'nextAction','매칭 모니터에서 현재 상태 확인 후 재시도')
from app_private.match_jobs j where j.status='EXCEPTION'
union all
select 'exceptions',r.event_id,'식당 배정','EXCEPTION',null,t.slot_id,t.id,null,r.due_at,
 jsonb_build_object('reason',case when r.last_error='VENUE_NO_COMPATIBLE_INVENTORY' then '적합한 식당 재고 없음' when r.last_error='VENUE_EVENT_STARTED' then '행사 시작으로 배정 종료' else '배정 작업 실패' end,'domain','venues','attempts',r.attempts,'nextAction','식당 재고와 적합성을 확인하고 식당 모니터에서 재시도')
from app_private.venue_receipts r join app_private.match_outbox o on o.id=r.event_id
join app_private.dining_tables t on t.id=o.aggregate_id where r.status='EXCEPTION'
union all
select 'exceptions',r.event_id,'단체방 생성','EXCEPTION',null,t.slot_id,t.id,null,r.due_at,
 jsonb_build_object('domain','chat','attempts',r.attempts,'nextAction','단체방 모니터에서 현재 배정 확인 후 재시도')
from app_private.chat_receipts r join app_private.match_outbox o on o.id=r.event_id
join app_private.dining_tables t on t.id=o.aggregate_id where r.status='EXCEPTION'
union all
select 'exceptions',j.id,'예약 안내','EXCEPTION',null,t.slot_id,t.id,null,j.due_at,
 jsonb_build_object('domain','content','attempts',j.attempts,'nextAction','예약 콘텐츠 모니터에서 장소와 기한 확인 후 재시도')
from app_private.content_jobs j join app_private.dining_tables t on t.id=j.table_id where j.status='EXCEPTION'
union all
select 'exceptions',j.id,'피드백 요청','EXCEPTION',a.user_id,t.slot_id,t.id,a.application_id,j.due_at,
 jsonb_build_object('domain','feedback','attempts',j.attempts,'nextAction','피드백 요청 모니터에서 참석과 기한 확인 후 재시도')
from app_private.feedback_jobs j join app_private.table_assignments a on a.id=j.assignment_id
join app_private.dining_tables t on t.id=a.table_id where j.status='EXCEPTION'
union all
select 'exceptions',j.id,'웹 푸시','EXCEPTION',n.user_id,t.slot_id,n.table_id,n.application_id,j.due_at,
 jsonb_build_object('domain','push','attempts',j.attempts,'nextAction','푸시 모니터에서 구독과 현재 참가 권한 확인 후 재시도')
from app_private.push_jobs j join app_private.member_notifications n on n.id=j.notification_id
left join app_private.dining_tables t on t.id=n.table_id where j.status='EXCEPTION';

revoke all on app_private.operations_entities from public,anon,authenticated,app_member_api;

create or replace function app_private.operations_explore(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor(); k text; q text; st text; page_no int;
 target uuid; slot uuid; member uuid; tbl uuid; result jsonb;from_at timestamptz;to_at timestamptz;
begin
 if jsonb_typeof(payload) is distinct from 'object' or
 exists(select 1 from jsonb_object_keys(payload) x where x not in ('kind','q','status','page','id','slotId','memberId','tableId','domain','paymentStatus','matchingStatus','attendanceStatus','from','to')) then raise exception 'VALIDATION_ERROR';end if;
 k:=payload->>'kind';q:=coalesce(payload->>'q','');st:=coalesce(payload->>'status','');
 if k is null or k not in ('members','applications','slots','tables','exceptions') or length(q)>80 or length(st)>32
 or coalesce(payload->>'page','0') !~ '^(0|[1-9][0-9]{0,3})$'
 or exists(select 1 from jsonb_each(payload) x where (x.key='page' and jsonb_typeof(x.value) not in ('string','number')) or (x.key<>'page' and jsonb_typeof(x.value)<>'string'))
 then raise exception 'VALIDATION_ERROR';end if;
 begin
 page_no:=coalesce(payload->>'page','0')::int;target:=(payload->>'id')::uuid;
 slot:=(payload->>'slotId')::uuid;member:=(payload->>'memberId')::uuid;tbl:=(payload->>'tableId')::uuid;
 from_at:=(payload->>'from')::timestamptz;to_at:=(payload->>'to')::timestamptz;
 exception when invalid_text_representation or invalid_datetime_format or datetime_field_overflow then raise exception 'VALIDATION_ERROR';end;
 if (from_at is not null and to_at is not null and from_at>=to_at) or (k='members' and (payload ? 'from' or payload ? 'to'))
 or exists(select 1 from jsonb_each_text(payload) f where f.key in('from','to') and f.value !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]{1,6})?Z$') then raise exception 'VALIDATION_ERROR';end if;
 -- Supplied scope IDs must identify real entities; never silently widen a filter.
 if (slot is not null and not exists(select 1 from app_private.intake_event_slots where id=slot))
 or (member is not null and not exists(select 1 from app_private.member_accounts where user_id=member))
 or (tbl is not null and not exists(select 1 from app_private.dining_tables where id=tbl)) then raise exception 'VALIDATION_ERROR';end if;
 with filtered as (
 select e.* from app_private.operations_entities e where e.kind=k
 and (from_at is null or e.at>=from_at) and (to_at is null or e.at<to_at)
 and (not payload ? 'domain' or e.facts->>'domain'=payload->>'domain')
 and not exists(select 1 from jsonb_each_text(payload) f where f.key in ('paymentStatus','matchingStatus','attendanceStatus') and e.facts->>f.key is distinct from f.value)
 and (target is null or e.id=target) and (st='' or e.status=st)
 and (q='' or position(lower(q) in lower(e.label||' '||e.id::text||' '||coalesce(e.member_id::text,'')))>0)
 and (member is null or e.member_id=member)
 and (tbl is null or e.table_id=tbl or (k='applications' and exists(select 1 from app_private.table_assignments a where a.table_id=tbl and a.application_id=e.id)))
 and (slot is null or e.slot_id=slot or (k='applications' and e.facts->'selectedSlotIds' ? slot::text))
 ), paged as (select * from filtered order by at desc nulls last,id,facts->>'domain' limit 25 offset page_no*25)
 select jsonb_build_object('items',coalesce((select jsonb_agg(jsonb_build_object('kind',kind,'id',id,'label',label,'status',status,
 'memberId',member_id,'slotId',slot_id,'tableId',table_id,'applicationId',application_id,'at',at,'facts',facts)
 order by at desc nulls last,id,facts->>'domain') from paged),'[]'::jsonb),
 'page',page_no,'total',(select count(*) from filtered),'pageSize',25) into result;
 if target is not null and (result->>'total')::int=0 then raise exception 'VALIDATION_ERROR';end if;
 insert into app_private.member_audit(actor_id,action) values(actor,'OPERATIONS_EXPLORE_'||upper(k));
 return result;
end $$;
revoke all on function app_private.operations_explore(jsonb) from public,anon,authenticated,app_member_api;
grant execute on function app_private.operations_explore(jsonb) to app_member_api;
