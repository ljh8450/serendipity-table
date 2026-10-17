# Web Push commands

All member routes require verified Supabase Auth and existing CORS rules. Subscription addresses/keys are private and are never returned in DTOs.

- GET `/member/push`: `{publicKey:string|null,activeDevices:number}`.
- POST `/member/push/subscribe`: `{subscription:{endpoint,keys:{p256dh,auth},expirationTime?}}`; explicit browser subscription only, at most10 active devices/account, unique endpoint owner. Returns `{subscribed:true}`.
- POST `/member/push/unsubscribe`: `{endpoint}`; idempotent current actor deactivation and queued/running job cancellation. Returns `{subscribed:false}`. Other accounts' rows are unaffected.
- POST `/member/push/test`: `{}`; queues a real self notification, requires active subscription, at most1/min. Returns `{notificationId,queued:true}`. Queued does not imply delivered.
- GET `/member/operations/push`: operator-only `{counts,exceptions:[{jobId,code,attempts}]}`; max50 exceptions.
- POST `/member/operations/push/retry`: operator-only `{jobId}`; resets EXCEPTION only; current validity is checked again by worker.

Invalid payload422, foreign subscription403, unavailable setup/missing subscription/device limit409, test rate429/Retry-After60. Member API cannot invoke dispatcher DB commands or read subscription tables.

Internal POST `/push-dispatch` accepts only64byte-or-smaller empty JSON object and exact private bearer. No CORS access, caller-specified recipients/payload, or user JWT bypass. Missing key/token config503, invalid bearer401. Returns processed count only. VAPID private key and token stay in Edge environment; Cron URL/token stay in Vault. Production provisioning must install matching public key in private push_config and server environment and verify dispatcher secret/URL before claiming push delivery.

Provider acceptance, actual service worker receipt and OS notification display are separate. Retries are at least once with2minute lease/3attempt cap; tag/topic suppress duplicates. Expired404/410 subscriptions are disabled; permanent errors require operator action. A race after claim may send generic notice after cancellation; no private message text is sent.
