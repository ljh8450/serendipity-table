# Venue inventory and allocation API

2026-10-16 · INF-01/02 · INF-004 project policy. SQL001–030/member/frontend and venue Cron are deployed to production. Remote rollback venue/resolution/matching tests and authenticated mobile authority smoke passed; operating inventory/events/consents remain unpublished. Auth/CORS/member_actor/operator_actor, private RLS and EXECUTE-only command role remain unchanged.

GET /member/operations/venues: operator-only published future slots, inventory DTO (no input dump), sanitized receipt exceptions. POST suffix /create accepts exactly requestKey,slotId,name,address,mapUrl,reservationName,mealPriceKrw,seats,rating,reviewCount,reviewUrl,verifiedAt,reservationValidUntil,safeAllergies,safeAvoidedFoods,verificationNote,reservationConfirmed. UTC-offset times required. Verified reservation is one4–6 seat table for one real slot. Rating>=4/5, reviews>=20, HTTPS source/map, verification within7 days, expiry beyond event start. Safe phrase arrays are explicit prior venue verification; no free-text inference. Same key/input replays; changed input409. Same slot/name/address/reservation is unique. No external booking is executed by this API.

POST /revoke {inventoryId}: operator-only idempotent disable, immediate local allocation release and scheduled reassessment. It does not cancel a booking at a restaurant. POST /retry {eventId}: operator-only final exception requeue. No public consumer/tick endpoint.

venue_tick runs via actual1-minute Supabase Cron. It uses matching-state plus own invocation lock, bounded20 receipts/tick, table/inventory row locks, unique active inventory/table indexes. Consumer receipts are per match_outbox event; global delivery status stays PENDING for later consumers. Current table state is authoritative even if old confirmation is consumed after invalidation. Business shortages retry3 times, inventory registration wakes prior receipts, final errors are safe codes.

Own GET /member/matching table DTO adds venueStatus PREPARING/CHECKING/ASSIGNED and venue {name,address,mapUrl,reservationName,mealPriceKrw}|null. Only own active confirmed table exposes location; cancelled/excluded members cannot read it. Other members' dietary restrictions and operator evidence are never serialized.

Operator exceptions are bounded to100 and include affected event time/region without member profiles. Reservation identity is case/outer-whitespace insensitive. Local SQL/actual Cron/concurrency and eight mobile E2E tests passed; no production venue data was created.
