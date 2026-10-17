import { useEffect, useState } from 'react'
import './App.css'
import MemberArea from './MemberArea'


export default function App() {
  const [attempt, setAttempt] = useState(0)
  const [state, setState] = useState<'loading' | 'ready' | 'error'>('loading')
  useEffect(() => {
    const controller = new AbortController()
    let active = true
    const timeout = setTimeout(() => controller.abort(), 8000)
    const apiBase = import.meta.env.VITE_SUPABASE_URL?.replace(/\/$/, '')
    const request = apiBase ? fetch(`${apiBase}/functions/v1/system-status`, { signal: controller.signal }) : Promise.reject(new Error('Missing Supabase URL'))
    request
      .then(async response => {
        if (!response.ok) throw new Error('API unavailable')
        const body: unknown = await response.json()
        if (!body || typeof body !== 'object' || !('status' in body) || body.status !== 'ready') {
          throw new Error('Invalid response')
        }
        if (active) setState('ready')
      })
      .catch(() => { if (active) setState('error') })
      .finally(() => clearTimeout(timeout))
    return () => { active = false; controller.abort(); clearTimeout(timeout) }
  }, [attempt])
  return <main>
    <p className="eyebrow">우연한식탁</p>
    <h1>함께하는 식사의 시작</h1>
    <p>새로운 사람들과 만나는 식탁을 준비하고 있어요.</p>
    <section aria-labelledby="status-title">
      <h2 id="status-title">서비스 연결 상태</h2>
      <p role="status" aria-live="polite">
        {state === 'loading' && '연결을 확인하고 있어요.'}
        {state === 'ready' && '서비스에 연결되었습니다.'}
        {state === 'error' && '연결하지 못했어요. 잠시 후 다시 시도해 주세요.'}
      </p>
      {state === 'error' && <button onClick={() => { setState('loading'); setAttempt(value => value + 1) }}>다시 시도</button>}
    </section>
    <MemberArea />
  </main>
}
