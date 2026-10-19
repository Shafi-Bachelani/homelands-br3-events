// POST { code }            -> { url } of a Square checkout page for that booking
// POST { code, confirm }   -> { paid } after checking with Square (used when someone returns from paying)
// POST { code, info }      -> what a guest's payment link page shows: names, game, amount, paid
// POST { code, guest }     -> as { code }, but Square sends them back to the guest payment page
import { json, missingSettings, square, getLocationId, bookingBy, confirmBooking, guestNames, db } from "../lib/square.mjs";

export default async (req) => {
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  const missing = missingSettings();
  if (missing.length) return json({ error: "Card payments aren't switched on yet." }, 503);

  const { code, confirm, info, guest } = await req.json().catch(() => ({}));
  if (!code) return json({ error: "Missing booking code." }, 400);
  try {
    const booking = await bookingBy("code", String(code).trim().toUpperCase());
    if (!booking) return json({ error: "Booking not found." }, 404);
    const names = await guestNames(booking);

    if (info) {
      if (!names) return json({ error: "Booking not found." }, 404);
      const ev = booking.events || {};
      const paid = booking.paid || (booking.square_order_id ? await confirmBooking(booking).catch(() => false) : false);
      return json({ ...names, paid, status: booking.status, amount: booking.amount, created_at: booking.created_at, event: { title: ev.title, day: ev.day, time: ev.time, kind: ev.kind } });
    }

    if (confirm || booking.paid) return json({ paid: await confirmBooking(booking) });
    if (booking.status !== "booked") return json({ error: "This booking is on the waitlist, so there's nothing to pay yet." }, 400);
    const pence = Math.round(Number(booking.amount) * 100);
    if (!(pence > 0)) return json({ error: "There's nothing to pay for this booking." }, 400);
    // If they started paying earlier and finished, don't charge twice.
    if (booking.square_order_id && (await confirmBooking(booking))) return json({ paid: true });

    const ev = booking.events || {};
    const when = ev.day ? new Date(`${ev.day}T12:00:00Z`).toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short", timeZone: "Europe/London" }) : "";
    // Fixed football item names so the Square summary groups them: game payments and kitty contributions.
    const name = ev.kind === "football" ? (booking.charge === "kitty" ? "BR3 Football Kitty Contributions" : "BR3 Football Payments") : `${ev.title} ${when}`;
    const origin = new URL(req.url).origin;
    const back = guest && names ? `guest:${booking.code}` : ev.kind === "football" ? "football" : "account";
    // A friend's place lists both names on the checkout, the receipt and the Square payment.
    const who = names ? `Guest ${names.guest}, booked by ${names.member}` : "";
    const price_money = { amount: pence, currency: "GBP" };
    const item = names
      ? { order: { location_id: await getLocationId(), line_items: [{ name: name.slice(0, 255), quantity: "1", base_price_money: price_money, note: who.slice(0, 2000) }] } }
      : { quick_pay: { name: name.slice(0, 255), price_money, location_id: await getLocationId() } };
    const { payment_link: link } = await square("/v2/online-checkout/payment-links", {
      method: "POST",
      body: JSON.stringify({
        idempotency_key: crypto.randomUUID(),
        ...item,
        checkout_options: {
          redirect_url: `${origin}/?paid=${encodeURIComponent(booking.code)}#${back}`,
          accepted_payment_methods: { apple_pay: true, google_pay: true },
        },
        payment_note: `${who || booking.display_name} · ${ev.kind === "football" ? `Football ${when} · ` : ""}booking ${booking.code}`,
      }),
    });
    await db(`bookings?id=eq.${booking.id}`, { method: "PATCH", body: JSON.stringify({ square_order_id: link.order_id }) });
    return json({ url: link.url });
  } catch (e) {
    return json({ error: e.message || "Something went wrong with the payment." }, 500);
  }
};
