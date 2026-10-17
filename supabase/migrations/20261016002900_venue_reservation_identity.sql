-- Reservation identity is insensitive to surrounding whitespace and case.
create unique index venue_reservation_identity on app_private.venue_inventory(slot_id,lower(btrim(name)),lower(btrim(address)),lower(btrim(reservation_name)));
create or replace function app_private.operations_venue_create(payload jsonb) returns jsonb
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
 if exists(select 1 from app_private.venue_inventory where slot_id=e.id and lower(btrim(name))=lower(btrim(payload->>'name')) and lower(btrim(address))=lower(btrim(payload->>'address')) and lower(btrim(reservation_name))=lower(btrim(payload->>'reservationName'))) then raise exception 'VENUE_DUPLICATE';end if;
 insert into app_private.venue_inventory(user_id,request_key,slot_id,name,address,map_url,reservation_name,meal_price_krw,seats,rating,review_count,review_url,verified_at,reservation_valid_until,safe_allergies,safe_avoided_foods,verification_note,input)
 values(actor,k,e.id,btrim(payload->>'name'),btrim(payload->>'address'),payload->>'mapUrl',btrim(payload->>'reservationName'),(payload->>'mealPriceKrw')::int,(payload->>'seats')::int,(payload->>'rating')::numeric,(payload->>'reviewCount')::int,payload->>'reviewUrl',verified,expiry,payload->'safeAllergies',payload->'safeAvoidedFoods',payload->>'verificationNote',payload);
 perform app_private.venue_wake(e.id);
 insert into app_private.member_audit(actor_id,action) values(actor,'VENUE_INVENTORY_REGISTERED');
 return app_private.operations_venues_get();
end $$;
