import { useEffect, useRef, useState } from 'react'
import { matchingRequest } from './matching-api'
type Review = { assignmentId: string; applicationId: string; startsAt: string; status: string; reviewStatus: string; canReview: boolean; actions: { action: string; at: string }[] }
type Data = { reviews: Review[] }
export default function AttendanceMonitor({ token }: { token: string }) {
 const [data, setData] = useState<Data | null>(null)
 const [error, setError] = useState('')
 const [busy, setBusy] = useState(false)
 const [attempt, setAttempt] = useState(0)
 const pending = useRef<{ body: string; key: string } | null>(null)
 useEffect(() => {
  let active = true
  matchingRequest<Data>(token, '/operations/attendance').then(v => { if (active) { setData(v); setError('') } }).catch(() => { if (active) setError('참석 검토 목록을 불러오지 못했어요. 권한과 연결을 확인해 주세요.') })
  return () => { active = false }
 }, [token, attempt])
 return <section aria-labelledby="attendance-monitor-title"><h3 id="attendance-monitor-title">참석·노쇼 후보 검토</h3>
  <p>미체크인은 노쇼 확정이 아니에요. 확인 근거를 기록한 뒤 처리해 주세요. 이 조치로 이용 제한이나 결제 차감은 적용되지 않아요.</p>
  <button type="button" className="secondary" disabled={busy} onClick={() => setAttempt(v => v + 1)}>참석 검토 새로고침</button>
  {error && <p role="alert">{error}</p>}
  {!data && !error && <p>검토 목록을 확인하고 있어요.</p>}
  {data && !data.reviews.length && <p>검토할 미체크인 후보가 없어요.</p>}
  {data?.reviews.map(r => <form key={r.assignmentId} className="previous-forms" onSubmit={async event => {
   event.preventDefault(); const fields = new FormData(event.currentTarget)
   const payload = { assignmentId: r.assignmentId, outcome: String(fields.get('outcome')), reason: String(fields.get('reason')) }
   const body = JSON.stringify(payload)
   if (pending.current?.body !== body) pending.current = { body, key: crypto.randomUUID() }
   setBusy(true); setError('')
   try { setData(await matchingRequest<Data>(token, '/operations/attendance/review', { ...payload, requestKey: pending.current.key })); pending.current = null }
   catch { setError('검토를 저장하지 못했어요. 입력·현재 배정 상태를 확인하고 다시 시도해 주세요.') }
   finally { setBusy(false) }
  }}>
   <h4>{new Date(r.startsAt).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })}</h4>
   <p>신청 식별자: {r.applicationId}</p><p>검토 상태: {r.reviewStatus === 'PENDING' ? '확인 대기' : r.reviewStatus === 'ATTENDED' ? '참석 확인' : '노쇼 확인'}</p>
   <details><summary>조치 이력 {r.actions.length}건</summary><ul>{r.actions.map((a, i) => <li key={i}>{a.action === 'NO_SHOW' ? '노쇼 확인' : a.action === 'ATTENDED' ? '참석 확인' : '본인 체크인'} · {new Date(a.at).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })}</li>)}</ul></details>
   {r.canReview ? <><label htmlFor={`outcome-${r.assignmentId}`}>확인 결과</label><select id={`outcome-${r.assignmentId}`} name="outcome"><option value="ATTENDED">참석 확인</option><option value="NO_SHOW">노쇼 확인</option></select>
    <label htmlFor={`reason-${r.assignmentId}`}>확인 근거 (5~500자, 개인정보 입력 금지)</label><textarea id={`reason-${r.assignmentId}`} name="reason" minLength={5} maxLength={500} required />
    <label className="check-label"><input type="checkbox" required />참석 여부와 확인 근거를 검토했습니다.</label>
    <button disabled={busy}>참석 검토 저장</button></> : <p>배정이 변경되어 검토할 수 없어요.</p>}
  </form>)}
 </section>
}
