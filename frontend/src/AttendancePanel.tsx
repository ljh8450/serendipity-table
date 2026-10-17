import { useEffect, useRef, useState } from 'react'
import { matchingRequest } from './matching-api'
type Attendance = { assignmentId: string; startsAt: string; opensAt: string; closesAt: string; status: string; checkedInAt: string | null; reviewStatus: string; canCheckIn: boolean }
const date = (s: string) => new Date(s).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })
export default function AttendancePanel({ token, onChanged }: { token: string; onChanged: () => void }) {
 const [data, setData] = useState<{ attendances: Attendance[] } | null>(null)
 const [error, setError] = useState('')
 const [busy, setBusy] = useState(false)
 const [attempt, setAttempt] = useState(0)
 const keys = useRef<Record<string,string>>({})
 useEffect(() => {
  let active = true
  matchingRequest<{ attendances: Attendance[] }>(token, '/attendance').then(v => { if (active) { setData(v); setError('') } }).catch(() => { if (active) setError('참석 상태를 불러오지 못했어요. 다시 확인해 주세요.') })
  return () => { active = false }
 }, [token, attempt])
 async function checkIn(id: string) {
  setBusy(true); setError('')
  keys.current[id] ??= crypto.randomUUID()
  try { setData(await matchingRequest(token, '/attendance/check-in', { assignmentId: id, requestKey: keys.current[id] })); onChanged() }
  catch (cause) { setError(cause instanceof Error && cause.message === 'CHECK_IN_CLOSED' ? '체크인 가능 시간이 아니에요. 참석 상태를 새로고침해 주세요.' : '체크인을 확인하지 못했어요. 같은 버튼으로 다시 시도해 주세요.') }
  finally { setBusy(false) }
 }
 return <section aria-labelledby="attendance-title"><h3 id="attendance-title">나의 참석</h3>
  <p>식당에 도착하면 체크인해 주세요. 한국 시각 기준 시작 30분 전부터 시작 후 3시간까지 가능해요.</p>
  <button type="button" className="secondary" disabled={busy} onClick={() => setAttempt(v => v + 1)}>참석 상태 새로고침</button>
  {error && <p role="alert">{error}</p>}
  {!data && !error && <p>참석 상태를 확인하고 있어요.</p>}
  {data && !data.attendances.length && <p>체크인할 확정 식탁이 없어요. 나의 매칭 상태를 확인해 주세요.</p>}
  {data?.attendances.map(a => <div className="previous-forms" key={a.assignmentId}>
   <h4>{date(a.startsAt)} 식탁</h4>
   <p>체크인 가능: {date(a.opensAt)} ~ {date(a.closesAt)} 직전</p>
   <p role="status">{a.status === 'ATTENDED' ? '참석 확인됨' : a.status === 'NO_SHOW' ? '운영 검토 후 미참석으로 확인됐어요.' : a.reviewStatus === 'PENDING' ? '체크인 기록이 없어 운영자가 참석 여부를 확인 중이에요.' : '참석 예정'}</p>
   {a.checkedInAt && <p>체크인: {date(a.checkedInAt)}</p>}
   {a.canCheckIn && <button type="button" disabled={busy} onClick={() => checkIn(a.assignmentId)}>{busy ? '체크인 확인 중…' : '도착 체크인'}</button>}
  </div>)}
 </section>
}
