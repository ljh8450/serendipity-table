import { useEffect, useId, useRef, useState } from 'react'
import type { FormEvent } from 'react'

type Message = { id: string; kind: 'MEMBER' | 'SYSTEM'; body: string; sentAt: string; mine: boolean; sender: string }
type Chat = { roomId: string; messages: Message[]; nextBefore: string | null; members: { label: string; mine: boolean }[] }
async function request<T>(token: string, path: string, payload?: unknown): Promise<T> {
  const response = await fetch(`${import.meta.env.VITE_SUPABASE_URL}/functions/v1/member${path}`, {
    method: payload === undefined ? 'GET' : 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    signal: AbortSignal.timeout(10000), ...(payload === undefined ? {} : { body: JSON.stringify(payload) }),
  })
  const data = await response.json()
  if (!response.ok) throw new Error(data.error?.code ?? 'SERVICE_UNAVAILABLE')
  return data
}
const date = (s: string) => new Date(s).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })
export default function TableChat({ token, roomId, standalone = false }: { token: string; roomId: string; standalone?: boolean }) {
  const [open, setOpen] = useState(standalone)
  const [data, setData] = useState<Chat | null>(null)
  const [draft, setDraft] = useState('')
  const [busy, setBusy] = useState(false)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [closed, setClosed] = useState(false)
  const [historyMode, setHistoryMode] = useState(false)
  const key = useRef(crypto.randomUUID())
  const id = useId()
  function fail(cause: unknown) {
    const code = cause instanceof Error ? cause.message : ''
    if (code === 'FORBIDDEN' || code === 'UNAUTHENTICATED') {
      setData(null); setClosed(true); setDraft('')
      setError(code === 'FORBIDDEN' ? '현재 참여 중인 식탁의 방에만 접근할 수 있어요. 매칭 상태를 다시 확인해 주세요.' : '로그인이 만료됐어요. 다시 로그인해 주세요.')
    } else setError(code === 'CHAT_RATE_LIMIT' ? '메시지를 연속으로 많이 보냈어요. 1분 후 같은 내용으로 다시 시도해 주세요.' : code === 'IDEMPOTENCY_CONFLICT' ? '전송 요청 내용이 달라졌어요. 메시지를 확인해 주세요.' : '연결을 확인하지 못했어요. 메시지는 입력창에 남아 있어요. 새로고침하거나 같은 내용으로 다시 전송해 주세요.')
  }
  useEffect(() => {
    if (!open || closed || historyMode) return
    let active = true
    async function refresh() {
      try { const value = await request<Chat>(token, `/chat/${roomId}`); if (active) { setData(value); setError('') } }
      catch (cause) { if (active) fail(cause) }
    }
    void refresh()
    const timer = window.setInterval(() => { if (document.visibilityState === 'visible') void refresh() }, 5000)
    const visible = () => { if (document.visibilityState === 'visible') void refresh() }
    document.addEventListener('visibilitychange', visible)
    return () => { active = false; window.clearInterval(timer); document.removeEventListener('visibilitychange', visible) }
  }, [token, roomId, open, closed, historyMode])
  async function load(older = false) {
    if (loading || closed) return
    setLoading(true)
    if (older) setHistoryMode(true)
    try {
      const value = await request<Chat>(token, `/chat/${roomId}${older && data?.nextBefore ? `?before=${data.nextBefore}` : ''}`)
      setData(current => older && current ? { ...value, messages: [...value.messages, ...current.messages].filter((m, i, all) => all.findIndex(v => v.id === m.id) === i) } : value)
      setHistoryMode(older); setError('')
    } catch (cause) { fail(cause) }
    finally { setLoading(false) }
  }
  async function send(event: FormEvent) {
    event.preventDefault()
    if (busy || closed || !draft.trim()) return
    setBusy(true); setError(''); setNotice('')
    try {
      await request(token, `/chat/${roomId}/messages`, { requestKey: key.current, body: draft })
      setDraft(''); key.current = crypto.randomUUID(); setNotice('메시지를 전송했어요.'); await load()
    } catch (cause) { fail(cause) }
    finally { setBusy(false) }
  }
  return <section aria-labelledby={`${id}-title`}>
    <h5 style={{ fontSize: 'inherit' }} id={`${id}-title`}>식탁 단체방</h5>
    {!standalone && <button type="button" className="secondary" aria-expanded={open} aria-controls={`${id}-body`} onClick={() => { setOpen(v => !v); setData(null); setHistoryMode(false) }}>{open ? '단체방 닫기' : '단체방 열기'}</button>}
    {open && <div id={`${id}-body`}>
      <p>현재 식탁 참가자만 읽고 쓸 수 있어요. 열린 방에서는 5초마다 최신 대화를 확인해요.</p>
      {error && <p role="alert">{error}</p>}{notice && <p role="status">{notice}</p>}
      {!closed && <button type="button" className="secondary" disabled={loading} onClick={() => void load()}>최신 대화 새로고침</button>}
      {!data && !error && <p>대화를 불러오고 있어요.</p>}
      {!closed && data && <><p>참가자: {data.members.map(m => `${m.label}${m.mine ? ' (나)' : ''}`).join(', ')}</p>
        {historyMode && <p>이전 대화를 보고 있어요. 최신 대화 새로고침을 누르면 자동 갱신을 다시 시작해요.</p>}
        {data.nextBefore && <button type="button" className="secondary" disabled={loading} onClick={() => void load(true)}>이전 대화 불러오기</button>}
        {!data.messages.length && <p>아직 대화가 없어요. 첫 인사를 남겨 주세요.</p>}
        <ol aria-label="대화 메시지" style={{ listStyle: 'none', padding: 0 }}>{data.messages.map(m => <li key={m.id} className="previous-forms">
          <p><strong>{m.kind === 'SYSTEM' ? '시스템 공지' : `${m.sender}${m.mine ? ' (나)' : ''}`}</strong> · <time dateTime={m.sentAt}>{date(m.sentAt)}</time></p>
          <p style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>{m.body}</p>
        </li>)}</ol>
      </>}
      {!closed && <form onSubmit={send}><label htmlFor={`${id}-message`}>보낼 메시지 (최대 1,000자)</label><textarea id={`${id}-message`} value={draft} maxLength={1000} disabled={busy || !data} onChange={e => { setDraft(e.target.value); key.current = crypto.randomUUID() }} /><p>연락처 등 민감한 정보를 대화에 남기지 마세요.</p><button type="submit" disabled={busy || !data || !draft.trim()}>{busy ? '전송 중…' : '메시지 전송'}</button></form>}
    </div>}
  </section>
}
