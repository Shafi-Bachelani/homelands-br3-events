// Lets the app open even with no internet. Bump the version when you change files.
const CACHE = "homelands-2026-11-16z";
const FILES = ["./", "index.html", "styles.css", "app.js", "data.js", "config.js", "vendor/supabase.js", "vendor/qrcode.min.js", "manifest.json", "images/logo.png", "images/banner.png", "images/icon-192.png", "images/icon-512.png", "images/footie.jpg", "images/footie-banner.jpg", "images/quran.jpg", "images/quran-banner.jpg"];

// cache: "reload" makes sure a new version saves fresh files, not ones the browser had lying around.
self.addEventListener("install", (e) => e.waitUntil(caches.open(CACHE).then((c) => c.addAll(FILES.map((f) => new Request(f, { cache: "reload" })))).then(() => self.skipWaiting())));
self.addEventListener("activate", (e) => e.waitUntil(
  caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim())
));
// The app opens straight away from the copy saved on the phone, and fetches fresh copies in the
// background for next time. A new version still shows at once: its new sw.js saves fresh files and
// the app reloads itself once. Only this site's own files are cached: bookings, sign-in and the
// Netlify functions always go live.
self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== self.location.origin || url.pathname.startsWith("/.netlify/")) return;
  const nav = e.request.mode === "navigate" && (url.pathname.endsWith("/") || url.pathname.endsWith("/index.html"));
  const key = nav ? "index.html" : e.request;
  const fresh = fetch(e.request).then((res) => {
    if (res.ok) { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(key, copy)); }
    return res;
  });
  e.respondWith(caches.match(key, { ignoreSearch: nav }).then((hit) => hit || fresh));
  e.waitUntil(fresh.catch(() => {}));
});

// Phone notifications: show each one, and open the app at the right screen when it's tapped.
self.addEventListener("push", (e) => {
  let m = {};
  try { m = e.data ? e.data.json() : {}; } catch { m = { body: e.data && e.data.text() }; }
  e.waitUntil(Promise.all([
    self.registration.showNotification(m.title || "Creating Our Homelands", {
      body: m.body || "", icon: "images/icon-192.png", badge: "images/icon-192.png",
      tag: m.tag || undefined, renotify: !!m.tag, data: { url: m.url || "" },
    }),
    self.navigator.setAppBadge ? self.navigator.setAppBadge().catch(() => {}) : null,
  ]));
});
self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const hash = e.notification.data?.url || "";
  e.waitUntil((async () => {
    const list = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    const open = list.find((c) => c.url.startsWith(self.registration.scope));
    if (open) { open.postMessage({ go: hash.replace(/^#/, "") }); return open.focus().catch(() => {}); }
    return self.clients.openWindow(new URL("./index.html" + hash, self.registration.scope).href);
  })());
});
