import { useEffect,useState } from 'react'
import { matchingRequest } from './matching-api'
type Data={jobs:{id:string;kind:string;status:string;attempts:number;dueAt:string}[];retentionHeld:number}
const states:Record<string,string>={PENDING:'정리 대기',RUNNING:'처리 중',DONE:'정리 완료',EXCEPTION:'운영 확인 필요'}
export default function PrivacyMonitor({token}:{token:string}){
 const [data,setData]=useState<Data|null>(null),[error,setError]=useState(''),[attempt,setAttempt]=useState(0),[busy,setBusy]=useState(false)
 useEffect(()=>{let active=true;matchingRequest<Data>(token,'/operations/privacy').then(d=>{if(active){setData(d);setError('')}}).catch(()=>{if(active)setError('개인정보 정리 상태를 불러오지 못했어요. 권한과 연결을 확인해 주세요.')});return()=>{active=false}},[token,attempt])
 return <section aria-labelledby="privacy-monitor-title"><h3 id="privacy-monitor-title">탈퇴·보존 만료 정리</h3><p>정상 정리는 서버에서 진행해요. 재시도해도 보존 기간·금융 권리·분쟁 보존 조건을 우회할 수 없어요.</p><button className="secondary" disabled={busy} onClick={()=>{setData(null);setError('');setAttempt(v=>v+1)}}>개인정보 정리 새로고침</button>
  {error&&<p role="alert">{error}</p>}{!data&&!error&&<p>정리 상태를 확인하고 있어요.</p>}
  {data&&<><p>기간 만료 후 금융·분쟁 보존 확인이 필요한 계정 {data.retentionHeld}건</p>{!data.jobs.length&&<p>진행할 탈퇴 정리 작업이 없어요.</p>}{data.jobs.map(j=><div className="previous-forms" key={j.id}><p>{j.kind==='SOFT_DELETE'?'인증 정보 소프트 정리':'보존 만료 최종 삭제'} · {states[j.status]} · {j.attempts}회</p><p>식별자 {j.id} · {new Date(j.dueAt).toLocaleString('ko-KR',{timeZone:'Asia/Seoul'})}</p>{j.status==='EXCEPTION'&&<button className="secondary" disabled={busy} onClick={async()=>{setBusy(true);setError('');try{setData(await matchingRequest<Data>(token,'/operations/privacy/retry',{jobId:j.id}))}catch{setError('재시도하지 못했어요. 현재 작업 상태와 보존 조건을 다시 확인해 주세요.')}finally{setBusy(false)}}}>개인정보 정리 재시도</button>}</div>)}</>}
 </section>
}
