// Push only: application pages and API responses are never cached here.
self.addEventListener('push', event => {
  event.waitUntil((async () => {
    let id = '';
    try { id = event.data.json().notificationId; } catch { /* generic fallback */ }
    if (typeof id !== 'string' || !/^[0-9a-f-]{36}$/i.test(id)) id = 'notice';
    await self.registration.showNotification('우연한식탁', {
      body: '새 안내가 도착했어요. 앱에서 최신 참가 현황을 확인해 주세요.',
      tag: `table-${id}`, data: { path: '/' },
    });
    // Local diagnostic receipt is not server delivery authority and contains no message text.
    const cache = await caches.open('push-receipts-v1');
    await cache.put(`/__push_receipt/${id}`, new Response(JSON.stringify({ notificationId: id, receivedAt: new Date().toISOString() })));
    const keys = await cache.keys();
    for (const key of keys.slice(0, Math.max(0, keys.length - 20))) await cache.delete(key);
  })());
});
self.addEventListener('notificationclick', event => {
  event.notification.close();
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of windows) if (new URL(client.url).origin === self.location.origin) { await client.navigate('/'); return client.focus(); }
    return self.clients.openWindow('/');
  })());
});
