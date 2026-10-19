import { useEffect, useState } from 'react'
export type AuthRoute = 'welcome' | 'login' | 'signup' | 'find-id' | 'forgot-password' | 'reset-password'
export const authTitles: Record<AuthRoute, string> = { welcome: '새로운 식탁을 만나보세요', login: '로그인', signup: '회원가입', 'find-id': '아이디 찾기', 'forgot-password': '비밀번호 찾기', 'reset-password': '새 비밀번호 설정' }
const routes: AuthRoute[] = ['login', 'signup', 'find-id', 'forgot-password', 'reset-password']
export function useAuthRoute() {
  const read = (): AuthRoute => routes.find(route => location.pathname === `/${route}`) ?? (location.hash || location.pathname === '/admin' || location.pathname === '/auth/callback' ? 'login' : 'welcome')
  const [route, setRoute] = useState<AuthRoute>(read)
  useEffect(() => {
    const update = () => setRoute(read())
    window.addEventListener('popstate', update)
    return () => window.removeEventListener('popstate', update)
  }, [])
  const navigate = (next: AuthRoute, replace = false) => {
    history[replace ? 'replaceState' : 'pushState'](null, '', `${next === 'welcome' ? '/' : `/${next}`}${location.hash}`)
    setRoute(next)
  }
  return [route, navigate] as const
}
