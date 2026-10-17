-- System messages also expose a strict boolean mine flag.
create or replace function app_private.chat_get(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor();room_uuid uuid;member_uuid uuid;before_id bigint;page jsonb;has_older boolean;next_before text;
begin
 if jsonb_typeof(payload) is distinct from 'object' or not payload ?& array['roomId','before'] or (select count(*) from jsonb_object_keys(payload))<>2
 or coalesce(payload->>'roomId','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
 or not(payload->'before'='null'::jsonb or (jsonb_typeof(payload->'before')='string' and payload->>'before' ~ '^[1-9][0-9]{0,18}$')) then raise exception 'VALIDATION_ERROR';end if;
 begin before_id:=(payload->>'before')::bigint;exception when numeric_value_out_of_range then raise exception 'VALIDATION_ERROR';end;
 room_uuid:=(payload->>'roomId')::uuid;
 perform pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));
 member_uuid:=app_private.chat_authorize(room_uuid,actor);
 select count(*)>50 into has_older from (select id from app_private.chat_messages where room_id=room_uuid and (before_id is null or id<before_id) order by id desc limit 51) p;
 select coalesce(jsonb_agg(jsonb_build_object('id',p.id::text,'kind',p.kind,'body',p.body,'sentAt',p.created_at,'mine',coalesce(p.member_id=member_uuid,false),
  'sender',case when p.kind='SYSTEM' then '시스템' else '참가자 '||m.participant_no end) order by p.id),'[]'::jsonb),min(p.id)::text into page,next_before
 from (select * from app_private.chat_messages where room_id=room_uuid and (before_id is null or id<before_id) order by id desc limit 50) p left join app_private.chat_members m on m.id=p.member_id;
 return jsonb_build_object('roomId',room_uuid,'messages',page,'nextBefore',case when has_older then next_before else null end,
  'members',(select jsonb_agg(jsonb_build_object('label','참가자 '||m.participant_no,'mine',m.id=member_uuid) order by m.participant_no) from app_private.chat_members m join app_private.chat_rooms r on r.id=m.room_id where m.room_id=room_uuid and m.active and exists(select 1 from app_private.table_assignments ta where ta.table_id=r.table_id and ta.user_id=m.user_id and ta.active)));
end $$;
