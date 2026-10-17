-- INF-004: preverified reservation units and a dedicated, idempotent consumer.
create table app_private.venue_inventory (
 id uuid primary key default gen_random_uuid(),request_key uuid not null,user_id uuid not null references auth.users(id),
 slot_id uuid not null references app_private.intake_event_slots(id) on delete cascade,
 name text not null,address text not null,map_url text not null,reservation_name text not null,
 meal_price_krw int not null check(meal_price_krw between 10000 and 1000000),seats int not null check(seats between 4 and 6),
 rating numeric not null check(rating between 4 and 5),review_count int not null check(review_count>=20),review_url text not null,
 verified_at timestamptz not null,reservation_valid_until timestamptz not null,
 safe_allergies jsonb not null,safe_avoided_foods jsonb not null,verification_note text not null,
 input jsonb not null,enabled boolean not null default true,created_at timestamptz not null default clock_timestamp(),
 unique(user_id,request_key),unique(slot_id,name,address,reservation_name)
);
create table app_private.venue_allocations (
 id uuid primary key default gen_random_uuid(),table_id uuid not null references app_private.dining_tables(id) on delete cascade,
 inventory_id uuid not null references app_private.venue_inventory(id),active boolean not null default true,
 created_at timestamptz not null default clock_timestamp(),released_at timestamptz
);
create unique index venue_one_table on app_private.venue_allocations(table_id) where active;
create unique index venue_one_reservation on app_private.venue_allocations(inventory_id) where active;
create table app_private.venue_receipts (
 event_id uuid primary key references app_private.match_outbox(id) on delete cascade,
 status text not null default 'QUEUED' check(status in ('QUEUED','DONE','EXCEPTION')),
 attempts int not null default 0,due_at timestamptz not null default clock_timestamp(),last_error text,finished_at timestamptz
);
do $$ declare n text;begin
 foreach n in array array['venue_inventory','venue_allocations','venue_receipts'] loop
 execute format('alter table app_private.%I enable row level security',n);
 execute format('revoke all on app_private.%I from public,anon,authenticated,app_member_api',n);end loop;
end $$;

create function app_private.venue_text(value text) returns text language sql immutable set search_path='' as $$
 select lower(regexp_replace(btrim(value),'\s+',' ','g'))
