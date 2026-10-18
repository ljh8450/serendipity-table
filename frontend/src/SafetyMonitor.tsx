import { useEffect, useRef, useState } from 'react'
import type { SafetyCaseLink } from './OperationsInsights'
import { matchingRequest } from './matching-api'
type Case = { caseType: string; caseId: string; kind: string; status: string; at: string }
type Summary = { canReview: boolean; cases: Case[] }
type Detail = { caseType: string; caseId: string; state: string; revision: number; details: string | null; status: string; actions: { action: string; reason: string; state: string; at: string }[] }
const labels: Record<string,string> = { HARASSMENT:'불쾌·위협 행동',UNWANTED_CONTACT:'원하지 않는 연락',OTHER:'기타 신고',NO_SHOW:'확인된 노쇼',CANCELED_LATE:'당일·마감 후 취소',PENDING:'검토 대기',REVIEWED:'검토 완료',DISMISSED:'종결',CORRECTED:'참석·취소 정정됨',REVIEW:'검토 대상',ACTIVE:'참가 가능',WARNING:'경고',RESTRICTED:'참가 제한',BANNED:'영구 참가 제한',WARN:'경고 기록',RESTRICT:'참가 제한 적용',BAN:'영구 제한 적용',RESTORE:'참가 제한 해제',DISMISS:'신고 기각·종결' }
const date=(s:string)=>new Date(s).toLocaleString('ko-KR',{timeZone:'Asia/Seoul'})
export default function SafetyMonitor({token,selectedCase}:{token:string;selectedCase?:SafetyCaseLink|null}){
 const [data,setData]=useState<Summary|null>(null),[detail,setDetail]=useState<Detail|null>(null),[error,setError]=useState(''),[notice,setNotice]=useState(''),[busy,setBusy]=useState(false),[attempt,setAttempt]=useState(0)
 const pending=useRef<{body:string;key:string}|null>(null)
 useEffect(()=>{let active=true;matchingRequest<Summary>(token,'/operations/safety').then(d=>{if(active){setData(d);setError('')}}).catch(()=>{if(active){setDetail(null);setError('안전 검토 목록을 불러오지 못했어요. 권한과 연결을 확인해 주세요.')}});return()=>{active=false}},[token,attempt])
 useEffect(()=>{
  if(!selectedCase)return
  let active=true
  matchingRequest<Detail>(token,'/operations/safety/detail',selectedCase).then(d=>{if(active){setDetail(d);setError('');pending.current=null;const title=document.getElementById('safety-monitor-title');if(title){title.tabIndex=-1;title.focus();title.scrollIntoView({block:'start'})}}}).catch(()=>{if(active){setDetail(null);setError('사건을 불러오지 못했어요. 안전 검토 권한과 현재 사건 상태를 확인해 주세요.')}})
  return()=>{active=false}
 },[token,selectedCase])
 return <section aria-labelledby="safety-monitor-title"><h3 id="safety-monitor-title">안전 신고·참가 제한 검토</h3>
  <button type="button" className="secondary" disabled={busy} onClick={()=>{setDetail(null);setAttempt(v=>v+1)}}>안전 검토 새로고침</button>
  {error&&<p id="safety-review-error" role="alert">{error}</p>}{notice&&<p role="status">{notice}</p>}{!data&&!error&&<p>검토 목록을 확인하고 있어요.</p>}
  {data&&!data.canReview&&<p>사건 요약만 볼 수 있어요. 원문 조회와 조치는 별도의 안전 검토 권한이 필요해요.</p>}
  {data&&!data.cases.length&&<p>검토할 안전 사건이 없어요.</p>}
  {data?.cases.map(c=><div className="previous-forms" key={`${c.caseType}-${c.caseId}`}><p>{date(c.at)} · {labels[c.kind]} · {labels[c.status]??c.status}</p>{data.canReview&&<button type="button" className="secondary" disabled={busy} onClick={async()=>{setBusy(true);setError('');setNotice('');setDetail(null);pending.current=null;try{setDetail(await matchingRequest<Detail>(token,'/operations/safety/detail',{caseType:c.caseType,caseId:c.caseId}))}catch{setError('사건을 불러오지 못했어요. 안전 검토 권한과 현재 참석 상태를 확인해 주세요.')}finally{setBusy(false)}}}>사건 상세 확인 {c.caseId.slice(0,8)}</button>}</div>)}
  {detail&&<div className="previous-forms"><h4>선택 사건 {detail.caseId.slice(0,8)}</h4><p>참가 상태: {labels[detail.state]} · {labels[detail.status]??detail.status}</p>{detail.details&&<><p><strong>신고 원문 · 안전 검토 권한 전용</strong></p><p className="policy-body">{detail.details}</p></>}
   <p>후보만으로 제재하지 않아요. 내용을 검토하고 사유를 기록해 주세요. 경고는 기존 제한을 해제하지 않으며, 해제해도 신고·차단 쌍의 분리는 유지돼요.</p>
   <form key={`${detail.caseType}-${detail.caseId}-${detail.revision}`} aria-label="안전 사건 조치" onSubmit={async event=>{
    event.preventDefault();const fields=new FormData(event.currentTarget),payload={caseType:detail.caseType,caseId:detail.caseId,revision:detail.revision,action:String(fields.get('action')),reason:String(fields.get('reason'))},body=JSON.stringify(payload)
    if(pending.current?.body!==body)pending.current={body,key:crypto.randomUUID()}
    setBusy(true);setError('');setNotice('')
    try{setDetail(await matchingRequest<Detail>(token,'/operations/safety/review',{...payload,requestKey:pending.current.key}));pending.current=null;setNotice('검토와 조치 이력을 저장했어요.');setAttempt(v=>v+1)}
    catch(cause){const code=cause instanceof Error?cause.message:'';if(code==='FORBIDDEN')setDetail(null);setError(code==='VALIDATION_ERROR'?'조치 선택과 사유를 확인해 주세요. 사유는 앞뒤 공백을 제외하고 5~500자여야 해요.':code==='SAFETY_CONFLICT'?'다른 조치로 상태가 바뀌었어요. 사건 상세를 다시 불러와 주세요.':code==='FORBIDDEN'?'안전 검토 권한이나 대상 권한을 확인해 주세요.':'조치 결과를 확인하지 못했어요. 같은 내용으로 다시 시도해 주세요.')}
    finally{setBusy(false)}
   }}><fieldset disabled={busy}><legend>검토 결과와 계정 조치</legend><label htmlFor="safety-action">조치 선택</label><select id="safety-action" name="action"><option value="REVIEWED">검토 완료 · 상태 유지</option>{detail.caseType==='REPORT'&&<option value="DISMISS">신고 기각·종결 · 쌍 분리 유지</option>}{detail.status!=='CORRECTED'&&<><option value="WARN">경고 기록</option><option value="RESTRICT" disabled={detail.state==='BANNED'}>참가 제한 적용</option><option value="BAN">영구 참가 제한 적용</option></>}<option value="RESTORE">참가 제한 해제</option></select>
    <label htmlFor="safety-reason">조치 사유 (5~500자, 내부 기록)</label><textarea id="safety-reason" name="reason" aria-describedby={error?'safety-review-error':undefined} onChange={()=>setError('')} minLength={5} maxLength={500} required /><p>제한은 미래 신청·매칭·채팅 참가에 적용해요. 자동 벌금이나 환불·이용권 몰수는 적용하지 않아요.</p><label className="check-label"><input type="checkbox" required />대상 사건·참가 상태·조치 결과를 확인했어요.</label><button>안전 조치 저장</button></fieldset></form>
   <p><strong>대상 최근 조치 이력 (최대50건)</strong></p>{detail.actions.length?detail.actions.map((a,i)=><p key={i}>{date(a.at)} · {labels[a.action]??a.action} · {labels[a.state]} · {a.reason}</p>):<p>기록된 조치가 없어요.</p>}
  </div>}
 </section>
}
