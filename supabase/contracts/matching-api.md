# Matching and scheduled-job API

2026-10-16 · MAT-01–13, STA-02–04, MAT-005 project policy. Migrations001–033, member endpoints and scheduled Cron are deployed to production; remote rollback permission tests and authenticated mobile smoke passed. Scheduled empty-queue runs succeeded; eight-person matching was verified with local fixtures.

All member routes retain Auth /user bearer validation, exact-origin CORS, no-store and app_member_api EXECUTE-only access. Internal match_enqueue/claim/process/tick and relation/score helpers are not exposed to the member role or anonymous/authenticated roles.

| Method /member suffix | Input | DTO / authorization |
|---|---|---|
| GET /matching | — | Up to20 own applications: server matching status, next selected matching time, generic attention flag, own confirmed table id/start/region/count, own safe reason history and open alternative slots |
| GET /operations/matching | — | Server operator: policy version/threshold, up to100 jobs,50 runs, safe exception codes and pending outbox count; no profile/relationship snapshots |
| POST /operations/matching/retry | `{jobId}` | Operator only; requeue an EXCEPTION job, reset attempts, audit. No manual normal-flow start, approval, proposed table or time override |

Matching results never expose other participants' contact, birth year, Instagram, preferences, relation reasons or scores. A table result reports venue PREPARING and delivery PENDING; no fake restaurant/chat/push completion is implied. Failures offer actual open slots for review, never automatic movement outside consent. Complete transfer/storage actions are subsequent work.

The DB stores (policy,input) snapshots, allocation reasons and a transactional outbox. A due slot has a unique queued job. Claim fencing tokens and finite leases protect committed claims; execution in one DB transaction makes crash rollback safe. Duplicate Cron ticks skip while another holds the tick fence. Each successful table/application has active uniqueness and user time-overlap exclusion. Publication/queue registration and confirmed state/outbox writes are atomic.

Default policy is project MAT-005, not an organizer MBTI compatibility table. Max16 users per bounded search window and size-diverse64-state beam; maximize covered users, then selected-slot reallocation stages, score, new people and stable IDs. There is no global optimality guarantee. Larger pools make progress across ticks; retry attempts rotate the bounded age-ordered window rather than repeatedly inspecting the same prefix; an exhausted search window is an explicit retryable exception, not an invented matching failure. Future selected slots defer final failure. Final matching failure invokes the internal idempotent membership extension.

JOB_CONFLICT=409 for invalid retry state. Domain execution exceptions persist only safe code names. Public /matching/tick or process endpoints do not exist. Browser polling/refresh is read-only. Finalization revalidates current account/application/entitlement/relations under locks, and a new excluded relationship invalidates an unsafe existing table and queues repair.

Known limits: full cancellation/repair semantics beyond relation fencing, venue/chat/notification consumers, feedback and safety input/administration are separate units. Cron project-pausing and missed deadlines are tracked, not treated as continuously available scheduling guarantees.

SQL023–027 extends own matching DTO with resolution capabilities and TABLE_UPDATED cancellation outbox. These migrations/Edge/frontend are now deployed with remote rollback tests and mobile authorization smoke; see [resolution API](resolution-api.md).

SQL028–030 adds own confirmed venue DTO; see [venue API](venue-api.md). This venue unit is now deployed with remote rollback tests and mobile authority smoke. Global deliveryStatus remains PENDING for future room/push consumers.

SQL031–033 adds own confirmed chat:{roomId,status:READY}|null; see [chat API](chat-api.md). Global deliveryStatus remains PENDING for future notification/push/content consumers. The chat unit is now deployed with remote rollback tests and authenticated mobile authority smoke.
