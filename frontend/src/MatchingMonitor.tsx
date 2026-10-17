import { useEffect, useState } from 'react'
import { matchingRequest } from './matching-api'
import type { Monitor } from './matching-api'
const labels: Record<string,string> = { QUEUED: '예약 대기', RUNNING: '처리 중', DONE: '완료', EXCEPTION: '조치 필요' }
export default function MatchingMonitor({ token }: { token: string }) {
  const [data, setData] = useState<Monitor | null>(null)
  const [error, setError] = useState('')
  const [attempt, setAttempt] = useState(0)
  const [busy, setBusy] = useState(false)
  useEffect(() => {
    let active = true
    matchingRequest<Monitor>(token, '/operations/matching').then(value => { if (active) { setData(value); setError('') } }).catch(() => { if (active) setError('매칭 운영 정보를 불러오지 못했어요. 권한과 연결을 확인해 주세요.') })
    return () => { active = false }
  }, [token, attempt])
  return <section aria-labelledby="matching-monitor-title"><h3 id="matching-monitor-title">자동 매칭 모니터</h3>
    {error && <p role="alert">{error}</p>}<button type="button" className="secondary" onClick={() => setAttempt(v => v + 1)}>매칭 운영 정보 새로고침</button>
    {!data && !error && <p>예약 작업을 확인하고 있어요.</p>}
    {data && <><p>정책 {data.policy.version} · 최소 점수 {data.policy.minimumScore}</p><p>식당·단체방·안내 연결 대기 이벤트: {data.pendingOutbox}건</p>
      {!data.jobs.length && <p>예약된 매칭 작업이 없어요. 모집을 발행하면 서버가 예약해요.</p>}
      {data.jobs.map(job => <div key={job.id} className="previous-forms"><p>{new Date(job.dueAt).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })} · {labels[job.status] ?? job.status} · 시도 {job.attempts}회</p>
        {job.lastError && <p>처리 사유: {job.lastError}</p>}
        {job.status === 'EXCEPTION' && <button type="button" className="secondary" disabled={busy} onClick={async () => {
          setBusy(true); setError('')
          try { setData(await matchingRequest<Monitor>(token, '/operations/matching/retry', { jobId: job.id })) }
          catch { setError('재시도를 예약하지 못했어요. 현재 예외 상태를 다시 확인해 주세요.') }
          finally { setBusy(false) }
        }}>예외 작업 재시도 예약</button>}
      </div>)}
      <h4>최근 실행 결과</h4>{data.runs.length ? data.runs.map(run => <p key={run.id}>배정 {run.allocated}명 · 후보 조합 {run.candidates}개 · {run.elapsedMs}ms · {run.policyVersion}</p>) : <p>아직 실행 결과가 없어요. 매칭 시각에 자동 실행돼요.</p>}
    </>}
  </section>
}
