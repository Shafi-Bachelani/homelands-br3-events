// POST { from, to } (dates, YYYY-MM-DD) with the organiser's sign-in token
//   -> { checked, updated } after copying that period's Square payments into the app.
// The webhook already does this as each payment happens; this fills any gaps.
import { json, missingSettings, square, getLocationId, db, recordPayment, applyPayment, doorUser } from "../lib/square.mjs";

const BOOKING_FIELDS = "id,amount,credit_used,paid,method,display_name,square_order_id,card_fee";

export default async (req) => {
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  if (missingSettings().length) return json({ error: "Square isn't connected yet." }, 503);
  try {
    if (!(await doorUser(req))) return json({ error: "Only organisers can check Square." }, 403);
    const { from, to } = await req.json().catch(() => ({}));
    const day = (s) => (/^\d{4}-\d{2}-\d{2}$/.test(s || "") ? s : null);
    if (!day(from) || !day(to)) return json({ error: "Choose the dates to check." }, 400);
    const begin = new Date(`${from}T00:00:00Z`); begin.setUTCHours(begin.getUTCHours() - 1); // UK summer time starts an hour earlier
    const end = new Date(`${to}T23:59:59Z`);

    const payments = [];
    let cursor;
    do {
      const qs = new URLSearchParams({ begin_time: begin.toISOString(), end_time: end.toISOString(), location_id: await getLocationId(), sort_order: "ASC", limit: "100" });
      if (cursor) qs.set("cursor", cursor);
      const r = await square(`/v2/payments?${qs}`);
      payments.push(...(r.payments || []));
      cursor = r.cursor;
    } while (cursor && payments.length < 1000);

    // What the app already has, so unchanged payments are skipped.
    const ids = payments.map((p) => p.id);
    const have = new Map();
    for (let i = 0; i < ids.length; i += 100) {
      const rows = await db(`square_payments?id=in.(${ids.slice(i, i + 100).map(encodeURIComponent).join(",")})&select=id,status,fee,refunded,kind`);
      (rows || []).forEach((r) => have.set(r.id, r));
    }
    const orders = [...new Set(payments.map((p) => p.order_id).filter(Boolean))];
    const bookings = new Map();
    for (let i = 0; i < orders.length; i += 100) {
      const rows = await db(`bookings?square_order_id=in.(${orders.slice(i, i + 100).map(encodeURIComponent).join(",")})&select=${BOOKING_FIELDS}`);
      (rows || []).forEach((b) => bookings.set(b.square_order_id, b));
    }

    let updated = 0;
    for (const p of payments) {
      const b = p.order_id ? bookings.get(p.order_id) : null;
      const h = have.get(p.id);
      const fee = (p.processing_fee || []).reduce((t, f) => t + Number(f.amount_money?.amount || 0), 0) / 100;
      const same = h && h.status === p.status && Number(h.fee) === fee && Number(h.refunded) === Number(p.refunded_money?.amount || 0) / 100 && (h.kind === "booking") === !!b;
      if (same) continue;
      if (b) await recordPayment(b, p);
      await applyPayment(p, b);
      updated++;
    }
    return json({ checked: payments.length, updated });
  } catch (e) {
    return json({ error: e.message || "Couldn't reach Square." }, 500);
  }
};
