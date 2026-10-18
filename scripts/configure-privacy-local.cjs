// This fixed local project only. Server-only token stays out of output and Git.
const fs=require('node:fs'),crypto=require('node:crypto'),{execFileSync}=require('node:child_process');
const file='.local/privacy-runtime.json';fs.mkdirSync('.local',{recursive:true});
const settings=fs.existsSync(file)?JSON.parse(fs.readFileSync(file,'utf8')):{token:crypto.randomBytes(32).toString('base64url')};
if(!/^[A-Za-z0-9_-]{40,64}$/.test(settings.token))throw Error('Invalid local token');
fs.writeFileSync(file,JSON.stringify(settings));
const envFile='supabase/functions/.env.local';let env=fs.existsSync(envFile)?fs.readFileSync(envFile,'utf8'):'';
env=env.replace(/^PRIVACY_DISPATCH_TOKEN=.*\r?\n?/mg,'');env+='\nPRIVACY_DISPATCH_TOKEN='+settings.token+'\n';fs.writeFileSync(envFile,env);
const q=`begin;do $$ declare ref uuid;begin
select id into ref from vault.secrets where name='privacy_dispatch_url';if ref is null then perform vault.create_secret('http://kong:8000/functions/v1/privacy-dispatch','privacy_dispatch_url');else perform vault.update_secret(ref,'http://kong:8000/functions/v1/privacy-dispatch');end if;
select id into ref from vault.secrets where name='privacy_dispatch_token';if ref is null then perform vault.create_secret('${settings.token}','privacy_dispatch_token');else perform vault.update_secret(ref,'${settings.token}');end if;
end $$;commit;`;
execFileSync('docker',['exec','-i','supabase_db_serendipity-table','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1'],{input:q,stdio:['pipe','pipe','pipe']});
console.log('Local privacy worker/Vault configured; credentials withheld. Restart local Edge serve.');
