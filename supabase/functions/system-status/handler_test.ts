import { createHandler } from './handler.ts';
function assert(value: unknown) { if (!value) throw new Error('Assertion failed'); }
Deno.test('health checks DB and returns minimal DTO', async () => {
  const handler = createHandler(async () => true, ['https://app.example']);
  const result = await handler(new Request('https://api.example', { headers: { origin: 'https://app.example' } }));
  assert(result.status === 200);
  assert(JSON.stringify(await result.json()) === '{"status":"ready"}');
  assert(result.headers.get('Access-Control-Allow-Origin') === 'https://app.example');
});
Deno.test('forbidden origins and unsupported methods never access DB', async () => {
  const handler = createHandler(() => { throw new Error('Must not query'); }, ['https://app.example']);
  assert((await handler(new Request('https://api.example', { headers: { origin: 'https://evil.example' } }))).status === 403);
  assert((await handler(new Request('https://api.example', { method: 'POST' }))).status === 405);
  assert((await handler(new Request('https://api.example', { method: 'OPTIONS', headers: { origin: 'https://app.example' } }))).status === 204);
});
Deno.test('database errors are sanitized and cannot return ready', async () => {
  for (const check of [async () => false, () => Promise.reject(new Error('secret credential'))]) {
    const result = await createHandler(check, [])(new Request('https://api.example'));
    assert(result.status === 503);
    assert(!(await result.text()).includes('secret'));
  }
});
