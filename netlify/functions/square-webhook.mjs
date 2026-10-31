// Square calls this when a payment changes, so bookings are marked paid even if
// someone closes the page before coming back to the app. Subscribe to payment.created and payment.updated.
// Every payment is also copied into the app for the Square check.
import { createHmac, timingSafeEqual } from "node:crypto";
import { json, bookingBy, recordPayment, applyPayment } from "../lib/square.mjs";

export default async (req) => {
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  const raw = await req.text();
  const key = process.env.SQUARE_WEBHOOK_SIGNATURE_KEY;
  if (!key) return json({ error: "Webhook not set up." }, 503);
  const url = process.env.SQUARE_WEBHOOK_URL || req.url;
  const expected = createHmac("sha256", key).update(url + raw).digest("base64");
  const given = req.headers.get("x-square-hmacsha256-signature") || "";
  if (given.length !== expected.length || !timingSafeEqual(Buffer.from(given), Buffer.from(expected))) return json({ error: "Bad signature." }, 401);

  const payment = JSON.parse(raw)?.data?.object?.payment;
  if (!payment?.id) return json({ ok: true });
  try {
    const booking = payment.order_id ? await bookingBy("square_order_id", payment.order_id) : null;
    if (booking) await recordPayment(booking, payment);
    // Every payment is kept for the Square check; a subscription payment goes into the Family Events fund.
    // If the database isn't ready for that yet, a booking's payment is still recorded above.
    const kept = applyPayment(payment, booking);
    if (booking) await kept.catch(() => {}); else await kept;
    return json({ ok: true });
  } catch (e) {
    return json({ error: e.message }, 500); // Square retries later
  }
};
