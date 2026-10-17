-- INF-05/07/08 and CON-01..03. DB time, never a caller-supplied clock.
create table app_private.content_jobs(
 id uuid primary key default gen_random_uuid(),table_id uuid not null references app_private.dining_tables(id) on delete cascade,
 kind text not null check(kind in('GUIDE','D1','START')),revision text not null default 'v1',
 scheduled_at timestamptz not null,due_at timestamptz not null,
 status text not null default 'WAITING' check(status in('WAITING','DONE','EXCEPTION','CANCELED')),
 attempts int not null default 0,last_error text,finished_at timestamptz,snapshot jsonb,
 unique(table_id,kind,revision)
);
create index on app_private.content_jobs(status,due_at);
alter table app_private.content_jobs enable row level security;
revoke all on app_private.content_jobs from public,anon,authenticated,app_member_api;

create function app_private.content_location_revision(table_uuid uuid) returns text
language plpgsql stable security definer set search_path='' as $$
declare a app_private.venue_allocations;v app_private.venue_inventory;begin
 select * into a from app_private.venue_allocations where table_id=table_uuid order by created_at desc,id desc limit 1;
 if a.id is null then return 'pending';end if;
 select * into v from app_private.venue_inventory where id=a.inventory_id;
 return a.id::text||case when a.active and app_private.venue_compatible(v,table_uuid) then ':ready' else ':withdrawn' end;
