// Community app – all screens. Content lives in data.js.
(() => {
  const D = APP_DATA;
  const C = D.community;
  const $ = (sel, el = document) => el.querySelector(sel);
  const view = $("#view");

  // ---------- saved state (stored on this device) ----------
  const STORE_KEY = "community-app-v1";
  const state = Object.assign(
    { posts: [], likes: {}, reactions: {}, comments: {}, votes: {}, rsvps: {}, bookings: [], requests: [], messages: [], seenNotes: 0 },
    load()
  );
  function load() { try { return JSON.parse(localStorage.getItem(STORE_KEY)) || {}; } catch { return {}; } }
  function save() { try { localStorage.setItem(STORE_KEY, JSON.stringify(state)); } catch {} }

  // ---------- helpers ----------
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const bold = (s) => esc(s).replace(/\*\*(.+?)\*\*/g, "<b>$1</b>");
  const MONTHS = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
  const MONTHS_LONG = ["January","February","March","April","May","June","July","August","September","October","November","December"];
  const parseDay = (s) => { const [y, m, d] = s.split("-").map(Number); return new Date(y, m - 1, d); };
  const dayKey = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  const today = () => { const d = new Date(); d.setHours(0, 0, 0, 0); return d; };
  const money = (n) => "£" + Number(n).toFixed(2);
  function ago(dateStr) {
    const days = Math.floor((Date.now() - new Date(dateStr).getTime()) / 864e5);
    if (days < 1) return "just now";
    if (days < 30) return `${days}d ago`;
    const mo = Math.floor(days / 30);
    return mo < 12 ? `${mo}mo ago` : `${Math.floor(mo / 12)}y ago`;
  }
  function agoLong(dateStr) {
    const a = ago(dateStr);
    return a.replace(/(\d+)mo ago/, (_, n) => `${n} month${n > 1 ? "s" : ""} ago`).replace(/(\d+)d ago/, (_, n) => `${n} day${n > 1 ? "s" : ""} ago`);
  }
  function toast(msg) {
    const t = $("#toast"); t.textContent = msg; t.hidden = false;
    clearTimeout(toast.t); toast.t = setTimeout(() => (t.hidden = true), 2200);
  }
  function modal(html, onOpen) {
    $("#modalBody").innerHTML = html; $("#modal").hidden = false;
    onOpen && onOpen($("#modalBody"));
  }
  const closeModal = () => ($("#modal").hidden = true);
  $("#modal").addEventListener("click", (e) => { if (e.target.id === "modal" || e.target.classList.contains("close")) closeModal(); });

  async function share(title, text) {
    const url = location.href.split("#")[0];
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
    eye: '<svg viewBox="0 0 24 24" class="fill" style="width:20px;height:20px;vertical-align:-4px"><path d="M12 5C6 5 2 12 2 12s4 7 10 7 10-7 10-7-4-7-10-7zm0 11a4 4 0 1 1 0-8 4 4 0 0 1 0 8z"/></svg>',
    camera: '<svg viewBox="0 0 24 24" class="fill"><path d="M9 4l-2 2H3v14h18V6h-4l-2-2zm3 13a4 4 0 1 1 0-8 4 4 0 0 1 0 8z"/></svg>',
    video: '<svg viewBox="0 0 24 24" class="fill"><path d="M3 6h12v12H3zM16 10l5-3v10l-5-3z"/></svg>',
    poll: '<svg viewBox="0 0 24 24"><path d="M6 20V12M12 20V4M18 20v-6"/></svg>',
    filter: '<svg viewBox="0 0 24 24"><path d="M3 6h18M6 12h12M10 18h4"/></svg>',
    cal: '<svg viewBox="0 0 24 24"><rect x="3" y="5" width="18" height="16" rx="2"/><path d="M8 3v4M16 3v4M8 12h.01M12 12h.01M16 12h.01M8 16h.01M12 16h.01"/></svg>',
    star: '<svg viewBox="0 0 24 24"><path d="M12 3l2.8 5.8 6.2.9-4.5 4.4 1 6.3L12 17.5 6.5 20.4l1-6.3L3 9.7l6.2-.9z"/></svg>',
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
  const TABS = ["home", "events", "groups", "schedule", "more"];
  const ROUTES = { home, events, groups, grouplist, schedule, more, services, counselling, messages, notifications };
  const PARENT = { grouplist: "groups", services: "more", counselling: "more", messages: null, notifications: null };
  let lastTab = "home";

  function go(route) { location.hash = route; }
  function render() {
    const route = (location.hash.slice(1) || "home");
    const fn = ROUTES[route] || home;
    if (TABS.includes(route)) lastTab = route;
    const active = TABS.includes(route) ? route : (PARENT[route] || lastTab);
    document.querySelectorAll("#tabbar button").forEach((b) => b.classList.toggle("active", b.dataset.tab === active));
    $("#backBtn").hidden = TABS.includes(route);
    $("#topbar").classList.toggle("clear", route === "home");
    view.classList.toggle("no-top", route === "home");
    view.innerHTML = "";
    fn(view);
    window.scrollTo(0, 0);
    $("#bellDot").hidden = state.seenNotes >= D.announcements.length;
  }
  window.addEventListener("hashchange", render);
  document.querySelectorAll("#tabbar button").forEach((b) => b.addEventListener("click", () => go(b.dataset.tab)));
  document.querySelectorAll("[data-go]").forEach((b) => b.addEventListener("click", () => go(b.dataset.go)));
  $("#backBtn").addEventListener("click", () => (history.length > 1 ? history.back() : go("home")));

  // ---------- HOME ----------
  function home(el) {
    const socials = Object.entries(C.socials).filter(([, url]) => url)
      .map(([k, url]) => `<a href="${esc(url)}" target="_blank" rel="noopener" aria-label="${k}">${SOCIAL[k] || ""}</a>`).join("");
    const notes = D.announcements.map((a) => `
      <div class="card announce">
        <div class="row"><div class="avatar" style="width:52px;height:52px;font-size:19px">${esc(D.admin.initials)}</div>
          <div><b style="font-size:19px">${esc(D.admin.name)}</b><div class="muted">${agoLong(a.date)}</div></div></div>
        <p>${bold(a.text)}</p>
      </div>`).join("");

    el.innerHTML = `
      <div class="hero"></div>
      <div class="hero-card">
        <div class="logo"></div>
        <h1>${esc(C.name)}</h1>
        <div>${esc(C.tagline)}</div>
        <div class="meta">
          <div class="avatar" style="width:26px;height:26px;font-size:11px">👤</div>
          <span>${C.members} Member${C.members === 1 ? "" : "s"}</span><span class="sep">|</span>
          <a href="#" id="info">General Info ›</a>
        </div>
        <div class="actions">
          <button class="btn" id="invite">${ICON.share} Invite</button>
          <a class="btn solid" href="${esc(C.website)}" target="_blank" rel="noopener">Open URL</a>
        </div>
        <p class="desc">${esc(C.description)}</p>
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
        ${notes}
      </div>`;
    $("#invite", el).onclick = () => share(C.name, `Join ${C.name} – ${C.tagline}`);
    $("#info", el).onclick = (e) => { e.preventDefault(); modal(`<h2>General Info</h2><p style="line-height:1.5">${esc(C.generalInfo)}</p>`); };
  }

  // ---------- EVENTS ----------
  function events(el) {
    const now = new Date();
    const list = [...D.events].sort((a, b) => {
      const pa = eventEnd(a) < now, pb = eventEnd(b) < now;
      if (pa !== pb) return pa ? 1 : -1;
      return pa ? parseDay(b.day) - parseDay(a.day) : parseDay(a.day) - parseDay(b.day);
    });
    el.innerHTML = `<div class="events">${list.map(eventCard).join("") || '<div class="empty"><h2>No events yet</h2></div>'}</div>`;
    el.querySelectorAll("[data-invite]").forEach((b) => (b.onclick = () => {
      const ev = D.events.find((x) => x.id === b.dataset.invite); share(ev.title, `${ev.title} – ${fmtEvent(ev)}`);
    }));
    el.querySelectorAll("[data-rsvp]").forEach((b) => (b.onclick = () => {
      const id = b.dataset.rsvp; state.rsvps[id] = !state.rsvps[id]; save();
      toast(state.rsvps[id] ? "You're going!" : "RSVP removed"); render();
    }));
    el.querySelectorAll("[data-event]").forEach((b) => (b.onclick = () => {
      const ev = D.events.find((x) => x.id === b.dataset.event);
      modal(`<h2>${esc(ev.title)}</h2><p class="muted">${fmtEvent(ev)}<br>${esc(ev.location)}</p><p style="line-height:1.5">${esc(ev.details || "")}</p>`);
    }));
  }
  function eventEnd(ev) { const d = parseDay(ev.day); const [h, m] = ev.time.split(":").map(Number); d.setHours(h + 3, m); return d; }
  function fmtEvent(ev) { const d = parseDay(ev.day); return `${MONTHS[d.getMonth()]} ${d.getDate()}, ${d.getFullYear()} | ${ev.time.replace(/^0(\d)/, "$1")}`; }
  function eventCard(ev) {
    const d = parseDay(ev.day);
    const past = eventEnd(ev) < new Date();
    const img = ev.image === "stage" ? '<div class="event-img">🎭🎶</div>' : ev.image ? `<img src="${esc(ev.image)}" style="width:100%;height:140px;object-fit:cover;display:block">` : "";
    let foot;
    if (past) foot = '<button class="off" style="color:var(--muted)" disabled>Event has ended</button>';
    else foot = `<button data-invite="${ev.id}">${ICON.share.replace('viewBox', 'style="width:20px;height:20px" viewBox')} Invite</button>` +
      (ev.rsvpOpen ? `<button class="go" data-rsvp="${ev.id}">${state.rsvps[ev.id] ? "Going ✓" : "RSVP"}</button>` : '<button class="off" disabled>RSVP Closed</button>');
    return `<article class="card">
      ${img}
      <div class="event-body" data-event="${ev.id}" style="cursor:pointer">
        <div class="event-date"><div class="d">${d.getDate()}</div><div class="m">${MONTHS[d.getMonth()]}</div></div>
        <div><h2>${esc(ev.title)}</h2><p>${fmtEvent(ev)}</p><p>${esc(ev.location)}</p>
          ${ev.multipleDates ? `<p>${ICON.smallcal} Multiple dates</p>` : ""}</div>
      </div>
      <div class="event-foot">${foot}</div>
    </article>`;
  }

  // ---------- GROUPS ----------
  const groupName = (id) => (D.groups.find((g) => g.id === id) || {}).name || "Group";
  function allPosts() { return [...state.posts, ...D.posts]; }

  function groups(el, filter = "") {
    const posts = allPosts().filter((p) => !filter || (p.text + groupName(p.group)).toLowerCase().includes(filter.toLowerCase()));
    el.innerHTML = `
      <div class="subhead"><h2>Groups feed</h2><a href="#grouplist">Group list</a>
        <span style="width:1px;height:28px;background:var(--line)"></span>
        <button id="searchBtn" style="color:var(--green)">${ICON.search}</button></div>
      ${filter ? `<div class="pad" style="padding-top:10px">Results for “${esc(filter)}” · <a href="#" id="clear">clear</a></div>` : ""}
      <div class="composer">
        <div class="row"><div class="avatar" style="width:46px;height:46px">${esc(D.admin.initials)}</div>
          <button class="share" data-compose="text">Share something...</button></div>
        <div class="tools">
          <button data-compose="photo">${ICON.camera} Photo</button>
          <button data-compose="video">${ICON.video} Video</button>
          <button data-compose="poll">${ICON.poll} Poll</button>
        </div>
      </div>
      <div id="feed">${posts.map(postHtml).join("") || '<div class="empty"><h2>No posts found</h2></div>'}</div>`;
    el.querySelectorAll("[data-compose]").forEach((b) => (b.onclick = () => compose(b.dataset.compose)));
    $("#searchBtn", el).onclick = () => {
      modal(`<h2>Search posts</h2><input id="q" placeholder="Search..." value="${esc(filter)}"><div class="form-actions"><button class="btn solid block" id="go">Search</button></div>`, (m) => {
        const q = $("#q", m); q.focus();
        const run = () => { closeModal(); view.innerHTML = ""; groups(view, q.value.trim()); };
        $("#go", m).onclick = run; q.onkeydown = (e) => e.key === "Enter" && run();
      });
    };
    const clr = $("#clear", el); if (clr) clr.onclick = (e) => { e.preventDefault(); render(); };
    wirePosts(el);
  }

  function postHtml(p) {
    const liked = !!state.likes[p.id];
    const likes = (p.likes || 0) + (liked ? 1 : 0);
    const reacts = state.reactions[p.id] || [];
    const comments = state.comments[p.id] || [];
    let poll = "";
    if (p.poll) {
      const voted = state.votes[p.id];
      const counts = p.poll.map((_, i) => (voted === i ? 1 : 0));
      const total = counts.reduce((a, b) => a + b, 0) || 1;
      poll = p.poll.map((o, i) => `<button class="poll-opt" data-vote="${p.id}" data-i="${i}">
        ${voted !== undefined ? `<div class="bar" style="width:${(counts[i] / total) * 100}%"></div>` : ""}
        <span>${esc(o)}${voted === i ? " ✓" : ""}</span></button>`).join("");
    }
    return `<article class="post" data-post="${p.id}">
      <div class="head"><div class="avatar" style="width:46px;height:46px">${esc(D.admin.initials)}</div>
        <div class="who"><b>${esc(p.author || D.admin.name)}</b> posted in the group <b>${esc(groupName(p.group))}</b>.<div class="muted">${ago(p.date)}</div></div>
        <button data-menu="${p.id}" style="font-size:24px;font-weight:900;letter-spacing:1px">•••</button></div>
      <div class="text">${bold(p.text)}</div>
      ${p.image ? `<img src="${p.image}" alt="">` : ""}
      ${p.video ? `<video src="${p.video}" controls style="width:100%;border-radius:8px;margin-bottom:12px"></video>` : ""}
      ${poll}
      <div class="reactions">
        <button class="pill ${liked ? "on" : ""}" data-like="${p.id}">${ICON.thumb} ${likes}</button>
        ${reacts.map((r) => `<span class="pill">${r}</span>`).join("")}
        <button class="pill" data-react="${p.id}">☺+</button>
      </div>
      <div class="views">${ICON.eye} ${p.views || 0} views</div>
      <div class="post-foot"><button data-comment="${p.id}">Comment${comments.length ? ` (${comments.length})` : ""}</button><button data-share="${p.id}">Share</button></div>
      ${comments.length ? `<div class="comments">${comments.map((c) => `<div class="comment"><b>${esc(c.name)}</b> ${esc(c.text)}</div>`).join("")}</div>` : ""}
    </article>`;
  }

  function wirePosts(el) {
    const find = (id) => allPosts().find((p) => p.id === id);
    el.querySelectorAll("[data-like]").forEach((b) => (b.onclick = () => { const id = b.dataset.like; state.likes[id] = !state.likes[id]; save(); refreshPost(id); }));
    el.querySelectorAll("[data-react]").forEach((b) => (b.onclick = () => {
      const id = b.dataset.react;
      modal(`<h2>Add a reaction</h2><div style="font-size:34px;display:flex;gap:14px;flex-wrap:wrap">${["❤️","😂","👏","🙏","🔥","🎉","😮","😢"].map((e) => `<button data-e="${e}">${e}</button>`).join("")}</div>`, (m) => {
        m.querySelectorAll("[data-e]").forEach((x) => (x.onclick = () => { (state.reactions[id] ||= []).push(x.dataset.e); save(); closeModal(); refreshPost(id); }));
      });
    }));
    el.querySelectorAll("[data-comment]").forEach((b) => (b.onclick = () => {
      const id = b.dataset.comment;
      modal(`<h2>Write a comment</h2><label>Your name</label><input id="n" value="${esc(localStorage.getItem("name") || "")}">
        <label>Comment</label><textarea id="t"></textarea><div class="form-actions"><button class="btn solid block" id="send">Post comment</button></div>`, (m) => {
        $("#t", m).focus();
        $("#send", m).onclick = () => {
          const name = $("#n", m).value.trim() || "Guest", text = $("#t", m).value.trim();
          if (!text) return;
          try { localStorage.setItem("name", name); } catch {}
          (state.comments[id] ||= []).push({ name, text }); save(); closeModal(); refreshPost(id);
        };
      });
    }));
    el.querySelectorAll("[data-share]").forEach((b) => (b.onclick = () => { const p = find(b.dataset.share); share(C.name, p.text.replace(/\*\*/g, "").slice(0, 120)); }));
    el.querySelectorAll("[data-vote]").forEach((b) => (b.onclick = () => { state.votes[b.dataset.vote] = Number(b.dataset.i); save(); refreshPost(b.dataset.vote); }));
    el.querySelectorAll("[data-menu]").forEach((b) => (b.onclick = () => {
      const id = b.dataset.menu, mine = state.posts.some((p) => p.id === id);
      modal(`<h2>Post options</h2>
        <button class="btn block" id="copy">Copy text</button>
        ${mine ? '<div style="height:10px"></div><button class="btn block" id="del" style="color:#c0392b;border-color:#c0392b">Delete post</button>' : ""}`, (m) => {
        $("#copy", m).onclick = async () => { try { await navigator.clipboard.writeText(find(id).text.replace(/\*\*/g, "")); toast("Copied"); } catch {} closeModal(); };
        const del = $("#del", m); if (del) del.onclick = () => { state.posts = state.posts.filter((p) => p.id !== id); save(); closeModal(); render(); };
      });
    }));
  }
  function refreshPost(id) {
    const old = view.querySelector(`[data-post="${id}"]`); if (!old) return;
    const p = allPosts().find((x) => x.id === id);
    const tmp = document.createElement("div"); tmp.innerHTML = postHtml(p);
    const fresh = tmp.firstElementChild; old.replaceWith(fresh); wirePosts(fresh);
  }

  function compose(kind) {
    const groupOpts = D.groups.map((g) => `<option value="${g.id}">${esc(g.name)}</option>`).join("");
    const extra = {
      photo: '<label>Photo</label><input type="file" id="file" accept="image/*">',
      video: '<label>Video (small clips only on this device)</label><input type="file" id="file" accept="video/*">',
      poll: '<label>Options (one per line)</label><textarea id="opts" placeholder="Yes\nNo\nMaybe"></textarea>',
      text: "",
    }[kind];
    modal(`<h2>${kind === "poll" ? "Create a poll" : "Share something"}</h2>
      <label>Group</label><select id="g">${groupOpts}</select>
      <label>${kind === "poll" ? "Question" : "Message"}</label><textarea id="t"></textarea>
      ${extra}
      <div class="form-actions"><button class="btn solid block" id="post">Post</button></div>`, (m) => {
      $("#post", m).onclick = async () => {
        const text = $("#t", m).value.trim();
        const post = { id: "u" + Date.now(), group: $("#g", m).value, date: new Date().toISOString(), text, views: 0 };
        const file = $("#file", m)?.files?.[0];
        if (file) {
          if (file.size > 4e6) return toast("File too big for this demo (max 4MB)");
          const data = await new Promise((r) => { const fr = new FileReader(); fr.onload = () => r(fr.result); fr.readAsDataURL(file); });
          post[kind === "video" ? "video" : "image"] = kind === "photo" ? await shrink(data) : data;
        }
        if (kind === "poll") {
          post.poll = $("#opts", m).value.split("\n").map((s) => s.trim()).filter(Boolean);
          if (post.poll.length < 2) return toast("Add at least 2 options");
        }
        if (!text && !file) return toast("Write something first");
        state.posts.unshift(post); save(); closeModal(); render(); toast("Posted");
      };
    });
  }
  // Downscale photos so they fit in device storage
  function shrink(dataUrl) {
    return new Promise((res) => {
      const img = new Image();
      img.onload = () => {
        const s = Math.min(1, 1000 / Math.max(img.width, img.height));
        const c = document.createElement("canvas"); c.width = img.width * s; c.height = img.height * s;
        c.getContext("2d").drawImage(img, 0, 0, c.width, c.height); res(c.toDataURL("image/jpeg", 0.8));
      };
      img.src = dataUrl;
    });
  }

  function grouplist(el) {
    el.innerHTML = `<div class="subhead"><h2>Group list</h2></div>` + D.groups.map((g) => {
      const n = allPosts().filter((p) => p.group === g.id).length;
      return `<div class="group-row"><div class="avatar" style="width:52px;height:52px;background:var(--green)">${esc(g.name.split(" ").map((w) => w[0]).join("").slice(0, 2))}</div>
        <div style="flex:1"><b style="font-size:18px">${esc(g.name)}</b><div class="muted">${esc(g.about)} · ${n} post${n === 1 ? "" : "s"}</div></div></div>`;
    }).join("");
  }

  // ---------- SCHEDULE ----------
  let selDay = today();
  function schedule(el) {
    const monday = new Date(selDay); monday.setDate(selDay.getDate() - ((selDay.getDay() + 6) % 7));
    const days = [...Array(7)].map((_, i) => { const d = new Date(monday); d.setDate(monday.getDate() + i); return d; });
    const t = today();
    const sessionsOn = (d) => D.sessions.filter((s) => s.day === dayKey(d));
    const todays = sessionsOn(selDay);
    el.innerHTML = `
      <div class="cal">
        <div class="cal-head"><button id="prev">${ICON.left}</button><b>${MONTHS_LONG[monday.getMonth()]} ${monday.getFullYear()} ⌄</b><button id="next" style="transform:scaleX(-1)">${ICON.left}</button></div>
        <div class="week">
          ${["Mon","Tue","Wed","Thu","Fri","Sat","Sun"].map((n) => `<div class="dn">${n}</div>`).join("")}
          ${days.map((d) => `<div><button data-day="${dayKey(d)}" class="${d >= t ? "future" : ""} ${dayKey(d) === dayKey(selDay) ? "sel" : ""} ${sessionsOn(d).length ? "has" : ""}">${d.getDate()}</button></div>`).join("")}
        </div>
      </div>
      <div class="filters">${ICON.filter} Filters</div>
      ${todays.length ? todays.map((s, i) => `<div class="card session"><div><b style="font-size:18px">${esc(s.title)}</b><div class="muted">${esc(s.time)} · ${esc(s.length || "")} · ${esc(s.place || "")}</div></div>
          <button class="btn small" data-book-session="${i}">Book</button></div>`).join("")
        : `<div class="empty"><h2>No Upcoming Sessions</h2><p style="font-size:19px;line-height:1.5">${nextSession() ? "There are no sessions on this day." : "There are no available sessions for the next 6 months."}</p>
          <button class="btn solid" id="nextAvail" style="margin-top:20px">Check Next Availability</button></div>`}`;
    const move = (n) => { selDay = new Date(selDay); selDay.setDate(selDay.getDate() + n); render(); };
    $("#prev", el).onclick = () => move(-7);
    $("#next", el).onclick = () => move(7);
    el.querySelectorAll("[data-day]").forEach((b) => (b.onclick = () => { selDay = parseDay(b.dataset.day); render(); }));
    const na = $("#nextAvail", el);
    if (na) na.onclick = () => { const s = nextSession(); if (s) { selDay = parseDay(s.day); render(); } else toast("Nothing scheduled yet"); };
    el.querySelectorAll("[data-book-session]").forEach((b) => (b.onclick = () => {
      const s = todays[Number(b.dataset.bookSession)]; bookForm(`${s.title} – ${s.day} ${s.time}`);
    }));
  }
  function nextSession() {
    const from = dayKey(today()), limit = new Date(); limit.setMonth(limit.getMonth() + 6);
    return D.sessions.filter((s) => s.day >= from && parseDay(s.day) <= limit).sort((a, b) => a.day.localeCompare(b.day))[0];
  }

  // ---------- MORE ----------
  function more(el) {
    el.innerHTML = `
      <button class="menu-row" data-to="services">${ICON.cal}<span>Services ${ICON.chev}</span></button>
      <button class="menu-row" data-to="counselling">${ICON.star}<span>Counselling ${ICON.chev}</span></button>
      ${state.bookings.length ? `<div class="pad" style="margin-top:30px"><h2>My bookings</h2>${state.bookings.map((b) => `<div class="list-row"><div><b>${esc(b.what)}</b><span class="muted">${esc(b.date)} · ${esc(b.name)}</span></div></div>`).join("")}</div>` : ""}`;
    el.querySelectorAll("[data-to]").forEach((b) => (b.onclick = () => go(b.dataset.to)));
  }

  function services(el, q = "") {
    const list = D.services.filter((s) => s.title.toLowerCase().includes(q.toLowerCase()));
    el.innerHTML = `
      <div class="search">${ICON.search}<input id="q" placeholder="Search for a service" value="${esc(q)}"></div>
      <div id="list">${list.map((s) => `
        <div class="service"><div class="thumb">${s.image ? `<img src="${esc(s.image)}" style="width:100%;height:100%;object-fit:cover;border-radius:6px">` : s.emoji || ""}</div>
          <div class="info"><b>${esc(s.title)}</b><div class="muted">${esc(s.place)}</div><div class="muted">${money(s.price)}</div></div>
          <button class="btn small" data-book="${s.id}">Book</button></div>`).join("") || '<div class="empty"><h2>No services found</h2></div>'}</div>`;
    const input = $("#q", el);
    input.oninput = () => { const pos = input.selectionStart; services(el, input.value); const n = $("#q", el); n.focus(); n.setSelectionRange(pos, pos); };
    el.querySelectorAll("[data-book]").forEach((b) => (b.onclick = () => {
      const s = D.services.find((x) => x.id === b.dataset.book); bookForm(`${s.title} (${money(s.price)})`);
    }));
  }

  function bookForm(what) {
    modal(`<h2>Book: ${esc(what)}</h2>
      <label>Your name</label><input id="n" value="${esc(localStorage.getItem("name") || "")}">
      <label>Phone or email</label><input id="c">
      <label>Preferred date</label><input id="d" type="date" min="${dayKey(today())}">
      <div class="form-actions"><button class="btn solid block" id="ok">Request booking</button></div>
      <p class="muted" style="font-size:14px">We'll contact you to confirm. Payment is taken on the day.</p>`, (m) => {
      $("#ok", m).onclick = () => {
        const name = $("#n", m).value.trim(), contact = $("#c", m).value.trim(), date = $("#d", m).value;
        if (!name || !contact || !date) return toast("Please fill in every box");
        state.bookings.push({ what, name, contact, date }); save(); closeModal(); toast("Booking requested ✓");
        if (location.hash === "#more") render();
      };
    });
  }

  function counselling(el) {
    el.innerHTML = `<div class="pad" style="padding-top:24px">
      <h1>Counselling</h1><p style="line-height:1.6;font-size:17px">${esc(D.counselling.intro)}</p>
      <label>Your name (or leave blank to stay anonymous)</label><input id="n">
      <label>How can we contact you?</label><input id="c" placeholder="Phone or email">
      <label>Anything you'd like us to know (optional)</label><textarea id="t"></textarea>
      <div class="form-actions"><button class="btn solid block" id="ok">Send request</button></div>
      <p class="muted" style="font-size:14px">Prefer to talk now? Call <a href="tel:${esc(C.phone)}">${esc(C.phone)}</a>.</p></div>`;
    $("#ok", el).onclick = () => {
      const contact = $("#c", el).value.trim();
      if (!contact) return toast("Please add a way to contact you");
      state.requests.push({ name: $("#n", el).value.trim(), contact, note: $("#t", el).value.trim(), at: new Date().toISOString() });
      save(); toast("Request sent ✓"); go("more");
    };
  }

  // ---------- header screens ----------
  function messages(el) {
    el.innerHTML = `<div class="pad" style="padding-top:24px"><h1>Messages</h1>
      <p class="muted">Chat with ${esc(C.contactName)}.</p>
      <div id="thread">${state.messages.map((m) => `<div class="comment" style="margin-left:40px;background:#cfe3dd">${esc(m)}</div>`).join("")}</div>
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

  render();
  if ("serviceWorker" in navigator && location.protocol.startsWith("http")) navigator.serviceWorker.register("sw.js").catch(() => {});
})();
