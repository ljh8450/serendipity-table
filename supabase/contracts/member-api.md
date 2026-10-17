# Member API v1

Status: contract for ACC-01~05 implementation, 2026-10-16. Application/payment/matching endpoints are not implemented by this contract.

## Transport and authentication

`/functions/v1/member` accepts GET (current member) and PUT (replace own profile). `/functions/v1/member/consents` accepts POST. OPTIONS is unauthenticated and performs origin checks. All other requests require `Authorization: Bearer <access_token>`. The Edge verifies the token with Supabase Auth `/auth/v1/user`; decoding claims alone is insufficient. User IDs and roles never come from request bodies. No authentication cookies are accepted. CORS is an exact origin allowlist, with no credentials header. All responses use no-store. Tokens and profile bodies are not logged.

The frontend supports Supabase Auth email/password signup and sign-in, automatic refresh and sign-out, plus Google/Kakao PKCE integration where provider configuration is enabled (AUTH-003). Administrator selection is never exposed. Session tokens live in browser sessionStorage (still subject to XSS, not an authorization source). Server role and account restrictions are read from private DB tables on every command. Supabase access tokens can remain valid until expiry after sign-out; immediate account restrictions are checked in the domain DB. New staged intake/application contracts are in intake-api.md; the v1 profile DTO below remains backwards compatible.

## Own profile

GET returns `{ userId, role, profile, consentDocuments, acceptedConsents }`. Role is participant or operator. Missing profile is null. Profile DTO contains only the following fields; no internal records are serialized:

`name`, `contact`, `birthYear`, `gender`, `occupation`, `mbti` (array), `interests` (array), `traits` (array), `preferredTraits` (array), `mealBudgetMin`, `mealBudgetMax` (integer KRW), `avoidedFoods` (array), `allergies` (array).

PUT accepts exactly those fields, with no userId/role/status. Basic text is required and bounded; birthYear storage is 1900 through the current Asia/Seoul calendar year, not a new age eligibility policy. Arrays are bounded strings (not invented official taxonomies); MBTI uses valid four-letter types. Meal bounds are nonnegative and ordered. Text/array limits are technical storage guards, not product policy. Blank optional arrays are allowed. Consent is a separate command. Profile changes never grant application eligibility by themselves.

Consent documents have `id`, `version`, `kind` (privacy/operations), `title`, `body`, `required`. POST body is `{ documents: [{ id, version }] }`, accepting published current required versions only. Duplicate acceptance is idempotent. Publication of real policy text is an operator-controlled data operation, not performed by the migration. Local demonstration documents must be explicitly marked as demo and must not be deployed as real policies. An empty catalogue means consent is unavailable, not implicitly granted. C must enforce both required kinds and current versions in its transaction.

## Errors

`{ error: { code, fields? } }`. Codes: UNAUTHENTICATED (401), FORBIDDEN (403), VALIDATION_ERROR (422), CONSENT_CHANGED (409), SERVICE_UNAVAILABLE (503), METHOD_NOT_ALLOWED (405), NOT_FOUND (404), PAYLOAD_TOO_LARGE (413), UNSUPPORTED_MEDIA_TYPE (415). Never return SQL errors, tokens, private records or account lookup details. fields maps input names to stable validation codes. Successful writes return the current own-member DTO (200).

## DB boundary and migration order

Keep 20261016000100 unchanged. New migrations add private member roles/restrictions, profile, versioned consent and audit. Edge uses a NOLOGIN command role with EXECUTE only, no table privileges, inside a transaction with a locally set verified actor ID. Functions use fixed search_path and explicit actor/account checks. Anonymous/authenticated Data API users cannot invoke them. Data API remains unnecessary for this API.

Application/state contracts follow in C: separate application/payment/matching/attendance axes; profile snapshot; selected real event-slot combinations; user+request key uniqueness and content conflict detection. No submit/payment/confirmation transition exists in B. UTC is used for stored instants; display/policy time is Asia/Seoul. Unconfirmed payment/matching policies remain in decisions.md.

Sources: PRD p4 ACC-01~05; ARCH-008; https://supabase.com/docs/reference/javascript/auth-getuser ; https://supabase.com/docs/guides/functions/auth .
