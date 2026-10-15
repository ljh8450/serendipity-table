export function createHandler(
  checkDatabase: () => Promise<boolean>,
  allowedOrigins: string[],
) {
  return async (request: Request): Promise<Response> => {
    const origin = request.headers.get('origin');
    const headers = new Headers({
      'Content-Type': 'application/json',
      'Cache-Control': 'no-store',
      'Vary': 'Origin',
    });
    if (origin && !allowedOrigins.includes(origin)) {
      return new Response(JSON.stringify({ error: 'Forbidden' }), { status: 403, headers });
    }
    if (origin) headers.set('Access-Control-Allow-Origin', origin);
    headers.set('Access-Control-Allow-Methods', 'GET, OPTIONS');
    headers.set('Access-Control-Allow-Headers', 'authorization, apikey, content-type, x-client-info');
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
    if (request.method !== 'GET') {
      headers.set('Allow', 'GET, OPTIONS');
      return new Response(JSON.stringify({ error: 'Method not allowed' }), { status: 405, headers });
    }
    try {
      if (!await checkDatabase()) throw new Error('Not ready');
      return new Response(JSON.stringify({ status: 'ready' }), { headers });
    } catch {
      return new Response(JSON.stringify({ error: 'Service unavailable' }), { status: 503, headers });
    }
  };
}
