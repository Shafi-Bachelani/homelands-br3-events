// Community app – all screens. Static content lives in data.js; events, bookings,
// groups, football and accounts are shared through Supabase (see supabase/schema.sql).
(() => {
  const D = APP_DATA;
  const C = D.community;
  const $ = (sel, el = document) => el.querySelector(sel);
  const view = $("#view");
  // Read a password-reset link's details before Supabase tidies them out of the address.
  const AUTH_HASH = new URLSearchParams(location.hash.slice(1).replace(/^[^=&]*#/, ""));
  const RECOVERY = AUTH_HASH.get("type") === "recovery", AUTH_ERROR = AUTH_HASH.get("error_description");
  const sb = supabase.createClient(APP_CONFIG.supabaseUrl, APP_CONFIG.supabaseKey);

  // ---------- small things kept on this device ----------
  const STORE_KEY = "community-app-v1";
  const state = Object.assign({ likes: {}, reactions: {}, requests: [], messages: [], seenNotes: 0, guestTickets: [] }, load());
  function load() { try { return JSON.parse(localStorage.getItem(STORE_KEY)) || {}; } catch { return {}; } }
  function save() { try { localStorage.setItem(STORE_KEY, JSON.stringify(state)); } catch {} }

  // ---------- who is signed in ----------
  let me = null; // { id, email, name, role, family, credit, kitty_session }
  const isOrg = () => !!me && (me.role === "organiser" || me.role === "admin");
  const isAdmin = () => !!me && me.role === "admin";
  // New members wait for the admin's approval before they can book or post.
  const pending = () => !!me && me.approved === false;
  const eventsOnly = () => !!me && me.football === false && !me.family; // events-only membership, no football
  const APPLY_FORM = "https://form.jotform.com/262877635236064";
  const applyUrl = () => `${APPLY_FORM}?memberId=${encodeURIComponent(me.id)}&email=${encodeURIComponent(me.email || "")}`;
  async function loadMe() {
    const { data: { session } } = await sb.auth.getSession();
    if (!session) { me = null; return; }
    const { data } = await sb.from("profiles").select("*").eq("id", session.user.id).maybeSingle();
    me = data ? { ...data, email: session.user.email } : null;
  }

  // ---------- helpers ----------
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const bold = (s) => esc(s).replace(/\*\*(.+?)\*\*/g, "<b>$1</b>");
  // WhatsApp writes bold as *text*; the app uses **text**.
  const fromWhatsApp = (s) => s.replace(/(^|[^*])\*([^*\n]+?)\*(?!\*)/gm, "$1**$2**");
  const MONTHS = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
  const MONTHS_LONG = ["January","February","March","April","May","June","July","August","September","October","November","December"];
  const DAYS = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];
  const parseDay = (s) => { const [y, m, d] = s.split("-").map(Number); return new Date(y, m - 1, d); };
  const dayKey = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  const today = () => { const d = new Date(); d.setHours(0, 0, 0, 0); return d; };
  const money = (n) => (Number(n) < 0 ? "−£" : "£") + Math.abs(Number(n)).toFixed(2);
  const short = (d) => `${DAYS[d.getDay()]} ${d.getDate()} ${MONTHS[d.getMonth()]}`;
  const hhmm = (t) => String(t || "").slice(0, 5);
  const at = (day, t, addDays = 0) => { const d = parseDay(day); d.setDate(d.getDate() + addDays); const [h, m] = t.split(":").map(Number); d.setHours(h, m, 0, 0); return d; };
  const fbOpens = (ev) => at(ev.day, "13:00", -2);
  const fbPayBy = (ev) => at(ev.day, "23:00", -1);
  const fbCreditUntil = (ev) => at(ev.day, "18:00");
  const eventStart = (ev) => at(ev.day, hhmm(ev.time));
  const eventEnd = (ev) => { const d = eventStart(ev); d.setHours(d.getHours() + 3); return d; };
  function ago(dateStr) {
    const mins = Math.floor((Date.now() - new Date(dateStr).getTime()) / 6e4);
    if (mins < 1) return "just now";
    if (mins < 60) return `${mins}m ago`;
    if (mins < 1440) return `${Math.floor(mins / 60)}h ago`;
    const days = Math.floor(mins / 1440);
    if (days < 30) return `${days}d ago`;
    const mo = Math.floor(days / 30);
    return mo < 12 ? `${mo}mo ago` : `${Math.floor(mo / 12)}y ago`;
  }
  function agoLong(dateStr) {
    return ago(dateStr).replace(/(\d+)mo ago/, (_, n) => `${n} month${n > 1 ? "s" : ""} ago`).replace(/(\d+)d ago/, (_, n) => `${n} day${n > 1 ? "s" : ""} ago`);
  }
  function toast(msg) {
    const t = $("#toast"); t.textContent = msg; t.hidden = false;
    clearTimeout(toast.t); toast.t = setTimeout(() => (t.hidden = true), 2600);
  }
  function modal(html, onOpen) {
    $("#modalBody").innerHTML = html; $("#modal").hidden = false;
    onOpen && onOpen($("#modalBody"));
  }
  const closeModal = () => ($("#modal").hidden = true);
  $("#modal").addEventListener("click", (e) => { if (e.target.id === "modal" || e.target.classList.contains("close")) closeModal(); });
  // Unwraps a Supabase result, turning database errors into readable messages.
  async function q(p) {
    const { data, error } = await p;
    if (error) throw new Error(error.message.replace(/^.*?ERROR:\s*/, ""));
    return data;
  }
  const fail = (e) => toast(e.message || String(e));
  const loading = (el) => (el.innerHTML = '<div class="empty"><p class="muted">Loading…</p></div>');
  const needSignIn = (el, what) => {
    el.innerHTML = `<div class="empty"><h2>Sign in to ${esc(what)}</h2><p class="muted" style="font-size:17px;line-height:1.5">This part of the app is for members.</p>
      <button class="btn solid" data-go="account" style="margin-top:16px">Sign in or join</button></div>`;
  };
  function qr(el, text, size = 150) {
    el.innerHTML = "";
    if (window.QRCode) new QRCode(el, { text, width: size, height: size, colorDark: "#1b3d36", colorLight: "#ffffff" });
    else el.textContent = text;
  }

  async function share(title, text, link) {
    const url = link || location.href.split("#")[0];
    if (navigator.share) { try { await navigator.share({ title, text, url }); } catch {} return; }
    try { await navigator.clipboard.writeText(`${text} ${url}`); toast("Link copied"); } catch { toast(url); }
  }

  const ICON = {
    share: '<svg viewBox="0 0 24 24"><path d="M12 15V3M7 8l5-5 5 5M5 12v8h14v-8"/></svg>',
    phone: '<svg viewBox="0 0 24 24"><path d="M5 3h4l2 5-2.5 1.5a11 11 0 0 0 6 6L16 13l5 2v4a2 2 0 0 1-2 2A16 16 0 0 1 3 5a2 2 0 0 1 2-2z"/></svg>',
    pin: '<svg viewBox="0 0 24 24"><path d="M12 21s-7-6.2-7-11.5A7 7 0 0 1 19 9.5C19 14.8 12 21 12 21z"/><circle cx="12" cy="9.5" r="2.5"/></svg>',
    chev: '<svg viewBox="0 0 24 24" style="width:20px;height:20px"><path d="M9 6l6 6-6 6"/></svg>',
    left: '<svg viewBox="0 0 24 24"><path d="M15 5l-7 7 7 7"/></svg>',
    search: '<svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="7"/><path d="M20 20l-4-4"/></svg>',
    thumb: '<svg viewBox="0 0 24 24"><path d="M7 10v11H3V10zM7 10l4-7a2 2 0 0 1 3 2l-1 5h6a2 2 0 0 1 2 2.3l-1.4 7A2 2 0 0 1 17.6 21H7"/></svg>',
    camera: '<svg viewBox="0 0 24 24" class="fill"><path d="M9 4l-2 2H3v14h18V6h-4l-2-2zm3 13a4 4 0 1 1 0-8 4 4 0 0 1 0 8z"/></svg>',
    poll: '<svg viewBox="0 0 24 24"><path d="M6 20V12M12 20V4M18 20v-6"/></svg>',
    filter: '<svg viewBox="0 0 24 24"><path d="M3 6h18M6 12h12M10 18h4"/></svg>',
    cal: '<svg viewBox="0 0 24 24"><rect x="3" y="5" width="18" height="16" rx="2"/><path d="M8 3v4M16 3v4M8 12h.01M12 12h.01M16 12h.01M8 16h.01M12 16h.01"/></svg>',
    star: '<svg viewBox="0 0 24 24"><path d="M12 3l2.8 5.8 6.2.9-4.5 4.4 1 6.3L12 17.5 6.5 20.4l1-6.3L3 9.7l6.2-.9z"/></svg>',
    ball: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 7l4 3-1.5 4.5h-5L8 10z"/></svg>',
    user: '<svg viewBox="0 0 24 24"><circle cx="12" cy="8" r="4"/><path d="M4 21c0-4.4 3.6-7 8-7s8 2.6 8 7"/></svg>',
    tools: '<svg viewBox="0 0 24 24"><path d="M14.7 6.3a4 4 0 0 0-5.4 5.4L3 18l3 3 6.3-6.3a4 4 0 0 0 5.4-5.4l-2.5 2.5-2.4-.6-.6-2.4z"/></svg>',
    smallcal: '<svg viewBox="0 0 24 24" class="fill" style="width:18px;height:18px;vertical-align:-3px"><path d="M7 2v2H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V6a2 2 0 0 0-2-2h-2V2h-2v2H9V2zM5 9h14v11H5z"/></svg>',
  };
  const SOCIAL = {
    instagram: '<svg viewBox="0 0 24 24"><path d="M7 2h10a5 5 0 0 1 5 5v10a5 5 0 0 1-5 5H7a5 5 0 0 1-5-5V7a5 5 0 0 1 5-5zm0 2a3 3 0 0 0-3 3v10a3 3 0 0 0 3 3h10a3 3 0 0 0 3-3V7a3 3 0 0 0-3-3zm5 3.5a4.5 4.5 0 1 1 0 9 4.5 4.5 0 0 1 0-9zm0 2a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5zM17.5 5.5a1 1 0 1 1 0 2 1 1 0 0 1 0-2z"/></svg>',
    facebook: '<svg viewBox="0 0 24 24"><path d="M12 2a10 10 0 0 0-1.6 19.9V14.9H7.9V12h2.5V9.8c0-2.5 1.5-3.9 3.8-3.9 1.1 0 2.2.2 2.2.2v2.5h-1.3c-1.2 0-1.6.8-1.6 1.6V12h2.8l-.4 2.9h-2.3v7A10 10 0 0 0 12 2z"/></svg>',
    x: '<svg viewBox="0 0 24 24"><path d="M17.8 3h3.1l-6.8 7.7L22 21h-6.2l-4.9-6.3L5.3 21H2.2l7.2-8.3L2 3h6.4l4.4 5.8zm-1.1 16.2h1.7L7.4 4.7H5.6z"/></svg>',
    youtube: '<svg viewBox="0 0 24 24"><path d="M23 7.2a3 3 0 0 0-2.1-2.1C19 4.6 12 4.6 12 4.6s-7 0-8.9.5A3 3 0 0 0 1 7.2 31 31 0 0 0 .5 12a31 31 0 0 0 .5 4.8 3 3 0 0 0 2.1 2.1c1.9.5 8.9.5 8.9.5s7 0 8.9-.5a3 3 0 0 0 2.1-2.1 31 31 0 0 0 .5-4.8 31 31 0 0 0-.5-4.8zM9.8 15V9l5.7 3z"/></svg>',
    tiktok: '<svg viewBox="0 0 24 24"><path d="M4 2h16a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zm9.5 3v9.3a2.3 2.3 0 1 1-2.3-2.3h.4V9.4h-.4a4.9 4.9 0 1 0 4.9 4.9V9.6a6 6 0 0 0 3.4 1V8a3.4 3.4 0 0 1-3.4-3z"/></svg>',
  };

  // ---------- router ----------
  const TABS = ["events", "groups", "schedule", "about", "more"];
  const ROUTES = { about, home: about, events, groups, grouplist, chat, schedule, more, services, counselling, messages, notifications, account, football, admin, funds, guest };
  const PARENT = { grouplist: "groups", chat: "groups", services: "more", counselling: "more", football: "events", funds: "more", guest: null, account: null, admin: "more", messages: null, notifications: null };
  let lastTab = "events", seq = 0;

  function go(route) { if (location.hash.slice(1) === route) render(); else location.hash = route; }
  async function render() {
    const [route, arg] = decodeURIComponent(location.hash.slice(1) || "events").split(":");
    const fn = ROUTES[route] || events;
    if (TABS.includes(route)) lastTab = route;
    const active = TABS.includes(route) ? route : (PARENT[route] || lastTab);
    document.querySelectorAll("#tabbar button").forEach((b) => b.classList.toggle("active", b.dataset.tab === active));
    // Chat screens keep the logo header; their subhead link already goes back.
    $("#backBtn").hidden = TABS.includes(route) || ["home", "chat", "grouplist"].includes(route);
    $("#brand").hidden = !$("#backBtn").hidden;
    $("#bellDot").hidden = state.seenNotes >= D.announcements.length;
    const token = ++seq, alive = () => token === seq;
    view.innerHTML = "";
    view.scrollTo(0, 0);
    try { await fn(view, alive, arg); } catch (e) { if (alive()) view.innerHTML = `<div class="empty"><h2>Something went wrong</h2><p class="muted">${esc(e.message)}</p><button class="btn solid" data-go="${route}" style="margin-top:16px">Try again</button></div>`; }
  }
  // Re-renders the current screen in place, keeping the scroll position.
  async function refresh() { const y = view.scrollTop; await render(); view.scrollTo(0, y); }
  window.addEventListener("hashchange", render);
  document.querySelectorAll("#tabbar button").forEach((b) => b.addEventListener("click", () => go(b.dataset.tab)));
  document.addEventListener("click", (e) => { const g = e.target.closest("[data-go]"); if (g) { e.preventDefault(); go(g.dataset.go); } });
  $("#backBtn").addEventListener("click", () => (history.length > 1 ? history.back() : go("events")));

  // ---------- ABOUT US ----------
  function about(el) {
    const socials = Object.entries(C.socials).filter(([, url]) => url)
      .map(([k, url]) => `<a href="${esc(url)}" target="_blank" rel="noopener" aria-label="${k}">${SOCIAL[k] || ""}</a>`).join("");
    el.innerHTML = `
      <div class="about-head"><img src="images/logo.png" alt="">
        <div><h1>${esc(C.name)}</h1><div class="muted">${esc(C.tagline)}</div></div></div>
      <div class="about-body">
        <div class="meta">
          <div class="avatar" style="width:26px;height:26px;font-size:11px">${me ? esc(initials(me.name)) : "👤"}</div>
          <a href="#account">${me ? `Signed in as ${esc(me.name)}` : "Sign in or join"} ›</a><span class="sep">|</span>
          <a href="#" id="info">General Info ›</a>
        </div>
        <div class="actions">
          <button class="btn" id="invite">${ICON.share} Invite</button>
          <a class="btn solid" href="${esc(C.website)}" target="_blank" rel="noopener">Our website</a>
        </div>
        <p class="desc">${esc(C.description)}</p>
        ${C.whoWeAre?.length ? `<div class="card who"><h2>Who we are</h2>${C.whoWeAre.map((p) => `<p>${esc(p)}</p>`).join("")}</div>` : ""}
        <div class="list-row">
          <div><b>Get in Touch</b><span class="muted">${esc(C.contactName)}</span></div>
          <a class="btn small" href="https://wa.me/${esc(C.whatsapp)}" target="_blank" rel="noopener">Message</a>
        </div>
        <a class="list-row" href="tel:${esc(C.phone)}" style="color:inherit">
          <div><b>${esc(C.phone)}</b><span class="muted">Phone Number</span></div>${ICON.phone}
        </a>
        <a class="list-row" href="https://maps.google.com/?q=${encodeURIComponent(C.location)}" target="_blank" rel="noopener" style="color:inherit">
          <div><b>${esc(C.location)}</b><span class="muted">Location</span></div>${ICON.pin}
        </a>
        <div class="socials">${socials}</div>
        <p class="muted" style="font-size:14px;line-height:1.5;margin-top:18px">${DISCLAIMER}</p>
      </div>`;
    $("#invite", el).onclick = () => share(C.name, `Join ${C.name} – ${C.tagline}`);
    $("#info", el).onclick = (e) => { e.preventDefault(); modal(`<h2>General Info</h2><p style="line-height:1.5">${esc(C.generalInfo)}</p>`); };
  }
  const initials = (n) => String(n || "?").split(/\s+/).map((w) => w[0]).join("").slice(0, 2).toUpperCase();

  // ---------- EVENTS ----------
  // Weekly events are stored once; show the next date that hasn't finished yet.
  function nextWeekly(ev) {
    if (!ev.weekly || !ev.day) return;
    const d = parseDay(ev.day);
    while (eventEnd({ ...ev, day: dayKey(d) }) < new Date()) d.setDate(d.getDate() + 7);
    ev.day = dayKey(d);
  }
  // Membership is for people within HOME_MILES of the centre of BR3 (Beckenham).
  const HOME = { lat: 51.4078, lng: -0.0328 }, HOME_MILES = 5;
  // Miles from BR3 for a UK postcode: a number, false if the postcode doesn't exist, null if the lookup failed.
  async function milesFromHome(postcode) {
    try {
      const r = await fetch(`https://api.postcodes.io/postcodes/${encodeURIComponent(postcode)}`);
      if (r.status === 404) return false;
      const { result } = await r.json();
      if (!result || result.latitude == null) return null;
      const rad = (x) => (x * Math.PI) / 180, dLat = rad(result.latitude - HOME.lat), dLng = rad(result.longitude - HOME.lng);
      const a = Math.sin(dLat / 2) ** 2 + Math.cos(rad(HOME.lat)) * Math.cos(rad(result.latitude)) * Math.sin(dLng / 2) ** 2;
      return 3958.8 * 2 * Math.asin(Math.sqrt(a));
    } catch { return null; }
  }
  // Groups the signed-in member has signed up to (members-only chats).
  let joined = [];
  async function myGroups() {
    if (!me) return [];
    try { return (await q(sb.from("group_members").select("group_id").eq("user_id", me.id))).map((r) => r.group_id); } catch { return []; }
  }
  async function joinGroup(id) {
    try { await q(sb.from("group_members").insert({ group_id: id, user_id: me.id })); toast("You're signed up ✓"); go("grouplist"); } catch (e) { fail(e); }
  }
  async function events(el, alive, arg) {
    loading(el);
    await sb.rpc("expire_unpaid"); // so the booked numbers don't count places already released
    const [list, places, mine] = await Promise.all([
      q(sb.from("events").select("*")),
      q(sb.rpc("event_places")),
      me ? q(sb.from("bookings").select("id,event_id,status,code").eq("user_id", me.id).neq("status", "cancelled")) : [],
      myGroups(),
    ]).then(([l, p, m, g]) => { joined = g; return [l, p, m]; });
    if (!alive()) return;
    list.forEach(nextWeekly);
    const taken = Object.fromEntries(places.map((p) => [p.event_id, Number(p.taken)]));
    const myBk = Object.fromEntries(mine.map((b) => [b.event_id, b]));
    const now = new Date();
    // Upcoming first (soonest first), then dates to be confirmed, then past events (latest first).
    const rank = (e) => (!e.day ? 1 : eventEnd(e) < now ? 2 : 0);
    list.sort((a, b) => rank(a) - rank(b) || (rank(a) === 1 ? a.title.localeCompare(b.title) : rank(a) === 2 ? eventStart(b) - eventStart(a) : eventStart(a) - eventStart(b)));
    el.innerHTML = `<div class="events">
      ${offerBanner(list, false)}
      ${isOrg() ? `<a class="btn block" href="#admin">${ICON.tools} Add or manage events</a>` : ""}
      ${list.map((ev) => eventCard(ev, taken[ev.id] || 0, myBk[ev.id])).join("") || '<div class="empty"><h2>No events yet</h2></div>'}</div>`;
    el.querySelectorAll("[data-invite]").forEach((b) => (b.onclick = () => {
      shareEvent(list.find((x) => x.id === b.dataset.invite));
    }));
    el.querySelectorAll("[data-book]").forEach((b) => (b.onclick = () => bookSheet(list.find((x) => x.id === b.dataset.book), taken[b.dataset.book] || 0)));
    el.querySelectorAll("[data-ticket]").forEach((b) => (b.onclick = () => showTicket(b.dataset.ticket)));
    el.querySelectorAll("[data-join]").forEach((b) => (b.onclick = () => joinGroup(b.dataset.join)));
    const detail = (ev) => {
      const card = el.querySelector(`[data-event="${ev.id}"]`)?.closest("article");
      const act = card?.querySelector(".event-foot .go");
      modal(`${ev.image ? `<img class="event-pic modal-pic" src="${esc(ev.image)}" alt="">` : ""}<h2>${esc(ev.title)}</h2><p class="muted">${ev.day ? fmtEvent(ev) : "Date to be confirmed"}<br>${esc(ev.location || "")}</p><p style="line-height:1.5;white-space:pre-wrap">${esc(ev.details || "")}</p>
        <div class="form-actions">${act ? `<button class="btn solid block" id="dGo">${act.textContent}</button>` : ""}${isOrg() ? '<button class="btn block" id="dQr">QR code poster</button>' : ""}</div>`, (m) => {
        if (act) $("#dGo", m).onclick = () => { closeModal(); if (act.href) window.open(act.href, "_blank", "noopener"); else act.click(); };
        if (isOrg()) $("#dQr", m).onclick = () => posterModal(ev);
      });
    };
    el.querySelectorAll("[data-event]").forEach((b) => (b.onclick = () => detail(list.find((x) => x.id === b.dataset.event))));
    // A shared link or QR code opens that event straight away.
    const linked = arg && list.find((x) => x.id === arg);
    if (linked) { history.replaceState(null, "", location.pathname + "#events"); detail(linked); }
  }
  // A football game priced below the usual £6 gets a big banner on Events and Football.
  function offerBanner(games, onFootball) {
    const g = games.filter((e) => e.kind === "football" && e.day && Number(e.price) < 6 && eventEnd(e) > new Date()).sort((a, b) => eventStart(a) - eventStart(b))[0];
    if (!g) return "";
    const d = parseDay(g.day), when = `Friday ${d.getDate()} ${MONTHS_LONG[d.getMonth()]}`;
    return `<a class="offer" href="#football"><small>Launch offer</small><b>Book here for ${when} and get your place for just ${money(g.price).replace(".00", "")}</b>
      <span>${onFootball ? "Book below in the app. " : ""}Only for bookings made in the app.${onFootball ? "" : " Tap to book →"}</span></a>`;
  }
  function fmtEvent(ev) { if (!ev.day) return "Date to be confirmed"; const d = parseDay(ev.day); return `${DAYS[d.getDay()]} ${d.getDate()} ${MONTHS[d.getMonth()]} ${d.getFullYear()} | ${hhmm(ev.time).replace(/^0(\d)/, "$1")}`; }
  // An event can link elsewhere, e.g. to its debate in Let's Debate, instead of being booked here.
  const linkLabel = (url) => (/ourhomelands\.co\.uk\/debates\//.test(url) ? "Open in Let's Debate" : "Open link");
  const linkButton = (ev) => `<a class="go" href="${esc(ev.link)}" target="_blank" rel="noopener">${linkLabel(ev.link)}</a>`;
  const eventPic = (ev) => (ev.image ? `<img class="event-pic" src="${esc(ev.image)}" alt="" data-event="${ev.id}">` : "");
  function eventCard(ev, taken, mine) {
    if (!ev.day) return `<article class="card">${eventPic(ev)}
      <div class="event-body" data-event="${ev.id}" style="cursor:pointer">
        <div class="event-date tbc"><div class="d">TBC</div><div class="m">Date</div></div>
        <div><h2>${esc(ev.title)}</h2><p>Date to be confirmed</p>${ev.location ? `<p>${esc(ev.location)}</p>` : ""}
          <div class="pills"><span class="tag">${Number(ev.price) > 0 ? money(ev.price) : "Free"}</span><span class="tag">${ACCESS_TAG[ev.access] || "Members only"}</span></div></div>
      </div>
      <div class="event-foot"><button data-invite="${ev.id}">${ICON.share.replace("viewBox", 'style="width:20px;height:20px" viewBox')} Share</button>${ev.link ? linkButton(ev) : '<button class="off" disabled>Booking opens soon</button>'}</div>
    </article>`;
    const d = parseDay(ev.day), past = eventEnd(ev) < new Date(), left = Math.max(0, ev.capacity - taken);
    const fb = ev.kind === "football";
    const pills = `<div class="pills"><span class="tag">${fb ? `${money(ev.price)} or kitty` : Number(ev.price) > 0 ? money(ev.price) : "Free"}</span>
      <span class="tag">${ACCESS_TAG[ev.access] || "Members only"}</span>
      ${ev.weekly ? `<span class="tag gold">Every ${DAYS[d.getDay()]}</span>` : !past && !ev.link ? `<span class="tag ${left ? "" : "warn"}">${left ? `${left} of ${ev.capacity} places left` : "Full"}</span>` : ""}
      ${!past && !ev.group_id && !ev.link ? `<span class="tag gold">${taken} booked</span>` : ""}</div>`;
    let action;
    if (past) action = '<button class="off" style="color:var(--muted)" disabled>Event has ended</button>';
    else if (ev.link) action = linkButton(ev);
    else if (ev.group_id && !me) action = '<button class="go" data-go="account">Sign in to sign up</button>';
    else if (pending() && !fb) action = '<button class="off" style="color:var(--muted)" disabled>Bookable once approved</button>';
    else if (ev.group_id) action = joined.includes(ev.group_id) ? '<button class="go" data-go="groups">Signed up ✓ · Open chat</button>' : `<button class="go" data-join="${esc(ev.group_id)}">Sign up · Free</button>`;
    else if (fb) action = `<button class="go" data-go="football">${mine ? "Booked ✓ · Open" : "Open football"}</button>`;
    else if (mine) action = `<button class="go" data-ticket="${mine.code}">${mine.status === "waitlist" ? "On waitlist · Ticket" : "Booked ✓ · Ticket"}</button>`;
    else if (!me && ev.access === "members") action = '<button class="go" data-go="account">Members only · Sign in</button>';
    else action = `<button class="go" data-book="${ev.id}">${left ? "Book" : "Join waitlist"}</button>`;
    return `<article class="card">${eventPic(ev)}
      <div class="event-body" data-event="${ev.id}" style="cursor:pointer">
        <div class="event-date"><div class="d">${d.getDate()}</div><div class="m">${MONTHS[d.getMonth()]}</div></div>
        <div><h2>${esc(ev.title)}</h2><p>${fmtEvent(ev)}</p><p>${esc(ev.location)}</p>${pills}</div>
      </div>
      <div class="event-foot">${past ? "" : `<button data-invite="${ev.id}">${ICON.share.replace("viewBox", 'style="width:20px;height:20px" viewBox')} Invite</button>`}${action}</div>
    </article>`;
  }

  const ACCESS = { members: "Members only", public: "Members and invited guests", open: "Open to everyone (anyone with the link or QR code)" };
  const ACCESS_TAG = { members: "Members only", public: "Open to invited guests", open: "Open to everyone" };
  const accessOpts = (v) => Object.entries(ACCESS).map(([k, t]) => `<option value="${k}" ${k === v ? "selected" : ""}>${t}</option>`).join("");
  const PRIVACY = "We keep your name, email and bookings only to run the association's events. For events open to the public, guests' details (name, age, gender and email) are kept only for the event and deleted 7 days after it. Ask the organiser and we'll delete your details sooner.";
  const DISCLAIMER = `This organisation is an unincorporated association of people with similar values. To see our values, see About us in the app and visit <a href="https://www.ourhomelands.co.uk/" target="_blank" rel="noopener">ourhomelands.co.uk</a>.`;
  const eventLink = (ev) => `${location.origin}${location.pathname}#events:${ev.id}`;
  // A printable poster with a QR code that opens the event in the app.
  function posterModal(ev) {
    modal(`<button class="close" aria-label="Close">×</button>
      <div class="poster" style="text-align:center">
        <h2 style="margin:0 0 6px">${esc(ev.title)}</h2>
        <p class="muted" style="margin:0 0 14px">${ev.day ? fmtEvent(ev) : "Date to be confirmed"}${ev.location ? ` · ${esc(ev.location)}` : ""}<br>${Number(ev.price) > 0 ? money(ev.price) : "Free"} · ${ACCESS_TAG[ev.access] || "Members only"}</p>
        <div id="pq" style="display:inline-block;background:#fff;padding:12px;border-radius:12px"></div>
        <p style="font-size:18px;margin:12px 0 0"><b>Scan to book</b></p>
      </div>
      ${ev.access === "open" ? "" : `<p class="note">This event is ${ev.access === "public" ? "for members and guests with an invite code" : "for members only"}, so people who scan it will need ${ev.access === "public" ? "an invite code" : "to be members"}. Choose "Open to everyone" in Organiser tools to let anyone book.</p>`}
      <div class="form-actions"><button class="btn solid block" id="pDl">Save QR code image</button><button class="btn block" id="pSh">Share the link</button></div>`, (m) => {
      qr($("#pq", m), eventLink(ev), 240);
      $("#pDl", m).onclick = () => {
        const c = $("#pq canvas", m), img = $("#pq img", m);
        const a = document.createElement("a"); a.download = `${ev.title.replace(/[^a-z0-9]+/gi, "-")}-qr.png`;
        a.href = c ? c.toDataURL("image/png") : img?.src; if (a.href) a.click();
      };
      $("#pSh", m).onclick = () => shareEvent(ev);
    });
  }
  const shareEvent = (ev) => share(ev.title, `${ev.title} – ${ev.day ? fmtEvent(ev) : "date to be confirmed"}. Book here:`, eventLink(ev));

  function bookSheet(ev, taken) {
    const left = ev.capacity - taken, price = Number(ev.price);
    const placeOpts = [1, 2, 3, 4, 5, 6].map((n) => `<option>${n}</option>`).join("");
    const guest = !me;
    modal(`<h2>Book: ${esc(ev.title)}</h2>
      <p class="muted">${fmtEvent(ev)} · ${esc(ev.location)}<br>${price > 0 ? `${money(price)} per place, paid to the organiser.` : "Free."} ${left > 0 ? `${left} places left.` : "It's full, so you'll join the waitlist."}</p>
      ${guest ? `<p class="note">${ev.access === "open" ? "Anyone can ask to book this event. An organiser checks each request before it's confirmed." : "Booking as a guest needs an invite code from a member."} Members, <a href="#account" data-close>sign in</a> first.</p>
        <label>Email</label><input id="ge" type="email" autocomplete="email">
        ${ev.access === "open" ? "" : '<label>Invite code</label><input id="gc" placeholder="e.g. INV-7Q4KA" style="text-transform:uppercase">'}`
        : ""}
      <label>Name</label><input id="gn" autocomplete="name" value="${guest ? "" : esc(me.name || "")}">
      <label>Age</label><input id="ga" type="number" min="1" max="120" inputmode="numeric">
      <label>Male or female</label><div class="radios" id="gg">
        <label class="check"><input type="radio" name="gg" value="Male"> Male</label>
        <label class="check"><input type="radio" name="gg" value="Female"> Female</label></div>
      <label class="check" id="parentRow" hidden><input type="checkbox" id="parent"> I'm under 16 and my parent or guardian has given permission</label>
      <label>Places</label><select id="pl">${placeOpts}</select>
      <p class="muted" style="font-size:14px;line-height:1.5">${DISCLAIMER} ${PRIVACY}</p>
      <div class="form-actions"><button class="btn solid block" id="ok">${left > 0 ? "Book" : "Join waitlist"}</button></div>`, (m) => {
      m.querySelectorAll("[data-close]").forEach((a) => (a.onclick = closeModal));
      const young = () => { const a = Number($("#ga", m).value); return a > 0 && a < 16; };
      $("#ga", m).oninput = () => ($("#parentRow", m).hidden = !young());
      $("#ok", m).onclick = async () => {
        const places = Number($("#pl", m).value);
        const name = $("#gn", m).value.trim(), age = Number($("#ga", m).value) || null, gender = m.querySelector('[name="gg"]:checked')?.value || "";
        if (!name) return toast("Please add your name");
        if (!age) return toast("Please add your age");
        if (!gender) return toast("Please choose male or female");
        if (young() && !$("#parent", m).checked) return toast("Under 16s need permission from a parent or guardian to book");
        try {
          $("#ok", m).disabled = true;
          let code;
          if (guest) {
            const r = await q(sb.rpc("guest_book", { p_event: ev.id, p_name: name, p_age: age,
              p_email: $("#ge", m).value.trim(), p_code: $("#gc", m)?.value || "", p_places: places }));
            code = r[0].code; state.guestTickets.push(code); save();
          } else {
            code = (await q(sb.rpc("book_event", { p_event: ev.id, p_places: places }))).code;
          }
          await q(sb.rpc("set_booking_details", { p_code: code, p_name: name, p_age: age, p_gender: gender, p_parent: young() ? $("#parent", m).checked : null })).catch(() => {});
          closeModal(); await refresh(); showTicket(code);
        } catch (e) { $("#ok", m).disabled = false; fail(e); }
      };
    });
  }

  async function showTicket(code, recheck) {
    try {
      const [t] = await q(sb.rpc("ticket", { p_code: code }));
      if (!t) return toast("Ticket not found");
      modal(`<h2>${esc(t.title)}</h2>
        <p class="muted">${short(parseDay(t.day))} · ${hhmm(t.time)} · ${esc(t.location)}</p>
        <div class="ticket">
          <div class="stamp ${t.status}">${t.status === "waitlist" ? "On the waitlist" : t.status === "cancelled" ? "Cancelled" : t.status === "pending" ? "Waiting for approval" : t.status === "declined" ? "Not approved" : t.checked_in ? "Checked in" : "Confirmed"}</div>
          <div class="qr" id="qr"></div>
          <div class="code">${esc(t.code)}</div>
          <div>${esc(t.display_name)} · ${t.places} place${t.places > 1 ? "s" : ""}</div>
        </div>
        ${!t.paid && Number(t.amount) > 0 && t.status === "booked" ? `<p class="note">${money(t.amount)} still to pay.</p><button class="btn solid block" data-pay="${esc(t.code)}">Pay ${money(t.amount)} by card</button>` : ""}
        ${t.status === "pending" ? '<p class="note">Thanks, your request has been received. An organiser will check it, and your QR ticket appears here once it\'s approved. Open Schedule on this phone to check.</p>'
          : t.status === "declined" ? '<p class="note">Sorry, we can\'t offer you a place at this event.</p>'
          : '<p class="muted" style="font-size:14px">Show this at the door. A screenshot works too.</p>'}`, (m) => { if (["booked", "cancelled"].includes(t.status)) qr($("#qr", m), t.code); });
      // If they paid by card but didn't come back through Square's return link, check with Square now.
      if (!t.paid && Number(t.amount) > 0 && !recheck) payApi({ code: t.code, confirm: true }).then((r) => { if (r.paid) { toast("Payment received, thank you!"); showTicket(t.code, true); } }).catch(() => {});
    } catch (e) { fail(e); }
  }

  // ---------- FUNDS ----------
  const FUND_NAME = { kitty: "Kitty", events: "Events", credits: "Credits" };
  const fundStats = (fs) => `<div class="stats"><div><span>Kitty fund</span><b>${money(fs.kitty)}</b></div><div><span>Events fund</span><b>${money(fs.events)}</b></div><div><span>Credits</span><b>${money(fs.credits || 0)}</b></div></div>`;
  const FUND_INFO = `<details class="info"><summary><b>What the three funds are</b></summary>
        <p><b>Kitty fund</b> runs the football. £15 kitty contributions and pay-and-play payments go in, and it pays the pitch hire and card fees. The kitty restarts when the fund drops below £150 or after 5 games, and anything over £100 then moves to the events fund.</p>
        <p><b>Events fund</b> is built up from the kitty and from owed money that's been paid. It's used for small come-together events and to buy new footballs and other things that keep the football going.</p>
        <p><b>Credits</b> is money members have paid but not used: they paid but didn't play, or cancelled before Friday 6pm. It still belongs to them. When they pay for a game from their credit, it moves from credits into the kitty fund. Advance payments are only taken through the app, which records every credit added or used, so the credits fund always matches the total credit on members' accounts.</p>
      </details>`;
  const ledgerTable = (rows) => `<div class="scroll"><table><thead><tr><th>Date</th><th>Fund</th><th>Reason</th><th class="amt">Change</th><th class="amt">Balance</th></tr></thead><tbody>${rows.map((l) => `<tr><td>${short(parseDay(l.on_date))}</td><td>${FUND_NAME[l.fund] || ""}</td><td>${esc(l.what)}</td><td class="amt ${Number(l.amount) < 0 ? "neg" : ""}">${money(l.amount)}</td><td class="amt">${money(l.balance)}</td></tr>`).join("")}</tbody></table></div>`;

  async function funds(el, alive, which = "") {
    if (!me) return needSignIn(el, "see the funds");
    loading(el);
    let lq = sb.from("ledger").select("*").order("id", { ascending: false }).limit(300);
    if (FUND_NAME[which]) lq = lq.eq("fund", which);
    const [fs, rows, accts] = await Promise.all([q(sb.from("fund_state").select("*").single()), q(lq), isOrg() ? q(sb.from("profiles").select("credit")) : []]);
    const onAccounts = Math.round(accts.reduce((t, r) => t + Number(r.credit || 0), 0) * 100) / 100;
    if (!alive()) return;
    el.innerHTML = `<div class="events"><div class="card fb"><h2>Funds</h2>
      ${fundStats(fs)}
      ${isOrg() ? (onAccounts === Math.round(Number(fs.credits || 0) * 100) / 100 ? `<p class="note">Credits tally ✓ The credits fund matches the ${money(onAccounts)} of credit on members' accounts.</p>`
        : `<p class="note">Credits don't tally: members' accounts hold ${money(onAccounts)} but the credits fund shows ${money(fs.credits || 0)}.</p>`) : ""}
      ${FUND_INFO.replace("<details ", "<details open ")}
      <h3>History</h3>
      <div class="seg">${[["", "All"], ["kitty", "Kitty"], ["events", "Events"], ["credits", "Credits"]].map(([k, v]) => `<button class="${k === (FUND_NAME[which] ? which : "") ? "on" : ""}" data-f="${k}">${v}</button>`).join("")}</div>
      ${rows.length ? ledgerTable(rows) : '<p class="muted">No changes yet. Every game\'s accounts and every fund change will be listed here.</p>'}
    </div></div>`;
    el.querySelectorAll("[data-f]").forEach((b) => (b.onclick = () => go(b.dataset.f ? "funds:" + b.dataset.f : "funds")));
  }

  // ---------- FOOTBALL ----------
  const PITCH = 18; // players on one pitch
  const RISK = `<label class="check risk"><input type="checkbox" id="riskOk"> I agree that I play at my own risk</label>`;
  // The booking blurb from the WhatsApp list, kept on the football page.
  // The deadline for paying for a place: Thursday 11pm, or 30 minutes after booking if that's later.
  const placePayBy = (ev, createdAt) => new Date(Math.max(fbPayBy(ev), new Date(createdAt).getTime() + 30 * 6e4));
  const payByText = (ev, createdAt) => {
    const d = placePayBy(ev, createdAt);
    return d > fbPayBy(ev) ? `by ${d.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" })} (within 30 minutes of booking)` : "by Thursday 11pm";
  };
  // A member sends their friend a link to pay for their own place.
  function guestLinkModal(ev, b) {
    const guestName = b.display_name.replace(/ \([^)]*\)$/, "");
    const url = `${location.origin}${location.pathname}#guest:${b.code}`;
    const text = `Hi ${guestName}, I've booked you in for football on ${short(parseDay(ev.day))} at ${hhmm(ev.time)}. Please pay ${money(b.amount)} for your place ${payByText(ev, b.created_at)}, or it's released:`;
    modal(`<button class="close" aria-label="Close">×</button><h2>Send ${esc(guestName)} a payment link</h2>
      <p class="muted">${esc(guestName)} pays ${money(b.amount)} on the link. Their payment shows your name and theirs, and they show as Paid on the roster once it's in. If it isn't paid ${payByText(ev, b.created_at)}, their place is released.</p>
      <div class="form-actions"><button class="btn solid block" id="glSend">${ICON.share} Send the link</button>
        <button class="btn block" id="glCopy" style="margin-top:10px">Copy the link</button></div>`, (m) => {
      $("#glSend", m).onclick = async () => {
        if (navigator.share) { try { await navigator.share({ title: "Football payment", text, url }); closeModal(); } catch {} return; }
        location.href = `https://wa.me/?text=${encodeURIComponent(`${text} ${url}`)}`;
      };
      $("#glCopy", m).onclick = async () => { try { await navigator.clipboard.writeText(`${text} ${url}`); toast("Link copied. Paste it to your friend"); } catch { toast(url); } };
    });
  }
  // The page a guest opens from their payment link. No sign-in needed.
  async function guest(el, alive, code) {
    loading(el);
    let g;
    await sb.rpc("expire_unpaid"); // releases unpaid places that are past their deadline
    try { g = await payApi({ code, info: true }); } catch (e) { g = null; }
    if (!alive()) return;
    if (!g || g.status !== "booked") {
      el.innerHTML = `<div class="empty"><h2>This place is no longer booked</h2><p class="muted" style="font-size:17px;line-height:1.5">It wasn't paid in time, or it was removed. Ask the friend who booked you to add you again.</p></div>`;
      return;
    }
    const ev = g.event, open = new Date() < placePayBy(ev, g.created_at);
    el.innerHTML = `<div class="events"><div class="card fb">
      <h2>${esc(ev.title || "Football")}</h2><p class="muted">${short(parseDay(ev.day))} · ${hhmm(ev.time)}</p>
      <p style="font-size:18px"><b>${esc(g.guest)}</b>, booked by <b>${esc(g.member)}</b></p>
      ${g.paid ? `<p class="note">Paid, thank you. See you on the pitch!</p>`
        : open ? `<p class="note">Please pay <b>${money(g.amount)}</b> ${payByText(ev, g.created_at)}, or your place is released.</p>
          <button class="btn solid block" data-pay="${esc(code)}" data-guest="1">Pay ${money(g.amount)} by card</button>`
        : `<p class="note">The time to pay has passed, so this place is being released.</p>`}
      <p class="muted">6-a-side at Goals, Beckenham, Elmers End Road, BR3 4EJ. Get together at ${hhmm(ev.time)} next to Pitch 1. Players must be 16 or over, and play is at your own risk.</p>
    </div></div>`;
  }
  function footballInfo(ev, fs) {
    const t = hhmm(ev.time);
    return `<details class="card fb info"><summary><b>How Friday football works</b><span class="muted">Times, rules and prices</span></summary>
      <p><b>6-a-side at Goals, Beckenham</b>, this Friday ${t} till 11pm. This is game ${fs.games_played + 1} in kitty ${fs.session_no}, for up to 5 consecutive kitty games. A new kitty starts when the kitty fund drops below £150 or after 5 games, whichever is sooner.</p>
      <p><b>Address:</b> Elmers End Road, BR3 4EJ. On-site car park, next to Elmers End station and numerous bus stops.</p>
      <p><b>Get together at ${t}</b> next to Pitch 1. Pitch booked from 9:30pm.</p>
      <ul>
        <li>Everyone welcome, from semi-pro to two left feet.</li>
        <li>Players from 16 up. We decide on ability, not age.</li>
        <li>Randomised, fair teams. Games of 11 minutes at most.</li>
        <li>To keep things fair, each person can add only 1 friend. They show on the roster with your name in brackets. Exceptions: dads for their sons, and sons for their dads (ask the organiser).</li>
        <li>No game is free: £6 pay and play, or £15 to join the kitty fund.${Number(ev.price) < 6 ? ` <b>Launch offer: ${money(ev.price).replace(".00", "")} pay and play for this game when you book in the app. Friends you add pay the full £6.</b>` : ""}</li>
        <li>No booking space? Come for the fun. If someone is late you'll be given their spot.</li>
        <li>Come early to guarantee play. No play is guaranteed if you're late.</li>
        <li>Can't make it? Remove yourself here, and everyone below moves up a place.</li>
      </ul>
      <h3>Guaranteed play and what to expect</h3>
      <p>Guaranteed play for places 1 to ${PITCH}, so long as you arrive on time. If we reach 28 or more players, we book a second pitch and accept a maximum of 30. If we reach 36, we play sudden death games on two pitches, with the last 10-minute game between the two teams with the most 2-goal wins.</p>
      <p>If you are late, your place may be given to someone who didn't book but arrived on time, even if you've paid. Your payment will be credited to your account.</p>
      <p class="note"><b>Play is at your own risk.</b></p>
      <p class="muted">This is not for profit. Any money over costs is used to bring us all together on a more social footing.</p>
    </details>`;
  }
  // Signed out: anyone can see how many are booked for the next game, then sign in to book.
  async function footballGuest(el, alive) {
    loading(el);
    await sb.rpc("expire_unpaid");
    const [games, places] = await Promise.all([
      q(sb.from("events").select("*").eq("kind", "football").not("day", "is", null).order("day")),
      q(sb.rpc("event_places")),
    ]);
    if (!alive()) return;
    const ev = games.find((g) => eventEnd(g) > new Date());
    const n = ev ? Number((places.find((p) => p.event_id === ev.id) || {}).taken || 0) : 0;
    needSignIn(el, "book football");
    if (ev) el.insertAdjacentHTML("afterbegin", `<div class="events"><div class="card fb"><h2>${esc(ev.title)}</h2><p class="muted">${fmtEvent(ev)} · ${esc(ev.location)}</p>
      <p style="font-size:20px"><b>${n} booked</b> so far${n < ev.capacity ? `, ${ev.capacity - n} places left` : ", it's full"}.</p></div></div>`);
  }
  async function football(el, alive) {
    if (!me) return footballGuest(el, alive);
    if (eventsOnly()) { el.innerHTML = `<div class="empty"><h2>Friday football</h2><p class="muted" style="font-size:17px;line-height:1.5">Your membership is for events only. If you'd like to play football, ask an organiser to add it to your membership.</p></div>`; return; }
    loading(el);
    await sb.rpc("expire_unpaid");
    const now = new Date();
    const [allGames, fs, posts] = await Promise.all([
      q(sb.from("events").select("*").eq("kind", "football").not("day", "is", null).order("day")),
      q(sb.from("fund_state").select("*").single()),
      q(sb.from("accounts_posts").select("*").order("created_at", { ascending: false }).limit(1)),
    ]);
    const games = allGames.filter((g) => g.day);
    // the game to show: the next one not yet finished, else the last one still awaiting accounts
    const ev = games.find((g) => eventEnd(g) > now) || [...games].reverse().find((g) => !g.accounts_posted) || null;
    const awaiting = games.filter((g) => !g.accounts_posted && eventEnd(g) <= now);
    const bookings = ev ? await q(sb.from("bookings").select("*").eq("event_id", ev.id).neq("status", "cancelled").order("created_at")) : [];
    const removed = ev ? (await q(sb.from("football_removed").select("event_id").eq("event_id", ev.id).eq("user_id", me.id)).catch(() => [])).length > 0 : false;
    if (!alive()) return;
    await loadMe();
    const kitty = me.kitty_session === fs.session_no;
    const week = fs.games_played + 1;
    const P = ev ? Number(ev.price) : 6, P$ = money(P).replace(".00", "");
    // Friends always pay the full pay and play price: offer prices are for members.
    const F = Math.max(P, 6), F$ = money(F).replace(".00", "");

    let top = "", you = "", players = "";
    if (!ev) {
      top = `<div class="card fb"><h2>No game scheduled</h2><p class="muted">The next Friday game hasn't been added yet.</p></div>`;
    } else {
      const opens = fbOpens(ev), payBy = fbPayBy(ev), creditUntil = fbCreditUntil(ev), start = eventStart(ev);
      const phase = now < opens ? "closed" : now < payBy ? "open" : now < creditUntil ? "locked" : now < start ? "late" : "played";
      const PH = { closed: "Booking opens Wednesday 1pm", open: "Booking open", locked: "Pay deadline passed", late: "Cancellations no longer give credit", played: "Game played" };
      const steps = [["Wed 1pm", "Booking opens", opens, "open"], ["Thu 11pm", "Unpaid places removed", payBy, "locked"], ["Fri 6pm", "Last chance to cancel for credit", creditUntil, "late"], [`Fri ${hhmm(ev.time)}`, `Game ${week} of up to 5 in kitty ${fs.session_no}`, start, "played"]];
      top = `<div class="card fb">
        <div class="row" style="justify-content:space-between;flex-wrap:wrap"><h2>${esc(ev.title)}</h2><span class="tag">${PH[phase]}</span></div>
        <p class="muted">${fmtEvent(ev)} · ${esc(ev.location)}</p>
        <div class="steps">${steps.map(([t, x, d, p]) => `<div class="${phase === p ? "now" : ""}"><b>${t} · ${d.getDate()} ${MONTHS[d.getMonth()]}</b>${x}</div>`).join("")}</div>
      </div>`;

      const mine = bookings.find((b) => b.user_id === me.id);
      if (mine && !mine.paid && mine.square_order_id) payApi({ code: mine.code, confirm: true }).then((r) => { if (r.paid && alive()) { toast("Payment received, thank you!"); refresh(); } }).catch(() => {});
      const pills = `<div class="pills"><span class="tag ${kitty ? "gold" : ""}">${kitty ? `Kitty member, kitty ${fs.session_no}` : "Ordinary member"}</span>
        ${me.family ? '<span class="tag">Family: pays by transfer</span>' : ""}<span class="tag">${money(me.credit || 0)} credit</span></div>`;
      let body;
      if (mine) {
        const st = mine.charge === "covered" ? "Booked, covered by your kitty" : mine.paid ? (mine.method === "credit" ? "Booked, paid with credit" : mine.method === "card" ? "Booked and paid by card" : "Booked and paid") : "Booked, not paid yet";
        body = `<p><b>${st}.</b> You're number ${bookings.indexOf(mine) + 1} on the list.</p>
          ${!mine.paid ? `<p class="note">Please pay <b>${money(mine.amount)}</b> ${new Date(mine.created_at) > payBy ? "within <b>30 minutes</b> of booking" : "before <b>Thursday 11pm</b>"}, or your place is released and you can't rebook this game.${me.family ? " Pay the organiser by bank transfer." : " Pay by card here, or by bank transfer to the organiser."}</p>
            ${me.family ? "" : `<button class="btn solid" data-pay="${esc(mine.code)}" style="margin-bottom:10px">Pay ${money(mine.amount)} by card</button>`}` : ""}
          ${me.family && mine.method === "transfer" ? `<p class="muted">As family you're added automatically each week. If you can't come, remove yourself to free your place.</p>`
            : mine.charge === "payg" && mine.paid ? `<p class="muted">${now < creditUntil ? `Remove yourself before Friday 6pm and your ${P$} becomes credit for your next game.` : "It's after Friday 6pm, so removing yourself now won't give credit."}</p>` : ""}
          <button class="btn" id="cancel">Remove me</button>`;
      } else if (pending()) body = `<p class="note">You can book once the admin has approved your membership.</p>`;
      else if (removed) body = `<p class="note">Your place was released because it wasn't paid in time, so you can't rebook this game. Message the organiser if something went wrong.</p>`;
      else if (phase === "closed") body = `<p>Booking for this game opens <b>Wednesday at 1pm</b>.</p>`;
      else if (phase === "played") body = `<p>This game has been played.</p>`;
      else if (bookings.length >= ev.capacity) body = `<p>All ${ev.capacity} places are taken.</p>`;
      else if (kitty) body = `${RISK}<p class="muted">Your kitty membership covers this game.</p><button class="btn solid" data-choice="payg">Book my place</button>`;
      else {
        const six = Number(me.credit) >= P ? `Use ${P$} of my credit` : me.family ? `${P$} by transfer` : `Pay as you play · ${P$}`;
        const due = !me.family && Number(me.credit) < P;
        body = `${RISK}<p class="muted">How do you want to pay for this game?${due && phase === "open" ? " Pay by Thursday 11pm or your place is released, and you won't be able to rebook." : due ? " The pay deadline has passed, so pay by card straight away: unpaid places are released after 30 minutes." : ""}</p>
          <div class="choices">
            <div><b>${P$} · this game</b><span class="muted">Pay as you play, just this Friday.${P < 6 ? " Launch offer price." : ""}</span><button class="btn solid small" data-choice="payg">${six}</button></div>
            <div><b>£15 · kitty</b><span class="muted">Every game until the kitty resets. This is week ${week} of up to 5.</span><button class="btn small" id="kittyAsk">Choose the kitty</button></div>
          </div>`;
      }
      // One friend per member per game, shown on the roster as "Friend (Member)".
      const friend = bookings.find((b) => b.booked_by === me.id);
      const canAdd = !pending() && !removed && (phase === "open" || phase === "locked" || phase === "late");
      const friendBox = friend ? `<h3>Your friend</h3><p><b>${esc(friend.display_name)}</b> is number ${bookings.indexOf(friend) + 1} on the list${friend.paid ? (friend.method === "credit" ? ", paid from your credit." : ", paid.") : "."}</p>
          ${friend.paid ? "" : `<p class="note">Please pay <b>${money(friend.amount)}</b> for your friend ${new Date(friend.created_at) > payBy ? "within <b>30 minutes</b>" : "before <b>Thursday 11pm</b>"}, or their place is released.${me.family ? " Pay the organiser by bank transfer." : ""}</p>
            ${me.family ? "" : `<button class="btn solid" data-pay="${esc(friend.code)}" style="margin-bottom:10px">Pay ${money(friend.amount)} for your friend</button>`}
            ${!me.family && Number(me.credit) >= Number(friend.amount) ? `<button class="btn" id="friendCredit" style="margin-bottom:10px">Use ${money(friend.amount)} of my credit</button>` : ""}
            <button class="btn" id="friendLink" style="margin-bottom:10px">${ICON.share} Send your friend a payment link</button>`}
          <button class="btn" id="cancelFriend">Remove my friend</button>`
        : canAdd && bookings.length < ev.capacity ? `<h3>Bring a friend</h3><p class="muted">You can add one friend per game. ${me.family ? `Pay their ${F$} by transfer, or send them a payment link` : `Pay their ${F$} yourself${Number(me.credit) >= F ? ", by card or from your credit," : ""} or send them a payment link`}.</p><button class="btn" id="addFriend">Add a friend</button>` : "";
      you = `<div class="card fb"><h2>You</h2>${pills}${body}${friendBox}</div>`;

      const paidCount = bookings.filter((b) => b.paid).length;
      players = `<div class="card fb"><div class="row" style="justify-content:space-between"><h2>Roster</h2><span class="muted">${bookings.length} booked · ${paidCount} paid</span></div>
        <p class="muted">Everyone on the list for this game. If someone drops out or is removed for not paying, everyone below moves up a place. Places 1 to ${PITCH} are guaranteed play if you arrive on time.</p>
        <ol class="players">${bookings.map((b, i) => `<li value="${i + 1}"><span>${esc(b.display_name)}${b.user_id === me.id || b.booked_by === me.id ? " ★" : ""}</span>${b.charge === "covered" || b.charge === "kitty" ? '<span class="tag gold">Kitty</span>' : ""}${b.paid ? '<span class="tag">Paid</span>' : '<span class="tag warn">Unpaid</span>'}${b.checked_in ? '<span class="tag">Here</span>' : ""}</li>`).join("") || '<li class="muted">No one has booked yet.</li>'}</ol></div>`;
    }

    const fund = `<div class="card fb"><h2>Football funds</h2>
      ${fundStats(fs)}
      <p class="muted">Kitty ${fs.session_no}: ${fs.games_played} game${fs.games_played === 1 ? "" : "s"} played of up to a maximum of 5 consecutive games.</p>
      ${FUND_INFO}
      ${posts[0] ? `<h3>Latest accounts · ${short(new Date(posts[0].created_at))}</h3><pre class="acc">${esc(posts[0].body)}</pre>${(posts[0].images || []).map((src) => `<img class="receipt" src="${esc(src)}" alt="Receipt">`).join("")}` : '<p class="muted">The organiser\'s confirmed accounts appear here after each game.</p>'}
      <div class="form-actions"><button class="btn block" data-go="funds">See all fund changes</button></div>
    </div>`;

    el.innerHTML = `<div class="events">${offerBanner(allGames, true)}${top}${ev ? footballInfo(ev, fs) : ""}${you}${players}${fund}${isOrg() ? '<div id="org"></div>' : ""}</div>`;

    const riskOk = () => { const r = $("#riskOk", el); if (r && r.checked) return true; toast("Please tick to confirm you play at your own risk"); return false; };
    el.querySelectorAll("[data-choice]").forEach((b) => (b.onclick = () => riskOk() && bookFootball(ev, b.dataset.choice)));
    const af = $("#addFriend", el);
    if (af) af.onclick = () => modal(`<h2>Add a friend</h2>
      <p class="muted">They'll appear on the roster as <b>Their name (${esc(me.name)})</b>. Pay their ${F$} yourself${me.family ? " by bank transfer" : ""}, or send them a payment link. If it isn't paid ${payByText(ev, new Date())}, their place is released.</p>
      <label>Your friend's name</label><input id="fName" maxlength="40" placeholder="Their full name">
      <label class="check"><input type="checkbox" id="fRisk"> My friend is 16 or over and agrees they play at their own risk</label>
      <label>Who pays?</label>
        <label class="check"><input type="radio" name="fPay" value="card" checked> I'll pay ${F$} ${me.family ? "by bank transfer" : "by card"}</label>
        ${!me.family && Number(me.credit) >= F ? `<label class="check"><input type="radio" name="fPay" value="credit"> I'll use ${F$} of my credit (${money(me.credit)} available)</label>` : ""}
        <label class="check"><input type="radio" name="fPay" value="link"> Send my friend a payment link</label>
      <div class="form-actions"><button class="btn solid block" id="fGo">Add to the roster · ${F$}</button></div>`, (m) => {
      $("#fName", m).focus();
      $("#fGo", m).onclick = async () => {
        if (!$("#fName", m).value.trim()) return toast("Enter your friend's name");
        if (!$("#fRisk", m).checked) return toast("Please tick to confirm your friend plays at their own risk");
        try {
          const how = m.querySelector('[name="fPay"]:checked')?.value;
          const b = await q(sb.rpc("book_friend", { p_event: ev.id, p_name: $("#fName", m).value.trim(), p_risk: true, p_credit: how === "credit", p_link: how === "link" }));
          await loadMe();
          if (how === "link" && !b.paid) { refresh(); return guestLinkModal(ev, b); }
          closeModal(); toast(b.paid ? (b.method === "credit" ? `Your friend is on the roster ✓ Paid ${F$} from your credit` : "Your friend is on the roster ✓") : `Friend added. Pay their ${F$} to keep the place`); refresh();
        } catch (e) { fail(e); }
      };
    });
    const fc = $("#friendCredit", el);
    if (fc) fc.onclick = async () => {
      try { fc.disabled = true; await q(sb.rpc("pay_friend_credit", { p_id: bookings.find((b) => b.booked_by === me.id).id })); toast(`Paid from your credit ✓`); await loadMe(); refresh(); }
      catch (e) { fc.disabled = false; fail(e); }
    };
    const fl = $("#friendLink", el);
    if (fl) fl.onclick = () => guestLinkModal(ev, bookings.find((b) => b.booked_by === me.id));
    const cf = $("#cancelFriend", el);
    if (cf) cf.onclick = async () => {
      if (cf.dataset.sure !== "1") { cf.dataset.sure = "1"; cf.textContent = "Tap again to remove your friend"; return; }
      try { toast(await q(sb.rpc("cancel_booking", { p_id: bookings.find((b) => b.booked_by === me.id).id }))); await loadMe(); refresh(); } catch (e) { fail(e); }
    };
    const ka = $("#kittyAsk", el);
    if (ka) ka.onclick = () => riskOk() && modal(`<h2>Before you join the kitty</h2>
      <p style="line-height:1.5">This Friday is <b>week ${week} of up to 5</b> in kitty ${fs.session_no}.<br>The kitty fund is currently <b>${money(fs.kitty)}</b>.</p>
      <p class="muted" style="line-height:1.5">The kitty resets when the fund drops below £150 or after week 5, whichever comes first. Then everyone goes back to ordinary membership and chooses £15 or pay as you play again. Joining now covers at most ${5 - fs.games_played} game${5 - fs.games_played === 1 ? "" : "s"}, and fewer if the fund runs low first.</p>
      <div class="form-actions"><button class="btn solid block" id="join">Join the kitty and book · £15${me.family ? " by transfer" : ""}</button></div>`, (m) => {
      $("#join", m).onclick = () => { closeModal(); bookFootball(ev, "kitty"); };
    });
    const cx = $("#cancel", el);
    if (cx) cx.onclick = async () => {
      const mine = bookings.find((b) => b.user_id === me.id);
      if (mine && !mine.paid && mine.square_order_id) payApi({ code: mine.code, confirm: true }).then((r) => { if (r.paid && alive()) { toast("Payment received, thank you!"); refresh(); } }).catch(() => {});
      if (cx.dataset.sure !== "1") { cx.dataset.sure = "1"; cx.textContent = "Tap again to remove yourself"; return; }
      try { toast(await q(sb.rpc("cancel_booking", { p_id: mine.id }))); await loadMe(); refresh(); } catch (e) { fail(e); }
    };
    if (isOrg()) organiserFootball($("#org", el), ev, bookings, fs, awaiting, games);
  }
  async function bookFootball(ev, choice) {
    try {
      const b = await q(sb.rpc("book_football", { p_event: ev.id, p_choice: choice, p_risk: true }));
      toast(b.paid ? "You're booked ✓" : "Booked. Pay by Thursday 11pm to keep your place");
      await loadMe(); refresh();
    } catch (e) { fail(e); }
  }

  // Organiser tools on the football screen: payments, accounts and adding the next game.
  const sumBy = (bs, m) => bs.filter((b) => b.paid && b.method === m && b.status !== "waitlist").reduce((t, b) => t + Number(b.amount), 0).toFixed(2);
  async function organiserFootball(box, current, currentBookings, fs, awaiting, games) {
    const target = awaiting[0] || current;
    const bookings = target && target !== current ? await q(sb.from("bookings").select("*").eq("event_id", target.id).neq("status", "cancelled").order("created_at")) : currentBookings;
    const people = current && !current.accounts_posted ? await q(sb.from("profiles").select("id,name,credit").order("name")) : [];
    const onList = new Set(currentBookings.map((b) => b.user_id).filter(Boolean));
    const debts = await q(sb.from("debts").select("*, profiles(name)").eq("cleared", false).order("on_date"));
    // cancelled before Friday 6pm: their money is in this game's takings but now belongs to the credits fund
    const cancelled = target ? (await q(sb.from("bookings").select("*").eq("event_id", target.id).eq("status", "cancelled")))
      .filter((b) => b.status === "cancelled" && b.charge === "payg" && b.paid && ["card", "transfer", "cash"].includes(b.method)) : [];
    // credits check: every credit change since the last accounts, and the credit on members' accounts now
    const [creditMoves, creditRows] = target && !target.accounts_posted ? await Promise.all([
      fs.posted_at ? q(sb.from("ledger").select("*").eq("fund", "credits").gt("created_at", fs.posted_at).order("id")) : [],
      q(sb.from("profiles").select("credit"))]) : [[], []];
    const fromCredit = target ? bookings.filter((b) => b.charge === "payg" && b.paid && b.method === "credit" && b.checked_in).reduce((t, b) => t + Number(b.amount), 0) : 0;
    const nextFri = (() => { const last = games.length ? parseDay(games[games.length - 1].day) : today(); const d = new Date(Math.max(last, today())); d.setDate(d.getDate() + ((5 - d.getDay() + 7) % 7 || (games.length ? 7 : 0))); return d; })();
    const charged = bookings.filter((b) => b.charge !== "covered");
    const METHODS = { card: "Card", transfer: "Transfer", cash: "Cash", owes: "Owes" };
    box.innerHTML = `<div class="card fb"><h2>Organiser</h2>
      <button class="btn small" id="addGame">Add game for ${short(nextFri)}</button>
      ${current ? `<h3>Who's turned up · ${short(parseDay(current.day))}</h3>
      <p class="muted">Tap a name when they arrive. ${currentBookings.filter((b) => b.checked_in).length} of ${currentBookings.length} here.</p>
      <div class="attend">${currentBookings.map((b) => `<label class="check"><input type="checkbox" data-here="${b.id}" ${b.checked_in ? "checked" : ""} ${current.accounts_posted ? "disabled" : ""}> ${esc(b.display_name)}${b.paid ? "" : ' <span class="tag warn">Unpaid</span>'}${current.accounts_posted ? "" : ` <button class="btn small" data-drop="${b.id}" style="margin-left:auto">Remove</button>`}</label>`).join("") || '<p class="muted">No one has booked yet.</p>'}</div>
      <p class="muted">Anyone paid for pay and play who isn't ticked when the accounts are posted keeps what they paid as credit on their account for their next booking.</p>
      ${current.accounts_posted ? "" : `<h3>Add someone who wasn't on the list</h3>
      <div class="grid2">
        <div><label>Member</label><select id="wiUser"><option value="">Not a member (type name)</option>${people.filter((p) => !onList.has(p.id)).map((p) => `<option value="${p.id}" data-credit="${Number(p.credit) || 0}">${esc(p.name)}${Number(p.credit) > 0 ? ` (${money(p.credit)} credit)` : ""}</option>`).join("")}</select></div>
        <div><label>Name</label><input id="wiName" placeholder="Their name"></div>
        <div><label id="wiPrice">Paid ${money(Math.max(Number(current.price), 6))} by</label><select id="wiMeth">${Object.entries(METHODS).map(([k, v]) => `<option value="${k}">${v}</option>`).join("")}<option value="credit" disabled>Account credit</option></select></div>
      </div>
      <div class="form-actions"><button class="btn solid block" id="wiAdd">Add and mark as here</button></div>`}` : ""}
      ${target ? `<h3>Payments · ${esc(target.title)} ${short(parseDay(target.day))}${target.accounts_posted ? " (accounts posted)" : ""}</h3>
      <p class="muted">Set how each person paid. Picking a method marks them paid straight away.</p>
      <div class="scroll"><table><thead><tr><th>Player</th><th>Type</th><th>Paid by</th></tr></thead><tbody>
        ${charged.map((b) => `<tr><td>${esc(b.display_name)}</td><td>${b.charge === "kitty" ? "Kitty £15" : `Pay & play ${money(b.amount)}`}</td><td>${b.method === "credit" ? "Credit" :
          `<select data-meth="${b.id}" ${target.accounts_posted ? "disabled" : ""}><option value="">Not paid</option>${Object.entries(METHODS).map(([k, v]) => `<option value="${k}" ${b.method === k ? "selected" : ""}>${v}</option>`).join("")}</select>`}</td></tr>`).join("") || '<tr><td colspan="3" class="muted">No payments to check.</td></tr>'}
      </tbody></table></div>
      ${!target.accounts_posted && eventStart(target) <= new Date() ? `
        ${debts.length ? `<h3>Owed from earlier games</h3>${debts.map((d) => `<label class="check"><input type="checkbox" data-clear="${d.id}"> ${esc(d.profiles?.name || "Member")} owes ${money(d.amount)} (${esc(d.reason)})</label>`).join("")}` : ""}
        <div class="grid2">
          <div><label>Game format</label><input id="fmt" value="3 team sudden death games"></div>
          <div><label>Turnout</label><input id="turnout" type="number" min="0" value="${bookings.filter((b) => b.checked_in).length}"></div>
        </div>
        <h3>Money actually received</h3>
        <p class="muted">From the Square summary, your bank and cash in hand. Filled in from the app's records, so change them to match.</p>
        <div class="grid2">
          <div><label>Square (£)</label><input id="rSquare" type="number" step="0.01" value="${sumBy([...bookings, ...cancelled], "card")}"></div>
          <div><label>Transfers (£)</label><input id="rTransfer" type="number" step="0.01" value="${sumBy([...bookings, ...cancelled], "transfer")}"></div>
          <div><label>Cash or PayPal (£)</label><input id="rCash" type="number" step="0.01" value="${sumBy([...bookings, ...cancelled], "cash")}"></div>
          <div><label>From credits (£)</label><input id="rCredit" type="number" value="${fromCredit.toFixed(2)}" readonly title="Worked out from who paid with credit and turned up"></div>
        </div>
        <p class="muted">From credits is filled in by the app: players who turned up and paid from their account credit.</p>
        <h3>Costs</h3>
        <div class="grid2">
          <div><label>Goals pitch hire (£)</label><input id="hire" type="number" step="0.01" value="${bookings.length >= 28 ? "124.00" : "62.00"}"></div>
          <div><label>Card fees (£)</label><input id="fees" type="number" step="0.01" value="${bookings.reduce((t, b) => t + Number(b.card_fee || 0), 0).toFixed(2)}"></div>
        </div>
        <h3>Receipt photos</h3>
        <div class="grid2">
          <div><label>Goals receipt</label><input id="phGoals" type="file" accept="image/*"></div>
          <div><label>Square summary</label><input id="phSquare" type="file" accept="image/*"></div>
        </div>
        <div class="form-actions"><button class="btn solid block" id="draft">Draft accounts</button></div>
        <div id="draftBox" hidden><label>Accounts (edit freely)</label><textarea id="acc" rows="18" class="mono"></textarea>
          <div class="form-actions" style="display:grid;gap:10px"><button class="btn solid block" id="post">Confirm and post to board</button><button class="btn block" id="copy">Copy for WhatsApp</button></div></div>`
        : !target.accounts_posted ? '<p class="muted">After the game, the accounts tools appear here.</p>' : ""}` : ""}
    </div>`;

    $("#addGame", box).onclick = async () => {
      try {
        await q(sb.from("events").insert({ kind: "football", title: "Weekly Friday Footie", day: dayKey(nextFri), time: "21:15", location: "Goals Beckenham, Elmers End",
          details: "Weekly 5-a-side every Friday night. All abilities welcome. £6 pay as you play, or £15 for the kitty.", price: 6, capacity: 36, access: "members" }));
        toast("Game added"); refresh();
      } catch (e) { fail(e); }
    };
    const wu = $("#wiUser", box);
    if (wu) {
      const sync = () => { const o = wu.selectedOptions[0], cr = Number(o.dataset.credit || 0), c = $("#wiMeth", box).querySelector('[value="credit"]');
        // Offer prices are for members; anyone else pays the full £6.
        $("#wiPrice", box).textContent = `Paid ${money(wu.value ? Number(current.price) : Math.max(Number(current.price), 6))} by`;
        $("#wiName", box).disabled = !!wu.value; c.disabled = cr < Number(current.price); if (c.disabled && $("#wiMeth", box).value === "credit") $("#wiMeth", box).value = "cash"; };
      wu.onchange = sync; sync();
      $("#wiAdd", box).onclick = async () => {
        try {
          $("#wiAdd", box).disabled = true;
          const b = (await q(sb.rpc("add_walkin", { p_event: current.id, p_user: wu.value || null, p_name: $("#wiName", box).value.trim() || null, p_method: $("#wiMeth", box).value })));
          const row = Array.isArray(b) ? b[0] : b;
          toast(row && row.charge === "covered" ? `${row.display_name} added (in the kitty, no charge)` : "Added and marked as here"); refresh();
        } catch (e) { $("#wiAdd", box).disabled = false; fail(e); }
      };
    }
    box.querySelectorAll("[data-drop]").forEach((d) => (d.onclick = async (e) => {
      e.preventDefault();
      if (d.dataset.sure !== "1") { d.dataset.sure = "1"; d.textContent = "Tap again to remove"; return; }
      try { d.disabled = true; await q(sb.rpc("cancel_booking", { p_id: d.dataset.drop })); toast("Removed from the list"); refresh(); } catch (err) { d.disabled = false; fail(err); }
    }));
    box.querySelectorAll("[data-here]").forEach((c) => (c.onchange = async () => {
      try { await q(sb.from("bookings").update({ checked_in: c.checked }).eq("id", c.dataset.here)); toast(c.checked ? "Marked as here" : "Unmarked"); refresh(); } catch (e) { c.checked = !c.checked; fail(e); }
    }));
    box.querySelectorAll("[data-meth]").forEach((s) => (s.onchange = async () => {
      try { await q(sb.from("bookings").update({ method: s.value || null, paid: !!s.value && s.value !== "owes" }).eq("id", s.dataset.meth)); toast("Saved"); refresh(); } catch (e) { fail(e); }
    }));
    const dr = $("#draft", box);
    if (!dr) return;
    const methodOf = (b) => b.method || "owes";
    const photos = {};
    [["phGoals", 0], ["phSquare", 1]].forEach(([id, i]) => {
      const f = $("#" + id, box);
      if (f) f.onchange = () => { const file = f.files[0]; if (!file) return delete photos[i];
        const rd = new FileReader(); rd.onload = async () => { photos[i] = await shrink(rd.result, 1600); }; rd.readAsDataURL(file); };
    });
    dr.onclick = () => {
      const cleared = [...box.querySelectorAll("[data-clear]:checked")].map((c) => debts.find((d) => d.id === c.dataset.clear));
      const all = bookings, here = all.filter((b) => b.checked_in);
      if (!here.length) return toast(`Tick who turned up under "Who's turned up" first`);
      const turnout = Number($("#turnout", box).value) || here.length;
      const kittyHere = here.filter((b) => b.charge === "covered" || b.charge === "kitty");
      const kp = all.filter((b) => b.charge === "kitty");
      const payers = Math.max(turnout - kittyHere.length, 0);
      const pg = here.filter((b) => b.charge === "payg");
      const viaCredit = pg.filter((b) => b.method === "credit" && b.paid);
      const counts = (b) => b.charge === "kitty" || b.checked_in;
      const owing = all.filter((b) => b.charge !== "covered" && counts(b) && methodOf(b) === "owes");
      const noShows = all.filter((b) => b.charge === "payg" && !b.checked_in && b.paid && (b.user_id || b.booked_by));
      const noShowCash = noShows.filter((b) => ["card", "transfer", "cash"].includes(b.method));
      const sum = (xs) => xs.reduce((t, b) => t + Number(b.amount), 0);
      const toCredits = sum(noShowCash) + sum(cancelled);
      const clearedAmt = cleared.reduce((t, d) => t + Number(d.amount), 0);
      const rSq = Number($("#rSquare", box).value) || 0, rTr = Number($("#rTransfer", box).value) || 0, rCa = Number($("#rCash", box).value) || 0;
      const received = rSq + rTr + rCa, rCr = sum(viaCredit), receivedAll = received + rCr;
      const hire = Number($("#hire", box).value) || 0, fees = Number($("#fees", box).value) || 0;
      // What should have come in (credit included): kitty joiners, the price from everyone else who played,
      // owed money cleared, and money from people who paid but didn't play or cancelled for credit; less deferred.
      const TP = Number(target.price);
      const friendsHere = pg.filter((b) => b.booked_by), fAmt = sum(friendsHere);
      const expGross = kp.length * 15 + Math.max(payers - friendsHere.length, 0) * TP + fAmt;
      const expIn = expGross + clearedAmt + toCredits - sum(owing);
      const diff = Math.round((receivedAll - expIn) * 100) / 100;
      // Same split as post_accounts: cleared debts go to events, unused money to credits, the rest to the kitty.
      const income = received + rCr - toCredits - clearedAmt;
      const net = income - hire - fees, newKitty = Number(fs.kitty) + net, newEv = Number(fs.events) + clearedAmt;
      // Credits: held at the last accounts + added - used (+ no-shows credited now) must equal members' accounts.
      const oldCr = Number(fs.credits_posted ?? fs.credits ?? 0);
      const crIn = creditMoves.filter((m) => Number(m.amount) > 0), crOut = creditMoves.filter((m) => Number(m.amount) < 0);
      const crAdded = crIn.reduce((t, m) => t + Number(m.amount), 0), crUsed = -crOut.reduce((t, m) => t + Number(m.amount), 0);
      const crNow = sum(noShows);
      const newCr = Math.round((oldCr + crAdded - crUsed + crNow) * 100) / 100;
      const onAccounts = Math.round((creditRows.reduce((t, r) => t + Number(r.credit || 0), 0) + crNow) * 100) / 100;
      const g = fs.games_played + 1, ORD = ["1st", "2nd", "3rd", "4th", "5th"], L = "________", d = parseDay(target.day);
      const t = [`Turnout ${turnout} - ${d.getDate()} ${MONTHS_LONG[d.getMonth()]} - ${ORD[g - 1] || g + "th"} kitty game of up to 5 consecutive games`, "",
        "Kitty restarts when either fund drops below £150 or we have had a maximum of 5 consecutive games", "", $("#fmt", box).value.trim(), L,
        "Before funds", `Kitty fund ${money(fs.kitty)}`, `Events fund ${money(fs.events)}`, `Credits ${money(oldCr)}`, L];
      if (kittyHere.length) t.push(`Kitty players who turned up (${kittyHere.length})`, ...kittyHere.map((b) => b.display_name), L);
      if (kp.length) t.push(`Joined the kitty this game (${kp.length})`, ...kp.map((b) => b.display_name), `Expected ${kp.length}x £15 = ${money(kp.length * 15)}`, L);
      t.push("Pay and Play", `Turnout ${turnout} less ${kittyHere.length} kitty = ${payers} to pay`, friendsHere.length && fAmt !== friendsHere.length * TP
        ? `Expected ${payers - friendsHere.length}x ${money(TP)} + ${friendsHere.length} friend${friendsHere.length === 1 ? "" : "s"} ${money(fAmt)} = ${money(expGross - kp.length * 15)}`
        : `Expected ${payers}x ${money(TP)} = ${money(payers * TP)}`);
      if (viaCredit.length) t.push(`Including ${viaCredit.length} paid from credit: ${viaCredit.map((b) => b.display_name).join(", ")}`);
      if (owing.length) t.push(`Less ${owing.length} deferred: ${owing.map((b) => b.display_name).join(", ")}`);
      if (noShowCash.length) t.push(`Plus ${noShowCash.length} paid but didn't come (now their credit): ${noShowCash.map((b) => b.display_name).join(", ")}`);
      if (cancelled.length) t.push(`Plus ${cancelled.length} paid then cancelled (now their credit): ${cancelled.map((b) => b.display_name).join(", ")}`);
      if (cleared.length) t.push(`Plus ${cleared.length} owed cleared ${money(clearedAmt)} (to events fund)`);
      t.push("", `Expected in ${money(expIn)}`, L, "Received",
        `Square ${money(rSq)}`, `Transfers ${money(rTr)}`, `Cash or PayPal ${money(rCa)}`, `From credits ${money(rCr)}`, `Total received ${money(receivedAll)}`, "",
        diff === 0 ? "Balanced." : `Off by ${money(Math.abs(diff))} (${diff > 0 ? "more" : "less"} than expected)`, L,
        "Less cost", `${money(hire)} Goals pitch hire`, `${money(fees)} card payment charge`, "—————————", "Receipts over costs", money(net), "——————————",
        "Movements between funds");
      if (rCr) t.push(`Credits to kitty fund ${money(rCr)} (paid from credit)`);
      if (toCredits) t.push(`Takings kept as credit ${money(toCredits)} (paid but didn't play or cancelled)`);
      if (clearedAmt) t.push(`Into events fund ${money(clearedAmt)} (owed money cleared)`);
      if (!rCr && !toCredits && !clearedAmt) t.push("None");
      t.push(L, "Credits check", `Held at last accounts ${money(oldCr)}`, `Added ${money(crAdded + crNow)}`,
        ...crIn.map((m) => `  + ${money(m.amount)} ${m.what}`), ...noShows.map((b) => `  + ${money(b.amount)} ${b.display_name}: paid but didn't play, credit added now`),
        `Used ${money(crUsed)}`, ...crOut.map((m) => `  - ${money(-m.amount)} ${m.what}`),
        `Credits held now ${money(newCr)}`, `Total credit on members' accounts ${money(onAccounts)}`,
        newCr === onAccounts ? "Credits tally ✓" : `Credits don't tally: off by ${money(Math.abs(newCr - onAccounts))}. Check before posting.`);
      t.push(L, "Updated funds", `Kitty fund ${money(newKitty)}`, `Events fund ${money(newEv)}`, `Credits ${money(newCr)}`);
      const owes = [...debts.filter((x) => !cleared.includes(x)).map((x) => `${x.profiles?.name || "Member"} ${money(x.amount)} ${esc(x.reason)}`),
        ...owing.map((b) => `${b.display_name} ${money(b.amount)} ${short(d)}`)];
      if (owes.length) t.push(L, "These OWE", ...owes);
      if (newKitty < 150 || g >= 5) t.push(L, `Kitty restarts: ${newKitty < 150 ? "fund is below £150" : "5 games played"}. Anything over £100 moves to the events fund and the next game starts a new kitty.`);
      $("#acc", box).value = t.join("\n"); $("#draftBox", box).hidden = false;
      $("#post", box).onclick = async () => {
        const methods = {}; all.forEach((b) => { if (b.charge !== "covered" && b.method !== "credit") methods[b.id] = methodOf(b); });
        try {
          $("#post", box).disabled = true;
          await q(sb.rpc("post_accounts", { p_event: target.id, p_body: $("#acc", box).value, p_hire: hire, p_fees: fees, p_methods: methods,
            p_cleared: cleared.map((x) => x.id), p_received: received, p_images: [photos[0], photos[1]].filter(Boolean) }));
          toast("Accounts posted to the board and Football Accounts"); refresh();
        } catch (e) { $("#post", box).disabled = false; fail(e); }
      };
      $("#copy", box).onclick = async () => { try { await navigator.clipboard.writeText($("#acc", box).value); toast("Copied. Paste it into WhatsApp"); } catch { $("#acc", box).select(); toast("Select all and copy"); } };
    };
  }

  // ---------- GROUPS ----------
  let groupCache = [];
  const groupName = (id) => (groupCache.find((g) => g.id === id) || {}).name || "Group";

  const ANNOUNCE = "announcements";
  const ORG_POSTS = ["football-accounts"]; // chats only organisers can post in
  const AUTO_GROUPS = ["football-accounts"]; // every approved member is in these, no sign-up
  const inGroup = (id) => joined.includes(id) || isOrg() || (AUTO_GROUPS.includes(id) && !!me && !pending() && !eventsOnly());
  const PENDING_NOTE = '<p class="note">You can join in once the admin has approved your membership.</p>';
  // Chats: open, informal chats anyone can join in. Joined: sign-up chats (like the Quran target).
  // Announcements are pinned at the top of both.
  function chat(el, alive, id) { return groups(el, alive, "", id); }
  function grouplist(el, alive) { return groups(el, alive, "", null, true); }
  async function groups(el, alive, filter = "", only = null, joinedTab = false) {
    if (!me) return needSignIn(el, "see the groups");
    loading(el);
    const [gs, posts, comments, votes] = await Promise.all([
      q(sb.from("groups").select("*").order("sort")),
      q(sb.from("posts").select("*").order("pinned", { ascending: false }).order("created_at", { ascending: false }).limit(100)),
      q(sb.from("comments").select("*").order("created_at")),
      q(sb.from("poll_votes").select("*")),
      myGroups(),
    ]).then(([a, b, c, d, g]) => { joined = g; return [a, b, c, d]; });
    if (!alive()) return;
    groupCache = gs;
    const boxed = (g) => g === ANNOUNCE || gs.find((x) => x.id === g)?.members_only;
    const news = posts.filter((p) => p.group_id === ANNOUNCE).slice(0, 3);
    const shown = posts.filter((p) => !boxed(p.group_id) && (!filter || (p.body + groupName(p.group_id)).toLowerCase().includes(filter.toLowerCase())));
    const newsBox = `<section class="news"><div class="row" style="justify-content:space-between"><h2>📢 Latest Community Announcements</h2>${isAdmin() ? '<button class="btn small" data-compose="news">Post</button>' : ""}</div>
      ${news.map((p) => postHtml(p, comments.filter((c) => c.post_id === p.id), votes.filter((v) => v.post_id === p.id))).join("") || '<p class="muted">No announcements yet.</p>'}</section>`;
    // Members-only chats (like the Quran target): shown to people who signed up, with a sign-up button for everyone else.
    if (only) {
      const g = gs.find((x) => x.id === only);
      if (!g) { el.innerHTML = '<div class="empty"><h2>Chat not found</h2></div>'; return; }
      const canRead = !g.members_only || inGroup(g.id);
      const canPost = canRead && !pending() && (g.id !== ANNOUNCE || isAdmin()) && (!ORG_POSTS.includes(g.id) || isOrg());
      const gp = posts.filter((p) => p.group_id === g.id);
      el.innerHTML = `<div class="subhead"><h2>${esc(g.name)}</h2>${g.members_only ? '<a href="#grouplist">Joined events</a>' : '<a href="#groups">Chats</a>'}</div>
        ${g.about ? `<p class="muted pad" style="padding-top:10px">${esc(g.about)}</p>` : ""}
        ${!canRead ? `<div class="pad">${pending() ? PENDING_NOTE : `<button class="btn solid" data-join="${esc(g.id)}">Sign up · Free</button>`}</div>` : `
        ${pending() && g.id !== ANNOUNCE ? `<div class="pad">${PENDING_NOTE}</div>` : ""}
        ${canPost ? `<div class="composer">
          <div class="row"><div class="avatar" style="width:46px;height:46px">${esc(initials(me.name))}</div>
            <button class="share" data-compose="text" data-group="${esc(g.id)}">Share something...</button></div>
          <div class="tools">
            <button data-compose="photo" data-group="${esc(g.id)}">${ICON.camera} Photo</button>
            <button data-compose="poll" data-group="${esc(g.id)}">${ICON.poll} Poll</button>
          </div>
        </div>` : ""}
        <div id="feed">${gp.map((p) => postHtml(p, comments.filter((c) => c.post_id === p.id), votes.filter((v) => v.post_id === p.id))).join("") || '<div class="empty"><h2>No posts yet</h2></div>'}</div>`}`;
      el.querySelectorAll("[data-compose]").forEach((b) => (b.onclick = () => compose(b.dataset.compose, b.dataset.group)));
      el.querySelectorAll("[data-join]").forEach((b) => (b.onclick = () => joinGroup(b.dataset.join).then(refresh)));
      wirePosts(el, posts);
      return;
    }
    const JOINED_ORDER = ["football-accounts", "quran"];
    const firstIn = (g) => { const i = JOINED_ORDER.indexOf(g.id); return i < 0 ? JOINED_ORDER.length : i; };
    const clubs = gs.filter((g) => g.members_only).sort((a, b) => firstIn(a) - firstIn(b)).map((g) => {
      const inIt = inGroup(g.id);
      const gp = posts.filter((p) => p.group_id === g.id).slice(0, 4);
      return `<section class="news club"><div class="row" style="justify-content:space-between"><h2>${inIt ? `<a href="#chat:${encodeURIComponent(g.id)}" style="color:inherit">📖 ${esc(g.name)}</a>` : `📖 ${esc(g.name)}`}</h2><span class="row" style="gap:8px">${inIt && !joined.includes(g.id) && !AUTO_GROUPS.includes(g.id) && !pending() ? `<button class="btn small" data-join="${esc(g.id)}">Sign up</button>` : ""}${inIt && (!ORG_POSTS.includes(g.id) || isOrg()) ? `<button class="btn small" data-compose="text" data-group="${esc(g.id)}">Post</button>` : ""}</span></div>
        ${inIt ? gp.map((p) => postHtml(p, comments.filter((c) => c.post_id === p.id), votes.filter((v) => v.post_id === p.id))).join("") || '<p class="muted">Nothing posted yet.</p>'
          : `<p class="muted">${esc(g.about)}</p>${pending() ? PENDING_NOTE : `<button class="btn solid" data-join="${esc(g.id)}">Sign up · Free</button>`}`}</section>`;
    }).join("");
    if (joinedTab) {
      el.innerHTML = `<div class="subhead"><h2>Joined events</h2><a href="#groups">Chats</a></div>
        <p class="muted pad" style="padding-top:10px">Group chats you sign up for. Sign up to see what's shared and join the conversation.</p>
        ${clubs || '<div class="empty"><h2>No group chats yet</h2></div>'}`;
      el.querySelectorAll("[data-compose]").forEach((b) => (b.onclick = () => compose(b.dataset.compose, b.dataset.group)));
      el.querySelectorAll("[data-join]").forEach((b) => (b.onclick = () => joinGroup(b.dataset.join).then(refresh)));
      wirePosts(el, posts);
      return;
    }
    const open = gs.filter((g) => g.id !== ANNOUNCE && !g.members_only).map((g) => {
      const n = posts.filter((p) => p.group_id === g.id).length;
      return `<a class="group-row" href="#chat:${encodeURIComponent(g.id)}"><div class="avatar" style="width:44px;height:44px;background:var(--green)">${esc(initials(g.name))}</div>
        <div style="flex:1"><b>${esc(g.name)}</b><div class="muted">${esc(g.about || "")}${g.about ? " · " : ""}${n} post${n === 1 ? "" : "s"}</div></div><span class="muted" aria-hidden="true">›</span></a>`;
    }).join("");
    el.innerHTML = `
      <div class="subhead"><h2>Chats</h2><a href="#grouplist">Joined events</a>
        <span style="width:1px;height:28px;background:var(--line)"></span>
        <button id="searchBtn" style="color:var(--green)">${ICON.search}</button></div>
      ${filter ? "" : newsBox + open}
      ${filter ? `<div class="pad" style="padding-top:10px">Results for “${esc(filter)}” · <a href="#" id="clear">clear</a></div>` : ""}
      ${pending() ? `<div class="pad">${PENDING_NOTE}</div>` : `<div class="composer">
        <div class="row"><div class="avatar" style="width:46px;height:46px">${esc(initials(me.name))}</div>
          <button class="share" data-compose="text">Share something...</button></div>
        <div class="tools">
          <button data-compose="photo">${ICON.camera} Photo</button>
          <button data-compose="poll">${ICON.poll} Poll</button>
        </div>
      </div>`}
      <div id="feed">${shown.map((p) => postHtml(p, comments.filter((c) => c.post_id === p.id), votes.filter((v) => v.post_id === p.id))).join("") || '<div class="empty"><h2>No posts yet</h2></div>'}</div>`;
    el.querySelectorAll("[data-compose]").forEach((b) => (b.onclick = () => compose(b.dataset.compose, b.dataset.group)));
    el.querySelectorAll("[data-join]").forEach((b) => (b.onclick = () => joinGroup(b.dataset.join).then(refresh)));
    $("#searchBtn", el).onclick = () => {
      modal(`<h2>Search posts</h2><input id="q" placeholder="Search..." value="${esc(filter)}"><div class="form-actions"><button class="btn solid block" id="go">Search</button></div>`, (m) => {
        const qi = $("#q", m); qi.focus();
        const run = () => { closeModal(); groups(view, () => true, qi.value.trim()); };
        $("#go", m).onclick = run; qi.onkeydown = (e) => e.key === "Enter" && run();
      });
    };
    const clr = $("#clear", el); if (clr) clr.onclick = (e) => { e.preventDefault(); render(); };
    wirePosts(el, posts);
  }

  function postHtml(p, comments, votes) {
    const liked = !!state.likes[p.id];
    const reacts = state.reactions[p.id] || [];
    let poll = "";
    if (p.poll) {
      const mine = votes.find((v) => v.user_id === me.id);
      const counts = p.poll.map((_, i) => votes.filter((v) => v.choice === i).length);
      const total = votes.length || 1;
      poll = p.poll.map((o, i) => `<button class="poll-opt" data-vote="${p.id}" data-i="${i}">
        ${mine ? `<div class="bar" style="width:${(counts[i] / total) * 100}%"></div>` : ""}
        <span>${esc(o)}${mine && mine.choice === i ? " ✓" : ""}${mine ? ` · ${counts[i]}` : ""}</span></button>`).join("");
    }
    return `<article class="post" data-post="${p.id}">
      <div class="head"><div class="avatar" style="width:46px;height:46px">${esc(initials(p.author_name))}</div>
        <div class="who"><b>${esc(p.author_name)}</b> posted in the group <b>${esc(groupName(p.group_id))}</b>.${p.pinned ? ' <span class="tag gold">Pinned</span>' : ""}<div class="muted">${ago(p.created_at)}</div></div>
        <button data-menu="${p.id}" style="font-size:24px;font-weight:900;letter-spacing:1px">•••</button></div>
      <div class="text">${bold(p.body)}</div>
      ${p.image ? `<img src="${p.image}" alt="">` : ""}
      ${poll}
      <div class="reactions">
        <button class="pill ${liked ? "on" : ""}" data-like="${p.id}">${ICON.thumb} ${liked ? 1 : 0}</button>
        ${reacts.map((r) => `<span class="pill">${r}</span>`).join("")}
        <button class="pill" data-react="${p.id}">☺+</button>
      </div>
      <div class="post-foot"><button data-comment="${p.id}">Comment${comments.length ? ` (${comments.length})` : ""}</button><button data-share="${p.id}">Share</button></div>
      ${comments.length ? `<div class="comments">${comments.map((c) => `<div class="comment"><b>${esc(c.author_name)}</b> ${esc(c.body)}</div>`).join("")}</div>` : ""}
    </article>`;
  }

  function wirePosts(el, posts) {
    const find = (id) => posts.find((p) => p.id === id);
    el.querySelectorAll("[data-like]").forEach((b) => (b.onclick = () => { const id = b.dataset.like; state.likes[id] = !state.likes[id]; save(); refresh(); }));
    el.querySelectorAll("[data-react]").forEach((b) => (b.onclick = () => {
      const id = b.dataset.react;
      modal(`<h2>Add a reaction</h2><div style="font-size:34px;display:flex;gap:14px;flex-wrap:wrap">${["❤️","😂","👏","🙏","🔥","🎉","😮","😢"].map((e) => `<button data-e="${e}">${e}</button>`).join("")}</div>`, (m) => {
        m.querySelectorAll("[data-e]").forEach((x) => (x.onclick = () => { (state.reactions[id] ||= []).push(x.dataset.e); save(); closeModal(); refresh(); }));
      });
    }));
    el.querySelectorAll("[data-comment]").forEach((b) => (b.onclick = () => {
      const id = b.dataset.comment;
      modal(`<h2>Write a comment</h2><label>Comment</label><textarea id="t"></textarea><div class="form-actions"><button class="btn solid block" id="send">Post comment</button></div>`, (m) => {
        $("#t", m).focus();
        $("#send", m).onclick = async () => {
          const body = $("#t", m).value.trim(); if (!body) return;
          try { await q(sb.from("comments").insert({ post_id: id, user_id: me.id, author_name: me.name, body })); closeModal(); refresh(); } catch (e) { fail(e); }
        };
      });
    }));
    el.querySelectorAll("[data-share]").forEach((b) => (b.onclick = () => { const p = find(b.dataset.share); share(C.name, p.body.replace(/\*\*/g, "").slice(0, 120)); }));
    el.querySelectorAll("[data-vote]").forEach((b) => (b.onclick = async () => {
      try { await q(sb.from("poll_votes").upsert({ post_id: b.dataset.vote, user_id: me.id, choice: Number(b.dataset.i) })); refresh(); } catch (e) { fail(e); }
    }));
    el.querySelectorAll("[data-menu]").forEach((b) => (b.onclick = () => {
      const p = find(b.dataset.menu), mine = p.user_id === me.id;
      modal(`<h2>Post options</h2>
        <button class="btn block" id="copy">Copy text</button>
        ${isOrg() ? `<div style="height:10px"></div><button class="btn block" id="pin">${p.pinned ? "Unpin" : "Pin to top"}</button>` : ""}
        ${isOrg() ? '<div style="height:10px"></div><button class="btn block" id="edit">Edit post</button>' : ""}
        ${mine || isOrg() ? '<div style="height:10px"></div><button class="btn block danger" id="del">Delete post</button>' : ""}`, (m) => {
        $("#copy", m).onclick = async () => { try { await navigator.clipboard.writeText(p.body.replace(/\*\*/g, "")); toast("Copied"); } catch {} closeModal(); };
        const pin = $("#pin", m); if (pin) pin.onclick = async () => { try { await q(sb.from("posts").update({ pinned: !p.pinned }).eq("id", p.id)); closeModal(); refresh(); } catch (e) { fail(e); } };
        const edit = $("#edit", m); if (edit) edit.onclick = () => {
          modal(`<h2>Edit post</h2><p class="muted">Paste the new text. *Bold* from WhatsApp stays bold.</p><textarea id="t" style="min-height:320px"></textarea><div class="form-actions"><button class="btn solid block" id="save">Save</button></div>`, (m2) => {
            $("#t", m2).value = p.body;
            $("#save", m2).onclick = async () => {
              const body = fromWhatsApp($("#t", m2).value.trim()); if (!body) return;
              try { await q(sb.from("posts").update({ body }).eq("id", p.id)); closeModal(); toast("Post updated"); refresh(); } catch (e) { fail(e); }
            };
          });
        };
        const del = $("#del", m); if (del) del.onclick = async () => { try { await q(sb.from("posts").delete().eq("id", p.id)); closeModal(); refresh(); } catch (e) { fail(e); } };
      });
    }));
  }

  function compose(kind, fixed) {
    if (kind === "news") { kind = "text"; fixed = ANNOUNCE; }
    const news = !!fixed;
    const groupOpts = groupCache.filter((g) => fixed ? g.id === fixed : g.id !== ANNOUNCE && (!ORG_POSTS.includes(g.id) || isOrg()) && (!g.members_only || inGroup(g.id))).map((g) => `<option value="${g.id}">${esc(g.name)}</option>`).join("");
    const extra = {
      photo: '<label>Photo</label><input type="file" id="file" accept="image/*">',
      poll: '<label>Options (one per line)</label><textarea id="opts" placeholder="Yes\nNo\nMaybe"></textarea>',
      text: "",
    }[kind];
    modal(`<h2>${kind === "poll" ? "Create a poll" : "Share something"}</h2>
      <label>Group</label><select id="g">${groupOpts}</select>
      <label>${kind === "poll" ? "Question" : "Message"}</label><textarea id="t"></textarea>
      ${extra}
      ${isOrg() && !news ? '<label class="check"><input type="checkbox" id="pinIt"> Pin as an organiser notice</label>' : ""}
      <div class="form-actions"><button class="btn solid block" id="post">Post</button></div>`, (m) => {
      $("#post", m).onclick = async () => {
        const body = fromWhatsApp($("#t", m).value.trim());
        const post = { group_id: $("#g", m).value, user_id: me.id, author_name: me.name, body, pinned: !!$("#pinIt", m)?.checked };
        const file = $("#file", m)?.files?.[0];
        if (file) {
          if (file.size > 15e6) return toast("That photo is too big");
          const data = await new Promise((r) => { const fr = new FileReader(); fr.onload = () => r(fr.result); fr.readAsDataURL(file); });
          post.image = await shrink(data);
        }
        if (kind === "poll") {
          post.poll = $("#opts", m).value.split("\n").map((s) => s.trim()).filter(Boolean);
          if (post.poll.length < 2) return toast("Add at least 2 options");
        }
        if (!body && !file) return toast("Write something first");
        try { $("#post", m).disabled = true; await q(sb.from("posts").insert(post)); closeModal(); refresh(); toast("Posted"); } catch (e) { $("#post", m).disabled = false; fail(e); }
      };
    });
  }
  // An event's picture from the phone's photos, shrunk like post photos.
  function picture(file) {
    return new Promise((res) => { const rd = new FileReader(); rd.onload = async () => res(await shrink(rd.result, 1000)); rd.readAsDataURL(file); });
  }
  // Downscale photos so posts stay small
  function shrink(dataUrl, max = 1000) {
    return new Promise((res) => {
      const img = new Image();
      img.onload = () => {
        const s = Math.min(1, max / Math.max(img.width, img.height));
        const c = document.createElement("canvas"); c.width = img.width * s; c.height = img.height * s;
        c.getContext("2d").drawImage(img, 0, 0, c.width, c.height); res(c.toDataURL("image/jpeg", 0.75));
      };
      img.src = dataUrl;
    });
  }

  // ---------- SCHEDULE ----------
  let selDay = today();
  // Schedule = everything you've booked, by date, with a week view that marks the days.
  async function schedule(el, alive) {
    loading(el);
    let rows;
    if (me) {
      const bks = await q(sb.from("bookings").select("code,status,paid,amount,charge,checked_in,places,events(title,day,time,location,kind)").eq("user_id", me.id).neq("status", "cancelled"));
      rows = bks.filter((b) => b.events && b.events.day).map((b) => ({ ...b, ...b.events }));
      // Weekly events tied to a chat you've joined (like the Quran target) show every week.
      joined = await myGroups();
      const evs = joined.length ? await q(sb.from("events").select("*").in("group_id", joined)) : [];
      evs.filter((e) => e.day && joined.includes(e.group_id)).forEach((e) => { const first = e.day; nextWeekly(e); rows.push({ ...e, first, joinedChat: true }); });
    } else {
      rows = (await Promise.all(state.guestTickets.map((c) => q(sb.rpc("ticket", { p_code: c })).then((r) => r[0]).catch(() => null)))).filter((t) => t && t.day && t.status !== "cancelled");
    }
    if (!alive()) return;
    const now = new Date();
    const upcoming = rows.filter((r) => eventEnd(r) > now).sort((a, b) => eventStart(a) - eventStart(b));
    const past = rows.filter((r) => eventEnd(r) <= now).sort((a, b) => eventStart(b) - eventStart(a));
    const on = (d) => upcoming.concat(past).filter((r) => r.day === dayKey(d)
      || (r.joinedChat && r.weekly && d >= parseDay(r.first) && d.getDay() === parseDay(r.first).getDay()));
    const monday = new Date(selDay); monday.setDate(selDay.getDate() - ((selDay.getDay() + 6) % 7));
    const days = [...Array(7)].map((_, i) => { const d = new Date(monday); d.setDate(monday.getDate() + i); return d; });
    const t = today();
    const status = (r) => r.status === "waitlist" ? '<span class="tag gold">Waitlist</span>'
      : r.checked_in ? '<span class="tag">Checked in</span>'
      : r.charge === "covered" ? '<span class="tag gold">Kitty</span>'
      : r.paid || !(Number(r.amount) > 0) ? '<span class="tag">Paid</span>' : `<span class="tag warn">To pay ${money(r.amount)}</span>`;
    const row = (r, day) => { const d = day || parseDay(r.day); return `<button class="card ticket-row" ${r.joinedChat ? `data-go="chat:${esc(r.group_id)}"` : `data-ticket="${esc(r.code)}"`}>
        <div class="event-date"><div class="d">${d.getDate()}</div><div class="m">${MONTHS[d.getMonth()]}</div></div>
        <div class="info"><b>${esc(r.title)}</b><span class="muted">${DAYS[d.getDay()]} · ${hhmm(r.time)}${r.location ? ` · ${esc(r.location)}` : ""}</span><div class="pills">${r.joinedChat ? `<span class="tag">${r.weekly ? `Every ${d.toLocaleDateString("en-GB", { weekday: "long" })}` : "Signed up"}</span>` : status(r)}${r.places > 1 ? `<span class="tag">${r.places} places</span>` : ""}</div></div>
        ${ICON.chev}</button>`; };
    const sel = on(selDay);
    el.innerHTML = `
      <div class="cal">
        <div class="cal-head"><button id="prev">${ICON.left}</button><b>${MONTHS_LONG[monday.getMonth()]} ${monday.getFullYear()}</b><button id="next" style="transform:scaleX(-1)">${ICON.left}</button></div>
        <div class="week">
          ${["Mon","Tue","Wed","Thu","Fri","Sat","Sun"].map((n) => `<div class="dn">${n}</div>`).join("")}
          ${days.map((d) => `<div><button data-day="${dayKey(d)}" class="${d >= t ? "future" : ""} ${dayKey(d) === dayKey(selDay) ? "sel" : ""} ${on(d).length ? "has" : ""}">${d.getDate()}</button></div>`).join("")}
        </div>
      </div>
      <div class="pad tickets">
        ${sel.length && dayKey(selDay) !== dayKey(t) ? `<h2>${short(selDay)}</h2>${sel.map((r) => row(r, selDay)).join("")}` : ""}
        <h2>My tickets</h2>
        ${upcoming.map((r) => row(r)).join("") || `<div class="empty" style="padding:30px 10px"><p class="muted">${me ? "Nothing booked yet." : "Sign in to see your tickets here."}</p><button class="btn solid" data-go="${me ? "events" : "account"}">${me ? "See events" : "Sign in or join"}</button></div>`}
        ${past.length ? `<details class="past"><summary>Past tickets (${past.length})</summary>${past.map((r) => row(r)).join("")}</details>` : ""}
      </div>`;
    const move = (n) => { selDay = new Date(selDay); selDay.setDate(selDay.getDate() + n); refresh(); };
    $("#prev", el).onclick = () => move(-7);
    $("#next", el).onclick = () => move(7);
    el.querySelectorAll("[data-day]").forEach((b) => (b.onclick = () => { selDay = parseDay(b.dataset.day); refresh(); }));
    el.querySelectorAll("[data-ticket]").forEach((b) => (b.onclick = () => showTicket(b.dataset.ticket)));
  }

  // ---------- MORE ----------
  function more(el) {
    el.innerHTML = `
      <button class="menu-row" data-to="account">${ICON.user}<span>${me ? "My account & tickets" : "Sign in or join"} ${ICON.chev}</span></button>
      <button class="menu-row" data-to="football">${ICON.ball}<span>Friday Football ${ICON.chev}</span></button>
      <button class="menu-row" data-to="funds">${ICON.poll}<span>Funds ${ICON.chev}</span></button>
      ${isOrg() ? `<button class="menu-row" data-to="admin">${ICON.tools}<span>Organiser tools ${ICON.chev}</span></button>` : ""}
      <button class="menu-row" data-to="counselling">${ICON.star}<span>Counselling ${ICON.chev}</span></button>`;
    el.querySelectorAll("[data-to]").forEach((b) => (b.onclick = () => go(b.dataset.to)));
  }

  function services(el, alive, qs = "") {
    const list = D.services.filter((s) => s.title.toLowerCase().includes(qs.toLowerCase()));
    el.innerHTML = `
      <div class="search">${ICON.search}<input id="q" placeholder="Search for a service" value="${esc(qs)}"></div>
      <div id="list">${list.map((s) => `
        <div class="service"><div class="thumb">${s.image ? `<img src="${esc(s.image)}" style="width:100%;height:100%;object-fit:cover;border-radius:6px">` : s.emoji || ""}</div>
          <div class="info"><b>${esc(s.title)}</b><div class="muted">${esc(s.place)}</div><div class="muted">${money(s.price)}</div></div>
          <button class="btn small" data-req="${s.id}">Book</button></div>`).join("") || '<div class="empty"><h2>No services found</h2></div>'}</div>`;
    const input = $("#q", el);
    input.oninput = () => { const pos = input.selectionStart; services(el, alive, input.value); const n = $("#q", el); n.focus(); n.setSelectionRange(pos, pos); };
    el.querySelectorAll("[data-req]").forEach((b) => (b.onclick = () => {
      const s = D.services.find((x) => x.id === b.dataset.req); requestForm(`${s.title} (${money(s.price)})`);
    }));
  }

  // Service and session requests go to the organiser on WhatsApp.
  function requestForm(what) {
    modal(`<h2>Book: ${esc(what)}</h2>
      <label>Your name</label><input id="n" value="${esc(me?.name || "")}">
      <label>Preferred date</label><input id="d" type="date" min="${dayKey(today())}">
      <div class="form-actions"><button class="btn solid block" id="ok">Send request on WhatsApp</button></div>
      <p class="muted" style="font-size:14px">We'll message you back to confirm. Payment is taken on the day.</p>`, (m) => {
      $("#ok", m).onclick = () => {
        const name = $("#n", m).value.trim(), date = $("#d", m).value;
        if (!name || !date) return toast("Please fill in every box");
        closeModal();
        window.open(`https://wa.me/${C.whatsapp}?text=${encodeURIComponent(`Booking request: ${what}\nName: ${name}\nPreferred date: ${date}`)}`, "_blank");
      };
    });
  }

  function counselling(el) {
    el.innerHTML = `<div class="pad" style="padding-top:24px">
      <h1>Counselling</h1><p style="line-height:1.6;font-size:17px">${esc(D.counselling.intro)}</p>
      <label>Your name (or leave blank to stay anonymous)</label><input id="n">
      <label>Anything you'd like us to know (optional)</label><textarea id="t"></textarea>
      <div class="form-actions"><button class="btn solid block" id="ok">Send request on WhatsApp</button></div>
      <p class="muted" style="font-size:14px">Prefer to talk now? Call <a href="tel:${esc(C.phone)}">${esc(C.phone)}</a>.</p>
      ${D.counselling.disclaimer ? `<p class="note" style="margin-top:20px">${esc(D.counselling.disclaimer)}</p>` : ""}</div>`;
    $("#ok", el).onclick = () => {
      const name = $("#n", el).value.trim(), note = $("#t", el).value.trim();
      window.open(`https://wa.me/${C.whatsapp}?text=${encodeURIComponent(`Counselling request${name ? ` from ${name}` : ""}.${note ? `\n${note}` : ""}`)}`, "_blank");
    };
  }

  // ---------- ACCOUNT ----------
  async function account(el, alive) {
    if (!me) return signInScreen(el);
    loading(el);
    const [bks, invites, debts, fs] = await Promise.all([
      q(sb.from("bookings").select("*, events(title, day, time)").eq("user_id", me.id).neq("status", "cancelled").order("created_at", { ascending: false }).limit(30)),
      q(sb.from("invites").select("*").eq("created_by", me.id).order("created_at", { ascending: false })),
      q(sb.from("debts").select("*").eq("user_id", me.id).eq("cleared", false)),
      q(sb.from("fund_state").select("*").single()),
    ]);
    // my credit changes, as recorded in the credits fund ("Name: reason")
    const myCredit = await q(sb.from("ledger").select("*").eq("fund", "credits").like("what", `${me.name}: %`).order("id", { ascending: false }).limit(20)).catch(() => []);
    const application = pending() ? await q(sb.from("applications").select("submitted_at").eq("user_id", me.id).maybeSingle()).catch(() => null) : null;
    if (!alive()) return;
    const upcoming = bks.filter((b) => b.events && b.events.day && eventEnd(b.events) > new Date());
    const ROLE = { member: "Member", organiser: "Organiser", admin: "Admin" };
    el.innerHTML = `<div class="pad" style="padding-top:24px">
      <h1>${esc(me.name)}</h1>
      <div class="pills"><span class="tag">${ROLE[me.role]}</span>${me.kitty_session === fs.session_no ? `<span class="tag gold">Kitty member, kitty ${fs.session_no}</span>` : ""}
        ${me.family ? '<span class="tag">Family: pays by transfer</span>' : ""}<span class="tag">${money(me.credit || 0)} credit</span></div>
      <p class="muted">${esc(me.email)}</p>
      ${pending() ? (application ? `<p class="note">Thanks, we've received your application. The admin will approve your membership soon. Until then you can look around, but you can't book or post.</p>`
        : `<p class="note">Please complete your membership application. Accounts without one are removed 24 hours after joining.</p><a class="btn solid block" href="${applyUrl()}" target="_blank" rel="noopener">Complete your application</a>`) : ""}
      ${debts.length ? `<p class="note">You owe ${money(debts.reduce((t, d) => t + Number(d.amount), 0))} from ${debts.map((d) => esc(d.reason)).join(", ")}. Please pay the organiser.</p>` : ""}
      <h2 style="margin-top:24px">My credit</h2>
      <p><b>${money(me.credit || 0)}</b> <span class="muted">held on your account</span></p>
      <p class="muted">Credit comes from paying for football and then not playing, or cancelling before Friday 6pm. It's used automatically for your next booking.</p>
      ${myCredit.length ? `<div class="scroll"><table><tbody>${myCredit.map((l) => `<tr><td>${short(new Date(l.created_at || l.on_date))}</td><td>${esc(l.what.slice(me.name.length + 2))}</td><td class="amt ${Number(l.amount) < 0 ? "neg" : ""}">${money(l.amount)}</td></tr>`).join("")}</tbody></table></div>` : '<p class="muted">No credit added or used yet.</p>'}
      <h2 style="margin-top:24px">My tickets</h2>
      ${upcoming.map((b) => `<button class="list-row block-row" data-ticket="${b.code}"><div><b>${esc(b.events.title)}</b><span class="muted">${short(parseDay(b.events.day))} · ${hhmm(b.events.time)} · ${b.status === "waitlist" ? "Waitlist" : b.paid ? "Paid" : "Not paid yet"}</span></div>${ICON.chev}</button>`).join("") || '<p class="muted">No upcoming bookings.</p>'}
      <h2 style="margin-top:24px">Invite a guest</h2>
      <p class="muted">Guests need a code from a member to book public events. Each code works for one guest.</p>
      <button class="btn small" id="newInv">Create invite code</button>
      ${invites.map((i) => `<div class="list-row"><div><b class="mono">${esc(i.code)}</b><span class="muted">${i.used_by ? `Used by ${esc(i.used_by)}` : "Not used yet"}</span></div>${i.used_by ? "" : `<button class="btn small" data-shareinv="${esc(i.code)}">Share</button>`}</div>`).join("")}
      <h2 style="margin-top:24px">Your name</h2>
      <div class="row"><input id="nm" value="${esc(me.name)}"><button class="btn small" id="saveNm">Save</button></div>
      <div class="form-actions"><button class="btn block" id="out">Sign out</button></div>
      <p class="muted" style="font-size:14px;line-height:1.5">${PRIVACY}</p>
    </div>`;
    el.querySelectorAll("[data-ticket]").forEach((b) => (b.onclick = () => showTicket(b.dataset.ticket)));
    $("#newInv", el).onclick = async () => {
      const code = "INV-" + Math.random().toString(36).slice(2, 7).toUpperCase().replace(/[01OIL]/g, "X");
      try { await q(sb.from("invites").insert({ code, created_by: me.id })); toast(`Invite code ${code} created`); refresh(); } catch (e) { fail(e); }
    };
    el.querySelectorAll("[data-shareinv]").forEach((b) => (b.onclick = () => share(C.name, `You're invited to ${C.name} events. Book on the Events tab with invite code ${b.dataset.shareinv}`)));
    $("#saveNm", el).onclick = async () => {
      const name = $("#nm", el).value.trim(); if (!name) return;
      try { await q(sb.from("profiles").update({ name }).eq("id", me.id)); await loadMe(); toast("Saved"); refresh(); } catch (e) { fail(e); }
    };
    $("#out", el).onclick = async () => { await sb.auth.signOut(); me = null; go("events"); };
  }

  function signInScreen(el) {
    const guest = state.guestTickets.length ? `<h2 style="margin-top:28px">Guest tickets on this phone</h2>${state.guestTickets.map((c) => `<button class="list-row block-row" data-ticket="${esc(c)}"><div><b class="mono">${esc(c)}</b><span class="muted">Tap to show</span></div>${ICON.chev}</button>`).join("")}` : "";
    el.innerHTML = `<div class="pad" style="padding-top:24px">
      <h1>Sign in or join</h1>
      <p class="muted" style="line-height:1.5">Members can book football and members-only events, post in the groups, and invite guests.</p>
      <div class="seg"><button data-mode="in" class="on">Sign in</button><button data-mode="up">Join</button></div>
      <div id="nameRow" hidden><label>Your full name</label><input id="nm" autocomplete="name">
        <label>Your postcode</label><input id="pc" autocomplete="postal-code" placeholder="e.g. BR3 1AA" style="text-transform:uppercase">
        <p class="muted" style="font-size:14px">Membership is for people living within ${HOME_MILES} miles of BR3. Only the admin can see your postcode.</p>
        <label>What would you like to join for?</label><div class="radios">
          <label class="check"><input type="radio" name="lvl" value="all" checked> Events and Friday football</label>
          <label class="check"><input type="radio" name="lvl" value="events"> Events only</label></div></div>
      <label>Email</label><input id="em" type="email" autocomplete="email">
      <label>Password</label><input id="pw" type="password" autocomplete="current-password" minlength="6">
      <div class="form-actions"><button class="btn solid block" id="go">Sign in</button></div>
      <p><a href="#" id="forgot">Forgot your password?</a></p>
      ${guest}
    </div>`;
    let mode = "in";
    el.querySelectorAll("[data-mode]").forEach((b) => (b.onclick = () => {
      mode = b.dataset.mode;
      el.querySelectorAll("[data-mode]").forEach((x) => x.classList.toggle("on", x === b));
      $("#nameRow", el).hidden = mode === "in";
      $("#go", el).textContent = mode === "in" ? "Sign in" : "Create my account";
      $("#pw", el).autocomplete = mode === "in" ? "current-password" : "new-password";
    }));
    el.querySelectorAll("[data-ticket]").forEach((b) => (b.onclick = () => showTicket(b.dataset.ticket)));
    $("#go", el).onclick = async () => {
      const email = $("#em", el).value.trim(), password = $("#pw", el).value, name = $("#nm", el).value.trim();
      if (!email || password.length < 6) return toast("Enter your email and a password of at least 6 characters");
      if (mode === "up" && !name) return toast("Enter your full name");
      const postcode = $("#pc", el).value.trim().toUpperCase();
      if (mode === "up" && !postcode) return toast("Enter your postcode");
      try {
        $("#go", el).disabled = true;
        if (mode === "up") {
          const miles = await milesFromHome(postcode);
          if (miles === false) { $("#go", el).disabled = false; return toast("We couldn't find that postcode. Please check it"); }
          const r = await q(sb.auth.signUp({ email, password, options: { data: { name, postcode, miles: miles == null ? "" : miles.toFixed(1) } } }));
          if (r.session && el.querySelector('[name="lvl"]:checked')?.value === "events") await q(sb.rpc("set_my_football", { p_on: false })).catch(() => {});
          const far = miles == null || miles > HOME_MILES;
          const uid = r.user?.id || r.session?.user?.id;
          const form = `${APPLY_FORM}?memberId=${encodeURIComponent(uid || "")}&email=${encodeURIComponent(email)}`;
          const next = `<p style="line-height:1.5"><b>Next, please complete your membership application.</b> The admin reviews it and approves your membership. Accounts without an application are removed after 24 hours.</p>
            ${far ? `<p class="note" style="line-height:1.5">Your postcode is outside our ${HOME_MILES}-mile area around BR3, so please say in the application how you're connected to the community.</p>` : ""}
            <a class="btn solid block" href="${form}" target="_blank" rel="noopener">Complete your application</a>`;
          $("#go", el).disabled = false;
          if (!r.session) return modal(`<h2>Check your email</h2><p style="line-height:1.5">We've sent a link to <b>${esc(email)}</b> to confirm your account.</p>${next}`);
          modal(`<h2>Welcome</h2>${next}`);
        } else {
          await q(sb.auth.signInWithPassword({ email, password }));
        }
        await loadMe(); toast(`Welcome, ${me?.name || ""}`); go("events");
      } catch (e) { $("#go", el).disabled = false; fail(e); }
    };
    $("#forgot", el).onclick = async (e) => {
      e.preventDefault();
      const email = $("#em", el).value.trim(); if (!email) return toast("Type your email above first");
      try { await q(sb.auth.resetPasswordForEmail(email, { redirectTo: location.origin + location.pathname })); modal(`<h2>Check your email</h2><p>We've sent a password reset link to <b>${esc(email)}</b>.</p>`); } catch (e2) { fail(e2); }
    };
  }

  // ---------- CHECK-IN AT THE DOOR ----------
  // Checks a ticket in and shows who it is, what they booked, whether they've paid and any note.
  async function checkIn(code, again) {
    try {
      const t = await q(sb.rpc("check_in_details", { p_code: code }));
      const ok = t.status === "booked" && !t.already;
      const head = t.status === "pending" ? "Not approved yet, not booked" : t.status === "declined" ? "This booking was declined" : t.status === "waitlist" ? "On the waitlist, not booked" : t.status === "cancelled" ? "This booking was cancelled" : t.already ? "Already checked in" : "Checked in ✓";
      const row = (k, v) => `<div class="list-row"><span class="muted">${k}</span><b style="text-align:right">${v}</b></div>`;
      modal(`<button class="close" aria-label="Close">×</button>
        <p class="${ok ? "" : "note"}" style="font-size:18px;margin:0 0 6px"><b>${head}</b></p>
        <h2 style="font-size:26px;margin:0 0 12px">${esc(t.guest_name || t.name)}</h2>
        ${row("Event", `${esc(t.title)} · ${short(parseDay(t.day))} ${hhmm(t.time)}`)}
        ${row("Places", t.places)}
        ${t.age || t.gender ? row("Age", `${t.age ? esc(t.age) : "?"}${t.gender ? ` · ${esc(t.gender)}` : ""}`) : ""}
        ${t.guest ? row("Guest", t.booked_by ? `invited by ${esc(t.booked_by)}` : "yes") : t.booked_by ? row("Booked by", esc(t.booked_by)) : ""}
        ${Number(t.amount) > 0 ? row("Payment", t.paid ? `Paid ${money(t.amount)}${t.method ? ` (${esc(t.method)})` : ""}` : `<span style="color:var(--warn,#e0a030)">${money(t.amount)} to pay</span>`) : row("Payment", "Free")}
        ${t.age && t.age < 16 ? row("Under 16", t.parent_ok ? "Parent permission given" : '<span style="color:var(--warn,#e0a030)">No parent permission recorded</span>') : ""}
        <div class="form-actions"><button class="btn solid block" id="ciNext">${again ? "Scan the next ticket" : "Done"}</button></div>`, (m) => {
        $("#ciNext", m).onclick = () => { closeModal(); if (again) scanTicket(checkIn); };
      });
    } catch (e) { fail(e); if (again) setTimeout(() => scanTicket(checkIn), 1200); }
  }
  // Opens the camera and reads a ticket's QR code. Uses the phone's own reader where it has one.
  async function scanTicket(onCode) {
    if (!navigator.mediaDevices?.getUserMedia) return toast("This phone can't open the camera here. Type the code instead");
    modal(`<button class="close" aria-label="Close">×</button><h2>Scan a ticket</h2>
      <video id="cam" playsinline muted style="width:100%;border-radius:12px;background:#000;aspect-ratio:1;object-fit:cover"></video>
      <p class="muted">Point the camera at the QR code on their ticket.</p>`);
    let stream;
    try { stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" }, audio: false }); }
    catch { closeModal(); return toast("Camera not allowed. Allow camera access, or type the code instead"); }
    const video = $("#cam"); video.srcObject = stream; await video.play().catch(() => {});
    let detect;
    if ("BarcodeDetector" in window) {
      const bd = new BarcodeDetector({ formats: ["qr_code"] });
      detect = async () => (await bd.detect(video))[0]?.rawValue;
    } else {
      if (!window.jsQR) await new Promise((ok, no) => { const s = document.createElement("script"); s.src = "vendor/jsqr.js"; s.onload = ok; s.onerror = no; document.head.appendChild(s); }).catch(() => {});
      const c = document.createElement("canvas"), cx = c.getContext("2d", { willReadFrequently: true });
      detect = async () => {
        if (!window.jsQR || !video.videoWidth) return null;
        c.width = video.videoWidth; c.height = video.videoHeight; cx.drawImage(video, 0, 0);
        return window.jsQR(cx.getImageData(0, 0, c.width, c.height).data, c.width, c.height)?.data;
      };
    }
    const stop = () => stream.getTracks().forEach((t) => t.stop());
    const tick = async () => {
      if ($("#modal").hidden || !$("#cam")) return stop();
      const code = await detect().catch(() => null);
      if (code) { stop(); closeModal(); return onCode(code.trim(), true); }
      setTimeout(tick, 250);
    };
    tick();
  }

  // ---------- ORGANISER TOOLS ----------
  async function admin(el, alive) {
    if (!isOrg()) { el.innerHTML = '<div class="empty"><h2>Organisers only</h2></div>'; return; }
    loading(el);
    const [evs, bks, guests, members, fs] = await Promise.all([
      q(sb.from("events").select("*").order("day", { ascending: false }).limit(40)),
      q(sb.from("bookings").select("*").neq("status", "cancelled")),
      q(sb.from("guests").select("*, profiles(name)")),
      q(sb.from("profiles").select("*").order("name")),
      q(sb.from("fund_state").select("*").single()),
    ]);
    if (!alive()) return;
    const g = Object.fromEntries(guests.map((x) => [x.booking_id, x]));
    const ROLES = ["member", "organiser", "admin"];
    const pending = isAdmin() ? members.filter((m) => m.approved === false) : [];
    const ids = pending.map((m) => m.id);
    const [pcs, apps] = ids.length ? await Promise.all([q(sb.from("member_postcodes").select("*").in("user_id", ids)), q(sb.from("applications").select("*").in("user_id", ids))]) : [[], []];
    if (!alive()) return;
    el.innerHTML = `<div class="pad" style="padding-top:24px">
      <h1>Organiser tools</h1>
      ${pending.length ? `<h2>Waiting for approval</h2>
      <p class="muted">New members can't book or post until you approve them. Their full answers are also in your Google Sheet. Anyone who hasn't sent the application within 24 hours of joining is removed automatically.</p>
      ${pending.map((m) => {
        const pc = pcs.find((x) => x.user_id === m.id), ap = apps.find((x) => x.user_id === m.id);
        const far = pc && (pc.miles == null || Number(pc.miles) > HOME_MILES);
        return `<div class="card" style="padding:14px;margin-bottom:10px"><b>${esc(m.name)}</b>
          <div class="muted">${pc ? `${esc(pc.postcode)}${pc.miles != null ? ` · ${pc.miles} miles from BR3` : " · distance not checked"}` : "No postcode given"} · joined ${short(new Date(m.created_at))}</div>
          ${far ? '<span class="tag warn">Outside 5 miles</span>' : ""}
          ${ap ? `<p style="white-space:pre-line;margin:8px 0">${esc(ap.answers || "Application received.")}</p>` : `<p class="muted">No application yet. Removed ${short(new Date(new Date(m.created_at).getTime() + 864e5))} if none arrives.</p>`}
          <div class="row" style="gap:8px"><button class="btn solid small" data-approve="${m.id}">Approve</button><button class="btn small" data-decline="${m.id}" data-name="${esc(m.name)}">Decline</button></div></div>`;
      }).join("")}` : ""}
      <h2>Check someone in</h2>
      <button class="btn solid block" id="ciScan" style="margin-bottom:10px">Scan a ticket's QR code</button>
      <div class="row"><input id="ci" placeholder="Or type the code, e.g. AA-7K2QX" style="text-transform:uppercase"><button class="btn small" id="ciGo">Check in</button></div>
      <h2 style="margin-top:28px">Add an event</h2>
      <label>Event name</label><input id="t">
      <div class="grid2"><div><label>Date (leave empty if not decided)</label><input id="d" type="date"></div><div><label>Start time</label><input id="tm" type="time" value="19:00"></div></div>
      <label>Where</label><input id="loc">
      <div class="grid2"><div><label>Price per place (£, 0 = free)</label><input id="pr" type="number" min="0" step="0.5" value="0"></div><div><label>Places</label><input id="cap" type="number" min="1" value="30"></div></div>
      <label>Who can book</label><select id="acc">${accessOpts("members")}</select>
      <label>Details</label><textarea id="det"></textarea>
      <label>Picture (optional)</label><input id="pic" type="file" accept="image/*">
      <label>Link instead of booking here (optional, e.g. the debate's page in Let's Debate)</label><input id="lnk" type="url" placeholder="https://debate.ourhomelands.co.uk/debates/…">
      <div class="form-actions"><button class="btn solid block" id="add">Add event</button></div>
      <h2 style="margin-top:28px">Events and bookings</h2>
      <button class="btn block" id="csv">Download all event bookings (opens in Google Sheets or Excel)</button>
      ${evs.map((e) => {
        const list = bks.filter((b) => b.event_id === e.id);
        return `<details class="card adm" ${list.some((b) => b.status === "pending") ? "open" : ""}><summary><b>${esc(e.title)}</b> <span class="muted">${e.day ? short(parseDay(e.day)) : "Date TBC"} · ${list.reduce((t, b) => t + (b.status === "booked" ? b.places : 0), 0)}/${e.capacity}</span>${list.some((b) => b.status === "pending") ? ` <span class="tag warn">${list.filter((b) => b.status === "pending").length} to approve</span>` : ""}</summary>
          <div class="scroll"><table><thead><tr><th>Name</th><th>Who</th><th>Places</th><th>Status</th><th>Code</th></tr></thead><tbody>
          ${list.map((b) => `<tr><td>${esc(b.display_name)}</td><td>${g[b.id] ? `Guest, age ${g[b.id].age}, ${esc(g[b.id].email)}, invited by ${esc(g[b.id].profiles?.name || "?")}` : "Member"}</td><td>${b.places}</td><td>${b.status === "pending" ? `<b>Waiting for approval</b><br><button class="btn small" data-ok="${b.id}">Approve</button> <button class="btn small danger" data-no="${b.id}">Decline</button>` : b.status}${b.checked_in ? ", in" : ""}${b.paid || b.status === "pending" ? "" : ", unpaid"}${b.age < 16 && b.age ? `<br>Under 16, parent permission: ${b.parent_ok ? "yes" : "no"}` : ""}</td><td class="mono">${b.code}</td></tr>`).join("") || '<tr><td colspan="5" class="muted">No bookings yet.</td></tr>'}
          </tbody></table></div>
          ${e.kind === "event" ? `<div class="grid2" data-edit="${e.id}"><div><label>Date</label><input data-f="day" type="date" value="${e.day || ""}"></div><div><label>Start time</label><input data-f="time" type="time" value="${hhmm(e.time)}"></div>
            <div><label>Price (£)</label><input data-f="price" type="number" min="0" step="0.5" value="${Number(e.price)}"></div><div><label>Places</label><input data-f="capacity" type="number" min="1" value="${e.capacity}"></div>
            <div style="grid-column:1/-1"><label>Who can book</label><select data-f="access">${accessOpts(e.access)}</select></div>
            <div style="grid-column:1/-1"><label>Link instead of booking here (optional)</label><input data-f="link" type="url" value="${esc(e.link || "")}" placeholder="https://debate.ourhomelands.co.uk/debates/…"></div>
            <div style="grid-column:1/-1"><label>Picture</label>${e.image ? `<img class="event-pic" src="${esc(e.image)}" alt="">` : ""}<input data-pic="${e.id}" type="file" accept="image/*">${e.image ? `<button class="btn small" data-nopic="${e.id}" style="margin-top:8px">Remove picture</button>` : ""}</div></div>
            <div class="row" style="margin:12px 0"><button class="btn small" data-upd="${e.id}">Save changes</button><button class="btn small" data-poster="${e.id}">QR code poster</button></div>` : ""}
          <button class="btn small danger" data-del="${e.id}">Remove event</button></details>`;
      }).join("")}
      <h2 style="margin-top:28px">Members</h2>
      <p class="muted">Family members pay by transfer and never by card. Tick Kitty for anyone who has already paid £15 for the current kitty. Untick Football for events-only members.${isAdmin() ? " Only you, as admin, can change roles." : ""}</p>
      ${members.map((m) => `<div class="member-row" data-mid="${m.id}"><b>${esc(m.name)}</b>
        <div class="row" style="flex-wrap:wrap;gap:8px">
          <select data-f="role" ${isAdmin() ? "" : "disabled"}>${ROLES.map((r) => `<option ${m.role === r ? "selected" : ""}>${r}</option>`).join("")}</select>
          <label class="check"><input type="checkbox" data-f="family" ${m.family ? "checked" : ""}> Family</label>
          <label class="check"><input type="checkbox" data-f="football" ${m.football !== false || m.family ? "checked" : ""}> Football</label>
          <label class="check"><input type="checkbox" data-f="kitty" ${m.kitty_session === fs.session_no ? "checked" : ""}> Kitty ${fs.session_no}</label>
          <label class="check">Credit £<input data-f="credit" type="number" step="1" min="0" value="${Number(m.credit)}" style="width:70px"></label>
          <button class="btn small" data-save="${m.id}">Save</button></div></div>`).join("")}
      ${isAdmin() ? `<h2 style="margin-top:28px">Starting funds</h2>
        <p class="muted">Use once to bring the balances over from WhatsApp. Kitty ${fs.session_no}, ${fs.games_played} of 5 games played.</p>
        <div class="grid2"><div><label>Kitty fund £</label><input id="fk" type="number" step="0.01" value="${fs.kitty}"></div><div><label>Events fund £</label><input id="fe" type="number" step="0.01" value="${fs.events}"></div><div><label>Credits £ (from members' accounts)</label><input id="fc" type="number" value="${fs.credits || 0}" readonly></div>
        <div><label>Kitty number</label><input id="fn" type="number" min="1" value="${fs.session_no}"></div><div><label>Games played in this kitty</label><input id="fg" type="number" min="0" max="4" value="${fs.games_played}"></div></div>
        <div class="form-actions"><button class="btn block" id="setF">Set funds</button></div>` : ""}
    </div>`;
    el.querySelectorAll("[data-approve]").forEach((b) => (b.onclick = async () => {
      try { await q(sb.rpc("approve_member", { p_id: b.dataset.approve })); toast("Approved"); refresh(); } catch (e) { fail(e); }
    }));
    el.querySelectorAll("[data-decline]").forEach((b) => (b.onclick = async () => {
      if (!confirm(`Decline ${b.dataset.name}? Their account will be removed.`)) return;
      try { await q(sb.rpc("decline_member", { p_id: b.dataset.decline })); toast("Declined and removed"); refresh(); } catch (e) { fail(e); }
    }));
    $("#ciGo", el).onclick = () => { const c = $("#ci", el).value.trim(); if (!c) return toast("Type the ticket code"); $("#ci", el).value = ""; checkIn(c); };
    $("#ciScan", el).onclick = () => scanTicket(checkIn);
    $("#add", el).onclick = async () => {
      const ev = { kind: "event", title: $("#t", el).value.trim(), day: $("#d", el).value, time: $("#tm", el).value, location: $("#loc", el).value.trim(),
        price: Number($("#pr", el).value) || 0, capacity: Number($("#cap", el).value) || 1, access: $("#acc", el).value, details: $("#det", el).value.trim(),
        link: $("#lnk", el).value.trim() || null };
      if (!ev.title || !ev.time) return toast("Fill in at least the name and start time");
      if (ev.link && !/^https?:\/\//.test(ev.link)) return toast("The link should start with https://");
      if (!ev.day) ev.day = null; // date to be confirmed
      const file = $("#pic", el).files[0];
      if (file) ev.image = await picture(file);
      try { await q(sb.from("events").insert(ev)); toast("Event added"); refresh(); } catch (e) { fail(e); }
    };
    $("#csv", el).onclick = () => {
      const evMap = Object.fromEntries(evs.map((e) => [e.id, e])), who = Object.fromEntries(members.map((x) => [x.id, x.name]));
      const head = ["Event", "Date", "Time", "Name", "Age", "Male/Female", "Places", "Member or guest", "Guest email", "Invited or booked by", "Status", "Paid", "Amount £", "Checked in", "Under 16 parent permission", "Ticket code", "Booked on"];
      const rows = bks.filter((b) => evMap[b.event_id]?.kind === "event")
        .sort((a, b) => (evMap[a.event_id].day || "9").localeCompare(evMap[b.event_id].day || "9") || evMap[a.event_id].title.localeCompare(evMap[b.event_id].title) || a.display_name.localeCompare(b.display_name))
        .map((b) => { const e = evMap[b.event_id], gu = g[b.id];
          return [e.title, e.day || "TBC", hhmm(e.time), b.display_name, b.age ?? gu?.age ?? "", b.gender || "", b.places, gu ? "Guest" : "Member", gu?.email || "",
            gu ? gu.profiles?.name || "" : b.booked_by ? who[b.booked_by] || "" : "", b.status, b.paid ? "Yes" : "No", Number(b.amount || 0).toFixed(2), b.checked_in ? "Yes" : "No",
            b.age && b.age < 16 ? (b.parent_ok ? "Yes" : "No") : "", b.code, (b.created_at || "").slice(0, 10)]; });
      const cell = (v) => { const t = String(v ?? ""); return /[",\n\r]/.test(t) || /^[=+\-@]/.test(t) ? `"${(/^[=+\-@]/.test(t) ? "'" : "") + t.replace(/"/g, '""')}"` : t; };
      const csv = "\ufeff" + [head, ...rows].map((r) => r.map(cell).join(",")).join("\r\n");
      const a = document.createElement("a"); a.href = URL.createObjectURL(new Blob([csv], { type: "text/csv" }));
      a.download = `event-bookings-${dayKey(new Date())}.csv`; a.click(); setTimeout(() => URL.revokeObjectURL(a.href), 5000);
      if (!rows.length) toast("No event bookings yet, the file only has headings");
    };
    const decide = (id, ok) => q(sb.rpc("decide_booking", { p_id: id, p_ok: ok })).then((v) => { toast(ok ? (v === "waitlist" ? "Approved, but it's full so they're on the waitlist" : "Approved") : "Declined"); refresh(); }).catch(fail);
    el.querySelectorAll("[data-ok]").forEach((b) => (b.onclick = () => decide(b.dataset.ok, true)));
    el.querySelectorAll("[data-no]").forEach((b) => (b.onclick = () => confirm("Decline this booking?") && decide(b.dataset.no, false)));
    el.querySelectorAll("[data-poster]").forEach((b) => (b.onclick = () => posterModal(evs.find((x) => x.id === b.dataset.poster))));
    el.querySelectorAll("[data-upd]").forEach((b) => (b.onclick = async () => {
      const box = $(`[data-edit="${b.dataset.upd}"]`, el), f = (k) => $(`[data-f="${k}"]`, box).value;
      const upd = { day: f("day") || null, time: f("time"), price: Number(f("price")) || 0, capacity: Number(f("capacity")) || 1, access: f("access"), link: f("link").trim() || null };
      if (upd.link && !/^https?:\/\//.test(upd.link)) return toast("The link should start with https://");
      const file = $(`[data-pic="${b.dataset.upd}"]`, box).files[0];
      if (file) upd.image = await picture(file);
      try { await q(sb.from("events").update(upd).eq("id", b.dataset.upd)); toast(upd.day ? "Saved" : "Saved, date still to be confirmed"); refresh(); } catch (e) { fail(e); }
    }));
    el.querySelectorAll("[data-nopic]").forEach((b) => (b.onclick = async () => {
      try { await q(sb.from("events").update({ image: null }).eq("id", b.dataset.nopic)); toast("Picture removed"); refresh(); } catch (e) { fail(e); }
    }));
    el.querySelectorAll("[data-del]").forEach((b) => (b.onclick = async () => {
      if (b.dataset.sure !== "1") { b.dataset.sure = "1"; b.textContent = "Tap again to remove it and its bookings"; return; }
      try { await q(sb.from("events").delete().eq("id", b.dataset.del)); toast("Event removed"); refresh(); } catch (e) { fail(e); }
    }));
    el.querySelectorAll("[data-save]").forEach((b) => (b.onclick = async () => {
      const row = b.closest("[data-mid]"), f = (k) => $(`[data-f="${k}"]`, row);
      try {
        await q(sb.rpc("update_member", { p_id: b.dataset.save, p_role: isAdmin() ? f("role").value : null, p_family: f("family").checked, p_credit: Number(f("credit").value) || 0 }));
        const m = members.find((x) => x.id === b.dataset.save);
        if (f("football").checked !== (m.football !== false)) await q(sb.rpc("set_member_football", { p_id: m.id, p_on: f("football").checked }));
        if (f("kitty").checked !== (m.kitty_session === fs.session_no)) await q(sb.rpc("set_kitty", { p_id: m.id, p_on: f("kitty").checked }));
        if (b.dataset.save === me.id) await loadMe();
        toast("Saved");
      } catch (e) { fail(e); }
    }));
    const sf = $("#setF", el);
    if (sf) sf.onclick = async () => {
      try { await q(sb.rpc("set_funds", { p_kitty: Number($("#fk", el).value), p_events: Number($("#fe", el).value), p_credits: Number($("#fc", el).value), p_session: Number($("#fn", el).value), p_games: Number($("#fg", el).value) })); toast("Funds set"); refresh(); } catch (e) { fail(e); }
    };
  }

  // ---------- header screens ----------
  function messages(el) {
    el.innerHTML = `<div class="pad" style="padding-top:24px"><h1>Messages</h1>
      <p class="muted">Chat with ${esc(C.contactName)}.</p>
      <div id="thread">${state.messages.map((m) => `<div class="comment" style="margin-left:40px;background:var(--green-soft)">${esc(m)}</div>`).join("")}</div>
      <textarea id="t" placeholder="Type a message..." style="min-height:80px;margin-top:12px"></textarea>
      <div class="form-actions" style="display:grid;gap:10px">
        <button class="btn solid block" id="send">Send on WhatsApp</button>
      </div></div>`;
    $("#send", el).onclick = () => {
      const t = $("#t", el).value.trim(); if (!t) return;
      state.messages.push(t); save();
      window.open(`https://wa.me/${C.whatsapp}?text=${encodeURIComponent(t)}`, "_blank");
      render();
    };
  }
  function notifications(el) {
    state.seenNotes = D.announcements.length; save();
    el.innerHTML = `<div class="pad" style="padding-top:24px"><h1>Notifications</h1>` +
      (D.announcements.map((a) => `<div class="list-row"><div><b style="font-size:16px">${esc(D.admin.name)}</b><span class="muted">${bold(a.text)}</span><div class="muted" style="font-size:13px;margin-top:4px">${agoLong(a.date)}</div></div></div>`).join("")
        || '<div class="empty"><h2>You\'re all caught up</h2></div>') + "</div>";
  }

  // A password-reset link lands here with a temporary session.
  function newPassword() {
    if (newPassword.shown) return; newPassword.shown = true;
      modal(`<h2>Choose a new password</h2><input id="np" type="password" minlength="6" autocomplete="new-password"><div class="form-actions"><button class="btn solid block" id="ok">Save password</button></div>`, (m) => {
        $("#ok", m).onclick = async () => {
          try { await q(sb.auth.updateUser({ password: $("#np", m).value })); closeModal(); toast("Password changed"); await loadMe(); go("events"); } catch (e) { fail(e); }
        };
      });
  }
  sb.auth.onAuthStateChange((event) => { if (event === "PASSWORD_RECOVERY") setTimeout(newPassword); });

  // Card payments: "Pay by card" opens Square's checkout, which sends people back here with ?paid=CODE.
  document.addEventListener("click", async (e) => {
    const b = e.target.closest("[data-pay]"); if (!b) return;
    e.preventDefault(); b.disabled = true; const label = b.textContent; b.textContent = "Opening secure payment…";
    try {
      const r = await payApi({ code: b.dataset.pay, guest: b.dataset.guest === "1" });
      if (r.url) { location.href = r.url; return; }
      if (r.paid) { toast("Already paid, thank you"); closeModal(); refresh(); }
    } catch (err) { fail(err); }
    b.disabled = false; b.textContent = label;
  });
  async function payApi(body) {
    const res = await fetch("/.netlify/functions/pay", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
    const r = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(r.error || "Card payments aren't available right now. Please pay the organiser by bank transfer.");
    return r;
  }
  async function confirmReturn() {
    const code = new URLSearchParams(location.search).get("paid"); if (!code) return;
    history.replaceState(null, "", location.pathname + location.hash);
    try {
      const r = await payApi({ code, confirm: true });
      toast(r.paid ? "Payment received, thank you!" : "We haven't had confirmation from Square yet. It'll update shortly.");
    } catch (err) { fail(err); }
  }

  loadMe().catch(() => {}).then(confirmReturn).finally(async () => {
    if (RECOVERY || AUTH_ERROR) history.replaceState(null, "", location.pathname + location.search);
    await render();
    if (AUTH_ERROR) modal(`<h2>That link didn't work</h2><p class="muted" style="line-height:1.5">${esc(AUTH_ERROR)}. Reset links work once and expire after an hour, so tap "Forgot your password?" on the sign-in page to get a new one.</p>`);
    else if (RECOVERY && (await sb.auth.getSession()).data.session) newPassword();
  });

  // "Add to home screen" pop-up. Android/Chrome installs with one tap; iPhone needs the Share menu.
  let installEvt = null;
  window.addEventListener("beforeinstallprompt", (e) => { e.preventDefault(); installEvt = e; });
  const INSTALL_KEY = "homelands-install-later";
  const installed = () => matchMedia("(display-mode: standalone)").matches || navigator.standalone === true;
  const isIOS = () => /iphone|ipad|ipod/i.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  function offerInstall() {
    if (installed() || !$("#modal").hidden) return;
    try { if (Date.now() < Number(localStorage.getItem(INSTALL_KEY) || 0)) return; } catch {}
    if (!installEvt && !isIOS()) return;
    const later = () => { try { localStorage.setItem(INSTALL_KEY, String(Date.now() + 7 * 864e5)); } catch {} closeModal(); };
    modal(`<button class="close" aria-label="Close">×</button>
      <div class="row" style="gap:14px"><img src="images/icon-192.png" alt="" style="width:56px;height:56px;border-radius:12px"><h2 style="margin:0">Add Homelands to your home screen</h2></div>
      <p class="muted" style="margin-top:12px">Open the app in one tap, like any other app on your phone.</p>
      ${installEvt ? "" : `<ol style="margin:12px 0 0 20px;line-height:1.7"><li>Tap the Share button <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" style="vertical-align:-4px"><path d="M12 3v12M8 7l4-4 4 4M6 11v9h12v-9"/></svg> at the bottom of Safari</li><li>Scroll down and tap <b>Add to Home Screen</b></li><li>Tap <b>Add</b></li></ol>`}
      <div class="form-actions">${installEvt ? `<button class="btn solid block" id="instGo">Add to home screen</button>` : ""}
        <button class="btn block" id="instLater" style="margin-top:10px">${installEvt ? "Not now" : "Got it"}</button></div>`, (m) => {
      $("#instLater", m).onclick = later;
      $(".close", m).onclick = later;
      const go = $("#instGo", m);
      if (go) go.onclick = async () => { const e = installEvt; installEvt = null; closeModal(); e.prompt(); try { await e.userChoice; } catch {} };
    });
  }
  window.addEventListener("load", () => setTimeout(offerInstall, 4000));
  // Phones keep a home-screen app paused, so check for a new version whenever it comes back
  // to the front, and reload once when one has been installed.
  if ("serviceWorker" in navigator && location.protocol.startsWith("http")) {
    const hadWorker = !!navigator.serviceWorker.controller;
    navigator.serviceWorker.register("sw.js").then((reg) => {
      document.addEventListener("visibilitychange", () => document.visibilityState === "visible" && reg.update().catch(() => {}));
    }).catch(() => {});
    let reloaded = false;
    navigator.serviceWorker.addEventListener("controllerchange", () => { if (hadWorker && !reloaded) { reloaded = true; location.reload(); } });
  }
})();
