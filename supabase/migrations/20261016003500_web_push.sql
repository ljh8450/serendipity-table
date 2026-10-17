-- External delivery is at least once; ACCEPTED means provider acceptance only.
create extension if not exists pg_net with schema extensions;
create table app_private.push_config(id boolean primary key default true check(id), public_key text not null);
create table app_private.push_subscriptions(
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
 endpoint text not null unique, p256dh text not null, auth text not null, enabled boolean not null default true,
 created_at timestamptz not null default clock_timestamp()
);
create index push_subscriptions_active_user on app_private.push_subscriptions(user_id) where enabled;
create table app_private.push_jobs(
 id uuid primary key default gen_random_uuid(), notification_id uuid not null references app_private.member_notifications(id) on delete cascade,
 subscription_id uuid not null references app_private.push_subscriptions(id) on delete cascade,
 status text not null default 'PENDING' check(status in ('PENDING','RUNNING','ACCEPTED','EXCEPTION','CANCELED')),
 attempts int not null default 0, due_at timestamptz not null default clock_timestamp(), lease_until timestamptz, token uuid,
 last_error text, accepted_at timestamptz, unique(notification_id,subscription_id)
);
create index on app_private.push_jobs(status,due_at);
alter table app_private.push_config enable row level security;
alter table app_private.push_subscriptions enable row level security;
alter table app_private.push_jobs enable row level security;
create function app_private.push_endpoint_valid(endpoint text) returns boolean
language sql immutable set search_path='' as $$
 select length(endpoint) between 30 and 2048 and endpoint ~ '^https://(fcm[.]googleapis[.]com|updates[.]push[.]services[.]mozilla[.]com|web[.]push[.]apple[.]com)/[A-Za-z0-9_./:%?=&~-]+$'
$$;
create function app_private.push_get() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor();begin
 return jsonb_build_object('publicKey',(select public_key from app_private.push_config where id),'activeDevices',(select count(*) from app_private.push_subscriptions where user_id=actor and enabled));
