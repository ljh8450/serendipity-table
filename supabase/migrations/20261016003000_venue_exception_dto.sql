-- Bound operator exceptions and show the affected slot without member profiles.
create or replace function app_private.operations_venues_get() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.operator_actor();
begin
 return jsonb_build_object('slots',coalesce((select jsonb_agg(jsonb_build_object('id',id,'startsAt',starts_at,'regionLabel',region_label)) from (select * from app_private.intake_event_slots where published and starts_at>clock_timestamp() order by starts_at limit 100) e),'[]'::jsonb),
 'inventory',coalesce((select jsonb_agg(jsonb_build_object('id',v.id,'slotId',v.slot_id,'name',v.name,'address',v.address,'reservationName',v.reservation_name,'mealPriceKrw',v.meal_price_krw,'seats',v.seats,'rating',v.rating,'reviewCount',v.review_count,'reviewUrl',v.review_url,'verifiedAt',v.verified_at,'validUntil',v.reservation_valid_until,'enabled',v.enabled,'allocated',exists(select 1 from app_private.venue_allocations where inventory_id=v.id and active))) from (select * from app_private.venue_inventory order by created_at desc limit 100) v),'[]'::jsonb),
 'exceptions',coalesce((select jsonb_agg(jsonb_build_object('eventId',r.event_id,'tableId',o.aggregate_id,'code',r.last_error,'status',r.status,'attempts',r.attempts,'startsAt',(select starts_at from app_private.intake_event_slots where id=t.slot_id),'regionLabel',(select region_label from app_private.intake_event_slots where id=t.slot_id))) from (select * from app_private.venue_receipts where last_error is not null order by due_at desc,event_id limit 100) r join app_private.match_outbox o on o.id=r.event_id join app_private.dining_tables t on t.id=o.aggregate_id),'[]'::jsonb));
end $$;
