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
  // Organisers do door duty only (scan tickets, see who's in, tick people in, add people at the pitch).
  // Everything else in the organiser screens is for the admin.
  const isAdmin = () => !!me && me.role === "admin";
  const isOrg = isAdmin;
  const isDoor = () => !!me && (me.role === "organiser" || me.role === "admin");
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
    // Events this person supervises, while their access lasts (empty until add-event-supervisors.sql is run).
    if (me) me.sup = await sb.from("event_supervisors").select("event_id,role,events(*)").eq("user_id", me.id)
      .then((r) => (r.data || []).filter((x) => x.events?.day && (x.events.weekly || supUntil(x.events) > new Date())), () => []);
  }
  // ---------- event supervisors ----------
  // Shafi's call for supervisors (20 Nov), shown on every advert that has applications open and no blurb of its own.
  const SUP_BLURB = "Want to make this happen, we are looking for UP TO A MAXIMUM of three 2-man teams, 6 members to take this forward. For some events we just need one or two to step up, for others a little more, to know how many we need just click to apply and help make this a great memory for everyone.\n\nOur larger events will be open to the public, so long as they book through our portal, and are happy with who we all are, which you can see in About Us, and the Welcome & Our Agreement, to which they are each signposted.\n\nOne team will man the door and be charged with SECURITY. A second team will be concerned with crowd management and ensuring the attendees needs are seen to and are charged with SAFETY. The third team will run the event and will ensure it’s MEMORABLE. You should apply singly with your preferences within the app about what you help with. We will form the team and encourage for you, each, to float between roles.\n\nYou will need to attend pre and post event meetings, the post-event meetings for a debrief.";
  // The standard call with About Us and Welcome & Our Agreement as links.
  const supBlurbHtml = () => esc(SUP_BLURB).replace("About Us", '<a href="#about" data-close>About Us</a>').replace("Welcome &amp; Our Agreement", '<a href="#welcome" data-close>Welcome &amp; Our Agreement</a>');
  const SUP_ROLES = { door: "Door and entrance security", crowd: "Audience control: keeping order inside, for safety", run: "Running the show up front: making it memorable and fun" };
  // A supervisor's scanning access ends at 4am the morning after the event (the database checks this too).
  const supUntil = (ev) => at(ev.day, "04:00", 1);
  // Applications are open until the end of the deadline day, and never after the event.
  const supOpen = (ev) => !!ev.supervisors_open && supNeeded(ev) > 0 && (!ev.supervisor_deadline || parseDay(ev.supervisor_deadline) >= today()) && (!ev.day || ev.weekly || parseDay(ev.day) >= today());
  // Hall events have 6 supervisors in 3 teams of 2. Any other event (football, Quran…) has a number needed, 1 to 6, and its own blurb.
  // How many supervisors each role needs at this event, 0 to 2 (the admin sets them per event).
  // Not set yet: hall events 2 / 2 / 2, anything else 2 on the door.
  const supCount = (ev, r) => (["sup_door", "sup_crowd", "sup_run"].every((k) => ev[k] == null)
    ? (ev.kind === "event" && !ev.weekly ? 2 : r === "door" ? 2 : 0) : Number(ev["sup_" + r]) || 0);
  const supRoles = (ev) => Object.keys(SUP_ROLES).filter((r) => supCount(ev, r) > 0);
  const supNeeded = (ev) => supRoles(ev).reduce((t, r) => t + supCount(ev, r), 0);
  // The standard call is for the full 3 teams of 2 at a hall event.
  const supStandard = (ev) => ev.kind === "event" && !ev.weekly && supRoles(ev).length === 3 && supNeeded(ev) === 6;
  const supNeededText = (ev) => `${supNeeded(ev)} supervisor${supNeeded(ev) === 1 ? "" : "s"} needed`;
  const supRoleList = (ev) => `<ul class="sup-roles">${supRoles(ev).map((r) => `<li>${SUP_ROLES[r]}: <b>${supCount(ev, r)}</b></li>`).join("")}</ul>`;
  // Supervising a Friday game: the Football Supervisors screen for it, until 4am Saturday.
  const supFootball = () => !!me?.sup?.some((x) => x.events?.kind === "football");
  const supDeadline = (ev) => (ev.supervisor_deadline ? (() => { const d = parseDay(ev.supervisor_deadline); return `${DAYS[d.getDay()]} ${d.getDate()} ${MONTHS_LONG[d.getMonth()]}`; })() : "");

  // ---------- helpers ----------
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  // Turn web addresses in already-escaped text into links that open in a new tab (like WhatsApp).
  const linkify = (h) => h.replace(/\b(?:https?:\/\/|www\.)(?:[^\s<&]|&amp;)+/gi, (m) => {
    const tail = (m.match(/[.,!?;:)\]]+$/) || [""])[0], url = tail ? m.slice(0, -tail.length) : m;
    return `<a href="${/^www\./i.test(url) ? "https://" + url : url}" target="_blank" rel="noopener noreferrer">${url}</a>${tail}`;
  });
  const bold = (s) => linkify(esc(s).replace(/\*\*(.+?)\*\*/g, "<b>$1</b>"));
  const escLinks = (s) => linkify(esc(s));
  // YouTube links also show the video's opening picture underneath, like WhatsApp. The picture comes
  // straight from YouTube using the video's id, so no account or key is needed. Tapping it opens the video.
  const ytIds = (s) => {
    const ids = [], re = /(?:youtube\.com\/(?:watch\?(?:[^\s#]*&)?v=|shorts\/|live\/|embed\/)|youtu\.be\/)([\w-]{11})/gi;
    for (const m of String(s ?? "").matchAll(re)) if (!ids.includes(m[1])) ids.push(m[1]);
    return ids;
  };
  const ytCards = (s) => ytIds(s).map((id) => `<a class="yt-card" href="https://www.youtube.com/watch?v=${id}" target="_blank" rel="noopener noreferrer" aria-label="Watch on YouTube"><img src="https://i.ytimg.com/vi/${id}/hqdefault.jpg" alt="" loading="lazy"><span class="yt-play" aria-hidden="true"></span><span class="yt-label">▶ Watch on YouTube</span></a>`).join("");
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
  const closeModal = () => { $("#modal").hidden = true; delete $("#modal").dataset.locked; };
  // A locked pop-up (the welcome agreement) only closes from its own button.
  $("#modal").addEventListener("click", (e) => { if (!$("#modal").dataset.locked && (e.target.id === "modal" || e.target.classList.contains("close"))) closeModal(); });
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

  // Posters are loaded ahead of time, so sharing one still counts as part of the tap.
  const picFiles = {};
  const picFile = (src) => (picFiles[src] ||= fetch(src).then((r) => r.blob()).then((b) => new File([b], src.split("/").pop(), { type: b.type })));
  async function share(title, text, link, pic) {
    const url = link || location.href.split("#")[0];
    // With a poster, the link goes in the text so apps that keep only the picture and caption still get it.
    if (pic && navigator.canShare) {
      try {
        const files = [await picFile(pic)];
        if (navigator.canShare({ files })) {
          try { await navigator.share({ title, text: `${text} ${url}`, files }); return; }
          catch (e) { if (e.name === "AbortError") return; } // otherwise fall back to sharing just the link
        }
      } catch {}
    }
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
    bell: '<svg viewBox="0 0 24 24"><path d="M6 16V11a6 6 0 0 1 12 0v5l2 2H4zM10 20a2 2 0 0 0 4 0"/></svg>',
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
  const TABS = ["events", "groups", "schedule", "leaderboard", "more"];
  const ROUTES = { about, home: about, events, groups, grouplist, accounts, chat, schedule, more, services, counselling, messages, notifications, account, football, admin, funds, eventaccounts, weekly, squarecheck: weekly, supervisors, supervising, footballadmin, guest, welcome, leaderboard, join: joinGuide, ticket: ticketLink };
  const PARENT = { grouplist: "groups", accounts: "groups", chat: "groups", services: "more", counselling: "more", football: "events", funds: "more", eventaccounts: "more", weekly: "more", squarecheck: "more", supervisors: "more", supervising: "more", footballadmin: "more", guest: null, ticket: null, account: null, welcome: "more", join: "more", about: "more", admin: "more", messages: null, notifications: null };
  let lastTab = "events", seq = 0;

  function go(route) { if (location.hash.slice(1) === route) render(); else location.hash = route; }
  async function render() {
    const [route, arg] = decodeURIComponent(location.hash.slice(1) || "events").split(":");
    const fn = ROUTES[route] || events;
    if (TABS.includes(route)) lastTab = route;
    const active = TABS.includes(route) ? route : (PARENT[route] || lastTab);
    document.querySelectorAll("#tabbar button").forEach((b) => b.classList.toggle("active", b.dataset.tab === active));
    // Chat screens keep the logo header; their subhead link already goes back.
    $("#backBtn").hidden = TABS.includes(route) || ["home", "chat", "grouplist", "accounts"].includes(route);
    $("#brand").hidden = !$("#backBtn").hidden;
    updateBell();
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
  // Tap a receipt photo to see it full size.
  document.addEventListener("click", (e) => { const i = e.target.closest("img[data-zoom]"); if (i) modal(`<button class="close" aria-label="Close">×</button><img src="${esc(i.getAttribute("src"))}" alt="" style="width:100%;border-radius:8px;margin-top:30px">`); });
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
  // ---------- WELCOME AND OUR AGREEMENT ----------
  // Everyone agrees to this when they join. Members who joined before it was in the app agree once, the next time they open it.
  const WELCOME = `<div class="welcome">
    <h2>WELCOME TO OUR HOMELANDS BR3</h2>
    <p>This is simply a group of friends getting together to play football and enjoy other activities together. There is no formal organisation, and this is not associated with any Mosque. It is in the main for Muslims around Beckenham and our friends.</p>
    <p>If you are here, I consider you my friend, and we are all friends of one another.</p>
    <p><b>Joining</b> is by invitation and approval only, and is not a right.</p>
    <p><b>Even friends deserve respect.</b> There is a two strike rule. If you are in a fracas on the pitch, walk away. I'll give you the benefit of the doubt the first time. The second time, I'll say bye bye.</p>
    <p>If you undermine this group, its activities or its planning, or if I no longer consider you a friend to me or the group, your account may be removed without warning.</p>
    <p><b>Bringing people together</b> is both a blessing and a passion. Your friends are always welcome on the pitch, as long as you book them in and come with them. And more importantly we hope to organise far more than football for us all.</p>
    <p><b>This App is here to cement a community,</b><br>and if you want for us to all organise other things for one another please be in contact, and if you want the chats to encourage further conversation then let me know. Activity on the chat is rewarded within the chats themselves :))</p>
    <p><b>Inactive accounts</b> may be closed. Any credit you hold can be claimed for 12 months, after which it goes to charity on your behalf.</p>
    <p><b>The Al Ansaar Association</b> is not a charity, but an unincorporated Association of like minded people that supports grass roots initiatives like this, and forms the backdrop for this to happen.</p>
  </div>`;
  const longDate = (d) => `${d.getDate()} ${MONTHS_LONG[d.getMonth()]} ${d.getFullYear()}`;
  function welcome(el) {
    el.innerHTML = `<div class="pad" style="padding-top:24px">${WELCOME}
      ${me ? (me.agreed_at ? `<p class="note">You agreed to this on ${longDate(new Date(me.agreed_at))}.</p>` : '<div class="form-actions"><button class="btn solid block" id="agreeNow">I agree</button></div>') : ""}</div>`;
    const a = $("#agreeNow", el); if (a) a.onclick = () => agree().then(refresh).catch(fail);
  }
  // ---------- HOW TO JOIN AND INSTALL THE APP ----------
  // A step-by-step guide anyone can open without an account, to share on WhatsApp or show on a phone.
  function joinGuide(el) {
    const link = location.origin + location.pathname.replace(/index\.html$/, "");
    const guideLink = link + "#join";
    const ios = isIOS(), android = /android/i.test(navigator.userAgent), home = installed();
    const iphoneSteps = `<ol><li>Open the link in <b>Safari</b></li><li>Tap the Share button <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" style="vertical-align:-4px"><path d="M12 3v12M8 7l4-4 4 4M6 11v9h12v-9"/></svg> at the bottom (or top) of the screen</li><li>Scroll down and tap <b>Add to Home Screen</b></li><li>Tap <b>Add</b>. The Homelands icon appears on your home screen</li></ol>`;
    const androidSteps = `<ol><li>Open the link in <b>Chrome</b></li><li>Tap the <b>⋮</b> menu at the top right</li><li>Tap <b>Add to home screen</b> or <b>Install app</b></li><li>Tap <b>Install</b>. The Homelands icon appears on your home screen</li></ol>`;
    const step = (n, title, body) => `<div class="step"><span class="num">${n}</span><div><h3>${title}</h3>${body}</div></div>`;
    const pushState = !pushSupported() ? "" : Notification.permission === "granted" ? '<p class="ok">✓ Notifications are on for this phone.</p>'
      : Notification.permission === "default" && me && !pending() ? '<button class="btn solid block" id="gPush">Turn on notifications</button>' : "";
    el.innerHTML = `<div class="pad guide" style="padding-top:24px">
      <h1>How to join and install the app</h1>
      <p style="line-height:1.5">Our community is moving from WhatsApp to this app, for football, events and chats. It takes about five minutes. If you get stuck, ask anyone at Friday football and we'll help.</p>
      ${step(1, "Open the app", `<p>On your phone, open <a href="${esc(link)}">${esc(link.replace(/^https?:\/\//, "").replace(/\/$/, ""))}</a>. On an iPhone, use Safari.</p>
        <details class="past"><summary>Show a QR code to scan</summary><div id="gQr" class="guide-qr"></div></details>`)}
      ${step(2, "Join", me ? `<p class="ok">✓ You're signed in as ${esc(me.name)}.</p>` : `<p>Tap <b>Sign in or join</b>, then <b>Join</b>. Fill in your full name, postcode, email and a password, read our welcome and tick to agree.</p><button class="btn solid block" data-go="account">Join now</button>`)}
      ${step(3, "Send your membership application", me && !pending() ? '<p class="ok">✓ You\'re approved.</p>' : `<p>Straight after joining you'll be asked to fill in a short membership application. Please do it then and there: accounts without one are removed after 24 hours. The admin then approves you, and you can book and post.</p>${me && pending() ? `<a class="btn solid block" href="${applyUrl()}" target="_blank" rel="noopener">Complete your application</a>` : ""}`)}
      ${step(4, "Add it to your home screen", home ? '<p class="ok">✓ Done. You\'re using the app from your home screen.</p>' : `<p>So it opens in one tap like any other app${ios ? ", and so it can send you notifications" : ""}.</p>
        ${installEvt ? '<button class="btn solid block" id="gInstall">Add to home screen</button>' : ""}
        ${ios || !android ? `<p><b>iPhone</b></p>${iphoneSteps}` : ""}
        ${android || !ios ? `<p><b>Android</b></p>${androidSteps}` : ""}`)}
      ${step(5, "Turn on notifications", `<p>Open the app from its new icon on your home screen. Tap the bell 🔔 at the top, then <b>Turn on notifications</b>, and tap <b>Allow</b>. You'll then get a buzz for announcements, new events, when football booking opens, and reminders before games you've booked. You choose what you get.</p>${pushState}`)}
      ${step(6, "You're in", `<p><b>Events</b> is where you book football and other events. <b>Chats</b> is for talking with everyone. <b>Schedule</b> shows your tickets. The bell 🔔 shows your notifications.</p>`)}
      <h2 style="margin-top:24px">Something not working?</h2>
      <details class="info"><summary><b>No buzz on my iPhone</b></summary><p>Notifications need iOS 16.4 or newer, and only work when you open the app from its home screen icon. Check that a Focus mode (like Personal or Sleep) isn't on: swipe down from the top right corner. Then open Settings, Notifications, Homelands, and make sure Allow Notifications is on.</p></details>
      <details class="info"><summary><b>I can't see Add to Home Screen</b></summary><p>On an iPhone, open the link in Safari rather than in WhatsApp or another app: press and hold the link and choose Open in Safari. On Android, open it in Chrome.</p></details>
      <details class="info"><summary><b>I forgot my password</b></summary><p>On the sign-in screen, type your email and tap <b>Forgot your password?</b>. We'll email you a link to choose a new one.</p></details>
      <details class="info"><summary><b>I've joined but can't book</b></summary><p>New members can look around but can't book or post until the admin approves them. Make sure you've sent the membership application (step 3).</p></details>
      <div class="form-actions" style="display:grid;gap:10px"><button class="btn solid block" id="gShare">${ICON.share} Share this guide</button></div>
    </div>`;
    qr($("#gQr", el), link, 200);
    $("#gShare", el).onclick = () => share("Join us on the Homelands app", "Our community is moving to the Homelands app for football, events and chats. Here's how to join and install it:", guideLink);
    const ins = $("#gInstall", el);
    if (ins) ins.onclick = async () => { const e = installEvt; installEvt = null; e.prompt(); try { await e.userChoice; } catch {} refresh(); };
    const gp = $("#gPush", el);
    if (gp) gp.onclick = () => { gp.disabled = true; turnOnPush().then(() => { toast("Notifications are on ✓"); refresh(); }).catch((e) => { gp.disabled = false; fail(e); }); };
  }
  async function agree() { await q(sb.rpc("agree_welcome")); await loadMe(); toast("Thank you, and welcome"); }
  // Shown once to signed-in members who haven't agreed yet. It stays until they tap I agree.
  function askAgreement() {
    // Only once the database has the agreed_at column (add-welcome-and-members.sql has been run).
    if (!me || !("agreed_at" in me) || me.agreed_at || isAdmin() || !$("#modal").hidden) return;
    modal(`<p class="muted" style="margin-top:0">Please read our welcome. We're now using the app to bring us all together, so we ask everyone to agree to it once.</p>
      <div class="welcome-scroll">${WELCOME}</div>
      <div class="form-actions"><button class="btn solid block" id="agreeGo">I agree</button></div>`, (m) => {
      $("#modal").dataset.locked = "1";
      $("#agreeGo", m).onclick = async () => { try { $("#agreeGo", m).disabled = true; await agree(); closeModal(); refresh(); } catch (e) { $("#agreeGo", m).disabled = false; fail(e); } };
    });
  }
  // Counts the days each member opens the app, for the admin's member search.
  function markSeen() {
    if (!me || state.seenDay === `${me.id}:${dayKey(new Date())}`) return;
    sb.rpc("i_was_here").then(({ error }) => { if (!error) { state.seenDay = `${me.id}:${dayKey(new Date())}`; save(); } });
  }
  document.addEventListener("visibilitychange", () => document.visibilityState === "visible" && markSeen());

  // ---------- LEADERBOARD ----------
  // The ten members who take part most in the app, this month or all time. It refreshes every 30 seconds while open.
  let lbPeriod = "month";
  async function leaderboard(el, alive) {
    if (!me) return needSignIn(el, "see the leaderboard");
    if (!el.firstChild) loading(el);
    const rows = await q(sb.rpc("leaderboard", { p_period: lbPeriod })).catch(() => null);
    if (!alive()) return;
    const MEDAL = ["🥇", "🥈", "🥉"];
    const top = (rows || []).filter((r) => !r.me || rows.indexOf(r) < 10), mine = (rows || []).find((r) => r.me);
    const bits = (r) => [[r.days, "day", "days"], [r.bookings, "booking", "bookings"], [r.posts, "post", "posts"], [r.comments, "comment", "comments"], [r.reactions, "reaction", "reactions"]]
      .filter(([n]) => n).map(([n, a, b]) => `${n} ${n === 1 ? a : b}`).join(" · ");
    const row = (r, i) => `<div class="lb-row ${r.me ? "me" : ""}"><span class="lb-rank">${r.rank <= 3 ? MEDAL[r.rank - 1] : r.rank}</span>
      <div class="avatar" style="width:40px;height:40px">${esc(initials(r.name))}</div>
      <div style="flex:1;min-width:0"><b>${esc(r.name)}${r.me ? " (you)" : ""}</b><div class="muted" style="font-size:13px">${bits(r)}</div></div><b class="lb-score">${r.score}</b></div>`;
    const inTop = top.some((r) => r.me);
    el.innerHTML = `<div class="pad" style="padding-top:20px">
      <h1>Leaderboard</h1>
      <p class="muted" style="line-height:1.5">Our most active members. Everything you do in the app counts, so join in to climb the table! Organisers aren't included.</p>
      <div class="seg"><button data-p="month" class="${lbPeriod === "month" ? "on" : ""}">${MONTHS_LONG[new Date().getMonth()]}</button><button data-p="all" class="${lbPeriod === "all" ? "on" : ""}">All time</button></div>
      ${rows === null ? '<p class="note">The leaderboard is being set up. Check back soon.</p>'
        : top.length ? `<div class="lb">${top.map(row).join("")}</div>${mine && !inTop ? `<p class="muted" style="margin:14px 0 4px">Your place</p><div class="lb">${row(mine)}</div>` : ""}`
        : '<p class="muted">Nobody has scored yet this month. Be the first!</p>'}
      ${rows && !mine && me.role === "member" ? '<p class="muted" style="margin-top:12px">You\'re not on the board yet. Book a game, post or react in the chats to get on it.</p>' : ""}
      <details class="info" style="margin-top:16px"><summary><b>How points work</b></summary>
        <p>1 point for each day you open the app<br>3 points for each booking, football or events (friends you book count too)<br>3 points for each post in the chats<br>2 points for each comment<br>1 point for each reaction or poll vote</p>
        <p class="muted">The table updates by itself while you're looking at it. The month's table starts again on the 1st.</p></details>
    </div>`;
    el.querySelectorAll("[data-p]").forEach((b) => (b.onclick = () => { lbPeriod = b.dataset.p; leaderboard(el, alive); }));
    clearTimeout(leaderboard.t);
    leaderboard.t = setTimeout(function tick() {
      if (!alive()) return;
      if (document.visibilityState === "visible") leaderboard(el, alive); else leaderboard.t = setTimeout(tick, 30000);
    }, 30000);
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
    const [list, places, mine] = await Promise.all([
      q(sb.from("events").select("*")),
      // Release unpaid places first, so the booked numbers don't count them. The rest loads meanwhile.
      sb.rpc("expire_unpaid").then(() => q(sb.rpc("event_places"))),
      me ? q(sb.from("bookings").select("id,event_id,status,code").eq("user_id", me.id).neq("status", "cancelled")) : [],
      myGroups(),
      sb.from("fund_state").select("intro_offer").single().then((r) => !!r.data?.intro_offer, () => false),
      sb.from("groups").select("id,guests_allowed").then((r) => (r.data || []).filter((x) => x.guests_allowed).map((x) => x.id), () => []),
      me ? sb.from("supervisor_applications").select("*").eq("user_id", me.id).then((r) => r.data || [], () => []) : [],
    ]).then(([l, p, m, g, io, gg, sa]) => { joined = g; introOn = io; guestGroups = gg; myApps = sa; return [l, p, m]; });
    if (!alive()) return;
    list.forEach(nextWeekly);
    const taken = Object.fromEntries(places.map((p) => [p.event_id, Number(p.taken)]));
    const myBk = Object.fromEntries(mine.map((b) => [b.event_id, b]));
    const now = new Date();
    // Upcoming first (soonest first), then dates to be confirmed, then past events (latest first).
    const rank = (e) => (!e.day ? 1 : eventEnd(e) < now ? 2 : 0);
    list.sort((a, b) => rank(a) - rank(b) || (rank(a) === 1 ? a.title.localeCompare(b.title) : rank(a) === 2 ? eventStart(b) - eventStart(a) : eventStart(a) - eventStart(b)));
    el.innerHTML = `<div class="events">
      ${offerBanner(list, false)}${introBanner(introOn, false)}
      ${isOrg() ? `<a class="btn block" href="#admin">${ICON.tools} Add or manage events</a>` : ""}
      ${list.map((ev) => eventCard(ev, taken[ev.id] || 0, myBk[ev.id])).join("") || '<div class="empty"><h2>No events yet</h2></div>'}</div>`;
    // A few seconds later, so the posters don't slow down the first load.
    if (navigator.canShare) setTimeout(() => [FOOTIE, QURAN].forEach((src) => picFile(src).catch(() => {})), 4000);
    el.querySelectorAll("[data-invite]").forEach((b) => (b.onclick = () => {
      shareEvent(list.find((x) => x.id === b.dataset.invite));
    }));
    el.querySelectorAll("[data-book]").forEach((b) => (b.onclick = () => bookSheet(list.find((x) => x.id === b.dataset.book), taken[b.dataset.book] || 0)));
    el.querySelectorAll("[data-ticket]").forEach((b) => (b.onclick = () => showTicket(b.dataset.ticket)));
    el.querySelectorAll("[data-join]").forEach((b) => (b.onclick = () => joinGroup(b.dataset.join)));
    const detail = (ev) => {
      const card = el.querySelector(`[data-event="${ev.id}"]`)?.closest("article");
      const act = card?.querySelector(".event-foot .go");
      modal(`${picOf(ev) ? `<img class="event-pic modal-pic" src="${esc(ev.image || (ev.kind === "football" ? FOOTIE : picOf(ev)))}" alt="">` : ""}<h2>${esc(ev.title)}</h2><p class="muted">${ev.day ? fmtEvent(ev) : "Date to be confirmed"}<br>${esc(ev.location || "")}</p><p style="line-height:1.5;white-space:pre-wrap">${escLinks(ev.details || "")}</p>${ytCards(ev.details)}
        ${supBox(ev)}
        <div class="form-actions">${act ? `<button class="btn solid block" id="dGo">${act.textContent}</button>` : ""}${isOrg() ? '<button class="btn block" id="dQr">QR code poster</button>' : ""}${isAdmin() && ev.kind === "event" ? '<button class="btn block" id="dEdit">Edit this event</button>' : ""}</div>`, (m) => {
        if (act) $("#dGo", m).onclick = () => { closeModal(); if (act.href) window.open(act.href, "_blank", "noopener"); else act.click(); };
        if (isOrg()) $("#dQr", m).onclick = () => posterModal(ev);
        if ($("#dEdit", m)) $("#dEdit", m).onclick = () => { closeModal(); go("admin:" + ev.id); };
        if ($("#supApply", m)) $("#supApply", m).onclick = () => supApply(ev, () => detail(ev));
        if ($("#supMine", m)) $("#supMine", m).onclick = () => { closeModal(); go("supervising"); };
        m.querySelectorAll("[data-close]").forEach((a) => (a.onclick = closeModal));
      });
    };
    el.querySelectorAll("[data-event]").forEach((b) => (b.onclick = () => detail(list.find((x) => x.id === b.dataset.event))));
    // A shared link or QR code opens that event straight away.
    const linked = arg && list.find((x) => x.id === arg);
    if (linked) { history.replaceState(null, "", location.pathname + "#events"); detail(linked); }
  }
  // While the admin has the new member offer switched on, a banner on Events and Football says so.
  let introOn = false;
  // Chats that non-members can read and join in as a guest (the Quran chat).
  let guestGroups = [];
  // This person's supervisor applications, keyed by event.
  let myApps = [];
  // The supervisor call inside an event's advert: the blurb, the deadline and Apply (or what they've applied for).
  function supBox(ev) {
    const team = me?.sup?.find((x) => x.event_id === ev.id);
    if (team) return `<div class="sup-box"><b>🙋 You're a supervisor for this event</b><p>Your role: <b>${SUP_ROLES[team.role] || "Supervisor"}</b>.${supStandard(ev) ? " Please come to the pre-event and post-event meetings." : ""}</p><button class="btn block sup-btn" id="supMine">Open supervisor tools</button></div>`;
    if (!supOpen(ev) || !supNeeded(ev)) return "";
    const app = myApps.find((a) => a.event_id === ev.id);
    return `<div class="sup-box"><b>🙋 Supervisor applications open</b>
      ${ev.supervisor_blurb ? `<p style="white-space:pre-wrap">${escLinks(ev.supervisor_blurb)}</p>` : `<p style="white-space:pre-line">${supBlurbHtml()}</p>`}
      <p><b>${supNeededText(ev)}</b></p>${supRoleList(ev)}
      ${ev.supervisor_deadline ? `<p><b>Application deadline: ${supDeadline(ev)}</b></p>` : ""}
      ${app ? `<p class="note">You've applied ✓${app.prefs?.length ? ` You'd like to help with: ${app.prefs.map((k) => SUP_ROLES[k]).join(", ")}.` : ""}</p>` : ""}
      ${!me ? '<button class="btn block" data-go="account" data-close>Sign in to apply</button>' : pending() ? '<p class="muted">You can apply once your membership is approved.</p>'
        : `<button class="btn block sup-btn" id="supApply">${app ? "Change or withdraw my application" : "Apply to be a supervisor"}</button>`}</div>`;
  }
  function supApply(ev, back) {
    const app = myApps.find((a) => a.event_id === ev.id);
    const has = (k) => (app ? app.prefs.includes(k) : false), roles = supRoles(ev), hall = ev.kind === "event" && !ev.weekly;
    modal(`<button class="close" aria-label="Close">×</button><h2>Supervise ${esc(ev.title)}</h2>
      <p class="muted">${ev.day ? (ev.weekly ? `Every ${DAYS[parseDay(ev.day).getDay()]}` : fmtEvent(ev)) : "Date to be confirmed"}${ev.supervisor_deadline ? ` · apply by ${supDeadline(ev)}` : ""}</p>
      ${roles.length > 1 ? `<p>Apply on your own. Tick everything you'd be happy to help with. We'll choose who does what, and you're welcome to float between roles on the night.</p>
      <div class="attend">${roles.map((k) => `<label class="check"><input type="checkbox" data-pref="${k}" ${has(k) ? "checked" : ""}> ${SUP_ROLES[k]} <span class="muted">(${supCount(ev, k)} needed)</span></label>`).join("")}</div>`
        : `<p>We need ${supCount(ev, roles[0])} for <b>${SUP_ROLES[roles[0]]}</b>. Apply on your own, and we'll choose from everyone who applies.</p>`}
      <label>Anything we should know? (optional)</label><textarea id="supNote" rows="3" maxlength="500">${esc(app?.note || "")}</textarea>
      ${hall ? `<label class="check"><input type="checkbox" id="supMeet" ${app ? "checked" : ""}> I can come to the pre-event meeting and the post-event debrief</label>` : ""}
      <div class="form-actions"><button class="btn solid block" id="supSend">${app ? "Save my application" : "Send my application"}</button>${app ? '<button class="btn block danger" id="supDrop">Withdraw my application</button>' : ""}</div>`, (m) => {
      $("#supSend", m).onclick = async () => {
        const prefs = roles.length > 1 ? [...m.querySelectorAll("[data-pref]:checked")].map((c) => c.dataset.pref) : roles;
        if (!prefs.length) return toast("Tick at least one thing you'd like to help with");
        if (hall && !$("#supMeet", m).checked) return toast("Supervisors need to come to the meetings before and after the event");
        try {
          await q(sb.rpc("apply_supervisor", { p_event: ev.id, p_prefs: prefs, p_note: $("#supNote", m).value }));
          myApps = [...myApps.filter((a) => a.event_id !== ev.id), { event_id: ev.id, prefs, note: $("#supNote", m).value }];
          toast(app ? "Application saved" : "Thanks, your application is in"); back();
        } catch (e) { fail(e); }
      };
      if ($("#supDrop", m)) $("#supDrop", m).onclick = async () => {
        try { await q(sb.from("supervisor_applications").delete().eq("event_id", ev.id).eq("user_id", me.id)); myApps = myApps.filter((a) => a.event_id !== ev.id); toast("Application withdrawn"); back(); } catch (e) { fail(e); }
      };
    });
  }
  const introBanner = (on, onFootball) => (on ? `<a class="offer${onFootball ? "" : " footie-offer"}" href="#football"><small>New member offer</small><b>New members, not in the kitty, pay just £1 for their first game</b>
      <span>Whilst the offer lasts.${onFootball ? "" : " Tap to book →"}</span></a>` : "");
  // A football game priced below the usual £6 gets a big banner on Events and Football.
  function offerBanner(games, onFootball) {
    const g = games.filter((e) => e.kind === "football" && e.day && Number(e.price) < 6 && eventEnd(e) > new Date()).sort((a, b) => eventStart(a) - eventStart(b))[0];
    if (!g) return "";
    const d = parseDay(g.day), when = `Friday ${d.getDate()} ${MONTHS_LONG[d.getMonth()]}`;
    return `<a class="offer${onFootball ? "" : " footie-offer"}" href="#football"><small>Launch offer</small><b>Book here for ${when} and get your place for just ${money(g.price).replace(".00", "")}</b>
      <span>${onFootball ? "Book below in the app. " : ""}Only for bookings made in the app.${onFootball ? "" : " Tap to book →"}</span></a>`;
  }
  function fmtEvent(ev) { if (!ev.day) return "Date to be confirmed"; const d = parseDay(ev.day); return `${DAYS[d.getDay()]} ${d.getDate()} ${MONTHS[d.getMonth()]} ${d.getFullYear()} | ${hhmm(ev.time).replace(/^0(\d)/, "$1")}`; }
  // An event can link elsewhere, e.g. to its debate in Let's Debate, instead of being booked here.
  const linkLabel = (url) => (/ourhomelands\.co\.uk\/debates\//.test(url) ? "Open in Let's Debate" : "Open link");
  const linkButton = (ev) => `<a class="go" href="${esc(ev.link)}" target="_blank" rel="noopener">${linkLabel(ev.link)}</a>`;
  // Friday football and the Quran group have their own posters, used when an event has no picture of its own.
  const FOOTIE = "images/footie.jpg", FOOTIE_BANNER = "images/footie-banner.jpg", QURAN = "images/quran.jpg", QURAN_BANNER = "images/quran-banner.jpg";
  const picOf = (ev) => ev.image || (ev.kind === "football" ? FOOTIE_BANNER : ev.group_id === "quran" ? QURAN_BANNER : "");
  const eventPic = (ev) => (picOf(ev) ? `<img class="event-pic" src="${esc(picOf(ev))}" alt="" data-event="${ev.id}">` : "");
  // "Supervisor applications open" on the advert, with the deadline.
  const supTag = (ev) => (supOpen(ev) ? `<span class="tag sup">🙋 Supervisor applications open${` · ${supNeeded(ev)} needed`}${ev.supervisor_deadline ? ` · apply by ${supDeadline(ev)}` : ""}</span>` : "");
  function eventCard(ev, taken, mine) {
    if (!ev.day) return `<article class="card">${eventPic(ev)}
      <div class="event-body" data-event="${ev.id}" style="cursor:pointer">
        <div class="event-date tbc"><div class="d">TBC</div><div class="m">Date</div></div>
        <div><h2>${esc(ev.title)}</h2><p>Date to be confirmed</p>${ev.location ? `<p>${esc(ev.location)}</p>` : ""}
          <div class="pills"><span class="tag">${Number(ev.price) > 0 ? money(ev.price) : "Free"}</span><span class="tag">${ACCESS_TAG[ev.access] || "Members only"}</span>${supTag(ev)}</div></div>
      </div>
      <div class="event-foot"><button data-invite="${ev.id}">${ICON.share.replace("viewBox", 'style="width:20px;height:20px" viewBox')} Share</button>${ev.link ? linkButton(ev) : '<button class="off" disabled>Booking opens soon</button>'}</div>
    </article>`;
    const d = parseDay(ev.day), past = eventEnd(ev) < new Date(), left = Math.max(0, ev.capacity - taken);
    const fb = ev.kind === "football";
    const pills = `<div class="pills"><span class="tag">${fb ? `${money(ev.price)} or kitty` : Number(ev.price) > 0 ? money(ev.price) : "Free"}</span>
      <span class="tag">${guestGroups.includes(ev.group_id) ? "Open to everyone" : ACCESS_TAG[ev.access] || "Members only"}</span>
      ${ev.weekly ? `<span class="tag gold">Every ${DAYS[d.getDay()]}</span>` : !past && !ev.link ? `<span class="tag ${left ? "" : "warn"}">${left ? `${left} of ${ev.capacity} places left` : "Full"}</span>` : ""}
      ${!past && !ev.group_id && !ev.link ? `<span class="tag gold">${taken} booked</span>` : ""}${past ? "" : supTag(ev)}</div>`;
    let action;
    if (past) action = '<button class="off" style="color:var(--muted)" disabled>Event has ended</button>';
    else if (ev.link) action = linkButton(ev);
    else if (ev.group_id && (!me || pending()) && guestGroups.includes(ev.group_id)) action = `<button class="go" data-go="chat:${esc(ev.group_id)}">${ev.group_id === "quran" ? "See the target · Join in" : "Open the chat · Join in"}</button>`;
    else if (ev.group_id && !me) action = '<button class="go" data-go="account">Sign in to sign up</button>';
    else if (pending() && !fb) action = '<button class="off" style="color:var(--muted)" disabled>Bookable once approved</button>';
    else if (ev.group_id) action = joined.includes(ev.group_id) ? '<button class="go" data-go="groups">Signed up ✓ · Open chat</button>' : `<button class="go" data-join="${esc(ev.group_id)}">Sign up · Free</button>`;
    else if (fb) action = `<button class="go" data-go="football">${mine ? "Booked ✓ · Open" : "Open football"}</button>`;
    else if (mine) action = `<button class="go" data-ticket="${mine.code}">${mine.status === "pending" ? "Applied · Waiting for approval" : mine.status === "declined" ? "Not approved" : mine.status === "waitlist" ? "On waitlist · Ticket" : "Booked ✓ · Ticket"}</button>`;
    else if (!me && ev.access === "members") action = '<button class="go" data-go="account">Members only · Sign in</button>';
    else if (ev.player_places != null && !me && appliedHere(ev)) action = `<button class="go" data-ticket="${appliedHere(ev)}">Applied · Check if approved</button>`;
    else if (ev.player_places != null) action = left ? `<button class="go" data-book="${ev.id}">Apply</button>` : '<button class="off" disabled>Full</button>';
    else action = `<button class="go" data-book="${ev.id}">${left ? "Book" : "Join waitlist"}</button>`;
    return `<article class="card${fb ? " footie-card" : ""}">${eventPic(ev)}
      <div class="event-body" data-event="${ev.id}" style="cursor:pointer">
        <div class="event-date"><div class="d">${d.getDate()}</div><div class="m">${MONTHS[d.getMonth()]}</div></div>
        <div><h2>${esc(ev.title)}</h2><p>${fmtEvent(ev)}</p><p>${esc(ev.location)}</p>${pills}</div>
      </div>
      <div class="event-foot">${past ? "" : `<button data-invite="${ev.id}">${ICON.share.replace("viewBox", 'style="width:20px;height:20px" viewBox')} Invite</button>`}${action}</div>
    </article>`;
  }

  const ACCESS = { members: "Members only", public: "Members and invited guests", open: "Open to everyone (anyone with the link or QR code)" };
  const ACCESS_TAG = { members: "Members only", public: "Open to invited guests", open: "Open to everyone" };
  const fundOpts = (v) => [["events", "Events fund"], ["family", "Family Events fund"]].map(([k, t]) => `<option value="${k}" ${v === k ? "selected" : ""}>${t}</option>`).join("");
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
  const shareEvent = (ev) => share(ev.title, `${ev.title} – ${ev.day ? fmtEvent(ev) : "date to be confirmed"}. Book here:`, eventLink(ev), ev.kind === "football" ? FOOTIE : ev.group_id === "quran" ? QURAN : null);

  // Events with Player and Audience tickets (e.g. the Speed Chess Tournament). Everyone applies and waits
  // for approval. Non-members answer the whole Jotform; members only the tournament questions (member=Yes).
  // The application code saved on this phone for an event, if they applied from here.
  const appliedHere = (ev) => Object.entries(state.applyInfo || {}).find(([c, v]) => v.event === ev.id && state.guestTickets.includes(c))?.[0];
  const TYPE_NAME = { player: "Player", audience: "Non-playing audience" };
  const typePrice = (ev, t) => Number(t === "audience" ? ev.audience_price ?? ev.price : ev.price);
  const applyFormUrl = (t) => {
    const u = new URL(t.apply_form);
    // Members answer only the tournament questions: the app already has their name, age and ticket type.
    if (t.member) { u.searchParams.set("q3_textbox1", t.code); u.searchParams.set("member", "Yes"); return u.toString(); }
    const v = { q3_textbox1: t.code, yourName: t.display_name, q4_radio2: t.ticket_type === "audience" ? "Non-playing audience (£10)" : "Player (£6)" };
    Object.entries(v).forEach(([k, x]) => x && u.searchParams.set(k, x));
    if (t.age) u.searchParams.set("q8_number6", t.age);
    if (t.linked) u.searchParams.set("q14_textbox12", t.linked);
    if (t.adult) u.searchParams.set("q11_textbox9", t.adult);
    return u.toString();
  };
  async function applySheet(ev) {
    if (!me && appliedHere(ev)) return showTicket(appliedHere(ev));
    const counts = Object.fromEntries((await q(sb.rpc("event_type_places", { p_event: ev.id })).catch(() => [])).map((r) => [r.ticket_type, Number(r.taken)]));
    const left = { player: Math.max(0, (ev.player_places || 0) - (counts.player || 0)), audience: Math.max(0, (ev.audience_places || 0) - (counts.audience || 0)) };
    const guest = !me;
    const opt = (t) => `<label class="check"><input type="radio" name="tt" value="${t}" ${left[t] ? "" : "disabled"}> ${TYPE_NAME[t]}, ${money(typePrice(ev, t))} <span class="muted">(${left[t] ? `${left[t]} of ${t === "player" ? ev.player_places : ev.audience_places} left` : "full"})</span></label>`;
    modal(`<button class="close" aria-label="Close">×</button><h2>Apply: ${esc(ev.title)}</h2>
      <p class="muted">${ev.day ? fmtEvent(ev) : "Date to be confirmed"}${ev.location ? ` · ${esc(ev.location)}` : ""}</p>
      <p class="note">Every application is checked by the organiser before a ticket is issued. <b>Step 1</b> is this page, <b>step 2</b> is our application form${guest ? "" : " (a few tournament questions)"}, and once you're approved you pay and get your QR ticket.${guest ? ` Members, <a href="#account" data-close>sign in</a> first.` : ""}</p>
      <label>I'm coming as</label><div class="radios" id="tt">${opt("player")}${opt("audience")}</div>
      <div id="linkRow" hidden><label>Name of the applicant you're coming with</label><input id="lk"><p class="muted" style="font-size:14px">Audience places are only for people coming with an applicant.</p></div>
      <label>Your name or handle</label><input id="gn" autocomplete="name" value="${guest ? "" : esc(me.name || "")}">
      <label>Age</label><input id="ga" type="number" min="1" max="120" inputmode="numeric">
      <div id="adultRow" hidden><p class="note">Under 16s must come with a parent or responsible adult, either as a player or as non-playing audience.</p><label>Their name</label><input id="ad"></div>
      <label class="check" id="consentRow" hidden><input type="checkbox" id="cs"> I have my parents' consent</label>
      <p class="muted" style="font-size:14px;line-height:1.5">${DISCLAIMER} ${PRIVACY}</p>
      <div class="form-actions"><button class="btn solid block" id="ok">Next: the application form</button></div>`, (m) => {
      m.querySelectorAll("[data-close]").forEach((a) => (a.onclick = closeModal));
      const type = () => m.querySelector('[name="tt"]:checked')?.value, age = () => Number($("#ga", m).value) || 0;
      const sync = () => { $("#linkRow", m).hidden = type() !== "audience"; $("#adultRow", m).hidden = !(age() > 0 && age() < 16); $("#consentRow", m).hidden = !(age() >= 16 && age() <= 18); };
      m.querySelectorAll('[name="tt"]').forEach((r) => (r.onchange = sync)); $("#ga", m).oninput = sync;
      $("#ok", m).onclick = async () => {
        const t = type(), name = $("#gn", m).value.trim(), linked = $("#lk", m).value.trim(), adult = $("#ad", m).value.trim();
        if (!t) return toast("Choose Player or Audience");
        if (!name) return toast("Please add your name or handle");
        if (!age()) return toast("Please add your age");
        if (t === "audience" && !linked) return toast("Add the name of the applicant you're coming with");
        if (age() < 16 && !adult) return toast("Add the name of your parent or responsible adult");
        if (age() >= 16 && age() <= 18 && !$("#cs", m).checked) return toast("Applicants aged 16 to 18 need their parents' consent");
        try {
          $("#ok", m).disabled = true;
          const [r] = await q(sb.rpc("apply_event", { p_event: ev.id, p_type: t, p_name: name, p_age: age(), p_email: "", p_linked: linked, p_adult: adult, p_consent: age() >= 16 && age() <= 18 ? true : null }));
          if (guest) {
            state.guestTickets.push(r.code); save();
            const link = await q(sb.rpc("guest_link_booking", { p_code: r.code, p_token: guestToken() })).catch(() => "ok");
            if (link === "blocked") { closeModal(); return toast("Sorry, we can't take an application from you. Please contact the organiser."); }
          }
          state.applyInfo = { ...(state.applyInfo || {}), [r.code]: { event: ev.id, age: age(), linked, adult, member: !guest } }; save();
          closeModal(); await refresh(); showTicket(r.code);
        } catch (e) { $("#ok", m).disabled = false; fail(e); }
      };
    });
  }

  function bookSheet(ev, taken) {
    if (ev.player_places != null) return applySheet(ev);
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
            // Links the booking to this phone, so the admin sees it with the guest's chat messages.
            const link = await q(sb.rpc("guest_link_booking", { p_code: code, p_token: guestToken() })).catch(() => "ok");
            if (link === "blocked") { closeModal(); return toast("Sorry, we can't take a booking from you. Please contact the organiser."); }
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
          <div>${esc(t.display_name)} · ${t.ticket_type ? TYPE_NAME[t.ticket_type] : `${t.places} place${t.places > 1 ? "s" : ""}`}</div>
        </div>
        ${t.apply_form && ["pending", "booked", "waitlist"].includes(t.status) ? (t.applied ? '<p class="muted">✓ Application form received.</p>'
          : `<p class="note">${t.status === "pending" ? "<b>Step 2:</b> fill in our application form. The organiser checks it before approving you." : "Please fill in the tournament questions too."}</p>
            <a class="btn solid block" target="_blank" rel="noopener" href="${esc(applyFormUrl({ ...t, member: !!me, ...(state.applyInfo?.[t.code] || {}) }))}">Fill in the application form</a>`) : ""}
        ${!t.paid && Number(t.amount) > 0 && t.status === "booked" ? `<p class="note">${money(t.amount)} still to pay.</p><button class="btn solid block" data-pay="${esc(t.code)}">Pay ${money(t.amount)} by card</button>` : ""}
        ${t.status === "pending" && t.apply_form ? `<p class="note">Approval usually takes a day. Come back after 24 hours: tap <b>Applied · Check if approved</b> on the event, on this phone. If you're approved, complete your application by paying ${money(t.amount)}, and your QR ticket appears here. If not, spaces may have been limited: after this preliminary speed chess tournament we will be organising a fuller version, or you can apply again to come as a spectator rather than a participant.</p>
            <p class="muted" style="font-size:14px">Keep your code <b>${esc(t.code)}</b> (a screenshot is fine) in case you change phone.</p>`
          : t.status === "pending" ? '<p class="note">Thanks, your request has been received. An organiser will check it, and your QR ticket appears here once it\'s approved. Open Schedule on this phone to check.</p>'
          : t.status === "declined" ? '<p class="note">Sorry, we can\'t offer you a place at this event.</p>'
          : '<p class="muted" style="font-size:14px">Show this at the door. A screenshot works too.</p>'}`, (m) => { if (["booked", "cancelled"].includes(t.status)) qr($("#qr", m), t.code); });
      // If they paid by card but didn't come back through Square's return link, check with Square now.
      if (!t.paid && Number(t.amount) > 0 && !recheck) payApi({ code: t.code, confirm: true }).then((r) => { if (r.paid) { toast("Payment received, thank you!"); showTicket(t.code, true); } }).catch(() => {});
    } catch (e) { fail(e); }
  }

  // ---------- FUNDS ----------
  const FUND_NAME = { kitty: "Kitty", events: "Events", credits: "Credits", family: "Family Events", unclaimed: "Unclaimed credit" };
  const fundStats = (fs) => `<div class="stats"><div><span>Kitty fund</span><b>${money(fs.kitty)}</b></div><div><span>Events fund</span><b>${money(fs.events)}</b></div><div><span>Credits</span><b>${money(fs.credits || 0)}</b></div></div>`;
  const FUND_INFO = `<details class="info"><summary><b>What the funds are</b></summary>
        <p><b>Kitty fund</b> runs the football. £15 kitty contributions and pay-and-play payments go in, and it pays the pitch hire and card fees. The kitty restarts when the fund drops below £150 or after 5 games, and anything over £100 then moves to the events fund.</p>
        <p><b>Events fund</b> is built up from the kitty and from owed money that's been paid. It's used for small come-together events and to buy new footballs and other things that keep the football going.</p>
        <p><b>Credits</b> is money members have paid but not used: they paid but didn't play, or cancelled. It still belongs to them. When they pay for a game from their credit, it moves from credits into the kitty fund. Advance payments are only taken through the app, which records every credit added or used, so the credits fund always matches the total credit on members' accounts.</p>
        <p><b>BR3 Family Events fund</b> is kept in Square for family events. Each weekly subscription payment comes in by itself, with Square's fee taken off.</p>
        <p><b>Unclaimed credit</b> is credit left on accounts that have been closed. It still belongs to them and can be claimed for 12 months, paid back by bank transfer with their consent. After that it goes to a charity on their behalf, and the receipt is kept.</p>
      </details>`;
  const ledgerTable = (rows) => `<div class="scroll"><table><thead><tr><th>Date</th><th>Fund</th><th>Reason</th><th class="amt">Change</th><th class="amt">Balance</th></tr></thead><tbody>${rows.map((l) => `<tr><td>${short(parseDay(l.on_date))}</td><td>${FUND_NAME[l.fund] || ""}</td><td>${esc(l.what)}</td><td class="amt ${Number(l.amount) < 0 ? "neg" : ""}">${money(l.amount)}</td><td class="amt">${money(l.balance)}</td></tr>`).join("")}</tbody></table></div>`;

  // Money moved by hand between the kitty and events funds. Credits belong to members, so they never move this way.
  const MOVE_FUND = { kitty: "Kitty fund", events: "Events fund" };
  const transfersOf = () => q(sb.from("fund_transfers").select("*").order("id", { ascending: false }).limit(100)).catch(() => []); // [] until the SQL is run
  // Net change from transfers not yet shown in any posted accounts, per fund.
  const pendingNet = (ts) => { const n = { kitty: 0, events: 0 }; ts.filter((t) => !t.accounts_post_id).forEach((t) => { n[t.to_fund] += Number(t.amount); n[t.from_fund] -= Number(t.amount); }); return n; };
  const transferLine = (t) => `${short(parseDay(t.on_date))} ${MOVE_FUND[t.from || t.from_fund]} to ${MOVE_FUND[t.to || t.to_fund]} ${money(t.amount)}: ${t.reason}`;
  // Family Events subscriptions week by week (weeks start on Monday), per plan: how many paid, paid, Square's fee and net.
  function familyWeeks(subs) {
    const ok = subs.filter((p) => p.status === "COMPLETED");
    if (!ok.length) return '<p class="muted">No subscription payments in the app yet.</p>';
    const monday = (d) => { const x = new Date(d); x.setHours(0, 0, 0, 0); x.setDate(x.getDate() - ((x.getDay() + 6) % 7)); return x; };
    const plan = (l) => String(l || "Subscription").replace(/\s*\(.*\)\s*$/, "") || "Subscription";
    const groups = new Map();
    ok.forEach((p) => {
      const wk = monday(p.paid_at).getTime(), k = `${wk}|${plan(p.label)}`;
      const g = groups.get(k) || { wk, plan: plan(p.label), n: 0, gross: 0, fee: 0, net: 0 };
      g.n++; g.gross += Number(p.gross); g.fee += Number(p.fee); g.net += Number(p.gross) - Number(p.fee) - Number(p.refunded || 0);
      groups.set(k, g);
    });
    const list = [...groups.values()].sort((a, b) => b.wk - a.wk || a.plan.localeCompare(b.plan));
    const sum = (k) => list.reduce((t, g) => t + g[k], 0);
    return `<h4>Subscriptions by week</h4><div class="scroll"><table class="wrap pay"><thead><tr><th>Week of</th><th>Plan</th><th class="amt">No.</th><th class="amt">Paid £</th><th class="amt">Fee</th><th class="amt">Net</th></tr></thead><tbody>
      ${list.map((g) => `<tr><td>${new Date(g.wk).getDate()} ${MONTHS[new Date(g.wk).getMonth()]}</td><td>${esc(g.plan)}</td><td class="amt">${g.n}</td><td class="amt">${g.gross.toFixed(2)}</td><td class="amt">(${g.fee.toFixed(2)})</td><td class="amt">${g.net.toFixed(2)}</td></tr>`).join("")}
      <tr><td colspan="2"><b>Total</b></td><td class="amt"><b>${sum("n")}</b></td><td class="amt"><b>${sum("gross").toFixed(2)}</b></td><td class="amt"><b>(${sum("fee").toFixed(2)})</b></td><td class="amt"><b>${sum("net").toFixed(2)}</b></td></tr>
    </tbody></table></div>`;
  }
  async function funds(el, alive, which = "") {
    if (!me) return needSignIn(el, "see the funds");
    loading(el);
    let lq = sb.from("ledger").select("*").order("id", { ascending: false }).limit(300);
    if (FUND_NAME[which]) lq = lq.eq("fund", which);
    const unclaimed = isAdmin() ? await q(sb.from("unclaimed_credit").select("id,name,email,amount,removed_at,claim_by,status,settled_at,settled_note").order("id", { ascending: false }).limit(100)).catch(() => []) : [];
    const [fs, rows, accts, subs] = await Promise.all([q(sb.from("fund_state").select("*").single()), isAdmin() ? q(lq) : [], isOrg() ? q(sb.from("profiles").select("credit")) : [],
      isAdmin() ? q(sb.from("square_payments").select("paid_at,status,gross,fee,refunded,label").eq("kind", "subscription").order("paid_at", { ascending: false }).limit(300)).catch(() => []) : []]);
    // The latest Square balance PDF (just its date here; the file loads after the page shows).
    const stmts = (await sb.from("square_statement").select("id,file_name,uploaded_at")).data || [];
    const onAccounts = Math.round(accts.reduce((t, r) => t + Number(r.credit || 0), 0) * 100) / 100;
    if (!alive()) return;
    el.innerHTML = `<div class="events"><div class="card fb"><h2>Funds & accounts</h2>
      <div class="stats four"><div><span>Kitty fund</span><b>${money(fs.kitty)}</b></div><div><span>Events fund</span><b>${money(fs.events)}</b></div><div><span>Credits</span><b>${money(fs.credits || 0)}</b></div><div><span>Family Events</span><b>${money(fs.family || 0)}</b></div></div>
      ${Number(fs.unclaimed) ? `<p class="muted">Unclaimed credit from closed accounts: <b>${money(fs.unclaimed)}</b></p>` : ""}
      <p class="muted">All funds together: <b>${money(Number(fs.kitty) + Number(fs.events) + Number(fs.credits || 0) + Number(fs.family || 0) + Number(fs.unclaimed || 0))}</b></p>
      ${isOrg() ? (onAccounts === Math.round(Number(fs.credits || 0) * 100) / 100 ? `<p class="note">Credits tally ✓ The credits fund matches the ${money(onAccounts)} of credit on members' accounts.</p>`
        : `<p class="note">Credits don't tally: members' accounts hold ${money(onAccounts)} but the credits fund shows ${money(fs.credits || 0)}.</p>`) : ""}
      ${[[1, "Square", fs.square_balance, fs.square_balance_at, "entered"], [2, fs.starling_name ? `Starling ${fs.starling_name}` : "Starling", fs.starling_balance, fs.starling_balance_at, "read by itself"]].map(([id, name, amt, at, how]) => { const st = stmts.find((x) => x.id === id);
        return `<div class="note"><b>${esc(name)}${amt != null ? ` ${money(amt)}` : ""}</b>${at ? ` <span class="muted">${how} ${short(new Date(at))}</span>` : ""}
        ${st ? `<div data-stshow="${id}" style="margin-top:8px"><span class="muted">Loading…</span></div>` : '<div class="muted">No balance photo yet.</div>'}</div>`; }).join("")}
      <p class="muted">Updated every Saturday: Starling is read by itself, and the Square balance and both photos are added on Weekly accounts.</p>
      <p class="muted">Square and Starling together should hold all the funds, less any cash not yet banked. The Accounts Reconciliation chat checks this every Saturday.</p>
      ${FUND_INFO.replace("<details ", "<details open ")}
      <p class="note">Posted accounts, and every move between funds, are on the <a href="#accounts">Accounts tab</a>, one chat for each fund. The Accounts Reconciliation chat checks all the funds together against Square every week.</p>
      <div class="form-actions"><button class="btn solid block" data-go="accounts">Open the Accounts tab</button>${isAdmin() ? '<button class="btn block" data-go="eventaccounts">Events accounts</button>' : ""}${isAdmin() ? '<button class="btn block" data-go="weekly">Weekly accounts</button>' : ""}</div>
      ${isAdmin() ? `<h3>Family Events fund</h3>
        <p class="muted">The Individual, Concessionary and Family subscriptions come in from Square by themselves every Saturday morning, covering the last 7 days (or when you tap Sync from Square on Weekly accounts), with Square's fee taken off. Use this for the opening balance, other money in, and money spent.</p>
        ${familyWeeks(subs)}
        <p class="note">Each week's subscriptions, and any money in or spent recorded here, are posted to the <a href="#chat:family-accounts">BR3 Family Events Accounts chat</a> on the Accounts tab.</p>
        <div class="grid2"><div><label>Money</label><select id="yDir"><option value="1">In</option><option value="-1">Spent</option></select></div>
          <div><label>Amount £</label><input id="yAmt" type="number" step="0.01" min="0.01" inputmode="decimal"></div></div>
        <label>Reason (everyone can see this)</label><input id="yWhy" placeholder="e.g. Opening balance, or Family day hall hire">
        <div class="form-actions"><button class="btn solid block" id="yGo">Record it</button></div>` : ""}
      ${isAdmin() && unclaimed.length ? `<h3>Unclaimed credit</h3>
        <p class="muted">Credit left when you removed someone. They can claim it for 12 months: pay it back by bank transfer with their consent, then tap Paid back. After the claim date, give it to a charity on their behalf and add a photo of the receipt.</p>
        ${unclaimed.map((u) => `<div class="member-row"><div><b>${esc(u.name)} · ${money(u.amount)}</b><div class="muted" style="font-size:14px">${u.email ? `${esc(u.email)} · ` : ""}Removed ${short(new Date(u.removed_at))} · ${u.status === "held" ? `claimable until ${short(parseDay(u.claim_by))} ${u.claim_by.slice(0, 4)}${parseDay(u.claim_by) < today() ? " · <b>claim time is over</b>" : ""}`
          : `${u.status === "paid" ? "Paid back" : "Given to charity"} ${short(new Date(u.settled_at))}${u.settled_note ? ` (${esc(u.settled_note)})` : ""}`}</div></div>
          ${u.status === "held" ? `<div class="row" style="gap:8px;margin-top:8px"><button class="btn small" data-upaid="${u.id}">Paid back</button><button class="btn small" data-ucharity="${u.id}">To charity</button></div>` : u.status === "charity" ? `<button class="btn small" data-ureceipt="${u.id}">Receipt</button>` : ""}</div>`).join("")}` : ""}
      ${isAdmin() ? `<h3>Move money between funds</h3>
        <p class="muted">For example, the kitty's excess over £100 into the events fund, or the events fund paying for a football game. Every move is posted, with its reason, to the Friday Football Accounts and Footballing Events Accounts chats.</p>
        <div class="grid2"><div><label>From</label><select id="tFrom"><option value="kitty">Kitty fund (${money(fs.kitty)})</option><option value="events">Events fund (${money(fs.events)})</option></select></div>
          <div><label>To</label><input id="tTo" value="Events fund" readonly></div></div>
        <label>Amount £</label><input id="tAmt" type="number" step="0.01" min="0.01" inputmode="decimal">
        ${Number(fs.kitty) > 100 ? `<button class="btn small" id="tExcess" style="margin-top:8px">Kitty excess over £100: ${money(Number(fs.kitty) - 100)}</button>` : ""}
        <label>Reason (everyone can see this)</label><input id="tWhy" placeholder="e.g. Kitty excess after 5 games">
        <div class="form-actions"><button class="btn solid block" id="tGo">Move money</button></div>` : ""}
      ${isAdmin() ? `<details class="info" ${which ? "open" : ""}><summary><b>Fund history (admin only)</b></summary>
      <div class="seg small">${[["", "All"], ["kitty", "Kitty"], ["events", "Events"], ["credits", "Credits"], ["family", "Family"], ["unclaimed", "Unclaimed"]].map(([k, v]) => `<button class="${k === (FUND_NAME[which] ? which : "") ? "on" : ""}" data-f="${k}">${v}</button>`).join("")}</div>
      ${rows.length ? ledgerTable(rows) : '<p class="muted">No changes yet.</p>'}</details>` : ""}
    </div></div>`;
    el.querySelectorAll("[data-f]").forEach((b) => (b.onclick = () => go(b.dataset.f ? "funds:" + b.dataset.f : "funds")));
    el.querySelectorAll("[data-stshow]").forEach((box) => showStatement(box, Number(box.dataset.stshow), alive, false));
    el.querySelectorAll("[data-upaid]").forEach((b) => (b.onclick = async () => {
      const u = unclaimed.find((x) => String(x.id) === b.dataset.upaid);
      const note = prompt(`Paid ${money(u.amount)} back to ${u.name}? Add a note, e.g. "bank transfer 3 Nov".`, "bank transfer");
      if (note === null) return;
      try { await q(sb.rpc("settle_unclaimed", { p_id: u.id, p_how: "paid", p_note: note, p_receipt: null })); toast("Recorded as paid back"); refresh(); } catch (e) { fail(e); }
    }));
    el.querySelectorAll("[data-ucharity]").forEach((b) => (b.onclick = () => {
      const u = unclaimed.find((x) => String(x.id) === b.dataset.ucharity);
      modal(`<button class="close" aria-label="Close">×</button><h2>Give ${esc(u.name)}'s ${money(u.amount)} to charity</h2>
        ${parseDay(u.claim_by) >= today() ? `<p class="note">Their claim time runs until ${short(parseDay(u.claim_by))} ${u.claim_by.slice(0, 4)}. Only do this early if they've asked you to.</p>` : ""}
        <label>Which charity</label><input id="uWho" placeholder="e.g. Islamic Relief">
        <label>Photo or PDF of the receipt</label><input id="uFile" type="file" accept="image/*,application/pdf,.pdf">
        <div class="form-actions"><button class="btn solid block" id="uGo">Record it</button></div>`, (m) => {
        $("#uGo", m).onclick = async () => {
          const f = $("#uFile", m).files[0], who = $("#uWho", m).value.trim();
          if (!who) return toast("Say which charity");
          if (!f) return toast("Add the receipt");
          const isPdf = /pdf$/i.test(f.type) || /\.pdf$/i.test(f.name);
          if (isPdf && f.size > 5e6) return toast("That PDF is over 5 MB. Try a smaller one");
          const data = await new Promise((r) => { const rd = new FileReader(); rd.onload = () => r(rd.result); rd.readAsDataURL(f); });
          const file = isPdf ? String(data).replace(/^data:[^;,]*(;base64)?,/, "data:application/pdf;base64,") : await shrink(data, 1600);
          try { $("#uGo", m).disabled = true; await q(sb.rpc("settle_unclaimed", { p_id: u.id, p_how: "charity", p_note: who, p_receipt: file })); closeModal(); toast("Recorded, with the receipt"); refresh(); }
          catch (e) { $("#uGo", m).disabled = false; fail(e); }
        };
      });
    }));
    el.querySelectorAll("[data-ureceipt]").forEach((b) => (b.onclick = async () => {
      try {
        const row = await q(sb.from("unclaimed_credit").select("receipt").eq("id", b.dataset.ureceipt).single());
        if (!row.receipt) return toast("No receipt saved");
        if (/^data:image\//.test(row.receipt)) modal(`<button class="close" aria-label="Close">×</button><img src="${esc(row.receipt)}" alt="Receipt" style="width:100%;border-radius:8px;margin-top:30px">`);
        else window.open(URL.createObjectURL(await (await fetch(row.receipt)).blob()), "_blank");
      } catch (e) { fail(e); }
    }));
    if ($("#yGo", el)) $("#yGo", el).onclick = async () => {
      const amt = Math.round(Number($("#yAmt", el).value) * 100) / 100, why = $("#yWhy", el).value.trim(), sign = Number($("#yDir", el).value);
      if (!(amt > 0)) return toast("Enter an amount");
      if (!why) return toast("Give a reason");
      if (!confirm(`${sign > 0 ? "Add" : "Take"} ${money(amt)} ${sign > 0 ? "to" : "from"} the Family Events fund?\n\nReason: ${why}`)) return;
      try { $("#yGo", el).disabled = true; await q(sb.rpc("family_entry", { p_amount: sign * amt, p_reason: why })); toast("Recorded"); refresh(); }
      catch (e) { $("#yGo", el).disabled = false; fail(e); }
    };
    const from = $("#tFrom", el);
    if (!from) return;
    const other = () => (from.value === "kitty" ? "events" : "kitty");
    from.onchange = () => ($("#tTo", el).value = MOVE_FUND[other()]);
    if ($("#tExcess", el)) $("#tExcess", el).onclick = () => {
      from.value = "kitty"; from.onchange();
      $("#tAmt", el).value = (Number(fs.kitty) - 100).toFixed(2);
      if (!$("#tWhy", el).value) $("#tWhy", el).value = `Kitty ${fs.session_no} excess over £100`;
    };
    $("#tGo", el).onclick = async () => {
      const amt = Math.round(Number($("#tAmt", el).value) * 100) / 100, why = $("#tWhy", el).value.trim();
      if (!(amt > 0)) return toast("Enter an amount");
      if (!why) return toast("Give a reason for the transfer");
      if (!confirm(`Move ${money(amt)} from the ${MOVE_FUND[from.value].toLowerCase()} to the ${MOVE_FUND[other()].toLowerCase()}?\n\nReason: ${why}`)) return;
      try {
        $("#tGo", el).disabled = true;
        await q(sb.rpc("transfer_funds", { p_from: from.value, p_to: other(), p_amount: amt, p_reason: why }));
        toast(`${money(amt)} moved to the ${MOVE_FUND[other()].toLowerCase()}`); refresh();
      } catch (e) { $("#tGo", el).disabled = false; fail(e); }
    };
  }

  // ---------- SQUARE CHECK ----------
  // Square holds all the funds (cash and transfers are paid in through Starling). This screen checks
  // the Square balance against the funds, and lists each Square payment with its fee and net.
  const PLACE = { cash: "Cash in hand", bank: "Bank (Starling)", square: "Square", count: "Counted" };
  const isoDay = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  // Weekly accounts: one page for the Saturday routine. 1 balances and photos, 2 the week's accounts to post,
  // 3 the reconciliation, then Square payments, matching and money moved underneath.
  let starlingAutoAt = 0; // reads Starling by itself when the page opens, at most every 10 minutes
  async function weekly(el, alive, arg = "") {
    if (!me) return needSignIn(el, "see the weekly accounts");
    if (!isDoor()) { el.innerHTML = '<div class="empty"><h2>For organisers</h2><p class="muted">Weekly accounts are for organisers and the admin.</p></div>'; return; }
    loading(el);
    const [a, b] = String(arg).split("~");
    const to = /^\d{4}-\d{2}-\d{2}$/.test(b || "") ? b : isoDay(new Date());
    const from = /^\d{4}-\d{2}-\d{2}$/.test(a || "") ? a : (() => { const d = parseDay(to); d.setDate(d.getDate() - 7); return isoDay(d); })();
    const start = parseDay(from).toISOString(), endD = parseDay(to); endD.setDate(endD.getDate() + 1);
    const end = endD.toISOString();
    let x, pays, cards, moves, unpaid, stx;
    try {
      [x, pays, cards, moves, unpaid, stx] = await Promise.all([
        q(sb.rpc("square_expected")),
        q(sb.from("square_payments").select("*").gte("paid_at", start).lt("paid_at", end).order("paid_at", { ascending: false })),
        q(sb.from("bookings").select("id,display_name,amount,credit_used,card_fee,created_at,square_order_id,events(title,day)").eq("method", "card").eq("paid", true).gte("created_at", start).lt("created_at", end)),
        q(sb.from("money_moves").select("*").order("id", { ascending: false }).limit(20)),
        isAdmin() ? q(sb.from("bookings").select("id,display_name,amount,created_at,events(title,day)").eq("paid", false).eq("status", "booked").gte("created_at", new Date(parseDay(from).getTime() - 7 * 864e5).toISOString()).lt("created_at", end).order("created_at", { ascending: false })) : [],
        isAdmin() ? q(sb.from("starling_txns").select("*").gte("at", start).lt("at", end).order("at", { ascending: false })).catch(() => []) : [],
      ]);
    } catch (e) {
      el.innerHTML = `<div class="empty"><h2>Weekly accounts aren't ready</h2><p class="muted">Run supabase/add-square-check.sql in Supabase first. (${esc(e.message)})</p></div>`;
      return;
    }
    // This week = since the last reconciliation was posted. Each step is done once it's been redone since then.
    let last = null, stmts = [], games = [], evs = [], weekSince = new Date(0);
    if (isAdmin()) {
      last = await q(sb.from("reconciliations").select("posted_at").order("id", { ascending: false }).limit(1)).then((r) => r[0] || null).catch(() => null);
      const since = last ? new Date(last.posted_at) : new Date(0), back = new Date(Math.max(since.getTime(), Date.now() - 60 * 864e5));
      let evRows, posted, lines;
      [stmts, games, evRows, posted, lines] = await Promise.all([
        q(sb.from("square_statement").select("id,uploaded_at")).catch(() => []),
        q(sb.from("events").select("id,title,day,time,accounts_posted").eq("kind", "football").eq("accounts_posted", false).not("day", "is", null).order("day")).catch(() => []),
        q(sb.from("events").select("id,title,day,time,price").neq("kind", "football").not("day", "is", null).gte("day", isoDay(new Date(back.getTime() - 14 * 864e5))).order("day")).catch(() => []),
        q(sb.from("event_accounts").select("event_id")).catch(() => []),
        q(sb.from("event_account_lines").select("event_id")).catch(() => []),
      ]);
      const done = new Set(posted.map((r) => r.event_id)), withLines = new Set(lines.map((r) => r.event_id));
      games = games.filter((g) => eventEnd(g) <= new Date());
      // Events that took money (a price or receipts entered) and have ended, without posted accounts.
      evs = evRows.filter((e) => !done.has(e.id) && eventEnd(e) <= new Date() && (Number(e.price) > 0 || withLines.has(e.id)));
      weekSince = since;
    }
    if (!alive()) return;
    const ok = pays.filter((p) => p.status === "COMPLETED");
    const sum = (k) => ok.reduce((t, p) => t + Number(p[k] || 0), 0);
    const tGross = sum("gross"), tFee = sum("fee"), tRef = sum("refunded");
    const matched = new Set(pays.map((p) => p.booking_id).filter(Boolean));
    const missing = cards.filter((c) => !matched.has(c.id));
    const other = ok.filter((p) => p.kind === "other");
    // Bookings a not-matched payment could belong to: card bookings with no Square payment, and unpaid bookings.
    const cands = [...missing, ...unpaid];
    const candLabel = (c) => `${esc(c.display_name)} · ${esc(c.events?.title || "")}${c.events?.day ? ` ${short(parseDay(c.events.day))}` : ""}${c.paid === false || !("square_order_id" in c) ? " (unpaid)" : ""}`;
    const bal = x.square_balance == null ? null : Number(x.square_balance);
    const diff = bal == null ? null : Math.round((bal - Number(x.expected)) * 100) / 100;
    const KIND = { booking: "Booking", subscription: "Family Events", other: "Not matched" };
    const row = (label, v, sign = "") => `<tr><td>${label}</td><td class="amt ${sign === "−" ? "neg" : ""}">${sign}${money(Math.abs(Number(v)))}</td></tr>`;
    const after = (t) => !!t && new Date(t) > weekSince;
    const stOf = (id) => stmts.find((x) => x.id === id);
    const step1 = isAdmin() && after(x.square_balance_at) && after(stOf(1)?.uploaded_at) && after(stOf(2)?.uploaded_at);
    const step2 = isAdmin() && !games.length && !evs.length;
    const tick = (b) => (b ? ' <span class="tag">✓ Done</span>' : "");
    const photoRow = (id, name) => { const st = stOf(id);
      return `<div class="note"><b>${name} balance photo</b> ${after(st?.uploaded_at) ? `<span class="tag">✓ ${short(new Date(st.uploaded_at))}</span>` : st ? `<span class="muted">last one ${short(new Date(st.uploaded_at))}</span>` : ""}
        <label>${after(st?.uploaded_at) ? "Replace it" : "Add this week's"} (a screenshot or PDF)</label><input data-stfile="${id}" type="file" accept="image/*,application/pdf,.pdf"></div>`; };
    const checkTable = `<div class="scroll"><table class="wrap"><tbody>
        ${row(`All funds (kitty, events, credits, Family Events${Number(x.unclaimed) ? ", unclaimed credit" : ""})`, x.funds)}
        ${row("Paid for games and events whose accounts aren't posted yet", x.pending_in, "+")}
        ${row("Square fees on those", x.pending_fees, "−")}
        ${row("Cash in hand", x.held_cash, Number(x.held_cash) < 0 ? "+" : "−")}
        ${row(x.starling_at ? `In Starling${x.starling_name ? `, ${esc(x.starling_name)}` : ""} (read ${short(new Date(x.starling_at))})` : "In the bank (Starling)", x.held_bank, Number(x.held_bank) < 0 ? "+" : "−")}
        <tr><td><b>Square should hold</b></td><td class="amt"><b>${money(x.expected)}</b></td></tr>
        <tr><td>Square balance${x.square_balance_at ? ` (entered ${short(new Date(x.square_balance_at))})` : ""}</td><td class="amt">${bal == null ? "—" : money(bal)}</td></tr>
      </tbody></table></div>
      ${diff == null ? "" : diff === 0 ? '<p class="note check-diff">✓ Square matches the funds.</p>' : `<p class="note check-diff">Square has ${money(Math.abs(diff))} ${diff > 0 ? "more" : "less"} than the funds.</p>
        <p class="muted">Common reasons: cash not yet banked, pitch hire paid before the game's accounts are posted, a payment below marked "Not matched", a refund, or money moved but not recorded.</p>`}
      ${x.pending.length ? `<details class="info"><summary>Games and events not yet in accounts</summary>${x.pending.map((p) => `<p>${esc(p.title)}${p.day ? ` ${short(parseDay(p.day))}` : ""}: ${money(p.paid || 0)} paid, ${money(p.fees || 0)} Square fees</p>`).join("")}</details>` : ""}`;
    el.innerHTML = `<div class="events"><div class="card fb"><h2>Weekly accounts</h2>
      ${isAdmin() ? `<p class="muted">Every Saturday, three steps in order. Each gets a ✓ when it's done for this week.${last ? ` Last reconciliation posted ${short(new Date(last.posted_at))}.` : ""}</p>
      <h3>1. Balances${tick(step1)}</h3>
      <p class="note"><b>${x.starling_name ? `Starling ${esc(x.starling_name)}` : "Starling"} ${x.starling_at ? money(x.starling) : "—"}</b> <span class="muted">${x.starling_at ? `read by itself ${short(new Date(x.starling_at))} ${new Date(x.starling_at).toTimeString().slice(0, 5)}` : "not read yet"}</span>
        <button class="btn small" id="stPull" style="margin-left:6px">Read again</button></p>
      <label>Square balance now, from the Square app £ ${after(x.square_balance_at) ? '<span class="tag">✓ saved</span>' : ""}</label>
      <div class="row" style="gap:8px"><input id="sqBal" type="number" step="0.01" inputmode="decimal" value="${bal == null ? "" : bal.toFixed(2)}" style="flex:1"><button class="btn solid" id="sqBalGo">Save</button></div>
      ${photoRow(1, "Square")}${photoRow(2, "Starling")}
      <h3>2. Accounts to post${tick(step2)}</h3>
      ${games.length || evs.length ? `${games.map((g) => `<div class="member-row"><div><b>${esc(g.title)}</b><div class="muted" style="font-size:14px">${short(parseDay(g.day))} · football accounts</div></div><button class="btn solid small" data-go="footballadmin">Open</button></div>`).join("")}
        ${evs.map((e) => `<div class="member-row"><div><b>${esc(e.title)}</b><div class="muted" style="font-size:14px">${short(parseDay(e.day))} · events accounts</div></div><button class="btn solid small" data-go="eventaccounts:${e.id}">Open</button></div>`).join("")}
        <p class="muted">Post each one. It drops off this list once it's posted.</p>` : '<p class="muted">Nothing waiting: this week\'s games and events are posted.</p>'}
      <h3>3. Reconciliation</h3>
      ${checkTable}
      ${step1 && step2 ? "" : `<p class="note">Finish ${!step1 && !step2 ? "steps 1 and 2" : !step1 ? "step 1" : "step 2"} first, so the reconciliation uses this week's figures.</p>`}
      <div class="form-actions"><button class="btn ${step1 && step2 ? "solid " : ""}block" id="rcDraft">Draft the reconciliation</button></div>
      <div id="rcBox" hidden><label>Reconciliation (edit freely)</label><textarea id="rcText" rows="20" class="mono"></textarea>
        <div id="rcDiff" hidden><label>Why there is a difference</label><textarea id="rcWhy" rows="3" placeholder="e.g. £6 cash from Friday not banked yet"></textarea>
          <label>How and when it will be corrected</label><textarea id="rcFix" rows="3" placeholder="e.g. Paid into Starling on Monday"></textarea></div>
        <p class="muted">Posted, pinned, to the Accounts Reconciliation chat, with both balance photos.</p>
        <div class="form-actions"><button class="btn solid block" id="rcPost">Post to the Accounts Reconciliation chat</button></div></div>
      <details class="info" style="margin-top:18px"><summary><b>Square payments, matching and money moved</b></summary>` : `<h3>Does Square match the funds?</h3>${checkTable}`}
      ${isAdmin() ? `<h3>Money moved</h3>
        <p class="muted">Record cash paid into Square, or money moved from Starling to Square, so the check stays right.</p>
        <div class="grid2"><div><label>From</label><select id="mFrom"><option value="cash">Cash in hand (${money(x.held_cash)})</option><option value="bank">Bank (Starling) (${money(x.held_bank)})</option><option value="square">Square</option><option value="count">Correct to a counted figure</option></select></div>
          <div><label>To</label><select id="mTo"><option value="square">Square</option><option value="bank">Bank (Starling)</option><option value="cash">Cash in hand</option></select></div></div>
        <label id="mAmtL">Amount £</label><input id="mAmt" type="number" step="0.01" min="0" inputmode="decimal">
        <label>Note</label><input id="mWhy" placeholder="e.g. Starling to Square after Friday's game">
        <div class="form-actions"><button class="btn solid block" id="mGo">Record it</button></div>` : ""}
      ${moves.length ? `<div class="scroll"><table class="wrap"><thead><tr><th>Date</th><th>Move</th><th class="amt">£</th></tr></thead><tbody>${moves.map((m) => `<tr><td>${short(parseDay(m.on_date))}</td><td>${m.from_place === "count" ? `${PLACE[m.to_place]} set to counted figure` : `${PLACE[m.from_place]} → ${PLACE[m.to_place]}`}${m.reason ? `: ${esc(m.reason)}` : ""}</td><td class="amt">${money(m.amount)}</td></tr>`).join("")}</tbody></table></div>` : ""}

      <h3>Square payments</h3>
      <div class="grid2"><div><label>From</label><input id="sqFrom" type="date" value="${from}"></div><div><label>To</label><input id="sqTo" type="date" value="${to}"></div></div>
      <div class="form-actions"><button class="btn block" id="sqShow">Show these dates</button><button class="btn solid block" id="sqSync">Sync from Square</button></div>
      <div class="stats"><div><span>Paid</span><b>${money(tGross)}</b></div><div><span>Square fees</span><b>${money(tFee)}</b></div><div><span>Net</span><b>${money(tGross - tFee - tRef)}</b></div></div>
      ${tRef ? `<p class="muted">Refunded: ${money(tRef)} (taken off the net).</p>` : ""}
      ${pays.length ? `<div class="scroll"><table class="wrap"><thead><tr><th>For</th><th class="amt">Paid</th><th class="amt">Fee</th><th class="amt">Net</th></tr></thead><tbody>${pays.map((p) => {
        const live = p.status === "COMPLETED";
        return `<tr><td>${esc(p.label || p.note || "Square payment")}<div class="muted" style="font-size:13px">${short(new Date(p.paid_at))} · ${live ? KIND[p.kind] : esc(p.status.toLowerCase())}</div></td><td class="amt">${money(p.gross)}</td><td class="amt">${money(p.fee)}</td><td class="amt">${money(live ? p.gross - p.fee - p.refunded : 0)}</td></tr>`;
      }).join("")}<tr><td><b>Total</b></td><td class="amt"><b>${money(tGross)}</b></td><td class="amt"><b>${money(tFee)}</b></td><td class="amt"><b>${money(tGross - tFee - tRef)}</b></td></tr></tbody></table></div>`
        : '<p class="muted">No Square payments in the app for these dates yet. Tap Sync from Square to fetch them.</p>'}
      ${other.length ? `<p class="note">${other.length} payment${other.length > 1 ? "s" : ""} (${money(other.reduce((t, p) => t + Number(p.gross), 0))}) in Square ${other.length > 1 ? "aren't" : "isn't"} matched to a booking or the subscription.</p>
        <p class="muted">This happens when someone pays outside the app, for example on the Square app or card reader at the pitch, so Square has nothing to link it to a booking. Payments made with the app's QR match by themselves.</p>
        ${isAdmin() ? `<h3>Match by hand</h3>${other.map((p) => `<div class="grid2"><div><label>${money(p.gross)} on ${short(new Date(p.paid_at))}${p.note ? ` · ${esc(p.note)}` : ""}</label><select data-mpay="${esc(p.id)}"><option value="">Choose the booking</option>${cands.map((c) => `<option value="${c.id}">${candLabel(c)}</option>`).join("")}</select></div><div style="align-self:end"><button class="btn solid block" data-mgo="${esc(p.id)}">Match</button></div></div>`).join("")}
        <p class="muted">Matching marks the booking as paid by card, with Square's fee. A later Sync keeps the match.</p>` : ""}` : ""}
      ${missing.length ? `<p class="note">${missing.length} card booking${missing.length > 1 ? "s" : ""} in the app ${missing.length > 1 ? "have" : "has"} no Square payment here: ${missing.map((c) => esc(c.display_name)).join(", ")}. Tap Sync from Square, and if ${missing.length > 1 ? "they stay" : "it stays"}, check Square.</p>` : ""}
      ${isAdmin() ? "</details>" : ""}
    </div></div>`;
    el.querySelectorAll("[data-mgo]").forEach((btn) => (btn.onclick = async () => {
      const sel = el.querySelector(`[data-mpay="${CSS.escape(btn.dataset.mgo)}"]`);
      if (!sel.value) return toast("Choose the booking");
      if (!confirm(`Match this payment to ${sel.selectedOptions[0].textContent}?`)) return;
      try { btn.disabled = true; await q(sb.rpc("link_square_payment", { p_payment: btn.dataset.mgo, p_booking: sel.value })); toast("Matched ✓"); refresh(); }
      catch (e) { btn.disabled = false; fail(e); }
    }));
    if ($("#stPull", el)) $("#stPull", el).onclick = async (e) => {
      const btn = e.currentTarget; btn.disabled = true; btn.textContent = "Reading Starling…";
      try {
        const { data: { session } } = await sb.auth.getSession();
        const res = await fetch("/.netlify/functions/starling-sync", { method: "POST", headers: { Authorization: `Bearer ${session?.access_token || ""}` } });
        const r = await res.json().catch(() => ({}));
        if (!res.ok) throw new Error(r.error || "Couldn't reach Starling.");
        toast(`Starling ${r.name}: ${money(r.balance)}, ${r.transactions} transaction${r.transactions === 1 ? "" : "s"} read`);
        refresh();
      } catch (err) { btn.disabled = false; btn.textContent = "Read again"; fail(err); }
    };
    $("#sqShow", el).onclick = () => go(`weekly:${$("#sqFrom", el).value}~${$("#sqTo", el).value}`);
    $("#sqSync", el).onclick = async (e) => {
      const btn = e.currentTarget; btn.disabled = true; btn.textContent = "Checking Square…";
      try {
        const { data: { session } } = await sb.auth.getSession();
        const res = await fetch("/.netlify/functions/square-sync", { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${session?.access_token || ""}` }, body: JSON.stringify({ from: $("#sqFrom", el).value, to: $("#sqTo", el).value }) });
        const r = await res.json().catch(() => ({}));
        if (!res.ok) throw new Error(r.error || "Couldn't reach Square.");
        toast(`${r.checked} Square payment${r.checked === 1 ? "" : "s"} checked, ${r.updated} updated${r.family ? `, ${r.family} to Family Events` : ""}`);
        go(`weekly:${$("#sqFrom", el).value}~${$("#sqTo", el).value}`);
      } catch (err) { btn.disabled = false; btn.textContent = "Sync from Square"; fail(err); }
    };
    if ($("#rcDraft", el)) $("#rcDraft", el).onclick = async () => {
      const v = $("#sqBal", el).value;
      if (v === "") return toast("Enter the Square balance from the Square app first");
      let fs, prev;
      try {
        [fs, prev] = await Promise.all([q(sb.from("fund_state").select("*").single()), q(sb.from("reconciliations").select("*").order("id", { ascending: false }).limit(1)).then((r) => r[0] || null)]);
      } catch (e) { return toast("Run add-accounts-tab.sql in Supabase first"); }
      const r2 = (n) => Math.round(Number(n || 0) * 100) / 100, br = (n) => (r2(n) < 0 ? `(${money(-n)})` : money(n)), sg = (n) => (r2(n) < 0 ? `(${money(-n)})` : `+${money(n)}`);
      const S = r2(v), E = r2(x.expected), D = r2(S - E);
      const held = r2(Number(x.held_cash) + Number(x.held_bank)), adv = r2(Number(x.pending_in) - Number(x.pending_fees));
      const FUNDS = [["kitty", "Friday Football"], ["events", "Footballing Events"], ["family", "BR3 Family Events"], ["credits", "Credits Held"], ["unclaimed", "Unclaimed credit"]]
        .filter(([k]) => k !== "unclaimed" || Number(fs.unclaimed || 0) || Number(prev?.unclaimed || 0));
      const now = new Date(), L = "________";
      const t = [`Accounts Reconciliation · ${DAYS[now.getDay()]} ${now.getDate()} ${MONTHS_LONG[now.getMonth()]} ${now.getFullYear()}`, "All our funds together, checked against the Square account", L];
      // Total to total first: what Square holds against what all the funds say it should hold.
      const B = x.starling_at ? r2(x.starling) : null;
      if (B != null) t.push(`Square bank balance as of Saturday morning ${money(S)}`, `Starling${x.starling_name ? ` (${x.starling_name})` : ""} balance ${money(B)}`, `Square and Starling together ${money(S + B)}`, "", "Expected holding");
      else t.push(`Square bank balance as of Saturday morning ${money(S)}`, "", "Expected Square holding");
      t.push(
        ...[["kitty", "Friday Football (kitty) fund"], ["credits", "Credits held"], ["events", "Footballing Events fund"], ["family", "BR3 Family Events fund (with the weekly subscriptions)"], ["unclaimed", "Unclaimed credit"]]
          .filter(([k]) => k !== "unclaimed" || r2(fs.unclaimed)).map(([k, n]) => `${n} ${money(fs[k] || 0)}`),
        `All funds together ${money(x.funds)}`);
      const cashOnly = r2(x.held_cash), notIn = B != null ? cashOnly : held;
      if (notIn) t.push(`Less ${B != null ? "cash not yet banked" : "cash and transfers not yet in Square"} (${money(notIn)})`);
      if (adv) t.push(`Plus paid in advance for the next game ${money(adv)}`);
      t.push(B != null ? `Expected holding ${money(E + B)}` : `Expected Square holding ${money(E)}`, D === 0 ? "Difference £0.00 ✓ Balanced" : `Difference ${br(D)} (Square has ${money(Math.abs(D))} ${D > 0 ? "more" : "less"})`, L);
      if (prev) {
        t.push("How it changed since last week");
        const prevDiff = r2(Number(prev.square_actual) - Number(prev.square_expected));
        t.push(`Prior Square balance (last week, according to Square) ${money(prev.square_actual)}`);
        if (prevDiff) t.push(`Less last week's difference ${br(-prevDiff)}`);
        t.push(L, "Fund value changes this week");
        let T = 0;
        FUNDS.forEach(([k, n]) => { const b = r2(prev[k]), a = r2(fs[k]); T += a - b; t.push(`${n} ${money(b)} → ${money(a)} ${sg(a - b)}`); });
        t.push(`Total change ${sg(T)}`);
        if (r2(held) || r2(prev.held)) t.push(`${B != null ? "Cash in hand and Starling" : "Cash and transfers not yet in Square"} ${money(prev.held)} → ${money(held)} ${sg(-(held - Number(prev.held)))}`);
        if (r2(adv) || r2(prev.advance)) t.push(`Paid in advance for the next game ${money(prev.advance)} → ${money(adv)} ${sg(adv - Number(prev.advance))}`);
        t.push(L, `Square balance expected ${money(E)}`, `Square bank balance according to Square ${money(S)}`, D === 0 ? "Difference £0.00 ✓ Balanced" : `Difference ${br(D)}`);
      } else {
        t.push("First reconciliation, so there's no change from last week to show yet.");
      }
      $("#rcText", el).value = t.join("\n");
      $("#rcDiff", el).hidden = D === 0;
      $("#rcBox", el).hidden = false; $("#rcText", el).focus();
      $("#rcPost", el).onclick = async () => {
        const why = $("#rcWhy", el).value.trim(), fix = $("#rcFix", el).value.trim();
        if (D !== 0 && (!why || !fix)) return toast("Say why there's a difference, and how and when it will be corrected");
        const body = $("#rcText", el).value.trim() + (D !== 0 ? `\n${L}\nWhy there is a difference\n${why}\n\nHow and when it will be corrected\n${fix}` : "");
        if (!confirm("Post the reconciliation to the Accounts Reconciliation chat? It's pinned there for every member.")) return;
        try { $("#rcPost", el).disabled = true; await q(sb.rpc("post_reconciliation", { p_body: body, p_square: S, p_why: why, p_fix: fix })); toast("Posted to the Accounts Reconciliation chat"); go("chat:accounts-reconciliation"); }
        catch (e) { $("#rcPost", el).disabled = false; fail(e); }
      };
    };
    if ($("#sqBalGo", el)) $("#sqBalGo", el).onclick = async () => {
      const v = $("#sqBal", el).value;
      if (v === "") return toast("Enter the Square balance");
      try { await q(sb.rpc("set_square_balance", { p_amount: Number(v) })); toast("Square balance saved"); refresh(); } catch (e) { fail(e); }
    };
    // The Square and Starling balance photos: shown on the Funds page and attached to the reconciliation post.
    el.querySelectorAll("[data-stfile]").forEach((inp) => (inp.onchange = () => {
      const f = inp.files[0]; if (!f) return;
      const isPdf = /pdf$/i.test(f.type) || /\.pdf$/i.test(f.name);
      if (!isPdf && !/^image\//.test(f.type)) return toast("Choose a photo, screenshot or PDF");
      if (isPdf && f.size > 5e6) return toast("That PDF is over 5 MB. Try a smaller one");
      const rd = new FileReader();
      rd.onload = async () => {
        const file = isPdf ? String(rd.result).replace(/^data:[^;,]*(;base64)?,/, "data:application/pdf;base64,") : await shrink(rd.result, 2000);
        try { await q(sb.from("square_statement").upsert({ id: Number(inp.dataset.stfile), file, file_name: f.name, uploaded_at: new Date().toISOString(), uploaded_by: me.id }));
          toast("Balance photo added"); refresh(); } catch (e) { fail(e); }
      };
      rd.readAsDataURL(f);
    }));
    // Starling is read by itself when the page opens (unless it was read in the last 10 minutes).
    if (isAdmin() && $("#stPull", el) && Date.now() - starlingAutoAt > 6e5 && (!x.starling_at || Date.now() - new Date(x.starling_at) > 6e5)) {
      starlingAutoAt = Date.now();
      (async () => {
        try {
          const { data: { session } } = await sb.auth.getSession();
          const res = await fetch("/.netlify/functions/starling-sync", { method: "POST", headers: { Authorization: `Bearer ${session?.access_token || ""}` } });
          if (res.ok && alive()) refresh();
        } catch {}
      })();
    }
    const mFrom = $("#mFrom", el);
    if (!mFrom) return;
    mFrom.onchange = () => {
      const count = mFrom.value === "count";
      $("#mAmtL", el).textContent = count ? "Counted amount £" : "Amount £";
      $("#mTo", el).innerHTML = (count ? ["cash", "bank"] : ["square", "bank", "cash"]).filter((k) => k !== mFrom.value).map((k) => `<option value="${k}">${PLACE[k]}</option>`).join("");
    };
    mFrom.onchange();
    $("#mGo", el).onclick = async () => {
      const amt = Math.round(Number($("#mAmt", el).value) * 100) / 100, f = mFrom.value, t = $("#mTo", el).value;
      if ($("#mAmt", el).value === "" || (f !== "count" && !(amt > 0))) return toast("Enter an amount");
      const what = f === "count" ? `Set ${PLACE[t].toLowerCase()} to ${money(amt)}?` : `Record ${money(amt)} moved from ${PLACE[f].toLowerCase()} to ${PLACE[t].toLowerCase()}?`;
      if (!confirm(what)) return;
      try { $("#mGo", el).disabled = true; await q(sb.rpc("move_money", { p_from: f, p_to: t, p_amount: amt, p_reason: $("#mWhy", el).value.trim() })); toast("Recorded"); refresh(); }
      catch (e) { $("#mGo", el).disabled = false; fail(e); }
    };
  }

  // ---------- EVENTS ACCOUNTS ----------
  // A tab per event: receipts (money in) offset against hiring and ancillary costs, with receipt photos.
  // Posting puts the profit into (or takes the loss out of) the events fund and copies the accounts to the Accounts chat.
  const LINE_KIND = { receipt: "Receipts", hiring: "A. Hiring costs", ancillary: "B. Ancillary costs" };
  const KIND_ORDER = ["receipt", "hiring", "ancillary"];
  const noPhotos = (t) => String(t || "").replace(/[ \t]*\n?[ \t]*\{photo \d+\}/g, "");
  // The order post_event_accounts puts the photos in, so {photo N} points at the right one.
  const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
  const photoOrder = (ls) => ls.filter((l) => l.photo).sort((a, b) => KIND_ORDER.indexOf(a.kind) - KIND_ORDER.indexOf(b.kind) || cmp(a.created_at, b.created_at) || cmp(a.id, b.id));
  const evDate = (e) => (e.day ? `${parseDay(e.day).getDate()} ${MONTHS_LONG[parseDay(e.day).getMonth()]} ${parseDay(e.day).getFullYear()}` : "date to be confirmed");

  async function eventaccounts(el, alive, id) {
    if (!me) return needSignIn(el, "see the events accounts");
    loading(el);
    const [evs, all, done, fs, transfers] = await Promise.all([
      q(sb.from("events").select("id,title,day,time,accounts_posted,fund").neq("kind", "football").order("day", { ascending: false, nullsFirst: false })),
      q(sb.from("event_account_lines").select("id,event_id,kind,what,amount,created_at").order("created_at")).catch(() => null),
      q(sb.from("event_accounts").select("*")).catch(() => []),
      q(sb.from("fund_state").select("*").single()),
      transfersOf(),
    ]);
    if (!alive()) return;
    if (!all) {
      el.innerHTML = `<div class="empty"><h2>Events accounts aren't set up yet</h2><p class="muted" style="line-height:1.5">${isAdmin() ? "Run add-fund-transfers-and-event-accounts.sql in the Supabase SQL Editor, then come back here." : "Check back soon."}</p></div>`;
      return;
    }
    const postedOf = (e) => done.find((a) => a.event_id === e.id);
    // Only events still waiting for accounts, for the admin. Posted accounts live in the Accounts chat only.
    const list = isAdmin() ? evs.filter((e) => !postedOf(e)) : [];
    if (!list.length) {
      el.innerHTML = `<div class="events"><div class="card fb"><h2>Events accounts</h2><p class="muted">${isAdmin() ? "No events are waiting for accounts. " : ""}Posted accounts are on the <a href="#accounts">Accounts tab</a>.</p></div></div>`;
      return;
    }
    const pick = list.find((e) => e.id === id) || list.find((e) => !e.accounts_posted && all.some((l) => l.event_id === e.id))
      || list.find((e) => e.day && e.day <= dayKey(today())) || list[0];
    const posted = postedOf(pick);
    const [lines, bks] = await Promise.all([
      q(sb.from("event_account_lines").select("*").eq("event_id", pick.id).order("created_at")),
      isAdmin() && !posted ? q(sb.from("bookings").select("amount,paid,status,card_fee").eq("event_id", pick.id).neq("status", "cancelled")) : [],
    ]);
    if (!alive()) return;
    const total = (k) => Math.round(lines.filter((l) => l.kind === k).reduce((t, l) => t + Number(l.amount), 0) * 100) / 100;
    const R = total("receipt"), H = total("hiring"), A = total("ancillary"), P = Math.round((R - H - A) * 100) / 100;
    const open = isAdmin() && !posted;
    // Funds: before = at the last posted accounts; then any transfers since; then this event's profit or loss.
    const moved = posted ? posted.transfers : transfers.filter((t) => !t.accounts_post_id).reverse();
    const mv = posted ? null : pendingNet(moved);
    const before = posted ? { kitty: Number(posted.kitty_before), events: Number(posted.events_before) } : { kitty: Number(fs.kitty) - mv.kitty, events: Number(fs.events) - mv.events };
    const after = posted ? { kitty: Number(posted.kitty_after), events: Number(posted.events_after) } : { kitty: Number(fs.kitty), events: Number(fs.events) + P };
    // A family event's profit or loss goes to the Family Events fund instead of the events fund.
    const fam = (posted ? posted.fund : pick.fund) === "family";
    if (fam) {
      if (!posted) after.events = Number(fs.events);
      before.family = posted ? Number(posted.fund_before) : Number(fs.family || 0);
      after.family = posted ? Number(posted.fund_after) : Number(fs.family || 0) + P;
    }
    const fundName = fam ? "Family Events fund" : "events fund";
    const pics = photoOrder(lines);
    const appTickets = bks.filter((b) => b.paid && b.status === "booked").reduce((t, b) => t + Number(b.amount), 0);
    const cardFees = bks.reduce((t, b) => t + Number(b.card_fee || 0), 0);
    const has = (what) => lines.some((l) => l.what === what);

    const section = (k) => {
      const ls = lines.filter((l) => l.kind === k);
      return `<h3>${LINE_KIND[k]}</h3><div class="scroll"><table><tbody>
        ${ls.map((l) => `<tr><td style="white-space:normal">${l.photo ? `<img class="receipt-thumb" src="${esc(l.photo)}" alt="Receipt photo" data-zoom>` : ""}${esc(l.what)}</td>
          <td class="amt">${money(l.amount)}</td>${open ? `<td class="amt"><button class="btn small" data-del="${l.id}">Remove</button></td>` : ""}</tr>`).join("")
          || `<tr><td class="muted">None</td><td></td>${open ? "<td></td>" : ""}</tr>`}
        <tr><td><b>Total ${k === "receipt" ? "receipts" : LINE_KIND[k].slice(3).toLowerCase()}</b></td><td class="amt"><b>${money(total(k))}</b></td>${open ? "<td></td>" : ""}</tr>
      </tbody></table></div>`;
    };
    const cell = (v) => `<td class="amt ${v < 0 ? "neg" : ""}">${v === null || v === undefined ? "" : money(v)}</td>`;
    const fundRow = (label, k, e, f) => `<tr><td style="white-space:normal">${label}</td>${cell(k)}${cell(e)}${fam ? cell(f) : ""}</tr>`;
    const summary = `<h3>Summary</h3><div class="scroll"><table><tbody>
        <tr><td>Receipts</td><td class="amt">${money(R)}</td></tr>
        <tr><td>Less A. Hiring costs</td><td class="amt">${money(-H)}</td></tr>
        <tr><td>Less B. Ancillary costs</td><td class="amt">${money(-A)}</td></tr>
        <tr><td><b>${P < 0 ? "Loss" : "Profit"}</b></td><td class="amt ${P < 0 ? "neg" : ""}"><b>${money(P)}</b></td></tr>
      </tbody></table></div>
      <h3>Funds</h3><div class="scroll"><table><thead><tr><th></th><th class="amt">Kitty</th><th class="amt">Events</th>${fam ? '<th class="amt">Family</th>' : ""}</tr></thead><tbody>
        ${fundRow(`<b>Before</b> <span class="muted">(at the last accounts)</span>`, before.kitty, before.events, before.family)}
        ${moved.map((t) => { const a = Number(t.amount), f = t.from || t.from_fund;
          return fundRow(`Transfer: ${esc(t.reason)} <span class="muted">${short(parseDay(t.on_date))}</span>`, f === "kitty" ? -a : a, f === "events" ? -a : a, null); }).join("")}
        ${fundRow(`Event ${P < 0 ? "loss" : "profit"}`, null, fam ? null : P, fam ? P : null)}
        ${fundRow(`<b>${posted ? "After" : "After posting"}</b>`, after.kitty, after.events, after.family)}
      </tbody></table></div>`;

    const L = "________";
    const draft = () => {
      const t = [`${pick.title} - ${evDate(pick)}`, "Events accounts", L];
      KIND_ORDER.forEach((k) => {
        const ls = lines.filter((l) => l.kind === k).sort((a, b) => cmp(a.created_at, b.created_at) || cmp(a.id, b.id));
        t.push(LINE_KIND[k]);
        if (!ls.length) t.push("None");
        ls.forEach((l) => { t.push(`${l.what} ${money(l.amount)}`); if (l.photo) t.push(`{photo ${pics.indexOf(l) + 1}}`); });
        t.push(`Total ${money(total(k))}`, L);
      });
      t.push(`Receipts ${money(R)}`, `Less costs ${money(H + A)}`, `${P < 0 ? "Loss" : "Profit"} ${money(P)}`, L,
        "Before funds", `Kitty fund ${money(before.kitty)}`, `Events fund ${money(before.events)}`, ...(fam ? [`Family Events fund ${money(before.family)}`] : []), L,
        "Transfers between funds", ...(moved.length ? moved.map(transferLine) : ["None"]), L,
        `Event ${P < 0 ? "loss from" : "profit to"} ${fundName} ${money(Math.abs(P))}`, L,
        "Updated funds", `Kitty fund ${money(after.kitty)}`, `Events fund ${money(after.events)}`, ...(fam ? [`Family Events fund ${money(after.family)}`] : []));
      return t.join("\n");
    };

    el.innerHTML = `<div class="events"><div class="card fb"><h2>Events accounts</h2>
      ${fundStats(fs)}
      <div class="tabs-scroll">${list.map((e) => `<button class="${e.id === pick.id ? "on" : ""}" data-ev="${e.id}">${esc(e.title)} · ${e.day ? short(parseDay(e.day)) : "TBC"}${postedOf(e) ? " ✓" : ""}</button>`).join("")}</div>
      <h2 style="margin-top:14px">${esc(pick.title)}</h2>
      <p class="muted">${evDate(pick)} · Linked to the ${fundName} · ${posted ? `Accounts posted ${short(new Date(posted.posted_at))}` : "Not posted yet"}</p>
      ${KIND_ORDER.map(section).join("")}
      ${open ? `<h3>Add a receipt or cost</h3>
        ${appTickets && !has("Tickets paid in the app") ? `<button class="btn small" id="qTickets" style="margin:0 8px 8px 0">Add ${money(appTickets)} tickets paid in the app</button>` : ""}
        ${cardFees && !has("Card payment fees") ? `<button class="btn small" id="qFees" style="margin:0 0 8px">Add ${money(cardFees)} card fees</button>` : ""}
        <div class="grid2"><div><label>Type</label><select id="lKind"><option value="receipt">Receipt (money in)</option><option value="hiring">A. Hiring cost</option><option value="ancillary">B. Ancillary cost</option></select></div>
          <div><label>Amount £</label><input id="lAmt" type="number" step="0.01" min="0.01" inputmode="decimal"></div></div>
        <label>What for</label><input id="lWhat" placeholder="e.g. Hall hire, Tickets on the door, Snacks">
        <label>Receipt photo (optional)</label><input id="lPhoto" type="file" accept="image/*">
        <div class="form-actions"><button class="btn solid block" id="lAdd">Add</button></div>` : ""}
      ${summary}
      ${open ? `<p class="muted">Hiring costs are hall, room or pitch hire. Ancillary costs are everything else: food, prizes, printing, card fees.</p>
        <div class="form-actions"><button class="btn solid block" id="eaDraft" ${lines.length ? "" : "disabled"}>Draft accounts</button></div>
        <div id="eaBox" hidden><label>Accounts (edit freely)</label><textarea id="eaText" rows="18" class="mono"></textarea>
          <p class="muted" style="font-size:14px">{photo 1}, {photo 2} and so on show that receipt's photo at that spot in the chat post.</p>
          <div class="form-actions" style="display:grid;gap:10px"><button class="btn solid block" id="eaPost">Confirm and post to the ${fam ? "BR3 Family Events Accounts" : "Footballing Events Accounts"} chat</button><button class="btn block" id="eaCopy">Copy for WhatsApp</button></div></div>` : ""}
    </div></div>`;

    el.querySelectorAll("[data-ev]").forEach((b) => (b.onclick = () => go("eventaccounts:" + b.dataset.ev)));
    if (!open) return;
    const addLine = async (row) => { try { await q(sb.from("event_account_lines").insert({ event_id: pick.id, created_by: me.id, ...row })); toast("Added"); refresh(); } catch (e) { fail(e); } };
    if ($("#qTickets", el)) $("#qTickets", el).onclick = () => addLine({ kind: "receipt", what: "Tickets paid in the app", amount: appTickets });
    if ($("#qFees", el)) $("#qFees", el).onclick = () => addLine({ kind: "ancillary", what: "Card payment fees", amount: Math.round(cardFees * 100) / 100 });
    let photo = null;
    $("#lPhoto", el).onchange = () => { const f = $("#lPhoto", el).files[0]; photo = null; if (!f) return;
      const rd = new FileReader(); rd.onload = async () => { photo = await shrink(rd.result, 1600); }; rd.readAsDataURL(f); };
    $("#lAdd", el).onclick = async () => {
      const amt = Math.round(Number($("#lAmt", el).value) * 100) / 100, what = $("#lWhat", el).value.trim();
      if (!what) return toast("Say what it's for");
      if (!(amt > 0)) return toast("Enter an amount");
      if ($("#lPhoto", el).files[0] && !photo) return toast("The photo is still loading, try again in a moment");
      $("#lAdd", el).disabled = true;
      await addLine({ kind: $("#lKind", el).value, what, amount: amt, photo });
      if ($("#lAdd", el)) $("#lAdd", el).disabled = false;
    };
    el.querySelectorAll("[data-del]").forEach((d) => (d.onclick = async () => {
      if (d.dataset.sure !== "1") { d.dataset.sure = "1"; d.textContent = "Tap again"; return; }
      try { d.disabled = true; await q(sb.from("event_account_lines").delete().eq("id", d.dataset.del)); toast("Removed"); refresh(); } catch (e) { d.disabled = false; fail(e); }
    }));
    $("#eaDraft", el).onclick = () => { $("#eaText", el).value = draft(); $("#eaBox", el).hidden = false; $("#eaText", el).focus(); };
    $("#eaCopy", el).onclick = async () => { try { await navigator.clipboard.writeText(noPhotos($("#eaText", el).value)); toast("Copied. Paste it into WhatsApp"); } catch { $("#eaText", el).select(); toast("Select all and copy"); } };
    $("#eaPost", el).onclick = async () => {
      if (!confirm(`Post the accounts for ${pick.title}? The ${P < 0 ? `loss of ${money(-P)} comes out of` : `profit of ${money(P)} goes into`} the ${fundName}, and the receipts and costs can't be changed after.`)) return;
      try {
        $("#eaPost", el).disabled = true;
        await q(sb.rpc("post_event_accounts", { p_event: pick.id, p_body: $("#eaText", el).value }));
        toast(`Accounts posted to the ${fam ? "BR3 Family Events Accounts" : "Footballing Events Accounts"} chat`); refresh();
      } catch (e) { $("#eaPost", el).disabled = false; fail(e); }
    };
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
    const guestName = b.display_name.replace(/ \([^)]*\)$/, ""), pitch = b.pitch_link;
    const due = b.paid && b.topup_method === "link" ? Number(b.topup) : Number(b.amount) - Number(b.credit_used || 0); // a QR kitty top-up pays just the top-up
    const url = `${location.origin}${location.pathname}#guest:${b.code}`;
    const text = pitch ? `Hi ${guestName}, please pay ${money(due)} ${b.topup_method === "link" ? "to top up to the kitty" : "for tonight's football"} here:`
      : `Hi ${guestName}, I've booked you in for football on ${short(parseDay(ev.day))} at ${hhmm(ev.time)}. Please pay ${money(due)} for your place ${payByText(ev, b.created_at)}, or it's released. Your QR code ticket is on the same page, so take a screenshot and show it at the game:`;
    modal(`<button class="close" aria-label="Close">×</button><h2>${pitch ? `${esc(guestName)}: scan to pay` : `Send ${esc(guestName)} a payment link`}</h2>
      ${pitch ? `<p>Ask ${esc(guestName)} to scan this with their phone camera and pay ${money(due)} by card.</p><div id="glQr" style="display:grid;place-items:center;background:#fff;padding:12px;border-radius:10px;margin:10px 0"></div>` : ""}
      <p class="muted">${pitch ? `${esc(guestName)} pays ${money(due)} on the link, and shows as Paid once it's in. Until then they show as Unpaid.`
        : `${esc(guestName)} pays ${money(due)} on the link. Their payment shows your name and theirs, and they show as Paid on the roster once it's in. If it isn't paid ${payByText(ev, b.created_at)}, their place is released.`}</p>
      ${pitch ? "" : `<p class="note">The link also shows ${esc(guestName)}'s QR code ticket. They can take a screenshot of it and show it at the game. As a back-up, you have a copy too: tap "Show my friend's ticket" on the Football page.</p>`}
      <div class="form-actions"><button class="btn ${pitch ? "" : "solid "}block" id="glSend">${ICON.share} ${pitch ? "Or send them the link" : "Send the link"}</button>
        <button class="btn block" id="glCopy" style="margin-top:10px">Copy the link</button></div>`, (m) => {
      if (pitch) qr($("#glQr", m), url, 220);
      $("#glSend", m).onclick = async () => {
        if (navigator.share) { try { await navigator.share({ title: "Football payment", text, url }); closeModal(); } catch {} return; }
        location.href = `https://wa.me/?text=${encodeURIComponent(`${text} ${url}`)}`;
      };
      $("#glCopy", m).onclick = async () => { try { await navigator.clipboard.writeText(`${text} ${url}`); toast("Link copied. Paste it to your friend"); } catch { toast(url); } };
    });
  }
  // A ticket link the admin emails to an approved applicant: keeps the ticket on this phone and opens it.
  async function ticketLink(el, alive, code) {
    code = String(code || "").trim().toUpperCase();
    if (code && !state.guestTickets.includes(code)) { state.guestTickets.push(code); save(); }
    await events(el, alive);
    if (alive() && code) showTicket(code);
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
    const ev = g.event, open = g.pitch || new Date() < placePayBy(ev, g.created_at);
    el.innerHTML = `<div class="events"><div class="card fb">
      <h2>${esc(ev.title || "Football")}</h2><p class="muted">${short(parseDay(ev.day))} · ${hhmm(ev.time)}</p>
      <p style="font-size:18px"><b>${esc(g.guest)}</b>, ${g.pitch ? "added by the organisers" : `booked by <b>${esc(g.member)}</b>`}</p>
      ${g.pitch ? "" : `<div class="ticket"><div class="qr" id="gq"></div><div class="code">${esc(code)}</div><div class="muted">Take a screenshot and show this QR code at the game. The friend who booked you has a copy too.</div></div>`}
      ${g.paid ? `<p class="note">Paid, thank you. See you on the pitch!</p>`
        : g.pitch ? `<p class="note">Please pay <b>${money(g.amount)}</b> ${g.topup ? "to top up to the kitty for this session" : "for tonight's game"}.</p>
          <button class="btn solid block" data-pay="${esc(code)}" data-guest="1">Pay ${money(g.amount)} by card</button>`
        : open ? `<p class="note">Please pay <b>${money(g.amount)}</b> ${payByText(ev, g.created_at)}, or your place is released.</p>
          <button class="btn solid block" data-pay="${esc(code)}" data-guest="1">Pay ${money(g.amount)} by card</button>`
        : `<p class="note">The time to pay has passed, so this place is being released.</p>`}
      <p class="muted">6-a-side at Goals, Beckenham, Elmers End Road, BR3 4EJ. Get together at ${hhmm(ev.time)} next to Pitch 1. Players must be 16 or over, and play is at your own risk.</p>
    </div></div>`;
    if ($("#gq", el)) qr($("#gq", el), code);
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
        <li>Can't make it? Please cancel as soon as you know, to free up the space for someone else. Remove yourself here and everyone below moves up a place. This works on trust, and we, the organisers, trust you!</li>
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
    const [allGames, fs] = await Promise.all([
      q(sb.from("events").select("*").eq("kind", "football").not("day", "is", null).order("day")),
      q(sb.from("fund_state").select("*").single()),
    ]);
    const games = allGames.filter((g) => g.day);
    // the game to show: the next one not yet finished, else the last one still awaiting accounts
    const ev = games.find((g) => eventEnd(g) > now) || [...games].reverse().find((g) => !g.accounts_posted) || null;
    const awaiting = games.filter((g) => !g.accounts_posted && eventEnd(g) <= now);
    const bookings = ev ? await q(sb.from("bookings").select("*").eq("event_id", ev.id).neq("status", "cancelled").order("created_at")) : [];
    const removed = ev ? (await q(sb.from("football_removed").select("event_id").eq("event_id", ev.id).eq("user_id", me.id)).catch(() => [])).length > 0 : false;
    // New member offer: their first game is £1 and the events fund pays the rest.
    const intro = ev && fs.intro_offer && !bookings.some((b) => b.user_id === me.id) ? await q(sb.rpc("my_intro_offer")).catch(() => false) : false;
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
      const opens = fbOpens(ev), payBy = fbPayBy(ev), start = eventStart(ev);
      // Football Awards voting: 11pm on match day (or an hour after kick-off if later) for 24 hours, as in award_opens().
      const voteOpens = new Date(Math.max(at(ev.day, "23:00"), start.getTime() + 36e5)), voteCloses = new Date(voteOpens.getTime() + 864e5);
      const phase = now < opens ? "closed" : now < payBy ? "open" : now < start ? "locked" : now < voteOpens ? "played" : "voting";
      const PH = { closed: "Booking opens Wednesday 1pm", open: "Booking open", locked: "Pay deadline passed", played: "Game played", voting: "Awards voting open" };
      const steps = [["Wed 1pm", "Booking opens", opens, "open"], ["Thu 11pm", "Unpaid places removed", payBy, "locked"], [`Fri ${hhmm(ev.time)}`, `Game ${week} of up to 5 in kitty ${fs.session_no}`, start, "played"],
        ["Fri 11pm", "🏆 Awards voting opens for tonight's players", voteOpens, "voting"], ["Sat 11pm", "Voting closes and the winners are announced", voteCloses, "results"]];
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
        const st = mine.charge === "covered" ? "Booked, covered by your kitty" : mine.paid ? (mine.method === "credit" ? "Booked, paid with credit" : mine.method === "card" ? "Booked and paid by card" : "Booked and paid") + (mine.method !== "credit" && Number(mine.credit_used) > 0 ? `, ${money(mine.credit_used)} of it from your credit` : "") : "Booked, not paid yet";
        body = `<p><b>${st}.</b> You're number ${bookings.indexOf(mine) + 1} on the list.</p>
          <button class="btn" data-ticket="${esc(mine.code)}" style="margin-bottom:10px">Show my ticket (QR code)</button>
          ${!mine.paid ? `<p class="note">Please pay <b>${money(cashPart(mine))}</b>${Number(mine.credit_used) > 0 ? ` (${money(mine.credit_used)} of the ${money(mine.amount)} came from your credit)` : ""} ${new Date(mine.created_at) > payBy ? "within <b>30 minutes</b> of booking" : "before <b>Thursday 11pm</b>"}, or your place is released and you can't rebook this game.${me.family ? " Pay the organiser by bank transfer." : " Pay by card here, or by bank transfer to the organiser."}</p>
            ${me.family ? "" : `<button class="btn solid" data-pay="${esc(mine.code)}" style="margin-bottom:10px">Pay ${money(cashPart(mine))} by card</button>`}` : ""}
          ${me.family && mine.method === "transfer" ? `<p class="muted">As family you're added automatically each week. If you can't come, remove yourself to free your place.</p>`
            : mine.charge === "payg" && mine.paid ? `<p class="muted">If you can't make it, please cancel as soon as you know, to free up the space for someone else. Your ${money(mine.amount).replace(".00", "")} becomes credit for your next game. This works on trust, and we, the organisers, trust you!</p>` : ""}
          <button class="btn" id="cancel">Remove me</button>`;
      } else if (pending()) body = `<p class="note">You can book once the admin has approved your membership.</p>`;
      else if (removed) body = `<p class="note">Your place was released because it wasn't paid in time, so you can't rebook this game. Message the organiser if something went wrong.</p>`;
      else if (phase === "closed") body = `<p>Booking for this game opens <b>Wednesday at 1pm</b>.</p>`;
      else if (phase === "played" || phase === "voting") body = `<p>This game has been played.</p>`;
      else if (bookings.length >= ev.capacity) body = `<p>All ${ev.capacity} places are taken.</p>`;
      else if (kitty) body = `${RISK}<p class="muted">Your kitty membership covers this game.</p><button class="btn solid" data-choice="payg">Book my place</button>`;
      else {
        // Members with credit choose whether to put it towards this booking (all of it, up to the price) or keep it.
        const cr = me.family ? 0 : Number(me.credit) || 0, use = cr > 0 && useCredit;
        const left = (price) => Math.max(price - (use ? cr : 0), 0);
        const label = (price) => me.family ? `${money(price)} by transfer` : !use ? `Pay ${money(price)}`
          : left(price) === 0 ? `Use ${money(price)} of my credit` : `Pay ${money(left(price))} + ${money(Math.min(cr, price))} credit`;
        const MP = intro && P > 1 ? 1 : P;
        const due = !me.family && left(MP) > 0;
        body = `${RISK}<p class="muted">How do you want to pay for this game?${due && phase === "open" ? " Pay by Thursday 11pm or your place is released, and you won't be able to rebook." : due ? " The pay deadline has passed, so pay by card straight away: unpaid places are released after 30 minutes." : ""}</p>
          ${cr > 0 ? `<div class="credit-choice"><b>You have ${money(cr)} credit</b>
            <label class="check"><input type="radio" name="useCr" value="1" ${use ? "checked" : ""}> Use it towards this booking</label>
            <label class="check"><input type="radio" name="useCr" value="0" ${use ? "" : "checked"}> Keep it for later and pay in full</label></div>` : ""}
          <div class="choices">
            ${MP < P ? `<div><b>£1 · your first game</b><span class="muted">New member offer: your first game is just £1, and the other ${money(P - MP).replace(".00", "")} comes from the events fund.</span><button class="btn solid small" data-choice="payg">${label(MP)}</button></div>`
              : `<div><b>${P$} · this game</b><span class="muted">Pay as you play, just this Friday.${P < 6 ? " Launch offer price." : ""}</span><button class="btn solid small" data-choice="payg">${label(P)}</button></div>`}
            <div><b>£15 · kitty</b><span class="muted">Every game until the kitty resets. This is week ${week} of up to 5.${use ? ` You pay ${money(left(15))}${left(15) ? " by card" : ""}.` : ""}</span><button class="btn small" id="kittyAsk">Choose the kitty</button></div>
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
          <button class="btn" data-ticket="${esc(friend.code)}" style="margin-bottom:10px">Show my friend's ticket</button>
          <button class="btn" id="cancelFriend">Remove my friend</button>`
        : canAdd && !mine && bookings.length < ev.capacity ? `<h3>Bring a friend</h3><p class="muted">Friends are always welcome, as long as you book them in and come with them. Book your own place first, then you can add one friend to this game.</p>`
        : canAdd && bookings.length < ev.capacity ? `<h3>Bring a friend</h3><p class="muted">You can add one friend per game, as long as you come with them. ${me.family ? `Pay their ${F$} by transfer, or send them a payment link` : `Pay their ${F$} yourself${Number(me.credit) >= F ? ", by card or from your credit," : ""} or send them a payment link`}.</p><button class="btn" id="addFriend">Add a friend</button>` : "";
      you = `<div class="card fb"><h2>You</h2>${pills}${body}${friendBox}</div>`;

      const paidCount = bookings.filter((b) => b.paid).length;
      players = `<div class="card fb"><div class="row" style="justify-content:space-between"><h2>Roster</h2><span class="muted">${bookings.length} booked · ${paidCount} paid</span></div>
        <p class="muted">Everyone on the list for this game. If someone drops out or is removed for not paying, everyone below moves up a place. Places 1 to ${PITCH} are guaranteed play if you arrive on time.</p>
        <ol class="players">${bookings.map((b, i) => `<li value="${i + 1}"><span>${esc(b.display_name)}${b.user_id === me.id || b.booked_by === me.id ? " ★" : ""}</span>${b.charge === "covered" || b.charge === "kitty" ? '<span class="tag gold">Kitty</span>' : ""}${b.paid ? '<span class="tag">Paid</span>' : '<span class="tag warn">Unpaid</span>'}${b.checked_in ? '<span class="tag">Here</span>' : ""}</li>`).join("") || '<li class="muted">No one has booked yet.</li>'}</ol>
        <p class="note">If we reach 25 booked and confirmed by Thursday night, then we will endeavour to inshaAllah book 2 pitches and have ourselves a mini-tournament.</p></div>`;
    }

    const fund = `<div class="card fb"><p class="muted" style="margin:0">Kitty fund <b>${money(fs.kitty)}</b> · kitty ${fs.session_no}, ${fs.games_played} of 5 games played${fs.games_played < 5 ? `, next is game ${fs.games_played + 1} of 5` : ""}. Past accounts are in the <a href="#chat:football-accounts">Friday Football Accounts chat</a>.</p>
      ${isDoor() || supFootball() ? `<div class="form-actions"><button class="btn solid block" data-go="supervisors">Football Supervisors</button>${isAdmin() ? '<button class="btn block" data-go="footballadmin">Football Accounts</button>' : ""}</div>` : ""}</div>`;

    el.innerHTML = `<div class="events">${offerBanner(allGames, true)}${introBanner(fs.intro_offer, true)}${top}${ev ? footballInfo(ev, fs) : ""}${you}${players}${fund}<div id="awards"></div></div>`;
    footballAwards($("#awards", el), alive);
    el.querySelectorAll("[data-ticket]").forEach((b) => (b.onclick = () => showTicket(b.dataset.ticket)));

    const riskOk = () => { const r = $("#riskOk", el); if (r && r.checked) return true; toast("Please tick to confirm you play at your own risk"); return false; };
    el.querySelectorAll("[data-choice]").forEach((b) => (b.onclick = () => riskOk() && bookFootball(ev, b.dataset.choice)));
    el.querySelectorAll('[name="useCr"]').forEach((r) => (r.onchange = () => { useCredit = r.value === "1"; const ok = $("#riskOk", el)?.checked; refresh().then(() => { const c = $("#riskOk", view); if (c && ok) c.checked = true; }); }));
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
      <div class="form-actions"><button class="btn solid block" id="join">Join the kitty and book · ${me.family ? "£15 by transfer" : useCredit && Number(me.credit) > 0 ? (Number(me.credit) >= 15 ? "£15 from my credit" : `${money(15 - Number(me.credit))} + ${money(me.credit)} credit`) : "£15"}</button></div>`, (m) => {
      $("#join", m).onclick = () => { closeModal(); bookFootball(ev, "kitty"); };
    });
    const cx = $("#cancel", el);
    if (cx) cx.onclick = async () => {
      const mine = bookings.find((b) => b.user_id === me.id);
      if (mine && !mine.paid && mine.square_order_id) payApi({ code: mine.code, confirm: true }).then((r) => { if (r.paid && alive()) { toast("Payment received, thank you!"); refresh(); } }).catch(() => {});
      const myFriend = bookings.find((b) => b.booked_by === me.id);
      if (myFriend) return modal(`<button class="close" aria-label="Close">×</button><h2>Remove your friend first</h2><p style="line-height:1.5">Friends can only play when you come with them. Please remove <b>${esc(myFriend.display_name)}</b> first, using "Remove my friend", then remove yourself.</p>`);
      if (cx.dataset.sure !== "1") { cx.dataset.sure = "1"; cx.textContent = "Tap again to remove yourself"; return; }
      try { toast(await q(sb.rpc("cancel_booking", { p_id: mine.id }))); await loadMe(); refresh(); } catch (e) { fail(e); }
    };
  }
  // ---------- Football Awards (supabase/add-football-awards.sql, then update-football-awards.sql) ----------
  // Players ticked in on the night pick one player per award (a different player each time, never themselves),
  // for 24 hours from 11pm. Loads after the rest of the page so it never slows the football tab down.
  // Man of the Match first, then the other four as a 2×2 grid (update-football-awards-save.sql).
  const AWARDS = [["overall", "🏅 Man of the Match"], ["save", "🧤 Best Save / Defensive Play"], ["motivator", "📣 Best Team Motivator"], ["goal", "⚽ Best Goal"], ["assist", "🎯 Best Assist"]];
  // The awards table also has Most Rounded Player: every vote across the four awards added up, Man of the Match not counted.
  const AWARD_TABS = [["rounded", "🌟 Most Rounded Player"], ...AWARDS];
  const MOTM_NOTE = "Anyone who stood out, including your picks below";
  const whenText = (iso) => { const d = new Date(iso), h = d.getHours(), m = d.getMinutes();
    return `${DAYS[d.getDay()]} ${h % 12 || 12}${m ? ":" + String(m).padStart(2, "0") : ""}${h < 12 ? "am" : "pm"}`; };
  const plural = (n, w) => `${n} ${w}${n === 1 ? "" : "s"}`;
  let awardKitty = null;
  async function footballAwards(box, alive) {
    if (!box || !me) return;
    if (!pending()) await sb.rpc("post_due_awards").then(() => {}, () => {}); // posts results that are due; harmless if someone already did
    const a = await q(sb.rpc("award_ballot")).catch(() => null);
    if (!alive() || !a || !box.isConnected) return;
    awardKitty = a.kitty || null;
    const day = (() => { const d = parseDay(a.day); return `${DAYS[d.getDay()]} ${d.getDate()} ${MONTHS[d.getMonth()]}`; })();
    const voted = (a.mine || []).length > 0, n = a.voters || 0;
    const names = (list) => list.map((x) => esc(x.name)).join(" and ");
    let inner;
    if (a.state === "soon") inner = `<p>After tonight's game, the players who were ticked in vote for Man of the Match, Best Save / Defensive Play, Best Team Motivator, Best Goal and Best Assist. Voting opens at <b>${whenText(a.opens)}</b> and stays open for 24 hours.</p>`;
    else if (a.state === "open") inner = `<p>Vote for the best from <b>${day}</b>. Voting closes <b>${whenText(a.closes)}</b>. ${plural(n, "player")} ${n === 1 ? "has" : "have"} voted so far.</p>
      ${a.can_vote ? `${voted ? '<p class="muted">You\'ve voted ✓ You can change your votes until voting closes.</p>' : ""}<button class="btn solid block" id="awVote">${voted ? "Change my votes" : "Vote now"}</button>`
        : '<p class="muted">Only players ticked in on the night can vote.</p>'}
      <p class="muted" style="font-size:13px">Results are hidden until voting closes, then posted in the Friday Football chat.</p>`;
    else {
      const won = (a.results || []).filter((r) => r.best.length);
      inner = !won.length ? `<p class="muted">Nobody voted for the ${day} game.</p>`
        : `<p class="muted">Winners from ${day}, voted by ${plural(n, "player")}.</p><div class="aw-grid">${won.map((r) => `<div class="aw-cell${r.category === "overall" ? " wide" : ""}">
            <span class="muted" style="font-size:13px">${esc(r.label)}</span><b>${names(r.best)}</b><span class="aw-votes">${plural(r.best[0].votes, "vote")}${r.best.length > 1 ? " each" : ""}</span></div>`).join("")}</div>`;
    }
    box.innerHTML = `<div class="card fb"><div class="row" style="justify-content:space-between;flex-wrap:wrap"><h2>🏆 Football Awards</h2>${a.state === "open" ? '<span class="tag gold">Voting open</span>' : ""}</div>
      ${inner}<button class="btn block" id="awTable" style="margin-top:10px">Awards table</button></div>`;
    $("#awTable", box).onclick = () => awardTable("kitty", "rounded");
    const v = $("#awVote", box);
    if (v) v.onclick = () => awardVote(a, () => footballAwards(box, alive));
  }
  // One dropdown per award. Anyone already picked for another award shows as "already picked".
  function awardVote(a, done) {
    const pick = (c) => ((a.mine || []).find((x) => x.category === c) || {}).pick || "";
    modal(`<h2>🏆 Football Awards</h2>
      <p class="muted" style="line-height:1.5">One player per award, and a different player for each of the four awards under Man of the Match. You can't pick yourself. Skip any you're not sure about.</p>
      ${AWARDS.map(([c, label]) => `<label style="margin-top:14px">${label}${c === "overall" ? ` <span class="muted" style="font-weight:400">(${MOTM_NOTE.toLowerCase()})</span>` : ""}</label><select data-c="${c}"></select>`).join("")}
      <div class="form-actions"><button class="btn solid block" id="awSave">Save my votes</button></div>`, (m) => {
      const sels = [...m.querySelectorAll("select[data-c]")];
      const fill = () => {
        // Man of the Match can go to anyone who played; the other awards need a different player each.
        const taken = (s) => s.dataset.c === "overall" ? [] : sels.filter((o) => o !== s && o.value && o.dataset.c !== "overall").map((o) => o.value);
        sels.forEach((s) => {
          const cur = s.value || s.dataset.v || "", t = taken(s);
          s.innerHTML = `<option value="">Choose a player</option>${a.players.map((p) => `<option value="${esc(p.id)}" ${t.includes(p.id) ? "disabled" : ""} ${p.id === cur ? "selected" : ""}>${esc(p.name)}${t.includes(p.id) ? " (already picked)" : ""}</option>`).join("")}`;
          delete s.dataset.v;
        });
      };
      sels.forEach((s) => { s.dataset.v = pick(s.dataset.c); s.onchange = fill; });
      fill();
      $("#awSave", m).onclick = async () => {
        const votes = sels.map((s) => ({ category: s.dataset.c, pick: s.value })).filter((x) => x.pick);
        if (!votes.length) return toast("Pick at least one player");
        const others = votes.filter((x) => x.category !== "overall");
        if (new Set(others.map((x) => x.pick)).size < others.length) return toast("Pick a different player for each award. Only Man of the Match can repeat a player");
        try { $("#awSave", m).disabled = true; await q(sb.rpc("cast_award_votes", { p_event: a.event_id, p_votes: votes })); closeModal(); toast("Thanks, your votes are in ✓"); done(); }
        catch (e) { $("#awSave", m).disabled = false; fail(e); }
      };
    });
  }
  // Top 6 for one award (or Most Rounded Player) at a time: last game, this kitty, or all time.
  async function awardTable(period, cat) {
    const rows = await q(sb.rpc("award_table", { p_period: period, p_category: cat })).catch(() => null);
    const top = (rows || []).filter((r, i) => i < 6), mine = (rows || []).find((r) => r.me), inTop = top.some((r) => r.me);
    const won = (r) => !r.wins ? "" : cat === "rounded" ? `Won ${plural(r.wins, "award")}` : period === "last" ? "Winner" : `Won ${plural(r.wins, "game")}`;
    const row = (r) => `<div class="lb-row ${r.me ? "me" : ""}"><span class="lb-rank">${r.rank}</span>
      <div style="flex:1;min-width:0"><b>${esc(r.name)}${r.me ? " (you)" : ""}</b><div class="muted" style="font-size:13px">${won(r)}</div></div><b class="lb-score">${r.votes}</b></div>`;
    const P = { last: "Last game", kitty: "This kitty", all: "All time" };
    modal(`<h2>🏆 Awards table</h2>
      <p class="muted" style="line-height:1.5">${period === "kitty" && awardKitty ? `Kitty ${awardKitty}, up to 5 games. ` : ""}Each vote is 1 point. Results count once each game's voting closes.${cat === "rounded" ? " Most Rounded Player adds up every vote across the four awards, not counting Man of the Match." : ""}</p>
      <div class="seg">${Object.entries(P).map(([k, l]) => `<button data-p="${k}" class="${period === k ? "on" : ""}">${l}</button>`).join("")}</div>
      <div class="aw-tabs">${AWARD_TABS.map(([c, l]) => `<button data-k="${c}" class="${cat === c ? "on" : ""}">${l.replace(/^\S+\s/, "")}</button>`).join("")}</div>
      ${rows === null ? '<p class="note">The awards are being set up. Check back soon.</p>'
        : top.length ? `<div class="lb">${top.map(row).join("")}</div>${mine && !inTop ? `<p class="muted" style="margin:14px 0 4px">Your place</p><div class="lb">${row(mine)}</div>` : ""}`
        : '<p class="muted">No votes counted yet.</p>'}`, (m) => {
      m.querySelectorAll("[data-p]").forEach((b) => (b.onclick = () => awardTable(b.dataset.p, cat)));
      m.querySelectorAll("[data-k]").forEach((b) => (b.onclick = () => awardTable(period, b.dataset.k)));
    });
  }
  let useCredit = true; // the member's choice on the booking screen: put their credit towards it, or keep it
  async function bookFootball(ev, choice) {
    try {
      const b = await q(sb.rpc("book_football", { p_event: ev.id, p_choice: choice, p_risk: true, p_use_credit: useCredit && !me.family && Number(me.credit) > 0 }));
      toast(b.paid ? "You're booked ✓" : "Booked. Pay by Thursday 11pm to keep your place");
      await loadMe(); refresh();
    } catch (e) { fail(e); }
  }

  // Organiser tools on the football screen: payments, accounts and adding the next game.
  // A place can be paid partly from the member's credit: the rest is the money that came in by card, transfer or cash.
  // A kitty top-up at the pitch is kept apart: what they paid first stays with its method, the top-up has its own.
  const cashPart = (b) => Number(b.amount) - Number(b.credit_used || 0) - Number(b.topup || 0);
  const creditPart = (b) => (b.method === "credit" ? Number(b.amount) : Number(b.credit_used || 0));
  const sumBy = (bs, m) => (bs.filter((b) => b.paid && b.method === m && b.status !== "waitlist").reduce((t, b) => t + cashPart(b), 0)
    + bs.filter((b) => b.topup_method === m && b.status === "booked").reduce((t, b) => t + Number(b.topup || 0), 0)).toFixed(2);
  // Payments for a game, person by person: card (with Square's fee), credit, cash and transfer, summed at the bottom,
  // then less the pitch hire and the credit movement, and what should have come in.
  function paymentsBreakdown(target, bookings, cancelled, full, METHODS, pitchDefault, fs = {}, kittyMembers = null) {
    const r2 = (n) => Math.round(n * 100) / 100;
    const by = (b, m) => (b.paid && b.method === m ? cashPart(b) : 0) + (b.topup_method === m ? Number(b.topup || 0) : 0);
    // Credit column: credit used by people who count is a plus; money that goes on someone's account as credit
    // (paid but didn't come, or removed) is a minus, shown in brackets. Removed people who paid are listed too.
    const counts = (b) => b.charge === "kitty" || b.checked_in;
    const paidMoney = (b) => b.paid && ["card", "transfer", "cash"].includes(b.method);
    const creditCol = (b) => (counts(b) ? creditPart(b) : b.charge === "payg" && paidMoney(b) ? -cashPart(b) : 0);
    const removed = cancelled.filter(paidMoney).map((b) => ({ ...b, removed: true }));
    const rows = [...bookings.filter((b) => b.charge !== "covered"), ...removed].map((b) => ({ b, card: by(b, "card"), fee: Number(b.card_fee || 0) + Number(b.topup_fee || 0), credit: b.removed ? -cashPart(b) : creditCol(b), cash: by(b, "cash"), transfer: by(b, "transfer") }));
    const tot = (k) => r2(rows.reduce((t, x) => t + x[k], 0));
    const T = { card: tot("card"), fee: tot("fee"), credit: tot("credit"), cash: tot("cash"), transfer: tot("transfer") };
    const grand = r2(T.card + T.cash + T.transfer);
    // Credit added this game: paid but didn't come, or cancelled for credit. Credit used: paid from credit by people who count.
    const added = r2(bookings.filter((b) => b.charge === "payg" && !b.checked_in && b.paid && ["card", "transfer", "cash"].includes(b.method)).reduce((t, b) => t + cashPart(b), 0)
      + cancelled.reduce((t, b) => t + cashPart(b), 0));
    const used = r2(bookings.filter((b) => b.charge !== "covered" && counts(b)).reduce((t, b) => t + creditPart(b), 0));
    const before = r2(grand - T.fee - (added - used));
    const here = bookings.filter((b) => b.checked_in), kittyHere = here.filter((b) => b.charge === "covered").length;
    const newKitty = bookings.filter((b) => b.charge === "kitty").length, P = Math.max(Number(target.price), 6);
    const expected = r2(Math.max(here.length - kittyHere - newKitty, 0) * P + newKitty * 15);
    const taken = r2(grand + T.credit); // what the players who count paid, credit included
    const c = (v) => `<td class="amt">${v ? (v < 0 ? `(${Math.abs(v).toFixed(2)})` : Number(v).toFixed(2)) : "–"}</td>`; // £ is in the heading; minus in brackets
    const who = (b) => `${esc(b.display_name)}<div class="muted" style="font-size:12px">${b.charge === "kitty" ? "Kitty £15" : `Pay & play ${money(b.amount)}`}${b.removed ? "" : b.checked_in ? "" : b.charge === "payg" && b.paid && b.method !== "owes" ? "" : " · not here"}</div>${b.removed || (!b.checked_in && b.charge === "payg" && b.paid && b.method !== "owes") ? `<span class="tag warn">No show${b.removed ? ", removed" : ""}</span>` : ""}
      ${b.removed ? "" : full && b.method !== "credit" ? `<select data-meth="${b.id}" ${target.accounts_posted ? "disabled" : ""} style="padding:4px;margin-top:4px;font-size:13px"><option value="">Not paid</option>${Object.entries(METHODS).map(([k, v]) => `<option value="${k}" ${b.method === k ? "selected" : ""}>${v}</option>`).join("")}</select>`
        : !b.paid && b.method !== "credit" ? '<span class="tag warn">Unpaid</span>' : ""}`;
    // Expected and actual, line by line: what the players who came should have paid, then what came in.
    const payg = here.filter((b) => b.charge === "payg");
    const full6 = (b) => Number(b.amount) + Number(b.intro_cover || 0); // the price before any new member offer
    const paygSum = r2(payg.reduce((t, b) => t + full6(b), 0));
    const same = payg.length && payg.every((b) => full6(b) === full6(payg[0]));
    const joiners = bookings.filter((b) => b.charge === "kitty");
    const kittyBooked = bookings.filter((b) => b.charge === "covered").length;
    const offer = r2(payg.reduce((t, b) => t + Number(b.intro_cover || 0), 0));
    const exp = r2(joiners.length * 15 + paygSum);
    const netCredit = r2(used - added);
    const fromPlayers = r2(T.card + netCredit + T.cash + T.transfer);
    const got = r2(fromPlayers + offer);
    const sign = (v) => (v < 0 ? `(${money(-v)})` : money(v));
    const line = (a, b, cls = "") => `<tr${cls ? ` class="${cls}"` : ""}><td>${a}</td><td class="amt">${b}</td></tr>`;
    const hire = Number(pitchDefault) || 0;
    const res = r2(got - hire - T.fee);
    const kitBefore = r2(Number(fs.kitty || 0)), evBefore = r2(Number(fs.events || 0));
    const crPrior = r2(Number(fs.credits_posted ?? fs.credits ?? 0)), crAfter = r2(crPrior - used + added), crNow = r2(Number(fs.credits ?? crAfter));
    const summary = `<h4>Expected and actual for this game</h4>
      <div class="scroll"><table class="wrap"><tbody>
        ${line("Turnout", here.length)}
        ${line("Kitty players who came", `${kittyHere} out of ${kittyMembers ?? kittyBooked}`)}
        ${line(`Joined the kitty: ${joiners.length} × £15`, money(joiners.length * 15))}
        ${line(`Paid and played: ${payg.length}${same ? ` × ${money(full6(payg[0]))}` : ""}`, money(paygSum))}
        ${line("<b>Total expected</b>", `<b>${money(exp)}</b>`)}
      </tbody></table></div>
      <h4>Received</h4>
      <div class="scroll"><table class="wrap"><tbody>
        ${line("Card via Square", money(T.card))}
        ${line(`Credits (used ${money(used)} − kept as credit ${money(added)})`, sign(netCredit))}
        ${line('Cash<div class="muted" style="font-size:12px">to be paid into Square</div>', money(T.cash))}
        ${line('Transfers<div class="muted" style="font-size:12px">from the organiser for family</div>', money(T.transfer))}
        ${line("From the events fund (new member offer)", money(offer))}
        ${line("<b>Total received</b>", `<b>${money(got)}</b>`)}
      </tbody></table></div>
      <p class="note">${got === exp ? "Balanced ✓" : `Not balanced: ${money(Math.abs(got - exp))} ${got > exp ? "more" : "less"} than expected.`}</p>`;
    // Mohamed's write-down under the payments: received, less costs, the result, then each fund before and after.
    const head = (x) => `<tr><td colspan="2" style="padding-top:14px"><b>${x}</b></td></tr>`;
    const writeDown = `<div class="scroll"><table class="wrap"><tbody>
        ${line(`Received as per above ${money(fromPlayers)}${offer ? ` + ${money(offer)} from the events fund` : ""}`, `<b>${money(got)}</b>`)}
        ${line(`LESS costs: Rental <span id="pbRent">${money(hire)}</span>, Card charges ${money(T.fee)}`, `<span id="pbCosts">(${money(hire + T.fee)})</span>`)}
        ${line('<b>Receipts over costs</b><div class="muted" style="font-size:12px">−ve means a loss</div>', `<b id="pbRes">${sign(res)}</b>`)}
      </tbody>${target.accounts_posted ? "" : `<tbody>
        ${head("UPDATED KITTY FUND")}
        ${line("Before", money(kitBefore))}
        ${line("After", `<b id="pbKit" data-before="${kitBefore}" data-got="${got}" data-fee="${T.fee}">${money(r2(kitBefore + res))}</b>`)}
        ${head("UPDATED EVENTS FUND")}
        ${line("Before", money(evBefore))}
        ${line("After", `<b>${money(r2(evBefore - offer))}</b>`)}
        ${head("UPDATED CREDITS HELD")}
        ${line("Before", money(crPrior))}
        ${line("After", `<b>${money(crAfter)}</b>`)}
        ${head("UPDATED BR3 FAMILY EVENTS FUND")}
      </tbody><tbody id="pbFam" data-day="${esc(target.day)}"><tr><td colspan="2" class="muted">Loading…</td></tr></tbody>`}</table></div>
      ${target.accounts_posted ? '<p class="muted">These accounts are posted: the funds before and after are in the Friday Football Accounts chat.</p>'
        : crNow !== crAfter ? `<p class="muted">Members' accounts hold ${money(crNow)} in credit now, ${money(Math.abs(crNow - crAfter))} ${crNow > crAfter ? "more" : "less"} than Credits held after. No-shows' credit is added when the accounts are posted; the accounts draft lists any other change.</p>` : ""}`;
    return `<h3>Payments · ${esc(target.title)} ${short(parseDay(target.day))}</h3>
      ${summary}
      ${full ? '<p class="muted">Card payments fill in by themselves from Square, with the fee. Set how anyone else paid.</p>' : '<p class="muted">Card payments fill in by themselves from Square, with the fee.</p>'}
      <div class="scroll"><table class="wrap pay"><thead><tr><th>Player</th><th class="amt">Card £</th><th class="amt">Fee</th><th class="amt">Credit</th><th class="amt">Cash</th><th class="amt">Trans&shy;fer</th></tr></thead><tbody>
        ${rows.map((x) => `<tr><td>${who(x.b)}</td>${c(x.card)}${c(-x.fee)}${c(x.credit)}${c(x.cash)}${c(x.transfer)}</tr>`).join("") || '<tr><td colspan="6" class="muted">No one to pay yet.</td></tr>'}
        <tr><td><b>Total</b></td>${["card", "fee", "credit", "cash", "transfer"].map((k) => `<b>${c(k === "fee" ? -T[k] : T[k]).replace(/<\/?td[^>]*>/g, "")}</b>`).map((v) => `<td class="amt">${v}</td>`).join("")}</tr>
      </tbody></table></div>
      <p class="muted">Figures in brackets are taken off. Card fees are what Square kept. If someone paid but didn't come (No show), whether they removed themselves, were removed, or just weren't ticked as here, what they paid goes on their account as credit and shows in the Credit column in brackets. Credit used to pay for a game shows without brackets.</p>
      ${writeDown}`;
  }
  // Football Supervisors: only the night's jobs (scan in, head count, who's not in, add someone with a QR to pay).
  // Football Accounts: payments, accounts and settings, for the admin only.
  function supervisors(el, alive) { return footballScreen(el, alive, "night"); }
  function footballadmin(el, alive) { return footballScreen(el, alive, "admin"); }
  async function footballScreen(el, alive, mode) {
    if (!me) return needSignIn(el, "run the football");
    if (mode === "night" ? !isDoor() && !supFootball() : !isAdmin()) { el.innerHTML = `<div class="empty"><h2>${mode === "night" ? "For organisers" : "For the admin"}</h2></div>`; return; }
    loading(el);
    await sb.rpc("expire_unpaid");
    const now = new Date();
    const [allGames, fs] = await Promise.all([
      q(sb.from("events").select("*").eq("kind", "football").not("day", "is", null).order("day")),
      q(sb.from("fund_state").select("*").single()),
    ]);
    const games = allGames.filter((g) => g.day);
    const ev = games.find((g) => eventEnd(g) > now) || [...games].reverse().find((g) => !g.accounts_posted) || null;
    const awaiting = games.filter((g) => !g.accounts_posted && eventEnd(g) <= now);
    const bookings = ev ? await q(sb.from("bookings").select("*").eq("event_id", ev.id).neq("status", "cancelled").order("created_at")) : [];
    if (!alive()) return;
    el.innerHTML = '<div class="events"><div id="org"></div></div>';
    await organiserFootball($("#org", el), ev, bookings, fs, awaiting, games, mode);
  }
  async function organiserFootball(box, current, currentBookings, fs, awaiting, games, mode) {
    const night = mode === "night";
    const target = awaiting[0] || current;
    const bookings = target && target !== current ? await q(sb.from("bookings").select("*").eq("event_id", target.id).neq("status", "cancelled").order("created_at")) : currentBookings;
    const people = current && !current.accounts_posted ? await q(sb.from("profiles").select("id,name,credit").order("name")) : [];
    const onList = new Set(currentBookings.map((b) => b.user_id).filter(Boolean));
    const full = isAdmin(); // organisers get door duty only
    const debts = full ? await q(sb.from("debts").select("*, profiles(name)").eq("cleared", false).order("on_date")) : [];
    // How many are in the current kitty, for "9 out of 11 kitty players attended".
    const kittyMembers = full && !night ? (await sb.from("profiles").select("id", { count: "exact", head: true }).eq("kitty_session", fs.session_no)).count : null;
    // cancelled before Friday 6pm: their money is in this game's takings but now belongs to the credits fund
    const cancelled = target ? (await q(sb.from("bookings").select("*").eq("event_id", target.id).eq("status", "cancelled")))
      .filter((b) => b.status === "cancelled" && b.charge === "payg" && b.paid && ["card", "transfer", "cash"].includes(b.method)) : [];
    // credits check: every credit change since the last accounts, and the credit on members' accounts now
    const [creditMoves, creditRows] = full && target && !target.accounts_posted ? await Promise.all([
      fs.posted_at ? q(sb.from("ledger").select("*").eq("fund", "credits").gt("created_at", fs.posted_at).order("id")) : [],
      q(sb.from("profiles").select("credit"))]) : [[], []];
    // credit that went into places that count: people who played, and kitty joiners
    const fromCredit = target ? bookings.filter((b) => (b.charge === "kitty" || (b.charge === "payg" && b.checked_in))).reduce((t, b) => t + creditPart(b), 0) : 0;
    const nextFri = (() => { const last = games.length ? parseDay(games[games.length - 1].day) : today(); const d = new Date(Math.max(last, today())); d.setDate(d.getDate() + ((5 - d.getDay() + 7) % 7 || (games.length ? 7 : 0))); return d; })();
    const charged = bookings.filter((b) => b.charge !== "covered");
    const METHODS = { card: "Card", transfer: "Transfer", cash: "Cash", owes: "Owes" };
    const adminBits = `${full ? `<h3>Next game</h3><button class="btn small" id="addGame">Add game for ${short(nextFri)}</button>` : ""}
      ${isAdmin() && "intro_offer" in fs ? `<h3>New member offer · ${fs.intro_offer ? "On" : "Off"}</h3>
      <p class="muted">${fs.intro_offer ? `Any member who joined since ${short(new Date(fs.intro_since))} and hasn't played yet pays £1 for their first game, and the events fund pays the rest when the accounts are posted.` : "Switch it on and anyone who joins from then on pays £1 for their first game, with the rest paid by the events fund."}</p>
      <button class="btn small" id="introSwitch">${fs.intro_offer ? "End the offer" : "Start the offer"}</button>` : ""}`;
    const pitchDefault = bookings.length >= 28 ? "134.00" : "67.00";
    const hereN = currentBookings.filter((b) => b.checked_in).length, missN = currentBookings.length - hereN;
    box.innerHTML = night ? `<div class="card fb"><h2>Football Supervisors</h2>
      ${current ? `<p class="muted">${esc(current.title)} · ${fmtEvent(current)}</p>
      <div class="stats"><div><span>Here</span><b>${hereN}</b></div><div><span>Not in yet</span><b>${missN}</b></div><div><span>Booked</span><b>${currentBookings.length}</b></div></div>` : '<p class="muted">No game scheduled.</p>'}
      ${current && !current.accounts_posted ? `<button class="btn solid block" id="fbScan">Scan tickets to check people in</button><div id="fbIn"></div>` : ""}
      ${current ? `<h3>Who's booked · ${short(parseDay(current.day))}</h3>
      <p class="muted">Scan their ticket, or tap a name when they arrive.</p>
      ${[["Not in yet", currentBookings.filter((b) => !b.checked_in)], ["Here", currentBookings.filter((b) => b.checked_in)]].map(([head, list]) => currentBookings.length ? `<h4>${head} (${list.length})</h4>
      <div class="attend">${list.map((b) => `<label class="check"><input type="checkbox" data-here="${b.id}" ${b.checked_in ? "checked" : ""} ${current.accounts_posted ? "disabled" : ""}> ${esc(b.display_name)}${b.paid ? "" : ' <span class="tag warn">Unpaid</span>'}${b.topup_method === "link" ? ' <span class="tag warn">Top-up unpaid</span>' : ""}${b.risk_ok ? ' <span class="tag">Own risk ✓</span>' : ""}${current.accounts_posted || !full ? "" : ` <button class="btn small" data-drop="${b.id}" style="margin-left:auto">Remove</button>`}</label>`).join("") || '<p class="muted">No one.</p>'}</div>` : "").join("") || '<p class="muted">No one has booked yet.</p>'}
      <p class="muted">Anyone paid for pay and play who isn't ticked when the accounts are posted keeps what they paid as credit on their account for their next booking.</p>
      ${current.accounts_posted ? "" : `<h3>Add someone who wasn't on the list, or top up to the kitty</h3>
      <div class="grid2">
        <div><label>Paying</label><select id="wiType"><option value="payg">Pay and play ${money(Math.max(Number(current.price), 6))}</option><option value="topup">Top up to the kitty £9 (already on the list)</option><option value="kitty">Join the kitty £15</option></select></div>
        <div><label>Member</label><select id="wiUser"></select></div>
        <div><label>Name</label><input id="wiName" placeholder="Their name"></div>
        <div><label id="wiPrice">Pays ${money(Math.max(Number(current.price), 6))} by</label><select id="wiMeth"><option value="link">Card: show a QR to pay on their phone</option><option value="cash">Cash</option></select></div>
      </div>
      <p class="muted">Payment is needed on the night: a QR to pay by card on their own phone, or cash. With the QR, they show as paid here once Square confirms it. A kitty top-up can be paid the same way.</p>
      <label class="check"><input type="checkbox" id="wiRisk"> They've confirmed they play at their own risk</label>
      <div class="form-actions"><button class="btn solid block" id="wiAdd">Add and mark as here</button></div>`}` : ""}
    </div>` : `<div class="card fb"><h2>Football Accounts</h2>
      ${target ? "" : '<p class="muted">No game to show yet.</p>'}
      ${target ? paymentsBreakdown(target, bookings, cancelled, full, METHODS, pitchDefault, fs, kittyMembers) : ""}
      ${full && target ? `      ${!target.accounts_posted && eventStart(target) <= new Date() ? `
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
          <div><label>Goals pitch hire (£)</label><input id="hire" type="number" step="0.01" value="${pitchDefault}"></div>
          <div><label>Card fees (£)</label><input id="fees" type="number" step="0.01" value="${[...bookings, ...cancelled].reduce((t, b) => t + Number(b.card_fee || 0) + Number(b.topup_fee || 0), 0).toFixed(2)}"></div>
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
      ${adminBits}
    </div>`;

    // Write-down: the pitch hire typed in below updates the costs, the result and the kitty after.
    const hireIn = $("#hire", box), kit = $("#pbKit", box);
    if (hireIn && $("#pbRes", box)) hireIn.addEventListener("input", () => {
      const r2 = (n) => Math.round(n * 100) / 100, h = Number(hireIn.value) || 0;
      const got = Number(kit?.dataset.got ?? 0), fee = Number(kit?.dataset.fee ?? 0), res = r2(got - h - fee);
      if (!kit) return;
      $("#pbRent", box).textContent = money(h); $("#pbCosts", box).textContent = `(${money(h + fee)})`;
      $("#pbRes", box).textContent = res < 0 ? `(${money(-res)})` : money(res);
      kit.textContent = money(r2(Number(kit.dataset.before) + res));
    });
    // BR3 Family Events for the game's week (Saturday to Friday): before, subscriptions received, after.
    const famBox = $("#pbFam", box);
    if (famBox) (async () => {
      try {
        const d = parseDay(famBox.dataset.day), from = new Date(d), to = new Date(d);
        from.setDate(from.getDate() - 6); to.setDate(to.getDate() + 1);
        const [subs, famRows, fsNow] = await Promise.all([
          q(sb.from("square_payments").select("gross,fee,refunded").eq("kind", "subscription").eq("status", "COMPLETED").gte("paid_at", from.toISOString()).lt("paid_at", to.toISOString())),
          q(sb.from("ledger").select("amount").eq("fund", "family").gte("on_date", isoDay(from))),
          q(sb.from("fund_state").select("family").single()),
        ]);
        const r2 = (n) => Math.round(n * 100) / 100;
        const after = r2(Number(fsNow.family || 0)), before = r2(after - famRows.reduce((t, l) => t + Number(l.amount), 0));
        const net = r2(subs.reduce((t, x) => t + Number(x.gross) - Number(x.fee) - Number(x.refunded || 0), 0)), other = r2(after - before - net);
        const row = (a, b) => `<tr><td>${a}</td><td class="amt">${b}</td></tr>`;
        famBox.innerHTML = `${row("Before", money(before))}
          ${row("Subscriptions received", money(net))}
          ${other ? row(`Other money ${other > 0 ? "in" : "spent"}`, other > 0 ? money(other) : `(${money(-other)})`) : ""}
          ${row("After", `<b>${money(after)}</b>`)}`;
      } catch { famBox.innerHTML = '<tr><td colspan="2" class="muted">Couldn\'t load this week\'s subscriptions.</td></tr>'; }
    })();
    if ($("#fbScan", box)) {
      $("#fbScan", box).onclick = () => scanTicket(checkIn);
      whosIn($("#fbIn", box), current.id, (t) => { const c = box.querySelector(`[data-here="${t.id}"]`); if (c && t.status === "booked") refresh(); });
    }
    const isw = $("#introSwitch", box);
    if (isw) isw.onclick = async () => {
      if (fs.intro_offer && isw.dataset.sure !== "1") { isw.dataset.sure = "1"; isw.textContent = "Tap again to end the offer"; return; }
      try { isw.disabled = true; await q(sb.rpc("set_intro_offer", { p_on: !fs.intro_offer })); toast(fs.intro_offer ? "New member offer ended" : "New member offer started"); refresh(); }
      catch (e) { isw.disabled = false; fail(e); }
    };
    if ($("#addGame", box)) $("#addGame", box).onclick = async () => {
      try {
        await q(sb.from("events").insert({ kind: "football", title: "Friday Weekly Footie", day: dayKey(nextFri), time: "21:15", location: "Goals Beckenham, Elmers End",
          details: "Weekly 5-a-side every Friday night. All abilities welcome. £6 pay as you play, or £15 for the kitty.", price: 6, capacity: 36, access: "members" }));
        toast("Game added"); refresh();
      } catch (e) { fail(e); }
    };
    const wu = $("#wiUser", box), wt = $("#wiType", box);
    if (wu) {
      // A top-up is for a member already on the list for pay and play: they pay the rest of the £15 and become a kitty place.
      const payg = new Map(currentBookings.filter((b) => b.user_id && b.charge === "payg").map((b) => [b.user_id, b]));
      const left = (b) => (b.paid && !["owes", "credit"].includes(b.method) ? 15 - Number(b.amount) : 15 - Number(b.paid && b.method === "credit" ? b.amount : b.credit_used || 0));
      const fill = () => {
        const t = wt.value, list = t === "topup" ? people.filter((p) => payg.has(p.id)) : people.filter((p) => !onList.has(p.id));
        wu.innerHTML = (t === "payg" ? '<option value="">Not a member (type name)</option>' : '<option value="">Choose a member</option>')
          + list.map((p) => `<option value="${p.id}" data-credit="${Number(p.credit) || 0}">${esc(p.name)}${t === "topup" ? ` (paid ${money(payg.get(p.id).amount)})` : Number(p.credit) > 0 ? ` (${money(p.credit)} credit)` : ""}</option>`).join("");
      };
      const sync = () => { const t = wt.value;
        const price = t === "kitty" ? 15 : Number(current.price);
        // Offer prices are for members; anyone else pays the full £6.
        $("#wiPrice", box).textContent = t === "topup" ? `Tops up ${wu.value ? money(left(payg.get(wu.value))) : "the rest"} by`
          : `Pays ${money(t === "kitty" ? 15 : wu.value ? price : Math.max(price, 6))}${t === "payg" && wu.value && fs.intro_offer ? " (£1 if it's a new member's first game)" : ""} by`;
        $("#wiName", box).disabled = t !== "payg" || !!wu.value;
      };
      wt.onchange = () => { fill(); sync(); }; wu.onchange = sync; fill(); sync();
      $("#wiAdd", box).onclick = async () => {
        if (wt.value !== "payg" && !wu.value) return toast("Choose the member");
        if (wt.value === "payg" && !wu.value && !$("#wiName", box).value.trim()) return toast("Type their name");
        if (!$("#wiRisk", box).checked) return toast("Tick that they've confirmed they play at their own risk");
        try {
          $("#wiAdd", box).disabled = true;
          const b = (await q(sb.rpc("add_walkin", { p_event: current.id, p_user: wu.value || null, p_name: wt.value === "payg" ? $("#wiName", box).value.trim() || null : null, p_method: $("#wiMeth", box).value, p_choice: wt.value })));
          const row = Array.isArray(b) ? b[0] : b;
          if (row && row.id) await q(sb.rpc("set_risk", { p_id: row.id }));
          toast(row && row.charge === "covered" ? `${row.display_name} added (in the kitty, no charge)` : wt.value === "topup" ? (row.topup_method === "link" ? `${row.display_name} is in the kitty. Show them the QR to pay` : `${row.display_name} topped up and in the kitty ✓`) : "Added and marked as here"); await refresh();
          if (row && (row.pitch_link && !row.paid || row.topup_method === "link")) guestLinkModal(current, row);
        } catch (e) { $("#wiAdd", box).disabled = false; fail(e); }
      };
    }
    box.querySelectorAll("[data-drop]").forEach((d) => (d.onclick = async (e) => {
      e.preventDefault();
      if (d.dataset.sure !== "1") { d.dataset.sure = "1"; d.textContent = "Tap again to remove"; return; }
      try { d.disabled = true; await q(sb.rpc("cancel_booking", { p_id: d.dataset.drop })); toast("Removed from the list"); refresh(); } catch (err) { d.disabled = false; fail(err); }
    }));
    box.querySelectorAll("[data-here]").forEach((c) => (c.onchange = async () => {
      try { await q(sb.rpc("set_here", { p_id: c.dataset.here, p_on: c.checked })); toast(c.checked ? "Marked as here" : "Unmarked"); refresh(); } catch (e) { c.checked = !c.checked; fail(e); }
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
    dr.onclick = async () => {
      // Money moved between funds since the last accounts: the funds before it, then the moves.
      const moved = (await transfersOf()).filter((x) => !x.accounts_post_id).reverse(), mv = pendingNet(moved);
      const cleared = [...box.querySelectorAll("[data-clear]:checked")].map((c) => debts.find((d) => d.id === c.dataset.clear));
      const all = bookings, here = all.filter((b) => b.checked_in);
      if (!here.length) return toast(`Tick who turned up under "Who's turned up" first`);
      const turnout = Number($("#turnout", box).value) || here.length;
      const kittyHere = here.filter((b) => b.charge === "covered" || b.charge === "kitty");
      const kp = all.filter((b) => b.charge === "kitty");
      const payers = Math.max(turnout - kittyHere.length, 0);
      const pg = here.filter((b) => b.charge === "payg");
      const counts = (b) => b.charge === "kitty" || b.checked_in;
      const viaCredit = all.filter((b) => b.charge !== "covered" && counts(b) && creditPart(b) > 0);
      const owing = all.filter((b) => b.charge !== "covered" && counts(b) && methodOf(b) === "owes");
      const noShows = all.filter((b) => b.charge === "payg" && !b.checked_in && b.paid && (b.user_id || b.booked_by));
      const noShowCash = noShows.filter((b) => ["card", "transfer", "cash"].includes(b.method));
      // Didn't play and never paid the rest: the credit they put in goes back to them.
      const creditBack = all.filter((b) => b.charge === "payg" && !b.checked_in && !b.paid && Number(b.credit_used) > 0 && (b.user_id || b.booked_by));
      const sum = (xs) => xs.reduce((t, b) => t + Number(b.amount), 0);
      const sumCash = (xs) => xs.reduce((t, b) => t + cashPart(b), 0), sumCredit = (xs) => xs.reduce((t, b) => t + creditPart(b), 0);
      const toCredits = sumCash(noShowCash) + sumCash(cancelled);
      const clearedAmt = cleared.reduce((t, d) => t + Number(d.amount), 0);
      const rSq = Number($("#rSquare", box).value) || 0, rTr = Number($("#rTransfer", box).value) || 0, rCa = Number($("#rCash", box).value) || 0;
      const received = rSq + rTr + rCa, rCr = sumCredit(viaCredit), receivedAll = received + rCr;
      const hire = Number($("#hire", box).value) || 0, fees = Number($("#fees", box).value) || 0;
      // What should have come in (credit included): kitty joiners, the price from everyone else who played,
      // owed money cleared, and money from people who paid but didn't play or cancelled for credit; less deferred.
      const TP = Number(target.price);
      const friendsHere = pg.filter((b) => b.booked_by), fAmt = sum(friendsHere);
      // New members' £1 first games: the events fund pays the rest into the kitty.
      const introHere = pg.filter((b) => Number(b.intro_cover) > 0), introAmt = sum(introHere), introCover = introHere.reduce((t, b) => t + Number(b.intro_cover), 0);
      const expGross = kp.length * 15 + Math.max(payers - friendsHere.length - introHere.length, 0) * TP + fAmt + introAmt;
      const expIn = expGross + clearedAmt + toCredits - sumCash(owing);
      const diff = Math.round((receivedAll - expIn) * 100) / 100;
      // Same split as post_accounts: cleared debts go to events, unused money to credits, the rest to the kitty.
      const income = received + rCr - toCredits - clearedAmt;
      const net = income - hire - fees, newKitty = Number(fs.kitty) + net + introCover, newEv = Number(fs.events) + clearedAmt - introCover;
      // Credits: held at the last accounts + added - used (+ no-shows credited now) must equal members' accounts.
      const oldCr = Number(fs.credits_posted ?? fs.credits ?? 0);
      const crIn = creditMoves.filter((m) => Number(m.amount) > 0), crOut = creditMoves.filter((m) => Number(m.amount) < 0);
      const crAdded = crIn.reduce((t, m) => t + Number(m.amount), 0), crUsed = -crOut.reduce((t, m) => t + Number(m.amount), 0);
      const crNow = sum(noShows) + creditBack.reduce((t, b) => t + Number(b.credit_used), 0);
      const newCr = Math.round((oldCr + crAdded - crUsed + crNow) * 100) / 100;
      const onAccounts = Math.round((creditRows.reduce((t, r) => t + Number(r.credit || 0), 0) + crNow) * 100) / 100;
      const g = fs.games_played + 1, ORD = ["1st", "2nd", "3rd", "4th", "5th"], L = "________", d = parseDay(target.day);
      // Mohamed's WhatsApp layout: prior funds, who came, expected, paid as, costs, updated funds.
      const r2 = (n) => Math.round(n * 100) / 100;
      const ordDay = (n) => n + (n % 10 === 1 && n !== 11 ? "st" : n % 10 === 2 && n !== 12 ? "nd" : n % 10 === 3 && n !== 13 ? "rd" : "th");
      const names = (xs, f = (b) => b.display_name) => xs.map(f).join(", ");
      const paygFull = r2(Math.max(payers - friendsHere.length - introHere.length, 0) * TP + fAmt + introAmt + introCover);
      const sameFriends = !friendsHere.length || fAmt === friendsHere.length * TP;
      const owingAmt = r2(sumCash(owing));
      const expFootball = r2(expGross + clearedAmt - owingAmt);
      const crHeld = r2(toCredits - rCr); // put into credit less credit used, from this game
      // BR3 Family Events: the week's subscriptions (Saturday to the game's Friday), with the fund before and after.
      // Loaded first, so the family fund can sit in the prior and updated funds too.
      let fam = null;
      const wkStart = new Date(d); wkStart.setDate(wkStart.getDate() - 6);
      try {
        const wkEnd = new Date(d); wkEnd.setDate(wkEnd.getDate() + 1);
        const [subs, famRows, fsNow] = await Promise.all([
          q(sb.from("square_payments").select("gross,fee,refunded,label,status").eq("kind", "subscription").eq("status", "COMPLETED").gte("paid_at", wkStart.toISOString()).lt("paid_at", wkEnd.toISOString())),
          q(sb.from("ledger").select("amount").eq("fund", "family").gte("on_date", isoDay(wkStart))),
          q(sb.from("fund_state").select("family").single()),
        ]);
        const famNow = r2(fsNow.family || 0), famPrior = r2(famNow - famRows.reduce((s2, l) => s2 + Number(l.amount), 0));
        // Individual, Concessionary and Family are always listed, even with none that week.
        const plan = (l) => { const n = String(l || "").toLowerCase(); return n.includes("famil") ? "Family" : n.includes("conces") ? "Concessionary" : "Individual"; };
        const byPlan = new Map(["Individual", "Concessionary", "Family"].map((k) => [k, { n: 0, gross: 0, fee: 0, net: 0 }]));
        subs.forEach((p) => { const k = plan(p.label), x = byPlan.get(k) || { n: 0, gross: 0, fee: 0, net: 0 };
          x.n++; x.gross += Number(p.gross); x.fee += Number(p.fee); x.net += Number(p.gross) - Number(p.fee) - Number(p.refunded || 0); byPlan.set(k, x); });
        const tot = [...byPlan.values()].reduce((s2, x) => ({ n: s2.n + x.n, gross: s2.gross + x.gross, fee: s2.fee + x.fee, net: s2.net + x.net }), { n: 0, gross: 0, fee: 0, net: 0 });
        fam = { famNow, famPrior, byPlan, tot, other: r2(famNow - famPrior - tot.net) };
      } catch { fam = null; }
      // Where the money sits: Square + Starling, last week (from the last reconciliation) and now.
      const prevRec = await q(sb.from("reconciliations").select("square_actual,starling").order("id", { ascending: false }).limit(1)).then((r) => r[0] || null).catch(() => null);
      const famP = fam ? fam.famPrior : null, famA = fam ? fam.famNow : null;
      const allPrior = r2(Number(fs.kitty) + Number(fs.events) + oldCr + (famP || 0));
      const allAfter = r2(newKitty + newEv + newCr + (famA || 0));
      const where = (sq, st) => (sq == null ? "" : st == null ? `(Square ${money(sq)})` : `(Square + Starling = ${money(sq)} + ${money(st)})`);
      const t = [`Turnout ${turnout} - ${ordDay(d.getDate())} ${MONTHS_LONG[d.getMonth()]} - ${g >= 5 ? `${ORD[g - 1] || g + "th"} and last game of this kitty session` : `${ORD[g - 1] || g + "th"} kitty game of up to 5 consecutive games`}`];
      if ($("#fmt", box).value.trim()) t.push("", $("#fmt", box).value.trim());
      // Expected and actual for this game first (the reconciliation), then the funds.
      // Expected stays at the full price for everyone who played; the events fund's share of the
      // new member deal is shown as money received instead.
      const expAll = r2(expFootball + introCover);
      const gotAll = r2(received - crHeld + introCover);
      t.push("", "Kitty restarts when either fund drops below £150 or we have had a maximum of 5 consecutive games",
        L, "EXPECTED AND ACTUAL FOR THIS GAME", `Turnout ${turnout}`, `Kitty players who came ${kittyHere.length}${kittyMembers != null ? ` out of ${kittyMembers}` : ""}`,
        `Joined the kitty: ${kp.length} × £15 = ${money(kp.length * 15)}`,
        `Paid and played: ${payers}${sameFriends ? ` × ${money(TP)}` : ""} = ${money(paygFull)}${sameFriends ? "" : ` (includes ${friendsHere.length} friend${friendsHere.length === 1 ? "" : "s"} ${money(fAmt)})`}`);
      if (cleared.length) t.push(`Owed money cleared ${money(clearedAmt)}: ${names(cleared, (x) => x.profiles?.name || "Member")}`);
      if (owing.length) t.push(`Less not paid yet (${money(owingAmt)}): ${names(owing)}`);
      t.push(`Total expected ${money(expAll)}`, "", "Received", `Card via Square ${money(rSq)}`);
      if (crHeld) t.push(crHeld < 0 ? `Credits (used ${money(rCr)} - kept as credit ${money(toCredits)}) ${money(-crHeld)}` : `Credits (used ${money(rCr)} - kept as credit ${money(toCredits)}) (${money(crHeld)})`);
      t.push(`Cash ${money(rCa)}`, `Transfers ${money(rTr)}`);
      if (introCover) t.push(`From the events fund (new member offer: ${names(introHere)}) ${money(introCover)}`);
      t.push(`Total received ${money(gotAll)}`, diff === 0 ? "Balanced ✓" : `Not balanced: ${money(Math.abs(diff))} ${diff > 0 ? "more" : "less"} than expected`);
      t.push(L, "Prior funds", `Kitty fund ${money(fs.kitty)}`, `Events fund ${money(fs.events)}`, `Credits held ${money(oldCr)}`);
      if (famP != null) t.push(`Family Events ${money(famP)}`);
      t.push("", `TOTAL ALL FUNDS ${money(allPrior)}`);
      if (prevRec) t.push(where(prevRec.square_actual, prevRec.starling));
      if (moved.length) t.push(...moved.map((x) => `(includes ${transferLine(x)})`));
      t.push(L, `These ${kittyHere.length}${kittyMembers != null ? ` out of ${kittyMembers}` : ""} kitty contributors came`, ...kittyHere.map((b) => b.display_name));
      if (kp.length) t.push("", `${kp.length} joined the kitty this game: ${kp.length} × £15 = ${money(kp.length * 15)}`,
        ...kp.map((b) => b.display_name + (Number(b.topup) > 0 ? ` (topped up ${money(b.topup)} from pay and play)` : "")));
      const res = r2(gotAll - clearedAmt - hire - fees);
      t.push(L, "Costs", `Rental ${money(hire)}`, `Card ${money(fees)}`, "");
      if (clearedAmt) t.push(`${money(clearedAmt)} owed money cleared goes to the events fund`);
      t.push(res < 0 ? `Costs over receipts -(${money(-res)})` : `Receipts over costs ${money(res)}`);
      t.push("—————————", "Updated funds", `Kitty fund ${money(newKitty)}`, `Events fund ${money(newEv)}`, `Credits held ${money(newCr)}`);
      if (famA != null) t.push(`Family Events ${money(famA)}`);
      t.push("", `TOTAL ALL FUNDS ${money(allAfter)}`);
      if (fs.square_balance != null) t.push(where(Number(fs.square_balance), fs.starling_balance_at ? Number(fs.starling_balance) : null).replace("=", "are"));
      if (newCr !== onAccounts) t.push(`Check before posting: members' accounts hold ${money(onAccounts)} in credit, ${money(Math.abs(newCr - onAccounts))} ${onAccounts > newCr ? "more" : "less"} than this.`);
      const owes = [...debts.filter((x) => !cleared.includes(x)).map((x) => `${x.profiles?.name || "Member"} ${money(x.amount)} ${esc(x.reason)}`),
        ...owing.filter((b) => cashPart(b) > 0).map((b) => `${b.display_name} ${money(cashPart(b))} ${short(d)}`)];
      t.push(L, "These OWE", ...(owes.length ? owes : ["All clear"]));
      if (newKitty < 150 || g >= 5) t.push(L, `Kitty restarts: ${newKitty < 150 ? "fund is below £150" : "5 games played"}. Anything over £100 moves to the events fund and the next game starts a new kitty.`);
      if (fam) {
        const dd = (x) => `${DAYS[x.getDay()]} ${x.getDate()} ${MONTHS[x.getMonth()]}`;
        t.push(L, "BR3 FAMILY EVENTS", `Prior fund ${money(fam.famPrior)}`, "", `Weekly subscriptions for BR3 Family Events (${dd(wkStart)} - ${dd(d)})`,
          "Type - no. - £/sub - received - less card costs - net received");
        [...fam.byPlan.entries()].forEach(([k, x]) =>
          t.push(`${k} - ${x.n} - ${x.n ? money(x.gross / x.n) : "-"} - ${money(x.gross)} - (${money(x.fee)}) - ${money(x.net)}`));
        t.push(`Total - ${fam.tot.n} - - ${money(fam.tot.gross)} - (${money(fam.tot.fee)}) - ${money(fam.tot.net)}`);
        if (fam.other) t.push(`Other money ${fam.other > 0 ? "in" : "spent"} ${fam.other > 0 ? money(fam.other) : `(${money(-fam.other)})`} (see the BR3 Family Events Accounts chat)`);
        t.push("", `Updated fund ${money(fam.famNow)}`);
      } else t.push(L, "BR3 FAMILY EVENTS", "Couldn't load this week's subscriptions. Add them by hand.");
      t.push(L, "For all the funds together, checked against the Square account, see the Accounts Reconciliation chat.");
      $("#acc", box).value = t.join("\n"); $("#draftBox", box).hidden = false;
      $("#post", box).onclick = async () => {
        const methods = {}; all.forEach((b) => { if (b.charge !== "covered" && b.method !== "credit") methods[b.id] = methodOf(b); });
        try {
          $("#post", box).disabled = true;
          await q(sb.rpc("post_accounts", { p_event: target.id, p_body: $("#acc", box).value, p_hire: hire, p_fees: fees, p_methods: methods,
            p_cleared: cleared.map((x) => x.id), p_received: received, p_images: [photos[0], photos[1]].filter(Boolean) }));
          toast("Accounts posted to the Friday Football Accounts chat"); refresh();
        } catch (e) { $("#post", box).disabled = false; fail(e); }
      };
      $("#copy", box).onclick = async () => { try { await navigator.clipboard.writeText($("#acc", box).value); toast("Copied. Paste it into WhatsApp"); } catch { $("#acc", box).select(); toast("Select all and copy"); } };
    };
  }

  // ---------- GROUPS ----------
  let groupCache = [];
  // Reactions everyone can see (null until add-welcome-and-members.sql is run: then they stay on this phone),
  // and the chats' most active members: last month's winner wears the 🏅 badge for the whole of this month.
  let reactCache = null, chatStars = [], commentCache = [];
  const REACTS = ["❤️", "😂", "👏", "🙏", "🔥", "🎉", "😮", "😢"];
  const lastMonthName = () => { const d = new Date(); d.setDate(1); d.setMonth(d.getMonth() - 1); return MONTHS_LONG[d.getMonth()]; };
  const badge = (uid) => { const top = chatStars.find((x) => x.period === "last"); return top && uid && top.user_id === uid ? ` <span class="star-badge" title="Most active in the chats in ${lastMonthName()}">🏅</span>` : ""; };
  function starsBox() {
    const last = chatStars.filter((x) => x.period === "last"), now = chatStars.filter((x) => x.period === "this");
    if (!last.length && !now.length) return "";
    const MEDAL = ["🥇", "🥈", "🥉"];
    return `<section class="news stars"><h2>🏅 Most active in the chats</h2>
      ${last.length ? `<p><b>${lastMonthName()}'s winner: ${esc(last[0].name)}</b>, who wears the 🏅 badge this month.${last.length > 1 ? ` Well done too, ${last.slice(1).map((x) => esc(x.name)).join(" and ")}.` : ""}</p>` : ""}
      ${now.length ? `<p class="muted" style="margin-bottom:4px">${MONTHS_LONG[new Date().getMonth()]} so far</p>${now.map((x, i) => `<div>${MEDAL[i]} ${esc(x.name)} <span class="muted">· ${x.score} point${x.score === 1 ? "" : "s"}</span></div>`).join("")}` : ""}
      <p class="muted" style="font-size:14px;margin-top:8px">Posts score 3, comments 2 and reactions 1. The top member at the end of the month gets the 🏅 badge next to their name all next month.</p></section>`;
  }
  // A shower of confetti each time someone posts or comments.
  function confetti() {
    if (matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const box = document.createElement("div"); box.className = "confetti"; box.setAttribute("aria-hidden", "true");
    const COLS = ["#f2c14e", "#2e8b57", "#e4572e", "#4ea5d9", "#ffffff", "#c45ab3"];
    for (let i = 0; i < 90; i++) {
      const b = document.createElement("i");
      b.style.left = Math.random() * 100 + "%"; b.style.background = COLS[i % COLS.length];
      b.style.animationDelay = Math.random() * 0.6 + "s"; b.style.animationDuration = 1.8 + Math.random() * 1.4 + "s";
      b.style.setProperty("--x", (Math.random() * 160 - 80) + "px"); b.style.transform = `rotate(${Math.random() * 360}deg)`;
      box.appendChild(b);
    }
    document.body.appendChild(box); setTimeout(() => box.remove(), 3600);
  }
  function cheer() {
    confetti();
    const day = dayKey(new Date()), first = state.cheerDay !== day;
    state.cheerDay = day; save();
    toast(first ? "Thanks for joining in today! 🎉" : "Posted 🎉");
  }
  const groupName = (id) => (groupCache.find((g) => g.id === id) || {}).name || "Group";

  const ANNOUNCE = "announcements";
  // The Accounts tab: the reconciliation (all funds against Square, pinned) first, then each fund's own accounts chat.
  const ACCOUNTS = ["accounts-reconciliation", "football-accounts", "events-accounts", "family-accounts"];
  const ACCOUNT_ICON = { "accounts-reconciliation": "⚖️", "football-accounts": "⚽", "events-accounts": "🏆", "family-accounts": "👨‍👩‍👧" };
  const ORG_POSTS = ACCOUNTS; // chats only the admin posts in
  const AUTO_GROUPS = ACCOUNTS; // every approved member is in it, no sign-up
  // The accounts chats always show the newest post first; pinning doesn't apply there.
  const byGroup = (posts, id) => { const gp = posts.filter((p) => p.group_id === id);
    return ORG_POSTS.includes(id) ? gp.sort((a, b) => (a.created_at < b.created_at ? 1 : a.created_at > b.created_at ? -1 : 0)) : gp; };
  const inGroup = (id) => joined.includes(id) || isOrg() || (AUTO_GROUPS.includes(id) && !!me && !pending());
  // Football chats (Friday Football, Footballing Events) are hidden from events-only members.
  const seesGroup = (g) => !g.football_only || !eventsOnly() || isDoor();
  const PENDING_NOTE = '<p class="note">You can join in once the admin has approved your membership.</p>';
  // Chats: open, informal chats anyone can join in. Joined: sign-up chats (like the Quran target).
  // Announcements are pinned at the top of both.
  async function chat(el, alive, id) {
    if ((!me || pending()) && await guestChat(el, alive, id)) return;
    return groups(el, alive, "", id);
  }
  // A chat opened by someone who isn't an approved member (e.g. from the Quran event's QR code).
  // They read it, and post or comment under their name marked "(guest)". Returns false if the
  // chat isn't open to guests, so the usual members-only screen shows instead.
  const guestToken = () => {
    if (!state.guestToken) { state.guestToken = (crypto.randomUUID ? crypto.randomUUID() : Array.from(crypto.getRandomValues(new Uint8Array(16)), (b) => b.toString(16).padStart(2, "0")).join("")); save(); }
    return state.guestToken;
  };
  async function guestChat(el, alive, id) {
    loading(el);
    let d;
    try { d = await q(sb.rpc("guest_chat", { p_group: id })); } catch { return false; }
    if (!alive()) return true;
    const name = state.guestName || (me && me.name) || "";
    const nameBox = `<label>Your name</label><input id="gName" autocomplete="name" value="${esc(name)}" placeholder="First and last name">`;
    const gpost = (p) => {
      const cs = d.comments.filter((c) => c.post_id === p.id);
      return `<article class="post">
        <div class="head"><div class="avatar" style="width:46px;height:46px">${esc(initials(p.author_name))}</div>
          <div class="who"><b>${esc(p.author_name)}</b>${p.pinned ? ' <span class="tag gold">Pinned</span>' : ""}<div class="muted">${ago(p.created_at)}</div></div></div>
        ${postBody(p)}
        ${Array.isArray(p.poll) ? p.poll.map((o) => `<div class="poll-opt"><span>${esc(o)}</span></div>`).join("") : ""}
        ${cs.length ? `<div class="comments">${cs.map((c) => `<div class="comment"><b>${esc(c.author_name)}</b> ${escLinks(c.body)}${ytCards(c.body)}</div>`).join("")}</div>` : ""}
        <div class="row" style="gap:8px;margin-top:8px"><input data-gc="${p.id}" placeholder="Write a comment…" style="flex:1;margin:0"><button class="btn small" data-gsend="${p.id}">Send</button></div>
      </article>`;
    };
    el.innerHTML = `<div class="subhead"><h2>${esc(d.group.name)}</h2><a href="#events">Events</a></div>
      ${groupHero(d.group.id)}
      ${d.group.about ? `<p class="muted pad" style="padding-top:10px">${esc(d.group.about)}</p>` : ""}
      <div class="pad"><p class="note">You're joining in as a guest, so your name shows with "(guest)". Everyone in the chat can read what you write. ${me ? "Once the admin approves your membership you'll join in as a member." : `Members, <a href="#account">sign in</a> first.`}</p>
        ${nameBox}
        <label>Share something with the group</label><textarea id="gBody" placeholder="How did you get on with this week's target?"></textarea>
        <div class="form-actions"><button class="btn solid block" id="gPost">Post</button></div></div>
      <div id="feed">${d.posts.map(gpost).join("") || '<div class="empty"><h2>No posts yet</h2></div>'}</div>`;
    const say = async (post, body, btn) => {
      const n = $("#gName", el).value.trim();
      if (n.length < 2) { $("#gName", el).focus(); return toast("Please add your name first"); }
      if (!body.trim()) return toast("Please write something first");
      state.guestName = n; save();
      btn.disabled = true;
      try { await q(sb.rpc("guest_say", { p_group: id, p_post: post, p_name: n, p_token: guestToken(), p_body: body })); toast(post ? "Comment added" : "Posted"); refresh(); }
      catch (e) { btn.disabled = false; fail(e); }
    };
    $("#gPost", el).onclick = (e) => say(null, $("#gBody", el).value, e.currentTarget);
    el.querySelectorAll("[data-gsend]").forEach((b) => (b.onclick = () => say(b.dataset.gsend, el.querySelector(`[data-gc="${b.dataset.gsend}"]`).value, b)));
    el.querySelectorAll("[data-gc]").forEach((i) => (i.onkeydown = (e) => e.key === "Enter" && el.querySelector(`[data-gsend="${i.dataset.gc}"]`).click()));
    return true;
  }
  // Chats with their own look: Friday football's accounts and the Quran Recitation Group.
  const GROUP_LOOK = { quran: "quran-club" };
  const GROUP_PIC = { quran: QURAN_BANNER };
  const groupHero = (id, link) => (GROUP_PIC[id] ? `<${link ? `a href="#chat:${encodeURIComponent(id)}"` : "div"} class="group-hero ${GROUP_LOOK[id]}"><img src="${GROUP_PIC[id]}" alt=""></${link ? "a" : "div"}>` : "");
  function grouplist(el, alive) { return groups(el, alive, "", null, true); }
  function accounts(el, alive) { return groups(el, alive, "", null, false, true); }
  const chatTabs = (on) => [["groups", "Chats"], ["accounts", "Accounts"], ["grouplist", "Joined events"]].filter(([k]) => k !== on).map(([k, t]) => `<a href="#${k}">${t}</a>`).join("");
  // The latest balance photos (or PDFs): 1 = Square, 2 = Starling BR3 Funds Space. Shown on the Funds page
  // and in the Accounts Reconciliation chat.
  const STMT_NAME = { 1: "Square", 2: "Starling" };
  async function showStatement(box, id, alive, withDate = true) {
    try {
      const row = (await sb.from("square_statement").select("file,uploaded_at").eq("id", id).maybeSingle()).data;
      if (!box || !alive()) return;
      if (!row) { box.innerHTML = `<p class="muted">No ${STMT_NAME[id]} balance photo uploaded yet.</p>`; return; }
      const when = withDate ? `<span class="muted">${STMT_NAME[id]}, uploaded ${short(new Date(row.uploaded_at))}.</span>` : "";
      if (/^data:image\//.test(row.file)) box.innerHTML = `${when}<img src="${esc(row.file)}" alt="${STMT_NAME[id]} balance" data-zoom style="display:block;max-width:100%;max-height:260px;border-radius:8px;margin-top:8px;cursor:zoom-in"><div class="muted" style="font-size:13px">Tap the photo to see it full size.</div>`;
      else { box.innerHTML = `${when}<a class="btn block" target="_blank" rel="noopener" style="margin-top:8px">Open the ${STMT_NAME[id]} PDF</a>`; box.querySelector("a").href = URL.createObjectURL(await (await fetch(row.file)).blob()); }
    } catch { if (box) box.textContent = "Couldn't load it, try again later"; }
  }
  async function squarePhoto(box, alive) {
    box.innerHTML = '<div data-sq="1"></div><div data-sq="2" style="margin-top:10px"></div>';
    await Promise.all([1, 2].map((id) => showStatement(box.querySelector(`[data-sq="${id}"]`), id, alive)));
  }
  async function groups(el, alive, filter = "", only = null, joinedTab = false, accountsTab = false) {
    if (!me) return needSignIn(el, "see the groups");
    loading(el);
    const [gs, posts, comments, votes] = await Promise.all([
      q(sb.from("groups").select("*").order("sort")).then((all) => all.filter(seesGroup)),
      q(sb.from("posts").select("*").order("pinned", { ascending: false }).order("created_at", { ascending: false }).limit(100)),
      q(sb.from("comments").select("*").order("created_at")),
      q(sb.from("poll_votes").select("*")),
      myGroups(),
      q(sb.from("post_reactions").select("post_id,user_id,emoji")).catch(() => null),
      q(sb.rpc("chat_stars")).catch(() => []),
    ]).then(([a, b, c, d, g, r, st]) => { joined = g; reactCache = r; chatStars = st || []; commentCache = c; return [a, b, c, d]; });
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
      const gp = byGroup(posts, g.id);
      el.innerHTML = `<div class="subhead"><h2>${esc(g.name)}</h2>${ACCOUNTS.includes(g.id) ? '<a href="#accounts">Accounts</a>' : g.members_only ? '<a href="#grouplist">Joined events</a>' : '<a href="#groups">Chats</a>'}</div>
        ${groupHero(g.id)}
        ${g.about ? `<p class="muted pad" style="padding-top:10px">${esc(g.about)}</p>` : ""}
        ${g.id === "accounts-reconciliation" && canRead ? `<div class="pad"><div class="note"><b>Square and Starling balances</b><div id="sqShow"><span class="muted">Loading…</span></div></div></div>` : ""}
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
      if ($("#sqShow", el)) squarePhoto($("#sqShow", el), alive).catch(() => {});
      wirePosts(el, posts);
      return;
    }
    const JOINED_ORDER = accountsTab ? ACCOUNTS : ["quran"];
    const firstIn = (g) => { const i = JOINED_ORDER.indexOf(g.id); return i < 0 ? JOINED_ORDER.length : i; };
    const clubs = gs.filter((g) => g.members_only && ACCOUNTS.includes(g.id) === accountsTab).sort((a, b) => firstIn(a) - firstIn(b)).map((g) => {
      const inIt = inGroup(g.id);
      const gp = byGroup(posts, g.id).slice(0, accountsTab ? 1 : 4);
      const icon = ACCOUNT_ICON[g.id] || "📖";
      return `<section class="news club${GROUP_LOOK[g.id] ? ` ${GROUP_LOOK[g.id]}` : ""}">${groupHero(g.id, inIt)}<div class="row" style="justify-content:space-between"><h2>${inIt ? `<a href="#chat:${encodeURIComponent(g.id)}" style="color:inherit">${icon} ${esc(g.name)}</a>` : `${icon} ${esc(g.name)}`}</h2><span class="row" style="gap:8px">${inIt && !joined.includes(g.id) && !AUTO_GROUPS.includes(g.id) && !pending() ? `<button class="btn small" data-join="${esc(g.id)}">Sign up</button>` : ""}${inIt && (!ORG_POSTS.includes(g.id) || isOrg()) ? `<button class="btn small" data-compose="text" data-group="${esc(g.id)}">Post</button>` : ""}</span></div>
        ${inIt ? gp.map((p) => postHtml(p, comments.filter((c) => c.post_id === p.id), votes.filter((v) => v.post_id === p.id))).join("") || '<p class="muted">Nothing posted yet.</p>'
          : `<p class="muted">${esc(g.about)}</p>${pending() ? PENDING_NOTE : `<button class="btn solid" data-join="${esc(g.id)}">Sign up · Free</button>`}`}</section>`;
    }).join("");
    if (accountsTab) {
      el.innerHTML = `<div class="subhead"><h2>Accounts</h2>${chatTabs("accounts")}</div>
        <p class="muted pad" style="padding-top:10px">All our accounts, open to every member. Each fund has its own chat, and the Accounts Reconciliation chat checks all the funds together against the Square account every week. Tap a chat's name to see all its posts.</p>
        ${clubs || '<div class="empty"><h2>No accounts yet</h2></div>'}`;
      wirePosts(el, posts);
      return;
    }
    if (joinedTab) {
      el.innerHTML = `<div class="subhead"><h2>Joined events</h2>${chatTabs("grouplist")}</div>
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
      <div class="subhead"><h2>Chats</h2>${chatTabs("groups")}
        <span style="width:1px;height:28px;background:var(--line)"></span>
        <button id="searchBtn" style="color:var(--green)">${ICON.search}</button></div>
      ${filter ? "" : newsBox + starsBox() + open}
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

  // Photos sit inside the post where it says {photo 1}, {photo 2} and so on; any others go underneath.
  function postBody(p) {
    const imgs = Array.isArray(p.images) ? p.images : [], used = new Set();
    const pic = (src) => `<img src="${esc(src)}" alt="" data-zoom>`;
    const text = bold(p.body).replace(/\{photo (\d+)\}/g, (m, n) => { const src = imgs[n - 1]; if (!src) return ""; used.add(n - 1); return `</div>${pic(src)}<div class="text">`; });
    return `<div class="text">${text}</div>${ytCards(p.body)}${p.image ? pic(p.image) : ""}${imgs.filter((_, i) => !used.has(i)).map(pic).join("")}`;
  }
  function postHtml(p, comments, votes) {
    const shared = Array.isArray(reactCache), mineR = shared ? reactCache.filter((r) => r.post_id === p.id) : [];
    const count = (e) => mineR.filter((r) => r.emoji === e).length, isMine = (e) => mineR.some((r) => r.emoji === e && r.user_id === me.id);
    const liked = shared ? isMine("👍") : !!state.likes[p.id];
    const reacts = shared ? [] : state.reactions[p.id] || [];
    const sharedPills = shared ? REACTS.filter((e) => count(e)).map((e) => `<button class="pill ${isMine(e) ? "on" : ""}" data-toggle="${p.id}" data-e="${e}">${e} ${count(e)}</button>`).join("") : "";
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
        <div class="who"><b>${esc(p.author_name)}</b>${badge(p.user_id)} posted in the group <b>${esc(groupName(p.group_id))}</b>.${p.pinned ? ' <span class="tag gold">Pinned</span>' : ""}<div class="muted">${ORG_POSTS.includes(p.group_id) ? `Posted ${short(new Date(p.created_at))} ${new Date(p.created_at).getFullYear()}` : ago(p.created_at)}</div></div>
        <button data-menu="${p.id}" style="font-size:24px;font-weight:900;letter-spacing:1px">•••</button></div>
      ${postBody(p)}
      ${poll}
      <div class="reactions">
        <button class="pill ${liked ? "on" : ""}" data-like="${p.id}">${ICON.thumb} ${shared ? count("👍") : liked ? 1 : 0}</button>
        ${sharedPills}${reacts.map((r) => `<span class="pill">${r}</span>`).join("")}
        <button class="pill" data-react="${p.id}">☺+</button>
      </div>
      <div class="post-foot"><button data-comment="${p.id}">Comment${comments.length ? ` (${comments.length})` : ""}</button><button data-share="${p.id}">Share</button></div>
      ${comments.length ? `<div class="comments">${comments.map((c) => `<div class="comment"><b>${esc(c.author_name)}</b>${badge(c.user_id)} ${escLinks(c.body)}${ytCards(c.body)}${isOrg() || (c.user_id && c.user_id === me.id) ? `<button class="c-del" data-delc="${c.id}" aria-label="Delete comment" title="Delete comment">×</button>` : ""}</div>`).join("")}</div>` : ""}
    </article>`;
  }

  function wirePosts(el, posts) {
    const find = (id) => posts.find((p) => p.id === id);
    // Reactions are shared with everyone once the database has them; until then they stay on this phone.
    const toggle = async (id, e) => {
      if (pending()) return toast("You can react once the admin has approved your membership");
      const on = reactCache.some((r) => r.post_id === id && r.user_id === me.id && r.emoji === e);
      try {
        if (on) await q(sb.from("post_reactions").delete().eq("post_id", id).eq("user_id", me.id).eq("emoji", e));
        else await q(sb.from("post_reactions").insert({ post_id: id, user_id: me.id, emoji: e }));
        refresh();
      } catch (err) { fail(err); }
    };
    el.querySelectorAll("[data-like]").forEach((b) => (b.onclick = () => {
      const id = b.dataset.like;
      if (Array.isArray(reactCache)) return toggle(id, "👍");
      state.likes[id] = !state.likes[id]; save(); refresh();
    }));
    el.querySelectorAll("[data-toggle]").forEach((b) => (b.onclick = () => toggle(b.dataset.toggle, b.dataset.e)));
    el.querySelectorAll("[data-react]").forEach((b) => (b.onclick = () => {
      const id = b.dataset.react;
      modal(`<h2>Add a reaction</h2><div style="font-size:34px;display:flex;gap:14px;flex-wrap:wrap">${REACTS.map((e) => `<button data-e="${e}">${e}</button>`).join("")}</div>`, (m) => {
        m.querySelectorAll("[data-e]").forEach((x) => (x.onclick = () => {
          closeModal();
          if (Array.isArray(reactCache)) return toggle(id, x.dataset.e);
          (state.reactions[id] ||= []).push(x.dataset.e); save(); refresh();
        }));
      });
    }));
    el.querySelectorAll("[data-comment]").forEach((b) => (b.onclick = () => {
      const id = b.dataset.comment;
      modal(`<h2>Write a comment</h2><label>Comment</label><textarea id="t"></textarea><div class="form-actions"><button class="btn solid block" id="send">Post comment</button></div>`, (m) => {
        $("#t", m).focus();
        $("#send", m).onclick = async () => {
          const body = $("#t", m).value.trim(); if (!body) return;
          try { await q(sb.from("comments").insert({ post_id: id, user_id: me.id, author_name: me.name, body })); closeModal(); refresh(); cheer(); } catch (e) { fail(e); }
        };
      });
    }));
    el.querySelectorAll("[data-share]").forEach((b) => (b.onclick = () => { const p = find(b.dataset.share); share(C.name, noPhotos(p.body).replace(/\*\*/g, "").slice(0, 120)); }));
    el.querySelectorAll("[data-vote]").forEach((b) => (b.onclick = async () => {
      try { await q(sb.from("poll_votes").upsert({ post_id: b.dataset.vote, user_id: me.id, choice: Number(b.dataset.i) })); refresh(); } catch (e) { fail(e); }
    }));
    el.querySelectorAll("[data-delc]").forEach((b) => (b.onclick = () => {
      const c = commentCache.find((x) => x.id === b.dataset.delc);
      deleteMessage("comments", b.dataset.delc, c);
    }));
    el.querySelectorAll("[data-menu]").forEach((b) => (b.onclick = () => {
      const p = find(b.dataset.menu), mine = p.user_id === me.id;
      modal(`<h2>Post options</h2>
        <button class="btn block" id="copy">Copy text</button>
        ${isOrg() ? `<div style="height:10px"></div><button class="btn block" id="pin">${p.pinned ? "Unpin" : "Pin to top"}</button>` : ""}
        ${isOrg() ? '<div style="height:10px"></div><button class="btn block" id="edit">Edit post</button>' : ""}
        ${mine || isOrg() ? '<div style="height:10px"></div><button class="btn block danger" id="del">Delete post</button>' : ""}`, (m) => {
        $("#copy", m).onclick = async () => { try { await navigator.clipboard.writeText(noPhotos(p.body).replace(/\*\*/g, "")); toast("Copied"); } catch {} closeModal(); };
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
        const del = $("#del", m); if (del) del.onclick = () => { closeModal(); deleteMessage("posts", p.id, p); };
      });
    }));
  }

  // Deletes a post or comment. For a guest's message the admin can give the guest a strike at the same time.
  function deleteMessage(table, id, row) {
    const what = table === "posts" ? "post" : "comment", guestKey = row?.guest_key && isAdmin() ? row.guest_key : null;
    const gname = (row?.author_name || "").replace(/ \(guest\)$/, "");
    const go = async (strike) => {
      try {
        await q(sb.from(table).delete().eq("id", id));
        if (strike) {
          const why = prompt(`Why the strike for ${gname}? (Only you see this.)`, `Deleted ${what}: ${(row.body || "").slice(0, 80)}`);
          const rep = (await q(sb.rpc("guest_report")).catch(() => [])).find((x) => x.key === guestKey) || { strikes: 0, note: "" };
          const n = Math.min(9, rep.strikes + 1);
          const note = [rep.note, `${short(new Date())} ${new Date().getFullYear()}: strike ${n}${why && why.trim() ? ` – ${why.trim()}` : ""}`].filter(Boolean).join("\n");
          await q(sb.rpc("set_guest_strikes", { p_key: guestKey, p_strikes: n, p_note: note, p_name: gname }));
          toast(n >= 2 ? `Deleted. ${gname} now has ${n} strikes: you can block them in Admin → Guests` : `Deleted, and ${gname} has a strike`);
        } else toast(`${what[0].toUpperCase() + what.slice(1)} deleted`);
        closeModal(); refresh();
      } catch (e) { fail(e); }
    };
    if (!guestKey) { if (table === "posts" || confirm("Delete this comment?")) go(false); return; }
    modal(`<h2>Delete this ${what}?</h2><p class="muted">It's from ${esc(gname)}, a guest. You can also give them a strike; at two strikes you can block them in Admin → Guests.</p>
      <div class="form-actions" style="display:grid;gap:10px"><button class="btn danger block" id="dS">Delete and give a strike</button><button class="btn block" id="dO">Just delete</button></div>`, (m) => {
      $("#dS", m).onclick = () => go(true); $("#dO", m).onclick = () => go(false);
    });
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
        try { $("#post", m).disabled = true; await q(sb.from("posts").insert(post)); closeModal(); refresh(); if (post.group_id === ANNOUNCE || ORG_POSTS.includes(post.group_id)) toast("Posted"); else cheer(); } catch (e) { $("#post", m).disabled = false; fail(e); }
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
      <button class="menu-row" data-to="funds">${ICON.poll}<span>Funds & accounts ${ICON.chev}</span></button>
      <button class="menu-row" data-to="counselling">${ICON.star}<span>Counselling ${ICON.chev}</span></button>
      <button class="menu-row" data-to="welcome">${ICON.user}<span>Welcome & our agreement ${ICON.chev}</span></button>
      <button class="menu-row" data-to="about">${ICON.star}<span>About us ${ICON.chev}</span></button>
      <button class="menu-row" data-to="notifications">${ICON.bell}<span>Phone notifications ${ICON.chev}</span></button>
      <button class="menu-row" data-to="join">${ICON.phone}<span>How to join & install the app ${ICON.chev}</span></button>
      ${isDoor() ? `<h3 class="menu-head">Organisers · on the night</h3>
      <button class="menu-row" data-to="supervisors">${ICON.ball}<span>Football Supervisors ${ICON.chev}</span></button>
      ${isAdmin() ? "" : `<button class="menu-row" data-to="admin">${ICON.tools}<span>Check in at other events ${ICON.chev}</span></button>`}` : ""}
      ${me?.sup?.length ? `<h3 class="menu-head">Event supervisor</h3>
      <button class="menu-row" data-to="supervising">${ICON.tools}<span>Supervisor tools: scan tickets ${ICON.chev}</span></button>` : ""}
      ${isAdmin() ? `<h3 class="menu-head">Admin</h3>
      <button class="menu-row" data-to="footballadmin">${ICON.ball}<span>Football Accounts ${ICON.chev}</span></button>
      <button class="menu-row" data-to="eventaccounts">${ICON.cal}<span>Events accounts to post ${ICON.chev}</span></button>
      <button class="menu-row" data-to="weekly">${ICON.poll}<span>Weekly accounts ${ICON.chev}</span></button>
      <button class="menu-row" data-to="admin">${ICON.tools}<span>Admin tools ${ICON.chev}</span></button>` : ""}`;
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
      <p class="muted">${me.agreed_at ? `You agreed to our welcome on ${longDate(new Date(me.agreed_at))}.` : "You haven't agreed to our welcome yet."} <a href="#welcome">Read it</a></p>
      <h2 style="margin-top:24px">My credit</h2>
      <p><b>${money(me.credit || 0)}</b> <span class="muted">held on your account</span></p>
      <p class="muted">Credit comes from paying for football and then not playing, or cancelling. It's used automatically for your next booking.</p>
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
    $("#out", el).onclick = async () => { await forgetThisPhone(false); await sb.auth.signOut(); me = null; updateBell(true); go("events"); };
  }

  function signInScreen(el) {
    const guest = state.guestTickets.length ? `<h2 style="margin-top:28px">Guest tickets on this phone</h2>${state.guestTickets.map((c) => `<button class="list-row block-row" data-ticket="${esc(c)}"><div><b class="mono">${esc(c)}</b><span class="muted">Tap to show</span></div>${ICON.chev}</button>`).join("")}` : "";
    el.innerHTML = `<div class="pad" style="padding-top:24px">
      <h1>Sign in or join</h1>
      <p class="muted" style="line-height:1.5">Members can book football and members-only events, post in the groups, and invite guests. New here? <a href="#join">See how to join and install the app</a>.</p>
      <div class="seg"><button data-mode="in" class="on">Sign in</button><button data-mode="up">Join</button></div>
      <div id="nameRow" hidden><label>Your full name</label><input id="nm" autocomplete="name">
        <label>Your postcode</label><input id="pc" autocomplete="postal-code" placeholder="e.g. BR3 1AA" style="text-transform:uppercase">
        <p class="muted" style="font-size:14px">Membership is for people living within ${HOME_MILES} miles of BR3. Only the admin can see your postcode.</p>
        <label>What would you like to join for?</label><div class="radios">
          <label class="check"><input type="radio" name="lvl" value="all" checked> Events and Friday football</label>
          <label class="check"><input type="radio" name="lvl" value="events"> Events only</label></div>
        <label>Our welcome and agreement</label><div class="welcome-scroll">${WELCOME}</div>
        <label class="check"><input type="checkbox" id="agreeJoin"> I have read the welcome and I agree to it</label></div>
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
      if (mode === "up" && !$("#agreeJoin", el).checked) return toast("Please read the welcome and tick I agree");
      try {
        $("#go", el).disabled = true;
        if (mode === "up") {
          const miles = await milesFromHome(postcode);
          if (miles === false) { $("#go", el).disabled = false; return toast("We couldn't find that postcode. Please check it"); }
          const r = await q(sb.auth.signUp({ email, password, options: { data: { name, postcode, miles: miles == null ? "" : miles.toFixed(1), agreed: "yes" } } }));
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
        await loadMe(); toast(`Welcome, ${me?.name || ""}`); go("events"); markSeen();
        if (mode === "in") setTimeout(askAgreement, 600);
        updateBell(true); keepPushFresh(); setTimeout(offerPush, 2500);
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
      if (onCheckedIn) onCheckedIn(t);
      modal(`<button class="close" aria-label="Close">×</button>
        <p class="${ok ? "" : "note"}" style="font-size:18px;margin:0 0 6px"><b>${head}</b></p>
        <h2 style="font-size:26px;margin:0 0 12px">${esc(t.guest_name || t.name)}</h2>
        ${row("Event", `${esc(t.title)} · ${short(parseDay(t.day))} ${hhmm(t.time)}`)}
        ${row("Places", t.places)}
        ${t.age || t.gender ? row("Age", `${t.age ? esc(t.age) : "?"}${t.gender ? ` · ${esc(t.gender)}` : ""}`) : ""}
        ${t.guest ? row("Guest", t.booked_by ? `invited by ${esc(t.booked_by)}` : "yes") : t.booked_by ? row("Booked by", esc(t.booked_by)) : ""}
        ${row("Payment", payStatus(t))}
        ${t.age && t.age < 16 ? row("Under 16", t.parent_ok ? "Parent permission given" : '<span style="color:var(--warn,#e0a030)">No parent permission recorded</span>') : ""}
        <div class="form-actions"><button class="btn solid block" id="ciNext">${again ? "Scan the next ticket" : "Done"}</button></div>`, (m) => {
        $("#ciNext", m).onclick = () => { closeModal(); if (again) scanTicket(checkIn); };
      });
    } catch (e) { fail(e); if (again) setTimeout(() => scanTicket(checkIn), 1200); }
  }
  // How a booking is paid, in words: kitty, pay and play, paid or still to pay.
  const METHOD_NAME = { card: "card", transfer: "transfer", cash: "cash", credit: "credit", owes: "owes" };
  function payStatus(b) {
    const warn = (t) => `<span style="color:var(--warn,#e0a030)">${t}</span>`;
    if (b.charge === "covered") return "Kitty member, nothing to pay";
    const what = b.charge === "kitty" ? "Kitty £15" : b.charge === "payg" ? `Pay and play ${money(b.amount)}` : money(b.amount);
    if (!(Number(b.amount) > 0)) return "Free";
    if (b.paid) return `${what}, paid${b.method && METHOD_NAME[b.method] ? ` by ${METHOD_NAME[b.method]}` : ""}`;
    return warn(`${what}, ${b.method === "owes" ? "owes" : "not paid yet"}`);
  }
  // A list under the scan button: how many are booked, how many are here, and who's still to come.
  let onCheckedIn = null;
  async function whosIn(box, eventId, also) {
    const load = async () => {
      if (!box.isConnected) { onCheckedIn = null; return; }
      const [bks, gs] = await Promise.all([
        q(sb.from("bookings").select("id,display_name,places,checked_in,paid,amount,method,charge").eq("event_id", eventId).eq("status", "booked").order("display_name")),
        q(sb.from("guests").select("booking_id,full_name")).catch(() => []),
      ]);
      const gn = Object.fromEntries(gs.map((x) => [x.booking_id, x.full_name]));
      const n = (l) => l.reduce((t, b) => t + (b.places || 1), 0);
      const here = bks.filter((b) => b.checked_in), toCome = bks.filter((b) => !b.checked_in);
      const li = (b) => `<li>${esc(gn[b.id] || b.display_name)}${b.places > 1 ? ` (${b.places})` : ""} <span class="muted" style="font-size:14px">· ${payStatus(b)}</span></li>`;
      box.innerHTML = `<details class="card" style="padding:12px 14px;margin:10px 0" ${box.dataset.open ? "open" : ""}><summary><b>Who's in: ${n(here)} here, ${n(toCome)} still to come</b> <span class="muted">(${n(bks)} booked)</span></summary>
        <h3>Still to come (${n(toCome)})</h3><ul>${toCome.map(li).join("") || '<li class="muted">Everyone is here.</li>'}</ul>
        <h3>Here (${n(here)})</h3><ul>${here.map(li).join("") || '<li class="muted">No one yet.</li>'}</ul></details>`;
      $("details", box).ontoggle = (e) => { if (e.target.open) box.dataset.open = "1"; else delete box.dataset.open; };
    };
    onCheckedIn = (t) => { if (also) also(t); load().catch(() => {}); };
    await load().catch((e) => (box.innerHTML = `<p class="muted">${esc(e.message)}</p>`));
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

  // ---------- SUPERVISOR TOOLS ----------
  // Members chosen to supervise an event: their team, the other supervisors, and scanning at that event only.
  // It disappears at 4am the morning after the event.
  async function supervising(el, alive) {
    loading(el);
    await loadMe();
    if (!alive()) return;
    const mine = (me?.sup || []).sort((a, b) => eventStart(a.events) - eventStart(b.events));
    if (!mine.length) { el.innerHTML = `<div class="empty"><h2>Supervisor tools</h2><p class="muted">You're not supervising an event at the moment. When the admin puts you in a team, the event shows here, and your access ends the morning after it.</p></div>`; return; }
    const ids = mine.map((x) => x.event_id);
    const all = await q(sb.from("event_supervisors").select("event_id,user_id,role,profiles(name)").in("event_id", ids)).catch(() => []);
    if (!alive()) return;
    el.innerHTML = `<div class="pad" style="padding-top:24px"><h1>Supervisor tools</h1>
      <p class="muted">Thank you for helping run our events. Scan tickets at the door, and see who's here and who's still to come.</p>
      ${mine.map((x) => { const ev = x.events, team = all.filter((s) => s.event_id === ev.id), roles = supRoles(ev);
        const nameRow = (s) => `<b>${esc(s.profiles?.name || "?")}${s.user_id === me.id ? " (you)" : ""}</b>`;
        // Tickets to scan: hall and other booked events. Football uses its own screen; chat sign-ups (Quran) have none.
        const tools = ev.kind === "football" ? '<button class="btn solid block" data-go="supervisors">Open Football Supervisors</button><p class="muted" style="font-size:14px">Scan tickets, tick people in and add people at the pitch, for this game.</p>'
          : ev.group_id || ev.link ? "" : `<button class="btn solid block" data-scan style="margin-bottom:10px">Scan a ticket's QR code</button>
          <div class="row"><input data-code placeholder="Or type the code, e.g. AA-7K2QX" style="text-transform:uppercase"><button class="btn small" data-type>Check in</button></div>`;
        return `<div class="card" style="padding:14px;margin:12px 0"><h2 style="margin:0 0 4px">${esc(ev.title)}</h2>
          <p class="muted" style="margin:0 0 8px">${ev.weekly ? `Every ${DAYS[parseDay(ev.day).getDay()]} · ${hhmm(ev.time)}` : fmtEvent(ev)}${ev.location ? ` · ${esc(ev.location)}` : ""}</p>
          <p>Your role: <b>${SUP_ROLES[x.role] || "Supervisor"}</b></p>
          ${ev.supervisor_blurb ? `<p style="white-space:pre-wrap">${escLinks(ev.supervisor_blurb)}</p>` : ""}
          <div class="sup-teams">${(roles.length ? roles : [x.role]).map((k) => `<div><small>${SUP_ROLES[k] || "Supervisors"}</small>${team.filter((s) => s.role === k).map(nameRow).join("") || '<span class="muted">No one yet</span>'}</div>`).join("")}</div>
          <p class="muted" style="font-size:14px">${supStandard(ev) ? "Please come to the pre-event meeting and the post-event debrief. " : ""}${ev.weekly ? "You stay a supervisor until the admin changes it." : "Your access ends at 4am the morning after the event."}</p>
          ${tools}
          ${tools && ev.kind !== "football" ? `<div data-list="${ev.id}"></div>` : ""}</div>`; }).join("")}</div>`;
    el.querySelectorAll("[data-scan]").forEach((b) => (b.onclick = () => scanTicket(checkIn)));
    el.querySelectorAll("[data-type]").forEach((b) => (b.onclick = () => { const i = b.parentElement.querySelector("[data-code]"), c = i.value.trim(); if (!c) return toast("Type the ticket code"); i.value = ""; checkIn(c); }));
    // One who's-in list at a time keeps the live updates simple: the soonest event's list.
    const lists = [...el.querySelectorAll("[data-list]")];
    if (lists[0]) whosIn(lists[0], lists[0].dataset.list);
    lists.slice(1).forEach((box) => { box.innerHTML = `<button class="btn small block" data-show="${box.dataset.list}">Show who's in</button>`; });
    el.querySelectorAll("[data-show]").forEach((b) => (b.onclick = () => whosIn(b.parentElement, b.dataset.show)));
  }

  // ---------- ORGANISER TOOLS ----------
  // What organisers see in Organiser tools: scanning and who's in.
  async function doorTools(el) {
    loading(el);
    const evs = await q(sb.from("events").select("*").gte("day", dayKey(today())).order("day").limit(10));
    const soon = evs.sort((a, b) => eventStart(a) - eventStart(b));
    el.innerHTML = `<div class="pad" style="padding-top:24px"><h2>Check someone in</h2>
      <button class="btn solid block" id="ciScan" style="margin-bottom:10px">Scan a ticket's QR code</button>
      <div class="row"><input id="ci" placeholder="Or type the code, e.g. AA-7K2QX" style="text-transform:uppercase"><button class="btn small" id="ciGo">Check in</button></div>
      ${soon.length ? `<label>Show who's in for</label><select id="ciEv">${soon.map((e) => `<option value="${e.id}">${esc(e.title)} · ${short(parseDay(e.day))}</option>`).join("")}</select><div id="ciList"></div>` : '<p class="muted">No events coming up.</p>'}
      <p class="muted">For Friday football, use Football Supervisors to tick people in and add people at the pitch.</p></div>`;
    $("#ciGo", el).onclick = () => { const c = $("#ci", el).value.trim(); if (!c) return toast("Type the ticket code"); $("#ci", el).value = ""; checkIn(c); };
    $("#ciScan", el).onclick = () => scanTicket(checkIn);
    if (soon.length) { const pick = () => whosIn($("#ciList", el), $("#ciEv", el).value); $("#ciEv", el).onchange = pick; pick(); }
  }
  async function admin(el, alive, openId) {
    if (!isDoor()) { el.innerHTML = '<div class="empty"><h2>Organisers only</h2></div>'; return; }
    if (!isAdmin()) return doorTools(el);
    loading(el);
    const [evs, bks, guests, members, fs] = await Promise.all([
      // The newest 40 events, plus weekly ones however long ago they started.
      Promise.all([q(sb.from("events").select("*").order("day", { ascending: false }).limit(40)), q(sb.from("events").select("*").eq("weekly", true))])
        .then(([a, w]) => [...a, ...w.filter((x) => !a.some((y) => y.id === x.id))]),
      q(sb.from("bookings").select("*").neq("status", "cancelled")),
      q(sb.from("guests").select("*, profiles(name)")),
      q(sb.from("profiles").select("*").order("name")),
      q(sb.from("fund_state").select("*").single()),
    ]);
    // Activity for the member search (empty until add-welcome-and-members.sql is run).
    const report = Object.fromEntries((await q(sb.rpc("member_report")).catch(() => [])).map((r) => [r.id, r]));
    // Guests (empty until add-guest-admin.sql is run).
    const greport = isAdmin() ? await q(sb.rpc("guest_report")).catch(() => null) : null;
    // Supervisor applications and teams (null until add-event-supervisors.sql is run).
    const [supApps, supRows] = await Promise.all([q(sb.from("supervisor_applications").select("*").order("created_at")).catch(() => null), q(sb.from("event_supervisors").select("*")).catch(() => null)]);
    if (!alive()) return;
    const g = Object.fromEntries(guests.map((x) => [x.booking_id, x]));
    // events from today on, soonest first, for the who's-in list under the scan button
    const soon = evs.filter((e) => e.day && e.day >= dayKey(today())).sort((a, b) => eventStart(a) - eventStart(b)).slice(0, 10);
    const ROLES = ["member", "organiser", "admin"];
    const evById = Object.fromEntries(evs.map((e) => [e.id, e]));
    const guestRequests = bks.filter((b) => b.status === "pending" && (!b.user_id || evById[b.event_id]?.apply_form));
    // Application details for events with Player and Audience tickets: type, who with, age checks, form answers.
    const appInfo = (b) => {
      const e = evById[b.event_id];
      if (!b.ticket_type && !e?.apply_form) return "";
      const bits = [b.ticket_type ? `<b>${TYPE_NAME[b.ticket_type]}</b>` : "", b.linked_to ? `with ${esc(b.linked_to)}` : "", b.adult_name ? `under 16, adult attending: ${esc(b.adult_name)}` : "",
        b.age >= 16 && b.age <= 18 ? `16 to 18, parents' consent: ${b.parent_ok ? "yes" : "no"}` : ""].filter(Boolean).join(" · ");
      const form = !e?.apply_form ? "" : b.application ? `<details><summary>Application form answers</summary><p style="white-space:pre-wrap;font-size:14px">${esc(b.application)}</p></details>`
        : `<div class="tag warn" style="margin-top:4px">Application form not in yet</div>`;
      return `<div style="margin-top:4px">${bits}</div>${form}`;
    };
    const pending = isAdmin() ? members.filter((m) => m.approved === false) : [];
    const ids = pending.map((m) => m.id);
    const nameOf = Object.fromEntries(members.map((m) => [m.id, m.name]));
    // Supervisors for one event: the 3 teams of 2, then everyone who applied, with a team to put them in.
    function supAdmin(e) {
      if (!supApps) return '<p class="muted"><b>Run add-event-supervisors.sql in Supabase to choose supervisors here.</b></p>';
      const team = supRows.filter((x) => x.event_id === e.id), apps = supApps.filter((x) => x.event_id === e.id);
      const inTeam = Object.fromEntries(team.map((x) => [x.user_id, x.role]));
      const perRole = "sup_door" in e, roles = supRoles(e), need = supNeeded(e);
      const rolePick = (dflt) => `<select data-team>${roles.map((k) => `<option value="${k}" ${k === dflt ? "selected" : ""}>${SUP_ROLES[k]}</option>`).join("")}</select>`;
      const settings = `<div class="sup-set" data-sup-set="${e.id}">
        <label class="check"><input type="checkbox" data-s="open" ${e.supervisors_open ? "checked" : ""}> Supervisor applications open (shows on the advert and tells members)</label>
        ${perRole ? `<p style="margin:6px 0 2px"><b>Supervisors needed for each role</b></p>
          ${Object.entries(SUP_ROLES).map(([k, v]) => `<div class="sup-count"><span>${v}</span><select data-s="${k}">${[0, 1, 2].map((n) => `<option ${n === supCount(e, k) ? "selected" : ""}>${n}</option>`).join("")}</select></div>`).join("")}
          <label>Blurb and tasks for this event (shown on the advert)</label><textarea data-s="blurb" rows="5" maxlength="3000" placeholder="Leave empty to use the standard call for supervisors">${esc(e.supervisor_blurb || "")}</textarea>`
          : '<p class="muted" style="font-size:14px"><b>Run add-supervisors-any-event.sql in Supabase to set the numbers for each role and your own blurb.</b></p>'}
        <label>Application deadline (optional)</label><input data-s="deadline" type="date" value="${e.supervisor_deadline || ""}">
        <button class="btn small" data-sup-save="${e.id}" style="margin-top:8px">Save supervisor settings</button></div>`;
      const nameRow = (x) => `<span class="sup-name">${esc(nameOf[x.user_id] || "?")} <button class="btn small" data-sup-rm="${e.id}|${x.user_id}">Remove</button></span>`;
      // Anyone already chosen for a role this event no longer needs still shows, so they can be moved or removed.
      const shown = [...new Set([...roles, ...team.map((x) => x.role)])];
      return `<div class="sup-admin"><h3>Supervisors (${team.length} of ${need})</h3>
        ${settings}
        <p class="muted" style="font-size:14px">${e.kind === "football" ? "Supervisors get the Football Supervisors screen for this game until 4am Saturday." : e.weekly ? "Supervisors stay until you remove them." : "Supervisors can scan tickets at this event until 4am the morning after it."}</p>
        <div class="sup-teams">${shown.map((k) => `<div><small>${SUP_ROLES[k] || "Supervisors"} (${team.filter((x) => x.role === k).length}/${supCount(e, k)})</small>${team.filter((x) => x.role === k).map(nameRow).join("") || '<span class="muted">No one yet</span>'}</div>`).join("") || '<p class="muted">No roles set yet.</p>'}</div>
        <h3>Applied (${apps.length})</h3>
        ${apps.map((a) => `<div class="sup-app" data-who="${a.user_id}"><b>${esc(nameOf[a.user_id] || "Member")}</b> <span class="muted" style="font-size:13px">applied ${short(new Date(a.created_at))}</span>
          ${a.prefs?.length ? `<div>Would like: ${a.prefs.map((k) => SUP_ROLES[k]).join(", ")}</div>` : ""}${a.note ? `<div class="muted" style="white-space:pre-line">${esc(a.note)}</div>` : ""}
          ${roles.length ? `<div class="row" style="gap:8px;margin-top:6px">${rolePick(inTeam[a.user_id] || a.prefs?.find((k) => roles.includes(k)))}<button class="btn small solid" data-sup-add="${e.id}">${a.user_id in inTeam ? "Change role" : "Choose"}</button></div>` : ""}
          ${a.user_id in inTeam ? `<span class="tag">Chosen: ${SUP_ROLES[inTeam[a.user_id]] || "supervisor"}</span>` : ""}</div>`).join("") || '<p class="muted">No applications yet.</p>'}
        ${roles.length ? `<details><summary class="muted">Add a member who didn't apply</summary>
          <div class="sup-app"><select data-member>${members.filter((m) => m.approved !== false && !(m.id in inTeam)).map((m) => `<option value="${m.id}">${esc(m.name)}</option>`).join("")}</select>
          <div class="row" style="gap:8px;margin-top:6px">${rolePick(roles[0])}<button class="btn small" data-sup-add="${e.id}">Add</button></div></div></details>` : ""}</div>`;
    }
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
      ${guestRequests.length ? `<p class="note"><b>${guestRequests.length} guest booking request${guestRequests.length > 1 ? "s" : ""} waiting.</b> <a href="#" id="toGuests">See Guests below</a></p>` : ""}
      <h2>Check someone in</h2>
      <button class="btn solid block" id="ciScan" style="margin-bottom:10px">Scan a ticket's QR code</button>
      <div class="row"><input id="ci" placeholder="Or type the code, e.g. AA-7K2QX" style="text-transform:uppercase"><button class="btn small" id="ciGo">Check in</button></div>
      ${soon.length ? `<label>Show who's in for</label><select id="ciEv">${soon.map((e) => `<option value="${e.id}">${esc(e.title)} · ${short(parseDay(e.day))}</option>`).join("")}</select><div id="ciList"></div>` : ""}
      <h2 style="margin-top:28px">Add an event</h2>
      <label>Event name</label><input id="t">
      <div class="grid2"><div><label>Date (leave empty if not decided)</label><input id="d" type="date"></div><div><label>Start time</label><input id="tm" type="time" value="19:00"></div></div>
      <label>Where</label><input id="loc">
      <div class="grid2"><div><label>Price per place (£, 0 = free)</label><input id="pr" type="number" min="0" step="0.5" value="0"></div><div><label>Places</label><input id="cap" type="number" min="1" value="30"></div></div>
      <label>Who can book</label><select id="acc">${accessOpts("members")}</select>
      <label>Linked fund (gets the profit, or pays the loss)</label><select id="fund">${fundOpts("events")}</select>
      <label>Details</label><textarea id="det"></textarea>
      <label>Picture (optional)</label><input id="pic" type="file" accept="image/*">
      <label>Link instead of booking here (optional, e.g. the debate's page in Let's Debate)</label><input id="lnk" type="url" placeholder="https://debate.ourhomelands.co.uk/debates/…">
      <label class="check"><input type="checkbox" id="supOn"> Supervisor applications open (shows the call for supervisors on the advert, and tells members)</label>
      <label>Supervisor application deadline</label><input id="supDl" type="date">
      <div class="form-actions"><button class="btn solid block" id="add">Add event</button></div>
      <h2 style="margin-top:28px">Events and bookings</h2>
      <button class="btn block" id="csv">Download all event bookings (opens in Google Sheets or Excel)</button>
      ${[...evs.filter((e) => e.weekly), ...evs.filter((e) => !e.weekly)].map((e) => {
        const list = bks.filter((b) => b.event_id === e.id);
        // Weekly events (like the Quran target) are saved under their first date: show the next one.
        const nx = { ...e }; nextWeekly(nx);
        const when = !e.day ? "Date TBC" : e.weekly ? `Every ${DAYS[parseDay(e.day).getDay()]} · next ${short(parseDay(nx.day))}` : short(parseDay(e.day));
        return `<details class="card adm" data-ev="${e.id}" ${list.some((b) => b.status === "pending") || e.id === openId ? "open" : ""}><summary><b>${esc(e.title)}</b> <span class="muted">${when} · ${e.group_id ? "chat sign-up" : e.player_places != null ? ["player", "audience"].map((t) => `${TYPE_NAME[t].replace("Non-playing a", "A")}s ${list.filter((b) => b.status === "booked" && (b.ticket_type || "player") === t).length}/${t === "player" ? e.player_places : e.audience_places}`).join(", ") : `${list.reduce((t, b) => t + (b.status === "booked" ? b.places : 0), 0)}/${e.capacity}`}</span>${list.some((b) => b.status === "pending") ? ` <span class="tag warn">${list.filter((b) => b.status === "pending").length} to approve</span>` : ""}</summary>
          <div class="scroll"><table><thead><tr><th>Name</th><th>Who</th><th>Places</th><th>Status</th><th>Code</th></tr></thead><tbody>
          ${list.map((b) => `<tr><td>${esc(b.display_name)}</td><td>${g[b.id] ? `Guest, age ${g[b.id].age}${g[b.id].email ? `, ${esc(g[b.id].email)}` : ""}${g[b.id].invited_by ? `, invited by ${esc(g[b.id].profiles?.name || "?")}` : ""}` : "Member"}${appInfo(b)}</td><td>${b.places}</td><td>${b.status === "pending" ? `<b>Waiting for approval</b><br><button class="btn small" data-ok="${b.id}">Approve</button> <button class="btn small danger" data-no="${b.id}">Decline</button>` : b.status}${b.checked_in ? ", in" : ""}${b.paid || b.status === "pending" ? "" : ", unpaid"}${b.age < 16 && b.age ? `<br>Under 16, parent permission: ${b.parent_ok ? "yes" : "no"}` : ""}</td><td class="mono">${b.code}</td></tr>`).join("") || '<tr><td colspan="5" class="muted">No bookings yet.</td></tr>'}
          </tbody></table></div>
          ${e.kind === "event" ? `<div class="grid2" data-edit="${e.id}"><div style="grid-column:1/-1"><label>Event name</label><input data-f="title" value="${esc(e.title)}"></div>
            <div><label>${e.weekly ? "First date (repeats every week)" : "Date"}</label><input data-f="day" type="date" value="${e.day || ""}"></div><div><label>Start time</label><input data-f="time" type="time" value="${hhmm(e.time)}"></div>
            <div><label>Price (£)</label><input data-f="price" type="number" min="0" step="0.5" value="${Number(e.price)}"></div><div><label>Places</label><input data-f="capacity" type="number" min="1" value="${e.capacity}"></div>
            <div style="grid-column:1/-1"><label>Where</label><input data-f="location" value="${esc(e.location || "")}"></div>
            <div style="grid-column:1/-1"><label>Who can book</label><select data-f="access">${accessOpts(e.access)}</select></div>
            <div style="grid-column:1/-1"><label>Linked fund (gets the profit, or pays the loss)</label><select data-f="fund" ${e.accounts_posted ? "disabled" : ""}>${fundOpts(e.fund || "events")}</select></div>
            <div style="grid-column:1/-1"><label>Details</label><textarea data-f="details" rows="6">${esc(e.details || "")}</textarea></div>
            ${"apply_form" in e ? `<div style="grid-column:1/-1"><label>Application form link (Jotform; when set, non-members apply and wait for approval)</label><input data-f="apply_form" type="url" value="${esc(e.apply_form || "")}" placeholder="https://form.jotform.com/…"></div>
            <div><label>Player places (empty = one kind of ticket)</label><input data-f="player_places" type="number" min="1" value="${e.player_places ?? ""}"></div><div><label>Audience places</label><input data-f="audience_places" type="number" min="0" value="${e.audience_places ?? ""}"></div>
            <div><label>Audience price (£)</label><input data-f="audience_price" type="number" min="0" step="0.5" value="${e.audience_price ?? ""}"></div><div></div>` : ""}
            <div style="grid-column:1/-1"><label>Link instead of booking here (optional)</label><input data-f="link" type="url" value="${esc(e.link || "")}" placeholder="https://debate.ourhomelands.co.uk/debates/…"></div>
            <div style="grid-column:1/-1"><label>Picture</label>${e.image ? `<img class="event-pic" src="${esc(e.image)}" alt="">` : ""}<input data-pic="${e.id}" type="file" accept="image/*">${e.image ? `<button class="btn small" data-nopic="${e.id}" style="margin-top:8px">Remove picture</button>` : ""}</div>
            </div>
            <div class="row" style="margin:12px 0"><button class="btn small" data-upd="${e.id}">Save changes</button><button class="btn small" data-poster="${e.id}">QR code poster</button></div>` : ""}
          ${supAdmin(e)}
          <button class="btn small danger" data-del="${e.id}">Remove event</button></details>`;
      }).join("")}
      ${isAdmin() ? `<h2 style="margin-top:28px" id="guestsHead">Guests</h2>
      <p class="muted">People who aren't members: they booked an event open to guests, or joined in the Quran chat from its link. Each phone counts as one guest. Only you see this.</p>
      ${guestRequests.length ? `<h3>Booking requests and applications waiting for approval</h3>${guestRequests.map((b) => { const gu = g[b.id], e = evById[b.event_id];
        return `<div class="card" style="padding:14px;margin-bottom:10px"><b>${esc(gu?.full_name || b.display_name)}</b> <span class="muted">${gu ? `age ${gu.age}${gu.email ? `, ${esc(gu.email)}` : ""}` : `member${b.age ? `, age ${b.age}` : ""}`}</span>
          <div class="muted">${esc(e?.title || "Event")} · ${e?.day ? short(parseDay(e.day)) : "Date TBC"} · ${b.places} place${b.places > 1 ? "s" : ""}${b.age && b.age < 16 && !b.ticket_type ? ` · under 16, parent permission: ${b.parent_ok ? "yes" : "no"}` : ""}</div>${appInfo(b)}
          <div class="row" style="gap:8px;margin-top:8px"><button class="btn solid small" data-ok="${b.id}">Approve</button><button class="btn small danger" data-no="${b.id}">Decline</button></div></div>`; }).join("")}` : ""}
      ${greport ? `<div class="member-search">
        <input id="gQ" type="search" placeholder="Search guests by name or email">
        <div class="chips" id="gWho">${[["all", "All"], ["booked", "Booked an event"], ["chat", "In the chat"], ["strikes", "Strikes"], ["blocked", "Blocked"]].map(([k, v], i) => `<button data-gwho="${k}" class="${i ? "" : "on"}">${v}</button>`).join("")}</div>
        <div><label>Sort by</label><select id="gSort"><option value="active">Most active</option><option value="quiet">Least active</option><option value="recent">Last active</option><option value="name">Name</option></select></div>
        <p class="muted" style="font-size:14px">Activity over the last 90 days: 3 per booking, 3 per post, 2 per comment. Guests' booking details are deleted 7 days after the event; their names in the chat stay until you delete them.</p>
        <p id="gCount" class="muted"></p></div>
      <div id="gList"></div>` : '<p class="muted"><b>Run add-guest-admin.sql in Supabase to see guests here.</b></p>'}` : ""}
      <h2 style="margin-top:28px">Members</h2>
      <p class="muted">Family members pay by transfer and never by card. Tick Kitty for anyone who has already paid £15 for the current kitty. Untick Football for events-only members.${isAdmin() ? " Only you, as admin, can change roles." : ""}</p>
      <div class="member-search">
        <input id="mQ" type="search" placeholder="Search members by name">
        <div class="chips" id="mWho">${[["all", "All"], ["football", "Football"], ["events", "Events only"], ["member", "Members"], ["organiser", "Organisers"], ["admin", "Admin"], ["family", "Family"], ["strikes", "Strikes"], ["notagreed", "Not agreed"]].map(([k, v], i) => `<button data-who="${k}" class="${i ? "" : "on"}">${v}</button>`).join("")}</div>
        <div class="grid2"><div><label>Not active for</label><select id="mIdle"><option value="0">Any time</option>${[1, 2, 3, 4, 5, 6, 12].map((n) => `<option value="${n}">${n}+ month${n > 1 ? "s" : ""}</option>`).join("")}</select></div>
          <div><label>Sort by</label><select id="mSort"><option value="name">Name</option><option value="seen">Last in the app</option><option value="football">Last football</option><option value="active">Most active</option><option value="quiet">Least active</option></select></div></div>
        <p class="muted" style="font-size:14px">Activity counts everything in the app over the last 90 days: days they opened it, bookings, posts, comments, reactions and poll votes.${Object.keys(report).length ? "" : " <b>Run add-welcome-and-members.sql in Supabase to see activity.</b>"}</p>
        <p id="mCount" class="muted"></p></div>
      <div id="mList"></div>
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
    if (soon.length) { const pick = () => whosIn($("#ciList", el), $("#ciEv", el).value); $("#ciEv", el).onchange = pick; pick(); }
    $("#add", el).onclick = async () => {
      const ev = { kind: "event", title: $("#t", el).value.trim(), day: $("#d", el).value, time: $("#tm", el).value, location: $("#loc", el).value.trim(),
        price: Number($("#pr", el).value) || 0, capacity: Number($("#cap", el).value) || 1, access: $("#acc", el).value, fund: $("#fund", el).value, details: $("#det", el).value.trim(),
        link: $("#lnk", el).value.trim() || null };
      if ($("#supOn", el).checked) ev.supervisors_open = true;
      if ($("#supDl", el).value) ev.supervisor_deadline = $("#supDl", el).value;
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
    const decide = (id, ok) => q(sb.rpc("decide_booking", { p_id: id, p_ok: ok })).then((v) => {
      toast(ok ? (v === "waitlist" ? "Approved, but it's full so they're on the waitlist" : "Approved") : "Declined"); refresh();
    }).catch(fail);
    el.querySelectorAll("[data-ok]").forEach((b) => (b.onclick = () => {
      const bk = bks.find((x) => x.id === b.dataset.ok);
      if (evById[bk?.event_id]?.apply_form && !bk.application && !confirm("Their application form isn't in yet. Approve anyway?")) return;
      decide(b.dataset.ok, true);
    }));
    el.querySelectorAll("[data-no]").forEach((b) => (b.onclick = () => confirm("Decline this booking?") && decide(b.dataset.no, false)));
    el.querySelectorAll("[data-poster]").forEach((b) => (b.onclick = () => posterModal(evs.find((x) => x.id === b.dataset.poster))));
    // Opened from an event's "Edit this event" button: scroll to it, open at the top of the box.
    const opened = openId && el.querySelector(`details[data-ev="${openId}"]`);
    if (opened) setTimeout(() => opened.scrollIntoView({ block: "start" }), 50);
    el.querySelectorAll("[data-upd]").forEach((b) => (b.onclick = async () => {
      const box = $(`[data-edit="${b.dataset.upd}"]`, el), f = (k) => $(`[data-f="${k}"]`, box).value;
      if (!f("title").trim()) return toast("Give the event a name");
      const upd = { title: f("title").trim(), location: f("location").trim(), details: f("details").trim(), day: f("day") || null, time: f("time"), price: Number(f("price")) || 0, capacity: Number(f("capacity")) || 1, access: f("access"), link: f("link").trim() || null };
      if (!$('[data-f="fund"]', box).disabled) upd.fund = f("fund");
      if ($('[data-f="apply_form"]', box)) {
        const num = (k) => (f(k) === "" ? null : Number(f(k)));
        Object.assign(upd, { apply_form: f("apply_form").trim() || null, player_places: num("player_places"), audience_places: num("audience_places"), audience_price: num("audience_price") });
        if (upd.apply_form && !/^https:\/\//.test(upd.apply_form)) return toast("The application form link should start with https://");
        if (upd.player_places != null) upd.capacity = upd.player_places + (upd.audience_places || 0);
      }
      if (upd.link && !/^https?:\/\//.test(upd.link)) return toast("The link should start with https://");
      const file = $(`[data-pic="${b.dataset.upd}"]`, box).files[0];
      if (file) upd.image = await picture(file);
      try { await q(sb.from("events").update(upd).eq("id", b.dataset.upd)); toast(upd.day ? "Saved" : "Saved, date still to be confirmed"); refresh(); } catch (e) { fail(e); }
    }));
    el.querySelectorAll("[data-sup-add]").forEach((b) => (b.onclick = async () => {
      const box = b.closest(".sup-app"), who = box.dataset.who || $("[data-member]", box)?.value;
      if (!who) return toast("Choose a member");
      try { await q(sb.rpc("assign_supervisor", { p_event: b.dataset.supAdd, p_user: who, p_role: $("[data-team]", box).value })); toast(`${nameOf[who] || "They"} added`); refresh(); } catch (e) { fail(e); }
    }));
    // Supervisor settings: open or closed, how many for each role (0 to 2), the blurb and the deadline.
    el.querySelectorAll("[data-sup-save]").forEach((b) => (b.onclick = async () => {
      const box = b.closest("[data-sup-set]"), v = (k) => $(`[data-s="${k}"]`, box);
      const upd = { supervisors_open: v("open").checked, supervisor_deadline: v("deadline").value || null };
      if (v("door")) Object.assign(upd, { sup_door: Number(v("door").value), sup_crowd: Number(v("crowd").value), sup_run: Number(v("run").value), supervisor_blurb: v("blurb").value.trim() || null });
      if (upd.supervisors_open && v("door") && !(upd.sup_door + upd.sup_crowd + upd.sup_run)) return toast("Set at least one supervisor for a role, or untick applications open");
      try { await q(sb.from("events").update(upd).eq("id", b.dataset.supSave)); toast(upd.supervisors_open ? "Saved. Applications are open" : "Saved"); refresh(); } catch (e) { fail(e); }
    }));
    el.querySelectorAll("[data-sup-rm]").forEach((b) => (b.onclick = async () => {
      const [ev, who] = b.dataset.supRm.split("|");
      try { await q(sb.from("event_supervisors").delete().eq("event_id", ev).eq("user_id", who)); toast("Removed from the team"); refresh(); } catch (e) { fail(e); }
    }));
    el.querySelectorAll("[data-nopic]").forEach((b) => (b.onclick = async () => {
      try { await q(sb.from("events").update({ image: null }).eq("id", b.dataset.nopic)); toast("Picture removed"); refresh(); } catch (e) { fail(e); }
    }));
    el.querySelectorAll("[data-del]").forEach((b) => (b.onclick = async () => {
      if (b.dataset.sure !== "1") { b.dataset.sure = "1"; b.textContent = "Tap again to remove it and its bookings"; return; }
      try { await q(sb.from("events").delete().eq("id", b.dataset.del)); toast("Event removed"); refresh(); } catch (e) { fail(e); }
    }));
    // ----- member search -----
    const ACT = (n) => (n >= 40 ? "Very active" : n >= 10 ? "Active" : n > 0 ? "Quiet" : "Inactive");
    const dayOf = (v) => (v ? parseDay(String(v).slice(0, 10)) : null);
    const lastActive = (m) => dayOf(report[m.id]?.last_active) || new Date(m.created_at);
    function memberFacts(m) {
      const r = report[m.id];
      if (!r) return m.approved === false ? ' <span class="tag warn">Waiting for approval</span>' : "";
      const seen = dayOf(r.last_seen), fb = dayOf(r.last_football);
      return ` ${r.strikes ? `<span class="tag warn">${r.strikes} strike${r.strikes > 1 ? "s" : ""}</span>` : ""}${m.approved === false ? ' <span class="tag warn">Waiting for approval</span>' : ""}
        <div class="muted member-facts">Last in the app: ${seen ? short(seen) + " " + seen.getFullYear() : "not yet recorded"} · Last football: ${fb ? short(fb) + " " + fb.getFullYear() : "none"} · Joined ${short(new Date(m.created_at))} ${new Date(m.created_at).getFullYear()}<br>
          Activity: <b>${ACT(r.score)}</b> (${r.score}) · ${r.days_90} day${r.days_90 === 1 ? "" : "s"} in the app, ${r.bookings_90} booking${r.bookings_90 === 1 ? "" : "s"}, ${r.posts_90} post${r.posts_90 === 1 ? "" : "s"}, ${r.comments_90} comment${r.comments_90 === 1 ? "" : "s"}, ${r.reactions_90} reaction${r.reactions_90 === 1 ? "" : "s"} or vote${r.reactions_90 === 1 ? "" : "s"}<br>
          ${r.agreed_at ? `Agreed to the welcome ${short(new Date(r.agreed_at))}` : "Hasn't agreed to the welcome yet"}${Number(r.credit) ? ` · ${money(r.credit)} credit` : ""}</div>
        <div class="row strikes" style="gap:8px;margin:6px 0"><span>Strikes (only you see these): <b>${r.strikes}</b></span><button class="btn small" data-strike="${m.id}" data-n="${r.strikes + 1}">+ Strike</button>${r.strikes ? `<button class="btn small" data-strike="${m.id}" data-n="${r.strikes - 1}">− Take one off</button>` : ""}</div>
        ${r.strike_note ? `<div class="muted" style="font-size:14px;white-space:pre-line">Note: ${esc(r.strike_note)}</div>` : ""}`;
    }
    let mWho = "all";
    function showMembers() {
      const text = $("#mQ", el).value.trim().toLowerCase(), idle = Number($("#mIdle", el).value), sort = $("#mSort", el).value;
      const cutoff = new Date(); cutoff.setMonth(cutoff.getMonth() - idle);
      const WHO = { all: () => true, football: (m) => m.football !== false || m.family, events: (m) => m.football === false && !m.family, member: (m) => m.role === "member", organiser: (m) => m.role === "organiser", admin: (m) => m.role === "admin",
        family: (m) => m.family, strikes: (m) => (report[m.id]?.strikes || 0) > 0, notagreed: (m) => !m.agreed_at };
      const t = (d) => (d ? d.getTime() : 0), sc = (m) => report[m.id]?.score || 0;
      const list = members.filter((m) => (!text || m.name.toLowerCase().includes(text)) && WHO[mWho](m) && (!idle || lastActive(m) < cutoff))
        .sort({ name: (a, b) => a.name.localeCompare(b.name), seen: (a, b) => t(dayOf(report[b.id]?.last_seen)) - t(dayOf(report[a.id]?.last_seen)),
          football: (a, b) => t(dayOf(report[b.id]?.last_football)) - t(dayOf(report[a.id]?.last_football)), active: (a, b) => sc(b) - sc(a), quiet: (a, b) => sc(a) - sc(b) || t(lastActive(a)) - t(lastActive(b)) }[sort]);
      $("#mCount", el).textContent = `${list.length} of ${members.length} member${members.length === 1 ? "" : "s"}`;
      const box = $("#mList", el);
      box.innerHTML = list.map((m) => `<div class="member-row" data-mid="${m.id}"><b>${esc(m.name)}</b>${memberFacts(m)}
        <div class="row" style="flex-wrap:wrap;gap:8px">
          <select data-f="role" ${isAdmin() ? "" : "disabled"}>${ROLES.map((r) => `<option ${m.role === r ? "selected" : ""}>${r}</option>`).join("")}</select>
          <label class="check"><input type="checkbox" data-f="family" ${m.family ? "checked" : ""}> Family</label>
          <label class="check"><input type="checkbox" data-f="football" ${m.football !== false || m.family ? "checked" : ""}> Football</label>
          <label class="check"><input type="checkbox" data-f="kitty" ${m.kitty_session === fs.session_no ? "checked" : ""}> Kitty ${fs.session_no}</label>
          <label class="check">Credit £<input data-f="credit" type="number" step="1" min="0" value="${Number(m.credit)}" style="width:70px"></label>
          <button class="btn small" data-save="${m.id}">Save</button>${isAdmin() && m.id !== me.id && m.role !== "admin" ? `<button class="btn small danger" data-rm="${m.id}">Remove member</button>` : ""}</div></div>`).join("") || '<p class="muted">No members match.</p>';
      box.querySelectorAll("[data-save]").forEach((b) => (b.onclick = async () => {
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
      box.querySelectorAll("[data-rm]").forEach((b) => (b.onclick = async () => {
        const m = members.find((x) => x.id === b.dataset.rm);
        if (!confirm(`Remove ${m.name} from the app? Their account is deleted and they can't sign in again. Past bookings stay in the history.${Number(m.credit) ? `\n\nTheir ${money(m.credit)} credit moves to the Unclaimed credit fund on the Funds page. They can claim it for 12 months, then it goes to charity on their behalf.` : ""}`)) return;
        try { await q(sb.rpc("remove_member", { p_id: m.id })); toast(`${m.name} removed`); refresh(); } catch (e) { fail(e); }
      }));
      box.querySelectorAll("[data-strike]").forEach((b) => (b.onclick = async () => {
        const m = members.find((x) => x.id === b.dataset.strike), n = Number(b.dataset.n), r = report[m.id];
        let note = r.strike_note;
        if (n > r.strikes) {
          const why = prompt(`Strike ${n} for ${m.name}. What happened? (Only you see this.)`, "");
          if (why === null) return;
          note = [r.strike_note, `${short(new Date())} ${new Date().getFullYear()}: strike ${n}${why.trim() ? ` – ${why.trim()}` : ""}`].filter(Boolean).join("\n");
          if (n >= 2) toast("That's the second strike: under the two strike rule you can remove them");
        } else {
          if (!confirm(`Take a strike off ${m.name}? They'll have ${n}.`)) return;
          note = [r.strike_note, `${short(new Date())} ${new Date().getFullYear()}: strike taken off, now ${n}`].filter(Boolean).join("\n");
        }
        try { await q(sb.rpc("set_strikes", { p_id: m.id, p_strikes: n, p_note: note })); r.strikes = n; r.strike_note = note; showMembers(); } catch (e) { fail(e); }
      }));
    }
    $("#mQ", el).oninput = showMembers;
    $("#mIdle", el).onchange = showMembers;
    $("#mSort", el).onchange = showMembers;
    el.querySelectorAll("[data-who]").forEach((b) => (b.onclick = () => { mWho = b.dataset.who; el.querySelectorAll("[data-who]").forEach((x) => x.classList.toggle("on", x === b)); showMembers(); }));
    showMembers();
    const tg = $("#toGuests", el); if (tg) tg.onclick = (e) => { e.preventDefault(); $("#guestsHead", el)?.scrollIntoView({ block: "start" }); };
    // ----- guests -----
    let gWho = "all";
    const gStatus = { booked: "booked", waitlist: "waitlist", pending: "waiting for approval", declined: "declined", cancelled: "cancelled" };
    function showGuests() {
      const box = $("#gList", el); if (!box || !greport) return;
      const text = $("#gQ", el).value.trim().toLowerCase(), sort = $("#gSort", el).value;
      const WHO = { all: () => true, booked: (x) => x.bookings.length > 0, chat: (x) => x.posts_90 + x.comments_90 > 0, strikes: (x) => x.strikes > 0, blocked: (x) => !!x.blocked_at };
      const t = (v) => (v ? new Date(v).getTime() : 0);
      const list = greport.filter((x) => (!text || `${x.name} ${x.email || ""}`.toLowerCase().includes(text)) && WHO[gWho](x))
        .sort({ active: (a, b) => b.score - a.score || t(b.last_active) - t(a.last_active), quiet: (a, b) => a.score - b.score || t(a.last_active) - t(b.last_active),
          recent: (a, b) => t(b.last_active) - t(a.last_active), name: (a, b) => a.name.localeCompare(b.name) }[sort]);
      $("#gCount", el).textContent = `${list.length} of ${greport.length} guest${greport.length === 1 ? "" : "s"}`;
      box.innerHTML = list.map((x, i) => `<div class="member-row" data-gi="${greport.indexOf(x)}"><b>${esc(x.name)}</b> <span class="tag">Guest</span>${x.blocked_at ? ' <span class="tag warn">Blocked</span>' : ""}${x.strikes ? ` <span class="tag warn">${x.strikes} strike${x.strikes > 1 ? "s" : ""}</span>` : ""}
        <div class="muted member-facts">${x.email ? `${esc(x.email)} · ` : ""}First seen ${x.first_seen ? short(new Date(x.first_seen)) + " " + new Date(x.first_seen).getFullYear() : "–"} · Last active ${x.last_active ? short(new Date(x.last_active)) + " " + new Date(x.last_active).getFullYear() : "–"}<br>
          Activity: <b>${ACT(x.score)}</b> (${x.score}) · ${x.bookings_90} booking${x.bookings_90 === 1 ? "" : "s"}, ${x.posts_90} post${x.posts_90 === 1 ? "" : "s"}, ${x.comments_90} comment${x.comments_90 === 1 ? "" : "s"}</div>
        ${x.bookings.length ? `<div class="muted" style="font-size:14px">Booked: ${x.bookings.map((b) => `${esc(b.title)} ${b.day ? short(parseDay(b.day)) : "(TBC)"}, ${b.places} place${b.places > 1 ? "s" : ""}, ${gStatus[b.status] || b.status}${b.checked_in ? ", came" : ""}${Number(b.amount) > 0 ? `, ${b.paid ? "paid" : "unpaid"} ${money(b.amount)}` : ""}`).join("; ")}</div>` : ""}
        <div class="row strikes" style="gap:8px;margin:6px 0"><span>Strikes: <b>${x.strikes}</b></span><button class="btn small" data-gstrike="${greport.indexOf(x)}" data-n="${x.strikes + 1}">+ Strike</button>${x.strikes ? `<button class="btn small" data-gstrike="${greport.indexOf(x)}" data-n="${x.strikes - 1}">− Take one off</button>` : ""}</div>
        ${x.note ? `<div class="muted" style="font-size:14px;white-space:pre-line">Note: ${esc(x.note)}</div>` : ""}
        <div class="row" style="gap:8px;flex-wrap:wrap"><button class="btn small${x.blocked_at ? "" : " danger"}" data-gblock="${greport.indexOf(x)}">${x.blocked_at ? "Unblock" : "Block"}</button><button class="btn small danger" data-gdel="${greport.indexOf(x)}">Delete guest</button></div></div>`).join("") || '<p class="muted">No guests match.</p>';
      box.querySelectorAll("[data-gstrike]").forEach((b) => (b.onclick = async () => {
        const x = greport[b.dataset.gstrike], n = Number(b.dataset.n);
        let note = x.note;
        if (n > x.strikes) {
          const why = prompt(`Strike ${n} for ${x.name}. What happened? (Only you see this.)`, ""); if (why === null) return;
          note = [x.note, `${short(new Date())} ${new Date().getFullYear()}: strike ${n}${why.trim() ? ` – ${why.trim()}` : ""}`].filter(Boolean).join("\n");
          if (n >= 2) toast("That's the second strike: you can block them");
        } else {
          if (!confirm(`Take a strike off ${x.name}? They'll have ${n}.`)) return;
          note = [x.note, `${short(new Date())} ${new Date().getFullYear()}: strike taken off, now ${n}`].filter(Boolean).join("\n");
        }
        try { await q(sb.rpc("set_guest_strikes", { p_key: x.key, p_strikes: n, p_note: note, p_name: x.name })); x.strikes = n; x.note = note; showGuests(); } catch (e) { fail(e); }
      }));
      box.querySelectorAll("[data-gblock]").forEach((b) => (b.onclick = async () => {
        const x = greport[b.dataset.gblock], on = !x.blocked_at;
        if (!confirm(on ? `Block ${x.name}? They won't be able to post or comment in the chat, or book events from that phone or their email. Any request waiting for approval is declined.` : `Unblock ${x.name}?`)) return;
        try { await q(sb.rpc("block_guest", { p_key: x.key, p_on: on, p_name: x.name })); toast(on ? `${x.name} blocked` : `${x.name} unblocked`); refresh(); } catch (e) { fail(e); }
      }));
      box.querySelectorAll("[data-gdel]").forEach((b) => (b.onclick = async () => {
        const x = greport[b.dataset.gdel];
        if (!confirm(`Delete ${x.name}? Their posts and comments in the chat are deleted, along with their details. Bookings for events still to come are cancelled; past ones stay in the head count as "Guest (details removed)".${x.blocked_at ? " They stay blocked." : " To stop them coming back, block them first."}`)) return;
        try { await q(sb.rpc("delete_guest", { p_key: x.key })); toast(`${x.name} deleted`); refresh(); } catch (e) { fail(e); }
      }));
    }
    if (greport) {
      $("#gQ", el).oninput = showGuests; $("#gSort", el).onchange = showGuests;
      el.querySelectorAll("[data-gwho]").forEach((b) => (b.onclick = () => { gWho = b.dataset.gwho; el.querySelectorAll("[data-gwho]").forEach((y) => y.classList.toggle("on", y === b)); showGuests(); }));
      showGuests();
    }
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
  // ---------- NOTIFICATIONS (the bell) ----------
  // Phone notifications are web push: the phone keeps a subscription, the database queues each
  // notification (supabase/add-phone-notifications.sql) and netlify/functions/push sends it.
  const PREF_LIST = [
    ["announcements", "Announcements", "When the admin posts in Announcements"],
    ["events", "New events", "When an event is added, or gets its date"],
    ["football", "Football booking open", "Wednesday at 1pm, when booking opens for Friday"],
    ["reminders", "Reminders", "The day before an event or game you've booked"],
    ["replies", "Comments", "On your posts, and posts you've commented on"],
    ["mygroups", "Chats you've signed up to", "Like the Quran Recitation Target"],
    ["chats", "Every other chat post", "Including the accounts chats. This can be a lot"],
  ];
  const PREF_DEFAULT = { announcements: true, events: true, football: true, reminders: true, replies: true, mygroups: true, chats: false };
  async function notifications(el, alive) {
    if (!me) return needSignIn(el, "get notifications");
    loading(el);
    const [list, prefs, stats, sub] = await Promise.all([
      q(sb.from("notices").select("id,title,body,url,created_at,read_at").order("id", { ascending: false }).limit(40)).catch(() => null),
      q(sb.from("push_prefs").select("*").eq("user_id", me.id).maybeSingle()).catch(() => null),
      isAdmin() ? q(sb.rpc("push_stats")).catch(() => null) : null,
      currentSub().catch(() => null),
    ]);
    if (!alive()) return;
    if (list === null) {
      el.innerHTML = `<div class="empty"><h2>Notifications are coming soon</h2><p class="muted" style="line-height:1.5">${isAdmin() ? "Run add-phone-notifications.sql in the Supabase SQL Editor, then come back here." : "Check back soon."}</p></div>`;
      return;
    }
    const p = { ...PREF_DEFAULT, ...(prefs || {}) };
    const prefRows = PREF_LIST.filter(([k]) => k !== "football" || !eventsOnly())
      .map(([k, name, about]) => `<label class="check pref"><input type="checkbox" data-pref="${k}" ${p[k] ? "checked" : ""}><span><b>${name}</b><span class="muted">${about}</span></span></label>`).join("");
    el.innerHTML = `<div class="pad" style="padding-top:24px"><h1>Notifications</h1>
      <div class="card fb">${pushStatusHtml(sub)}</div>
      ${stats ? `<p class="muted" style="margin-top:12px">${stats.on} of ${stats.members} approved members have notifications on (${stats.phones} phone${stats.phones === 1 ? "" : "s"}).</p>` : ""}
      <h2 style="margin-top:24px">What to tell me about</h2>
      <div class="prefs">${prefRows}</div>
      <h2 style="margin-top:24px">Recent</h2>
      ${list.map((n) => `<button class="list-row block-row${n.read_at ? "" : " unread"}" data-open="${esc(n.url)}"><div><b>${esc(n.title)}</b><span class="muted">${esc(n.body)}</span><div class="muted" style="font-size:13px;margin-top:4px">${agoLong(n.created_at)}</div></div></button>`).join("")
        || '<p class="muted">Nothing yet. New announcements, events and reminders will show here.</p>'}
    </div>`;
    wirePush(el, sub);
    el.querySelectorAll("[data-pref]").forEach((c) => (c.onchange = async () => {
      const row = { user_id: me.id };
      el.querySelectorAll("[data-pref]").forEach((x) => (row[x.dataset.pref] = x.checked));
      try { await q(sb.from("push_prefs").upsert(row)); toast("Saved"); } catch (e) { c.checked = !c.checked; fail(e); }
    }));
    el.querySelectorAll("[data-open]").forEach((b) => (b.onclick = () => go(b.dataset.open.replace(/^#/, "") || "events")));
    if (list.some((n) => !n.read_at)) sb.rpc("read_notices").then(() => updateBell(true));
  }
  // The box at the top of the Notifications screen: what this phone can do, and the button for it.
  function pushStatusHtml(sub) {
    if (!pushSupported()) {
      if (isIOS() && !installed()) return `<h2>Add the app to your home screen first</h2>
        <p>On an iPhone, notifications only work from the app's icon on your home screen. Add it, open it from there, and come back here.</p>
        <button class="btn solid block" data-go="join" style="margin-top:8px">Show me how</button>`;
      return `<h2>Notifications aren't available here</h2><p>This browser can't show notifications. On an iPhone you need iOS 16.4 or newer (Settings, General, Software Update). On Android, use Chrome.</p>`;
    }
    if (Notification.permission === "denied") return `<h2>Notifications are blocked</h2>
      <p>${isIOS() ? "Open your iPhone's Settings, then Notifications, then Homelands, and switch on Allow Notifications." : "Tap the padlock or the ⓘ next to the address (or press and hold the app icon, then App info) and allow Notifications."} Then come back here.</p>`;
    if (sub && Notification.permission === "granted") return `<h2>✓ Notifications are on</h2>
      <p class="muted">You'll get a buzz on this phone for the things ticked below.</p>
      <div class="form-actions" style="display:grid;gap:10px"><button class="btn solid block" id="pushTest">Send me a test</button><button class="btn block" id="pushOff">Turn off on this phone</button></div>`;
    return `<h2>Turn on notifications</h2><p>Get a buzz on your phone for announcements, new events, football booking and reminders, just like WhatsApp.</p>
      <button class="btn solid block" id="pushOn" style="margin-top:8px">Turn on notifications</button>`;
  }
  function wirePush(el) {
    const on = $("#pushOn", el), off = $("#pushOff", el), test = $("#pushTest", el);
    if (on) on.onclick = () => { on.disabled = true; turnOnPush().then(() => { toast("Notifications are on ✓"); refresh(); }).catch((e) => { on.disabled = false; fail(e); refresh(); }); };
    if (off) off.onclick = () => forgetThisPhone(true).then(() => { toast("Turned off on this phone"); refresh(); }).catch(fail);
    if (test) test.onclick = async () => {
      test.disabled = true;
      try { await q(sb.rpc("test_push")); toast("Sent. It should arrive in a few seconds"); } catch (e) { fail(e); }
      setTimeout(() => (test.disabled = false), 4000);
    };
  }

  const pushSupported = () => "serviceWorker" in navigator && "PushManager" in window && "Notification" in window && window.isSecureContext;
  const PUSH_KEY = "homelands-push-key";
  const fromB64 = (s) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4)), (c) => c.charCodeAt(0));
  const toB64 = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  async function pushKey() {
    try { const k = localStorage.getItem(PUSH_KEY); if (k) return k; } catch {}
    const r = await fetch("/.netlify/functions/push?key").then((x) => x.json()).catch(() => ({}));
    if (!r.key) throw new Error("Notifications aren't ready yet. Please try again later.");
    try { localStorage.setItem(PUSH_KEY, r.key); } catch {}
    return r.key;
  }
  async function currentSub() {
    if (!pushSupported()) return null;
    const reg = await navigator.serviceWorker.ready;
    return reg.pushManager.getSubscription();
  }
  const deviceName = () => (isIOS() ? "iPhone" : /android/i.test(navigator.userAgent) ? "Android" : "Computer");
  // Asks for permission (the first thing it does, so iPhones count it as part of the tap), then saves this phone.
  async function turnOnPush(ask = true) {
    if (!pushSupported()) throw new Error("This phone can't show notifications from here.");
    const perm = ask ? await Notification.requestPermission() : Notification.permission;
    if (perm !== "granted") throw new Error(perm === "denied" ? "Notifications are blocked. See the steps on this screen to allow them." : "Notifications weren't turned on.");
    const reg = await navigator.serviceWorker.ready;
    const key = await pushKey();
    let sub = await reg.pushManager.getSubscription();
    // A subscription made with a different key can't receive anything, so make a new one.
    if (sub && sub.options?.applicationServerKey && toB64(sub.options.applicationServerKey) !== key) { await sub.unsubscribe().catch(() => {}); sub = null; }
    sub ||= await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: fromB64(key) });
    const j = sub.toJSON();
    await q(sb.rpc("save_push", { p_endpoint: j.endpoint, p_p256dh: j.keys.p256dh, p_auth: j.keys.auth, p_device: deviceName() }));
    state.pushSaved = `${me.id}:${dayKey(new Date())}`; save();
  }
  // Stops notifications to this phone for the signed-in member. With unsubscribe, the phone forgets it too.
  async function forgetThisPhone(unsubscribe) {
    try {
      const sub = await Promise.race([currentSub(), new Promise((r) => setTimeout(() => r(null), 1500))]);
      if (!sub) return;
      await sb.rpc("forget_push", { p_endpoint: sub.endpoint });
      if (unsubscribe) await sub.unsubscribe();
      state.pushSaved = ""; save();
    } catch {}
  }
  // Once a day, re-save this phone so it keeps working (and moves to whoever is signed in now).
  async function keepPushFresh() {
    if (!me || pending() || !pushSupported() || Notification.permission !== "granted") return;
    if (state.pushSaved === `${me.id}:${dayKey(new Date())}`) return;
    try { await turnOnPush(false); } catch {}
  }
  // The dot on the bell: notifications not yet seen.
  let bellAt = 0;
  async function updateBell(force) {
    const dot = $("#bellDot");
    if (!me) { dot.hidden = true; return; }
    if (!force && Date.now() - bellAt < 30000) return;
    bellAt = Date.now();
    const { count, error } = await sb.from("notices").select("id", { count: "exact", head: true }).is("read_at", null);
    if (error) return;
    dot.hidden = !count;
    try { if (count) navigator.setAppBadge?.(count); else navigator.clearAppBadge?.(); } catch {}
  }
  // A tapped notification opens the app at the right screen.
  if ("serviceWorker" in navigator) navigator.serviceWorker.addEventListener("message", (e) => { if (e.data && "go" in e.data) { go(e.data.go || "events"); updateBell(true); } });
  document.addEventListener("visibilitychange", () => document.visibilityState === "visible" && updateBell());
  // Asks members once (then every few days until they decide) to turn notifications on.
  const PUSH_LATER = "homelands-push-later";
  function offerPush() {
    if (!me || pending() || !pushSupported() || Notification.permission !== "default" || !$("#modal").hidden) return;
    try { if (Date.now() < Number(localStorage.getItem(PUSH_LATER) || 0)) return; } catch {}
    const later = () => { try { localStorage.setItem(PUSH_LATER, String(Date.now() + 3 * 864e5)); } catch {} closeModal(); };
    modal(`<button class="close" aria-label="Close">×</button>
      <div class="row" style="gap:14px"><img src="images/icon-192.png" alt="" style="width:56px;height:56px;border-radius:12px"><h2 style="margin:0">Turn on notifications?</h2></div>
      <p style="line-height:1.5;margin-top:12px">Get a buzz on your phone for announcements, new events, when football booking opens and reminders before games, just like WhatsApp. You can choose what you get under the bell 🔔 at the top.</p>
      <div class="form-actions"><button class="btn solid block" id="pushGo">Turn on notifications</button>
        <button class="btn block" id="pushLater" style="margin-top:10px">Not now</button></div>`, (m) => {
      $("#pushLater", m).onclick = later;
      $(".close", m).onclick = later;
      $("#pushGo", m).onclick = () => {
        const b = $("#pushGo", m); b.disabled = true;
        turnOnPush().then(() => { closeModal(); toast("Notifications are on ✓"); }).catch((e) => { later(); fail(e); });
      };
    });
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
    markSeen();
    if (!AUTH_ERROR && !RECOVERY) askAgreement();
    updateBell(true); keepPushFresh(); setTimeout(offerPush, 6000);
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
      <p class="muted" style="margin-top:12px">Open the app in one tap, like any other app on your phone${isIOS() ? ". On an iPhone this is also how you get notifications" : ""}.</p>
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
