import { useEffect, useRef, useState } from 'react'
import { matchingRequest } from './matching-api'
type Query = { from: string; to: string; slotId?: string }
type Session = { id: string; slotId: string; startedAt: string; endedAt?: string | null }
type Metric = { id: string; label: string; numerator: number | null; denominator: number; value: number | null; unit: string; note: string; coverage: string }
type Data = { metrics: Metric[]; asOf: string; instrumentationSince: string; openSessions: number; completedSessions: number; myActiveSession: Session | null }
const date = (v: string) => new Date(v).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })
const localDate = (v: string) => new Date(new Date(v).getTime()+9*3600000).toISOString().slice(0,16)
const defaultQuery = ():Query => ({ from: new Date(Date.now()-30*86400000).toISOString(), to: new Date(Date.now()+86400000).toISOString() })
export default function OperationsMetrics({token,slots}:{token:string;slots:{id:string;startsAt:string;regionLabel:string}[]}) {
 const [query,setQuery]=useState<Query>(defaultQuery),[data,setData]=useState<Data|null>(null),[error,setError]=useState(''),[attempt,setAttempt]=useState(0),[busy,setBusy]=useState(false)
 const pending=useRef<{body:string;key:string}|null>(null)
 useEffect(()=>{let active=true;matchingRequest<Data>(token,'/operations/metrics',query).then(d=>{if(active){setData(d);setError('')}}).catch(()=>{if(active)setError('지표를 불러오지 못했어요. 기간과 운영 권한을 확인하고 다시 시도해 주세요.')});return()=>{active=false}},[token,query,attempt])
 async function work(payload:{action:string;slotId?:string;sessionId?:string}) {
  const body=JSON.stringify(payload)
  if(pending.current?.body!==body)pending.current={body,key:crypto.randomUUID()}
  setBusy(true);setError('')
  try {await matchingRequest(token,'/operations/work',{...payload,requestKey:pending.current.key});pending.current=null;setData(null);setAttempt(v=>v+1)}
  catch {setError('시간 기록을 처리하지 못했어요. 이미 시작한 세션과 권한을 확인하고 같은 행동으로 다시 시도해 주세요.')}
  finally {setBusy(false)}
 }
 return <section className="operations-metrics" aria-labelledby="operations-metrics-title"><h3 id="operations-metrics-title">운영 대시보드 · 13개 지표</h3>
  <p>신청은 제출 시각, 신청 시작은 단계 진입 시각, 테이블은 생성 시각을 기준으로 집계해요. 과거 미계측 자료와 아직 처리 중인 결과를 구분해 주세요.</p>
  <form onSubmit={e=>{e.preventDefault();const f=new FormData(e.currentTarget),from=new Date(`${f.get('from')}:00+09:00`).toISOString(),to=new Date(`${f.get('to')}:00+09:00`).toISOString();if(from>=to){setError('기간 종료는 시작보다 나중이어야 해요.');return}setQuery({from,to,...(f.get('slotId')?{slotId:String(f.get('slotId'))}:{})});setData(null);setError('')}}>
   <label htmlFor="metrics-from">집계 시작 · KST (포함)</label><input id="metrics-from" name="from" type="datetime-local" required defaultValue={localDate(query.from)} />
   <label htmlFor="metrics-to">집계 종료 · KST (미포함)</label><input id="metrics-to" name="to" type="datetime-local" required defaultValue={localDate(query.to)} />
   <label htmlFor="metrics-slot">회차 범위</label><select id="metrics-slot" name="slotId"><option value="">전체 회차</option>{slots.map(s=><option value={s.id} key={s.id}>{date(s.startsAt)} · {s.regionLabel}</option>)}</select><button>지표 조건 적용</button>
  </form>
  <button className="secondary" onClick={()=>{setData(null);setError('');setAttempt(v=>v+1)}}>지표 새로고침</button>
  {error&&<p role="alert">{error}</p>}{!data&&!error&&<p role="status">지표를 계산하고 있어요.</p>}
  {data&&<><p>조회 기준 {date(data.asOf)} · 신규 계측 시작 {date(data.instrumentationSince)}</p>
   {data.metrics.map(m=><article className="previous-forms" key={m.id}><h4>{m.label}</h4><p>{m.value===null?'N/A':m.unit==='ratio'?`${(m.value*100).toFixed(1)}%`:`${(m.value/60).toFixed(1)}분 / 측정 회차`}{m.coverage==='PARTIAL'?' · 부분 측정':m.coverage==='UNMEASURED'?' · 미계측':''}</p><p>분자 {m.numerator??'미계측'} / 분모 {m.denominator} · {m.note}</p></article>)}
   <h4>회차 예외 처리 시간 기록</h4><p>직접 예외를 처리하기 시작할 때 기록을 켜고 마친 뒤 종료해 주세요. 서버가 시각을 기록하며 미종료 시간은 완료 시간에 합산하지 않아요.</p>
   <p>완료 세션 {data.completedSessions}건 · 미종료 세션 {data.openSessions}건</p>
   {data.myActiveSession?<><p>내 진행 세션 · {date(data.myActiveSession.startedAt)}</p><button disabled={busy} onClick={()=>work({action:'stop',sessionId:data.myActiveSession!.id})}>예외 처리 시간 기록 종료</button></>:<form onSubmit={e=>{e.preventDefault();void work({action:'start',slotId:String(new FormData(e.currentTarget).get('slotId'))})}}><label htmlFor="work-slot">시간을 기록할 회차</label><select id="work-slot" name="slotId" required defaultValue=""><option value="">선택해 주세요</option>{slots.map(s=><option value={s.id} key={s.id}>{date(s.startsAt)} · {s.regionLabel}</option>)}</select><button disabled={busy}>예외 처리 시간 기록 시작</button></form>}
  </>}
 </section>
}
