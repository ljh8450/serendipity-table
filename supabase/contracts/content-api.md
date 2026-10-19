# Scheduled guide/content

Participants read system messages through the existing currently authorized chat endpoint. No participant can generate content or supply a scheduler clock.

- GET `/member/operations/content`: operator Auth only; `{jobs:[{jobId,kind,status,attempts,code,scheduledAt,startsAt,regionLabel,retryable}]}`. Exception-first100 maximum. No message body, private preference or snapshot.
- POST `/member/operations/content/retry`: operator Auth, JSON `{jobId:UUID}` only; returns the monitor DTO. Current EXCEPTION, confirmed table and remaining posting window are required. Stale/missed requests409, invalid input422, participants403, anonymous401.

Internal content_tick registers GUIDE/D1/START jobs and processes20 due items/minute with DB time. D1 window `[startsAt-24h,startsAt)`, START `[startsAt,startsAt+3h)`. GUIDE posts current reservation revision before the end of the3hour window. Invalidated tables/obsolete pending GUIDE revisions are canceled. D1 requires compatible current venue; all postings require valid current4–6 participants, account/payment/application and live room access. SQL036 keeps this work inside the matching-state fence.

System messages, generic app notifications, existing real push queue insertion and public template snapshot/DONE are atomic and uniquely keyed. Retry rolls back the entire attempted posting, backs off1minute, and becomes an operator exception after3attempts. Passed windows never send late reminders/content. DONE means DB posting, not provider acceptance or OS display. Existing Web Push delivery limits apply unchanged.

## Operator text templates (SQL051, 2026-10-18)
Local implementation, not yet production deployed. GET /operations/templates returns five active `{kind,version,body,createdAt}` rows (GUIDE,D1,START,CURATION,ALTERNATIVE). POST accepts exactly `{kind,expectedVersion,body}`; plain text1..500 trimmed chars, operator-only, stale version409, invalid422, audit and immutable versions. Server-generated current venue/date/refund facts and dynamic topics remain authoritative. Dispatch resolves the active operator text and persists versions/bodies with messages in the content job snapshot. Alternative notifications snapshot at insert; already delivered text is never rewritten. These routes reject query parameters and expose no actor/time override.
