// Every hour: removes people who joined more than 24 hours ago and never sent the
// membership application (see remove_stale_applicants in the database), and deletes
// guests' details 7 days after an event (purge_old_event_data).
import { db } from "../lib/square.mjs";

export default async () => {
  if (!process.env.SUPABASE_SECRET_KEY) return new Response("Not set up.", { status: 503 });
  const removed = await db("rpc/remove_stale_applicants", { method: "POST", body: "{}" });
  const purged = await db("rpc/purge_old_event_data", { method: "POST", body: "{}" }).catch(() => "not set up");
  return new Response(`Removed ${removed}, guest details purged ${purged}`);
};

export const config = { schedule: "@hourly" };
