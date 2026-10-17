# Attendance API (ATT-004)

Bearer JWT/Auth validation, allowlisted CORS and trusted transaction actor follow member-api.md. No client clock/actor accepted.

- GET /member/attendance: {attendances:[{assignmentId,applicationId,startsAt,opensAt,closesAt,status,checkedInAt,reviewStatus,canCheckIn}]}. Own active confirmed assignments only, latest20.
- POST /member/attendance/check-in: {assignmentId,requestKey}; same DTO. Server clock [start-30min,start+3h), current submitted/paid/confirmed assignment required. Duplicate returns current state; changed target with same key409.
- GET /member/operations/attendance: operator-only {reviews:[{assignmentId,applicationId,startsAt,status,reviewStatus,closedAt,canReview,actions:[{action,at}]}]}, latest100. No contact/profile/reason text.
- POST /member/operations/attendance/review: {assignmentId,requestKey,outcome:ATTENDED|NO_SHOW,reason:string(5..500 trimmed)}. Operator confirmation after close, immutable audit; correction uses new key. Returns monitor DTO.

Errors:401 unauthenticated,403 ownership/role/restricted,422 shape/field validation,409 CHECK_IN_CLOSED/ATTENDANCE_CONFLICT/IDEMPOTENCY_CONFLICT. No public tick, caller clock, automatic restriction or financial mutation. Cron every minute closes eligible assignments and creates PENDING candidates without marking NO_SHOW. UTC persisted, Asia/Seoul displayed. Partial first attendance unit; feedback/safety sanctions remain separate.
