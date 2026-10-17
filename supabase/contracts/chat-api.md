# Table chat API

2026-10-16 · INF-04 · CHAT-001 project policy. SQL001–033/member/frontend and chat Cron are deployed to production. Remote rollback chat/matching/resolution tests and authenticated mobile authority smoke passed; operating rooms/events/consents remain unpublished. Member Auth/CORS/no-store, private RLS and EXECUTE-only role remain unchanged.

GET /member/chat/{roomId}?before={positive bigint string}: latest50 or preceding50, ascending within page. Optional single before; unknown/repeated query keys are422. DTO {roomId,messages:[{id:string,kind:MEMBER|SYSTEM,body,sentAt,mine:boolean,sender:room-local label}],nextBefore:string|null,members:[{label,mine}]}. No Auth/member/application IDs or private profiles are serialized. Messages are real DB rows, displayed as plain text.

POST /member/chat/{roomId}/messages exact body {requestKey:UUID,body:string1..1000/nonblank}. Path room ID is supplied by the handler, client roomId/actor/unknown fields are rejected. Response {messageId:string}. Same member/key/body replays, changed content409. New sends max10 in60 seconds (server time),429/Retry-After60; replay does not consume quota. Requests always recheck current authorization before replaying.

Both routes validate actor/restriction and OPEN room/current CONFIRMED table/active own assignment/SUBMITTED+PAID+CONFIRMED application on every request. Matching-state shared read/exclusive send fence linearizes requests against cancellation/report/invalidations. Cached mirrored chat membership is insufficient.403 includes unowned/missing/invalidated rooms,401 invalid Auth,422 malformed,503 transient failures. Already legitimately received messages cannot be retroactively erased from recipients.

Independent chat_tick1-minute DB Cron processes20 per-consumer receipts. One room per table, stable room-local member numbers, unique welcome/update system keys,3 retries/final safe exception. Canonical table state handles delayed/reversed events; invalidation closes old room, no history copied to replacement. Global outbox delivery remains PENDING for notifications/push consumers.

GET /member/operations/chat operator-only counts/status/limited exceptions, no conversation bodies or member identities. POST /member/operations/chat/retry {eventId} requeues a final exception and audits. Internal consumer functions have no public execute route. Own matching table DTO adds chat:{roomId,status:READY}|null.

Mobile UI uses read-only5-second polling only while open/visible/latest; older-page mode pauses polling until latest refresh. Close/unmount clears displayed messages. Lost send responses preserve input and request key for safe retry;403/401 clears chat content and disables sending. Operations monitoring does not read conversations. Attachments/moderation/deletion/long-term retention and actual push/content remain separate work.

2026-10-16 검증 갱신: front lint/typecheck/3tests/build·Deno13tests/check 통과, 별도 실제1분 chat Cron/실행 로그·병렬 consumer·동일 키 동시 전송·취소/전송 경합·회수 후 읽기 거부를 통과했다. SQL033은 현재 활성 인원이4~6명인지 권한 검사에도 추가한다. 실제 두 브라우저 대화/응답 유실 재시도·전체 회귀 검증도 통과했다.

Verification: local SQL8 files, frontend3/Deno13, actual Cron/concurrency and all9 mobile E2E passed. Production is SQL033; notification/push/content delivery is not completed by chat consumer receipts.
