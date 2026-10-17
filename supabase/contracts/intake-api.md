# Form intake API

2026-10-16 · FORM-001/002, AUTH-003, PAY-003. Implementation is local until explicitly deployed. Existing member v1 endpoints remain available; the new UI writes the intake model without overwriting legacy profile JSON.

All routes are under `/functions/v1/member/intake`. Bearer authentication, ownership checks, account restrictions, exact-origin CORS, bounded JSON bodies and no-store follow member-api.md. Anonymous/Data API roles cannot invoke private DB functions. No client userId, role, amount, payment or matching status is accepted.

| Method/path | Body | Behavior |
|---|---|---|
| GET / | — | Own identity/onboarding/draft/history; current schema groups, open real event-slot combinations and products |
| PUT /identity | `{ schemaVersion, data: { name, contact } }` | Save required signup basic information |
| PUT /onboarding | `{ schemaVersion, data }` | Strict required Instagram/birthYear/gender/occupation/MBTI/interests/traits/preferredTraits/mealBudgetBands, optional avoidedFoods/allergies |
| PUT /draft | `{ input: { slotIds, regions, otherRegion, ticketCode }, sourceId }` | Save partial draft, validate IDs/shape, return opaque revision; identical input keeps revision |
| POST /reuse | `{ sourceId }` | Copy own source choices to new draft; clear event-slot selections, preserve original; never copy payment/matching/attendance/consent/request key |
| POST /submit | `{ requestKey, draftRevision }` | Lock actor/draft/member/events/documents/product; require current profile/schema, both current consent kinds, open selected slots within selected regions; snapshot data and product/consent versions |

Success returns the current intake DTO. History includes at most 20 recent own applications; user identity and onboarding snapshots are own-only. The UI offers explicit editing of a previous profile; saving it changes the current profile, never the original application snapshot.

Application axes start SUBMITTED / PENDING / WAITING / SCHEDULED. Submission is not payment or matching confirmation. Same request key and revision returns the existing result; a different revision conflicts. Same-user active overlap of exact slot IDs is rejected. Later matching must also enforce global user/confirmed-time conflicts.

Choices are stable IDs from the DB schema. Meal budgets are independent IDs, not the encompassing min/max range. Instagram is private. Original age input is not converted into an invented birth year: collect PRD birthYear and explicitly explain its use. Multiple date/region selections are real slot IDs, not an invented cross product. Other-region text records a preference and never creates an event or authorizes automatic relocation.

Products follow the user's confirmed single 8,000 KRW / prepaid three-use 15,000 KRW, validityMonths=2. No recurring subscription. Validity start/boundary and credit accounting belong to the payment unit. `use_three` is recorded in drafts but submission fails TICKET_UNAVAILABLE until a server credit ledger is integrated. No unverified entitlement or fake PAID status is granted.

Additional 409 codes: SCHEMA_CHANGED, PROFILE_REQUIRED, DRAFT_CHANGED, EVENT_CLOSED, TICKET_UNAVAILABLE, CONSENT_REQUIRED, DUPLICATE_APPLICATION, IDEMPOTENCY_CONFLICT. Domain validation is 422. Caller must display review/retry actions and keep unsaved inputs. Errors do not include SQL details or private records.

Email signup and sign-in use Supabase Auth. Google/Kakao use PKCE and `/auth/callback`; callback detection/exchange is handled by the SDK initialization, query parameters are removed after processing. The public Auth settings endpoint controls provider readiness; unconfigured buttons are disabled. Provider app client IDs/secrets and redirect allowlists must be configured before real OAuth verification. Local test accounts/consent/event fixtures never become operating data by migration.

Official integration references:
- https://supabase.com/docs/guides/auth/social-login/auth-google
- https://supabase.com/docs/guides/auth/social-login/auth-kakao
- https://supabase.com/docs/guides/auth/sessions/pkce-flow


## Requirement supersession: FAQ-001 (2026-10-16)

The product/three-use behavior above documents the deployed SQL004–009 contract, not the current target requirement. User-provided Blaybus Q&A supersedes PAY-003 with PAY-004–006; see [decisions](../../docs/context/decisions.md#faq-001-적용-결정-2026-10-16). No API, migration or deployment change was made in this documentation update. Future catalog/version and eligibility changes must preserve existing application snapshots, reject stale product choices explicitly and revalidate reused drafts. Unlimited membership is period eligibility, not a remaining-credit counter. Matching-failure extensions require an idempotent event ledger. Refund cutoff and matching deadline are separate server fields. Extension amount and refund/cancellation details remain project design decisions.
