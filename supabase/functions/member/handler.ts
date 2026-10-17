export type MemberCommand = 'get' | 'profile' | 'consents' | 'intake' | 'identity' | 'onboarding' | 'draft' | 'reuse' | 'submit' | 'payment' | 'refund' | 'operations' | 'slot' | 'publish' | 'document' | 'matching' | 'matching-monitor' | 'matching-retry' | 'matching-resolve' | 'venues' | 'venue-create' | 'venue-revoke' | 'venue-retry' | 'chat-read' | 'chat-send' | 'chat-monitor' | 'chat-retry' | 'notifications' | 'notifications-read' | 'push-config' | 'push-subscribe' | 'push-unsubscribe' | 'push-test' | 'push-monitor' | 'push-retry' | 'content-monitor' | 'content-retry' | 'attendance' | 'attendance-check-in' | 'attendance-monitor' | 'attendance-review' | 'feedback' | 'feedback-submit' | 'feedback-monitor' | 'feedback-retry' | 'preferences' | 'preferences-save' | 'safety' | 'safety-submit' | 'safety-monitor' | 'safety-detail' | 'safety-review' | 'return-recommendations';
export type MemberDependencies = {
  authenticate: (token: string) => Promise<string | null>;
  execute: (actor: string, command: MemberCommand, payload?: unknown) => Promise<unknown>;
};

