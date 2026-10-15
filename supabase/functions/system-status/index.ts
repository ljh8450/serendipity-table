import postgres from 'npm:postgres@3.4.7';
import { createHandler } from './handler.ts';

const connection = Deno.env.get('HEALTH_DATABASE_URL') ?? Deno.env.get('SUPABASE_DB_URL');
const origins = (Deno.env.get('APP_ALLOWED_ORIGINS') ?? '').split(',').map(v => v.trim()).filter(Boolean);
const localHosts = ['127.0.0.1', 'localhost', 'host.docker.internal', 'supabase_db_serendipity-table', 'db'];
const disableLocalTls = Deno.env.get('HEALTH_DATABASE_SSL') === 'disable' && connection && localHosts.includes(new URL(connection).hostname);
const sql = connection ? postgres(connection, {
  ssl: disableLocalTls ? false : 'require', max: 1, prepare: false, connect_timeout: 5, idle_timeout: 10,
}) : undefined;

// Public infrastructure health only. Product endpoints must independently verify JWT and roles.
Deno.serve(createHandler(async () => {
  if (!sql) return false;
  const rows = await sql.begin(async tx => {
    await tx`set local role app_health_reader`;
    return await tx`select version from app_private.schema_marker where id = true`;
  });
  return rows.length === 1 && rows[0].version === 1;
}, origins));
