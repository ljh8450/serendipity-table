import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import MatchingExplanation from './MatchingExplanation'
import type { MatchApplication } from './matching-api'
import OperationsInsights from './OperationsInsights'
import type { SafetyCaseLink } from './OperationsInsights'
import { operationsCsv } from './operations-csv'
import type { OperationsExport } from './operations-csv'
import { matchingRequest } from './matching-api'

type Kind = 'members' | 'applications' | 'slots' | 'tables' | 'exceptions'
type Query = { kind: Kind; q: string; status: string; page: number; id?: string; memberId?: string; slotId?: string; tableId?: string; domain?: string; paymentStatus?: string; matchingStatus?: string; attendanceStatus?: string; from?: string; to?: string }
type Item = { kind: Kind; id: string; label: string; status: string; memberId: string | null; slotId: string | null; tableId: string | null; applicationId: string | null; at: string | null; facts: Record<string, unknown> }
type Data = { items: Item[]; page: number; total: number; pageSize: number }
const kinds: Record<Kind, string> = { members: '회원', applications: '신청', slots: '회차', tables: '테이블', exceptions: '예외' }
const labels: Record<string, string> = { ticketType: '이용권 종류', ticketCode: '이용권 코드', creditStored: '권리 보관', carriedPaymentId: '유지 원결제', membershipExpiresAt: '멤버십 만료', gender: '성별', ageBand: '연령대', mbti: 'MBTI', interests: '관심사', attendedCount: '이전 참석', confirmedNoShowCount: '확인 노쇼', lateCancellationCount: '마감 후 취소', participationAllowed: '현재 참가 가능', ledger: '모의 거래 이력', role: '역할', applicationStatus: '신청', paymentStatus: '결제', matchingStatus: '매칭', attendanceStatus: '참석', selectedSlotIds: '선택 회차', selectedRegions: '선택 지역', closesAt: '모집 마감', matchesAt: '매칭 실행', capacity: '정원', tableCount: '테이블 수', selectedApplicationCount: '선택 신청 수', activeCount: '현재 인원', venueName: '식당', roomStatus: '단체방', domain: '담당 업무', attempts: '시도 횟수', reason: '사유', nextAction: '다음 행동' }
const states: Record<string, string> = { WITHDRAWN: '탈퇴', ACTIVE: '이용 가능', RESTRICTED: '이용 제한', PUBLISHED: '발행', DRAFT: '초안', SUBMITTED: '제출', CANCELED: '취소', PENDING: '대기', PAID: '결제 완료', FAILED: '실패', WAITING: '매칭 대기', MATCHING: '매칭 중', REALLOCATING: '재배치 중', CONFIRMED: '확정', INVALIDATED: '배정 무효', EXCEPTION: '운영 확인 필요', ALTERNATIVE_OFFERED: '대안 선택 가능', TRANSFERRED: '이동', NO_MATCH: '매칭 없음', SCHEDULED: '참석 예정', ATTENDED: '참석', CANCELED_EARLY: '기한 내 취소', CANCELED_LATE: '마감 후 취소', NO_SHOW: '확인 노쇼', OPEN: '열림', CLOSED: '종료', participant: '참가자', operator: '운영자' }
const initial: Query = { kind: 'applications', q: '', status: '', page: 0 }
const time = (v: string) => new Date(v).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })
const value = (key: string, v: unknown): string => v == null ? '미설정' : typeof v === 'boolean' ? v ? '예' : '아니오' : Array.isArray(v) ? v.join(', ') : key.endsWith('At') && typeof v === 'string' ? time(v) : states[String(v)] ?? String(v)

