/* Offline cache for the Backrooms web build.
   Cache-first with background refresh: the game is fully playable with no
   network (procedural world + local three.js + stickman models), which is
   also what a wrapped iOS build expects. Bump VERSION on every release. */
const VERSION = 'backrooms-v2';
const CORE = [
  './',
  'index.html',
  'manifest.webmanifest',
  'lib/three.min.js',
  'lib/GLTFLoader.js',
  'icons/icon-192.png',
  'icons/icon-512.png',
  '../assets/models/entities/stickman_tall.glb',
  '../assets/models/entities/stickman_hound.glb',
  '../assets/models/entities/stickman_crawler.glb',
  '../assets/models/entities/stickman_drowned.glb'
];
self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(VERSION)
      .then(c => Promise.allSettled(CORE.map(u => c.add(u))))
      .then(() => self.skipWaiting())
  );
});
self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  const url = new URL(e.request.url);
  if (url.origin !== location.origin) return;   /* never intercept cross-origin */
  e.respondWith(
    caches.match(e.request).then(hit => {
      const refresh = fetch(e.request).then(res => {
        if (res && res.ok) caches.open(VERSION).then(c => c.put(e.request, res.clone()));
        return res;
      }).catch(() => hit);
      return hit || refresh;
    })
  );
});
