import { useEffect, useState } from 'react'
import PersonPreferences from './PersonPreferences'
import FeedbackPanel from './FeedbackPanel'
import AttendancePanel from './AttendancePanel'
import TableChat from './TableChat'
import ResolutionActions from './ResolutionActions'
import { matchingRequest } from './matching-api'
import type { Matching } from './matching-api'
const date = (s: string) => new Date(s).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })
const paymentLabels: Record<string,string> = { PAID: '결제 완료', REFUND_FAILED: '환불 실패 · 재시도 필요', REFUNDED: '환불 완료', PENDING: '결제 대기', FAILED: '결제 실패' }
const labels: Record<string,string> = { WAITING: '매칭 대기', REALLOCATING: '선택 일정 안에서 재배치 중', CONFIRMED: '매칭 확정', ALTERNATIVE_OFFERED: '다른 일정 검토', EXCEPTION: '확인 필요', TRANSFERRED: '일정 이동 완료', NO_MATCH: '신청 종료' }
export default function MatchingPanel({ token, onReview, onChanged }: { token: string; onReview: () => void; onChanged: () => void }) {
  const [data, setData] = useState<Matching | null>(null)
  const [error, setError] = useState('')
  const [attempt, setAttempt] = useState(0)
  useEffect(() => {
    let active = true
    matchingRequest<Matching>(token).then(value => { if (active) { setData(value); setError('') } }).catch(() => { if (active) setError('매칭 상태를 불러오지 못했어요. 다시 확인해 주세요.') })
    return () => { active = false }
  }, [token, attempt])
  return <section aria-labelledby="matching-title"><h3 id="matching-title">나의 매칭 상태</h3>
    {error && <p role="alert">{error}</p>}
    <button type="button" className="secondary" onClick={() => setAttempt(v => v + 1)}>매칭 상태 새로고침</button>
    {!data && !error && <p>서버에서 매칭 상태를 확인하고 있어요.</p>}
    {data && !data.applications.length && <p>아직 신청 내역이 없어요. 참석 가능한 회차를 선택해 주세요.</p>}
    <AttendancePanel token={token} onChanged={onChanged} /><FeedbackPanel token={token} /><PersonPreferences token={token} />
    {data?.applications.map(a => <div key={a.id} className="previous-forms">
      <h4>{a.stored ? '이용권 보관 중' : labels[a.status] ?? '신청 상태 확인'}</h4>
      {a.resolutionReason === 'safety_hold' && <p>참가 제한으로 이 신청의 매칭을 멈췄어요. 이용권 보관·원결제 모의 환불 가능 여부를 아래에서 확인해 주세요.</p>}
      <p>결제: {paymentLabels[a.paymentStatus] ?? '상태 확인'} · 신청: {a.applicationStatus === 'CANCELED' ? '종료' : '접수됨'}</p>
      {a.attentionRequired && <p>자동 처리가 멈춰 운영 확인 중이에요. 상태를 다시 확인해 주세요.</p>}
      {a.nextMatchAt && <p>다음 선택 회차 매칭 예정: {date(a.nextMatchAt)}</p>}
      {a.status === 'REALLOCATING' && <p>선택하신 일정·지역 안에서 다시 살펴보고 있어요.</p>}
      {a.table && <><p>{date(a.table.startsAt)} · {a.table.regionLabel} · {a.table.count}명</p><p>{a.table.chat ? '참가 안내·알림은 준비 중이에요.' : a.table.venue ? '단체방·참가 안내는 준비 중이에요.' : '식당·단체방·참가 안내는 준비 중이에요.'}</p>{a.table.venue ? <div><p>식당: {a.table.venue.name}</p><p>{a.table.venue.address}</p><p>예약명: {a.table.venue.reservationName} · 1인 식사 {a.table.venue.mealPriceKrw.toLocaleString()}원</p><a href={a.table.venue.mapUrl} target="_blank" rel="noopener noreferrer">식당 지도 보기</a></div> : a.table.venueStatus === 'CHECKING' && <p>식사 조건에 맞는 예약 재고를 확인 중이에요. 장소 확정 후 안내할게요.</p>}</>}
      {a.table?.chat && <TableChat key={a.table.chat.roomId} token={token} roomId={a.table.chat.roomId} />}
      {a.history.some(h => h.reason === 'REALLOCATED') && <p>선택하신 다른 회차에서 조건을 확인했어요.</p>}
      {a.status === 'ALTERNATIVE_OFFERED' && <><p>선택한 회차에서 조건에 맞는 식탁을 만들지 못했어요. 동의 없이 다른 일정으로 이동하지 않아요.</p>
        {a.alternatives.length ? <ul>{a.alternatives.map(slot => <li key={slot.id}>{date(slot.startsAt)} · {slot.regionLabel}</li>)}</ul> : <p>현재 검토할 수 있는 새 모집이 없어요.</p>}
        <button type="button" className="secondary" onClick={onReview}>신청 내역·새 일정 검토</button>
      </>}
      {a.stored && <p>이번 신청은 매칭에서 제외됐어요. 다른 모집을 선택해 보관한 권리를 사용할 수 있어요.</p>}
      {a.attendanceStatus === 'CANCELED_LATE' && <p>환불 제한 이후 취소로 기록됐어요. 이용권은 복구되지 않아요.</p>}
      <ResolutionActions application={a} token={token} onChanged={() => { setAttempt(v => v + 1); onChanged() }} />
    </div>)}
  </section>
}
