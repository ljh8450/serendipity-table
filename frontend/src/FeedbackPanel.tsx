import { useEffect, useRef, useState } from 'react'
import { matchingRequest } from './matching-api'
type Ratings = { atmosphere: number; conversation: number; venue: number; revisit: boolean; recommend: boolean }
type Event = { assignmentId: string; startsAt: string; deadlineAt: string; canSubmit: boolean; submittedAt: string | null; ratings: Ratings | null }
type Data = { events: Event[] }
const date = (s: string) => new Date(s).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })
const scores = [['atmosphere','식탁 분위기'],['conversation','대화 만족도'],['venue','식당 만족도']] as const
export default function FeedbackPanel({ token }: { token: string }) {
 const [data, setData] = useState<Data | null>(null)
 const [error, setError] = useState('')
 const [busy, setBusy] = useState(false)
 const [attempt, setAttempt] = useState(0)
 const pending = useRef<{ body: string; key: string } | null>(null)
 useEffect(() => {
  let active = true
  matchingRequest<Data>(token, '/feedback').then(v => { if (active) { setData(v); setError('') } }).catch(() => { if (active) setError('식탁 평가를 불러오지 못했어요. 다시 확인해 주세요.') })
  return () => { active = false }
 }, [token, attempt])
 return <section aria-labelledby="feedback-title"><h3 id="feedback-title">식탁 평가</h3>
  <p>참석한 식탁의 경험을 알려 주세요. 평가는 다른 참가자에게 공개되지 않아요. 제출 후에는 수정할 수 없어요.</p>
  <button type="button" className="secondary" disabled={busy} onClick={() => setAttempt(v => v + 1)}>식탁 평가 새로고침</button>
  {error && <p role="alert">{error}</p>}
  {!data && !error && <p>식탁 평가를 확인하고 있어요.</p>}
  {data && !data.events.length && <p>평가할 식탁이 없어요. 행사 종료 후 참석이 확인되면 여기에 표시돼요.</p>}
  {data?.events.map(e => <div className="previous-forms" key={e.assignmentId}>
   <h4>{date(e.startsAt)} 식탁 평가</h4><p>제출 기한: {date(e.deadlineAt)} 직전</p>
   {e.ratings ? <><p role="status">식탁 평가를 제출했어요.</p><ul>{scores.map(([key,label]) => <li key={key}>{label}: {e.ratings![key]}점</li>)}<li>재참여 의향: {e.ratings.revisit ? '있어요' : '없어요'}</li><li>추천 의향: {e.ratings.recommend ? '있어요' : '없어요'}</li></ul></>
    : e.canSubmit ? <form onSubmit={async event => {
     event.preventDefault(); const fields = new FormData(event.currentTarget)
     const ratings: Ratings = { atmosphere: Number(fields.get('atmosphere')), conversation: Number(fields.get('conversation')), venue: Number(fields.get('venue')), revisit: fields.get('revisit') === 'yes', recommend: fields.get('recommend') === 'yes' }
     const payload = { assignmentId: e.assignmentId, ratings }; const body = JSON.stringify(payload)
     if (pending.current?.body !== body) pending.current = { body, key: crypto.randomUUID() }
     setBusy(true); setError('')
     try { setData(await matchingRequest<Data>(token, '/feedback/submit', { ...payload, requestKey: pending.current.key })); pending.current = null }
     catch (cause) { setError(cause instanceof Error && ['FEEDBACK_CONFLICT','FEEDBACK_CLOSED','FORBIDDEN'].includes(cause.message) ? '제출 기한·참석 상태가 바뀌었거나 이미 제출했어요. 식탁 평가를 새로고침해 주세요.' : '제출을 확인하지 못했어요. 입력을 유지한 채 같은 버튼으로 다시 시도해 주세요.') }
     finally { setBusy(false) }
    }}>
     {scores.map(([key,label]) => <div key={key}><label htmlFor={`${key}-${e.assignmentId}`}>{label} (1~5점)</label><select id={`${key}-${e.assignmentId}`} name={key} required defaultValue=""><option value="" disabled>점수를 선택해 주세요</option>{[1,2,3,4,5].map(n => <option value={n} key={n}>{n}점 · {['매우 아쉬워요','아쉬워요','보통이에요','좋아요','매우 좋아요'][n-1]}</option>)}</select></div>)}
     {([['revisit','다시 참여하고 싶으신가요?'],['recommend','지인에게 추천하고 싶으신가요?']] as const).map(([key,label]) => <fieldset key={key}><legend>{label}</legend>{[['yes','네'],['no','아니요']].map(([value,text]) => <label className="check-label" key={value}><input type="radio" name={key} value={value} required />{text}</label>)}</fieldset>)}
     <button disabled={busy}>{busy ? '평가 제출 확인 중…' : '식탁 평가 제출'}</button>
    </form> : <p>평가 제출 기한이 지났어요.</p>}
  </div>)}
 </section>
}
