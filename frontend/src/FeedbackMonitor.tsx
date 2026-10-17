import { useEffect, useState } from 'react'
import { matchingRequest } from './matching-api'
type Data = { jobs: { id: string; kind: string; status: string; attempts: number; dueAt: string; lastError: string | null }[] }
const states: Record<string,string> = { WAITING:'대기',DONE:'알림 생성 완료',CANCELED:'요청 종료',EXCEPTION:'운영 확인 필요' }
export default function FeedbackMonitor({ token }: { token: string }) {
 const [data, setData] = useState<Data | null>(null)
 const [error, setError] = useState('')
 const [busy, setBusy] = useState(false)
 const [attempt, setAttempt] = useState(0)
 useEffect(() => {
  let active = true
  matchingRequest<Data>(token, '/operations/feedback').then(v => { if (active) { setData(v); setError('') } }).catch(() => { if (active) setError('피드백 요청 상태를 불러오지 못했어요. 권한과 연결을 확인해 주세요.') })
  return () => { active = false }
 }, [token, attempt])
 return <section aria-labelledby="feedback-monitor-title"><h3 id="feedback-monitor-title">피드백 요청·리마인드</h3>
  <p>요청 알림 생성 상태를 확인해요. 실제 푸시 전송은 발송 모니터에서 확인해 주세요.</p>
  <button type="button" className="secondary" disabled={busy} onClick={() => setAttempt(v => v + 1)}>피드백 요청 새로고침</button>
  {error && <p role="alert">{error}</p>}{!data && !error && <p>요청 상태를 확인하고 있어요.</p>}
  {data && !data.jobs.length && <p>피드백 요청 작업이 없어요.</p>}
  {data?.jobs.map(j => <div className="previous-forms" key={j.id}><p>{j.kind === 'REQUEST' ? '평가 요청' : '미응답 리마인드'} · {states[j.status]} · 시도 {j.attempts}회</p><p>{new Date(j.dueAt).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })}</p>
   {j.lastError && <p>알림 생성에 실패했어요. 현재 참가 상태와 제출 기한을 확인해 주세요.</p>}
   {j.status === 'EXCEPTION' && <button type="button" className="secondary" disabled={busy} onClick={async () => {
    setBusy(true); setError('')
    try { setData(await matchingRequest<Data>(token, '/operations/feedback/retry', { jobId: j.id })) }
    catch { setError('재시도하지 못했어요. 기한·참석·이미 응답했는지 확인해 주세요.') }
    finally { setBusy(false) }
   }}>피드백 요청 재시도</button>}
  </div>)}
 </section>
}
