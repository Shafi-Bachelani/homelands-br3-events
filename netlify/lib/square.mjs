// Shared helpers for card payments: talks to Square and to the database with the server-only key.
// Settings live in Netlify environment variables, never in this repo:
//   SQUARE_ACCESS_TOKEN   from the Square developer app (Sandbox token while testing)
//   SQUARE_ENVIRONMENT    "sandbox" (default) or "production"
//   SQUARE_LOCATION_ID    optional; the first active Square location is used if missing
//   SUPABASE_SECRET_KEY   Supabase secret (service_role) key, so payments can be recorded
//   SQUARE_WEBHOOK_SIGNATURE_KEY  optional, from the Square webhook subscription

export const SUPABASE_URL = process.env.SUPABASE_URL || "https://nacooqfqrnfbmrtiqlxt.supabase.co";
const SQUARE_HOST = process.env.SQUARE_ENVIRONMENT === "production" ? "https://connect.squareup.com" : "https://connect.squareupsandbox.com";
const SQUARE_VERSION = "2024-10-17";

export const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

export function missingSettings() {
  return ["SQUARE_ACCESS_TOKEN", "SUPABASE_SECRET_KEY"].filter((k) => !process.env[k]);
}

export async function square(path, init = {}) {
  const res = await fetch(SQUARE_HOST + path, {
    ...init,
    headers: { Authorization: `Bearer ${process.env.SQUARE_ACCESS_TOKEN}`, "Square-Version": SQUARE_VERSION, "Content-Type": "application/json" },
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.errors?.[0]?.detail || `Square error ${res.status}`);
  return body;
}

let locationId = process.env.SQUARE_LOCATION_ID;
export async function getLocationId() {
  if (locationId) return locationId;
  const { locations = [] } = await square("/v2/locations");
  const loc = locations.find((l) => l.status === "ACTIVE" && l.currency === "GBP") || locations.find((l) => l.status === "ACTIVE");
  if (!loc) throw new Error("No active Square location found.");
  return (locationId = loc.id);
}

export async function db(path, init = {}) {
  const key = process.env.SUPABASE_SECRET_KEY;
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: key, "Content-Type": "application/json", Prefer: "return=representation",
      ...(key?.startsWith("eyJ") ? { Authorization: `Bearer ${key}` } : {}), // older service_role keys need this too
      ...(init.headers || {}),
    },
  });
  const body = await res.json().catch(() => null);
  if (!res.ok) throw new Error(body?.message || `Database error ${res.status}`);
  return body;
}

const BOOKING_FIELDS = "id,code,amount,credit_used,paid,method,status,charge,display_name,booked_by,pitch_link,created_at,square_order_id,card_fee,events(title,day,time,kind)";
export async function bookingBy(field, value) {
  const rows = await db(`bookings?${field}=eq.${encodeURIComponent(value)}&select=${BOOKING_FIELDS}`);
  return rows?.[0] || null;
}

// Records a completed Square payment against its booking. Safe to call more than once.
export async function recordPayment(booking, payment) {
  if (!payment || payment.status !== "COMPLETED") return false;
  const fee = (payment.processing_fee || []).reduce((t, f) => t + Number(f.amount_money?.amount || 0), 0) / 100;
  const update = { paid: true, method: "card" };
  if (fee > 0) update.card_fee = fee;
  if (booking.paid && booking.method === "card" && !(fee > 0)) return true;
  await db(`bookings?id=eq.${booking.id}`, { method: "PATCH", body: JSON.stringify(update) });
  return true;
}

// Asks Square whether this booking's checkout has been paid, and records it if so.
export async function confirmBooking(booking) {
  if (!booking.square_order_id) return booking.paid;
  const { order } = await square(`/v2/orders/${booking.square_order_id}`);
  const paymentId = order?.tenders?.find((t) => t.payment_id)?.payment_id;
  if (!paymentId) return booking.paid;
  const { payment } = await square(`/v2/payments/${paymentId}`);
  const paid = await recordPayment(booking, payment);
  await applyPayment(payment, booking).catch(() => {}); // for the Square check
  return paid || booking.paid;
}

