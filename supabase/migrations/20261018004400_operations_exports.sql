-- OP-03: one-statement, bounded export snapshot and private audit.
create table app_private.operations_exports(
 id uuid primary key default gen_random_uuid(),actor_id uuid not null,kind text not null,
 filters jsonb not null,row_count int not null,exported_at timestamptz not null default clock_timestamp());
alter table app_private.operations_exports enable row level security;
revoke all on app_private.operations_exports from public,anon,authenticated,app_member_api;
create or replace function app_private.operations_export(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor();k text;q text;st text;page_no int;target uuid;slot uuid;member uuid;tbl uuid;from_at timestamptz;to_at timestamptz;result jsonb;columns jsonb;total int;stamp timestamptz:=clock_timestamp();
begin
 -- Reuse the strict filter and scope validator; client pages cannot truncate an export.
 if payload ? 'page' or payload ? 'id' then raise exception 'VALIDATION_ERROR';end if;
 perform app_private.operations_explore(payload);
 k:=payload->>'kind';q:=coalesce(payload->>'q','');st:=coalesce(payload->>'status','');
 slot:=(payload->>'slotId')::uuid;member:=(payload->>'memberId')::uuid;tbl:=(payload->>'tableId')::uuid;from_at:=(payload->>'from')::timestamptz;to_at:=(payload->>'to')::timestamptz;
 columns:=case k
 when 'members' then '["id","label","status","role"]'::jsonb
 when 'applications' then '["id","label","memberId","applicationStatus","paymentStatus","matchingStatus","attendanceStatus","tableId","at","selectedSlotIds","selectedRegions"]'::jsonb
 when 'slots' then '["id","label","status","at","closesAt","matchesAt","capacity","tableCount","selectedApplicationCount"]'::jsonb
 when 'tables' then '["id","label","status","slotId","at","activeCount","venueName","roomStatus"]'::jsonb
 else '["id","label","status","domain","slotId","tableId","applicationId","at","attempts","reason","nextAction"]'::jsonb end;
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

 ), limited as(select * from filtered order by at desc nulls last,id,facts->>'domain' limit 5001),
 flattened as(select id,at,facts->>'domain' domain,
 jsonb_build_object('id',id,'label',label,'status',status,'memberId',member_id,'slotId',slot_id,'tableId',table_id,'applicationId',application_id,'at',at)||facts item from limited),
 rows as(select id,at,domain,(select jsonb_object_agg(c,coalesce(item->c,'null'::jsonb)) from jsonb_array_elements_text(columns)c) item from flattened)
 select jsonb_build_object('kind',k,'columns',columns,'exportedAt',stamp,
 'rows',coalesce((select jsonb_agg(item order by at desc nulls last,id,domain) from rows),'[]'::jsonb),
 'total',(select count(*) from limited)) into result;
 total:=(result->>'total')::int;
 if total>5000 then raise exception 'EXPORT_LIMIT';end if;
 insert into app_private.operations_exports(actor_id,kind,filters,row_count,exported_at) values(actor,k,payload,total,stamp);
 insert into app_private.member_audit(actor_id,action) values(actor,'OPERATIONS_EXPORT_'||upper(k));
 return result;
end $$;
revoke all on function app_private.operations_export(jsonb) from public,anon,authenticated,app_member_api;
grant execute on function app_private.operations_export(jsonb) to app_member_api;
