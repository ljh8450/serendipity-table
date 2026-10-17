# Event feedback API (FDB-005)

Existing member Auth/JWT/CORS/EXECUTE-only transaction actor rules apply. No caller clock, actor, peer preference or free text accepted.

- GET /member/feedback: {events:[{assignmentId,startsAt,deadlineAt,canSubmit,submittedAt,ratings}]}, own currently authorized ended/ATTENDED assignments, newest20. ratings is null or {atmosphere,conversation,venue:integer1..5,revisit,recommend:boolean}. Stored evaluations remain own-readable after deadline while current authorization remains valid.
- POST /member/feedback/submit: {assignmentId,requestKey,ratings}, returns same DTO. Only ended attended active confirmed paid submitted assignments; deadline end+7days exclusive. Same key+same ratings replays; changed existing submission409; reused key for another assignment409. Each command rechecks permission including replays.
- GET /member/operations/feedback: operator-only {jobs:[{id,kind,status,attempts,dueAt,lastError}]}, exception-first latest100. No ratings, raw comments, identities or delivery endpoints.
- POST /member/operations/feedback/retry: {jobId}, exception-only; current permission/deadline/unanswered checks; audit; same monitor DTO.

Errors:401 Auth,403 ownership/role/revoked attendance,422 exact shape/score/boolean,409 FEEDBACK_CLOSED/FEEDBACK_CONFLICT/IDEMPOTENCY_CONFLICT. Public worker/clock endpoints404.

DB Cron creates first request after end/attendance confirmed, one reminder24h after request generation and only before end+7days if unanswered. Job+notification+existing push queue insert is atomic/unique; failed notification insert retries3 then EXCEPTION. Submission cancels waiting jobs/push and hides both request/reminder notices. Claim rechecks current eligibility. Provider acceptance/OS display remain separate from notification creation. Ratings and request keys never exposed to peers/operator monitor. Person preferences, next matching and safety sanctions remain separate units.
