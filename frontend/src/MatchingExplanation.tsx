import type { MatchApplication } from './matching-api'
type Explanation = NonNullable<MatchApplication['explanation']> & { previousMeetingPairs?: number }
const checks: Record<string, string> = { minimumScore: '최소 매칭 기준', size: '4~6인', ageGap: '연령차 8세 이내', selectedSlot: '선택 일정', selectedRegion: '선택 지역', exclusions: '제외 관계 없음' }
const interests: Record<string, string> = { film: '영화·드라마', music: '음악', books: '책', exercise: '운동', food: '음식', travel: '여행', photo: '사진', art: '예술', fashion: '패션', study: '공부' }
const date = (s: string) => new Date(s).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })
export default function MatchingExplanation({ data }: { data: Explanation }) {
 return <details><summary>매칭 이유와 처리 이력</summary>
  <p>재배치 {data.reallocationCount}회 · 최종 배치 사유: {({ CONFIRMED: '선택 회차에서 조건 충족', REALLOCATED: '선택한 다른 회차에서 조건 충족', ALTERNATIVE_OFFERED: '선택 범위에서 조건 미충족 · 대안 선택', WAITING_SELECTED_SLOT: '선택한 다음 회차 대기', NEXT_BATCH: '다음 검색 대기' } as Record<string, string>)[data.finalReason ?? ''] ?? '처리 이력 없음'}</p>
  {data.confirmedAt && <p>확정: {date(data.confirmedAt)}</p>}
  {data.failedAt && <p>매칭 실패: {date(data.failedAt)}</p>}
  {data.checks && <><p>나이 범위: {data.ageMin}~{data.ageMax}세 · 차이 {(data.ageMax ?? 0) - (data.ageMin ?? 0)}세 (행사 연도 기준 연나이)</p>
   <p>성별 구성: {Object.entries(data.genderComposition ?? {}).map(([key, n]) => `${key === 'male' ? '남성' : key === 'female' ? '여성' : '기타'} ${n}명`).join(' · ')}</p>
   <p>MBTI 구성: {Object.entries(data.mbtiComposition ?? {}).map(([key, n]) => `${key} ${n}명`).join(' · ')}</p>
   <p>공통 관심사: {data.commonInterests?.map(key => interests[key] ?? key).join(' · ') || '공통 항목 없음'}</p>
   {data.preferredTraitsMatchedPeers !== undefined && <p>내가 희망한 대화 성향과 겹치는 참가자: {data.preferredTraitsMatchedPeers}/{data.peerCount}명 · 이전에 만난 참가자: {data.previouslyMetPeers}명</p>}
   {data.previousMeetingPairs !== undefined && <p>이전에 만난 참가자 쌍: {data.previousMeetingPairs}쌍</p>}
   <ul>{Object.entries(data.checks).map(([key, ok]) => <li key={key}>{checks[key] ?? key}: {ok ? '충족' : '재확인 필요'}</li>)}</ul>
   {data.participantConditions && <ul>{data.participantConditions.map(p => <li key={p.participantNo}>구성 {p.participantNo}{p.isMe ? ' (나)' : ''}: 희망 일정 {p.selectedSlot ? '충족' : '재확인 필요'} · 희망 지역 {p.selectedRegion ? '충족' : '재확인 필요'}</li>)}</ul>}
   <p>적용 규칙: {data.policyVersion}</p></>}
 </details>
}
