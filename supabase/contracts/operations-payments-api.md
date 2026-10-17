# Operations and payment API

2026-10-16 · APP-01/04, ACC-05, PAY-01/02, FAQ-001/PAY-004~007. Migrations010–013, member function and frontend were deployed together to production on 2026-10-16; see docs/context/deployment.md for evidence. Operating events/consent documents remain unpublished.

All routes use the existing member bearer authentication, exact-origin CORS/no-store, 16 KiB stream limit and EXECUTE-only DB role. Server account roles authorize operations; a browser role or Auth user_metadata cannot grant operator access. No amount, payment status, membership expiry, owner or role is accepted from the browser.

| Method /member suffix | Body | Result |
|---|---|---|
| GET /operations | — | Up to 100 slots and consent versions, explicitly projected; operator only |
| POST /operations/slot | startsAt, opensAt, closesAt, matchesAt (offset timestamps), regionCode, capacity | Create unpublished slot; server validates ordering/4~240 capacity/initial four regions; calculates refund cutoff |
| POST /operations/publish | slotId, published boolean | Publish/unpublish existing slot; shared publication transaction lock with new applications |
| POST /operations/document | kind, version, title, body | Immediately publish a new required consent version; retain previous document and acceptances, reject version reuse |
| POST /intake/refund | applicationId, requestKey UUID, outcome success/failure | Full original-transaction mock refund; PAY-008 eligibility, retry and cancellation |
| POST /intake/payment | applicationId, requestKey UUID, outcome success/failure | Explicit mock payment only. Amount comes from immutable application product snapshot; return own current intake DTO |

The new catalog uses single_v2 / membership_1 / membership_3 / membership_6 / membership_use. Legacy single/three become inactive; existing snapshots and repeated old submission keys are preserved. Old drafts can be loaded, but must select a current product before a new submission. Historical three-use products are not silently converted. Membership products do not expose a remaining-use count.

A successful mock membership purchase creates one period entitlement, in KST calendar months from the transaction time, with an exclusive end. Active membership purchases cannot overlap. membership_use validates ownership/current validity and coverage of every selected event start, then sets application payment eligibility without a new charge or usage counter. Failed attempts never create entitlements. Actor locks serialize payment/submission/extension, one successful payment per application is enforced by an index, and (actor, requestKey) replays return the prior result or conflict on changed content.

New intake DTO fields: membership list with startsAt/endsAt/active/extensionDays, product kind/policyVersion, application productSnapshot/eligible, slot matchesAt/refundCutoffAt. eligible is server-calculated preliminary financial eligibility; final matching must independently revalidate all matching constraints and live entitlement state.

Internal membership_failure_extend(applicationId) is not executable by anonymous/authenticated/member command roles. It requires PAID membership-linked matching failure, locks account/application/entitlement, records one extension per application and adds seven days (project PAY-007 policy, not an organizer-specified amount). Different failures accumulate; retrying the same failure cannot extend twice. Automatic matching dispatch and complete resolution/transfer and automatic dispatch remain the following plan units, so this function is verified directly with local SQL fixtures rather than described as a running automatic workflow.

refund_cutoff_at is the Wednesday 00:00 KST preceding the event (Tuesday 24:00); Monday/Tuesday events use the previous week. The exact cutoff is exclusive of voluntary refunds from that timestamp. matches_at is independent. This unit exposes the policy, stores the cutoff and implements original-transaction mock refunds. The server determines voluntary versus matching-failure reason, caps the full refund to the one successful original payment, rejects repeated success, and records failed attempts for retry. Accepted failed refunds can retry after cutoff; financial eligibility stays locked out. A membership refund requires no other active paid applications and disables entitlement on both accepted failure and success. Voluntary refunds currently require WAITING: confirmed-table cancellation is rejected until its repair domain is implemented. Used/partial membership refunds and table repair after confirmed cancellation remain following resolution work. Production consent text has not been invented or published.

Additional 409 errors: MEMBERSHIP_REQUIRED, MEMBERSHIP_ACTIVE, PAYMENT_CONFLICT, MEMBERSHIP_IN_USE, REFUND_CLOSED. FORBIDDEN=403, invalid domain input=422, existing conflicts follow intake-api.md. SQL details are never returned. Actor locks and publication locks are part of the DB boundary; authorization is not left to the UI.

SQL023–027 supersedes the WAITING-only cancellation boundary with explicit early/late cancellation and safe table repair. The refund endpoint now delegates to match_resolve, preserving pre-upgrade request replays and original-payment amounts. Membership refunds reject any other application usage history. These changes are deployed to production SQL027 with remote rollback financial/resolution/matching tests and mobile authorization smoke. See [resolution API](resolution-api.md).
