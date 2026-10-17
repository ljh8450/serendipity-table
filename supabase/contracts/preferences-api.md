# Person preferences and attendance history API (FDB-006/MAT-006)

Member JWT/Auth server validation, CORS and transaction actor rules apply. No public worker, caller clock, global peer/user IDs or operator preference listing.

- GET /member/preferences: {events:[{assignmentId,startsAt,regionLabel,feedbackSubmitted,deadlineAt,canEdit,peers:[{peerId,label,value,revision,effective}]}]}, own valid ended ATTENDED events, newest20. Peers are current jointly ATTENDED people with existing chat participant numbers; peerId is a scoped assignment token, not a global account ID. Only the caller's saved value is returned. effective indicates current source attendance remains valid.
- POST /member/preferences/save: {assignmentId,peerId,requestKey,value:LIKE|AVOID|NEUTRAL,revision:int0..999999999}. Exact shape; same-event nonself current attendee check, source end+7days exclusive. Initial revision0; each save increments. Same key+same input replays current DTO; changed input409; stale revision409. Replay rechecks permission. Neutral clears caller's choice only.

401 Auth;403 ownership/peer attendance;422 shape/query/clock/value;409 PREFERENCE_CONFLICT/PREFERENCE_CLOSED/IDEMPOTENCY_CONFLICT. No raw preferences in peer/operator matching DTOs or messages.

Server-derived actual_meetings uses ended confirmed active assignments with both ATTENDED. Manual trusted legacy encounters remain supported. Corrected no-show/cancellation removes live evidence immediately. Effective AVOID from either direction excludes the pair alongside legacy block/report/dislike. Explicit LIKE is a separate tie breaker after placed count, reallocation step and base score, before repeated encounters; minimum score and hard constraints unchanged. Algorithm beam-feedback-v2 records internal pair snapshots. Saves serialize with matching/attendance; AVOID repairs conflicting future confirmed tables/outbox/jobs atomically while preserving source past tables. Clearing a choice never reopens invalidated tables. Privacy/safety reporting and next-event recommendations remain separate.

Operator attendance restoration also takes the exclusive matching fence and repairs future conflicts in the same transaction: an existing AVOID can become effective again after a NO_SHOW correction is reversed. The ended source table remains intact.
