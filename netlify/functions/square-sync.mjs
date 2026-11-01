// POST { from, to } (dates, YYYY-MM-DD) with the organiser's sign-in token
//   -> { checked, updated, family } after copying that period's Square payments into the app.
// The webhook already does this as each payment happens, and the weekly pull runs every Saturday; this fills any gaps.
import { json, missingSettings, doorUser, syncPayments } from "../lib/square.mjs";

export default async (req) => {
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  if (missingSettings().length) return json({ error: "Square isn't connected yet." }, 503);
  try {
    if (!(await doorUser(req))) return json({ error: "Only organisers can check Square." }, 403);
    const { from, to } = await req.json().catch(() => ({}));
    const day = (s) => (/^\d{4}-\d{2}-\d{2}$/.test(s || "") ? s : null);
    if (!day(from) || !day(to)) return json({ error: "Choose the dates to check." }, 400);
    return json(await syncPayments(from, to));
  } catch (e) {
    return json({ error: e.message || "Couldn't reach Square." }, 500);
  }
};
