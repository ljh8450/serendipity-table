import { lazy, Suspense, useEffect, useRef, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { createAuthClient, memberRequest } from './member-api'
import type { Member } from './member-api'
import PushSettings from './PushSettings'
import { disableDevicePush } from './push-api'
import NotificationCenter from './NotificationCenter'
import IntakeForms from './IntakeForms'
import ChatPage from './ChatPage'
import FeedbackPanel from './FeedbackPanel'
import PersonPreferences from './PersonPreferences'
import { PageNav } from './PageNav'
import { usePage } from './usePage'
const PrivacyPanel = lazy(() => import('./PrivacyPanel'))
const OperationsArea = lazy(() => import('./OperationsArea'))
import SafetyPanel from './SafetyPanel'
import type { WithdrawalReceipt } from './PrivacyPanel'
import AuthScreen from './AuthScreen'
import { authTitles, useAuthRoute } from './useAuthRoute'

export default function MemberArea() {
  const [page, navigate] = usePage(['apply', 'table', 'chat', 'history', 'notifications', 'account', 'operations'], 'apply')
  const [auth] = useState(createAuthClient)
  const [session, setSession] = useState<Session | null>(null)
  const [member, setMember] = useState<Member | null>(null)
  const [initializing, setInitializing] = useState(true)
  const [authRoute, navigateAuth] = useAuthRoute()
  const [authEmail, setAuthEmail] = useState('')
  const [recovery, setRecovery] = useState(false)
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
      if (location.pathname === '/auth/callback') {
        const destination = window.sessionStorage.getItem('dining-auth-destination') ?? ''
        window.sessionStorage.removeItem('dining-auth-destination')
        history.replaceState(null, '', `/${['apply','table','chat','history','notifications','account','operations'].includes(destination) ? `#${destination}` : ''}`)
        window.dispatchEvent(new HashChangeEvent('hashchange'))
      }
    }).catch(() => { if (active) { setInitializing(false); setError('로그인 상태를 확인하지 못했어요.') } })
    const { data } = auth.auth.onAuthStateChange((event, value) => {
      if (!active) return
      if (event === 'SIGNED_IN' && ['/login', '/signup'].includes(location.pathname)) {
        history.replaceState(null, '', `/${location.hash}`)
        window.dispatchEvent(new PopStateEvent('popstate'))
      }
      if (event === 'PASSWORD_RECOVERY') {
        setRecovery(true)
        history.replaceState(null, '', '/reset-password')
        window.dispatchEvent(new PopStateEvent('popstate'))
      }
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
  if (!auth) return <section className="member-area"><h2>참가 준비</h2><p>로그인 연결을 준비하고 있어요. 공개 인증 설정을 확인해 주세요.</p></section>
  return <section className="member-area" data-layout={session && authRoute !== 'reset-password' && !recovery ? 'workspace' : 'auth'} aria-labelledby="member-title">
    <h2 id="member-title" tabIndex={-1}>{recovery || authRoute === 'reset-password' ? authTitles['reset-password'] : session ? member?.role === 'operator' ? '운영자 공간' : ({ apply: '식탁 신청', table: '내 식탁', chat: '채팅', history: '참가 이력', notifications: '알림', account: '계정 관리' } as Record<string,string>)[page] ?? '참가자 공간' : authTitles[authRoute]}</h2>
    {error && <div role="alert" className="member-error"><p>{error}</p>{session && <button className="secondary" onClick={() => setAttempt(v => v + 1)}>다시 불러오기</button>}</div>}
    {notice && <p aria-live="polite">{notice}</p>}
    {!session && withdrawReceipt && <div><p>접수 번호 {withdrawReceipt.receiptId} · 보관 기준 {withdrawReceipt.policyVersion} · 확인할 결제 신청 {withdrawReceipt.unresolvedFinancialApplications}건. 금융 권리 확인을 위해 접수 확인서를 보관해 주세요.</p><button className="secondary" onClick={() => { const url = URL.createObjectURL(new Blob([JSON.stringify(withdrawReceipt, null, 2)], { type: 'application/json' })); const link = document.createElement('a'); link.href = url; link.download = `dining-withdrawal-${withdrawReceipt.receiptId}.json`; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000) }}>탈퇴 접수 확인서 저장</button></div>}
    {initializing && <p>인증 상태를 확인하고 있어요.</p>}
    {!initializing && (!session || authRoute === 'reset-password' || recovery) && <AuthScreen key={recovery ? 'reset-password' : authRoute} email={authEmail} onEmailChange={setAuthEmail} auth={auth} route={recovery ? 'reset-password' : authRoute} navigate={async (route, replace) => {
      setError('')
      if (recovery && route !== 'reset-password') {
        try {
          const { error } = await auth.auth.signOut({ scope: 'local' })
          if (error) throw error
          setRecovery(false); setMember(null); setSession(null)
        } catch { setError('인증 화면으로 돌아가지 못했어요. 다시 시도해 주세요.'); return }
      }
      navigateAuth(route, replace)
    }} providers={providers} canReset={Boolean(session) && (recovery || authRoute === 'reset-password')} onReset={async () => {
      const { error } = await auth.auth.signOut()
      if (error) throw error
      setRecovery(false); setMember(null); setSession(null)
      setNotice('비밀번호를 변경했어요. 새 비밀번호로 로그인해 주세요.')
      navigateAuth('login', true)
    }} />}
    {session && authRoute !== 'reset-password' && !recovery && <>

      {member?.username && <p>아이디: {member.username}</p>}
      <button type="button" className="secondary" disabled={busy} onClick={async () => {
        setBusy(true)
        try { await disableDevicePush(session.access_token).catch(() => {}); const { error } = await auth.auth.signOut(); if (error) throw error; setMember(null); setError(''); navigateAuth('login', true) }
        catch { setError('로그아웃하지 못했어요. 다시 시도해 주세요.') }
        finally { setBusy(false) }
      }}>로그아웃</button>
      {member ? <>
        <PageNav current={member.role === 'operator' && !['account','notifications'].includes(page) ? 'operations' : page} onNavigate={navigate} items={member.role === 'operator' ? [['operations','운영 관리'],['notifications','알림'],['account','계정']] : [['apply','식탁 신청'],['table','내 식탁'],['chat','채팅'],['history','참가 이력'],['notifications','알림'],['account','계정']]} />
        {member.role === 'participant' && page === 'chat' && <ChatPage token={session.access_token} />}
        {member.role === 'participant' && <IntakeForms key={member.userId} token={session.access_token} member={member} onMemberChange={setMember} view={page === 'table' ? 'table' : 'apply'} visible={page === 'apply' || page === 'table'} onNavigate={navigate} />}
        {member.role === 'participant' && page === 'history' && <><p>지난 식탁의 평가와 비공개 사람 선택을 확인해 주세요. 다음 일정은 상단 식탁 신청에서 선택할 수 있어요.</p><FeedbackPanel token={session.access_token} /><PersonPreferences token={session.access_token} /><a className="next-action" href="#apply">다음 식탁 신청하기</a></>}
        {page === 'notifications' && <><NotificationCenter token={session.access_token} operator={member.role === 'operator'} /><PushSettings token={session.access_token} /></>}
        {page === 'account' && <><SafetyPanel token={session.access_token} />{member.role === 'participant' && <Suspense fallback={<p>계정 관리 화면을 불러오고 있어요.</p>}><PrivacyPanel token={session.access_token} onWithdraw={async receipt => { await auth.auth.signOut({ scope: 'global' }).catch(() => {}); await auth.auth.signOut({ scope: 'local' }).catch(() => {}); setMember(null); setSession(null); setError(''); setWithdrawReceipt(receipt); setNotice('탈퇴를 처리했어요. 개인정보는 안내한 보관 기준에 따라 정리됩니다.') }} /></Suspense>}</>}
        {member.role === 'operator' && !['notifications','account'].includes(page) && <Suspense fallback={<p>운영 화면을 불러오고 있어요.</p>}><OperationsArea token={session.access_token} /></Suspense>}
        {member.role === 'participant' && page === 'operations' && <p>운영 화면은 운영자 계정에서 사용할 수 있어요. 상단에서 식탁 신청을 선택해 주세요.</p>}
      </> : !error && <p>내 정보를 불러오고 있어요.</p>}
    </>}
  </section>
}
