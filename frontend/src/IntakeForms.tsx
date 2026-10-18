import { lazy, Suspense, useEffect, useLayoutEffect, useRef, useState } from 'react'
import type { FormEvent } from 'react'
import { matchingRequest } from './matching-api'
import { intakeRequest } from './intake-api'
import type { Intake, Identity, Onboarding, ApplicationInput, Group } from './intake-api'
import type { Member } from './member-api'
import { memberRequest } from './member-api'
import MatchingPanel from './MatchingPanel'
const ReturnRecommendations = lazy(() => import('./ReturnRecommendations'))

const emptyInput = (): ApplicationInput => ({ slotIds: [], regions: [], otherRegion: '', ticketCode: '' })
const emptyOnboarding = (): Onboarding => ({ instagram: '', birthYear: '', gender: '', occupation: '', mbti: [], interests: [], traits: [], preferredTraits: [], mealBudgetBands: [], avoidedFoods: '', allergies: '' })
const date = (value: string) => new Intl.DateTimeFormat('ko-KR', { timeZone: 'Asia/Seoul', month: 'long', day: 'numeric', weekday: 'short', hour: '2-digit', minute: '2-digit' }).format(new Date(value))
const applicationLabels: Record<string,string> = { SUBMITTED: '접수됨', CANCELED: '취소됨' }
const paymentLabels: Record<string,string> = { PENDING: '대기', PAID: '완료', FAILED: '실패', REFUNDED: '환불 완료', REFUND_FAILED: '환불 실패 (재시도 필요)' }
const matchingLabels: Record<string,string> = { WAITING: '대기', MATCHING: '진행 중', REALLOCATING: '재배치 중', CONFIRMED: '확정', ALTERNATIVE_OFFERED: '대안 선택', TRANSFERRED: '일정 이동', NO_MATCH: '미성사', EXCEPTION: '확인 필요' }
const errors: Record<string, string> = {
  PARTICIPATION_RESTRICTED: '참가 제한 중에는 새 신청·결제를 진행할 수 없어요. 안전 상태를 확인해 주세요.',
  UNAUTHENTICATED: '로그인이 만료됐어요. 다시 로그인해 주세요.', FORBIDDEN: '본인 신청서만 불러올 수 있어요.',
  VALIDATION_ERROR: '필수 항목과 선택 내용을 확인해 주세요.', SCHEMA_CHANGED: '질문이 변경됐어요. 다시 불러와 확인해 주세요.',
  PROFILE_REQUIRED: '가입 기본정보와 온보딩을 먼저 저장해 주세요.', EVENT_CLOSED: '선택한 모집이 마감됐어요. 일정을 다시 선택해 주세요.',
  TICKET_UNAVAILABLE: '사용 가능한 참가권을 확인하지 못했어요. 참가권을 최신 목록에서 다시 선택해 주세요.',
  REFUND_CLOSED: '자발 취소 환불 제한 시각이 지났어요.', MEMBERSHIP_IN_USE: '다른 신청에 사용 중인 멤버십은 전체 환불할 수 없어요.',
  MEMBERSHIP_REQUIRED: '선택한 행사까지 유효한 멤버십이 필요해요.', MEMBERSHIP_ACTIVE: '이미 유효한 멤버십이 있어요. 보유 멤버십 사용을 선택해 주세요.', PAYMENT_CONFLICT: '이미 결제했거나 처리할 수 없는 상태예요. 다시 불러와 확인해 주세요.',
  CONSENT_REQUIRED: '신청 전에 현재 개인정보·운영 정책 동의를 완료해 주세요.', DUPLICATE_APPLICATION: '같은 일정에 이미 신청했어요. 내 신청 내역을 확인해 주세요.',
  IDEMPOTENCY_CONFLICT: '다른 내용으로 같은 요청이 전송됐어요. 다시 불러와 확인해 주세요.', DRAFT_CHANGED: '다른 화면에서 신청서가 변경됐어요. 다시 불러와 내용을 확인해 주세요.',
}
function Choices({ group, selected, onChange, error }: { group: Group; selected: string[]; onChange: (value: string[]) => void; error?: string }) {
  return <fieldset aria-describedby={error ? `error-${group.key}` : undefined}><legend>{group.label} (필수{group.multiple ? '·복수 선택' : ''})</legend>
    {group.options.map(option => <label className="check-label" key={option.id}><input name={group.key} type={group.multiple ? 'checkbox' : 'radio'} value={option.id} checked={selected.includes(option.id)} onChange={event => onChange(group.multiple ? event.target.checked ? [...selected, option.id] : selected.filter(v => v !== option.id) : [option.id])} />{option.label}</label>)}
    {error && <p id={`error-${group.key}`} className="field-error">{error}</p>}
  </fieldset>
}

