import { useEffect, useState } from 'react'
import { matchingRequest } from './matching-api'
export type SafetyCaseLink = { caseType: string; caseId: string }
type Data = { attendance: { assigned: number; attended: number; noShowCandidates: number; confirmedNoShows: number; lateCancellations: number }; feedback: { eligible: number; responses: number; atmosphere: number | null; conversation: number | null; venue: number | null; revisitYes: number; recommendYes: number }; canReviewSafety: boolean; cases: (SafetyCaseLink & { kind: string; status: string; at: string | null; tableId: string; applicationId: string | null })[]; page: number; totalCases: number; pageSize: number }
const labels: Record<string,string> = { REPORT:'신고',ATTENDANCE:'참석 검토',CANCELLATION:'마감 후 취소',CANDIDATE:'노쇼 후보 · 미확정',NO_SHOW:'확인 노쇼',CORRECTED:'정정됨',REVIEW:'검토 대상',PENDING:'검토 대기',REVIEWED:'검토 완료',DISMISSED:'종결' }
export default function OperationsInsights({token,scope,onSafetyCase}:{token:string;scope:{slotId?:string;tableId?:string};onSafetyCase:(v:SafetyCaseLink)=>void}) {
 const [data,setData]=useState<Data|null>(null),[error,setError]=useState(''),[page,setPage]=useState(0),[attempt,setAttempt]=useState(0)
 const {slotId,tableId}=scope
 useEffect(()=>{let active=true;matchingRequest<Data>(token,'/operations/insights',{...(slotId?{slotId}:{}),...(tableId?{tableId}:{}),page}).then(d=>{if(active){setData(d);setError('')}}).catch(()=>{if(active)setError('집계를 불러오지 못했어요. 연결과 운영 권한을 확인해 주세요.')});return()=>{active=false}},[token,slotId,tableId,page,attempt])
 const mean=(n:number|null)=>n===null?'응답 없음':`${Number(n).toFixed(2)} / 5`
 return <section aria-labelledby="operations-insights-title"><h4 id="operations-insights-title">참석·피드백·연결 사건</h4>
  <button className="secondary" onClick={()=>{setData(null);setError('');setAttempt(v=>v+1)}}>집계 새로고침</button>
  {error&&<p role="alert">{error}</p>}{!data&&!error&&<p role="status">집계를 불러오고 있어요.</p>}
  {data&&<><p>현재 배정 {data.attendance.assigned}명 · 참석 {data.attendance.attended}명 · 노쇼 후보 {data.attendance.noShowCandidates}명 · 확인 노쇼 {data.attendance.confirmedNoShows}명 · 마감 후 취소 {data.attendance.lateCancellations}건</p>
   <p>종료 후 현재 참석 자격을 만족하는 배정 기준이에요. 후보는 확정 노쇼와 구분하며 정정한 평가는 집계에서 다시 검사해요.</p>
   <p>피드백 {data.feedback.responses} / 대상 {data.feedback.eligible}건 · 응답률 {data.feedback.eligible?`${(data.feedback.responses/data.feedback.eligible*100).toFixed(1)}%`:'N/A'}</p>
   <p>분위기 {mean(data.feedback.atmosphere)} · 대화 {mean(data.feedback.conversation)} · 식당 {mean(data.feedback.venue)}</p>
   <p>재방문 긍정 {data.feedback.revisitYes}건 · 추천 긍정 {data.feedback.recommendYes}건 (유효 응답 기준)</p>
   <p>연결 사건 {data.totalCases}건 · {data.page+1}페이지</p>{!data.cases.length&&<p>연결된 신고·참석 검토·마감 후 취소가 없어요.</p>}
   {data.cases.map(c=><div className="previous-forms" key={`${c.caseType}-${c.caseId}`}><p>{labels[c.caseType]} · {labels[c.status]??c.status} · {c.caseId}</p>
    {c.at&&<p>{new Date(c.at).toLocaleString('ko-KR',{timeZone:'Asia/Seoul'})}</p>}
    {c.status==='CANDIDATE'?<button className="secondary" onClick={()=>{window.dispatchEvent(new CustomEvent('operations-monitor',{detail:'attendance-monitor-title'}))}}>참석 후보 검토로 이동</button>:data.canReviewSafety?<button className="secondary" onClick={()=>onSafetyCase({caseType:c.caseType,caseId:c.caseId})}>권한 있는 사건 상세로 연결</button>:<p>사건 원문과 조치는 별도 안전 검토 권한이 필요해요.</p>}
   </div>)}
   <div className="intake-steps"><button className="secondary" disabled={!page} onClick={()=>{setPage(v=>v-1);setData(null)}}>이전 사건 페이지</button><button className="secondary" disabled={(page+1)*data.pageSize>=data.totalCases} onClick={()=>{setPage(v=>v+1);setData(null)}}>다음 사건 페이지</button></div>
  </>}
 </section>
}
