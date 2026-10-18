# 운영 피드백·사건 연결

2026-10-18 · OP-02 · SQL043 · 로컬 전용 구현/검증. 운영 통합 조회 상세에 연결한다.

`POST /member/operations/insights`: JWT→operator_actor 필수. 본문은 slotId 또는 tableId(UUID 문자열, 하나 이상), page(0~9999, 기본0)만 허용한다. 둘을 보내면 테이블이 해당 회차에 속해야 한다. 존재하지 않는 ID·잘못된 타입/관계/미허용필드/query는422, GET405, 참가자403다. 일반 역할 직접 EXECUTE는 금지하며 조회 감사 OPERATIONS_INSIGHTS_READ를 기록한다.

응답은 attendance, feedback, canReviewSafety, cases, page, totalCases, pageSize(25)다. 한 statement snapshot에서 범위를 검사하고 집계한다. 금융·안전·참석 상태를 수정하지 않는다.

attendance는 현재 유효 CONFIRMED/SUBMITTED 배정의 assigned/attended/noShowCandidates(PENDING)/confirmedNoShows(검토·신청 둘 다 NO_SHOW), 과거 배정 근거가 있는 고유 신청의 lateCancellations다. 무효/회수 배정을 현재 인원에 합산하지 않는다. 후보는 자동 제재의 근거가 아니다.

feedback은 기존 feedback_eligible을 다시 만족하는 종료 참석 배정의 eligible, 해당 배정의 유효 응답 responses, atmosphere/conversation/venue 평균, revisitYes/recommendYes를 제공한다. 평가 원문이나 개인별 선호는 반환하지 않는다. 노쇼 정정/권한 변경으로 자격을 잃은 과거 응답은 보존하지만 현재 집계에서 제외한다. 응답0이면 평균null, 대상0이면 UI 응답률N/A다. 수집 이후 변화하는 운영 스냅샷이며 과거 고정 보고서가 아니다.

cases는 같은 범위의 REPORT(분류·처리상태), ATTENDANCE(후보/확인/조치 후 정정), CANCELLATION(마감 후 취소/조치 후 정정)을 at DESC nulls last→caseType→caseId로 정렬한다. 각 항목은 caseType,caseId,kind,status,at,tableId,applicationId만 포함하며 REPORT.applicationId는null이다. 신고자/대상 사용자 식별자·원문·개인별 선호·조치 사유를 일반 집계에서 반환하지 않는다.

현재 safety_reviewers에 포함된 운영자에게만 canReviewSafety=true다. 사건 연결은 기존 `/operations/safety/detail`과 review를 사용하므로 새 우회 권한을 추가하지 않는다. 후보는 기존 참석 모니터로 이동하고 안전 제재 상세로 바로 연결하지 않는다. 계정 해제·사건 종결이 영속 쌍 제외를 지우는 정책을 추가하지 않았다.

필수 화면 연결: OP-01 회원/신청/회차/테이블/작업실패 + OP-02 회차/테이블 참석·일반평가 집계/신고·확인노쇼·마감후취소 요약/권한별 기존 상세. 개인별 비공개 선호/차단 원문을 일반 운영자에게 공개하는 화면은 추가하지 않는다. CSV·13지표·운영시간·보관삭제는 별도 계획 단위다.

검증은 operations_insights_permissions.sql(실제 rollback 권한·범위/교차ID·집계·참석정정·원문권한) 및 operations-insights.spec.ts(실제 모바일/Auth/Edge/DB·역할부여/회수·담당화면 포커스/기존목록복원)를 사용한다. 실행 결과는 docs/context/operations.md 참조.
