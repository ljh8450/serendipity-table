import { useEffect, useId, useState } from 'react'
import { disableDevicePush, pushRequest } from './push-api'
type Config = { publicKey: string | null; activeDevices: number }
async function bounded<T>(promise: Promise<T>): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined
  try { return await Promise.race([promise, new Promise<never>((_resolve, reject) => { timer = setTimeout(() => reject(new Error('PUSH_TIMEOUT')), 30000) })]) }
  finally { clearTimeout(timer) }
}
export default function PushSettings({ token }: { token: string }) {
  const id = useId()
  const supported = 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window && window.isSecureContext
  const [config, setConfig] = useState<Config | null>(null)
  const [enabled, setEnabled] = useState(false)
  const [permission, setPermission] = useState(supported ? Notification.permission : 'denied')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [attempt, setAttempt] = useState(0)
  useEffect(() => {
    let active = true
    pushRequest<Config>(token).then(async value => {
      const registration = supported ? await navigator.serviceWorker.getRegistration('/') : undefined
      const subscription = await registration?.pushManager?.getSubscription()
      if (active) { setConfig(value); setEnabled(!!subscription); setError('') }
    }).catch(() => { if (active) setError('푸시 설정을 불러오지 못했어요. 다시 시도해 주세요.') })
    return () => { active = false }
  }, [token, attempt, supported])
  async function subscribe() {
    if (!config?.publicKey) return
    setBusy(true); setError(''); setNotice('')
    try {
      // Permission starts directly from this explicit click, before other async work.
      const result = await Notification.requestPermission(); setPermission(result)
      if (result !== 'granted') { setNotice('푸시를 허용하지 않았어요. 앱 내 알림은 계속 확인할 수 있어요.'); return }
      await navigator.serviceWorker.register('/sw.js', { scope: '/' })
      const registration = await bounded(navigator.serviceWorker.ready)
      const bytes = Uint8Array.from(atob(config.publicKey.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0))
      const subscription = await registration.pushManager.getSubscription() ?? await bounded(registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: bytes }))
      await pushRequest(token, 'subscribe', { subscription: subscription.toJSON() })
      setEnabled(true); setNotice('이 기기의 푸시 구독을 저장했어요. 수신 확인으로 실제 도착 여부를 확인해 주세요.')
    } catch (cause) { setError(cause instanceof Error && cause.message === 'PUSH_DEVICE_LIMIT' ? '이미 10개 기기에서 푸시를 사용하고 있어요. 기존 기기에서 푸시를 끈 뒤 다시 시도해 주세요.' : '구독을 저장하지 못했어요. 브라우저 알림 권한과 연결을 확인한 뒤 다시 시도해 주세요.') }
    finally { setBusy(false) }
  }
  return <section className="intake-section" aria-labelledby={id}>
    <h3 id={id}>이 기기 푸시 알림</h3>
    <p>앱을 닫아도 새 안내를 받을 수 있어요. 잠금 화면에는 일반 안내만 표시해요.</p>
    {!supported && <p>이 브라우저에서는 푸시를 사용할 수 없어요. 앱 내 알림을 확인해 주세요. iPhone에서는 홈 화면에 추가한 웹앱에서 다시 확인해 주세요.</p>}
    {supported && permission === 'denied' && <p>브라우저에서 알림이 차단돼 있어요. 사이트 알림 권한을 변경한 후 다시 확인해 주세요.</p>}
    {!config && !error && <p role="status">푸시 설정을 확인하고 있어요.</p>}
    {config && !config.publicKey && <p>푸시 연결을 준비하고 있어요. 앱 내 알림은 사용할 수 있어요.</p>}
    {supported && config?.publicKey && <>
      <p>{enabled ? '이 브라우저에 구독이 있어요. 계정에 다시 연결하려면 푸시 켜기를 눌러 주세요.' : '이 기기의 푸시가 꺼져 있어요.'}</p>
      <button disabled={busy || permission === 'denied'} onClick={subscribe}>이 기기 푸시 켜기</button>
      {enabled && <><button className="secondary" disabled={busy} onClick={async () => {
        setBusy(true); setError(''); setNotice('')
        try { await disableDevicePush(token); setEnabled(false); setNotice('이 기기의 푸시를 해제했어요.') }
        catch { setError('해제를 확인하지 못했어요. 연결을 확인하고 다시 시도해 주세요.') }
        finally { setBusy(false) }
      }}>이 기기 푸시 끄기</button><button className="secondary" disabled={busy} onClick={async () => {
        setBusy(true); setError(''); setNotice('')
        try { await pushRequest(token, 'test', {}); setNotice('수신 확인을 예약했어요. 1분 내 발송을 시도하며, 예약 성공이 실제 도착을 뜻하지는 않아요.') }
        catch { setError('수신 확인을 예약하지 못했어요. 구독을 다시 연결하거나 1분 후 재시도해 주세요.') }
        finally { setBusy(false) }
      }}>푸시 수신 확인</button></>}
    </>}
    <button className="secondary" disabled={busy} onClick={() => { if (supported) setPermission(Notification.permission); setAttempt(v => v + 1) }}>푸시 설정 다시 확인</button>
    {error && <p role="alert">{error}</p>}{notice && <p role="status">{notice}</p>}
  </section>
}
