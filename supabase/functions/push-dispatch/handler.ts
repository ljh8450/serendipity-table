export type PushJob = { id: string; token: string; notificationId: string; subscription: { endpoint: string; keys: { p256dh: string; auth: string } } };
export function validEndpoint(endpoint: string): boolean {
  try {
    const u = new URL(endpoint);
    return u.protocol === 'https:' && !u.username && !u.password && !u.port && !u.hash
      && ['fcm.googleapis.com', 'updates.push.services.mozilla.com', 'web.push.apple.com'].includes(u.hostname);
  } catch { return false; }
}
export function createPushHandler(deps: { secret?: string; claim: () => Promise<PushJob | null>; send: (job: PushJob) => Promise<number>; finish: (job: PushJob, status: number) => Promise<void> }) {
  return async (req: Request): Promise<Response> => {
    const headers = { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' };
    const reply = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers });
    if (!deps.secret || deps.secret.length < 32) return reply(503, { error: 'NOT_CONFIGURED' });
    const supplied = req.headers.get('authorization') ?? '';
    const expected = `Bearer ${deps.secret}`;
    let diff = supplied.length ^ expected.length;
    for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ (supplied.charCodeAt(i) || 0);
    if (diff !== 0) return reply(401, { error: 'UNAUTHENTICATED' });
    if (req.method !== 'POST') return reply(405, { error: 'METHOD_NOT_ALLOWED' });
    // No caller-controlled recipients, payload or batch size.
    if (req.headers.get('content-type')?.split(';')[0] !== 'application/json') return reply(415, { error: 'UNSUPPORTED_MEDIA_TYPE' });
    const reader = req.body?.getReader();
    if (!reader) return reply(422, { error: 'VALIDATION_ERROR' });
    const chunks: number[] = [];
    while (true) { const { value, done } = await reader.read(); if (done) break; if (chunks.length + value.length > 64) { await reader.cancel(); return reply(413, { error: 'PAYLOAD_TOO_LARGE' }); } chunks.push(...value); }
    try { if (JSON.stringify(JSON.parse(new TextDecoder().decode(new Uint8Array(chunks)))) !== '{}') return reply(422, { error: 'VALIDATION_ERROR' }); }
    catch { return reply(422, { error: 'VALIDATION_ERROR' }); }
    let processed = 0;
    try {
      for (let i = 0; i < 5; i++) {
        const job = await deps.claim(); if (!job) break;
        let status = 400;
        if (validEndpoint(job.subscription.endpoint)) { try { status = await deps.send(job); } catch { status = 0; } }
        await deps.finish(job, status); processed++;
      }
      return reply(200, { processed });
    } catch { return reply(503, { error: 'SERVICE_UNAVAILABLE' }); }
  };
}
