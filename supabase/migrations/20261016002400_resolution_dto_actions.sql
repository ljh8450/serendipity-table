-- Explicit server capabilities and stable own-history ordering.
create or replace function app_private.matching_get() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=app_private.member_actor(); dto jsonb;
begin
 dto:=app_private.matching_get_v1();
 return jsonb_build_object('applications',coalesce((select jsonb_agg(item||jsonb_build_object(
  'applicationStatus',a.application_status,'paymentStatus',a.payment_status,'attendanceStatus',a.attendance_status,'stored',a.credit_stored,
  'resolutionReason',a.resolution_reason,
  'canResolve',coalesce(a.resolution_reason,'matching_failure')='matching_failure' and a.payment_status='PAID' and a.matching_status in ('ALTERNATIVE_OFFERED','NO_MATCH') and (a.application_status='SUBMITTED' or a.credit_stored),
  'canCancel',a.application_status='SUBMITTED' and a.payment_status='PAID' and a.matching_status in ('WAITING','REALLOCATING','CONFIRMED') and coalesce((select lower(ta.occupied_at) from app_private.table_assignments ta where ta.application_id=a.id and ta.active),(select min(e.starts_at) from app_private.intake_event_slots e where a.input->'slotIds' ? e.id::text))>clock_timestamp(),
  'refundCutoffAt',(select min(coalesce(e.refund_cutoff_at,app_private.refund_cutoff(e.starts_at))) from app_private.intake_event_slots e where a.input->'slotIds' ? e.id::text),
  'hasOriginalPayment',a.credit_payment_id is not null,
  'canRefund',a.credit_payment_id is not null and a.payment_status in ('PAID','REFUND_FAILED') and a.matching_status<>'TRANSFERRED'
   and coalesce(a.resolution_reason,'')<>'voluntary_late'
   and (a.matching_status='ALTERNATIVE_OFFERED' or a.credit_stored or a.resolution_reason in ('voluntary','matching_failure') or (a.application_status='SUBMITTED' and a.matching_status='WAITING'))
   and not exists(select 1 from app_private.refund_attempts r where r.payment_id=a.credit_payment_id and r.outcome='success')
   and (a.membership_id is null or not exists(select 1 from app_private.intake_applications x where x.membership_id=a.membership_id and x.id<>a.id)),
  'nextMatchAt',case when a.application_status='SUBMITTED' and a.payment_status='PAID' and a.matching_status in ('WAITING','REALLOCATING') then item->'nextMatchAt' else 'null'::jsonb end,
  'alternatives',case when a.payment_status='PAID' and (a.matching_status='ALTERNATIVE_OFFERED' or a.credit_stored) then coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'startsAt',e.starts_at,'regionLabel',e.region_label)) from (select * from app_private.intake_event_slots e where e.published and e.opens_at<=clock_timestamp() and e.closes_at>clock_timestamp() and e.matches_at>clock_timestamp() and (a.membership_id is null or app_private.membership_covers(a.membership_id,jsonb_build_array(e.id))) order by e.starts_at limit 20) e),'[]'::jsonb) else '[]'::jsonb end
 ) order by ordinal) from jsonb_array_elements(dto->'applications') with ordinality j(item,ordinal) join app_private.intake_applications a on a.id::text=item->>'id' where a.user_id=actor),'[]'::jsonb));
end $$;
