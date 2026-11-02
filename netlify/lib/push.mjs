// Phone notifications. The database writes each notification to the notices table (see
// supabase/add-phone-notifications.sql) and calls /.netlify/functions/push, which sends the
// waiting ones to every phone each member has turned notifications on for.
// The VAPID keys are made on the first call and kept in push_settings, which only the server can read,
// so there is nothing to set up in Netlify beyond SUPABASE_SECRET_KEY.
import { db } from "./square.mjs";
import { generateVapidKeys, sendPush } from "./webpush.mjs";

let settings = null;
export async function pushSettings() {
  if (settings?.public_key) return settings;
  let [row] = await db("push_settings?id=eq.1&select=*");
  if (!row) throw new Error("Run add-phone-notifications.sql first.");
  if (!row.public_key) {
    const k = generateVapidKeys();
    // Only fills in empty keys, so two calls at once can't end up with different keys.
    await db("push_settings?id=eq.1&public_key=is.null", { method: "PATCH", body: JSON.stringify({ public_key: k.publicKey, private_key: k.privateKey }) });
    [row] = await db("push_settings?id=eq.1&select=*");
  }
  return (settings = row);
}

// Sends everything waiting, in batches, until it runs out or time is nearly up (Netlify allows 10 seconds).
export async function sendWaiting(budgetMs = 8000) {
  const start = Date.now();
  const s = await pushSettings();
  const vapid = { publicKey: s.public_key, privateKey: s.private_key, subject: s.subject || "https://br3-mens.ourhomelands.co.uk" };
  let sent = 0, gone = 0, failed = 0;
  while (Date.now() - start < budgetMs) {
    const batch = await db("rpc/claim_push_batch", { method: "POST", body: JSON.stringify({ p_limit: 200 }) });
    if (!batch?.length) break;
    const dead = [];
    for (let i = 0; i < batch.length; i += 25) {
      await Promise.all(batch.slice(i, i + 25).map(async (r) => {
        try {
          const status = await sendPush(r, { title: r.title, body: r.body, url: r.url, tag: r.tag }, vapid);
          if (status === 404 || status === 410) { dead.push(r.endpoint); gone++; }
          else if (status >= 200 && status < 300) sent++;
          else { failed++; console.log("Push refused", status, new URL(r.endpoint).host); }
        } catch (e) { failed++; console.log("Push failed", e.message); }
      }));
    }
    if (dead.length) await db("rpc/forget_push_endpoints", { method: "POST", body: JSON.stringify({ p_endpoints: dead }) }).catch(() => {});
  }
  return { sent, gone, failed };
}
