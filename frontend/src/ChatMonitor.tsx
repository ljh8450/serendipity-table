import { useEffect, useState } from 'react'
import { matchingRequest } from './matching-api'
type Monitor = { rooms: { id: string; status: string; regionLabel: string; startsAt: string; memberCount: number; messageCount: number }[]; exceptions: { eventId: string; code: string; status: string; attempts: number }[] }
export default function ChatMonitor({ token }: { token: string }) {
  const [data, setData] = useState<Monitor | null>(null)
  const [attempt, setAttempt] = useState(0)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  useEffect(() => {
    let active = true
    matchingRequest<Monitor>(token, '/operations/chat').then(v => { if (active) { setData(v); setError('') } }).catch(() => { if (active) setError('단체방 실행 상태를 불러오지 못했어요. 권한과 연결을 확인하고 다시 시도해 주세요.') })
    return () => { active = false }
  }, [token, attempt])
  async function retry(eventId: string) {
    setBusy(true)
    try { setData(await matchingRequest<Monitor>(token, '/operations/chat/retry', { eventId })); setError('') }
    catch { setError('재시도하지 못했어요. 상태를 새로고침하고 다시 확인해 주세요.') }
    finally { setBusy(false) }
  }
  return <section aria-labelledby="chat-monitor-title"><h3 id="chat-monitor-title">단체방 실행 상태</h3>
    <p>방 생성·구성원 동기화의 상태와 건수만 제공해요. 참가자의 대화 원문은 조회하지 않아요.</p>
    <button type="button" className="secondary" disabled={busy} onClick={() => setAttempt(v => v + 1)}>단체방 실행 상태 새로고침</button>
    {error && <p role="alert">{error}</p>}{!data && !error && <p>단체방 상태를 불러오고 있어요.</p>}
    {data && <>{!data.rooms.length && <p>생성된 단체방이 없어요.</p>}{data.rooms.map(r => <div key={r.id} className="previous-forms"><p>{new Date(r.startsAt).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })} · {r.regionLabel}</p><p>{r.status === 'OPEN' ? '열림' : '닫힘'} · 동기화된 구성원 {r.memberCount}명 · 저장 메시지 {r.messageCount}개</p></div>)}
      <h4>단체방 확인 필요</h4>{!data.exceptions.length && <p>현재 단체방 실행 예외가 없어요.</p>}{data.exceptions.map(e => <div key={e.eventId} className="previous-forms"><p>단체방 구성/상태 확인 필요 · 시도 {e.attempts}회 · {e.status === 'EXCEPTION' ? '운영 확인 필요' : '자동 재시도 대기'}</p>{e.status === 'EXCEPTION' && <button type="button" disabled={busy} onClick={() => void retry(e.eventId)}>단체방 생성 재시도</button>}</div>)}
    </>}
  </section>
}
