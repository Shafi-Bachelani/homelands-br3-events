// Jotform calls this when someone sends the membership application, so the app knows
// they applied (and doesn't remove them after 24 hours) and the admin can read their answers.
// Set up in Jotform: Settings → Integrations → Webhooks → https://<site>/.netlify/functions/jotform-webhook
// Event application forms (e.g. the Speed Chess Tournament) use the same webhook: the app opens the form
// with the booking code (AA-XXXXXX) filled in, and the answers are saved on that booking for the admin.
import { json, db } from "../lib/square.mjs";

const FORM_IDS = ["262877635236064", "262877268047066"]; // current form, then the first one
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default async (req) => {
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  if (!process.env.SUPABASE_SECRET_KEY) return json({ error: "Not set up." }, 503);
  const form = await req.formData().catch(() => null);
  if (!form) return json({ error: "Unknown form." }, 400);
  let raw = {};
  try { raw = JSON.parse(form.get("rawRequest") || "{}"); } catch {}

  // An event application: one of the answers is the booking code the app filled in.
  const bookingCode = Object.values(raw).map((v) => String(v ?? "").trim().toUpperCase()).find((v) => /^AA-[A-Z0-9]{6}$/.test(v));
  if (!FORM_IDS.includes(String(form.get("formID")))) {
    if (!bookingCode) return json({ ok: true, note: "No booking code on this application." });
    const answers = String(form.get("pretty") || "").split(/, (?=[A-Za-z][^:,]{0,200}:)/).filter((l) => !l.includes(bookingCode)).join("\n");
    try {
      await db(`bookings?code=eq.${encodeURIComponent(bookingCode)}&status=in.(pending,booked,waitlist)`, {
        method: "PATCH",
        body: JSON.stringify({ application: answers.slice(0, 8000), application_at: new Date().toISOString() }),
      });
      return json({ ok: true });
    } catch (e) {
      return json({ error: e.message }, 500); // Jotform retries later
    }
  }
  const idKey = Object.keys(raw).find((k) => /_memberId$/i.test(k));
  const memberId = String((idKey && raw[idKey]) || "").trim();
  if (!UUID.test(memberId)) return json({ ok: true, note: "No member id on this submission." });

  // One answer per line, without the hidden fields.
  const answers = String(form.get("pretty") || "")
    .split(/, (?=[A-Za-z][^:,]{0,60}:)/)
    .filter((line) => !/^(member ?id|email):/i.test(line))
    .join("\n");
  try {
    const waiting = await db(`profiles?id=eq.${memberId}&approved=eq.false&select=id`);
    if (!waiting.length) return json({ ok: true, note: "Not waiting for approval." });
    await db("applications?on_conflict=user_id", {
      method: "POST",
      headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
      body: JSON.stringify({ user_id: memberId, submitted_at: new Date().toISOString(), answers }),
    });
    return json({ ok: true });
  } catch (e) {
    return json({ error: e.message }, 500); // Jotform retries later
  }
};
