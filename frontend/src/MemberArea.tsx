import { lazy, Suspense, useEffect, useRef, useState } from 'react'
import type { FormEvent } from 'react'
import type { Session } from '@supabase/supabase-js'
import { createAuthClient, memberRequest } from './member-api'
import type { Member } from './member-api'
import PushSettings from './PushSettings'
import { disableDevicePush } from './push-api'
import NotificationCenter from './NotificationCenter'
import IntakeForms from './IntakeForms'
const PrivacyPanel = lazy(() => import('./PrivacyPanel'))
const OperationsArea = lazy(() => import('./OperationsArea'))
import SafetyPanel from './SafetyPanel'
import type { WithdrawalReceipt } from './PrivacyPanel'

export default function MemberArea() {
  const [auth] = useState(createAuthClient)
  const [session, setSession] = useState<Session | null>(null)
  const [member, setMember] = useState<Member | null>(null)
  const [initializing, setInitializing] = useState(true)
  const [mode, setMode] = useState<'login' | 'signup'>('login')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [withdrawReceipt, setWithdrawReceipt] = useState<WithdrawalReceipt | null>(null)
  const [attempt, setAttempt] = useState(0)
  const [providers, setProviders] = useState({ google: false, kakao: false })
  const identity = useRef<string | null>(null)
  useEffect(() => {
    if (!auth) return
    let active = true
    auth.auth.getSession().then(({ data, error }) => {
      if (!active) return
      setSession(data.session); setInitializing(false)
      if (error || new URLSearchParams(location.search).has('error')) setError('인증을 완료하지 못했어요. 다시 로그인해 주세요.')
      if (location.pathname === '/auth/callback') history.replaceState(null, '', '/')
    }).catch(() => { if (active) { setInitializing(false); setError('로그인 상태를 확인하지 못했어요.') } })
    const { data } = auth.auth.onAuthStateChange((_event, value) => {
      if (!active) return
      if (identity.current !== (value?.user.id ?? null)) { setMember(null); setNotice(''); identity.current = value?.user.id ?? null }
      if (value?.user.id) setWithdrawReceipt(null)
      setSession(value); setInitializing(false)
    })
    fetch(`${import.meta.env.VITE_SUPABASE_URL}/auth/v1/settings`, {
      headers: { apikey: import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY }, signal: AbortSignal.timeout(5000),
    }).then(async response => { if (!response.ok) throw new Error('Auth unavailable'); return response.json() })
      .then(value => { if (active) setProviders({ google: value.external?.google === true, kakao: value.external?.kakao === true }) })
      .catch(() => {})
    return () => { active = false; data.subscription.unsubscribe() }
  }, [auth])
  useEffect(() => {
    if (!session) return
    let active = true
    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), 8000)
    memberRequest(session.access_token, 'GET', undefined, '', controller.signal)
      .then(value => { if (active) { setMember(value); setError('') } })
      .catch(() => { if (active) setError('내 정보를 불러오지 못했어요. 다시 시도하거나 로그인해 주세요.') })
      .finally(() => clearTimeout(timeout))
    return () => { active = false; controller.abort(); clearTimeout(timeout) }
  }, [session, attempt])
  async function authenticate(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); if (!auth) return
    const data = new FormData(event.currentTarget)
    const email = String(data.get('email')).trim()
    const password = String(data.get('password'))
    if (mode === 'signup' && password !== data.get('confirmPassword')) { setError('비밀번호 확인이 일치하지 않아요.'); return }
    setBusy(true); setError(''); setNotice('')
    try {
      const result = mode === 'signup' ? await auth.auth.signUp({ email, password, options: { emailRedirectTo: `${location.origin}/auth/callback` } }) : await auth.auth.signInWithPassword({ email, password })
      if (result.error) throw result.error
      if (mode === 'signup' && !result.data.session) setNotice('이메일의 인증 링크를 확인해 주세요. 확인 후 로그인하면 기본정보를 입력할 수 있어요.')
    } catch { setError(mode === 'signup' ? '가입을 완료하지 못했어요. 입력 내용과 이메일 인증 설정을 확인해 주세요.' : '로그인하지 못했어요. 계정과 비밀번호를 확인해 주세요.') }
    finally { setBusy(false) }
  }
  if (!auth) return <section className="member-area"><h2>참가 준비</h2><p>로그인 연결을 준비하고 있어요. 공개 인증 설정을 확인해 주세요.</p></section>
  return <section className="member-area" aria-labelledby="member-title">
    <h2 id="member-title">{session ? '나의 참가 준비' : mode === 'signup' ? '회원가입' : '로그인'}</h2>
    {error && <div role="alert" className="member-error"><p>{error}</p>{session && <button className="secondary" onClick={() => setAttempt(v => v + 1)}>다시 불러오기</button>}</div>}
    {notice && <p aria-live="polite">{notice}</p>}
    {!session && withdrawReceipt && <div><p>접수 번호 {withdrawReceipt.receiptId} · 보관 기준 {withdrawReceipt.policyVersion} · 확인할 결제 신청 {withdrawReceipt.unresolvedFinancialApplications}건. 금융 권리 확인을 위해 접수 확인서를 보관해 주세요.</p><button className="secondary" onClick={() => { const url = URL.createObjectURL(new Blob([JSON.stringify(withdrawReceipt, null, 2)], { type: 'application/json' })); const link = document.createElement('a'); link.href = url; link.download = `dining-withdrawal-${withdrawReceipt.receiptId}.json`; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000) }}>탈퇴 접수 확인서 저장</button></div>}
    {initializing && <p>인증 상태를 확인하고 있어요.</p>}
    {!initializing && !session && <>
      <div className="intake-steps"><button type="button" className={mode === 'login' ? '' : 'secondary'} onClick={() => { setMode('login'); setError(''); setNotice('') }}>로그인 화면</button><button type="button" className={mode === 'signup' ? '' : 'secondary'} onClick={() => { setMode('signup'); setError(''); setNotice('') }}>회원가입 화면</button></div>
      <form onSubmit={authenticate} key={mode}>
        <p>{mode === 'signup' ? '이메일 인증 후 이름·연락처와 온보딩 정보를 입력해요.' : '이메일 또는 연결된 소셜 계정으로 로그인해 주세요. 테스트 계정도 사용할 수 있어요.'}</p>
        <label htmlFor="login-email">이메일</label><input id="login-email" name="email" type="email" autoComplete="username" required />
        <label htmlFor="login-password">비밀번호</label><input id="login-password" name="password" type="password" autoComplete={mode === 'signup' ? 'new-password' : 'current-password'} minLength={mode === 'signup' ? 8 : undefined} required />
        {mode === 'signup' && <><label htmlFor="confirm-password">비밀번호 확인</label><input id="confirm-password" name="confirmPassword" type="password" autoComplete="new-password" minLength={8} required /></>}
        <button disabled={busy}>{busy ? '인증 중…' : mode === 'signup' ? '이메일로 회원가입' : '로그인'}</button>
      </form>
      <div className="social-logins">{(['google','kakao'] as const).map(provider => <button type="button" key={provider} className="secondary" disabled={busy || !providers[provider]} onClick={async () => {
        setBusy(true); setError('')
        try { const { error } = await auth.auth.signInWithOAuth({ provider, options: { redirectTo: `${location.origin}/auth/callback` } }); if (error) throw error }
        catch { setError('소셜 인증을 시작하지 못했어요. 연결 설정을 확인해 주세요.') }
        finally { setBusy(false) }
      }}>{provider === 'google' ? 'Google' : '카카오'}로 계속하기{!providers[provider] ? ' (연결 준비 중)' : ''}</button>)}</div>
      {(!providers.google || !providers.kakao) && <p className="help">준비 중인 소셜 로그인은 OAuth 앱 연결이 완료되면 사용할 수 있어요.</p>}
    </>}
    {session && <>
      <SafetyPanel key={`safety-${session.user.id}`} token={session.access_token} />
      {member?.username && <p>아이디: {member.username}</p>}
      <button type="button" className="secondary" disabled={busy} onClick={async () => {
        setBusy(true)
        try { await disableDevicePush(session.access_token).catch(() => {}); const { error } = await auth.auth.signOut(); if (error) throw error; setMember(null); setError('') }
        catch { setError('로그아웃하지 못했어요. 다시 시도해 주세요.') }
        finally { setBusy(false) }
      }}>로그아웃</button>
      {member ? <><NotificationCenter key={`notifications-${member.userId}`} token={session.access_token} /><PushSettings key={`push-${member.userId}`} token={session.access_token} />{member.role === 'participant' && <Suspense fallback={<p>계정 관리 화면을 불러오고 있어요.</p>}><PrivacyPanel token={session.access_token} onWithdraw={async receipt => { await auth.auth.signOut({ scope: 'global' }).catch(() => {}); await auth.auth.signOut({ scope: 'local' }).catch(() => {}); setMember(null); setSession(null); setError(''); setWithdrawReceipt(receipt); setNotice('탈퇴를 처리했어요. 개인정보는 안내한 보관 기준에 따라 정리됩니다.') }} /></Suspense>}<IntakeForms key={member.userId} token={session.access_token} member={member} onMemberChange={setMember} />{member.role === 'operator' && <Suspense fallback={<p>운영 화면을 불러오고 있어요.</p>}><OperationsArea key={`operations-${member.userId}`} token={session.access_token} /></Suspense>}</> : !error && <p>내 정보를 불러오고 있어요.</p>}
    </>}
  </section>
}
