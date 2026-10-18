# 운영 지표·시간 계측

2026-10-18 · OP-04 · SQL045 · PRD3쪽 핵심 지표13개. SQL047/member와 함께 운영 배포·원격 권한 검증 완료.

`POST /member/operations/metrics`: operator_actor 필수. 본문 from(UTC ISO, 포함),to(미포함) 필수, slotId 선택. 기간/UUID/알려지지 않은 필드/query는422, GET405, 참가자403. 응답은 from,to,asOf,instrumentationSince,metrics[13],openSessions,completedSessions,myActiveSession이다. 각 metric은 id,label,numerator,denominator,value,unit,note,coverage만 반환한다. 분모0은null/N/A이며 PARTIAL/UNMEASURED를 숨기지 않는다. 개인정보/원문은 반환하지 않고 조회 감사를 남긴다.

신청 집합은 submitted_at 기간과 선택 회차를 기준으로 고정한 cohort다. 신청 시작은 started_at, 확정 테이블은 created_at, 작업 시간은 started_at 기간을 사용한다. 성과는 asOf 현재 유효 상태·정정까지 반영하며 고정 역사 보고서가 아니다. 이후 재방문 신청은 현재까지 조회한다. 각 지표의 note와 UI에 집계 기준을 표시한다.

| 지표 | 분자 / 분모 (고유 단위) |
|---|---|
| 신청 완료 | 신청 단계 진입과 같은 작성 키의 제출 사용자 / 단계 진입 사용자 |
| 결제 전환 | 원결제·멤버십·원거래 이동 자격 사용자 / 신청 제출 사용자 |
| 매칭 성공 | 현재 유효 확정 배정 사용자 / 결제 자격 사용자 |
| 자동 확정 | 생성 전 회차 예외 개입 없는 확정 테이블 / 수집 이후 생성된 현재 확정 테이블 |
| 자동 재배치 | 최초 실패/재계획/무효 배정 뒤 다른 유효 테이블 배치 신청 / 실패·재계획·무효 배정 이력 신청 |
| 대체 일정 전환 | 명시 이동 완료 신청 / 최종 대안 제시 이력 신청 |
| 자동 환불 완료 | 성공 모의 환불 신청 / 환불 선택 이력 신청 |
| 실제 참가 전환 | 종료 참석 확인 사용자 / 신청 제출 사용자 |
| 노쇼 | 검토와 신청상태 둘 다 NO_SHOW 사용자 / 배정 이력이 있는 사용자 |
| 재방문 | 종료 참석 후 다른 신청 제출 사용자 / 종료 참석 사용자 |
| 피드백 응답 | 일반 평가 제출 사용자 / 종료 참석 사용자 |
| 운영자 개입 | 성공 예외 명령의 신청/회차 범위에 속한 신청 / 수집 이후 제출 신청 |
| 운영 시간 | 완료된 서버 세션 초 합계 / 실제 측정한 회차 수 |

같은 회차의 무효 테이블 복구와 날짜/지역 재배치 단계 이력을 함께 검사한다. 단순 알고리즘 후보 탐색을 실제 실패 배정으로 만들어 집계하지 않는다. 후보 노쇼는 노쇼율 분자에서 제외하고 참석 정정 후 노쇼/피드백 분모를 다시 계산한다. 금융과 이동은 고유 신청/사용자로 재시도를 중복 집계하지 않는다. 환불은 허용된 모의 결제/환불 범위이며 현재 본인 요청 API가 자동 처리하고 운영자 환불 명령은 없다.

신청 시작은 인증된 `/member/intake/start`(POST requestKey,slotIds 최대20개·실재 회차, actor는JWT)로 회차 신청 단계 진입·선택 변경 시 수집한다. participant만 기록하고 operator는 recorded=false다. 같은 작성 키로 UPSERT하며 브라우저 시각을 받지 않는다. 계측 실패는 신청을 차단하지 않으며 누락된 과거 시작을 추정/backfill하지 않는다. 시작 전 기간은PARTIAL이다.

운영 예외 개입은 Edge가 트랜잭션 로컬 명령 이름/본문을 설정하고 기존 도메인의 성공 감사 INSERT를 DB trigger가 관찰한다. matching/venue/chat/content/push/feedback retry, attendance/safety review만 대상이다. 사전 설정/조회/실패/멱등 재전송은 개입 성공으로 추가하지 않는다. audit_id 고유키로 중복을 막는다. 신청 없는 회차 작업은 해당 회차 선택/배정 신청 전체의 영향으로 연결하며 원시 개입 건수와 신청 비율을 혼동하지 않는다. 신규 수집 이전의 개입을 없었다고 가정하지 않는다.

`POST /member/operations/work`: start는 `{action:'start',slotId,requestKey}`, stop은 `{action:'stop',sessionId,requestKey}`. operator_actor·서버 시각·본인 세션만 허용한다. actor별 advisory lock/한 개 open 제약, 동일키/동일내용 멱등, 다른 활성 시작·변경된 종료는409 WORK_CONFLICT/IDEMPOTENCY_CONFLICT, 타인 세션은403이다. 기록 없는 시간은null/UNMEASURED, 미종료 세션은완료합계에서제외한다. 여러 운영자의 완료 시간은 작업 인시 합계이며 벽시계 회차 지속시간과 다르다. 브라우저 타이머를 예약 실행이나 저장 시간으로 사용하지 않는다.

검증: operations_metrics_permissions.sql(13개 DTO·정확 cohort·시작/환불 중복·재배치/이동/재방문·정정/0분모/미계측·역할), verify-operations-local.mjs(실제 병렬 시작/종료/경쟁/타인), operations-metrics.spec.ts(실제 모바일13개·시작/새로고침/종료·참가자403·320px). 기록 테이블은private/RLS/직접권한없음. 새DB/원격CI/운영행사·과거계측을 이번 로컬 결과로 대체하지 않는다.
