import { useEffect, useState } from 'react'
import { matchingRequest } from './matching-api'
type Policy = { version: string; minimumScore: number; weights: Record<string, number> }
const fields = { age: '연령', gender: '성비', mbti: 'MBTI', interests: '관심사', traits: '대화 성향' }
export default function MatchingPolicy({ token }: { token: string }) {
 const [data, setData] = useState<Policy | null>(null)
 const [error, setError] = useState('')
 const [notice, setNotice] = useState('')
 const [busy, setBusy] = useState(false)
 const [attempt, setAttempt] = useState(0)
 useEffect(() => {
  let active = true
  matchingRequest<Policy>(token, '/operations/policy').then(v => { if (active) { setData(v); setError('') } }).catch(() => { if (active) setError('매칭 규칙을 불러오지 못했어요. 다시 시도해 주세요.') })
  return () => { active = false }
 }, [token, attempt])
 return <section aria-labelledby="policy-title"><h3 id="policy-title">매칭 규칙 설정</h3>
  <p>전역 규칙은 다음 매칭 실행부터 적용돼요. 확정 결과와 실행 이력은 유지돼요. 인원·연령차·선택 일정·제외 관계는 완화하지 않아요.</p>
  <button type="button" className="secondary" disabled={busy} onClick={() => setAttempt(v => v + 1)}>매칭 규칙 새로고침</button>
  {error && <p role="alert">{error}</p>}{notice && <p role="status">{notice}</p>}
  {!data && !error && <p>현재 규칙을 확인하고 있어요.</p>}
  {data && <form onSubmit={async e => {
   e.preventDefault(); setError(''); setNotice('')
   if (Math.abs(Object.values(data.weights).reduce((a, b) => a + b, 0) - 100) > 0.000001) { setError('가중치 합계를 100으로 맞춰 주세요.'); return }
   setBusy(true)
   try { setData(await matchingRequest<Policy>(token, '/operations/policy', { expectedVersion: data.version, minimumScore: data.minimumScore, weights: data.weights })); setNotice('새 매칭 규칙을 발행했어요.') }
   catch { setError('규칙을 저장하지 못했어요. 다른 운영자의 변경이 있는지 새로고침 후 확인해 주세요.') }
   finally { setBusy(false) }
  }}><p>현재 버전: {data.version}</p>
   <label>최소 매칭 점수<input type="number" min="0" max="100" step="0.1" required value={data.minimumScore} disabled={busy} onChange={e => setData({ ...data, minimumScore: Number(e.target.value) })} /></label>
   {Object.entries(fields).map(([key, label]) => <label key={key}>{label} 가중치<input type="number" min="0" max="100" step="0.1" required disabled={busy} value={data.weights[key]} onChange={e => setData({ ...data, weights: { ...data.weights, [key]: Number(e.target.value) } })} /></label>)}
   <p>가중치 합계: {Object.values(data.weights).reduce((a, b) => a + b, 0)} / 100</p>
   <button disabled={busy} type="submit">{busy ? '발행 중…' : '매칭 규칙 발행'}</button>
  </form>}
 </section>
}