end $$;
create function app_private.push_subscribe(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor(); sub jsonb; existing app_private.push_subscriptions;begin
 perform pg_advisory_xact_lock(hashtextextended('push-state',0));
 sub:=payload->'subscription';
 if jsonb_typeof(payload) is distinct from 'object' or (payload-'subscription')<>'{}'::jsonb or jsonb_typeof(sub) is distinct from 'object'
 or (sub-array['endpoint','keys','expirationTime'])<>'{}'::jsonb or jsonb_typeof(sub->'keys') is distinct from 'object'
 or ((sub->'keys')-array['p256dh','auth'])<>'{}'::jsonb
 or not coalesce(app_private.push_endpoint_valid(sub->>'endpoint'),false)
 or coalesce(sub->'keys'->>'p256dh','')!~'^B[A-Za-z0-9_-]{86}$' or coalesce(sub->'keys'->>'auth','')!~'^[A-Za-z0-9_-]{22}$'
 then raise exception 'VALIDATION_ERROR';end if;
 if not exists(select 1 from app_private.push_config where id) then raise exception 'PUSH_NOT_CONFIGURED';end if;
 perform pg_advisory_xact_lock(hashtextextended(sub->>'endpoint',5));
 select * into existing from app_private.push_subscriptions where endpoint=sub->>'endpoint' for update;
 if found and existing.user_id<>actor then raise exception 'FORBIDDEN';end if;
 if (existing.id is null or not existing.enabled) and (select count(*) from app_private.push_subscriptions where user_id=actor and enabled)>=10 then raise exception 'PUSH_DEVICE_LIMIT';end if;
 insert into app_private.push_subscriptions(user_id,endpoint,p256dh,auth) values(actor,sub->>'endpoint',sub->'keys'->>'p256dh',sub->'keys'->>'auth')
 on conflict(endpoint) do update set p256dh=excluded.p256dh,auth=excluded.auth,enabled=true;
 insert into app_private.member_audit(actor_id,action) values(actor,'PUSH_SUBSCRIBE');
 return jsonb_build_object('subscribed',true);
end $$;
create function app_private.push_unsubscribe(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor();begin
 perform pg_advisory_xact_lock(hashtextextended('push-state',0));
 if jsonb_typeof(payload) is distinct from 'object' or (payload-'endpoint')<>'{}'::jsonb or not coalesce(app_private.push_endpoint_valid(payload->>'endpoint'),false) then raise exception 'VALIDATION_ERROR';end if;
 update app_private.push_subscriptions set enabled=false where user_id=actor and endpoint=payload->>'endpoint';
 update app_private.push_jobs set status='CANCELED',token=null,lease_until=null where status in ('PENDING','RUNNING') and subscription_id in(select id from app_private.push_subscriptions where user_id=actor and endpoint=payload->>'endpoint');
 insert into app_private.member_audit(actor_id,action) values(actor,'PUSH_UNSUBSCRIBE');
 return jsonb_build_object('subscribed',false);
end $$;
create function app_private.push_enqueue() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 insert into app_private.push_jobs(notification_id,subscription_id) select new.id,s.id from app_private.push_subscriptions s where s.user_id=new.user_id and s.enabled on conflict do nothing;
 return new;
end $$;
create trigger notification_push after insert on app_private.member_notifications for each row execute function app_private.push_enqueue();
create role app_push_worker nologin;
grant app_push_worker to postgres;
grant usage on schema app_private to app_push_worker;
create function app_private.push_claim() returns jsonb
language plpgsql security definer set search_path='' as $$
declare j app_private.push_jobs; n app_private.member_notifications; s app_private.push_subscriptions; t uuid:=gen_random_uuid();begin
 perform pg_advisory_xact_lock(hashtextextended('push-state',0));
 perform pg_advisory_xact_lock_shared(hashtextextended('matching-state',0));
 update app_private.push_jobs set status='EXCEPTION',last_error='LEASE_EXHAUSTED',token=null where status='RUNNING' and lease_until<clock_timestamp() and attempts>=3;
 for j in select * from app_private.push_jobs where (status='PENDING' and due_at<=clock_timestamp()) or (status='RUNNING' and lease_until<clock_timestamp() and attempts<3) order by due_at,id for update skip locked limit 20 loop
  select * into n from app_private.member_notifications where id=j.notification_id;
  select * into s from app_private.push_subscriptions where id=j.subscription_id;
  if not s.enabled or not app_private.notification_visible(n,s.user_id) or not exists(select 1 from app_private.member_accounts a where a.user_id=s.user_id and not a.restricted) then
   update app_private.push_jobs set status='CANCELED',token=null where id=j.id;continue;
  end if;
  update app_private.push_jobs set status='RUNNING',attempts=attempts+1,token=t,lease_until=clock_timestamp()+interval '2 minutes' where id=j.id;
  return jsonb_build_object('id',j.id,'token',t,'notificationId',n.id,'subscription',jsonb_build_object('endpoint',s.endpoint,'keys',jsonb_build_object('p256dh',s.p256dh,'auth',s.auth)));
 end loop;return null;
end $$;
create function app_private.push_finish(job uuid, claim uuid, http_status int) returns boolean
language plpgsql security definer set search_path='' as $$
declare j app_private.push_jobs;begin
 perform pg_advisory_xact_lock(hashtextextended('push-state',0));
 select * into j from app_private.push_jobs where id=job and token=claim and status='RUNNING' and lease_until>clock_timestamp() for update;
 if not found then return false;end if;
 if http_status in (404,410) then update app_private.push_subscriptions set enabled=false where id=j.subscription_id;end if;
 update app_private.push_jobs set status=case when http_status between 200 and 299 then 'ACCEPTED'
 when http_status in(404,410) then 'CANCELED' when attempts>=3 or (http_status between 400 and 499 and http_status<>429) then 'EXCEPTION' else 'PENDING' end,
 last_error=case when http_status between 200 and 299 then null when http_status=0 then 'TRANSPORT_FAILED' else 'HTTP_'||http_status::text end,
 due_at=clock_timestamp()+interval '1 minute'*attempts,token=null,lease_until=null,
 accepted_at=case when http_status between 200 and 299 then clock_timestamp() else null end where id=job;
 return true;
end $$;
create function app_private.push_dispatch_tick() returns bigint
language plpgsql security definer set search_path='' as $$
declare target text; secret text; request_id bigint;begin
 select decrypted_secret into target from vault.decrypted_secrets where name='push_dispatch_url';
 select decrypted_secret into secret from vault.decrypted_secrets where name='push_dispatch_token';
 if target is null or secret is null or length(secret)<32 then return null;end if;
 if target !~ '^https://[a-z0-9]{20}[.]supabase[.]co/functions/v1/push-dispatch$' and target<>'http://kong:8000/functions/v1/push-dispatch' then raise exception 'PUSH_INVALID_DISPATCH_URL';end if;
 select net.http_post(url:=target,headers:=jsonb_build_object('Authorization','Bearer '||secret,'Content-Type','application/json'),body:='{}'::jsonb,timeout_milliseconds:=60000) into request_id;
 return request_id;
end $$;
revoke all on function app_private.push_endpoint_valid(text),app_private.push_get(),app_private.push_subscribe(jsonb),app_private.push_unsubscribe(jsonb),app_private.push_enqueue(),app_private.push_claim(),app_private.push_finish(uuid,uuid,int),app_private.push_dispatch_tick() from public,anon,authenticated;
grant execute on function app_private.push_get(),app_private.push_subscribe(jsonb),app_private.push_unsubscribe(jsonb) to app_member_api;
grant execute on function app_private.push_claim(),app_private.push_finish(uuid,uuid,int) to app_push_worker;
select cron.schedule('serendipity-push-dispatch','* * * * *','select app_private.push_dispatch_tick();');

-- Explicit self-test is recipient scoped, rate limited, and uses the real queue.
alter table app_private.member_notifications drop constraint member_notifications_kind_check;
alter table app_private.member_notifications add constraint member_notifications_kind_check check(kind in ('TABLE_CONFIRMED','TABLE_UPDATED','TABLE_INVALIDATED','ALTERNATIVE_OFFERED','VENUE_ASSIGNED','CHAT_MESSAGE','PUSH_TEST'));
alter function app_private.notification_visible(app_private.member_notifications,uuid) rename to notification_visible_v1;
create function app_private.notification_visible(n app_private.member_notifications, actor uuid) returns boolean
language sql stable security definer set search_path='' as $$ select case when n.kind='PUSH_TEST' then n.user_id=actor else app_private.notification_visible_v1(n,actor) end $$;
revoke all on function app_private.notification_visible(app_private.member_notifications,uuid) from public,anon,authenticated;
create function app_private.push_test() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor(); notice uuid;begin
 perform pg_advisory_xact_lock(hashtextextended(actor::text,6));
 if not exists(select 1 from app_private.push_subscriptions where user_id=actor and enabled) then raise exception 'PUSH_SUBSCRIPTION_REQUIRED';end if;
 if exists(select 1 from app_private.member_notifications where user_id=actor and kind='PUSH_TEST' and created_at>clock_timestamp()-interval '1 minute') then raise exception 'PUSH_RATE_LIMIT';end if;
 insert into app_private.member_notifications(user_id,event_key,kind) values(actor,'push-test:'||gen_random_uuid()::text,'PUSH_TEST') returning id into notice;
 return jsonb_build_object('notificationId',notice,'queued',true);
end $$;
revoke all on function app_private.push_test() from public,anon,authenticated;
grant execute on function app_private.push_test() to app_member_api;

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
   when 'PUSH_TEST' then '푸시 수신 확인을 요청했어요' when 'VENUE_ASSIGNED' then '만날 장소가 정해졌어요' else '식탁에 새 대화가 있어요' end,
  'body','나의 참가 현황에서 최신 안내를 확인해 주세요.') item
  from app_private.member_notifications n where n.user_id=actor and app_private.notification_visible(n,actor) order by n.created_at desc,n.id desc limit 50
 ) q;
 return jsonb_build_object('notifications',result,'unreadCount',unread);
