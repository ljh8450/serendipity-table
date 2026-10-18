# 회원 탈퇴·보관/정리

2026-10-18 · PRIV-002 · PRD11쪽16절 · SQL046~047. SQL047/member/privacy-dispatch와 서버 Cron 운영 배포·원격 권한 검증 완료. 실제 Auth soft/hard 정리 증거는 가상 로컬 계정 기준이다. 보관 설계의 출처/적용 한계는 docs/context/decisions.md의 PRIV-002를 따른다.

## 본인 명령

`GET /member/privacy`는 검증된 Auth actor의 최소 탈퇴 상태만 반환한다. `POST /member/privacy/withdraw` 본문은 requestKey(UUID),confirmation(`탈퇴`)만 허용한다. 본문 userId/time/정책기간/알려지지 않은 필드와 query는422다. 일반 product API와 달리 이미 탈퇴한 본인의 접수 확인을 위해 privacy_actor를 사용하되 일반 프로필·금융 상세를 반환하지 않는다. 일반 참가자만 탈퇴 가능하고 운영자는403이다. 원래의 일반 계정 제한/안전 제한을 탈퇴로 해제하지 않는다.

DTO: withdrawn,receiptId(서버 생성 고유 UUID),withdrawnAt,policyVersion,canWithdraw,financialUntil,safetyUntil,auditUntil,authCleanupPending,unresolvedFinancialApplications. 접수 확인서는 이 최소 DTO만 JSON으로 저장하며 연락처·이메일·신고·결제 원문은 없다. 확인서가 환불 완료나 권리 포기를 뜻하지 않는다. 접수 번호만으로 공개 금융 명령을 허용하지 않는다.

동일 actor/동일 requestKey는 동일 접수 결과, 다른 key는409 IDEMPOTENCY_CONFLICT다. 탈퇴 원장은 member_accounts.restricted·safety_accounts와 독립이다. matching-state exclusive fence→탈퇴 원장→도메인 행 순서를 사용해 기존 member_actor 계정 SHARE→매칭 잠금과 교착하지 않게 한다. 미래 테이블은 기존 cancel_table_repair를 호출해 유효한4~6명/나이≤8/선택/최소점수/관계 제외를 재검증하고, 3명은 무효·선택 범위 내 재배치로 연결한다. 진행/종료 참석 근거는 유지하며 진행 중 탈퇴는 운영 예외로 기록한다. 금융 상태/원결제/멤버십을 강제 환불·소진·몰수하지 않는다.

탈퇴 즉시 member_actor·safety_allowed에서 제품 권한과 매칭 자격을 회수한다. 모든 본인 푸시 구독/알림을 정리하고 채팅 회원 권한을 회수하며 본인 채팅 본문을 탈퇴 표시로 대체한다. 일반 프로필·온보딩·초안·시작 계측·사람별 선호/관련 선택 명령을 정리하고 신청 identity/onboarding/자유 입력과 매칭 입력 스냅샷을 최소화한다. 동시 개인정보 INSERT/UPDATE는 statement fence 후 독립 탈퇴 상태를 다시 검사한다. 내부 최소화에서만 사용한 transaction-local cleanup 표시는 반환 전에 복원한다. 일반 모니터/CSV의 회원 이름은 즉시 탈퇴 표시로 마스킹하고 Auth 정리 후 username도 제거한다.

## 보존과 Auth

privacy-v1 기본값은 일반 정보 즉시 최소화, 해당 자료가 있는 경우 금융5년/안전·분쟁3년, 일반 감사1년이다. 기간은 탈퇴 및 보존할 마지막 거래/사건 시각을 바탕으로 서버가 관리하며 원장에 정책 버전을 남긴다. 자료가 없으면 해당 금융/안전 기간을 부여하지 않는다. 새 사건/정산 기록은 필요한 기한을 늘릴 수 있고 기존 기간을 임의 단축하지 않는다. 원문 PRD가 지정한 기간이나 모든 자료에 일괄 적용되는 법정 값이라는 주장은 아니다. 실제 서비스의 적용 대상·고지 전문 발행은 운영 준비 게이트다.

private privacy_holds는 FINANCIAL/SAFETY/LEGAL 사유와 유한한 expires_at을 가진다. API에 hold 생성/해제/기간 변경을 공개하지 않는다. 미해결 이용권/환불·유효 멤버십도 별도로 보존한다. 기간 만료만으로 금융 권리를 없애지 않고 운영 모니터에 보존 확인 건수를 표시한다. 탈퇴 후 앱 셀프 환불 접근은 종료되므로 참가자는 탈퇴 전에 해결 선택을 확인하고 접수 확인서를 보관한다. 남은 권리는 신뢰 백엔드 정산/증빙 확인 대상으로 보존하며 자동 몰수하지 않는다.

Auth 정리는 DB 영속 작업·독립 app_privacy_dispatch EXECUTE 역할을 사용한다. 1분 Cron의 privacy-dispatch는 private bearer+고정 빈 JSON만 받으며 caller가 수신자/시각/작업 종류를 정하지 못한다. worker는 Supabase Admin DELETE의 should_soft_delete=true로 인증 자료를 소프트 정리하고, TTL 후에는 false로 최종 삭제한다. Supabase Auth 소프트 삭제는 복원 기능이 아니다. JWT는 만료 전까지 존재할 수 있으므로 Auth 정리 전에도 DB 제품 권한을 차단하며 프론트는 global signOut/로컬 세션 정리를 수행한다.

HTTP200/404만으로 완료 처리하지 않고 private DB 함수가 실제 auth.users.deleted_at 또는 행 부재를 확인한다. job token/lease·SKIP LOCKED·상한5배치·5회실패후예외·기한있는재시도로 응답 유실/중단을 복구한다. 보존 만료 Cron은 매시17분에 최대50계정을 순환 점검한다. 오래 보존 중인 계정이 뒤의 계정을 굶기지 않게 last_checked_at으로 순환한다. 최종 삭제 전 금융/법적 hold·새 거래/사건 기한을 재검사하고 의존 레코드를 명시 순서로 정리한다. hard_delete_prepared_at 이후 새 hold 삽입은 거부해 이미 시작한 최종 파기와의 경합을 막는다. 타인의 테이블/참석·원장까지 cascade 파기하지 않는다. 최소 접수 이력은 최종 Auth 삭제1년후 정리한다.

## 운영·검증 경계

`GET /member/operations/privacy`는 operator_actor에게 작업 id/kind/status/attempts/dueAt과 기한 만료 후 보존 확인 건수만 반환한다. `/retry` POST(jobId)는 현재 EXCEPTION만 재시도하며 period/hold를 우회하지 않는다. 성공 재시도는 감사와 기존 운영 개입 계측에 연결한다. 통합 예외 목록/CSV에는 정제된 업무·다음 행동만 포함한다. 보존 원문·키·Auth 응답·참가자 이메일은 운영 요약/CSV로 보내지 않는다.

검증: privacy_permissions.sql,privacy_retention_permissions.sql(rollback 역할/4→3·5→4/원장·자유입력·멱등/hold·기한·의존성/다른 참가자 보존),verify-privacy-local.mjs(실제4종DB경합),zz-privacy.spec.ts(별도 가상 Auth·refresh/재로그인 차단·확인서·실제1분 Auth/만료Cron·실제 soft/hard 확인). e2e의 기간 조절/보존 Cron 분 단위 변경은 해당 로컬 테스트만 대상으로 하며 원래 schedule을 복원한다. 정책 실행·외부 Auth 성공·로컬/원격 배포를 구분하며 실제 결과는 docs/context/privacy.md를 따른다.
