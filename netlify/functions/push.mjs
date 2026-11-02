// GET ?key: the public key phones need to turn notifications on.
// Anything else: sends the notifications waiting in the database. The database calls this straight
// after a new announcement, post, comment or event. It only ever sends what the database has queued,
// so it is safe for anyone to call.
import { json } from "../lib/square.mjs";
import { pushSettings, sendWaiting } from "../lib/push.mjs";

export default async (req) => {
  if (!process.env.SUPABASE_SECRET_KEY) return json({ error: "Not set up." }, 503);
  try {
    if (new URL(req.url).searchParams.has("key")) {
      const s = await pushSettings();
      return new Response(JSON.stringify({ key: s.public_key }), { headers: { "content-type": "application/json", "cache-control": "public, max-age=3600" } });
    }
    return json(await sendWaiting());
  } catch (e) {
    console.error("Push", e);
    return json({ error: e.message || "Failed" }, 500);
  }
};
