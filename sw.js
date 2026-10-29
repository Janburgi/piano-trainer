/* Offline-Cache: die App selbst kommt immer frisch aus dem Netz (Updates sofort da) und nur ohne
   Netz aus dem Cache. Klänge und Schrift werden einmal geladen und danach aus dem Cache gespielt. */
const APP = 'pt-app-v1', MEDIA = 'pt-media';
const CORE = ['./', 'index.html', 'manifest.webmanifest', 'icon-180.png', 'icon-192.png', 'icon-512.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(APP).then(c => c.addAll(CORE)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== APP && k !== MEDIA).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  const u = new URL(e.request.url);
  if (u.origin === location.origin) {
    e.respondWith(fetch(e.request).then(r => {
      if (r.ok) { const copy = r.clone(); caches.open(APP).then(c => c.put(e.request, copy)); }
      return r;
    }).catch(() => caches.match(e.request, { ignoreSearch: true }).then(r => r || caches.match('./'))));
    return;
  }
  if (/^(tonejs|gleitz)\.github\.io$|^fonts\.(googleapis|gstatic)\.com$/.test(u.host)) {
    e.respondWith(caches.open(MEDIA).then(c => c.match(e.request).then(hit => hit || fetch(e.request).then(r => {
      if (r.ok || r.type === 'opaque') c.put(e.request, r.clone());
      return r;
    }))));
  }
});