end $$;
create function app_private.content_topics(table_uuid uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare topics jsonb:='[]';item record;topic text;deep_n int;calm_n int;energy_n int;game text;begin
 for item in select interest,count(distinct ta.user_id) n from app_private.table_assignments ta
 join app_private.intake_applications a on a.id=ta.application_id
 cross join lateral jsonb_array_elements_text(case when jsonb_typeof(a.onboarding_snapshot->'interests')='array' then a.onboarding_snapshot->'interests' else '[]'::jsonb end) interest
 where ta.table_id=table_uuid and ta.active group by interest having count(distinct ta.user_id)>=2 order by n desc,interest limit 3 loop
  topic:=case item.interest when 'film' then '최근 본 영화나 드라마에서 기억에 남은 장면은 무엇인가요?'
   when 'music' then '요즘 자주 듣는 노래와 그 노래를 듣기 좋은 순간을 소개해 주세요.'
   when 'books' then '다른 사람에게 소개하고 싶은 책이나 문장 하나가 있나요?'
   when 'exercise' then '즐겨 하는 운동이나 가볍게 시작해 보고 싶은 활동은 무엇인가요?'
   when 'food' then '다시 가고 싶은 식당이나 함께 나누고 싶은 음식은 무엇인가요?'
   when 'travel' then '다시 가고 싶은 여행지와 그곳에서의 작은 기억을 나눠 주세요.'
   when 'photo' then '최근 남긴 사진 중 설명하고 싶은 순간은 무엇인가요?'
   when 'art' then '기억에 남는 전시나 작품이 있나요? 편하게 소개해 주세요.'
   when 'fashion' then '나를 편안하게 해 주는 옷이나 물건 하나를 소개해 주세요.'
   when 'study' then '최근 새롭게 배우거나 궁금해진 것은 무엇인가요?' else null end;
  if topic is not null then topics:=topics||jsonb_build_array(topic);end if;
 end loop;
 foreach topic in array array['최근 일상에서 작지만 기분 좋았던 순간은 무엇인가요?','여유로운 하루가 생기면 무엇을 하고 싶나요?','올해 가볍게 시도해 보고 싶은 일 한 가지를 소개해 주세요.'] loop
  exit when jsonb_array_length(topics)>=3;topics:=topics||jsonb_build_array(topic);
 end loop;
 select count(*) filter(where a.onboarding_snapshot->'traits' ? 'deep'),
 count(*) filter(where a.onboarding_snapshot->'traits' ?| array['calm','listener']),
 count(*) filter(where a.onboarding_snapshot->'traits' ?| array['energetic','humor']) into deep_n,calm_n,energy_n
 from app_private.table_assignments ta join app_private.intake_applications a on a.id=ta.application_id where ta.table_id=table_uuid and ta.active;
 if deep_n>=2 then select jsonb_agg(value||' 원한다면 그 이유도 들려주세요.' order by ordinal) into topics from jsonb_array_elements_text(topics) with ordinality q(value,ordinal);end if;
 game:=case when calm_n>=energy_n then '한 문장 소개: 차례대로 오늘의 기분과 최근의 작은 즐거움을 한 문장씩 나눠요. 듣기만 하거나 패스해도 좋아요.'
 else '가벼운 취향 선택: 산책과 카페, 바다와 숲 중 오늘 끌리는 쪽을 고르고 짧게 이유를 나눠요. 정답은 없고 패스해도 좋아요.' end;
 return jsonb_build_object('templateVersion','conversation-v1','topics',topics,'game',game,'curation',case when calm_n>=energy_n then '차분하게 한 사람씩 근황을 나누며 관심이 가는 이야기를 이어가는 식탁을 제안해요.' else '가벼운 취향 선택으로 시작하고 관심이 가는 이야기를 자유롭게 이어가는 식탁을 제안해요.' end);
end $$;

create function app_private.content_apply(job_uuid uuid) returns void
language plpgsql security definer set search_path='' as $$
declare j app_private.content_jobs;t app_private.dining_tables;s app_private.intake_event_slots;r app_private.chat_rooms;
 v app_private.venue_inventory;u record;messages jsonb:='[]';content jsonb;body text;ordinal int:=0;cutoff timestamptz;kind text;begin
 select * into j from app_private.content_jobs where id=job_uuid;
 select * into t from app_private.dining_tables where id=j.table_id;
 select * into s from app_private.intake_event_slots where id=t.slot_id;
 if t.status is distinct from 'CONFIRMED' then raise exception 'CONTENT_STALE';end if;
 if clock_timestamp()<j.scheduled_at or (j.kind='START' and clock_timestamp()<s.starts_at) or (j.kind='D1' and clock_timestamp()<s.starts_at-interval '24 hours') then raise exception 'CONTENT_EARLY';end if;
 if clock_timestamp()>=s.starts_at+(case when j.kind='D1' then interval '0' else interval '3 hours' end) then raise exception 'CONTENT_MISSED_WINDOW';end if;
 if j.kind='GUIDE' and j.revision<>app_private.content_location_revision(t.id) then raise exception 'CONTENT_STALE';end if;
 select * into r from app_private.chat_rooms where table_id=t.id and status='OPEN';
 if r.id is null then raise exception 'CONTENT_ROOM_PENDING';end if;
 if exists(select 1 from app_private.table_assignments ta left join app_private.member_accounts ma on ma.user_id=ta.user_id where ta.table_id=t.id and ta.active and ma.user_id is null) then raise exception 'CONTENT_STALE';end if;
 if (select count(*) from app_private.table_assignments where table_id=t.id and active) not between 4 and 6 then raise exception 'CONTENT_STALE';end if;
 for u in select ta.user_id,a.application_status,a.payment_status,a.matching_status,ma.restricted from app_private.table_assignments ta
 join app_private.intake_applications a on a.id=ta.application_id join app_private.member_accounts ma on ma.user_id=ta.user_id where ta.table_id=t.id and ta.active loop
  if u.restricted or u.application_status<>'SUBMITTED' or u.payment_status<>'PAID' or u.matching_status<>'CONFIRMED' then raise exception 'CONTENT_STALE';end if;
  perform app_private.chat_authorize(r.id,u.user_id);
 end loop;
 if j.kind='START' then
  content:=app_private.content_topics(t.id);
  for body in select value from jsonb_array_elements_text(content->'topics') loop ordinal:=ordinal+1;messages:=messages||jsonb_build_array('대화 주제 '||ordinal::text||': '||body);end loop;
  messages:=messages||jsonb_build_array('선택 게임: '||(content->>'game'));kind:='EVENT_CONTENT';
 else
  select vi.* into v from app_private.venue_allocations va join app_private.venue_inventory vi on vi.id=va.inventory_id
   where va.table_id=t.id and va.active and app_private.venue_compatible(vi,t.id);
  if j.kind='D1' and v.id is null then raise exception 'CONTENT_VENUE_PENDING';end if;
  cutoff:=coalesce(s.refund_cutoff_at,app_private.refund_cutoff(s.starts_at));
  messages:=jsonb_build_array(case when j.kind='D1' then '다가오는 식탁 안내' else '최신 식탁 안내' end||': '||to_char(s.starts_at at time zone 'Asia/Seoul','YYYY.MM.DD HH24:MI')||' (서울) · '||s.region_label||'. 게시 시점 정보이며 장소 변경 시 최신 공지와 참가 현황을 확인해 주세요.');
  if v.id is null then messages:=messages||jsonb_build_array('기존 장소가 회수됐거나 장소를 준비하고 있어요. 확정 전 방문하지 말고 최신 참가 현황을 확인해 주세요.');
  else messages:=messages||jsonb_build_array('식당: '||v.name,'주소: '||v.address,'예약명: '||v.reservation_name||' · 식사 가격 '||v.meal_price_krw::text||'원. 지도는 참가 현황에서 확인해 주세요.');end if;
  messages:=messages||jsonb_build_array('취소·환불: 자발 취소 환불은 '||to_char(cutoff at time zone 'Asia/Seoul','YYYY.MM.DD HH24:MI')||' (서울) 정각부터 불가해요. 행사 당일 취소는 제한되며 매칭 실패 해결은 별도 안내를 따라 주세요. 서로 원하는 만큼 소개하고 대화하며, 시작 시각에 대화 주제와 선택 게임이 게시돼요.');
  if j.kind='GUIDE' then messages:=messages||jsonb_build_array('식탁 이야기 방향: '||(app_private.content_topics(t.id)->>'curation')||' 소개와 답변은 원하는 만큼만 나눠도 좋아요.');end if;
  content:=jsonb_build_object('templateVersion','guide-v1','allocationRevision',app_private.content_location_revision(t.id));kind:=case when j.kind='D1' then 'EVENT_REMINDER' else 'EVENT_GUIDE' end;
 end if;
 ordinal:=0;
 for body in select value from jsonb_array_elements_text(messages) loop
  ordinal:=ordinal+1;insert into app_private.chat_messages(room_id,system_key,kind,body) values(r.id,'content:'||j.id::text||':'||ordinal::text,'SYSTEM',body) on conflict(room_id,system_key) do nothing;
 end loop;
 insert into app_private.member_notifications(user_id,event_key,kind,table_id,application_id)
  select ta.user_id,'content:'||j.id::text,kind,t.id,ta.application_id from app_private.table_assignments ta where ta.table_id=t.id and ta.active on conflict do nothing;
 update app_private.content_jobs set snapshot=content||jsonb_build_object('messages',messages),status='DONE',finished_at=clock_timestamp(),last_error=null where id=j.id;
end $$;
create function app_private.content_tick() returns int
language plpgsql security definer set search_path='' as $$
declare work record;processed int:=0;code text;begin
 if not pg_try_advisory_xact_lock(hashtextextended('content-tick',0)) then return 0;end if;
 perform pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));
 insert into app_private.content_jobs(table_id,kind,scheduled_at,due_at)
  select t.id,k.kind,s.starts_at-k.offset_time,s.starts_at-k.offset_time from app_private.dining_tables t join app_private.intake_event_slots s on s.id=t.slot_id
  cross join(values('D1',interval '24 hours'),('START',interval '0')) k(kind,offset_time) where t.status='CONFIRMED' on conflict do nothing;
 insert into app_private.content_jobs(table_id,kind,revision,scheduled_at,due_at)
  select t.id,'GUIDE',app_private.content_location_revision(t.id),clock_timestamp(),clock_timestamp() from app_private.dining_tables t join app_private.intake_event_slots s on s.id=t.slot_id
  where t.status='CONFIRMED' and s.starts_at+interval '3 hours'>clock_timestamp() on conflict do nothing;
 update app_private.content_jobs j set status='CANCELED',last_error='CONTENT_STALE' where status in('WAITING','EXCEPTION') and (not exists(select 1 from app_private.dining_tables t where t.id=j.table_id and t.status='CONFIRMED') or (j.kind='GUIDE' and j.revision<>app_private.content_location_revision(j.table_id)));
 for work in select id from app_private.content_jobs where status='WAITING' and due_at<=clock_timestamp() order by due_at,id for update skip locked limit 20 loop
  begin
   perform app_private.content_apply(work.id);
   update app_private.content_jobs set attempts=attempts+1 where id=work.id;
  exception when others then
   code:=case when sqlerrm in('CONTENT_STALE','CONTENT_EARLY','CONTENT_MISSED_WINDOW','CONTENT_ROOM_PENDING','CONTENT_VENUE_PENDING') then sqlerrm else 'CONTENT_EXECUTION_FAILED' end;
   update app_private.content_jobs set attempts=attempts+1,last_error=code,status=case when code='CONTENT_STALE' then 'CANCELED' when code='CONTENT_MISSED_WINDOW' or attempts>=2 then 'EXCEPTION' else 'WAITING' end,due_at=clock_timestamp()+interval '1 minute' where id=work.id;
  end;processed:=processed+1;
 end loop;return processed;
