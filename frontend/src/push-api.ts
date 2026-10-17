export async function pushRequest<T>(token: string, action = '', body?: unknown): Promise<T> {
  const response = await fetch(`${import.meta.env.VITE_SUPABASE_URL}/functions/v1/member/push${action ? `/${action}` : ''}`, {
    method: body === undefined ? 'GET' : 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    signal: AbortSignal.timeout(8000), ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })
  const data = await response.json()
  if (!response.ok) throw new Error(data.error?.code ?? 'SERVICE_UNAVAILABLE')
  return data
}
export async function disableDevicePush(token: string) {
  if (!('serviceWorker' in navigator)) return
  const registration = await navigator.serviceWorker.getRegistration('/')
  const subscription = await registration?.pushManager?.getSubscription()
  if (!subscription) return
  // Stop the server first. On failure retain the browser subscription so retry is possible.
  await pushRequest(token, 'unsubscribe', { endpoint: subscription.endpoint })
  await subscription.unsubscribe()
}
