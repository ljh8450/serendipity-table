export type Option = { id: string; label: string }
export type Group = { key: string; label: string; multiple: boolean; options: Option[] }
export type Identity = { name: string; contact: string }
export type Onboarding = { instagram: string; birthYear: number | ''; gender: string; occupation: string; mbti: string[]; interests: string[]; traits: string[]; preferredTraits: string[]; mealBudgetBands: string[]; avoidedFoods: string; allergies: string }
export type ApplicationInput = { slotIds: string[]; regions: string[]; otherRegion: string; ticketCode: string }
export type Application = { id: string; submittedAt: string; input: ApplicationInput; identitySnapshot: Identity; onboardingSnapshot: Onboarding; applicationStatus: string; paymentStatus: string; matchingStatus: string; attendanceStatus: string; eligible: boolean; productSnapshot: { code: string; amountKrw: number; kind?: string; validityMonths: number | null } }
export type Intake = {
  schemaVersion: string; savedSchemaVersion: string | null; groups: Group[]; identity: Identity | null; onboarding: Onboarding | null;
  draft: { input: ApplicationInput; sourceId: string | null; revision: string } | null;
  slots: { id: string; startsAt: string; closesAt: string; regionCode: string; regionLabel: string; matchesAt: string | null; refundCutoffAt: string }[];
  products: { code: string; label: string; amountKrw: number; kind: string; validityMonths: number | null }[];
  memberships: { id: string; startsAt: string; endsAt: string; active: boolean; extensionDays: number }[];
  applications: Application[];
}
export async function intakeRequest(token: string, path = '', body?: unknown): Promise<Intake> {
  const response = await fetch(`${import.meta.env.VITE_SUPABASE_URL}/functions/v1/member/intake${path}`, {
    method: body === undefined ? 'GET' : ['/reuse','/submit','/payment','/refund'].includes(path) ? 'POST' : 'PUT',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    signal: AbortSignal.timeout(10000), ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })
  const data = await response.json()
  if (!response.ok) throw new Error(data.error?.code ?? 'SERVICE_UNAVAILABLE')
  if (!data || typeof data.schemaVersion !== 'string' || !Array.isArray(data.groups) || !Array.isArray(data.applications)) throw new Error('SERVICE_UNAVAILABLE')
  return data
}
