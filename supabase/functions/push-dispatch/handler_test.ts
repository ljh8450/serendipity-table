import { createPushHandler, validEndpoint, type PushJob } from './handler.ts';
const assert = (v: unknown) => { if (!v) throw new Error('Assertion failed'); };
const secret = 'x'.repeat(40);
const request = (body='{}', token=secret) => new Request('http://internal/push-dispatch', {method:'POST',headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},body});
const job: PushJob = {id:'id',token:'lease',notificationId:'notice',subscription:{endpoint:'https://fcm.googleapis.com/send/example',keys:{p256dh:'key',auth:'auth'}}};
Deno.test('dispatcher fails closed and rejects caller controlled recipients',async()=>{
 let calls=0;
 const deps={secret,claim:async()=>{calls++;return null;},send:async()=>201,finish:async()=>{}};
 assert((await createPushHandler({...deps,secret:undefined})(request())).status===503);
 const handler=createPushHandler(deps);
 assert((await handler(request('{}','wrong'))).status===401);
 assert((await handler(request('{"endpoint":"http://localhost"}'))).status===422);
 assert((await handler(request('x'.repeat(65)))).status===413);
 assert(calls===0);
});
Deno.test('dispatcher bounds batches and records transport failure without leaking payload',async()=>{
 let claimed=0;const statuses:number[]=[];
 const handler=createPushHandler({secret,claim:async()=>++claimed<=2?job:null,send:async()=>{if(claimed===1)throw Error('secret endpoint');return 201;},finish:async(_j,status)=>{statuses.push(status);}});
 const response=await handler(request());assert(response.status===200);assert(JSON.stringify(statuses)==='[0,201]');assert((await response.json()).processed===2);
 let count=0;await createPushHandler({secret,claim:async()=>job,send:async()=>201,finish:async()=>{count++;}})(request());assert(count===5);
});
Deno.test('dispatcher rejects internal, credentialed, redirected or lookalike endpoints',()=>{
 for(const s of ['http://fcm.googleapis.com/path','https://fcm.googleapis.com.evil.test/path','https://localhost/path','https://a@fcm.googleapis.com/path','https://fcm.googleapis.com:8443/path','https://fcm.googleapis.com/path#frag'])assert(!validEndpoint(s));
 assert(validEndpoint('https://updates.push.services.mozilla.com/wpush/v2/test'));
});
