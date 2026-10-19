# Return recommendations (RET-003)

GET /member/return-recommendations returns an authenticated caller-only, no-store DTO:

```
{status: AVAILABLE|NO_HISTORY|NO_OPEN_SLOTS|RESTRICTED,
 items: [{id, startsAt, closesAt, regionCode, regionLabel,
          reason: POSITIVE_EXPERIENCE|PREVIOUS_REGION, datePreference: boolean}]}
```

At most five published, currently open, future slots in the regions explicitly selected in the caller's latest currently valid, ended ATTENDED application. Current feedback eligibility excludes corrected no-shows, canceled/invalidated assignments and unpaid applications. SQL050 first ranks matching KST weekday/hour from the caller's previously explicitly selected slots, then own positive region feedback, then startsAt/id. The boolean datePreference explains this ordering. Region filters and explicit selection are unchanged. Other participants' ratings, person preferences, reports and identities are never queried for ranking or returned. No predictions about matching quality, peer availability or acceptance.

Exclude submitted duplicate slot selections, any active assignment overlap using the current matching duration, and safety restrictions. Read under matching/attendance locks. No persistent recommendation state, queue, external notification, application/payment mutation or new Cron.

Query parameters (including actor/time), all command methods and public ticks are rejected. 401 unauthenticated, 422 query, 405 method, 403 invalid actor/CORS. No anon/authenticated database RPC grant; only trusted app_member_api executes after actor validation.

React selection explicitly replaces draft-local dates/regions after refreshing the current intake catalog, opens the normal application form and focuses its heading. It does not save a draft, submit, charge or bypass onboarding/consents/server rules. Unpublication after reading is rechecked on selection and by existing submission validation. Dates display in Asia/Seoul; timestamps remain UTC.

SQL041/member/Vercel were deployed on 2026-10-17. Remote rollback SQL and production mobile/API permission smoke passed. With no operating events published, personalized live event suggestions/selection remain supported by local SQL/mobile evidence rather than a real production event. Permission provisioning remains separate.

2026-10-18 SQL050 date preference addition is locally applied/tested, not yet deployed; prior SQL041 deployment record remains historical.
