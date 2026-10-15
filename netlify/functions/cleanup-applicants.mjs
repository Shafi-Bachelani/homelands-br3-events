// Every hour: removes people who joined more than 24 hours ago and never sent the
// membership application (see remove_stale_applicants in the database).
import { db } from "../lib/square.mjs";

export default async () => {
  if (!process.env.SUPABASE_SECRET_KEY) return new Response("Not set up.", { status: 503 });
  const removed = await db("rpc/remove_stale_applicants", { method: "POST", body: "{}" });
  return new Response(`Removed ${removed}`);
};

export const config = { schedule: "@hourly" };
