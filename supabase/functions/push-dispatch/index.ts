import postgres from 'npm:postgres@3.4.7';
// @deno-types="npm:@types/web-push@3.6.4"
import webpush from 'npm:web-push@3.6.7';
import { createPushHandler, type PushJob } from './handler.ts';
const connection = Deno.env.get('SUPABASE_DB_URL');
const local = connection && ['127.0.0.1','localhost','host.docker.internal','supabase_db_serendipity-table','db'].includes(new URL(connection).hostname);
const sql = connection ? postgres(connection, { ssl: local && Deno.env.get('HEALTH_DATABASE_SSL') === 'disable' ? false : 'require', max: 1, prepare: false, connect_timeout: 5 }) : null;
async function transaction<T>(action: (tx: postgres.TransactionSql) => Promise<T>): Promise<T> {
  if (!sql) throw new Error('DB unavailable');
  return await sql.begin(async tx => { await tx`set local role app_push_worker`; await tx`set local statement_timeout='5s'`; return action(tx); }) as T;
}
Deno.serve(createPushHandler({
  secret: Deno.env.get('PUSH_VAPID_PUBLIC_KEY') && Deno.env.get('PUSH_VAPID_PRIVATE_KEY') ? Deno.env.get('PUSH_DISPATCH_TOKEN') : undefined,
  async claim() { return transaction(async tx => (await tx`select app_private.push_claim() as job`)[0].job as PushJob | null); },
  async finish(job, status) { await transaction(async tx => { await tx`select app_private.push_finish(${job.id}::uuid,${job.token}::uuid,${status})`; }); },
  async send(job) {
    const publicKey = Deno.env.get('PUSH_VAPID_PUBLIC_KEY'), privateKey = Deno.env.get('PUSH_VAPID_PRIVATE_KEY');
    if (!publicKey || !privateKey) throw new Error('Push unavailable');
    const details = webpush.generateRequestDetails(job.subscription, JSON.stringify({ notificationId: job.notificationId }), {
      vapidDetails: { subject: 'https://serendipity-table.vercel.app', publicKey, privateKey }, TTL: 300,
      topic: job.notificationId.replaceAll('-', '').slice(0,32),
    });
    const response = await fetch(details.endpoint, { method: 'POST', headers: details.headers as Record<string,string>, body: new Uint8Array(details.body!), redirect: 'error', signal: AbortSignal.timeout(5000) });
    await response.body?.cancel(); return response.status;
  },
}));
