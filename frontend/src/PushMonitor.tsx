import { useEffect, useState } from 'react'
import { matchingRequest } from './matching-api'
type Monitor = { counts: Record<string, number>; exceptions: { jobId: string; code: string; attempts: number }[] }
export default function PushMonitor({ token }: { token: string }) {
  const [data, setData] = useState<Monitor | null>(null)
  const [attempt, setAttempt] = useState(0)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  useEffect(() => {
    let active = true
    matchingRequest<Monitor>(token, '/operations/push').then(v => { if (active) { setData(v); setError('') } })
      .catch(() => { if (active) setError('푸시 실행 상태를 불러오지 못했어요. 권한과 연결을 확인해 주세요.') })
    return () => { active = false }
  }, [token, attempt])
  return <section aria-labelledby="push-monitor-title"><h3 id="push-monitor-title">푸시 실행 상태</h3>
    <p>공급자 수락은 실제 기기 도착과 구분해요. 구독 주소·키·대화 원문은 표시하지 않아요.</p>
    <button className="secondary" disabled={busy} onClick={() => setAttempt(v => v + 1)}>푸시 실행 상태 새로고침</button>
    {error && <p role="alert">{error}</p>}{!data && !error && <p role="status">푸시 실행 상태를 불러오고 있어요.</p>}
    {data && <><p>대기 {data.counts.PENDING ?? 0} · 처리 중 {data.counts.RUNNING ?? 0} · 공급자 수락 {data.counts.ACCEPTED ?? 0} · 취소 {data.counts.CANCELED ?? 0} · 확인 필요 {data.counts.EXCEPTION ?? 0}</p>
      {!data.exceptions.length && <p>현재 푸시 발송 예외가 없어요.</p>}
      {data.exceptions.map(e => <div key={e.jobId} className="previous-forms"><p>{e.code} · 시도 {e.attempts}회</p><button disabled={busy} onClick={async () => {
        setBusy(true)
        try { setData(await matchingRequest<Monitor>(token, '/operations/push/retry', { jobId: e.jobId })); setError('') }
        catch { setError('재시도하지 못했어요. 현재 상태를 다시 확인해 주세요.') }
        finally { setBusy(false) }
      }}>푸시 발송 재시도</button></div>)}
    </>}
  </section>
}
