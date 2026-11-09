// POST with the admin's sign-in token -> { connected, balance, name, transactions }
// Reads Starling's balance and the last 8 days of transactions into the app (read-only).
// The weekly Saturday pull (square-weekly) does the same by itself.
import { json, doorUser } from "../lib/square.mjs";
import { syncStarling } from "../lib/starling.mjs";

export default async (req) => {
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  if (!process.env.STARLING_TOKEN) return json({ error: "Starling isn't connected yet: add STARLING_TOKEN in Netlify." }, 503);
  if (!process.env.SUPABASE_SECRET_KEY) return json({ error: "SUPABASE_SECRET_KEY is missing in Netlify." }, 503);
  try {
    const u = await doorUser(req);
    if (u?.role !== "admin") return json({ error: "Only the admin can pull from Starling." }, 403);
    return json(await syncStarling(8));
  } catch (e) {
    return json({ error: e.message || "Couldn't reach Starling." }, 500);
  }
};
