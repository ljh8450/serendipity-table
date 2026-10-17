import { useEffect, useState } from 'react'
import { matchingRequest } from './matching-api'
type Job = { jobId: string; kind: 'GUIDE' | 'D1' | 'START'; status: string; attempts: number; code: string | null; scheduledAt: string; startsAt: string; regionLabel: string; retryable: boolean }
export default function ContentMonitor({ token }: { token: string }) {
  const [data, setData] = useState<{ jobs: Job[] } | null>(null)
  const [attempt, setAttempt] = useState(0)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  useEffect(() => {
    let active = true
    matchingRequest<{ jobs: Job[] }>(token, '/operations/content').then(v => { if (active) { setData(v); setError('') } })
      .catch(() => { if (active) setError('예약 안내 상태를 불러오지 못했어요. 권한과 연결을 확인해 주세요.') })
    return () => { active = false }
  }, [token, attempt])
  return <section aria-labelledby="content-monitor-title"><h3 id="content-monitor-title">예약 안내·대화 콘텐츠</h3>
    <p>확인 필요한 작업을 우선으로 최대 100개를 확인해요. 게시 완료와 푸시 도착은 구분되며, 발송 상태는 푸시 실행 상태에서 확인할 수 있어요.</p>
    <button className="secondary" disabled={busy} onClick={() => setAttempt(v => v + 1)}>예약 안내 상태 새로고침</button>
    {error && <p role="alert">{error}</p>}{!data && !error && <p role="status">예약 안내 상태를 불러오고 있어요.</p>}
    {data?.jobs.length === 0 && <p>예약 안내 작업이 없어요. 식탁 확정 후 서버에서 자동 등록해요.</p>}
    {data?.jobs.map(j => <div key={j.jobId} className="previous-forms">
      <p>{j.kind === 'D1' ? '행사 전날 안내' : j.kind === 'START' ? '시작 대화 주제·게임' : '장소·최신 공지'} · {j.regionLabel}</p>
      <p>예약 시각 {new Date(j.scheduledAt).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })} · {({ WAITING: '대기', DONE: '게시 완료', EXCEPTION: '확인 필요', CANCELED: '회수됨' } as Record<string, string>)[j.status]} · 시도 {j.attempts}회</p>
      {j.code && <p>{j.code === 'CONTENT_VENUE_PENDING' ? '식당 배정 확인 필요' : j.code === 'CONTENT_ROOM_PENDING' ? '단체방 생성 확인 필요' : j.code === 'CONTENT_MISSED_WINDOW' ? '게시 가능 시간이 지났어요. 늦은 안내를 자동 발송하지 않아요.' : '구성·게시 상태 확인 필요'}</p>}
      {j.retryable && <button disabled={busy} onClick={async () => {
        setBusy(true)
        try { setData(await matchingRequest<{ jobs: Job[] }>(token, '/operations/content/retry', { jobId: j.jobId })); setError('') }
        catch { setError('재시도하지 못했어요. 현재 상태와 게시 가능 시간을 다시 확인해 주세요.') }
        finally { setBusy(false) }
      }}>예약 안내 재시도</button>}
    </div>)}
  </section>
}