export function createMemberHandler(deps: MemberDependencies, allowedOrigins: string[]) {
  return async (request: Request): Promise<Response> => {
    const headers = new Headers({ 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'Vary': 'Origin' });
    const respond = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers });
    const error = (code: string, status: number) => respond({ error: { code } }, status);
    const origin = request.headers.get('origin');
    if (origin && !allowedOrigins.includes(origin)) return error('FORBIDDEN', 403);
    if (origin) headers.set('Access-Control-Allow-Origin', origin);
    headers.set('Access-Control-Allow-Headers', 'authorization, apikey, content-type, x-client-info');
    headers.set('Access-Control-Allow-Methods', 'GET, PUT, POST, OPTIONS');
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
    const parsedUrl = new URL(request.url);
    const path = parsedUrl.pathname.replace(/\/$/, '');
    const isRoot = path.endsWith('/member');
    const isConsents = path.endsWith('/member/consents');
    const intakePath = path.match(/\/member\/intake(?:\/(identity|onboarding|draft|reuse|submit))?$/);
    const operationsPath = path.match(/\/member\/operations(?:\/(slot|publish|document))?$/);
    const chatPath = path.match(/\/member\/chat\/([0-9a-fA-F-]{36})(?:\/(messages))?$/);
    const chatOperations = path.match(/\/member\/operations\/chat(?:\/(retry))?$/);
    const venuePath = path.match(/\/member\/operations\/venues(?:\/(create|revoke|retry))?$/);
    const notificationsPath = path.match(/\/member\/notifications(?:\/(read))?$/);
    const pushPath = path.match(/\/member\/push(?:\/(subscribe|unsubscribe|test))?$/);
    const pushOps = path.match(/\/member\/operations\/push(?:\/(retry))?$/);
    const contentOps = path.match(/\/member\/operations\/content(?:\/(retry))?$/);
    const attendancePath = path.match(/\/member\/attendance(?:\/(check-in))?$/);
    const attendanceOps = path.match(/\/member\/operations\/attendance(?:\/(review))?$/);
    const feedbackPath = path.match(/\/member\/feedback(?:\/(submit))?$/);
    const feedbackOps = path.match(/\/member\/operations\/feedback(?:\/(retry))?$/);
    const safetyPath = path.match(/\/member\/safety(?:\/(submit))?$/);
    const safetyOps = path.match(/\/member\/operations\/safety(?:\/(detail|review))?$/);
    const preferencesPath = path.match(/\/member\/preferences(?:\/(save))?$/);
    const isRecommendations = path.endsWith('/member/return-recommendations');
    const isResolve = path.endsWith('/member/matching/resolve');
    const isMatching = path.endsWith('/member/matching');
    const isMonitor = path.endsWith('/member/operations/matching');
    const isRetry = path.endsWith('/member/operations/matching/retry');
    const isPayment = path.endsWith('/member/intake/payment');
    const isRefund = path.endsWith('/member/intake/refund');
    if (!isRecommendations && !isRoot && !isConsents && !intakePath && !operationsPath && !isPayment && !isRefund && !isMatching && !isMonitor && !isRetry && !isResolve && !venuePath && !chatPath && !chatOperations && !notificationsPath && !pushPath && !pushOps && !contentOps && !attendancePath && !attendanceOps && !feedbackPath && !feedbackOps && !preferencesPath && !safetyPath && !safetyOps) return error('NOT_FOUND', 404);
    const command: MemberCommand | undefined = isRecommendations && request.method === 'GET' ? 'return-recommendations'
      : isRoot && request.method === 'GET' ? 'get'
      : isRoot && request.method === 'PUT' ? 'profile'
      : isConsents && request.method === 'POST' ? 'consents'
      : intakePath && !intakePath[1] && request.method === 'GET' ? 'intake'
      : intakePath && ['identity','onboarding','draft'].includes(intakePath[1]) && request.method === 'PUT' ? intakePath[1] as MemberCommand
      : intakePath && ['reuse','submit'].includes(intakePath[1]) && request.method === 'POST' ? intakePath[1] as MemberCommand
      : chatPath && !chatPath[2] && request.method === 'GET' ? 'chat-read'
      : chatPath?.[2] && request.method === 'POST' ? 'chat-send'
      : chatOperations && !chatOperations[1] && request.method === 'GET' ? 'chat-monitor'
      : chatOperations?.[1] && request.method === 'POST' ? 'chat-retry'
      : venuePath && !venuePath[1] && request.method === 'GET' ? 'venues'
      : venuePath?.[1] && request.method === 'POST' ? `venue-${venuePath[1]}` as MemberCommand
      : notificationsPath && !notificationsPath[1] && request.method === 'GET' ? 'notifications'
      : notificationsPath?.[1] && request.method === 'POST' ? 'notifications-read'
      : pushPath && !pushPath[1] && request.method === 'GET' ? 'push-config'
      : pushPath?.[1] && request.method === 'POST' ? `push-${pushPath[1]}` as MemberCommand
      : pushOps && !pushOps[1] && request.method === 'GET' ? 'push-monitor'
      : pushOps?.[1] && request.method === 'POST' ? 'push-retry'
      : contentOps && !contentOps[1] && request.method === 'GET' ? 'content-monitor'
      : contentOps?.[1] && request.method === 'POST' ? 'content-retry'
      : attendancePath && !attendancePath[1] && request.method === 'GET' ? 'attendance'
      : attendancePath?.[1] && request.method === 'POST' ? 'attendance-check-in'
      : attendanceOps && !attendanceOps[1] && request.method === 'GET' ? 'attendance-monitor'
      : attendanceOps?.[1] && request.method === 'POST' ? 'attendance-review'
      : feedbackPath && !feedbackPath[1] && request.method === 'GET' ? 'feedback'
      : feedbackPath?.[1] && request.method === 'POST' ? 'feedback-submit'
      : feedbackOps && !feedbackOps[1] && request.method === 'GET' ? 'feedback-monitor'
      : feedbackOps?.[1] && request.method === 'POST' ? 'feedback-retry'
      : safetyPath && !safetyPath[1] && request.method === 'GET' ? 'safety'
      : safetyPath?.[1] && request.method === 'POST' ? 'safety-submit'
      : safetyOps && !safetyOps[1] && request.method === 'GET' ? 'safety-monitor'
      : safetyOps?.[1] === 'detail' && request.method === 'POST' ? 'safety-detail'
      : safetyOps?.[1] === 'review' && request.method === 'POST' ? 'safety-review'
      : preferencesPath && !preferencesPath[1] && request.method === 'GET' ? 'preferences'
      : preferencesPath?.[1] && request.method === 'POST' ? 'preferences-save'
      : isResolve && request.method === 'POST' ? 'matching-resolve'
      : isMatching && request.method === 'GET' ? 'matching'
      : isMonitor && request.method === 'GET' ? 'matching-monitor'
      : isRetry && request.method === 'POST' ? 'matching-retry'
      : isPayment && request.method === 'POST' ? 'payment'
      : isRefund && request.method === 'POST' ? 'refund'
      : operationsPath && !operationsPath[1] && request.method === 'GET' ? 'operations'
      : operationsPath?.[1] && request.method === 'POST' ? operationsPath[1] as MemberCommand : undefined;
    if (!command) {
      headers.set('Allow', isRecommendations ? 'GET, OPTIONS' : isRoot ? 'GET, PUT, OPTIONS' : ((safetyPath && !safetyPath[1]) || (safetyOps && !safetyOps[1]) || (preferencesPath && !preferencesPath[1])) ? 'GET, OPTIONS' : (feedbackPath && !feedbackPath[1]) || (feedbackOps && !feedbackOps[1]) ? 'GET, OPTIONS' : (attendancePath && !attendancePath[1]) || (attendanceOps && !attendanceOps[1]) ? 'GET, OPTIONS' : isMatching || isMonitor || (contentOps && !contentOps[1]) || (pushOps && !pushOps[1]) || (pushPath && !pushPath[1]) || (notificationsPath && !notificationsPath[1]) || (chatPath && !chatPath[2]) || (chatOperations && !chatOperations[1]) || (venuePath && !venuePath[1]) ? 'GET, OPTIONS' : operationsPath && !operationsPath[1] ? 'GET, OPTIONS' : intakePath && !intakePath[1] ? 'GET, OPTIONS'
        : intakePath && ['identity','onboarding','draft'].includes(intakePath[1]) ? 'PUT, OPTIONS' : 'POST, OPTIONS');
      return error('METHOD_NOT_ALLOWED', 405);
    }
    const token = request.headers.get('authorization')?.match(/^Bearer ([^\s]+)$/i)?.[1];
    if (!token) return error('UNAUTHENTICATED', 401);
    try {
      const actor = await deps.authenticate(token);
      if (!actor) return error('UNAUTHENTICATED', 401);
      let payload: unknown;
      if ((isRecommendations || feedbackPath || feedbackOps || preferencesPath || safetyPath || safetyOps) && parsedUrl.search) return error('VALIDATION_ERROR',422);
      if (chatPath && (Array.from(parsedUrl.searchParams.keys()).some(k => k !== 'before') || parsedUrl.searchParams.getAll('before').length>1 || (command === 'chat-send' && parsedUrl.search))) return error('VALIDATION_ERROR',422);
      if (command === 'chat-read') payload = { roomId: chatPath![1], before: parsedUrl.searchParams.get('before') };
      if (command !== 'return-recommendations' && command !== 'get' && command !== 'intake' && command !== 'operations' && command !== 'matching' && command !== 'matching-monitor' && command !== 'venues' && command !== 'chat-read' && command !== 'chat-monitor' && command !== 'notifications' && command !== 'push-config' && command !== 'push-monitor' && command !== 'content-monitor' && command !== 'attendance' && command !== 'attendance-monitor' && command !== 'feedback' && command !== 'feedback-monitor' && command !== 'preferences' && command !== 'safety' && command !== 'safety-monitor') {
        if (request.headers.get('content-type')?.split(';')[0].trim() !== 'application/json') return error('UNSUPPORTED_MEDIA_TYPE', 415);
        // Bound the actual stream, not just a caller-controlled Content-Length.
        const reader = request.body?.getReader();
        if (!reader) return error('VALIDATION_ERROR', 422);
        let size = 0;
        const chunks: Uint8Array[] = [];
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          size += value.byteLength;
          if (size > 16384) { await reader.cancel(); return error('PAYLOAD_TOO_LARGE', 413); }
          chunks.push(value);
        }
        const bytes = new Uint8Array(size);
        let offset = 0;
        for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
        try { payload = JSON.parse(new TextDecoder().decode(bytes)); }
        catch { return error('VALIDATION_ERROR', 422); }
      }
      if (command === 'push-test' && (!payload || typeof payload !== 'object' || Array.isArray(payload) || Object.keys(payload).length)) return error('VALIDATION_ERROR',422);
      if (command === 'chat-send') {
        if (!payload || typeof payload !== 'object' || Array.isArray(payload) || 'roomId' in payload) return error('VALIDATION_ERROR',422);
        payload = { ...payload, roomId: chatPath![1] };
      }
      return respond(await deps.execute(actor, command, payload));
    } catch (cause) {
      const message = cause instanceof Error ? cause.message : '';
      if (message === 'PUSH_RATE_LIMIT') { headers.set('Retry-After','60'); return error(message,429); }
      if (['PUSH_NOT_CONFIGURED','PUSH_SUBSCRIPTION_REQUIRED','PUSH_DEVICE_LIMIT'].includes(message)) return error(message,409);
      if (message === 'SAFETY_RATE_LIMIT') { headers.set('Retry-After','86400'); return error(message,429); }
      if (message === 'CHAT_RATE_LIMIT') { headers.set('Retry-After','60'); return error('CHAT_RATE_LIMIT',429); }
      if (message === 'PARTICIPATION_RESTRICTED') return error(message,403);
      if (message === 'FORBIDDEN') return error('FORBIDDEN', 403);
      if (message === 'VALIDATION_ERROR') return error('VALIDATION_ERROR', 422);
      if (message === 'CONSENT_CHANGED') return error('CONSENT_CHANGED', 409);
      if (['SAFETY_CONFLICT','PREFERENCE_CLOSED','PREFERENCE_CONFLICT','FEEDBACK_CLOSED','FEEDBACK_CONFLICT','CHECK_IN_CLOSED','ATTENDANCE_CONFLICT','SCHEMA_CHANGED','PROFILE_REQUIRED','EVENT_CLOSED','TICKET_UNAVAILABLE','CONSENT_REQUIRED','DUPLICATE_APPLICATION','IDEMPOTENCY_CONFLICT','DRAFT_CHANGED','PAYMENT_CONFLICT','MEMBERSHIP_REQUIRED','MEMBERSHIP_ACTIVE','MEMBERSHIP_IN_USE','REFUND_CLOSED','JOB_CONFLICT','RESOLUTION_CONFLICT','CANCELLATION_CLOSED','VENUE_VERIFICATION_REQUIRED','VENUE_DUPLICATE'].includes(message)) return error(message, 409);
      return error('SERVICE_UNAVAILABLE', 503);
    }
  };
}
