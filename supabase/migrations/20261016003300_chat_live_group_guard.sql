-- Defense in depth: a malformed confirmed group cannot expose a chat.
create or replace function app_private.chat_authorize(room_uuid uuid,actor_uuid uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare member_uuid uuid;
begin
 select m.id into member_uuid from app_private.chat_members m join app_private.chat_rooms r on r.id=m.room_id
 join app_private.dining_tables t on t.id=r.table_id
 where r.id=room_uuid and r.status='OPEN' and t.status='CONFIRMED' and m.user_id=actor_uuid and m.active
 and (select count(*) from app_private.table_assignments ta where ta.table_id=t.id and ta.active) between 4 and 6
 and exists(select 1 from app_private.table_assignments ta join app_private.intake_applications a on a.id=ta.application_id
  where ta.table_id=t.id and ta.user_id=actor_uuid and ta.active and a.application_status='SUBMITTED' and a.payment_status='PAID' and a.matching_status='CONFIRMED');
 if member_uuid is null then raise exception 'FORBIDDEN';end if;
 return member_uuid;
end $$;
