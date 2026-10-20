import { useEffect, useRef, useState } from 'react'
import { matchingRequest } from './matching-api'
import type { Matching } from './matching-api'
import TableChat from './TableChat'

export default function ChatPage({ token }: { token: string }) {
  const [data, setData] = useState<Matching | null>(null)
  const [error, setError] = useState('')
  const [attempt, setAttempt] = useState(0)
  const [selected, setSelected] = useState<string | null>(null)
  const heading = useRef<HTMLHeadingElement>(null)
  useEffect(() => {
    let active = true
    matchingRequest<Matching>(token).then(value => {
      if (active) { setData(value); setError('') }
    }).catch(() => { if (active) setError('채팅방 목록을 불러오지 못했어요. 다시 시도해 주세요.') })
    return () => { active = false }
  }, [token, attempt])
  useEffect(() => { heading.current?.focus() }, [selected])
  const rooms = [...new Map((data?.applications ?? []).flatMap(a => a.table?.chat ? [[a.table.chat.roomId, a.table] as const] : [])).values()]
  const room = rooms.find(r => r.chat?.roomId === selected)
  const label = (r: typeof rooms[number]) => `${new Date(r.startsAt).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })} · ${r.regionLabel}`
  return <section className="chat-page" aria-labelledby="chat-page-title">
    <h3 id="chat-page-title" ref={heading} tabIndex={-1}>{room ? label(room) : '식탁 채팅방'}</h3>
    {room ? <>
      <button type="button" className="secondary" onClick={() => setSelected(null)}>채팅방 목록으로</button>
      <TableChat key={room.chat!.roomId} token={token} roomId={room.chat!.roomId} standalone />
    </> : <>
      <p>대화하고 싶은 식탁의 채팅방을 선택해 주세요.</p>
      <button type="button" className="secondary" onClick={() => { setData(null); setError(''); setAttempt(v => v + 1) }}>채팅방 목록 새로고침</button>
      {error && <p role="alert">{error}</p>}
      {!data && !error && <p role="status">참여 중인 채팅방을 불러오고 있어요.</p>}
      {data && !rooms.length && <><p>아직 참여할 수 있는 채팅방이 없어요. 매칭 확정 후 방이 준비되면 여기에 표시돼요.</p><a className="next-action" href="#table">내 식탁에서 매칭 상태 확인</a></>}
      <div className="card-grid">{rooms.map(r => <div className="previous-forms" key={r.chat!.roomId}>
        <h4>{label(r)}</h4><p>식탁 참가자 {r.count}명</p>
        <button type="button" onClick={() => setSelected(r.chat!.roomId)} aria-label={`${label(r)} 채팅방 열기`}>채팅방 열기</button>
      </div>)}</div>
    </>}
  </section>
}
