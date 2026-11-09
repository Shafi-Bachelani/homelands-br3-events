// Starling Bank, read-only. Reads the BR3 account (or one Space in it) and its transactions,
// and copies them into the app so the reconciliation can check Square + Starling against the funds.
//
// Netlify environment variables:
//   STARLING_TOKEN   personal access token from developer.starlingbank.com (read scopes only:
//                    account:read, account-list:read, balance:read, transaction:read, space:read, savings-goal:read)
//   STARLING_SPACE   optional: the name of the Space that holds BR3 money, if the account is also used for
//                    other things. Left out, the whole account is read.
import { db } from "./square.mjs";

const API = "https://api.starlingbank.com/api/v2";

async function starling(path) {
  const res = await fetch(`${API}${path}`, { headers: { Authorization: `Bearer ${process.env.STARLING_TOKEN}`, Accept: "application/json" } });
  const body = await res.json().catch(() => null);
  if (!res.ok) throw new Error(`Starling ${res.status}: ${body?.error_description || body?.errors?.[0]?.message || body?.message || "request failed"}`);
  return body;
}

const pounds = (m) => (m && typeof m.minorUnits === "number" ? m.minorUnits / 100 : null);

// The account, and which balance and transaction category to read (the whole account, or one Space).
async function target() {
  const { accounts = [] } = await starling("/accounts");
  const acct = accounts.find((a) => a.currency === "GBP") || accounts[0];
  if (!acct) throw new Error("No Starling account found for this token.");
  const want = (process.env.STARLING_SPACE || "").trim().toLowerCase();
  if (!want) {
    const b = await starling(`/accounts/${acct.accountUid}/balance`);
    // total*Balance includes the account's Spaces; the whole account is BR3's, so count them.
    const balance = pounds(b.totalEffectiveBalance) ?? pounds(b.effectiveBalance);
    return { acct, category: acct.defaultCategory, balance, name: acct.name || "Starling account" };
  }
  const spaces = await starling(`/account/${acct.accountUid}/spaces`);
  const all = [
    ...(spaces.savingsGoals || []).map((s) => ({ uid: s.savingsGoalUid, name: s.name, bal: pounds(s.totalSaved) })),
    ...(spaces.spendingSpaces || []).map((s) => ({ uid: s.spaceUid, name: s.name, bal: pounds(s.balance) })),
  ];
  const sp = all.find((s) => (s.name || "").trim().toLowerCase() === want);
  if (!sp) throw new Error(`No Starling Space called "${process.env.STARLING_SPACE}". Spaces found: ${all.map((s) => s.name).join(", ") || "none"}.`);
  return { acct, category: sp.uid, balance: sp.bal, name: `${sp.name} (Space)` };
}

// Reads the balance and the last `days` days of transactions, and saves both.
export async function syncStarling(days = 8) {
  if (!process.env.STARLING_TOKEN) return { connected: false };
  const t = await target();
  const to = new Date(), from = new Date(to.getTime() - days * 864e5);
  const q = `minTransactionTimestamp=${encodeURIComponent(from.toISOString())}&maxTransactionTimestamp=${encodeURIComponent(to.toISOString())}`;
  const { feedItems = [] } = await starling(`/feed/account/${t.acct.accountUid}/category/${t.category}/transactions-between?${q}`);
  const rows = feedItems
    .filter((f) => f.feedItemUid && f.amount && f.status !== "DECLINED" && f.status !== "REVERSED")
    .map((f) => ({
      id: f.feedItemUid,
      at: f.transactionTime || f.settlementTime || f.updatedAt || new Date().toISOString(),
      amount: (f.direction === "OUT" ? -1 : 1) * pounds(f.amount),
      counterparty: f.counterPartyName || "",
      reference: f.reference || f.userNote || "",
      status: f.status || "",
      source: f.source || "",
      category: f.spendingCategory || "",
      raw: f,
      synced_at: new Date().toISOString(),
    }));
  if (rows.length) await db("starling_txns?on_conflict=id", { method: "POST", headers: { Prefer: "resolution=merge-duplicates,return=minimal" }, body: JSON.stringify(rows) });
  if (t.balance == null) throw new Error("Starling didn't return a balance.");
  await db("fund_state?id=eq.1", { method: "PATCH", headers: { Prefer: "return=minimal" },
    body: JSON.stringify({ starling_balance: Math.round(t.balance * 100) / 100, starling_balance_at: new Date().toISOString(), starling_name: t.name }) });
  return { connected: true, balance: t.balance, name: t.name, transactions: rows.length };
}
