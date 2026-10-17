import { createMemberHandler } from './handler.ts';

function assert(value: unknown, message = 'Assertion failed'): asserts value { if (!value) throw new Error(message); }
const origin = 'https://app.example';
const request = (method = 'GET', body?: string, token = 'valid') => new Request('https://edge.example/member', {
  method, headers: { origin, authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body,
});

Deno.test('member rejects unauthenticated/forbidden requests before any command', async () => {
  let commands = 0;
  const handler = createMemberHandler({ authenticate: async () => null, execute: async () => { commands++; } }, [origin]);
  assert((await handler(request())).status === 401);
  assert((await handler(new Request('https://edge.example/member'))).status === 401);
  assert((await handler(new Request('https://edge.example/member', { headers: { origin: 'https://evil.example' } }))).status === 403);
  assert(commands === 0);
});
Deno.test('member uses the verified actor and returns no-store DTO', async () => {
  const handler = createMemberHandler({ authenticate: async token => token === 'valid' ? 'verified-id' : null,
    execute: async (actor, command) => { assert(actor === 'verified-id'); assert(command === 'get'); return { profile: null }; } }, [origin]);
  const response = await handler(request());
  assert(response.status === 200);
  assert(response.headers.get('cache-control') === 'no-store');
  assert(response.headers.get('access-control-allow-origin') === origin);
  assert((await response.json()).profile === null);
});
Deno.test('member bounds JSON bodies and sanitizes server failures', async () => {
  let commands = 0;
  const handler = createMemberHandler({ authenticate: async () => 'actor', execute: async () => { commands++; throw new Error('secret sql details'); } }, [origin]);
  assert((await handler(request('PUT', '{'))).status === 422);
  assert((await handler(request('PUT', 'x'.repeat(16385)))).status === 413);
  assert(commands === 0);
  const response = await handler(request());
  assert(response.status === 503);
  assert(!JSON.stringify(await response.json()).includes('secret'));
});
Deno.test('member accepts preflight, restricts methods and maps domain errors', async () => {
  const handler = createMemberHandler({ authenticate: async () => 'actor', execute: async () => { throw new Error('CONSENT_CHANGED'); } }, [origin]);
  assert((await handler(request('OPTIONS'))).status === 204);
  assert((await handler(request('DELETE'))).status === 405);
  assert((await handler(request('PUT', '{}'))).status === 409);
});

Deno.test('intake routes dispatch only authenticated allowed commands and map stale drafts', async () => {
  const commands: string[] = [];
  const handler = createMemberHandler({ authenticate: async () => 'actor', execute: async (_actor, command) => {
    commands.push(command);
    if (command === 'submit') throw new Error('DRAFT_CHANGED');
    return {};
  } }, [origin]);
  for (const [route, method, expected] of [['','GET','intake'],['/identity','PUT','identity'],['/onboarding','PUT','onboarding'],['/draft','PUT','draft'],['/reuse','POST','reuse']] as const) {
    const response = await handler(new Request(`https://edge.example/member/intake${route}`, { method, headers: { authorization: 'Bearer valid', 'content-type':'application/json' }, ...(method === 'GET' ? {} : { body:'{}' }) }));
    assert(response.status === 200); assert(commands.at(-1) === expected);
  }
  const response = await handler(new Request('https://edge.example/member/intake/submit', { method:'POST', headers:{ authorization:'Bearer valid','content-type':'application/json' }, body:'{}' }));
  assert(response.status === 409);
});

Deno.test('operations and payments route through actor commands and sanitize policy conflicts', async () => {
  const handler = createMemberHandler({ authenticate: async () => 'actor', execute: async (_actor, command) => {
    if (command === 'operations' || command === 'document') throw new Error('FORBIDDEN');
    if (command === 'refund') throw new Error('REFUND_CLOSED');
    if (command === 'payment') throw new Error('MEMBERSHIP_REQUIRED');
    return {};
  } }, [origin]);
  const call = (path: string, method: string) => handler(new Request(`https://edge.example/member/${path}`, { method, headers: { authorization: 'Bearer valid', 'content-type': 'application/json' }, ...(method === 'GET' ? {} : { body: '{}' }) }));
  assert((await call('operations','GET')).status === 403);
  assert((await call('operations/document','POST')).status === 403);
  assert((await call('operations/slot','GET')).status === 405);
  assert((await call('intake/payment','POST')).status === 409);
  assert((await call('intake/refund','POST')).status === 409);
  assert((await call('intake/payment','PUT')).status === 405);
  assert((await call('operations/role','POST')).status === 404);
});

Deno.test('matching has read-only member/monitor routes and no public worker execution', async () => {
  const calls: string[] = [];
  const handler = createMemberHandler({ authenticate: async () => 'actor', execute: async (_actor, command) => { calls.push(command); return { applications: [] }; } }, [origin]);
  for (const [path,command] of [['matching','matching'],['operations/matching','matching-monitor']] as const) {
    const response = await handler(new Request(`https://edge.example/member/${path}`, { headers: { authorization: 'Bearer valid' } }));
    assert(response.status === 200 && calls.at(-1) === command);
  }
  assert((await handler(new Request('https://edge.example/member/matching/tick', { method: 'POST', headers: { authorization: 'Bearer valid' } }))).status === 404);
  assert((await handler(new Request('https://edge.example/member/matching', { method: 'POST', headers: { authorization: 'Bearer valid' } }))).status === 405);
});

Deno.test('resolution route requires Auth/JSON and maps stale state without leaking details', async () => {
  let called = '';
  const handler = createMemberHandler({ authenticate: async () => 'actor', execute: async (_actor, command) => { called=command; throw new Error('RESOLUTION_CONFLICT'); } }, [origin]);
  const url = 'https://edge.example/member/matching/resolve';
  assert((await handler(new Request(url, { method:'POST', headers:{'content-type':'application/json'},body:'{}' }))).status===401);
  assert((await handler(new Request(url, { headers:{authorization:'Bearer valid'} }))).status===405);
  const response = await handler(new Request(url, { method:'POST',headers:{authorization:'Bearer valid','content-type':'application/json'},body:'{}' }));
  assert(response.status===409 && called==='matching-resolve');
  assert((await response.json()).error.code==='RESOLUTION_CONFLICT');
});

Deno.test('venue routes dispatch authenticated operator commands and hide internal consumer', async () => {
 const calls: string[]=[];
 const handler=createMemberHandler({authenticate:async()=> 'actor',execute:async(_actor,command)=>{calls.push(command);return {};}},[origin]);
 for(const [suffix,method,command] of [['','GET','venues'],['/create','POST','venue-create'],['/revoke','POST','venue-revoke'],['/retry','POST','venue-retry']] as const){
  const response=await handler(new Request(`https://edge.example/member/operations/venues${suffix}`,{method,headers:{authorization:'Bearer valid','content-type':'application/json'},...(method==='POST'?{body:'{}'}:{})}));
  assert(response.status===200 && calls.at(-1)===command);
 }
 assert((await handler(new Request('https://edge.example/member/operations/venues/tick',{method:'POST',headers:{authorization:'Bearer valid'}}))).status===404);
});

Deno.test('chat derives room/cursor from URL, rejects spoofed body/query and maps rate limits', async () => {
 const room='00000000-0000-4000-8000-000000000001';let last: unknown;
 const handler=createMemberHandler({authenticate:async()=> 'actor',execute:async(_actor,command,payload)=>{last=payload;if(command==='chat-send')throw new Error('CHAT_RATE_LIMIT');return {};}},[origin]);
 const base=`https://edge.example/member/chat/${room}`;
 const headers={authorization:'Bearer valid','content-type':'application/json'};
 assert((await handler(new Request(base+'?before=123',{headers}))).status===200);
 assert(JSON.stringify(last)===JSON.stringify({roomId:room,before:'123'}));
 assert((await handler(new Request(base+'?actor=x',{headers}))).status===422);
 assert((await handler(new Request(base+'?before=1&before=2',{headers}))).status===422);
 assert((await handler(new Request(base+'/messages',{method:'POST',headers,body:JSON.stringify({roomId:room,requestKey:room,body:'hello'})}))).status===422);
 const rate=await handler(new Request(base+'/messages',{method:'POST',headers,body:JSON.stringify({requestKey:room,body:'hello'})}));
 assert(rate.status===429 && rate.headers.get('retry-after')==='60');
 assert((await handler(new Request(base+'/messages',{headers}))).status===405);
 assert((await handler(new Request('https://edge.example/member/chat/tick',{method:'POST',headers}))).status===404);
 assert((await handler(new Request(base))).status===401);
});

Deno.test('notifications use authenticated private commands and expose no public consumer',async()=>{
 let called='';
 const handler=createMemberHandler({authenticate:async()=> 'actor',execute:async(_a,c)=>{called=c;return {notifications:[],unreadCount:0}}},[origin]);
 const base='https://edge.example/member/notifications';
 assert((await handler(new Request(base))).status===401);
 assert((await handler(new Request(base,{headers:{authorization:'Bearer valid'}}))).status===200 && called==='notifications');
 assert((await handler(new Request(base+'/read',{method:'POST',headers:{authorization:'Bearer valid','content-type':'application/json'},body:'{"id":"example"}'}))).status===200 && String(called)==='notifications-read');
 assert((await handler(new Request(base+'/tick',{method:'POST',headers:{authorization:'Bearer valid','content-type':'application/json'},body:'{}'}))).status===404);
 assert((await handler(new Request(base,{method:'POST',headers:{authorization:'Bearer valid','content-type':'application/json'},body:'{}'}))).status===405);
});

Deno.test('push member routes preserve actor commands and forbid recipient spoofing',async()=>{
 let called='';
 const handler=createMemberHandler({authenticate:async()=> 'actor',execute:async(_a,c)=>{called=c;return {}; }},[origin]);
 const req=(path:string,method='GET',body?:string)=>new Request('https://edge.example/member'+path,{method,headers:{authorization:'Bearer valid','content-type':'application/json'},body});
 assert((await handler(req('/push'))).status===200 && called==='push-config');
 assert((await handler(req('/push/test','POST','{}'))).status===200 && String(called)==='push-test');
 assert((await handler(req('/push/test','POST','{"userId":"other"}'))).status===422);
 assert((await handler(req('/operations/push'))).status===200 && String(called)==='push-monitor');
 assert((await handler(req('/push/claim','POST','{}'))).status===404);
});

Deno.test('scheduled content has operator commands without a public clock or tick',async()=>{
 let called='';const handler=createMemberHandler({authenticate:async()=> 'actor',execute:async(_a,c)=>{called=c;return {}; }},[origin]);
 const req=(path:string,method='GET',body?:string)=>new Request('https://edge.example/member'+path,{method,headers:{authorization:'Bearer valid','content-type':'application/json'},body});
 assert((await handler(req('/operations/content'))).status===200&&called==='content-monitor');
 assert((await handler(req('/operations/content/retry','POST','{"jobId":"id"}'))).status===200&&String(called)==='content-retry');
 assert((await handler(req('/operations/content/tick','POST','{"now":"future"}'))).status===404);
 assert((await handler(new Request('https://edge.example/member/operations/content'))).status===401);
});

Deno.test('attendance authenticates, dispatches reads/writes and keeps tick private',async()=>{
 let called='';
 const handler=createMemberHandler({authenticate:async()=> 'actor',execute:async(_a,c)=>{called=c;if(c==='attendance-check-in')throw new Error('CHECK_IN_CLOSED');return {}; }},[origin]);
 const req=(path:string,method='GET',body?:string)=>new Request('https://edge.example/member'+path,{method,headers:{authorization:'Bearer valid','content-type':'application/json'},body});
 assert((await handler(req('/attendance'))).status===200&&called==='attendance');
 assert((await handler(req('/attendance/check-in','POST','{}'))).status===409&&String(called)==='attendance-check-in');
 assert((await handler(req('/operations/attendance'))).status===200&&String(called)==='attendance-monitor');
 assert((await handler(req('/operations/attendance/review','POST','{}'))).status===200&&String(called)==='attendance-review');
 assert((await handler(req('/attendance/tick','POST','{}'))).status===404);
 assert((await handler(req('/attendance','POST','{}'))).status===405);
 assert((await handler(new Request('https://edge.example/member/attendance'))).status===401);
 assert((await handler(new Request('https://edge.example/member/attendance',{headers:{authorization:'Bearer valid',origin:'https://evil.example'}}))).status===403);
});

Deno.test('feedback routes preserve auth, methods and private worker boundary',async()=>{
 let called='';
 const handler=createMemberHandler({authenticate:async()=> 'actor',execute:async(_a,c)=>{called=c;if(c==='feedback-submit')throw new Error('FEEDBACK_CLOSED');return {}; }},[origin]);
 const req=(path:string,method='GET',body?:string)=>new Request('https://edge.example/member'+path,{method,headers:{authorization:'Bearer valid','content-type':'application/json'},body});
 assert((await handler(req('/feedback'))).status===200&&called==='feedback');
 assert((await handler(req('/feedback/submit','POST','{}'))).status===409&&String(called)==='feedback-submit');
 assert((await handler(req('/operations/feedback'))).status===200&&String(called)==='feedback-monitor');
 assert((await handler(req('/operations/feedback/retry','POST','{}'))).status===200&&String(called)==='feedback-retry');
 assert((await handler(req('/feedback/tick','POST','{}'))).status===404);
 assert((await handler(req('/feedback','POST','{}'))).status===405);
  assert((await handler(req('/feedback?now=2099-01-01'))).status===422);
 assert((await handler(new Request('https://edge.example/member/feedback'))).status===401);
 assert((await handler(new Request('https://edge.example/member/feedback',{headers:{authorization:'Bearer valid',origin:'https://evil.example'}}))).status===403);
});

Deno.test('person preferences preserve private actor scope, reject clock query and map revision conflicts',async()=>{
 let called='';let failure='PREFERENCE_CONFLICT';
 const handler=createMemberHandler({authenticate:async()=> 'actor',execute:async(_a,c)=>{called=c;if(c==='preferences-save')throw new Error(failure);return {events:[]};}},[origin]);
 const req=(path:string,method='GET',body?:string)=>new Request('https://edge.example/member'+path,{method,headers:{authorization:'Bearer valid','content-type':'application/json'},body});
 assert((await handler(req('/preferences'))).status===200&&called==='preferences');
 for(const code of ['PREFERENCE_CONFLICT','PREFERENCE_CLOSED']){failure=code;const r=await handler(req('/preferences/save','POST','{}'));assert(r.status===409&&String(called)==='preferences-save');assert((await r.json()).error.code===code);}
 assert((await handler(req('/preferences?now=2099-01-01'))).status===422);
 assert((await handler(req('/preferences/tick','POST','{}'))).status===404);
 assert((await handler(req('/preferences','POST','{}'))).status===405);
 assert((await handler(new Request('https://edge.example/member/preferences'))).status===401);
 assert((await handler(new Request('https://edge.example/member/preferences',{headers:{authorization:'Bearer valid',origin:'https://evil.example'}}))).status===403);
});

Deno.test('safety protects review/detail authority, actor DTO routes, clock and private consumers',async()=>{
 let called='';let fail='';const handler=createMemberHandler({authenticate:async()=> 'actor',execute:async(_a,c)=>{called=c;if(fail)throw Error(fail);return {}; }},[origin]);
 const req=(path:string,method='GET',body?:string)=>new Request('https://edge.example/member'+path,{method,headers:{authorization:'Bearer valid','content-type':'application/json'},body});
 for(const [path,method,command] of [['/safety','GET','safety'],['/safety/submit','POST','safety-submit'],['/operations/safety','GET','safety-monitor'],['/operations/safety/detail','POST','safety-detail'],['/operations/safety/review','POST','safety-review']]){
  assert((await handler(req(path,method,method==='POST'?'{}':undefined))).status===200&&called===command);
 }
 for(const [code,status] of [['FORBIDDEN',403],['PARTICIPATION_RESTRICTED',403],['SAFETY_CONFLICT',409],['SAFETY_RATE_LIMIT',429]] as const){fail=code;assert((await handler(req('/operations/safety/review','POST','{}'))).status===status)}fail='';
 assert((await handler(req('/safety?actor=other'))).status===422);assert((await handler(req('/operations/safety/detail?now=future','POST','{}'))).status===422);
 assert((await handler(req('/safety/tick','POST','{}'))).status===404);assert((await handler(req('/operations/safety/grant','POST','{}'))).status===404);assert((await handler(req('/safety','POST','{}'))).status===405);
 assert((await handler(new Request('https://edge.example/member/safety'))).status===401);
 assert((await handler(new Request('https://edge.example/member/safety',{headers:{authorization:'Bearer valid',origin:'https://evil.example'}}))).status===403);
});