end $$;
create function app_private.operations_content_get() returns jsonb
language plpgsql security definer set search_path='' as $$
begin perform app_private.operator_actor();
 return jsonb_build_object('jobs',(select coalesce(jsonb_agg(jsonb_build_object('jobId',j.id,'kind',j.kind,'status',j.status,'attempts',j.attempts,'code',j.last_error,'scheduledAt',j.scheduled_at,'startsAt',s.starts_at,'regionLabel',s.region_label,
 'retryable',j.status='EXCEPTION' and t.status='CONFIRMED' and clock_timestamp()<s.starts_at+(case when j.kind='D1' then interval '0' else interval '3 hours' end)) order by (j.status='EXCEPTION') desc,j.due_at desc,j.id),'[]'::jsonb)
 from(select * from app_private.content_jobs order by (status='EXCEPTION') desc,due_at desc,id limit 100) j join app_private.dining_tables t on t.id=j.table_id join app_private.intake_event_slots s on s.id=t.slot_id));end $$;
create function app_private.operations_content_retry(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor();target uuid;begin
 if jsonb_typeof(payload) is distinct from 'object' or (payload-'jobId')<>'{}'::jsonb or coalesce(payload->>'jobId','')!~'^[0-9a-fA-F-]{36}$' then raise exception 'VALIDATION_ERROR';end if;
 begin target:=(payload->>'jobId')::uuid;exception when invalid_text_representation then raise exception 'VALIDATION_ERROR';end;
 perform pg_advisory_xact_lock(hashtextextended('content-tick',0));
 update app_private.content_jobs j set status='WAITING',attempts=0,last_error=null,due_at=clock_timestamp() from app_private.dining_tables t join app_private.intake_event_slots s on s.id=t.slot_id
 where j.id=target and j.table_id=t.id and j.status='EXCEPTION' and t.status='CONFIRMED' and clock_timestamp()<s.starts_at+(case when j.kind='D1' then interval '0' else interval '3 hours' end);
 if not found then raise exception 'JOB_CONFLICT';end if;
 insert into app_private.member_audit(actor_id,action) values(actor,'CONTENT_RETRY');return app_private.operations_content_get();end $$;

alter table app_private.member_notifications drop constraint member_notifications_kind_check;
alter table app_private.member_notifications add constraint member_notifications_kind_check check(kind in('TABLE_CONFIRMED','TABLE_UPDATED','TABLE_INVALIDATED','ALTERNATIVE_OFFERED','VENUE_ASSIGNED','CHAT_MESSAGE','PUSH_TEST','EVENT_GUIDE','EVENT_REMINDER','EVENT_CONTENT'));
revoke all on function app_private.content_location_revision(uuid),app_private.content_topics(uuid),app_private.content_apply(uuid),app_private.content_tick(),app_private.operations_content_get(),app_private.operations_content_retry(jsonb) from public,anon,authenticated;
grant execute on function app_private.operations_content_get(),app_private.operations_content_retry(jsonb) to app_member_api;
select cron.schedule('serendipity-content-tick','* * * * *','select app_private.content_tick();');

create or replace function app_private.notifications_get() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor(); result jsonb; unread bigint;
begin
 perform pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));
 select count(*) into unread from app_private.member_notifications n where n.user_id=actor and n.read_at is null and app_private.notification_visible(n,actor);
 select coalesce(jsonb_agg(item order by created_at desc,id desc),'[]'::jsonb) into result from (
  select n.created_at,n.id,jsonb_build_object('id',n.id,'kind',n.kind,'createdAt',n.created_at,'read',n.read_at is not null,
  'title',case n.kind when 'TABLE_CONFIRMED' then '식탁이 확정됐어요' when 'TABLE_UPDATED' then '식탁 안내가 변경됐어요'
   when 'TABLE_INVALIDATED' then '식탁을 다시 준비하고 있어요' when 'ALTERNATIVE_OFFERED' then '다음 참가 방법을 선택해 주세요'
   when 'EVENT_REMINDER' then '식탁 준비 안내가 도착했어요' when 'EVENT_CONTENT' then '대화 주제와 게임을 확인해 주세요' when 'EVENT_GUIDE' then '최신 식탁 공지를 확인해 주세요' when 'PUSH_TEST' then '푸시 수신 확인을 요청했어요' when 'VENUE_ASSIGNED' then '만날 장소가 정해졌어요' else '식탁에 새 대화가 있어요' end,
  'body','나의 참가 현황에서 최신 안내를 확인해 주세요.') item
  from app_private.member_notifications n where n.user_id=actor and app_private.notification_visible(n,actor) order by n.created_at desc,n.id desc limit 50
 ) q;
 return jsonb_build_object('notifications',result,'unreadCount',unread);
end $$;

