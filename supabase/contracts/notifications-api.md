# Member notifications

Verified Supabase Auth JWT, configured CORS origin and `app_member_api` command permissions are required. Internal tables and Cron are inaccessible to clients.

- `GET /member/notifications`: `{notifications:[{id,kind,title,body,createdAt,read}],unreadCount}`. Latest 50 visible notices; unread count covers all visible notices. Timestamps are UTC. No chat text, participant identifiers, preferences or raw outbox payload.
- `POST /member/notifications/read`: JSON `{id:UUID}` only; returns `{read:true}`. Replays are idempotent. Foreign, missing or no longer visible IDs return403. Invalid shape/UUID returns422.

Normal table notices require current active assignment and a confirmed group of4–6 with submitted/paid/confirmed application. Invalidation/failure notices require the recipient's submitted application. Account restrictions are checked by member_actor. Reads share the matching-state transaction fence.

Matching events are consumed separately with unique per-event receipts and recipient/event keys. Venue inserts and member chat inserts generate notices in the same transaction; the sender receives no self notice. This consumer never updates global outbox delivery state. One-minute DB Cron is responsible for matching notices; no browser scheduling.

SQL034 implements in-app notifications only. Web Push, subscriptions, external delivery and scheduled content are not part of this API yet.
