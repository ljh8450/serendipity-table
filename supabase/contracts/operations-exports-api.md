# 운영 CSV 내보내기

2026-10-18 · OP-03 · SQL044 · SQL047/member와 함께 운영 배포·원격 권한 검증 완료. `POST /member/operations/export`는 검증된 JWT→operator_actor를 사용한다. 참가자403·GET405·query422. 본문은 operations/explore의 적용 필터와 동일하되 page/id는 거부한다. 페이지 단위가 아니라 같은 정렬/필터의 단일 statement snapshot을 내보낸다. from(포함)/to(미포함)는 UTC ISO 문자열이며 목록과 동일한 at 기준이다. UI 입력은 KST→UTC 변환한다. 회원은 날짜 필드가 없으므로 기간 필터를 거부한다.

DTO: `{kind,columns,exportedAt,total,rows}`. columns는 종류별 코드 고정 허용 목록이며 rows는 해당 컬럼만 투영한다. 5,000건을 넘으면409 EXPORT_LIMIT로 전부 거부하며 조용히 잘라내지 않는다. UI는 회차/회원/검색 조건을 좁히도록 안내한다. 조회 시간은 exportedAt UTC, UI는 KST 표시·파일명에 UTC 시각을 포함한다. CSV 본문 날짜도 서버 UTC ISO를 보존한다.

| 종류 | CSV 컬럼 |
|---|---|
| members | id,label,status,role |
| applications | id,label,memberId,applicationStatus,paymentStatus,matchingStatus,attendanceStatus,tableId,at,selectedSlotIds,selectedRegions |
| slots | id,label,status,at,closesAt,matchesAt,capacity,tableCount,selectedApplicationCount |
| tables | id,label,status,slotId,at,activeCount,venueName,roomStatus |
| exceptions | id,label,status,domain,slotId,tableId,applicationId,at,attempts,reason,nextAction |

추가 안전 검토 권한이 있어도 CSV에 원문·신고자/대상·개인별 선호를 추가하지 않는다. 연락처·실명·생년·신청 원본·채팅원문·기기키·작업 원시 오류는 제외한다. role은 서버 판정된 계정 역할이다. 클라이언트 컬럼 지정은 허용하지 않는다.

CSV는 UTF-8 BOM·CRLF·모든 셀 double quote·따옴표 이스케이프, 배열은 세미콜론 구분이다. 공백/제어문자 뒤 =,+,-,@ 및 선행 제어문자는 apostrophe로 중화한다. 한글/쉼표/개행을 보존한다. Blob URL은 다운로드 후 회수한다. 서버는 요청 필터/actor/건수/시각을 private operations_exports에 기록하고 일반 직접 접근을 금지한다. 기존 감사와 같이 actor UUID는 Auth 삭제의 FK 차단을 추가하지 않으며 보관 정책은 PRIV-001 결정 범위를 따른다.

근거: operations_exports_permissions.sql(27건 전체/필터·기간경계/권한·감사/5001건 거부), operations-csv.test.ts(수식·제어문자·한글/개행/컬럼), operations-explorer.spec.ts(실제 모바일 다운로드/필터/UTF-8/참가자403). 배포 경계·실행 결과는 docs/context/operations.md 참조.
