import { useEffect, useRef, useState } from 'react'
import { matchingRequest } from './matching-api'
type Data = { state: string; reports: { id: string; category: string; status: string; createdAt: string }[]; contexts: { assignmentId: string; startsAt: string; regionLabel: string; peers: { peerId: string; label: string; separated: boolean }[] }[] }
const states: Record<string,string> = { ACTIVE:'참가 가능',WARNING:'경고 기록 있음 · 참가 가능',RESTRICTED:'참가 제한',BANNED:'영구 참가 제한' }
const statuses: Record<string,string> = { PENDING:'검토 대기',REVIEWED:'검토 완료',DISMISSED:'검토 종결' }
const date = (s: string) => new Date(s).toLocaleString('ko-KR',{timeZone:'Asia/Seoul'})
export default function SafetyPanel({ token }: { token: string }) {
 const [data,setData] = useState<Data | null>(null),[error,setError] = useState(''),[notice,setNotice] = useState(''),[attempt,setAttempt] = useState(0),[busy,setBusy] = useState(false),[kind,setKind] = useState('REPORT'),[version,setVersion] = useState(0)
 const [selected,setSelected] = useState('')
 const pending = useRef<{ body: string; key: string } | null>(null)
 useEffect(()=>{let active=true;matchingRequest<Data>(token,'/safety').then(d=>{if(active){setData(d);setError('')}}).catch(()=>{if(active)setError('안전 정보를 불러오지 못했어요. 다시 확인해 주세요.')});return()=>{active=false}},[token,attempt])
 const peers=data?.contexts.flatMap(c=>c.peers.map(p=>({ ...p,assignmentId:c.assignmentId,description:`${date(c.startsAt)} · ${c.regionLabel} · ${p.label}` }))) ?? []
 return <section aria-labelledby="safety-title"><h3 id="safety-title">신고·차단과 나의 안전 상태</h3>
  <p>단체방의 참가자 번호로 상대를 확인해 주세요. 신고 내용과 운영 검토 사유는 상대에게 공개되지 않아요.</p>
  <button type="button" className="secondary" disabled={busy} onClick={()=>setAttempt(v=>v+1)}>안전 상태 새로고침</button>
  {error&&<p id="safety-error" role="alert">{error}</p>}{notice&&<p role="status">{notice}</p>}{!data&&!error&&<p>안전 정보를 확인하고 있어요.</p>}
  {data&&<><p>내 상태: {states[data.state]}</p>{['RESTRICTED','BANNED'].includes(data.state)&&<p>새 신청·결제·일정 이동·매칭·채팅 참가가 제한돼요. 기존 신청의 보관·환불 가능 여부는 매칭 상태에서 확인해 주세요. 안전 신고는 계속 접수할 수 있어요.</p>}
   {peers.length?<form key={version} aria-label="안전 신고·차단 접수" onSubmit={async event=>{
    event.preventDefault();const fields=new FormData(event.currentTarget),peer=peers.find(p=>p.peerId===fields.get('peer'));if(!peer)return
    const payload={assignmentId:peer.assignmentId,peerId:peer.peerId,kind,...(kind==='REPORT'?{category:String(fields.get('category')),details:String(fields.get('details'))}:{})},body=JSON.stringify(payload)
    if(pending.current?.body!==body)pending.current={body,key:crypto.randomUUID()}
    setBusy(true);setError('');setNotice('')
    try{setData(await matchingRequest<Data>(token,'/safety/submit',{...payload,requestKey:pending.current.key}));pending.current=null;setSelected('');setVersion(v=>v+1);setNotice(kind==='REPORT'?'신고를 접수하고 두 분을 매칭에서 분리했어요. 운영자가 내용을 검토해요.':'차단을 접수하고 두 분을 매칭에서 분리했어요.')}
    catch(cause){const code=cause instanceof Error?cause.message:'';setError(code==='VALIDATION_ERROR'?'신고 분류와 내용을 확인해 주세요. 신고 내용은 앞뒤 공백을 제외하고 10~2000자여야 해요.':code==='SAFETY_RATE_LIMIT'?'최근 24시간 신고 접수 한도에 도달했어요. 이후 다시 시도해 주세요.':code==='FORBIDDEN'||code==='IDEMPOTENCY_CONFLICT'?'선택한 식탁과 접수 상태를 새로고침해 주세요.':'접수 결과를 확인하지 못했어요. 같은 내용으로 다시 시도해 주세요.')}
    finally{setBusy(false)}
   }}><fieldset disabled={busy}><legend>신고 또는 차단 접수</legend>
    <label htmlFor="safety-peer">함께 배정된 식탁·상대</label><select id="safety-peer" name="peer" value={selected} onChange={e=>setSelected(e.target.value)} required><option value="">선택해 주세요</option>{peers.map(p=><option key={p.peerId} value={p.peerId}>{p.description}{p.separated?' · 내 접수로 매칭 분리됨':''}</option>)}</select>
    {selected&&<p>선택한 식탁·상대: {peers.find(p=>p.peerId===selected)?.description}</p>}
    <label htmlFor="safety-kind">접수 종류</label><select id="safety-kind" value={kind} onChange={e=>setKind(e.target.value)}><option value="REPORT">불쾌한 행동 신고</option><option value="BLOCK">상대 차단</option></select>
    {kind==='REPORT'&&<><label htmlFor="safety-category">신고 분류</label><select id="safety-category" name="category"><option value="HARASSMENT">불쾌하거나 위협적인 행동</option><option value="UNWANTED_CONTACT">원하지 않는 연락</option><option value="OTHER">기타</option></select><label htmlFor="safety-details">신고 내용 (10~2000자)</label><textarea id="safety-details" name="details" aria-describedby={error?'safety-error':undefined} onChange={()=>setError('')} minLength={10} maxLength={2000} required /><p>확인이 필요한 행동과 시점을 적어 주세요. 불필요한 연락처나 다른 사람의 개인정보는 적지 않아도 돼요.</p></>}
    <p>접수 즉시 두 사람을 향후 매칭에서 제외하고 같은 단체방 접근을 닫아요. 미래의 확정 식탁은 재배치될 수 있어요. 이번 화면에서 차단을 해제할 수 없어요.</p>
    <label className="check-label"><input type="checkbox" required />선택한 상대와 접수 결과를 확인했어요.</label><button>{busy?'접수 중…':'안전 접수 제출'}</button>
   </fieldset></form>:<p>선택할 식탁 상대가 없어요. 배정된 식탁의 단체방 번호가 준비되면 접수할 수 있어요.</p>}
   <h4>내 신고 접수 내역</h4>{data.reports.length?data.reports.map(r=><p key={r.id}>{date(r.createdAt)} · {statuses[r.status]}</p>):<p>접수한 신고가 없어요.</p>}
  </>}
 </section>
}
