import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import App from './App'
const mocks = vi.hoisted(() => ({
  auth: { getSession: vi.fn(), onAuthStateChange: vi.fn(), signInWithPassword: vi.fn(), signUp: vi.fn(), resetPasswordForEmail: vi.fn(), updateUser: vi.fn(), signOut: vi.fn(), resend: vi.fn() },
  memberRequest: vi.fn(),
}))
vi.mock('./member-api', () => ({ createAuthClient: () => ({ auth: mocks.auth }), memberRequest: mocks.memberRequest }))
beforeEach(() => {
  history.replaceState(null, '', '/')
  sessionStorage.clear()
  vi.resetAllMocks()
  mocks.auth.getSession.mockResolvedValue({ data: { session: null } })
  mocks.auth.onAuthStateChange.mockReturnValue({ data: { subscription: { unsubscribe: vi.fn() } } })
  vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: true, json: async () => ({ external: {} }) }))
})
afterEach(() => { cleanup(); vi.unstubAllGlobals() })

test('home offers login without diagnostic UI or diagnostic request', async () => {
  render(<App />)
  fireEvent.click(await screen.findByRole('link', { name: '로그인하기' }))
  expect(location.pathname).toBe('/login')
  expect(await screen.findByLabelText('이메일')).toBeVisible()
  expect(screen.queryByText('서비스 연결 상태')).not.toBeInTheDocument()
  expect(vi.mocked(fetch).mock.calls.some(([url]) => String(url).includes('system-status'))).toBe(false)
})

test('signup and help links preserve email and popstate returns to login', async () => {
  history.replaceState(null, '', '/login')
  render(<App />)
  fireEvent.change(await screen.findByLabelText('이메일'), { target: { value: 'person@example.test' } })
  fireEvent.click(screen.getByRole('link', { name: '회원가입' }))
  expect(location.pathname).toBe('/signup')
  expect(screen.getByLabelText('이메일')).toHaveValue('person@example.test')
  history.replaceState(null, '', '/login'); fireEvent.popState(window)
  expect(await screen.findByRole('heading', { name: '로그인' })).toHaveFocus()
  fireEvent.click(screen.getByRole('link', { name: '아이디 찾기' }))
  expect(screen.getByText(/가입할 때 사용한 이메일이 로그인 아이디/)).toBeVisible()
  fireEvent.click(screen.getByRole('link', { name: '비밀번호 찾기' }))
  expect(screen.getByLabelText('이메일')).toHaveValue('person@example.test')
})

test('signup mismatch focuses field and sends no signup request', async () => {
  history.replaceState(null, '', '/signup'); render(<App />)
  fireEvent.change(await screen.findByLabelText('이메일'), { target: { value: 'person@example.test' } })
  fireEvent.change(screen.getByLabelText('비밀번호', { exact: true }), { target: { value: 'Password1!' } })
  fireEvent.change(screen.getByLabelText('비밀번호 확인'), { target: { value: 'Different1!' } })
  fireEvent.click(screen.getByRole('button', { name: '이메일로 회원가입' }))
  expect(screen.getByLabelText('비밀번호 확인')).toHaveFocus()
  expect(screen.getByLabelText('비밀번호 확인')).toHaveAttribute('aria-invalid', 'true')
  expect(mocks.auth.signUp).not.toHaveBeenCalled()
})

test('signup without session offers resend and email correction', async () => {
  mocks.auth.signUp.mockResolvedValue({ data: { session: null }, error: null })
  mocks.auth.resend.mockResolvedValue({ error: null })
  history.replaceState(null, '', '/signup'); render(<App />)
  fireEvent.change(await screen.findByLabelText('이메일'), { target: { value: 'person@example.test' } })
  fireEvent.change(screen.getByLabelText('비밀번호', { exact: true }), { target: { value: 'Password1!' } })
  fireEvent.change(screen.getByLabelText('비밀번호 확인'), { target: { value: 'Password1!' } })
  fireEvent.click(screen.getByRole('button', { name: '이메일로 회원가입' }))
  fireEvent.click(await screen.findByRole('button', { name: '인증 메일 다시 받기' }))
  await waitFor(() => expect(mocks.auth.resend).toHaveBeenCalledWith(expect.objectContaining({ type: 'signup', email: 'person@example.test' })))
  fireEvent.click(await screen.findByRole('button', { name: '이메일 수정하기' }))
  expect(screen.getByLabelText('이메일')).toHaveValue('person@example.test')
})

