// POST { code }            -> { url } of a Square checkout page for that booking
// POST { code, confirm }   -> { paid } after checking with Square (used when someone returns from paying)
import { json, missingSettings, square, getLocationId, bookingBy, confirmBooking, db } from "../lib/square.mjs";

export default async (req) => {
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  const missing = missingSettings();
  if (missing.length) return json({ error: "Card payments aren't switched on yet." }, 503);

  const { code, confirm } = await req.json().catch(() => ({}));
  if (!code) return json({ error: "Missing booking code." }, 400);
  try {
    const booking = await bookingBy("code", String(code).trim().toUpperCase());
    if (!booking) return json({ error: "Booking not found." }, 404);

    if (confirm || booking.paid) return json({ paid: await confirmBooking(booking) });
    if (booking.status !== "booked") return json({ error: "This booking is on the waitlist, so there's nothing to pay yet." }, 400);
    const pence = Math.round(Number(booking.amount) * 100);
    if (!(pence > 0)) return json({ error: "There's nothing to pay for this booking." }, 400);
    // If they started paying earlier and finished, don't charge twice.
    if (booking.square_order_id && (await confirmBooking(booking))) return json({ paid: true });

    const ev = booking.events || {};
    const when = ev.day ? new Date(`${ev.day}T12:00:00Z`).toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short", timeZone: "Europe/London" }) : "";
    const name = ev.kind === "football" ? `Friday Football ${when} (${booking.charge === "kitty" ? "£15 kitty" : "pay as you play"})` : `${ev.title} ${when}`;
    const origin = new URL(req.url).origin;
    const back = ev.kind === "football" ? "football" : "account";
    const { payment_link: link } = await square("/v2/online-checkout/payment-links", {
      method: "POST",
      body: JSON.stringify({
        idempotency_key: crypto.randomUUID(),
        quick_pay: { name: name.slice(0, 255), price_money: { amount: pence, currency: "GBP" }, location_id: await getLocationId() },
        checkout_options: {
          redirect_url: `${origin}/?paid=${encodeURIComponent(booking.code)}#${back}`,
          accepted_payment_methods: { apple_pay: true, google_pay: true },
        },
        payment_note: `${booking.display_name} · booking ${booking.code}`,
      }),
    });
    await db(`bookings?id=eq.${booking.id}`, { method: "PATCH", body: JSON.stringify({ square_order_id: link.order_id }) });
    return json({ url: link.url });
  } catch (e) {
    return json({ error: e.message || "Something went wrong with the payment." }, 500);
  }
};
