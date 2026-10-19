import { useEffect, useState } from 'react'
import { matchingRequest } from './matching-api'
type Template = { kind: string; version: string; body: string; createdAt: string }
type Data = { templates: Template[] }
const labels: Record<string, string> = { GUIDE: '확정 안내', D1: '전날 리마인드', START: '시작 안내', CURATION: '큐레이션', ALTERNATIVE: '대안 일정 안내' }
export default function MessageTemplates({ token }: { token: string }) {
 const [data, setData] = useState<Data | null>(null)
 const [error, setError] = useState('')
 const [notice, setNotice] = useState('')
 const [busy, setBusy] = useState(false)
 const [attempt, setAttempt] = useState(0)
 useEffect(() => {
  let active = true
  matchingRequest<Data>(token, '/operations/templates').then(v => { if (active) { setData(v); setError('') } }).catch(() => { if (active) setError('안내 템플릿을 불러오지 못했어요. 다시 시도해 주세요.') })
  return () => { active = false }
 }, [token, attempt])
 return <section aria-labelledby="templates-title"><h3 id="templates-title">자동 안내 템플릿 관리</h3>
  <p>발행한 문구는 이후 생성되는 안내에 적용돼요. 이미 발송된 내용은 유지돼요. 일정·장소·환불 기준과 대화 주제는 서버가 현재 상태를 확인해 함께 안내해요.</p>
  <button type="button" className="secondary" disabled={busy} onClick={() => setAttempt(v => v + 1)}>템플릿 새로고침</button>
  {error && <p role="alert">{error}</p>}{notice && <p role="status">{notice}</p>}
  {!data && !error && <p>안내 문구를 확인하고 있어요.</p>}
  {data?.templates.map(t => <form key={t.kind + t.version} onSubmit={async e => {
   e.preventDefault(); const body = String(new FormData(e.currentTarget).get('body')); setBusy(true); setError(''); setNotice('')
   try { setData(await matchingRequest<Data>(token, '/operations/templates', { kind: t.kind, expectedVersion: t.version, body })); setNotice(`${labels[t.kind]} 문구를 발행했어요.`) }
   catch { setError('문구를 발행하지 못했어요. 다른 운영자의 변경이 있는지 새로고침 후 확인해 주세요.') }
   finally { setBusy(false) }
  }}><label htmlFor={`template-${t.kind}`}>{labels[t.kind]} 문구 (최대 500자)</label><textarea id={`template-${t.kind}`} name="body" required maxLength={500} defaultValue={t.body} disabled={busy} />
   <p className="help">발행: {new Date(t.createdAt).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })} · 버전 {t.version}</p><button disabled={busy}>{busy ? '발행 중…' : `${labels[t.kind]} 발행`}</button>
  </form>)}
 </section>
}
