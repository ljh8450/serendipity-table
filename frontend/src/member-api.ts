import { createClient } from '@supabase/supabase-js'

export type Profile = {
  name: string; contact: string; birthYear: number; gender: string; occupation: string;
  mbti: string[]; interests: string[]; traits: string[]; preferredTraits: string[];
  mealBudgetMin: number; mealBudgetMax: number; avoidedFoods: string[]; allergies: string[];
}
export type ConsentDocument = { id: string; kind: 'privacy' | 'operations'; version: string; title: string; body: string; required: boolean }
export type Member = { userId: string; username?: string | null; displayName?: string | null; role: 'participant' | 'operator'; profile: Profile | null; consentDocuments: ConsentDocument[]; acceptedConsents: { id: string; version: string }[] }
let cachedAuth: ReturnType<typeof createClient> | null = null
let cachedConfig = ''
export function createAuthClient() {
  const url = import.meta.env.VITE_SUPABASE_URL
  const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY
  if (!url || !key) return null
  if (cachedAuth && cachedConfig === `${url}|${key}`) return cachedAuth
  cachedConfig = `${url}|${key}`
  cachedAuth = createClient(url, key, { auth: {
    storage: window.sessionStorage, persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, flowType: 'pkce',
  } })
  return cachedAuth
}
export async function memberRequest(token: string, method = 'GET', body?: unknown, path = '', signal?: AbortSignal): Promise<Member> {
  const response = await fetch(`${import.meta.env.VITE_SUPABASE_URL}/functions/v1/member${path}`, {
    method, signal: signal ?? AbortSignal.timeout(8000), headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })
  const result = await response.json()
  if (!response.ok) throw new Error(result.error?.code ?? 'SERVICE_UNAVAILABLE')
  if (!result || typeof result.userId !== 'string' || !Array.isArray(result.consentDocuments) || !Array.isArray(result.acceptedConsents)) throw new Error('SERVICE_UNAVAILABLE')
  return result
}
