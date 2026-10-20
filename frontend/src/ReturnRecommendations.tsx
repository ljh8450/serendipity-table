import { useEffect, useState } from 'react'
import { matchingRequest } from './matching-api'

type Slot = { id: string; startsAt: string; closesAt: string; regionCode: string; regionLabel: string; reason: string; datePreference: boolean }
type Data = { status: 'AVAILABLE' | 'RESTRICTED' | 'NO_HISTORY' | 'NO_OPEN_SLOTS'; items: Slot[] }
const date = (s: string) => new Date(s).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })
export default function ReturnRecommendations({ token, onSelect }: { token: string; onSelect: (slot: Slot) => Promise<void> }) {
 const [data, setData] = useState<Data | null>(null)
 const [error, setError] = useState('')
 const [attempt, setAttempt] = useState(0)
 const [notice, setNotice] = useState('')
 const [busy, setBusy] = useState(false)
 useEffect(() => {
  let active = true
  matchingRequest<Data>(token, '/return-recommendations').then(v => { if (active) { setData(v); setError('') } }).catch(() => {
   if (active) { setData(null); setError('다음 모집을 불러오지 못했어요. 연결과 로그인 상태를 확인한 뒤 다시 시도해 주세요.') }
  })
  return () => { active = false }
 }, [token, attempt])
 return <section aria-labelledby="return-title"><h3 id="return-title">다음 식탁 추천</h3>
  <p>마지막으로 참석한 신청에서 선택한 지역·요일·시간대와 본인의 재방문 의사를 참고해요. 추천은 매칭 확정을 보장하지 않아요.</p>
  <button type="button" className="secondary" disabled={busy} onClick={() => { setData(null); setError(''); setNotice(''); setAttempt(v => v + 1) }}>다음 모집 새로고침</button>
  {error && <p role="alert">{error}</p>}{notice && <p role="status">{notice}</p>}
  {!data && !error && <p>모집 중인 다음 식탁을 확인하고 있어요.</p>}
  {data?.status === 'NO_HISTORY' && <p>참석이 확인된 식탁이 생기면 다음 모집을 추천해 드려요. 지금은 회차 신청에서 모집 일정을 확인해 주세요.</p>}
  {data?.status === 'NO_OPEN_SLOTS' && <p>이전에 선택한 지역에 추천할 모집이 없어요. 다음 모집을 기다리거나 회차 신청에서 직접 일정을 확인해 주세요.</p>}
  {data?.status === 'RESTRICTED' && <p>참가 제한 중에는 다음 식탁을 추천하지 않아요. 나의 안전 상태를 확인해 주세요.</p>}
  <div className="card-grid">{data?.items.map(slot => <div className="previous-forms" key={slot.id}>
   <h4>{date(slot.startsAt)}</h4><p>{slot.regionLabel} · 4~6인 식탁</p>
   <p>{slot.reason === 'POSITIVE_EXPERIENCE' ? '다시 방문하고 싶다고 답한 식탁의 지역이에요.' : '이전 참석 신청에서 직접 선택한 지역이에요.'}</p>
   {slot.datePreference && <p>이전에 선택한 일정과 같은 요일·시간대예요.</p>}
   <p>신청 마감: {date(slot.closesAt)}</p>
   <button type="button" disabled={busy} onClick={async () => {
    setBusy(true); setError(''); setNotice('')
    try { await onSelect(slot); setNotice('선택한 일정과 지역을 신청서에 넣었어요. 아래 신청서에서 참가권·동의·일정을 확인해 주세요. 아직 신청·결제되지 않았어요.') }
    catch { setData(null); setError('현재 신청 가능한 일정인지 확인하지 못했어요. 다음 모집을 새로고침하고 다시 선택해 주세요.') }
    finally { setBusy(false) }
   }}>이 일정으로 신청서 작성 · {slot.regionLabel} {date(slot.startsAt)}</button>
  </div>)}</div>
 </section>
}
