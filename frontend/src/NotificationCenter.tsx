import { useEffect, useId, useState } from 'react'

type Item = { id: string; kind: string; title: string; body: string; createdAt: string; read: boolean }
type Inbox = { notifications: Item[]; unreadCount: number }
async function request(token: string, id?: string, signal?: AbortSignal): Promise<Inbox> {
  const response = await fetch(`${import.meta.env.VITE_SUPABASE_URL}/functions/v1/member/notifications${id ? '/read' : ''}`, {
    method: id ? 'POST' : 'GET', signal: signal ?? AbortSignal.timeout(8000),
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    ...(id ? { body: JSON.stringify({ id }) } : {}),
  })
  if (!response.ok) throw new Error('알림을 확인하지 못했어요. 다시 시도해 주세요.')
  return response.json()
}
export default function NotificationCenter({ token }: { token: string }) {
  const id = useId()
  const [data, setData] = useState<Inbox | null>(null)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [attempt, setAttempt] = useState(0)
  useEffect(() => {
    let active = true
    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), 8000)
    request(token, undefined, controller.signal).then(value => { if (active) { setData(value); setError('') } })
      .catch(() => { if (active) setError('알림을 확인하지 못했어요. 다시 시도해 주세요.') })
      .finally(() => clearTimeout(timeout))
    return () => { active = false; clearTimeout(timeout); controller.abort() }
  }, [token, attempt])
  return <section className="intake-section" aria-labelledby={id}>
    <h3 id={id}>나의 알림{data ? ` · 읽지 않음 ${data.unreadCount}개` : ''}</h3>
    <p className="help">매칭·장소·새 대화 안내를 확인해요. 최신 참가 상태는 아래 참가 현황에서 확인해 주세요.</p>
    <button className="secondary" disabled={busy} onClick={() => setAttempt(v => v + 1)}>알림 새로고침</button>
    {error && <p role="alert">{error}</p>}
    {!data && !error && <p role="status">알림을 불러오고 있어요.</p>}
    {data?.notifications.length === 0 && <p>아직 도착한 알림이 없어요. 신청 후 이곳에서 진행 안내를 확인할 수 있어요.</p>}
    {data && <ul>{data.notifications.map(item => <li key={item.id}>
      <strong>{item.title}</strong><p>{item.body}</p>
      <p className="help"><time dateTime={item.createdAt}>{new Date(item.createdAt).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })}</time> · {item.read ? '읽음' : '새 알림'}</p>
      {!item.read && <button className="secondary" disabled={busy} onClick={async () => {
        setBusy(true); setError('')
        try { await request(token, item.id); setData(await request(token)) }
        catch { setError('읽음 처리를 확인하지 못했어요. 알림을 새로고침한 뒤 다시 시도해 주세요.') }
        finally { setBusy(false) }
      }}>읽음으로 표시</button>}
    </li>)}</ul>}
  </section>
}
