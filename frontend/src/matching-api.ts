export type MatchApplication = {
  id: string; status: string; applicationStatus: string; paymentStatus: string; attendanceStatus: string; stored: boolean; canResolve: boolean; canCancel: boolean; canRefund: boolean; refundCutoffAt: string | null; resolutionReason: string | null; nextMatchAt: string | null; attentionRequired: boolean;
  table: { id: string; startsAt: string; regionLabel: string; count: number; venueStatus: string; deliveryStatus: string; chat?: { roomId: string; status: string } | null; venue?: { name: string; address: string; mapUrl: string; reservationName: string; mealPriceKrw: number } | null } | null;
  history: { reason: string; step: number; at: string }[];
  alternatives: { id: string; startsAt: string; regionLabel: string }[];
}
export type Matching = { applications: MatchApplication[] }
export type Monitor = {
  policy: { version: string; minimumScore: number; batchSize: number; beamWidth: number };
  jobs: { id: string; status: string; applicationStatus: string; paymentStatus: string; attendanceStatus: string; stored: boolean; canResolve: boolean; canCancel: boolean; canRefund: boolean; refundCutoffAt: string | null; resolutionReason: string | null; dueAt: string; attempts: number; lastError: string | null }[];
  runs: { id: string; policyVersion: string; allocated: number; candidates: number; elapsedMs: number; finishedAt: string }[];
  exceptions: { jobId: string; code: string; at: string }[]; pendingOutbox: number;
}
export async function matchingRequest<T>(token: string, path = '/matching', payload?: unknown): Promise<T> {
  const response = await fetch(`${import.meta.env.VITE_SUPABASE_URL}/functions/v1/member${path}`, {
    method: payload === undefined ? 'GET' : 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    signal: AbortSignal.timeout(10000), ...(payload === undefined ? {} : { body: JSON.stringify(payload) }),
  })
  const data = await response.json()
  if (!response.ok) throw new Error(data.error?.code ?? 'SERVICE_UNAVAILABLE')
  return data
}
