// Lets the app open even with no internet. Bump the version when you change files.
const CACHE = "homelands-2026-10-15c";
const FILES = ["./", "index.html", "styles.css", "app.js", "data.js", "config.js", "vendor/supabase.js", "vendor/qrcode.min.js", "manifest.json", "images/logo.png", "images/banner.png", "images/icon-192.png", "images/icon-512.png"];

self.addEventListener("install", (e) => e.waitUntil(caches.open(CACHE).then((c) => c.addAll(FILES)).then(() => self.skipWaiting())));
self.addEventListener("activate", (e) => e.waitUntil(
  caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim())
));
// Network first so edits show up straight away; fall back to the cache when offline.
// Only this site's own files are cached: bookings and sign-in always go live to the database.
self.addEventListener("fetch", (e) => {
  if (e.request.method !== "GET" || new URL(e.request.url).origin !== self.location.origin) return;
  e.respondWith(
    fetch(e.request).then((res) => { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(e.request, copy)); return res; })
      .catch(() => caches.match(e.request))
  );
});
