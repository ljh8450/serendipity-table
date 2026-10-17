// Generates local-only keys; never prints credentials or writes production.
const fs=require('node:fs'),crypto=require('node:crypto'),{execFileSync}=require('node:child_process');
let settings;
if(fs.existsSync('.local/push-runtime.json')) settings=JSON.parse(fs.readFileSync('.local/push-runtime.json','utf8'));
else {const e=crypto.createECDH('prime256v1');e.generateKeys();settings={publicKey:e.getPublicKey().toString('base64url'),privateKey:e.getPrivateKey().toString('base64url'),token:crypto.randomBytes(32).toString('base64url')};fs.writeFileSync('.local/push-runtime.json',JSON.stringify(settings));}
const file='supabase/functions/.env.local';let env=fs.readFileSync(file,'utf8');for(const[k,v]of Object.entries({PUSH_VAPID_PUBLIC_KEY:settings.publicKey,PUSH_VAPID_PRIVATE_KEY:settings.privateKey,PUSH_DISPATCH_TOKEN:settings.token})){env=env.replace(new RegExp('^'+k+'=.*\\r?\\n?','mg'),'');env+='\n'+k+'='+v+'\n';}fs.writeFileSync(file,env);
const q=`begin;insert into app_private.push_config(id,public_key) values(true,'${settings.publicKey}') on conflict(id) do update set public_key=excluded.public_key;
do $$ declare ref uuid;begin
 select id into ref from vault.secrets where name='push_dispatch_url';
 if ref is null then perform vault.create_secret('http://kong:8000/functions/v1/push-dispatch','push_dispatch_url');else perform vault.update_secret(ref,'http://kong:8000/functions/v1/push-dispatch');end if;
 select id into ref from vault.secrets where name='push_dispatch_token';
 if ref is null then perform vault.create_secret('${settings.token}','push_dispatch_token');else perform vault.update_secret(ref,'${settings.token}');end if;
end $$;commit;`;
execFileSync('docker',['exec','-i','supabase_db_serendipity-table','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1'],{input:q,stdio:['pipe','pipe','pipe']});console.log('Local VAPID and Vault configuration saved; secrets withheld');
