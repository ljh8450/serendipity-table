import { useEffect, useRef, useState } from 'react'
import { matchingRequest } from './matching-api'
export type WithdrawalReceipt={withdrawn:boolean;receiptId:string|null;withdrawnAt:string|null;canWithdraw:boolean;policyVersion:string;unresolvedFinancialApplications:number;authCleanupPending:boolean}
type Data=WithdrawalReceipt
export default function PrivacyPanel({token,onWithdraw}:{token:string;onWithdraw:(receipt:WithdrawalReceipt)=>Promise<void>}){
 const [data,setData]=useState<Data|null>(null),[error,setError]=useState(''),[busy,setBusy]=useState(false),[attempt,setAttempt]=useState(0)
 const key=useRef(crypto.randomUUID())
 useEffect(()=>{let active=true;matchingRequest<Data>(token,'/privacy').then(d=>{if(active){setData(d);setError('')}}).catch(()=>{if(active)setError('계정 관리 정보를 불러오지 못했어요. 연결을 확인하고 다시 시도해 주세요.')});return()=>{active=false}},[token,attempt])
 return <section aria-labelledby="privacy-title"><h3 id="privacy-title">회원 탈퇴·개인정보 보관</h3>
  <details><summary>탈퇴와 보관 기준 확인</summary>
   <p>탈퇴하면 앱 이용·새 신청·매칭·단체방과 이 기기의 알림 권한을 회수해요. 미래 식탁은 남은 참가자의 조건을 다시 확인합니다. 탈퇴한 계정과 지운 프로필은 복원할 수 없어요.</p>
   <p>일반 프로필·신청 원본·비공개 사람 선택은 탈퇴 시 최소화해요. 보존할 거래 자료는 기본 5년, 안전·분쟁 근거는 기본 3년, 일반 감사 기록은 기본 1년으로 구분해 접근을 제한하고 기간 이후 서버가 정리합니다. 자료가 없으면 해당 보존 기간을 부여하지 않아요. 진행 중인 분쟁이나 미해결 금융 권리는 필요한 보존 사유가 끝날 때까지 자동 삭제에서 보호해요.</p>
   <p>탈퇴가 자동 환불이나 권리 포기를 뜻하지 않아요. 남은 이용권과 환불 선택을 먼저 참가 현황에서 확인해 주세요. 탈퇴 후에는 앱에서 직접 이용권을 사용하거나 환불을 신청할 수 없어요.</p>
   {data&&<p>보관 기준 {data.policyVersion} · 확인이 필요한 결제 신청 {data.unresolvedFinancialApplications}건</p>}
   {error&&<p role="alert">{error}</p>}{!data&&!error&&<p>계정 상태를 확인하고 있어요.</p>}
   <button className="secondary" disabled={busy} onClick={()=>{setError('');setData(null);setAttempt(v=>v+1)}}>탈퇴 가능 상태 다시 확인</button>
   {data?.withdrawn?<><p role="status">이미 탈퇴 처리된 계정이에요.</p><button onClick={()=>void onWithdraw(data)}>로그인 정보 정리</button></>:data?.canWithdraw&&<form onSubmit={async e=>{
    e.preventDefault();const f=new FormData(e.currentTarget);if(f.get('confirmation')!=='탈퇴'){setError('확인 문구에 탈퇴를 입력해 주세요.');return}
    setBusy(true);setError('');try{const receipt=await matchingRequest<Data>(token,'/privacy/withdraw',{requestKey:key.current,confirmation:'탈퇴'});await onWithdraw(receipt)}catch{setError('탈퇴 결과를 확인하지 못했어요. 같은 화면에서 상태를 다시 확인하거나 같은 내용으로 재시도해 주세요.')}finally{setBusy(false)}
   }}><fieldset disabled={busy}><legend>회원 탈퇴 확인</legend><label className="check-label"><input type="checkbox" required />미래 배정 취소·복원 불가·보관 기준과 남은 금융 권리를 확인했어요.</label><label htmlFor="withdraw-confirm">확인 문구 · 탈퇴</label><input id="withdraw-confirm" name="confirmation" required autoComplete="off" aria-invalid={!!error} aria-describedby={error?'withdraw-error':undefined} /><p id="withdraw-error" className="help">정확히 ‘탈퇴’를 입력해 주세요.</p><button>회원 탈퇴 처리</button></fieldset></form>}
  </details>
 </section>
}