// A friend's booking is shown as "Guest (Member)". Returns both names, or null for anyone else's booking.
export async function guestNames(booking) {
  // someone added at the pitch and sent a payment link by the organisers
  if (!booking.booked_by && booking.pitch_link) return { guest: booking.display_name, member: "the organisers" };
  if (!booking.booked_by) return null;
  const rows = await db(`profiles?id=eq.${booking.booked_by}&select=name`);
  const member = rows?.[0]?.name || (booking.display_name.match(/\(([^)]*)\)\s*$/) || [])[1] || "";
  const suffix = ` (${member})`;
  const guest = booking.display_name.endsWith(suffix) ? booking.display_name.slice(0, -suffix.length) : booking.display_name;
  return { guest, member };
}

// ---------- Square check: every payment, with what Square kept ----------

const pounds = (m) => Number(m?.amount || 0) / 100;
const feeOf = (payment) => (payment.processing_fee || []).reduce((t, f) => t + Number(f.amount_money?.amount || 0), 0) / 100;

// Which Square orders belong to a subscription. Cached in square_sub_orders, so Square is only
// asked about invoices the app hasn't seen yet.
export async function subscriptionLabel(orderId) {
  if (!orderId) return null;
  const hit = await db(`square_sub_orders?order_id=eq.${encodeURIComponent(orderId)}&select=label`);
  if (hit?.length) return hit[0].label;
  const known = new Set(((await db("square_sub_orders?select=invoice_id")) || []).map((r) => r.invoice_id));
  const subs = [];
  let cursor;
  do {
    const r = await square("/v2/subscriptions/search", { method: "POST", body: JSON.stringify({ cursor, limit: 100, query: { filter: { location_ids: [await getLocationId()] } } }) });
    subs.push(...(r.subscriptions || []));
    cursor = r.cursor;
  } while (cursor);
  let found = null;
  for (const s of subs) {
    const fresh = (s.invoice_ids || []).filter((id) => !known.has(id));
    if (!fresh.length) continue;
    let who = "";
    if (s.customer_id) {
      const { customer: c } = await square(`/v2/customers/${s.customer_id}`).catch(() => ({}));
      who = [c?.given_name, c?.family_name].filter(Boolean).join(" ") || c?.company_name || "";
    }
    const label = `Family Events subscription${who ? ` (${who})` : ""}`;
    const rows = [];
    for (const id of fresh) {
      const { invoice } = await square(`/v2/invoices/${id}`).catch(() => ({}));
      if (!invoice?.order_id) continue;
      rows.push({ order_id: invoice.order_id, invoice_id: id, subscription_id: s.id, label });
      if (invoice.order_id === orderId) found = label;
    }
    if (rows.length) await db("square_sub_orders", { method: "POST", headers: { Prefer: "resolution=merge-duplicates,return=minimal" }, body: JSON.stringify(rows) });
  }
  return found;
}

// Keeps the app's copy of a Square payment up to date. Subscription payments go into the
// Family Events fund (the database does that, once per payment, and again only for changes).
export async function applyPayment(payment, booking) {
  if (!payment?.id) return null;
  const sub = booking ? null : await subscriptionLabel(payment.order_id);
  const row = {
    id: payment.id,
    paid_at: payment.created_at,
    status: payment.status,
    gross: pounds(payment.total_money || payment.amount_money),
    fee: feeOf(payment),
    refunded: pounds(payment.refunded_money),
    order_id: payment.order_id || null,
    note: payment.note || "",
    source: payment.source_type || "",
    kind: booking ? "booking" : sub ? "subscription" : "other",
    booking_id: booking?.id || null,
    label: booking ? booking.display_name : sub || payment.note || "",
  };
  return db("rpc/apply_square_payment", { method: "POST", body: JSON.stringify({ p: row }) });
}

// The signed-in person, from the token the app sends. Only organisers and the admin get through.
export async function doorUser(req) {
  const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  if (!token) return null;
  const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: process.env.SUPABASE_SECRET_KEY, Authorization: `Bearer ${token}` } });
  if (!res.ok) return null;
  const user = await res.json().catch(() => null);
  if (!user?.id) return null;
  const rows = await db(`profiles?id=eq.${user.id}&select=id,role`);
  return ["organiser", "admin"].includes(rows?.[0]?.role) ? rows[0] : null;
}
