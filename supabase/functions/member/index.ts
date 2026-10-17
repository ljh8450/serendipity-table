import postgres from 'npm:postgres@3.4.7';
import { createMemberHandler } from './handler.ts';

const connection = Deno.env.get('SUPABASE_DB_URL');
const url = Deno.env.get('SUPABASE_URL');
const key = Deno.env.get('SUPABASE_ANON_KEY');
const origins = (Deno.env.get('APP_ALLOWED_ORIGINS') ?? '').split(',').map(v => v.trim()).filter(Boolean);
const localHosts = ['127.0.0.1', 'localhost', 'host.docker.internal', 'supabase_db_serendipity-table', 'db'];
const localTls = Deno.env.get('HEALTH_DATABASE_SSL') === 'disable' && connection && localHosts.includes(new URL(connection).hostname);
const sql = connection ? postgres(connection, {
  ssl: localTls ? false : 'require', max: 1, prepare: false, connect_timeout: 5, idle_timeout: 10,
}) : undefined;

Deno.serve(createMemberHandler({
  async authenticate(token) {
    if (!url || !key) throw new Error('Auth unavailable');
    // Auth server validation supports legacy and asymmetric JWT signing keys.
    const response = await fetch(`${url}/auth/v1/user`, {
      headers: { apikey: key, Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(5000),
    });
    if (response.status === 401 || response.status === 403) return null;
    if (!response.ok) throw new Error('Auth unavailable');
    const user = await response.json();
    return typeof user.id === 'string' && /^[0-9a-f-]{36}$/i.test(user.id) ? user.id : null;
  },
  async execute(actor, command, payload) {
    if (!sql) throw new Error('DB unavailable');
    return await sql.begin(async tx => {
      await tx`set local role app_member_api`;
      await tx`set local statement_timeout = '5s'`;
      await tx`select set_config('app.actor_id', ${actor}, true)`;
      const rows = command === 'safety' ? await tx`select app_private.safety_get() as dto`
        : command === 'safety-submit' ? await tx`select app_private.safety_submit(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'safety-monitor' ? await tx`select app_private.operations_safety_get() as dto`
        : command === 'safety-detail' ? await tx`select app_private.operations_safety_detail(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'safety-review' ? await tx`select app_private.operations_safety_review(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'preferences' ? await tx`select app_private.preferences_get() as dto`
        : command === 'preferences-save' ? await tx`select app_private.preferences_save(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'feedback' ? await tx`select app_private.feedback_get() as dto`
        : command === 'feedback-submit' ? await tx`select app_private.feedback_submit(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'feedback-monitor' ? await tx`select app_private.operations_feedback_get() as dto`
        : command === 'feedback-retry' ? await tx`select app_private.operations_feedback_retry(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'attendance' ? await tx`select app_private.attendance_get() as dto`
        : command === 'attendance-check-in' ? await tx`select app_private.attendance_check_in(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'attendance-monitor' ? await tx`select app_private.operations_attendance_get() as dto`
        : command === 'attendance-review' ? await tx`select app_private.operations_attendance_review(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'content-monitor' ? await tx`select app_private.operations_content_get() as dto`
        : command === 'content-retry' ? await tx`select app_private.operations_content_retry(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'push-monitor' ? await tx`select app_private.operations_push_get() as dto`
        : command === 'push-retry' ? await tx`select app_private.operations_push_retry(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'push-config' ? await tx`select app_private.push_get() as dto`
        : command === 'push-subscribe' ? await tx`select app_private.push_subscribe(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'push-unsubscribe' ? await tx`select app_private.push_unsubscribe(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'push-test' ? await tx`select app_private.push_test() as dto`
        : command === 'notifications' ? await tx`select app_private.notifications_get() as dto`
        : command === 'notifications-read' ? await tx`select app_private.notifications_read(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'chat-read' ? await tx`select app_private.chat_get(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'chat-send' ? await tx`select app_private.chat_send(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'chat-monitor' ? await tx`select app_private.operations_chat_get() as dto`
        : command === 'chat-retry' ? await tx`select app_private.operations_chat_retry(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'venues' ? await tx`select app_private.operations_venues_get() as dto`
        : command === 'venue-create' ? await tx`select app_private.operations_venue_create(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'venue-revoke' ? await tx`select app_private.operations_venue_revoke(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'venue-retry' ? await tx`select app_private.operations_venue_retry(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'return-recommendations' ? await tx`select app_private.return_recommendations_get() as dto`
        : command === 'matching' ? await tx`select app_private.matching_get() as dto`
        : command === 'matching-resolve' ? await tx`select app_private.match_resolve(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'matching-monitor' ? await tx`select app_private.operations_matching_get() as dto`
        : command === 'matching-retry' ? await tx`select app_private.match_retry(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'operations' ? await tx`select app_private.operations_get() as dto`
        : command === 'slot' ? await tx`select app_private.operations_slot(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'publish' ? await tx`select app_private.operations_publish(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'document' ? await tx`select app_private.operations_consent(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'refund' ? await tx`select app_private.mock_refund(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'payment' ? await tx`select app_private.mock_payment(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'intake' ? await tx`select app_private.intake_get() as dto`
        : command === 'identity' || command === 'onboarding' ? await tx`select app_private.intake_profile_save(${tx.json(payload as postgres.JSONValue)},${command === 'identity'}) as dto`
        : command === 'draft' ? await tx`select app_private.intake_draft_save(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'reuse' ? await tx`select app_private.intake_reuse(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'submit' ? await tx`select app_private.intake_submit(${tx.json(payload as postgres.JSONValue)}) as dto`
        : command === 'get' ? await tx`select app_private.member_get() as dto`
        : command === 'profile' ? await tx`select app_private.member_profile_save(${tx.json(payload as postgres.JSONValue)}) as dto`
        : await tx`select app_private.member_consents_accept(${tx.json(payload as postgres.JSONValue)}) as dto`;
      return rows[0].dto;
    });
  },
}, origins));