export default function IntakeForms({ token, member, onMemberChange }: { token: string; member: Member; onMemberChange: (member: Member) => void }) {
  const [data, setData] = useState<Intake | null>(null)
  const [identity, setIdentity] = useState<Identity>({ name: member.displayName ?? member.profile?.name ?? '', contact: member.profile?.contact ?? '' })
  const [onboarding, setOnboarding] = useState<Onboarding>(() => ({ ...emptyOnboarding(), birthYear: member.profile?.birthYear ?? '', occupation: member.profile?.occupation ?? '', avoidedFoods: member.profile?.avoidedFoods.join(', ') ?? '', allergies: member.profile?.allergies.join(', ') ?? '' }))
  const [input, setInput] = useState<ApplicationInput>(emptyInput)
  const [sourceId, setSourceId] = useState<string | null>(null)
  const [step, setStep] = useState(0)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [fieldErrors, setFieldErrors] = useState<Record<string, string>>({})
  const [attempt, setAttempt] = useState(0)
  const requestKey = useRef(crypto.randomUUID())
  const applicationHeading = useRef<HTMLHeadingElement>(null)
  const focusApplication = useRef(false)
  const startSlots = JSON.stringify(input.slotIds)
  useEffect(() => {
    if (step === 2 && member.role === 'participant') {
      void matchingRequest(token, '/intake/start', { requestKey: requestKey.current, slotIds: JSON.parse(startSlots) }).catch(() => { /* Measurement failure must not block the participant. */ })
    }
  }, [token, step, startSlots, member.role])
  useLayoutEffect(() => {
    if (focusApplication.current && step === 2 && applicationHeading.current) {
      applicationHeading.current.focus()
      focusApplication.current = false
    }
  }, [input.slotIds, step])
  useEffect(() => {
    let active = true
    intakeRequest(token).then(value => {
      if (!active) return
      setData(value); setError('')
      if (value.identity) setIdentity(value.identity)
      if (value.onboarding) setOnboarding(value.onboarding)
      if (value.draft) { setInput(value.draft.input); setSourceId(value.draft.sourceId) }
    }).catch(cause => { if (active) setError(errors[cause.message] ?? '정보를 불러오지 못했어요. 다시 시도해 주세요.') })
    return () => { active = false }
  }, [token, attempt])
  async function run(task: () => Promise<Intake>, success: string) {
    setBusy(true); setError(''); setNotice('')
    try { const value = await task(); setData(value); setNotice(success); return value }
    catch (cause) { setError(errors[cause instanceof Error ? cause.message : ''] ?? '저장하지 못했어요. 연결을 확인하고 다시 시도해 주세요.'); return null }
    finally { setBusy(false) }
  }
  function updateInput(next: ApplicationInput) { setInput(next); requestKey.current = crypto.randomUUID() }
  async function saveOnboarding(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const missing: Record<string,string> = {}
    for (const key of ['mbti','interests','traits','preferredTraits','mealBudgetBands'] as const) if (!onboarding[key].length) missing[key] = '하나 이상 선택해 주세요.'
    if (!onboarding.gender) missing.gender = '성별을 선택해 주세요.'
    setFieldErrors(missing)
    if (Object.keys(missing).length) { event.currentTarget.querySelector<HTMLInputElement>(`[name=${Object.keys(missing)[0]}]`)?.focus(); return }
    const value = await run(() => intakeRequest(token, '/onboarding', { schemaVersion: data!.schemaVersion, data: onboarding }), '온보딩을 저장했어요.')
    if (value) setStep(2)
  }
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const missing: Record<string,string> = {}
    if (!input.regions.length) missing.regions = '참석 가능 지역을 선택해 주세요.'
    if (!input.slotIds.length) missing.slots = '실제 참석 가능한 일정·지역 조합을 선택해 주세요.'
    setFieldErrors(missing)
    if (Object.keys(missing).length) return
    await run(async () => {
      const saved = await intakeRequest(token, '/draft', { input, sourceId })
      return intakeRequest(token, '/submit', { requestKey: requestKey.current, draftRevision: saved.draft!.revision })
    }, '신청서를 제출했어요. 결제 상태를 확인해 주세요. 매칭 확정은 아니에요.')
  }
  if (!data) return <div>{error ? <><p role="alert">{error}</p><button onClick={() => setAttempt(v => v + 1)}>다시 불러오기</button></> : <p>가입·온보딩 정보를 불러오고 있어요.</p>}</div>
  const regionGroup = data.groups.find(group => group.key === 'regions')!
  return <div>
    <Suspense fallback={<p>다음 식탁 추천을 불러오고 있어요.</p>}><ReturnRecommendations token={token} onSelect={async slot => {
      const latest = await intakeRequest(token)
      if (!latest.slots.some(s => s.id === slot.id && s.regionCode === slot.regionCode)) throw new Error('EVENT_CLOSED')
      setData(latest)
      focusApplication.current = true
      updateInput({ ...input, regions: [slot.regionCode], slotIds: [slot.id], otherRegion: '' })
      setSourceId(null)
      setError(''); setFieldErrors({})
      setStep(2)
    }} /></Suspense>
    <MatchingPanel token={token} onReview={() => setStep(2)} onChanged={() => setAttempt(v => v + 1)} />
    <nav className="intake-steps" aria-label="참가 준비 단계">{['가입 기본정보','온보딩','회차 신청'].map((label, index) => <button type="button" key={label} className={step === index ? '' : 'secondary'} aria-current={step === index ? 'step' : undefined} onClick={() => { setStep(index); setNotice(''); setFieldErrors({}) }}>{index + 1}. {label}</button>)}</nav>
    {error && <div role="alert"><p className="member-error">{error}</p><button className="secondary" onClick={() => setAttempt(v => v + 1)}>다시 불러오기</button></div>}
    {notice && <p aria-live="polite">{notice}</p>}
    {step === 0 && <form onSubmit={async event => {
      event.preventDefault()
      const value = await run(() => intakeRequest(token, '/identity', { schemaVersion: data.schemaVersion, data: identity }), '가입 기본정보를 저장했어요.')
      if (value) setStep(1)
    }}><h3>가입 기본정보</h3><p>소셜 로그인 후에도 이름과 연락처를 직접 확인해 주세요. 연락처는 한 번 더 오타를 확인해 주세요.</p>
      <label htmlFor="intake-name">이름 (필수)</label><input id="intake-name" required maxLength={100} value={identity.name} onChange={event => setIdentity({ ...identity, name: event.target.value })} />
      <label htmlFor="intake-contact">연락처 (필수)</label><input id="intake-contact" required type="tel" maxLength={100} value={identity.contact} onChange={event => setIdentity({ ...identity, contact: event.target.value })} />
      <button disabled={busy}>기본정보 저장하고 계속</button>
    </form>}
    {step === 1 && <form onSubmit={saveOnboarding}><h3>나를 소개하는 온보딩</h3>
      {member.profile && !data.onboarding && <p>기존 프로필의 기본 입력을 가져왔어요. 새 선택지와 Instagram 정보를 확인해 저장해 주세요.</p>}
      <p>다음 신청에도 불러올 수 있어요. Instagram과 비공개 선호는 참가자에게 공개하지 않아요.</p>
      <label htmlFor="instagram">Instagram ID (필수)</label><input id="instagram" required maxLength={100} value={onboarding.instagram} onChange={event => setOnboarding({ ...onboarding, instagram: event.target.value })} /><p className="help">어떤 분인지 확인하기 위한 정보예요.</p>
      <label htmlFor="birth-year">출생연도 (나이 확인용·필수)</label><input id="birth-year" type="number" required min={1900} max={new Date().getFullYear()} value={onboarding.birthYear} onChange={event => setOnboarding({ ...onboarding, birthYear: event.target.value ? Number(event.target.value) : '' })} />
      <p className="help">나이는 출생연도를 기준으로 확인해요.</p>
      <label htmlFor="occupation">직업 (구체적으로·필수)</label><input id="occupation" required maxLength={100} value={onboarding.occupation} onChange={event => setOnboarding({ ...onboarding, occupation: event.target.value })} />
      <Choices group={{ key: 'mbti', label: 'MBTI', multiple: true, options: ['E','I'].flatMap(a => ['N','S'].flatMap(b => ['F','T'].flatMap(c => ['J','P'].map(d => ({ id: a+b+c+d, label: a+b+c+d }))))) }} selected={onboarding.mbti} onChange={value => setOnboarding({ ...onboarding, mbti: value })} error={fieldErrors.mbti} />
      {data.groups.filter(group => group.key !== 'regions').map(group => <Choices key={group.key} group={group} selected={group.key === 'gender' ? [onboarding.gender] : onboarding[group.key as 'interests'] as string[]} onChange={value => setOnboarding({ ...onboarding, [group.key]: group.key === 'gender' ? value[0] : value })} error={fieldErrors[group.key]} />)}
      <label htmlFor="avoided-foods">못 먹는 음식 (선택)</label><textarea id="avoided-foods" maxLength={500} value={onboarding.avoidedFoods} onChange={event => setOnboarding({ ...onboarding, avoidedFoods: event.target.value })} />
      <label htmlFor="allergies">알레르기 (선택)</label><textarea id="allergies" maxLength={500} value={onboarding.allergies} onChange={event => setOnboarding({ ...onboarding, allergies: event.target.value })} />
      <button disabled={busy}>온보딩 저장하고 계속</button>
    </form>}
    {step === 2 && <>
      <h3 ref={applicationHeading} tabIndex={-1}>이번 회차 신청</h3><p>식사 비용은 현장에서 각자 계산해요. 참가비와 별도입니다. 일정·지역 조합을 직접 선택해 주세요.</p>
      <div className="previous-forms"><h4>기존 신청서 불러오기</h4>{data.applications.length ? data.applications.map(application => <div key={application.id}><p>{date(application.submittedAt)} 신청 · {applicationLabels[application.applicationStatus] ?? '확인 필요'} · 결제 {paymentLabels[application.paymentStatus] ?? '확인 필요'} · 매칭 {matchingLabels[application.matchingStatus] ?? '확인 필요'}</p><p>선택한 참가권: {application.input.ticketCode === 'single_v2' ? '1회권' : application.input.ticketCode.startsWith('membership') ? '멤버십' : '이전 참가권'}</p><button className="secondary" disabled={busy} onClick={async () => {
        const value = await run(() => intakeRequest(token, '/reuse', { sourceId: application.id }), '이전 지역·참가권을 가져왔어요. 날짜는 다시 선택하고 현재 프로필을 확인해 주세요.')
        if (value?.draft) { setInput(value.draft.input); setSourceId(value.draft.sourceId); requestKey.current = crypto.randomUUID() }
      }}>이 신청서 불러오기</button><button className="secondary" onClick={() => {
        setIdentity(application.identitySnapshot); setOnboarding(application.onboardingSnapshot); setStep(0); setNotice('이전 프로필을 편집 화면에 가져왔어요. 확인 후 저장하면 현재 프로필이 변경돼요. 원본 신청서는 유지돼요.')
      }}>이전 프로필 내용으로 편집</button>
        <p>참석: {application.attendanceStatus === 'SCHEDULED' ? '예정' : application.attendanceStatus} · {application.eligible ? '매칭 참가 자격 확인됨' : '결제·멤버십 자격 확인 필요'}</p>
        {['PENDING','FAILED'].includes(application.paymentStatus) && <div><p>모의 결제 · ₩{application.productSnapshot.amountKrw.toLocaleString('ko-KR')} · 실제 청구하지 않아요.</p>{(['success','failure'] as const).map(outcome => <button type="button" key={outcome} className={outcome === 'failure' ? 'secondary' : ''} disabled={busy} onClick={() => run(() => intakeRequest(token, '/payment', { applicationId: application.id, requestKey: crypto.randomUUID(), outcome }), outcome === 'success' ? '모의 결제가 완료됐어요.' : '모의 결제 실패를 기록했어요. 다시 결제할 수 있어요.')}>{outcome === 'success' ? '모의 결제 성공' : '모의 결제 실패'}</button>)}</div>}
        {['PAID','REFUND_FAILED'].includes(application.paymentStatus) && application.input.ticketCode !== 'membership_use' && <details><summary>모의 환불·신청 취소</summary><p>환불 성공 시 이 신청이 취소돼요. 자발 환불은 표시된 제한 시각 전에만 가능하고, 멤버십은 다른 신청에 사용하지 않은 경우 전체 환불할 수 있어요. 실제 돈은 반환하지 않아요.</p>{(['success','failure'] as const).map(outcome => <button type="button" className="secondary" key={outcome} disabled={busy} onClick={() => { if (window.confirm('모의 환불을 요청합니다. 성공하면 이 신청이 취소되고 구매한 멤버십 자격도 회수돼요. 진행할까요?')) void run(() => intakeRequest(token, '/refund', { applicationId: application.id, requestKey: crypto.randomUUID(), outcome }), outcome === 'success' ? '모의 환불과 신청 취소가 완료됐어요.' : '모의 환불 실패를 기록했어요. 다시 시도해 주세요.') }}>{outcome === 'success' ? '모의 환불 성공' : '모의 환불 실패'}</button>)}</details>}
      </div>) : <p>이전에 제출한 신청서가 없어요.</p>}</div>
      <h4>보유 멤버십</h4>{data.memberships.length ? data.memberships.map(m => <p key={m.id}>{date(m.startsAt)} ~ {date(m.endsAt)} · 실패 보상 {m.extensionDays}일 연장 · {m.active ? '기간 확인 후 사용 가능' : '사용 중지'}</p>) : <p>보유한 멤버십이 없어요.</p>}
      <form onSubmit={submit}>
        {sourceId && <p>이전 신청서에서 가져온 새 초안입니다. 현재 저장된 기본정보·온보딩으로 제출하며 결제·확정 상태와 동의는 복사하지 않아요.</p>}
        <Choices group={regionGroup} selected={input.regions} onChange={value => updateInput({ ...input, regions: value, slotIds: input.slotIds.filter(id => data.slots.some(slot => slot.id === id && value.includes(slot.regionCode))) })} error={fieldErrors.regions} />
        {input.regions.includes('other') && <><label htmlFor="other-region">기타 희망 지역 (구체적으로·필수)</label><input id="other-region" required maxLength={200} value={input.otherRegion} onChange={event => updateInput({ ...input, otherRegion: event.target.value })} /><p>희망 지역을 기록하며, 모집 회차가 없는 지역으로 자동 배정하지 않아요.</p></>}
        <fieldset><legend>참가 가능한 일정·지역 (필수·복수 선택)</legend>{data.slots.filter(slot => input.regions.includes(slot.regionCode)).map(slot => <label className="check-label" key={slot.id}><input type="checkbox" checked={input.slotIds.includes(slot.id)} onChange={event => updateInput({ ...input, slotIds: event.target.checked ? [...input.slotIds, slot.id] : input.slotIds.filter(id => id !== slot.id) })} />{date(slot.startsAt)} · {slot.regionLabel} (마감 {date(slot.closesAt)}) · 환불 제한 {date(slot.refundCutoffAt)}부터{slot.matchesAt ? ` · 매칭 예정 ${date(slot.matchesAt)}` : ''}</label>)}
          {!data.slots.length && <p>현재 모집 중인 회차가 없어요. 초안을 저장하고 나중에 다시 확인해 주세요.</p>}
          {!!data.slots.length && !data.slots.some(slot => input.regions.includes(slot.regionCode)) && <p>지역을 선택하면 실제 모집 일정이 표시돼요.</p>}
          {fieldErrors.slots && <p className="field-error">{fieldErrors.slots}</p>}
        </fieldset>
        <label htmlFor="ticket">참가권 선택 (필수)</label><select id="ticket" required value={input.ticketCode} onChange={event => updateInput({ ...input, ticketCode: event.target.value })}><option value="">선택해 주세요</option>{data.products.map(product => <option key={product.code} value={product.code}>{product.label} · ₩{product.amountKrw.toLocaleString('ko-KR')}{product.validityMonths ? ` · ${product.validityMonths}개월 무제한` : ''}</option>)}</select>
        {input.ticketCode && !data.products.some(p => p.code === input.ticketCode) && <p role="alert">이전 상품은 판매가 종료됐어요. 참가권을 다시 선택해 주세요.</p>}
        <p>멤버십은 결제 시점부터 달력 개월로 계산하며 선택한 행사 시작까지 유효해야 해요. 횟수 제한은 없고 매칭 실패 1건당 7일 연장해요. 자발 취소 환불은 행사 전 화요일 24:00부터 제한돼요. 매칭 실패 시 해결 선택은 별도로 안내해요.</p>
        <details><summary>참여 안내</summary><p>소개팅이나 이성 만남을 목적으로 한 자리가 아니며 연애 목적 매칭을 보장하지 않아요. 과도한 연락처 요구나 상대방에게 부담을 주는 행동은 제한될 수 있어요. 신청만으로 매칭이 보장되지 않으며, 선택하지 않은 일정으로 자동 이동하지 않아요.</p></details>
        <div><h4>필수 동의</h4>{member.consentDocuments.length ? member.consentDocuments.filter(doc => doc.required).map(doc => <details key={doc.id}><summary>{doc.title} · {doc.version}</summary><p className="policy-body">{doc.body}</p></details>) : <p>개인정보·운영 동의 문서를 준비 중이에요. 발행 전에는 신청을 제출할 수 없어요.</p>}
          {member.consentDocuments.filter(doc => doc.required).map(doc => <label key={`${doc.id}-${doc.version}`} className="check-label"><input type="checkbox" name={`consent-${doc.id}`} required defaultChecked={member.acceptedConsents.some(value => value.id === doc.id && value.version === doc.version)} />{doc.title}에 동의합니다.</label>)}
          {member.consentDocuments.length > 0 && <button type="button" className="secondary" disabled={busy} onClick={async event => {
            const form = event.currentTarget.form!
            if (member.consentDocuments.some(doc => doc.required && !form.querySelector<HTMLInputElement>(`[name="consent-${doc.id}"]`)?.checked)) { setError('필수 동의 문서를 모두 확인하고 선택해 주세요.'); return }
            setBusy(true); setError('')
            try { const value = await memberRequest(token, 'POST', { documents: member.consentDocuments.filter(doc => doc.required).map(({ id, version }) => ({ id, version })) }, '/consents'); onMemberChange(value); setNotice('필수 동의를 저장했어요.') }
            catch { setError('동의가 변경됐거나 저장하지 못했어요. 다시 로그인해 문서를 확인해 주세요.') }
            finally { setBusy(false) }
          }}>동의 저장</button>}
        </div>
        <button type="button" className="secondary" disabled={busy} onClick={() => run(() => intakeRequest(token, '/draft', { input, sourceId }), '신청서 초안을 저장했어요. 아직 제출되지 않았어요.')}>초안 저장</button>
        <button disabled={busy || !data.slots.length || !member.consentDocuments.some(doc => doc.kind === 'privacy') || !member.consentDocuments.some(doc => doc.kind === 'operations')}>신청서 제출</button>
      </form>
    </>}
  </div>
}
