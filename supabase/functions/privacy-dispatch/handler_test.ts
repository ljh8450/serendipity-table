import { createPrivacyHandler } from './handler.ts';
function assert(v:unknown):asserts v{if(!v)throw Error('Assertion failed')}
const secret='a'.repeat(40),job={id:'job',token:'token',userId:'11111111-1111-4111-8111-111111111111',kind:'SOFT_DELETE' as const};
const req=(body='{}',token=secret)=>new Request('https://edge.example/privacy-dispatch',{method:'POST',headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},body});
Deno.test('privacy worker fails closed and forbids caller-selected targets',async()=>{
 let calls=0;const deps={secret,configured:true,claim:async()=>{calls++;return null},process:async()=>true,finish:async()=>{}};
 assert((await createPrivacyHandler({...deps,configured:false})(req())).status===503);
 const h=createPrivacyHandler(deps);assert((await h(req('{}','wrong'))).status===401);assert((await h(req('{"userId":"target"}'))).status===422);assert((await h(req('x'.repeat(65)))).status===413);assert(calls===0);
});
Deno.test('privacy worker bounds batch and persists failed Auth transport',async()=>{
 let claimed=0,finished=0;const h=createPrivacyHandler({secret,configured:true,claim:async()=>{claimed++;return job},process:async()=>{throw Error('private transport detail')},finish:async(_,success)=>{assert(!success);finished++}});
 const response=await h(req());assert(response.status===200);assert(claimed===5&&finished===5);assert(!JSON.stringify(await response.json()).includes('private'));
});
Deno.test('privacy worker never calls Auth with an invalid database job target',async()=>{
 let processed=0,finished=false,first=true;
 const h=createPrivacyHandler({secret,configured:true,claim:async()=>{if(!first)return null;first=false;return {...job,userId:'../../admin'}},process:async()=>{processed++;return true},finish:async(_,ok)=>{assert(!ok);finished=true}});
 assert((await h(req())).status===200);assert(processed===0&&finished);
});