export default function OperationsExplorer({ token, onSafetyCase }: { token: string; onSafetyCase: (v: SafetyCaseLink) => void }) {
 const [query, setQuery] = useState<Query>(initial)
 const [history, setHistory] = useState<Query[]>([])
 const [data, setData] = useState<Data | null>(null)
 const [error, setError] = useState('')
 const [attempt, setAttempt] = useState(0)
 const [exporting, setExporting] = useState(false)
 const [exportNotice, setExportNotice] = useState('')
 const heading = useRef<HTMLHeadingElement>(null)
 const focusNext = useRef(false)
 useEffect(() => {
  let active = true
  matchingRequest<Data>(token, '/operations/explore', query).then(v => { if (active) { setData(v); setError('') } }).catch(() => { if (active) setError('조회하지 못했어요. 운영 권한과 검색 조건을 확인하고 다시 시도해 주세요.') })
  return () => { active = false }
 }, [token, query, attempt])
 useLayoutEffect(() => { if (focusNext.current) { heading.current?.focus(); focusNext.current = false } }, [query])
 function navigate(next: Query) {
  setHistory(v => [...v, query]); setQuery(next); setData(null); setError(''); focusNext.current = true
 }
 function related(kind: Kind, filter: Partial<Query>) { navigate({ ...initial, kind, ...filter }) }
 return <section className="operations-explorer" aria-labelledby="operations-explorer-title">
  <h3 id="operations-explorer-title" ref={heading} tabIndex={-1}>운영 통합 조회 · {kinds[query.kind]}{query.id ? ' 상세' : ''}</h3>
  <p>신청·결제·매칭·참석을 각각 확인해요. 시각은 한국 시각(KST)이며 정상 흐름은 자동 처리돼요.</p>
  {history.length > 0 && <button type="button" className="secondary" onClick={() => {
   setQuery(history[history.length - 1]); setHistory(v => v.slice(0, -1)); setData(null); setError(''); focusNext.current = true
  }}>이전 목록으로</button>}
  {!query.id && <form key={JSON.stringify(query)} onSubmit={event => {
   event.preventDefault(); const fields = new FormData(event.currentTarget)
   const kind = fields.get('kind') as Kind
   const period = Object.fromEntries(['from','to'].filter(k => kind !== 'members' && fields.get(k)).map(k => [k, new Date(`${fields.get(k)}:00+09:00`).toISOString()]))
   setQuery({ ...initial, ...(kind === query.kind ? { memberId: query.memberId, slotId: query.slotId, tableId: query.tableId } : {}), kind, ...period, q: String(fields.get('q')), status: String(fields.get('status')), page: 0, ...Object.fromEntries(['paymentStatus','matchingStatus','attendanceStatus'].filter(k => fields.get(k)).map(k => [k, String(fields.get(k))])) }); setData(null); setError('')
  }}>
   <div><label htmlFor="explore-kind">조회 대상</label><select id="explore-kind" name="kind" defaultValue={query.kind}>{Object.entries(kinds).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></div>
   <div><label htmlFor="explore-q">아이디·식별자·지역 검색</label><input id="explore-q" name="q" maxLength={80} defaultValue={query.q} /></div>
   <div><label htmlFor="explore-status">상태</label><select id="explore-status" name="status" defaultValue={query.status}><option value="">전체 상태</option>{['ACTIVE','RESTRICTED','WITHDRAWN','SUBMITTED','CANCELED','PUBLISHED','DRAFT','CONFIRMED','INVALIDATED','EXCEPTION'].map(s => <option value={s} key={s}>{states[s]}</option>)}</select></div>
   {query.kind === 'applications' && (['paymentStatus','matchingStatus','attendanceStatus'] as const).map(key => <div key={key}><label htmlFor={`explore-${key}`}>{labels[key]} 상태</label><select id={`explore-${key}`} name={key} defaultValue={query[key] ?? ''}><option value="">전체</option>{(key === 'paymentStatus' ? ['PENDING','PAID','FAILED','REFUND_AVAILABLE','REFUND_REQUESTED','REFUND_PROCESSING','REFUNDED','REFUND_FAILED'] : key === 'matchingStatus' ? ['WAITING','MATCHING','REALLOCATING','CONFIRMED','ALTERNATIVE_OFFERED','TRANSFERRED','NO_MATCH','EXCEPTION'] : ['SCHEDULED','ATTENDED','CANCELED_EARLY','CANCELED_LATE','NO_SHOW']).map(s => <option key={s} value={s}>{states[s] ?? s}</option>)}</select></div>)}
   {query.kind !== 'members' && (['from','to'] as const).map(key => <div key={key}><label htmlFor={`explore-${key}`}>{key === 'from' ? '기간 시작 (포함)' : '기간 종료 (미포함)'} · KST</label><input id={`explore-${key}`} name={key} type="datetime-local" defaultValue={query[key] ? new Date(new Date(query[key]!).getTime() + 9 * 3600000).toISOString().slice(0,16) : ''} /></div>)}
   <button>조건 적용</button>
  </form>}
  {(query.memberId || query.slotId || query.tableId) && <p>선택한 {query.memberId ? '회원' : query.slotId ? '회차' : '테이블'}에 연결된 결과예요. 이전 목록으로 돌아가 다른 대상을 선택할 수 있어요.</p>}
  <button type="button" className="secondary" onClick={() => { setData(null); setError(''); setAttempt(v => v + 1) }}>통합 조회 새로고침</button>
  {!query.id && <button type="button" className="secondary" disabled={exporting || !data} onClick={async () => {
   setExporting(true); setExportNotice('')
   try {
    const filter = { ...query }; delete (filter as Partial<Query>).page
    const result = await matchingRequest<OperationsExport>(token, '/operations/export', filter)
    const url = URL.createObjectURL(new Blob([operationsCsv(result)], { type: 'text/csv;charset=utf-8' }))
    const link = document.createElement('a'); link.href = url; link.download = `dining-${result.kind}-${result.exportedAt.replaceAll(/[:.]/g, '-')}.csv`; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000)
    setExportNotice(`현재 적용한 조건으로 ${result.total}건을 내보냈어요. 조회 기준 시각: ${time(result.exportedAt)}`)
   } catch (cause) { setExportNotice(cause instanceof Error && cause.message === 'EXPORT_LIMIT' ? '최대 5,000건까지 내보낼 수 있어요. 회차·회원·검색 조건을 좁혀 주세요.' : '내보내지 못했어요. 권한과 연결을 확인한 뒤 다시 시도해 주세요.') }
   finally { setExporting(false) }
  }}>{exporting ? 'CSV 준비 중' : '현재 조건 CSV 내보내기'}</button>}
  {exportNotice && <p role="status">{exportNotice}</p>}
  {error && <p role="alert">{error}</p>}
  {!data && !error && <p role="status">목록을 불러오고 있어요.</p>}
  {data && <>
   <p role="status">총 {data.total}건 · {data.page + 1}페이지</p>
   {!data.items.length && <p>조건에 맞는 결과가 없어요. 검색 조건을 바꾸거나 새로고침해 주세요.</p>}
   {data.items.map(item => <article className="previous-forms" key={`${item.kind}-${item.id}-${item.facts.domain ?? ''}`}>
    <h4>{item.label} · {states[item.status] ?? item.status}</h4>
    <p>식별자 {item.id}</p>{item.at && <p>{time(item.at)}</p>}
    {query.id ? <>
     {(item.kind === 'slots' || item.kind === 'tables') && <OperationsInsights key={item.id} token={token} scope={item.kind === 'slots' ? { slotId: item.id } : { tableId: item.id }} onSafetyCase={onSafetyCase} />}
     <dl>{Object.entries(item.facts).filter(([key]) => key !== 'ledger' && key !== 'tableExplanation').map(([key, v]) => <div key={key}><dt>{labels[key] ?? key}</dt><dd>{value(key, v)}</dd></div>)}</dl>
     {item.facts.tableExplanation != null && <MatchingExplanation data={item.facts.tableExplanation as NonNullable<MatchApplication['explanation']>} />}
     {Array.isArray(item.facts.ledger) && <div><h4>결제·환불 원장 (모의 거래)</h4>{!item.facts.ledger.length && <p>거래 이력이 없어요. 멤버십 사용은 새 결제가 아니에요.</p>}{item.facts.ledger.map((raw, i) => { const entry = raw as { kind: string; id: string; amountKrw: number; outcome: string; at: string; paymentId?: string; reason?: string }; return <div className="previous-forms" key={i}><p>{entry.kind === 'REFUND' ? '환불' : '결제'} · {entry.amountKrw.toLocaleString()}원 · {entry.outcome === 'success' ? '성공' : '실패'}</p><p>{time(entry.at)} · 거래 {entry.id}</p>{entry.paymentId && <p>원결제: {entry.paymentId} · {entry.reason === 'matching_failure' ? '매칭 실패' : '자발 취소'}</p>}</div> })}</div>}
     {item.applicationId && item.kind === 'exceptions' && <button className="secondary" onClick={() => related('applications', { id: item.applicationId! })}>연결 신청·거래 원장</button>}
     {item.memberId && <button className="secondary" onClick={() => related('members', { id: item.memberId! })}>연결 회원</button>}
     {item.slotId && item.kind !== 'slots' && <button className="secondary" onClick={() => related('slots', { id: item.slotId! })}>연결 회차</button>}
     {item.tableId && item.kind !== 'tables' && <button className="secondary" onClick={() => related('tables', { id: item.tableId! })}>연결 테이블</button>}
     {item.kind === 'members' && <button className="secondary" onClick={() => related('applications', { memberId: item.id })}>회원 신청 목록</button>}
     {item.kind === 'slots' && <><button className="secondary" onClick={() => related('applications', { slotId: item.id })}>회차 신청 목록</button><button className="secondary" onClick={() => related('tables', { slotId: item.id })}>회차 테이블 목록</button><button className="secondary" onClick={() => related('exceptions', { slotId: item.id })}>회차 예외 목록</button></>}
     {item.kind === 'tables' && <><button className="secondary" onClick={() => related('applications', { tableId: item.id })}>테이블 신청 목록</button><button className="secondary" onClick={() => related('exceptions', { tableId: item.id })}>테이블 예외 목록</button></>}
     {item.kind === 'applications' && Array.isArray(item.facts.selectedSlotIds) && item.facts.selectedSlotIds.map(id => <button key={String(id)} className="secondary" onClick={() => related('slots', { id: String(id) })}>선택 회차 {String(id).slice(0, 8)}</button>)}
     {item.kind === 'exceptions' && <><p>식별자를 대조해 조치해 주세요. 재시도 가능 여부는 서버가 다시 확인해요.</p><button className="secondary" onClick={() => { const id = ({ finance: 'operations-explorer-title', matching: 'matching-monitor-title', venues: 'venue-operations-title', chat: 'chat-monitor-title', content: 'content-monitor-title', feedback: 'feedback-monitor-title', push: 'push-monitor-title', privacy: 'privacy-monitor-title' } as Record<string, string>)[String(item.facts.domain)]; if (id) window.dispatchEvent(new CustomEvent('operations-monitor', { detail: id })) }}>담당 업무 모니터로 이동</button></>}
    </> : <>
     {item.kind === 'applications' && <p>신청 {value('applicationStatus', item.facts.applicationStatus)} · 결제 {value('paymentStatus', item.facts.paymentStatus)} · 매칭 {value('matchingStatus', item.facts.matchingStatus)} · 참석 {value('attendanceStatus', item.facts.attendanceStatus)}</p>}
     <button className="secondary" onClick={() => navigate({ ...query, id: item.id, page: 0, ...(typeof item.facts.domain === 'string' ? { domain: item.facts.domain } : {}) })}>{kinds[item.kind]} 상세 보기</button>
    </>}
   </article>)}
   {!query.id && <div className="intake-steps"><button className="secondary" disabled={!data.page} onClick={() => { setQuery({ ...query, page: query.page - 1 }); setData(null) }}>이전 페이지</button><button className="secondary" disabled={(data.page + 1) * data.pageSize >= data.total} onClick={() => { setQuery({ ...query, page: query.page + 1 }); setData(null) }}>다음 페이지</button></div>}
  </>}
 </section>
}
