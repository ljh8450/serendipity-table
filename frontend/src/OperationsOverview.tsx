import { useEffect, useState } from 'react'
import { matchingRequest } from './matching-api'
type Data = { asOf: string; counts: Record<string, number>; slots: { id: string; startsAt: string; regionLabel: string; counts: Record<string, number> }[] }
const labels: Record<string, string> = { sameDayCancellations: '행사 당일 취소', reallocatedSucceeded: '자동 재배치 확정 신청', pendingChoice: '대안·환불 선택 대기', refundFailures: '환불 실패', conditionConflicts: '미해결 매칭 작업', venueUnavailable: '식당 배정 예외 테이블', messageFailures: '예약 안내·푸시 실패', lateCancellations: '마감 후 취소', noShowCandidates: '미확정 노쇼 후보', pendingReports: '미처리 신고', applicants: '신청 회원', applications: '누적 신청', paid: '결제 완료 신청', waiting: '매칭 대기·처리 중', reallocating: '재배치 중', confirmed: '확정 신청', failedMatching: '대안 선택·매칭 종료', tables: '확정 테이블', attended: '참석', noShows: '확인 노쇼', refunds: '환불 성공 거래', financeFailures: '결제·환불 실패 신청', exceptions: '조치 필요 예외' }
export default function OperationsOverview({ token }: { token: string }) {
 const [slotId, setSlotId] = useState('')
 const [data, setData] = useState<Data | null>(null)
 const [error, setError] = useState('')
 const [attempt, setAttempt] = useState(0)
 useEffect(() => {
  let active = true
  matchingRequest<Data>(token, '/operations/overview').then(v => { if (active) { setData(v); setError('') } }).catch(() => { if (active) setError('운영 현황을 불러오지 못했어요. 다시 시도해 주세요.') })
  return () => { active = false }
 }, [token, attempt])
 return <section className="operations-overview" aria-labelledby="overview-title"><h3 id="overview-title">운영 현황</h3>
  <p>전체 또는 선택 회차의 현재 상태별 건수예요. 서로 다른 상태 축의 건수를 합산하지 마세요. 비율·기간별 분석은 아래 운영 지표에서 확인해요.</p>
  <button type="button" className="secondary" onClick={() => setAttempt(v => v + 1)}>운영 현황 새로고침</button>
  {error && <p role="alert">{error}</p>}{!data && !error && <p>운영 현황을 확인하고 있어요.</p>}
  {data && <>{!data.slots.length && <p>아직 모집 회차가 없어요. 모집 초안을 만든 뒤 발행해 주세요.</p>}<label htmlFor="overview-slot">현황 회차</label><select id="overview-slot" value={slotId} onChange={e => setSlotId(e.target.value)}><option value="">전체 회차</option>{data.slots.map(s => <option key={s.id} value={s.id}>{new Date(s.startsAt).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })} · {s.regionLabel}</option>)}</select><p>최신 100개 회차를 선택할 수 있어요. 성공 건수·성공률의 분자/분모는 아래 운영 지표에서 같은 회차로 확인해 주세요.</p><p>집계: {new Date(data.asOf).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })}</p><dl>{Object.entries(slotId ? data.slots.find(s => s.id === slotId)?.counts ?? {} : data.counts).map(([key, n]) => <div key={key}><dt>{labels[key] ?? key}</dt><dd>{n.toLocaleString()}건</dd></div>)}</dl></>}
 </section>
}
