import { useId, useRef, useState } from 'react'
import { matchingRequest } from './matching-api'
import type { MatchApplication } from './matching-api'

const date = (s: string) => new Date(s).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })
const errors: Record<string, string> = {
  PARTICIPATION_RESTRICTED: '참가 제한 중에는 다른 일정으로 이동할 수 없어요. 보관·환불 가능 여부를 확인해 주세요.',
  EVENT_CLOSED: '선택한 모집이 마감됐어요. 매칭 상태를 새로고침하고 다시 선택해 주세요.',
  CONSENT_REQUIRED: '회차 신청에서 현재 개인정보·운영 정책 동의를 먼저 완료해 주세요.',
  MEMBERSHIP_REQUIRED: '선택한 행사까지 유효한 멤버십이 필요해요.',
  MEMBERSHIP_IN_USE: '다른 신청에 사용한 멤버십은 전액 환불할 수 없어요. 중도·부분 환불은 지원하지 않아요.',
  REFUND_CLOSED: '환불 제한 시각이 지나 환불할 수 없어요.',
  CANCELLATION_CLOSED: '행사가 시작돼 앱에서 취소할 수 없어요.',
  DUPLICATE_APPLICATION: '이미 신청했거나 확정된 일정과 겹쳐요. 다른 회차를 선택해 주세요.',
  RESOLUTION_CONFLICT: '신청 상태가 바뀌었어요. 매칭 상태를 새로고침해 주세요.',
  PAYMENT_CONFLICT: '결제·환불 상태를 확인한 뒤 다시 시도해 주세요.',
  IDEMPOTENCY_CONFLICT: '요청 내용이 바뀌었어요. 매칭 상태를 새로고침해 주세요.',
  UNAUTHENTICATED: '로그인이 만료됐어요. 다시 로그인해 주세요.',
}
type Action = '' | 'transfer' | 'store' | 'refund' | 'cancel'
export default function ResolutionActions({ application: a, token, onChanged }: { application: MatchApplication; token: string; onChanged: () => void }) {
  const id = useId()
  const key = useRef(crypto.randomUUID())
  const [action, setAction] = useState<Action>('')
  const [slot, setSlot] = useState('')
  const [outcome, setOutcome] = useState('success')
  const [confirmed, setConfirmed] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const reset = () => { key.current = crypto.randomUUID(); setConfirmed(false); setError(''); setNotice('') }
  if (!a.canResolve && !a.canCancel && !a.canRefund) return null
  const target = a.alternatives.find(s => s.id === slot)
  async function submit(event: React.FormEvent) {
    event.preventDefault()
    if (!action || !confirmed || busy || (action === 'transfer' && !target)) return
    setBusy(true); setError('')
    try {
      await matchingRequest(token, '/matching/resolve', { applicationId: a.id, requestKey: key.current, action,
        ...(action === 'transfer' ? { slotId: slot } : {}), ...(action === 'refund' ? { outcome } : {}) })
      setAction(''); setConfirmed(false); key.current = crypto.randomUUID()
      setNotice(action === 'refund' && outcome === 'failure' ? '모의 환불 실패를 기록했어요. 같은 원거래로 다시 시도할 수 있어요.' : '선택한 처리가 완료됐어요. 최신 신청 상태를 확인해 주세요.')
      onChanged()
    } catch (cause) { setError(errors[cause instanceof Error ? cause.message : ''] ?? '처리 결과를 확인하지 못했어요. 같은 내용으로 다시 시도하거나 매칭 상태를 새로고침해 주세요.') }
    finally { setBusy(false) }
  }
  return <form onSubmit={submit} aria-label="신청 해결 선택">
    {notice && <p role="status">{notice}</p>}
    <fieldset disabled={busy}><legend>다음 행동 선택</legend>
      <label htmlFor={`${id}-action`}>처리 방법</label>
      <select id={`${id}-action`} value={action} onChange={e => { reset(); setAction(e.target.value as Action) }}>
        <option value="">선택해 주세요</option>
        {a.canResolve && !!a.alternatives.length && <option value="transfer">결제를 유지하고 다른 일정으로 이동</option>}
        {a.canResolve && !a.stored && <option value="store">신청을 중단하고 이용권 보관</option>}
        {a.canRefund && <option value="refund">원결제 모의 환불</option>}
        {a.canCancel && <option value="cancel">참가 취소</option>}
      </select>
      {action === 'transfer' && <><label htmlFor={`${id}-slot`}>이동할 일정·지역</label><select required id={`${id}-slot`} value={slot} onChange={e => { reset(); setSlot(e.target.value) }}><option value="">일정을 선택해 주세요</option>{a.alternatives.map(s => <option key={s.id} value={s.id}>{date(s.startsAt)} · {s.regionLabel}</option>)}</select><p>기존 신청은 이동 완료로 남고, 선택한 회차에 새 매칭 대기 신청이 생성돼요. 추가 결제는 없어요.</p></>}
      {action === 'store' && <p>이번 신청의 매칭을 중단해요. 1회권은 보관 후 다른 모집에 사용할 수 있어요. 멤버십 기간은 동결되지 않으며 유효기간 안에서 재사용할 수 있어요.</p>}
      {action === 'cancel' && <p>참가 취소를 접수하고 함께 배정된 식탁을 다시 확인해요. 환불 제한 시각 {a.refundCutoffAt ? date(a.refundCutoffAt) : '확인 필요'} 이후에는 이용권 복구·환불 없이 취소돼요. 제한 전 취소도 환불은 별도로 선택해야 해요.</p>}
      {action === 'refund' && <><p>모의 환불이에요. 원결제 전체 금액을 한 번 반환하며 해당 이용권을 다시 사용할 수 없어요. 사용한 멤버십의 중도·부분 환불은 지원하지 않아요.</p><label htmlFor={`${id}-outcome`}>모의 환불 결과</label><select id={`${id}-outcome`} value={outcome} onChange={e => { reset(); setOutcome(e.target.value) }}><option value="success">성공</option><option value="failure">실패 (재시도 확인)</option></select></>}
      {!!action && <><label className="check-label"><input type="checkbox" checked={confirmed} onChange={e => setConfirmed(e.target.checked)} />{action === 'transfer' && target ? `${date(target.startsAt)} · ${target.regionLabel} 이동에 동의해요.` : '위 처리 내용과 결과를 확인했어요.'}</label><button type="submit" disabled={!confirmed || (action === 'transfer' && !target)}>{busy ? '처리 중…' : '선택한 처리 실행'}</button></>}
    </fieldset>
    {error && <p role="alert">{error}</p>}
  </form>
}