$$;
create function app_private.venue_diet_safe(constraint_value jsonb,approved jsonb) returns boolean
language sql immutable set search_path='' as $$
 select jsonb_typeof(constraint_value)='string' and app_private.venue_text(constraint_value#>>'{}') not in ('모름','미확인','unknown')
 and (app_private.venue_text(constraint_value#>>'{}') in ('','없음','해당 없음','없어요')
 or exists(select 1 from jsonb_array_elements_text(approved) a where app_private.venue_text(a)=app_private.venue_text(constraint_value#>>'{}')))
$$;
create function app_private.venue_compatible(inv app_private.venue_inventory,table_uuid uuid) returns boolean
language plpgsql stable security definer set search_path='' as $$
declare profile jsonb; size int;
begin
 select count(*) into size from app_private.table_assignments where table_id=table_uuid and active;
 if size not between 4 and 6 or size>inv.seats or not inv.enabled then return false;end if;
 for profile in select a.onboarding_snapshot from app_private.table_assignments ta join app_private.intake_applications a on a.id=ta.application_id where ta.table_id=table_uuid and ta.active loop
  if jsonb_typeof(profile->'mealBudgetBands') is distinct from 'array' then return false;end if;
  if not exists(select 1 from jsonb_array_elements_text(profile->'mealBudgetBands') b where
   (b='10_20' and inv.meal_price_krw between 10000 and 20000) or (b='20_30' and inv.meal_price_krw between 20000 and 30000) or (b='30_plus' and inv.meal_price_krw>=30000)) then return false;end if;
  if not coalesce(app_private.venue_diet_safe(profile->'allergies',inv.safe_allergies),false)
   or not coalesce(app_private.venue_diet_safe(profile->'avoidedFoods',inv.safe_avoided_foods),false) then return false;end if;
 end loop;
 return true;
end $$;

create function app_private.venue_wake(slot_uuid uuid) returns void
language sql security definer set search_path='' as $$
 update app_private.venue_receipts r set status='QUEUED',attempts=0,due_at=clock_timestamp(),last_error=null,finished_at=null
 from app_private.match_outbox o join app_private.dining_tables t on t.id=o.aggregate_id
 where r.event_id=o.id and t.slot_id=slot_uuid
$$;
create function app_private.venue_apply(table_uuid uuid) returns text
language plpgsql security definer set search_path='' as $$
declare t app_private.dining_tables%rowtype; inv app_private.venue_inventory%rowtype; current_inv uuid;
begin
 select * into t from app_private.dining_tables where id=table_uuid for update;
 if t.id is null or t.status<>'CONFIRMED' then
  update app_private.venue_allocations set active=false,released_at=clock_timestamp() where table_id=table_uuid and active;return null;
 end if;
 select inventory_id into current_inv from app_private.venue_allocations where table_id=t.id and active;
 if current_inv is not null then
  select * into inv from app_private.venue_inventory where id=current_inv for update;
  if app_private.venue_compatible(inv,t.id) then return null;end if;
  update app_private.venue_allocations set active=false,released_at=clock_timestamp() where table_id=t.id and active;
 end if;
 if (select starts_at from app_private.intake_event_slots where id=t.slot_id)<=clock_timestamp() then return 'VENUE_EVENT_STARTED';end if;
 for inv in select * from app_private.venue_inventory v where v.slot_id=t.slot_id and v.enabled
  and v.verified_at>=clock_timestamp()-interval '7 days' and v.verified_at<=clock_timestamp()
  and v.reservation_valid_until>(select starts_at from app_private.intake_event_slots where id=t.slot_id)
  and not exists(select 1 from app_private.venue_allocations va where va.inventory_id=v.id and va.active)
  order by v.rating desc,v.review_count desc,v.id for update loop
  if app_private.venue_compatible(inv,t.id) then
   insert into app_private.venue_allocations(table_id,inventory_id) values(t.id,inv.id);
   insert into app_private.member_audit(actor_id,action) values('00000000-0000-0000-0000-000000000000','VENUE_AUTO_ALLOCATED');return null;
  end if;
 end loop;
 return 'VENUE_NO_COMPATIBLE_INVENTORY';
end $$;

create function app_private.venue_tick() returns int
language plpgsql security definer set search_path='' as $$
declare event record; code text; processed int:=0;
begin
 if not pg_try_advisory_xact_lock(hashtextextended('venue-tick',0)) then return 0;end if;
 perform pg_advisory_xact_lock(hashtextextended('matching-state',0));
 insert into app_private.venue_receipts(event_id) select id from app_private.match_outbox where event_type in ('TABLE_CONFIRMED','TABLE_UPDATED','TABLE_INVALIDATED') on conflict do nothing;
 for event in select r.event_id,o.aggregate_id from app_private.venue_receipts r join app_private.match_outbox o on o.id=r.event_id where r.status='QUEUED' and r.due_at<=clock_timestamp() order by o.created_at,o.id for update of r skip locked limit 20 loop
  begin
   code:=app_private.venue_apply(event.aggregate_id);
   if code is not null then
    update app_private.venue_receipts set attempts=attempts+1,status=case when attempts>=2 then 'EXCEPTION' else 'QUEUED' end,last_error=code,due_at=clock_timestamp()+interval '1 minute' where event_id=event.event_id;
   else
   update app_private.venue_receipts set status='DONE',attempts=attempts+1,last_error=null,finished_at=clock_timestamp() where event_id=event.event_id;
   end if;
  exception when others then
   code:=case when sqlerrm in ('VENUE_NO_COMPATIBLE_INVENTORY','VENUE_EVENT_STARTED') then sqlerrm else 'VENUE_EXECUTION_FAILED' end;
   update app_private.venue_receipts set attempts=attempts+1,status=case when attempts>=2 then 'EXCEPTION' else 'QUEUED' end,last_error=code,due_at=clock_timestamp()+interval '1 minute' where event_id=event.event_id;
  end;
  processed:=processed+1;
 end loop;
 return processed;
end $$;
select cron.schedule('serendipity-venue-tick','* * * * *','select app_private.venue_tick();');

create function app_private.operations_venues_get() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor();
begin
 return jsonb_build_object('slots',coalesce((select jsonb_agg(jsonb_build_object('id',id,'startsAt',starts_at,'regionLabel',region_label)) from (select * from app_private.intake_event_slots where published and starts_at>clock_timestamp() order by starts_at limit 100) e),'[]'::jsonb),
 'inventory',coalesce((select jsonb_agg(jsonb_build_object('id',v.id,'slotId',v.slot_id,'name',v.name,'address',v.address,'reservationName',v.reservation_name,'mealPriceKrw',v.meal_price_krw,'seats',v.seats,'rating',v.rating,'reviewCount',v.review_count,'reviewUrl',v.review_url,'verifiedAt',v.verified_at,'validUntil',v.reservation_valid_until,'enabled',v.enabled,'allocated',exists(select 1 from app_private.venue_allocations where inventory_id=v.id and active))) from (select * from app_private.venue_inventory order by created_at desc limit 100) v),'[]'::jsonb),
 'exceptions',coalesce((select jsonb_agg(jsonb_build_object('eventId',r.event_id,'tableId',o.aggregate_id,'code',r.last_error,'status',r.status,'attempts',r.attempts)) from app_private.venue_receipts r join app_private.match_outbox o on o.id=r.event_id where r.last_error is not null),'[]'::jsonb));
end $$;
create function app_private.operations_venue_create(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor(); e app_private.intake_event_slots%rowtype; old app_private.venue_inventory%rowtype; k uuid; v jsonb; verified timestamptz; expiry timestamptz;
begin
 if jsonb_typeof(payload) is distinct from 'object' or not payload ?& array['requestKey','slotId','name','address','mapUrl','reservationName','mealPriceKrw','seats','rating','reviewCount','reviewUrl','verifiedAt','reservationValidUntil','safeAllergies','safeAvoidedFoods','verificationNote','reservationConfirmed'] or (select count(*) from jsonb_object_keys(payload))<>17 then raise exception 'VALIDATION_ERROR';end if;
 if coalesce(payload->>'requestKey','') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' or payload->'reservationConfirmed' is distinct from 'true'::jsonb then raise exception 'VALIDATION_ERROR';end if;
 for v in select payload->x from unnest(array['name','address','reservationName','verificationNote']) x loop
  if jsonb_typeof(v) is distinct from 'string' or length(btrim(v#>>'{}')) not between 1 and 500 then raise exception 'VALIDATION_ERROR';end if;
 end loop;
 if coalesce(payload->>'mapUrl','') !~ '^https://[^\s]+$' or coalesce(payload->>'reviewUrl','') !~ '^https://[^\s]+$' or length(payload->>'mapUrl')>1500 or length(payload->>'reviewUrl')>1500 then raise exception 'VALIDATION_ERROR';end if;
 if jsonb_typeof(payload->'mealPriceKrw') is distinct from 'number' or coalesce(payload->>'mealPriceKrw','') !~ '^[0-9]{1,7}$' or (payload->>'mealPriceKrw')::int not between 10000 and 1000000
 or jsonb_typeof(payload->'seats') is distinct from 'number' or coalesce(payload->>'seats','') !~ '^[4-6]$'
 or jsonb_typeof(payload->'rating') is distinct from 'number' or (payload->>'rating')::numeric not between 4 and 5
 or jsonb_typeof(payload->'reviewCount') is distinct from 'number' or coalesce(payload->>'reviewCount','') !~ '^[0-9]{1,7}$' or (payload->>'reviewCount')::int<20 then raise exception 'VALIDATION_ERROR';end if;
 for v in select payload->x from unnest(array['safeAllergies','safeAvoidedFoods']) x loop
  if jsonb_typeof(v) is distinct from 'array' or jsonb_array_length(v)>30 then raise exception 'VALIDATION_ERROR';end if;
  if exists(select 1 from jsonb_array_elements(v) x where jsonb_typeof(x)<>'string' or length(btrim(x#>>'{}')) not between 1 and 500) then raise exception 'VALIDATION_ERROR';end if;
 end loop;
 if coalesce(payload->>'verifiedAt','') !~ '(Z|[+-][0-9]{2}:[0-9]{2})$' or coalesce(payload->>'reservationValidUntil','') !~ '(Z|[+-][0-9]{2}:[0-9]{2})$' then raise exception 'VALIDATION_ERROR';end if;
 begin verified:=(payload->>'verifiedAt')::timestamptz;expiry:=(payload->>'reservationValidUntil')::timestamptz;exception when others then raise exception 'VALIDATION_ERROR';end;
 k:=(payload->>'requestKey')::uuid;
 perform pg_advisory_xact_lock(hashtextextended('matching-state',0));
 select * into old from app_private.venue_inventory where user_id=actor and request_key=k;
 if old.id is not null then if old.input<>payload then raise exception 'IDEMPOTENCY_CONFLICT';end if;return app_private.operations_venues_get();end if;
 select * into e from app_private.intake_event_slots where id::text=payload->>'slotId' for share;
 if e.id is null or not e.published or e.starts_at<=clock_timestamp() or expiry<=e.starts_at or verified>clock_timestamp() or verified<clock_timestamp()-interval '7 days' then raise exception 'VENUE_VERIFICATION_REQUIRED';end if;
 if exists(select 1 from app_private.venue_inventory where slot_id=e.id and name=btrim(payload->>'name') and address=btrim(payload->>'address') and reservation_name=btrim(payload->>'reservationName')) then raise exception 'VENUE_DUPLICATE';end if;
 insert into app_private.venue_inventory(user_id,request_key,slot_id,name,address,map_url,reservation_name,meal_price_krw,seats,rating,review_count,review_url,verified_at,reservation_valid_until,safe_allergies,safe_avoided_foods,verification_note,input)
 values(actor,k,e.id,btrim(payload->>'name'),btrim(payload->>'address'),payload->>'mapUrl',btrim(payload->>'reservationName'),(payload->>'mealPriceKrw')::int,(payload->>'seats')::int,(payload->>'rating')::numeric,(payload->>'reviewCount')::int,payload->>'reviewUrl',verified,expiry,payload->'safeAllergies',payload->'safeAvoidedFoods',payload->>'verificationNote',payload);
 perform app_private.venue_wake(e.id);
 insert into app_private.member_audit(actor_id,action) values(actor,'VENUE_INVENTORY_REGISTERED');
 return app_private.operations_venues_get();
end $$;
create function app_private.operations_venue_revoke(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor(); slot_uuid uuid;
begin
 if jsonb_typeof(payload) is distinct from 'object' or not payload ? 'inventoryId' or (select count(*) from jsonb_object_keys(payload))<>1 then raise exception 'VALIDATION_ERROR';end if;
 perform pg_advisory_xact_lock(hashtextextended('matching-state',0));
 update app_private.venue_inventory set enabled=false where id::text=payload->>'inventoryId' and enabled returning slot_id into slot_uuid;
 if slot_uuid is not null then
  update app_private.venue_allocations set active=false,released_at=clock_timestamp() where inventory_id::text=payload->>'inventoryId' and active;
  perform app_private.venue_wake(slot_uuid);
  insert into app_private.member_audit(actor_id,action) values(actor,'VENUE_INVENTORY_REVOKED');
 end if;
 return app_private.operations_venues_get();
end $$;
create function app_private.operations_venue_retry(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor(); changed int;
begin
 if jsonb_typeof(payload) is distinct from 'object' or not payload ? 'eventId' or (select count(*) from jsonb_object_keys(payload))<>1 then raise exception 'VALIDATION_ERROR';end if;
 update app_private.venue_receipts set status='QUEUED',attempts=0,due_at=clock_timestamp(),last_error=null where event_id::text=payload->>'eventId' and status='EXCEPTION';
 get diagnostics changed=row_count;if changed<>1 then raise exception 'JOB_CONFLICT';end if;
 insert into app_private.member_audit(actor_id,action) values(actor,'VENUE_EXCEPTION_REQUEUED');return app_private.operations_venues_get();
end $$;

alter function app_private.matching_get() rename to matching_get_v2;
revoke all on function app_private.matching_get_v2() from app_member_api;
create function app_private.matching_get() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor(); dto jsonb;
begin
 dto:=app_private.matching_get_v2();
 return jsonb_build_object('applications',coalesce((select jsonb_agg(case when item->'table'='null'::jsonb then item else jsonb_set(item,'{table}',item->'table'||jsonb_build_object(
 'venueStatus',case when v.id is not null then 'ASSIGNED' when exists(select 1 from app_private.venue_receipts r join app_private.match_outbox o on o.id=r.event_id where o.aggregate_id=t.id and r.last_error is not null) then 'CHECKING' else 'PREPARING' end,
 'venue',case when v.id is not null then jsonb_build_object('name',v.name,'address',v.address,'mapUrl',v.map_url,'reservationName',v.reservation_name,'mealPriceKrw',v.meal_price_krw) else 'null'::jsonb end)) end order by ordinal)
 from jsonb_array_elements(dto->'applications') with ordinality j(item,ordinal)
 left join app_private.table_assignments ta on ta.application_id::text=item->>'id' and ta.user_id=actor and ta.active
 left join app_private.dining_tables t on t.id=ta.table_id and t.status='CONFIRMED'
 left join app_private.venue_allocations va on va.table_id=t.id and va.active
 left join app_private.venue_inventory v on v.id=va.inventory_id and v.enabled),'[]'::jsonb));
end $$;
revoke all on function app_private.venue_text(text),app_private.venue_diet_safe(jsonb,jsonb),app_private.venue_compatible(app_private.venue_inventory,uuid),app_private.venue_wake(uuid),app_private.venue_apply(uuid),app_private.venue_tick(),app_private.operations_venues_get(),app_private.operations_venue_create(jsonb),app_private.operations_venue_revoke(jsonb),app_private.operations_venue_retry(jsonb),app_private.matching_get() from public,anon,authenticated,app_member_api;
grant execute on function app_private.operations_venues_get(),app_private.operations_venue_create(jsonb),app_private.operations_venue_revoke(jsonb),app_private.operations_venue_retry(jsonb),app_private.matching_get() to app_member_api;
