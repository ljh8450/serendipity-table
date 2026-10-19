import { useEffect, useRef, useState } from 'react'
import type { FormEvent, MouseEvent } from 'react'
import type { createAuthClient } from './member-api'
import type { AuthRoute } from './useAuthRoute'

type Props = {
  auth: NonNullable<ReturnType<typeof createAuthClient>>
  route: AuthRoute
  navigate: (route: AuthRoute, replace?: boolean) => void
  providers: { google: boolean; kakao: boolean }
  email: string
  onEmailChange: (email: string) => void
  canReset: boolean
  onReset: () => Promise<void>
}
export default function AuthScreen({ auth, route, navigate, providers, email, onEmailChange, canReset, onReset }: Props) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [verificationEmail, setVerificationEmail] = useState('')
  const [mismatch, setMismatch] = useState(false)
  const errorRef = useRef<HTMLDivElement>(null)
  const confirmRef = useRef<HTMLInputElement>(null)
  useEffect(() => {
    document.getElementById('member-title')?.focus()
  }, [route])
  function fail(message: string) { setError(message); requestAnimationFrame(() => errorRef.current?.focus()) }
  function link(next: AuthRoute) {
    return (event: MouseEvent<HTMLAnchorElement>) => {
      if (event.button || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return
      event.preventDefault(); if (!busy) navigate(next)
    }
  }
  const loginLink = <a href={`/login${location.hash}`} onClick={link('login')}>로그인으로 돌아가기</a>
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); if (busy) return
    const data = new FormData(event.currentTarget)
    const password = String(data.get('password') ?? '')
    if (['signup', 'reset-password'].includes(route) && password !== data.get('confirmPassword')) {
      setMismatch(true); confirmRef.current?.focus(); return
    }
    setBusy(true); setError(''); setNotice(''); setMismatch(false)
    try {
      if (route === 'forgot-password') {
        const { error } = await auth.auth.resetPasswordForEmail(email.trim(), { redirectTo: `${location.origin}/auth/callback` })
        if (error) throw error
        setNotice('입력한 이메일로 가입된 계정이 있다면 재설정 메일을 보내드려요. 받은편지함과 스팸함을 확인해 주세요. 링크는 메일을 요청한 브라우저에서 열어 주세요.')
      } else if (route === 'reset-password') {
        if (!canReset) throw new Error('Recovery required')
        const { error } = await auth.auth.updateUser({ password })
        if (error) throw error
        await onReset()
      } else {
        window.sessionStorage.setItem('dining-auth-destination', location.hash.slice(1))
        const result = route === 'signup'
          ? await auth.auth.signUp({ email: email.trim(), password, options: { emailRedirectTo: `${location.origin}/auth/callback` } })
          : await auth.auth.signInWithPassword({ email: email.trim(), password })
        if (result.error) throw result.error
        if (route === 'signup' && !result.data.session) setVerificationEmail(email.trim())
      }
    } catch (cause) {
      const code = cause && typeof cause === 'object' && 'code' in cause ? cause.code : ''
      fail(code === 'email_not_confirmed' ? '이메일 인증이 필요해요. 가입할 때 받은 인증 메일을 확인해 주세요.'
        : code === 'over_email_send_rate_limit' || code === 'over_request_rate_limit' ? '요청이 많아요. 잠시 후 다시 시도해 주세요.'
        : route === 'login' ? '로그인하지 못했어요. 이메일·비밀번호와 인터넷 연결을 확인해 주세요.'
        : route === 'signup' ? '가입을 완료하지 못했어요. 입력 내용과 인터넷 연결을 확인한 뒤 다시 시도해 주세요.'
        : '요청을 완료하지 못했어요. 인터넷 연결을 확인하고, 인증 링크가 만료됐다면 재설정 메일을 다시 요청해 주세요.')
    } finally { setBusy(false) }
  }
  async function resend() {
    if (busy) return
    setBusy(true); setError(''); setNotice('')
    try {
      const { error } = await auth.auth.resend({ type: 'signup', email: verificationEmail, options: { emailRedirectTo: `${location.origin}/auth/callback` } })
      if (error) throw error
      setNotice('인증이 필요한 계정이라면 메일을 다시 보내드려요. 받은편지함과 스팸함을 확인해 주세요.')
    } catch { fail('인증 메일을 요청하지 못했어요. 잠시 후 다시 시도해 주세요.') }
    finally { setBusy(false) }
  }
  return <>
    {error && <div role="alert" tabIndex={-1} ref={errorRef} className="member-error">{error}</div>}
    {notice && <p role="status">{notice}</p>}
    {route === 'welcome' ? <><p>로그인하고 나에게 맞는 일정과 지역을 선택해 주세요.</p><a className="auth-primary" href="/login" onClick={link('login')}>로그인하기</a></>
      : route === 'find-id' ? <><p>이메일로 가입했다면 가입할 때 사용한 이메일이 로그인 아이디예요. 로그인 후 표시되는 별도 아이디로는 로그인할 수 없어요.</p><p>받은편지함에서 ‘우연한식탁’ 인증 메일을 검색해 가입 이메일을 확인해 주세요. 소셜 계정으로 가입했다면 같은 소셜 로그인으로 접속해 주세요.</p><p className="help">다른 사람의 계정 정보가 노출되지 않도록 이름·연락처로 이메일을 조회하는 기능은 제공하지 않아요.</p><nav className="auth-links" aria-label="계정 찾기">{loginLink}<a href="/forgot-password" onClick={link('forgot-password')}>비밀번호 찾기</a></nav></>
      : route === 'reset-password' && !canReset ? <><p>유효한 비밀번호 재설정 링크가 필요해요. 링크가 만료됐거나 다른 브라우저에서 열었다면 메일을 다시 요청해 주세요.</p><nav className="auth-links" aria-label="인증 안내"><a href="/forgot-password" onClick={link('forgot-password')}>재설정 메일 요청하기</a>{loginLink}</nav></>
      : route === 'signup' && verificationEmail ? <><p>{verificationEmail}로 가입 인증 메일을 요청했어요. 인증 링크를 확인한 후 로그인해 주세요. 링크는 가입을 진행한 브라우저에서 열어 주세요.</p><button type="button" className="secondary" disabled={busy} onClick={resend}>{busy ? '요청 중…' : '인증 메일 다시 받기'}</button><button type="button" className="secondary" disabled={busy} onClick={() => { setVerificationEmail(''); setNotice(''); setError('') }}>이메일 수정하기</button><nav className="auth-links" aria-label="가입 후 이동">{loginLink}</nav></>
      : <>
        <p>{route === 'signup' ? '이메일로 가입한 뒤 기본정보와 식사 선호를 입력해요.' : route === 'forgot-password' ? '가입한 이메일로 비밀번호 재설정 링크를 보내드려요.' : route === 'reset-password' ? '앞으로 사용할 새 비밀번호를 입력해 주세요.' : '가입한 이메일로 로그인해 주세요.'}</p>
        <form onSubmit={submit} key={route}>
          {route !== 'reset-password' && <><label htmlFor="login-email">이메일</label><input id="login-email" name="email" type="email" autoComplete="username" value={email} onChange={event => onEmailChange(event.target.value)} required /></>}
          {route !== 'forgot-password' && <><label htmlFor="login-password">{route === 'reset-password' ? '새 비밀번호' : '비밀번호'}</label><input id="login-password" name="password" type="password" autoComplete={route === 'login' ? 'current-password' : 'new-password'} minLength={route === 'login' ? undefined : 8} aria-describedby={route !== 'login' ? 'password-help' : undefined} required /></>}
          {['signup', 'reset-password'].includes(route) && <><p id="password-help" className="help">비밀번호는 8자 이상으로 입력해 주세요.</p><label htmlFor="confirm-password">비밀번호 확인</label><input ref={confirmRef} id="confirm-password" name="confirmPassword" type="password" autoComplete="new-password" minLength={8} aria-invalid={mismatch} aria-describedby={mismatch ? 'password-mismatch' : undefined} onChange={() => setMismatch(false)} required />{mismatch && <p id="password-mismatch" role="alert" className="field-error">비밀번호 확인이 일치하지 않아요.</p>}</>}
          <button disabled={busy}>{busy ? '처리 중…' : route === 'signup' ? '이메일로 회원가입' : route === 'forgot-password' ? '재설정 메일 받기' : route === 'reset-password' ? '비밀번호 변경' : '로그인'}</button>
        </form>
        {route === 'login' && <>
          <nav className="auth-links" aria-label="로그인 도움"><a href="/find-id" onClick={link('find-id')}>아이디 찾기</a><a href="/forgot-password" onClick={link('forgot-password')}>비밀번호 찾기</a></nav>
          {(providers.google || providers.kakao) && <div className="social-logins">{(['google','kakao'] as const).filter(provider => providers[provider]).map(provider => <button type="button" key={provider} className="secondary" disabled={busy} onClick={async () => {
            setBusy(true); setError('')
            window.sessionStorage.setItem('dining-auth-destination', location.hash.slice(1))
            try { const { error } = await auth.auth.signInWithOAuth({ provider, options: { redirectTo: `${location.origin}/auth/callback` } }); if (error) throw error }
            catch { fail('소셜 로그인을 시작하지 못했어요. 잠시 후 다시 시도해 주세요.') }
            finally { setBusy(false) }
          }}>{provider === 'google' ? 'Google' : '카카오'}로 계속하기</button>)}</div>}
          <p className="auth-links">처음 오셨나요? <a href="/signup" onClick={link('signup')}>회원가입</a></p>
        </>}
        {route !== 'login' && <nav className="auth-links" aria-label="인증 화면 이동">{loginLink}</nav>}
      </>}
  </>
}
