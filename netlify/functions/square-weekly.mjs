// Every Saturday morning: pulls the last 7 days of Square payments into the app, the same as tapping
// Sync from Square. Football payments are matched to their bookings, and the Family Events subscriptions
// (Individual, Concessionary and Family) go into the Family Events fund, with Square's fee taken off.
import { missingSettings, syncPayments, db } from "../lib/square.mjs";
// Then posts the week's subscriptions (Saturday to Friday) to the Family Events Accounts chat, once per week.

export default async () => {
  if (missingSettings().length) return new Response("Square isn't connected.", { status: 503 });
  const iso = (d) => d.toISOString().slice(0, 10);
  const to = new Date(), from = new Date(to.getTime() - 7 * 864e5);
  try {
    const r = await syncPayments(iso(from), iso(to));
    const ukToday = new Date().toLocaleDateString("en-CA", { timeZone: "Europe/London" }); // YYYY-MM-DD
    r.posted = await db("rpc/post_family_week", { method: "POST", body: JSON.stringify({ p_end: ukToday }) }).catch((e) => `not posted: ${e.message}`);
    console.log("Weekly Square pull", r);
    return new Response(JSON.stringify(r), { headers: { "content-type": "application/json" } });
  } catch (e) {
    console.error("Weekly Square pull failed", e);
    return new Response(e.message || "Failed", { status: 500 });
  }
};

// 08:00 UTC on Saturdays: 8am in winter, 9am in summer (UK).
export const config = { schedule: "0 8 * * 6" };
