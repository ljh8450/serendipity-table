import { lazy, Suspense, useEffect, useState } from 'react'
import type { FormEvent } from 'react'
import FeedbackMonitor from './FeedbackMonitor'
const SafetyMonitor = lazy(() => import('./SafetyMonitor'))
import AttendanceMonitor from './AttendanceMonitor'
import ContentMonitor from './ContentMonitor'
import PushMonitor from './PushMonitor'
import ChatMonitor from './ChatMonitor'
import VenueOperations from './VenueOperations'
import MatchingMonitor from './MatchingMonitor'

type Slot = { id: string; startsAt: string; closesAt: string; matchesAt: string | null; refundCutoffAt: string | null; regionLabel: string; capacity: number; published: boolean }
type Document = { id: string; kind: string; version: string; title: string; body: string; active: boolean }
type Operations = { slots: Slot[]; documents: Document[] }
const format = (value: string) => new Date(value).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })
async function request(token: string, path = '', payload?: unknown): Promise<Operations> {
  const response = await fetch(`${import.meta.env.VITE_SUPABASE_URL}/functions/v1/member/operations${path}`, {
    method: payload === undefined ? 'GET' : 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    signal: AbortSignal.timeout(10000), ...(payload === undefined ? {} : { body: JSON.stringify(payload) }),
  })
  const data = await response.json()
  if (!response.ok) throw new Error(data.error?.code ?? 'SERVICE_UNAVAILABLE')
  if (!Array.isArray(data.slots) || !Array.isArray(data.documents)) throw new Error('SERVICE_UNAVAILABLE')
  return data
}
export default function OperationsArea({ token }: { token: string }) {
  const [data, setData] = useState<Operations | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [attempt, setAttempt] = useState(0)
  useEffect(() => {
    let active = true
    request(token).then(value => { if (active) { setData(value); setError('') } }).catch(() => { if (active) setError('운영 정보를 불러오지 못했어요. 권한과 연결을 확인해 주세요.') })
    return () => { active = false }
  }, [token, attempt])
  async function run(path: string, payload: unknown, notice: string) {
    setBusy(true); setError(''); setNotice('')
    try { setData(await request(token, path, payload)); setNotice(notice) }
    catch (cause) { setError(cause instanceof Error && cause.message === 'CONSENT_CHANGED' ? '이미 사용한 동의 버전이에요. 새 버전을 입력해 주세요.' : '저장하지 못했어요. 시각 순서·입력 내용·운영 권한을 확인해 주세요.') }
    finally { setBusy(false) }
  }
  async function createSlot(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const fields = new FormData(event.currentTarget)
    const time = (key: string) => new Date(`${fields.get(key)}:00+09:00`).toISOString()
    await run('/slot', { startsAt: time('startsAt'), opensAt: time('opensAt'), closesAt: time('closesAt'), matchesAt: time('matchesAt'), regionCode: fields.get('regionCode'), capacity: Number(fields.get('capacity')) }, '모집 초안을 만들었어요. 목록에서 확인 후 발행해 주세요.')
  }
  return <section className="member-area" aria-labelledby="operations-title">
    <h2 id="operations-title">운영 모집·동의 설정</h2><p>모집·문서를 사전 설정하면 신청과 매칭은 서버 규칙으로 처리해요.</p>
    {error && <div role="alert"><p>{error}</p><button className="secondary" onClick={() => setAttempt(v => v + 1)}>운영 정보 다시 불러오기</button></div>}
    {notice && <p role="status">{notice}</p>}
    {!data && !error && <p>운영 정보를 불러오고 있어요.</p>}
    {data && <>
      <Suspense fallback={<p>안전 검토 화면을 불러오고 있어요.</p>}><SafetyMonitor token={token} /></Suspense><FeedbackMonitor token={token} /><AttendanceMonitor token={token} /><MatchingMonitor token={token} /><VenueOperations token={token} /><ChatMonitor token={token} /><PushMonitor token={token} /><ContentMonitor token={token} />
      <form onSubmit={createSlot}><h3>모집 초안 만들기</h3><p>모든 입력 시각은 한국 시각(KST)이에요. 모집 시작 → 마감 → 매칭 → 행사 순서로 입력해 주세요.</p>
        {(['opensAt','closesAt','matchesAt','startsAt'] as const).map((key, index) => <div key={key}><label htmlFor={`slot-${key}`}>{['모집 시작','모집 마감','매칭 실행','행사 시작'][index]} (KST)</label><input id={`slot-${key}`} name={key} type="datetime-local" required /></div>)}
        <label htmlFor="slot-region">모집 지역</label><select id="slot-region" name="regionCode"><option value="hongdae">홍대</option><option value="jamsil">잠실</option><option value="gangnam">강남</option><option value="jongno">을지로</option></select>
        <label htmlFor="slot-capacity">모집 정원</label><input id="slot-capacity" name="capacity" type="number" min={4} max={240} defaultValue={24} required />
        <button disabled={busy}>모집 초안 생성</button>
      </form>
      <h3>모집 발행 상태</h3>{data.slots.length ? data.slots.map(slot => <div className="previous-forms" key={slot.id}><p>{format(slot.startsAt)} · {slot.regionLabel} · 정원 {slot.capacity}명 · {slot.published ? '발행됨' : '초안'}</p><p>마감 {format(slot.closesAt)} · 매칭 {slot.matchesAt ? format(slot.matchesAt) : '미설정'} · 환불 제한 {slot.refundCutoffAt ? format(slot.refundCutoffAt) : '미설정'}</p><button type="button" className="secondary" disabled={busy} onClick={() => run('/publish', { slotId: slot.id, published: !slot.published }, '모집 공개 상태를 변경했어요.')}>{slot.published ? '모집 비공개' : '모집 발행'}</button></div>) : <p>모집 초안이 없어요. 첫 회차를 만들어 주세요.</p>}
      <form onSubmit={async event => {
        event.preventDefault(); const fields = new FormData(event.currentTarget)
        await run('/document', Object.fromEntries(['kind','version','title','body'].map(key => [key, fields.get(key)])), '새 필수 동의 버전을 발행했어요. 기존 수락 이력은 보존돼요.')
      }}><h3>필수 동의 새 버전 발행</h3><p>확인된 운영 전문만 입력해 주세요. 발행한 내용은 수정하지 않고 새 버전으로 교체해요.</p>
        <label htmlFor="document-kind">동의 종류</label><select id="document-kind" name="kind"><option value="privacy">개인정보 수집·이용</option><option value="operations">운영 정책</option></select>
        <label htmlFor="document-version">동의 버전</label><input id="document-version" name="version" maxLength={80} required />
        <label htmlFor="document-title">문서 제목</label><input id="document-title" name="title" maxLength={100} required />
        <label htmlFor="document-body">동의 전문</label><textarea id="document-body" name="body" maxLength={10000} required />
        <label className="check-label"><input type="checkbox" required />전문을 검토했으며 새 필수 동의로 공개하는 것을 확인합니다.</label><button disabled={busy}>필수 동의 발행</button>
      </form>
      <h3>동의 문서 이력</h3>{data.documents.length ? data.documents.map(doc => <details key={doc.id}><summary>{doc.title} · {doc.version} · {doc.active ? '현재 버전' : '이전 버전'}</summary><p className="policy-body">{doc.body}</p></details>) : <p>발행된 동의가 없어요. 두 종류의 전문을 준비해 주세요.</p>}
    </>}
  </section>
}
