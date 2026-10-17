import { useEffect, useRef, useState } from 'react'
import type { FormEvent } from 'react'
import { matchingRequest } from './matching-api'

type Venues = {
  slots: { id: string; startsAt: string; regionLabel: string }[];
  inventory: { id: string; name: string; reservationName: string; mealPriceKrw: number; seats: number; rating: number; enabled: boolean; allocated: boolean }[];
  exceptions: { eventId: string; tableId: string; code: string; status: string; attempts: number; startsAt: string; regionLabel: string }[];
}
const date = (s: string) => new Date(s).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })
export default function VenueOperations({ token }: { token: string }) {
  const [data, setData] = useState<Venues | null>(null)
  const [attempt, setAttempt] = useState(0)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const key = useRef(crypto.randomUUID())
  useEffect(() => {
    let active = true
    matchingRequest<Venues>(token, '/operations/venues').then(v => { if (active) { setData(v); setError('') } }).catch(() => { if (active) setError('식당 재고를 불러오지 못했어요. 권한과 연결을 확인하고 다시 시도해 주세요.') })
    return () => { active = false }
  }, [token, attempt])
  async function run(path: string, payload: unknown, message: string) {
    setBusy(true); setError(''); setNotice('')
    try { setData(await matchingRequest<Venues>(token, `/operations/venues/${path}`, payload)); setNotice(message); return true }
    catch (cause) {
      const code = cause instanceof Error ? cause.message : ''
      setError(code === 'VENUE_DUPLICATE' ? '동일 회차·식당·예약명의 재고가 이미 있어요.' : code === 'VENUE_VERIFICATION_REQUIRED' ? '공개 회차·최근 7일 확인 시각·행사 시작 이후 예약 유효시각을 확인해 주세요.' : code === 'IDEMPOTENCY_CONFLICT' ? '같은 요청의 내용이 달라졌어요. 입력을 확인해 다시 등록해 주세요.' : '처리하지 못했어요. 입력 조건·권한을 확인하거나 같은 내용으로 다시 시도해 주세요.')
      return false
    } finally { setBusy(false) }
  }
  async function create(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const form = event.currentTarget
    const fields = new FormData(form)
    const time = (name: string) => new Date(`${fields.get(name)}:00+09:00`).toISOString()
    const lines = (name: string) => String(fields.get(name) ?? '').split('\n').map(v => v.trim()).filter(Boolean)
    const success = await run('create', { requestKey: key.current, slotId: fields.get('slotId'), name: fields.get('name'), address: fields.get('address'), mapUrl: fields.get('mapUrl'), reservationName: fields.get('reservationName'),
      mealPriceKrw: Number(fields.get('mealPriceKrw')), seats: Number(fields.get('seats')), rating: Number(fields.get('rating')), reviewCount: Number(fields.get('reviewCount')), reviewUrl: fields.get('reviewUrl'),
      verifiedAt: time('verifiedAt'), reservationValidUntil: time('reservationValidUntil'), safeAllergies: lines('safeAllergies'), safeAvoidedFoods: lines('safeAvoidedFoods'), verificationNote: fields.get('verificationNote'), reservationConfirmed: fields.has('reservationConfirmed'),
    }, '예약 재고를 등록했어요. 서버가 다음 예약 실행에서 조건을 검사하고 자동 배정해요.')
    if (success) { key.current = crypto.randomUUID(); form.reset() }
  }
  return <section aria-labelledby="venue-operations-title"><h3 id="venue-operations-title">식당 재고·자동 배정</h3>
    <p>예약이 확인된 식탁 한 건을 재고 한 개로 등록해요. 식당에 확인한 실제 정보만 입력해 주세요. 등록은 외부 예약을 대신하지 않아요.</p>
    <button type="button" className="secondary" disabled={busy} onClick={() => setAttempt(v => v + 1)}>식당 재고 새로고침</button>
    {error && <p role="alert">{error}</p>}{notice && <p role="status">{notice}</p>}
    {!data && !error && <p>식당 재고를 불러오고 있어요.</p>}
    {data && <><form onSubmit={create} onChange={() => { key.current = crypto.randomUUID() }}><fieldset disabled={busy || !data.slots.length}><legend>확인된 예약 재고 등록</legend>
      <label htmlFor="venue-slot">배정 회차 (필수)</label><select id="venue-slot" name="slotId" required defaultValue=""><option value="">선택해 주세요</option>{data.slots.map(s => <option key={s.id} value={s.id}>{date(s.startsAt)} · {s.regionLabel}</option>)}</select>
      <label htmlFor="venue-name">식당 이름 (필수)</label><input id="venue-name" name="name" required maxLength={500} />
      <label htmlFor="venue-address">주소 (필수)</label><input id="venue-address" name="address" required maxLength={500} />
      <label htmlFor="venue-map">지도 HTTPS 링크 (필수)</label><input id="venue-map" name="mapUrl" type="url" pattern="https://.*" required maxLength={1500} />
      <label htmlFor="venue-reservation">예약명·식탁 식별명 (필수)</label><input id="venue-reservation" name="reservationName" required maxLength={500} /><p>참가자에게 안내할 실제 예약명이에요. 같은 예약을 여러 재고로 중복 등록하지 마세요.</p>
      <label htmlFor="venue-price">1인 식사 가격·원 (필수)</label><input id="venue-price" name="mealPriceKrw" type="number" min={10000} max={1000000} step={1} required />
      <label htmlFor="venue-seats">예약 좌석 수 (필수·4~6)</label><input id="venue-seats" name="seats" type="number" min={4} max={6} step={1} required />
      <label htmlFor="venue-rating">5점 만점 리뷰 평점 (필수·4.0 이상)</label><input id="venue-rating" name="rating" type="number" min={4} max={5} step={0.01} required />
      <label htmlFor="venue-reviews">리뷰 수 (필수·20개 이상)</label><input id="venue-reviews" name="reviewCount" type="number" min={20} max={9999999} step={1} required />
      <label htmlFor="venue-review-url">리뷰 출처 HTTPS 링크 (필수)</label><input id="venue-review-url" name="reviewUrl" type="url" pattern="https://.*" required maxLength={1500} />
      <label htmlFor="venue-verified">리뷰·예약·메뉴 확인 시각 (필수·한국 시각·최근 7일)</label><input id="venue-verified" name="verifiedAt" type="datetime-local" required />
      <label htmlFor="venue-valid">예약 유효시각 (필수·한국 시각·행사 시작 이후)</label><input id="venue-valid" name="reservationValidUntil" type="datetime-local" required />
      <label htmlFor="venue-allergies">식당에 대응 가능함을 확인한 알레르기 문구 (한 줄에 하나)</label><textarea id="venue-allergies" name="safeAllergies" maxLength={5000} />
      <label htmlFor="venue-avoided">식당에 대응 가능함을 확인한 기피 음식 문구 (한 줄에 하나)</label><textarea id="venue-avoided" name="safeAvoidedFoods" maxLength={5000} /><p>해당 예약 메뉴와 교차접촉 대응을 확인한 문구만 입력하세요. 참가자 문구 전체와 일치하지 않거나 정보가 없으면 자동 배정하지 않아요.</p>
      <label htmlFor="venue-note">예약·식사 조건 확인 근거 (필수·운영자 전용)</label><textarea id="venue-note" name="verificationNote" required maxLength={500} />
      <label className="check-label"><input type="checkbox" name="reservationConfirmed" required />실제 예약과 위 식사 조건을 식당에 확인했어요.</label><button type="submit">{busy ? '등록 중…' : '확인된 식당 재고 등록'}</button>
    </fieldset></form>
      {!data.slots.length && <p>식당 재고를 연결할 공개 회차가 없어요. 모집 회차를 먼저 등록·발행해 주세요.</p>}
      <h4>등록된 식당 재고</h4>{!data.inventory.length && <p>등록된 예약 재고가 없어요.</p>}{data.inventory.map(v => <div key={v.id} className="previous-forms"><p>{v.name} · {v.reservationName} · {v.seats}석 · 1인 {v.mealPriceKrw.toLocaleString()}원</p><p>{!v.enabled ? '사용 중지' : v.allocated ? '배정됨' : '배정 가능 여부 검사 대기'}</p>{v.enabled && <details><summary>예약 재고 사용 중지</summary><p>배정된 식당 안내가 내려가고 다른 재고를 다시 검사해요. 실제 식당 예약 취소는 별도로 확인해 주세요.</p><button type="button" disabled={busy} onClick={() => void run('revoke', { inventoryId: v.id }, '재고를 사용 중지하고 재배정 검사를 예약했어요.')}>사용 중지 확인</button></details>}</div>)}
      <h4>식당 배정 확인 필요</h4>{!data.exceptions.length && <p>현재 식당 배정 예외가 없어요.</p>}{data.exceptions.map(e => <div key={e.eventId} className="previous-forms"><p>{date(e.startsAt)} · {e.regionLabel}</p><p>{e.code === 'VENUE_NO_COMPATIBLE_INVENTORY' ? '인원·가격·식사 조건을 충족하는 예약 재고가 없어요.' : e.code === 'VENUE_EVENT_STARTED' ? '행사가 시작되어 자동 배정을 중단했어요.' : '자동 식당 배정을 확인해 주세요.'}</p><p>시도 {e.attempts}회 · {e.status === 'EXCEPTION' ? '운영 확인 필요' : '자동 재시도 대기'}</p>{e.status === 'EXCEPTION' && <button type="button" disabled={busy} onClick={() => void run('retry', { eventId: e.eventId }, '식당 배정을 재시도하도록 예약했어요.')}>식당 배정 재시도</button>}</div>)}
    </>}
  </section>
}
