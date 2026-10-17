import { useEffect, useRef, useState } from 'react'
import { matchingRequest } from './matching-api'
type Peer = { peerId: string; label: string; value: string; revision: number; effective: boolean }
type Event = { assignmentId: string; startsAt: string; regionLabel: string; deadlineAt: string; canEdit: boolean; feedbackSubmitted: boolean; peers: Peer[] }
type Data = { events: Event[] }
const date = (s: string) => new Date(s).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })
const labels: Record<string,string> = { NEUTRAL:'선택 없음',LIKE:'다시 만나고 싶어요',AVOID:'다시 만나고 싶지 않아요' }
export default function PersonPreferences({ token }: { token: string }) {
 const [data, setData] = useState<Data | null>(null)
 const [error, setError] = useState('')
 const [notice, setNotice] = useState('')
 const [busy, setBusy] = useState(false)
 const [attempt, setAttempt] = useState(0)
 const pending = useRef<{ body: string; key: string } | null>(null)
 useEffect(() => {
  let active = true
  matchingRequest<Data>(token, '/preferences').then(v => { if (active) { setData(v); setError('') } }).catch(() => { if (active) setError('참석 이력과 비공개 선택을 불러오지 못했어요. 다시 확인해 주세요.') })
  return () => { active = false }
 }, [token, attempt])
 return <section aria-labelledby="person-preferences-title"><h3 id="person-preferences-title">참석 이력·비공개 사람 선택</h3>
  <p>단체방의 참가자 번호로 함께 참석한 분을 확인해 주세요. 내 선택은 상대에게 공개되지 않아요.</p>
  <p>다시 만나고 싶지 않은 분은 다음 매칭에서 제외해요. 이미 확정된 다음 식탁도 재배치될 수 있어요. 다시 만나고 싶은 선택은 조건이 맞는 조합의 동점 비교에 반영해요.</p>
  <button type="button" className="secondary" disabled={busy} onClick={() => setAttempt(v => v + 1)}>참석 이력·사람 선택 새로고침</button>
  {error && <p role="alert">{error}</p>}{notice && <p role="status">{notice}</p>}
  {!data && !error && <p>참석 이력을 확인하고 있어요.</p>}
  {data && !data.events.length && <p>아직 참석이 확인된 지난 식탁이 없어요.</p>}
  {data?.events.map(e => <div className="previous-forms" key={e.assignmentId}>
   <h4>{date(e.startsAt)} · {e.regionLabel}</h4><p>식탁 평가: {e.feedbackSubmitted ? '제출 완료' : '미제출'}</p>
   <p>사람 선택 수정 기한: {date(e.deadlineAt)} 직전</p>
   {!e.peers.length && <p>현재 선택할 수 있는 공동 참석자가 없어요. 단체방과 참석 확인 상태를 다시 확인해 주세요.</p>}
   {e.peers.map(p => <div key={p.peerId}><h5>{p.label}</h5><p>내 저장된 선택: {labels[p.value]}</p>
    {p.value !== 'NEUTRAL' && <p>{p.effective ? '다음 매칭에 반영되는 선택이에요.' : '이전 선택의 적용 조건을 다시 확인해 주세요.'}</p>}
    {e.canEdit ? <form key={`${p.peerId}-${p.revision}`} onSubmit={async event => {
     event.preventDefault(); const fields = new FormData(event.currentTarget)
     const payload = { assignmentId: e.assignmentId, peerId: p.peerId, value: String(fields.get('value')), revision: p.revision }
     const body = JSON.stringify(payload)
     if (pending.current?.body !== body) pending.current = { body, key: crypto.randomUUID() }
     setBusy(true); setError(''); setNotice('')
     try { setData(await matchingRequest<Data>(token, '/preferences/save', { ...payload, requestKey: pending.current.key })); pending.current = null; setNotice('비공개 선택을 저장했어요. 최신 매칭 상태도 확인해 주세요.') }
     catch (cause) { setError(cause instanceof Error && ['PREFERENCE_CONFLICT','PREFERENCE_CLOSED','FORBIDDEN'].includes(cause.message) ? '선택·참석 상태나 수정 기한이 바뀌었어요. 이력을 새로고침해 주세요.' : '저장을 확인하지 못했어요. 같은 내용으로 다시 시도해 주세요.') }
     finally { setBusy(false) }
    }}>
     <label htmlFor={`person-${p.peerId}`}>{p.label}에 대한 비공개 선택</label><select id={`person-${p.peerId}`} name="value" defaultValue={p.value}>{Object.entries(labels).map(([value,label]) => <option value={value} key={value}>{label}</option>)}</select>
     <label className="check-label"><input type="checkbox" required />내 선택과 다음 식탁이 재배치될 수 있음을 확인했어요.</label>
     <button disabled={busy}>{p.label} 선택 저장</button>
    </form> : <p>사람 선택 수정 기한이 지났어요.</p>}
   </div>)}
  </div>)}
 </section>
}
