# 운영 통합 조회 API

2026-10-18 · OP-01 · SQL042. 로컬 구현이며 production SQL041과 구분한다.

`POST /member/operations/explore`는 검증된 JWT actor와 DB `operator_actor()`를 사용한다. 참가자는 403, 일반 공개 역할은 함수 EXECUTE와 뷰 SELECT 권한이 없다. 요청 query parameter는 422, GET은 405다. 응답은 no-store이며 조회마다 종류별 감사 기록을 남긴다. 도메인 상태를 변경하지 않는다.

본문: `kind` 필수(`members`, `applications`, `slots`, `tables`, `exceptions`), 선택 `q`(최대80자, 대소문자 무시한 리터럴 부분 검색), `status`(최대32자), `page`(0~9999, 기본0), `id`, `memberId`, `slotId`, `tableId`(UUID), `domain`, `paymentStatus`, `matchingStatus`, `attendanceStatus`, `from`/`to`(UTC ISO, at 시작 포함/종료 미포함; 회원은 기간 없음)다. page 외 값은 문자열이다. 알려지지 않은 필드·잘못된 타입/UUID·존재하지 않는 scope·연결 조건에 맞지 않는 detail은 422다. 서버가 역할·연결 관계를 조회하며 actor/time/권한을 본문으로 받지 않는다.

응답: `{items, page, total, pageSize:25}`. 각 item은 `{kind,id,label,status,memberId,slotId,tableId,applicationId,at,facts}`만 포함한다. 정렬은 at 내림차순(null 마지막)→id→domain으로 고정한다. 동일 요청의 count/페이지는 한 SQL statement snapshot이다. 페이지 간 데이터 변경이 있으면 새로고침이 필요하며 장기 고정 snapshot을 보장하지 않는다.

| 종류 | label / facts 허용 필드 |
|---|---|
| 회원 | username 또는 ‘회원’ / role |
| 신청 | username 또는 ‘회원’ / applicationStatus, paymentStatus, matchingStatus, attendanceStatus, selectedSlotIds, selectedRegions |
| 회차 | regionLabel / closesAt, matchesAt, capacity, tableCount, selectedApplicationCount |
| 테이블 | regionLabel / activeCount, venueName, roomStatus |
| 예외 | 업무명 / domain, attempts, nextAction; 식당은 정제된 reason 추가 |

회원 제한은 기존 member_accounts.restricted다. 별도 safety_state와 사건/참석 검토 연결은 OP-02 범위다. 연락처·실명·생년·알레르기·신청 스냅샷·비공개 선호·신고 원문·채팅 원문·구독 endpoint/키·원시 작업 오류는 포함하지 않는다. UUID는 역할 내 연결 조회용이며 참가자에게 이 API를 공개하지 않는다.

회차 신청 수는 해당 회차를 선택한 신청 수이며 실제 배정 인원과 구분한다. 테이블 신청 목록은 현재/과거 배정 근거를 포함하며 현재 인원은 activeCount로 구분한다. 회원 상세→신청, 회차 상세→신청/테이블/예외, 테이블 상세→신청/예외, 신청 상세→회원/선택 회차/현재 테이블을 연결한다. UI는 목록 필터·페이지를 복원한다.

예외는 매칭·식당·방·콘텐츠·피드백·푸시의 현재 EXCEPTION 작업만 포함한다. 같은 outbox ID의 식당/방 실패는 domain으로 구분한다. 대기·정상 완료·취소·무효 테이블 자체를 실패로 합산하지 않는다. 조치는 기존 도메인 모니터와 기존 서버 명령을 사용한다. 새 통합 쓰기/재시도 명령을 만들지 않는다. 신고 검토와 노쇼 후보는 작업 실패와 구분해 OP-02에서 연결한다.

검증: operations_explorer_permissions.sql(rollback), member handler 테스트, operations-explorer.spec.ts(실제 로컬 Auth/API·390/320px). 검증 결과와 한계는 docs/context/operations.md가 기준이다.