end $$;

create function app_private.operations_push_get() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 perform app_private.operator_actor();
 return jsonb_build_object('counts',(select coalesce(jsonb_object_agg(status,n),'{}'::jsonb) from(select status,count(*) n from app_private.push_jobs group by status) q),
 'exceptions',(select coalesce(jsonb_agg(jsonb_build_object('jobId',id,'code',last_error,'attempts',attempts) order by due_at),'[]'::jsonb) from(select id,last_error,attempts,due_at from app_private.push_jobs where status='EXCEPTION' order by due_at,id limit 50) q));
end $$;
create function app_private.operations_push_retry(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor();target uuid;begin
 perform pg_advisory_xact_lock(hashtextextended('push-state',0));
 if jsonb_typeof(payload) is distinct from 'object' or (payload-'jobId')<>'{}'::jsonb or coalesce(payload->>'jobId','')!~'^[0-9a-fA-F-]{36}$' then raise exception 'VALIDATION_ERROR';end if;
 begin target:=(payload->>'jobId')::uuid;exception when invalid_text_representation then raise exception 'VALIDATION_ERROR';end;
 update app_private.push_jobs set status='PENDING',attempts=0,token=null,lease_until=null,due_at=clock_timestamp(),last_error=null where id=target and status='EXCEPTION';
 if not found then raise exception 'JOB_CONFLICT';end if;
 insert into app_private.member_audit(actor_id,action) values(actor,'PUSH_RETRY');
 return app_private.operations_push_get();
end $$;
revoke all on function app_private.operations_push_get(),app_private.operations_push_retry(jsonb) from public,anon,authenticated;
grant execute on function app_private.operations_push_get(),app_private.operations_push_retry(jsonb) to app_member_api;
