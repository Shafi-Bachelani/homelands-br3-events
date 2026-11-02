// Every hour, just after the hour: queues the timed notifications (football booking has opened,
// reminders the day before an event you've booked) and sends anything still waiting.
import { db, json } from "../lib/square.mjs";
import { sendWaiting } from "../lib/push.mjs";

export default async () => {
  if (!process.env.SUPABASE_SECRET_KEY) return json({ error: "Not set up." }, 503);
  try {
    const queued = await db("rpc/queue_due_notices", { method: "POST", body: "{}" });
    // Football Awards: tell players when voting opens, post the results when it closes (add-football-awards.sql).
    const awards = await db("rpc/post_due_awards", { method: "POST", body: "{}" }).catch((e) => `not set up: ${e.message}`);
    const r = await sendWaiting();
    console.log("Hourly notifications", { queued, awards, ...r });
    return json({ queued, awards, ...r });
  } catch (e) {
    console.error("Hourly notifications failed", e);
    return json({ error: e.message || "Failed" }, 500);
  }
};

export const config = { schedule: "5 * * * *" };
