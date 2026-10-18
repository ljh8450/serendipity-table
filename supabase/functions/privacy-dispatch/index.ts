import postgres from 'npm:postgres@3.4.7';
import { createPrivacyHandler } from './handler.ts';
const connection=Deno.env.get('SUPABASE_DB_URL'),url=Deno.env.get('SUPABASE_URL')?.replace(/\/$/,''),serviceKey=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
const localHosts=['127.0.0.1','localhost','host.docker.internal','supabase_db_serendipity-table','db'];
const localTls=Deno.env.get('HEALTH_DATABASE_SSL')==='disable'&&connection&&localHosts.includes(new URL(connection).hostname);
const sql=connection?postgres(connection,{ssl:localTls?false:'require',max:1,prepare:false,connect_timeout:5,idle_timeout:10}):undefined;
Deno.serve(createPrivacyHandler({
 secret:Deno.env.get('PRIVACY_DISPATCH_TOKEN'),configured:!!sql&&!!url&&!!serviceKey,
 async claim(){
  if(!sql)throw Error('Not configured');return await sql.begin(async tx=>{await tx`set local role app_privacy_dispatch`;await tx`set local statement_timeout = '5s'`;const rows=await tx`select app_private.privacy_claim() dto`;return rows[0].dto});
 },
 async process(job){
  if(!sql||!url||!serviceKey)throw Error('Not configured');
  if(job.kind==='HARD_DELETE')await sql.begin(async tx=>{await tx`set local role app_privacy_dispatch`;await tx`set local statement_timeout = '5s'`;await tx`select app_private.privacy_hard_prepare(${job.id}::uuid,${job.token}::uuid)`});
  const response=await fetch(`${url}/auth/v1/admin/users/${job.userId}`,{method:'DELETE',headers:{apikey:serviceKey,Authorization:`Bearer ${serviceKey}`,'Content-Type':'application/json'},body:JSON.stringify({should_soft_delete:job.kind==='SOFT_DELETE'}),signal:AbortSignal.timeout(5000),redirect:'error'});
  if(!response.ok&&response.status!==404)return false;
  return await sql.begin(async tx=>{await tx`set local role app_privacy_dispatch`;await tx`set local statement_timeout = '5s'`;const rows=await tx`select app_private.privacy_auth_complete(${job.id}::uuid,${job.token}::uuid) complete`;return rows[0].complete});
 },
 async finish(job,success){
  if(!sql)throw Error('Not configured');await sql.begin(async tx=>{await tx`set local role app_privacy_dispatch`;await tx`set local statement_timeout = '5s'`;await tx`select app_private.privacy_finish(${job.id}::uuid,${job.token}::uuid,${success})`});
 },
}));