test('password recovery uses email API and does not reveal account existence', async () => {
  mocks.auth.resetPasswordForEmail.mockResolvedValue({ error: null })
  history.replaceState(null, '', '/forgot-password'); render(<App />)
  fireEvent.change(await screen.findByLabelText('이메일'), { target: { value: 'person@example.test' } })
  fireEvent.click(screen.getByRole('button', { name: '재설정 메일 받기' }))
  expect(await screen.findByRole('status')).toHaveTextContent('가입된 계정이 있다면')
  expect(mocks.auth.resetPasswordForEmail).toHaveBeenCalledWith('person@example.test', { redirectTo: `${location.origin}/auth/callback` })
})

test('recovery event opens password form, saves and signs out before login', async () => {
  let callback: (event: string, session: unknown) => void = () => {}
  mocks.auth.onAuthStateChange.mockImplementation(cb => { callback = cb; return { data: { subscription: { unsubscribe: vi.fn() } } } })
  mocks.auth.updateUser.mockResolvedValue({ error: null }); mocks.auth.signOut.mockResolvedValue({ error: null })
  mocks.memberRequest.mockReturnValue(new Promise(() => {}))
  render(<App />); await screen.findByRole('link', { name: '로그인하기' })
  const { act } = await import('@testing-library/react')
  act(() => callback('PASSWORD_RECOVERY', { access_token: 'local-test-token', user: { id: 'local-user' } }))
  fireEvent.change(await screen.findByLabelText('새 비밀번호'), { target: { value: 'NewPassword1!' } })
  fireEvent.change(screen.getByLabelText('비밀번호 확인'), { target: { value: 'NewPassword1!' } })
  fireEvent.click(screen.getByRole('button', { name: '비밀번호 변경' }))
  await waitFor(() => expect(location.pathname).toBe('/login'))
  expect(mocks.auth.updateUser).toHaveBeenCalledWith({ password: 'NewPassword1!' })
  expect(mocks.auth.signOut).toHaveBeenCalled()
  expect(await screen.findByText('비밀번호를 변경했어요. 새 비밀번호로 로그인해 주세요.')).toBeVisible()
})


test('login submits the preserved email and current password', async () => {
  mocks.auth.signInWithPassword.mockResolvedValue({ data: { session: null }, error: null })
  history.replaceState(null, '', '/login'); render(<App />)
  fireEvent.change(await screen.findByLabelText('이메일'), { target: { value: 'person@example.test' } })
  fireEvent.change(screen.getByLabelText('비밀번호'), { target: { value: 'CurrentPassword1!' } })
  fireEvent.click(screen.getByRole('button', { name: '로그인' }))
  await waitFor(() => expect(mocks.auth.signInWithPassword).toHaveBeenCalledWith({ email: 'person@example.test', password: 'CurrentPassword1!' }))
})


test('leaving recovery signs out its local session without changing a password', async () => {
  let callback: (event: string, session: unknown) => void = () => {}
  mocks.auth.onAuthStateChange.mockImplementation(cb => { callback = cb; return { data: { subscription: { unsubscribe: vi.fn() } } } })
  mocks.auth.signOut.mockResolvedValue({ error: null })
  mocks.memberRequest.mockReturnValue(new Promise(() => {}))
  render(<App />); await screen.findByRole('link', { name: '로그인하기' })
  const { act } = await import('@testing-library/react')
  act(() => callback('PASSWORD_RECOVERY', { access_token: 'local-test-token', user: { id: 'local-user' } }))
  fireEvent.click(await screen.findByRole('link', { name: '로그인으로 돌아가기' }))
  await waitFor(() => expect(location.pathname).toBe('/login'))
  expect(mocks.auth.signOut).toHaveBeenCalledWith({ scope: 'local' })
  expect(mocks.auth.updateUser).not.toHaveBeenCalled()
  expect(screen.getByRole('button', { name: '로그인' })).toBeVisible()
})
