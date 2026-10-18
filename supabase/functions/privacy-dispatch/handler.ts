export type PrivacyJob = { id: string; token: string; userId: string; kind: 'SOFT_DELETE' | 'HARD_DELETE' };
export function createPrivacyHandler(deps: { secret?: string; configured: boolean; claim: () => Promise<PrivacyJob | null>; process: (job: PrivacyJob) => Promise<boolean>; finish: (job: PrivacyJob, success: boolean) => Promise<void> }) {
 return async (req: Request): Promise<Response> => {
  const reply=(status:number,body:unknown)=>new Response(JSON.stringify(body),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});
  if(!deps.configured||!deps.secret||deps.secret.length<32)return reply(503,{error:'NOT_CONFIGURED'});
  const given=req.headers.get('authorization')??'',expected=`Bearer ${deps.secret}`;
  let diff=given.length^expected.length;for(let i=0;i<expected.length;i++)diff|=expected.charCodeAt(i)^(given.charCodeAt(i)||0);
  if(diff)return reply(401,{error:'UNAUTHENTICATED'});
  if(req.method!=='POST')return reply(405,{error:'METHOD_NOT_ALLOWED'});
  if(new URL(req.url).search)return reply(422,{error:'VALIDATION_ERROR'});
  if(req.headers.get('content-type')?.split(';')[0]!=='application/json')return reply(415,{error:'UNSUPPORTED_MEDIA_TYPE'});
  const reader=req.body?.getReader();if(!reader)return reply(422,{error:'VALIDATION_ERROR'});
  const bytes:number[]=[];while(true){const {done,value}=await reader.read();if(done)break;if(bytes.length+value.length>64){await reader.cancel();return reply(413,{error:'PAYLOAD_TOO_LARGE'})}bytes.push(...value)}
  try{if(JSON.stringify(JSON.parse(new TextDecoder().decode(new Uint8Array(bytes))))!=='{}')return reply(422,{error:'VALIDATION_ERROR'})}catch{return reply(422,{error:'VALIDATION_ERROR'})}
  let processed=0;
  try{
   for(let i=0;i<5;i++){
    const job=await deps.claim();if(!job)break;
    let success=false;
    if(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(job.userId)&&['SOFT_DELETE','HARD_DELETE'].includes(job.kind)){
     try{success=await deps.process(job)}catch{/* Persist generic failure only. */}
    }
    await deps.finish(job,success);processed++;
   }
   return reply(200,{processed});
  }catch{return reply(503,{error:'SERVICE_UNAVAILABLE'})}
 };
}
