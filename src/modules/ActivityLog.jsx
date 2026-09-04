import { useState, useEffect, useMemo, useCallback } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useViewport } from "../lib/hooks.js";
import { useTabParam, TabLink } from "../lib/routing.jsx";
import { T } from "../lib/theme.js";

// ============================================================
// ActivityLog — the Production module (nav label "Production", route
// /production; the old /activity route still resolves). Team capture
// for Retention Points, sales, quotes, and cancelations.
//
// ONE flat page, Peter's layout (2026-09-04):
//  * Row 1, one wrapping row: Log for (owner), first name, last initial,
//    Relationship type, Good Neighbor Connect. Date reads "Today" with a
//    link to change it; the date box appears only when it is not today.
//  * First name suggests customers already on file (rp_customer_suggest,
//    eight matches per keystroke after two letters, nothing cached), so
//    "Anna S." is spelled one way and cancelations can match sales.
//  * "Add Activity" dropdown, cheapest first. Each pick is a pill with
//    an x; the same item can be added twice (two policy changes = two
//    pills = two rows). Pivot is on the list at $0: tracked, not paid.
//  * "Add Policy" dropdown adds a row: line, type, Quoted / Sold /
//    Canceled, then premium and cars once Sold or Canceled.
//  * Bottom row: ECRM link (only with a sale), Note, Marketing type (only
//    with a sale or quote), Who sourced the lead (only on a referral).
//
// Layout follows the web-form research Peter asked for (2026-09-04):
//  * Fewer visible choices. Three policy blocks became one list with one
//    "Add" chip; the line bubbles appear on tap. Date, note, and ECRM
//    link start folded (Hick 1952: decision time grows with the number
//    of options; Iyengar & Lepper 2000: too many visible options lower
//    completion).
//  * Errors after the attempt, not while typing (Bargas-Avila et al.
//    2007, Interacting with Computers: "don't show errors right away").
//    The Log button is always live; a tap with something missing shows
//    the "Still needed" list next to it and saves nothing.
//  * Sensible defaults so most rows need one tap (Johnson & Goldstein
//    2003): cars defaults to 1, date to today.
//  * Short labels, no parenthetical hints in headings, one column on a
//    phone (Seckler et al. 2014, CHI: the 20-guideline form cut
//    completion time, retries, and eye movements).
//
// The button calls rp_log_entry, which writes every part in one
// transaction. Any failure rolls the whole entry back. Only the owner
// may log on someone else's behalf, enforced server-side.
// ============================================================

const PRODUCTS = [
  { key: "auto",     label: "Auto",                 short: "Auto" },
  { key: "fire",     label: "Fire (home / renters)", short: "Fire" },
  { key: "business", label: "Business",             short: "Business" },
  { key: "life",     label: "Life",                 short: "Life" },
  { key: "health",   label: "Health",               short: "Health" },
  { key: "ips",      label: "Investment (IPS)",     short: "IPS" },
  { key: "bank",     label: "Bank",                 short: "Bank" },
];
const PRODUCT_LABEL = Object.fromEntries(PRODUCTS.map(p => [p.key, p.label]));
const PRODUCT_SHORT = Object.fromEntries(PRODUCTS.map(p => [p.key, p.short]));
const SERVICE_PREFIX = "service_task";
const RELATIONSHIPS = [
  { key: "new",      label: "New household" },
  { key: "existing", label: "Existing customer" },
  { key: "winback",  label: "Winback" },
];
const TABS = ["log", "week"];

// ---------- styles ----------
const inputBase = {
  width: "100%", padding: "10px 12px", borderRadius: 8,
  border: `1px solid ${T.slate300}`, background: T.white, color: T.slate900,
  fontSize: 15, outline: "none", boxSizing: "border-box",
};
const labelStyle = { fontSize: 12, fontWeight: 600, color: T.slate600, marginBottom: 6, display: "block" };
const hintStyle = { color: T.slate400, fontWeight: 400 };
const cardStyle = {
  background: T.white, borderRadius: 12, border: `1px solid ${T.slate200}`,
  padding: 20, boxShadow: "0 1px 2px rgba(0,0,0,0.04)",
};
const blockStyle = { marginTop: 18, paddingTop: 16, borderTop: `1px solid ${T.slate100}` };
const blockTitle = { fontSize: 14, fontWeight: 700, color: T.slate900, marginBottom: 8 };
const tableTh = {
  fontSize: 11, fontWeight: 700, color: T.slate500, textTransform: "uppercase", letterSpacing: 0.4,
  padding: "8px 6px", borderBottom: `1px solid ${T.slate200}`, textAlign: "left", whiteSpace: "nowrap",
};
const tableTd = { fontSize: 13, color: T.slate800, padding: "8px 6px", borderBottom: `1px solid ${T.slate100}`, verticalAlign: "top" };
const btnPrimary = (disabled) => ({
  padding: "10px 18px", borderRadius: 8, border: "none", fontWeight: 700, fontSize: 14, cursor: disabled ? "default" : "pointer",
  background: disabled ? T.slate200 : T.blue, color: disabled ? T.slate500 : T.white,
});
const btnGhost = { padding: "6px 10px", borderRadius: 6, border: `1px solid ${T.slate300}`, background: T.white, color: T.slate700, fontSize: 12, cursor: "pointer" };
const chip = (on) => ({
  padding: "8px 12px", borderRadius: 999, fontSize: 13, fontWeight: 600, cursor: "pointer", userSelect: "none",
  border: `1px solid ${on ? T.blue : T.slate300}`, background: on ? T.blueLt : T.white, color: on ? T.blue : T.slate700,
});
const chipRow = { display: "flex", flexWrap: "wrap", gap: 8 };
const gridForm = { display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(180px, 1fr))", gap: 12 };
const policyRow = { display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(150px, 1fr))", gap: 10, padding: 12, background: T.slate50, borderRadius: 8, alignItems: "end" };
const removeBtn = { ...btnGhost, color: T.red, borderColor: T.slate300, alignSelf: "center", whiteSpace: "nowrap" };
const wrapRow = { display: "flex", flexWrap: "wrap", gap: 10, alignItems: "flex-end" };
const linkBtn = { background: "none", border: "none", padding: 0, color: T.blue, fontSize: 13, fontWeight: 600, cursor: "pointer", fontFamily: "inherit" };
const field = (min = 150) => ({ flex: `1 1 ${min}px`, minWidth: 0 });
const addSelect = {
  ...inputBase, width: 190, flex: "0 0 190px", color: T.blue, fontWeight: 700,
  border: `1px dashed ${T.blue}`, background: T.blueLt, cursor: "pointer",
};
const pill = { display: "inline-flex", alignItems: "center", gap: 6, padding: "8px 8px 8px 12px", borderRadius: 999, fontSize: 13, fontWeight: 600, border: `1px solid ${T.blue}`, background: T.blueLt, color: T.blue };
const pillX = { border: "none", background: "transparent", color: T.blue, fontSize: 16, lineHeight: 1, cursor: "pointer", padding: "0 4px", fontFamily: "inherit" };
const STATUSES = [
  { key: "quoted",      label: "Quoted" },
  { key: "sold",        label: "Sold" },
  { key: "quoted_sold", label: "Quoted and sold" },
  { key: "canceled",    label: "Canceled" },
];

// ---------- helpers ----------
function todayCentral() {
  return new Date().toLocaleDateString("en-CA", { timeZone: "America/Chicago" });
}
function addDays(iso, n) {
  const [y, m, d] = iso.split("-").map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d + n));
  return dt.toISOString().slice(0, 10);
}
function weekEndOf(iso) {
  const [y, m, d] = iso.split("-").map(Number);
  const dow = new Date(Date.UTC(y, m - 1, d)).getUTCDay(); // 0 = Sunday
  return addDays(iso, 6 - dow);
}
function fmtDate(iso) {
  if (!iso) return "—";
  const [y, m, d] = iso.split("-");
  return `${Number(m)}/${Number(d)}/${y}`;
}
function fmtPts(n) {
  const x = Number(n);
  return isFinite(x) ? x.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 }) : "0.00";
}
function errText(e) {
  return e?.message || e?.error || (typeof e === "string" ? e : "Something went wrong.");
}
let _pid = 0;
const newPolicyId = () => `p${++_pid}`;
const itemLabel = (v) => Number(v.points) > 0 ? `${v.label} · $${fmtPts(v.points)}` : v.label;

// ---------- shared field blocks ----------

function Notice({ kind, children }) {
  if (!children) return null;
  const bg = kind === "error" ? T.redLt : T.greenLt;
  const fg = kind === "error" ? T.red : T.green;
  return <div style={{ padding: "10px 12px", borderRadius: 8, background: bg, color: fg, fontSize: 13, fontWeight: 600, marginTop: 12 }}>{children}</div>;
}


function typeLabel(types, line, key) {
  const t = (types[line] || []).find(x => x.type_key === key);
  return t ? t.label : null;
}

// Plain-English wrap-up of what rp_log_entry saved.
function summarizeEntry(data) {
  const parts = [];
  const a = data?.activity;
  if (a) {
    const n = (a.items || []).length;
    const pend = (a.items || []).filter(i => i.credit_available_on);
    parts.push(`${n} activity item${n === 1 ? "" : "s"} for $${fmtPts(a.points_total)}` +
      (pend.length ? ` (save clears ${fmtDate(pend[0].credit_available_on)})` : ""));
  }
  const q = data?.quote;
  if (q) parts.push(`quoted ${q.policies} polic${q.policies === 1 ? "y" : "ies"}`);
  const s = data?.sale;
  if (s) {
    const credits = (s.credits || []).map(c => c.activity_key === "multiline_sold" ? `Multiline (${PRODUCT_SHORT[c.line] || c.line})` : "Referral Sold");
    parts.push(`sold ${s.policies} polic${s.policies === 1 ? "y" : "ies"} for $${fmtPts(s.total_premium)} premium` +
      (credits.length ? `, credited ${credits.join(", ")} = $${fmtPts(s.retention_points)}` : ", no multiline or referral credit"));
  }
  const cs = Array.isArray(data?.cancelation) ? data.cancelation : [];
  if (cs.length) {
    const lines = cs.map(c => PRODUCT_SHORT[c.policy_line] || c.policy_line).join(", ");
    const voided = cs.reduce((n, c) => n + Number(c.saves_voided || 0), 0);
    parts.push(`canceled: ${lines}` + (voided > 0 ? `, ${voided} unpaid save${voided === 1 ? "" : "s"} taken back` : ""));
  }
  return `Logged for ${data?.customer || "the customer"}: ${parts.join("; ")}.`;
}

// =====================================================================
// Entry page — one customer, one contact, everything that happened, on
// one flat page. One Log button; one RPC that saves all of it or none.
// =====================================================================
function EntryPage({ values, sources, types, isOwner, roster, onLogged, refreshKey }) {
  const today = todayCentral();
  const [first, setFirst] = useState("");
  const [initial, setInitial] = useState("");
  const [date, setDate] = useState(today);
  const [dateOpen, setDateOpen] = useState(false);
  const [logFor, setLogFor] = useState(null);
  const [suggest, setSuggest] = useState([]);      // customer names on file that match what's typed
  const [relationship, setRelationship] = useState("");
  const [gnc, setGnc] = useState("");
  const [source, setSource] = useState("");
  const [sourcedBy, setSourcedBy] = useState("");
  const [activities, setActivities] = useState([]);  // [{id, key}]
  const [saveLine, setSaveLine] = useState("");
  const [saveReason, setSaveReason] = useState("");
  const [policies, setPolicies] = useState([]);      // [{id, line, type, status, premium, vehicles, isNewLine}]
  const [cReason, setCReason] = useState("");
  const [ecrm, setEcrm] = useState("");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const [ok, setOk] = useState("");
  const [attempted, setAttempted] = useState(false); // show what's missing only after a Log tap
  const [last, setLast] = useState(null);            // {result, first, initial, date} of the entry just logged, for Undo / Log another

  // every Retention Points item, least expensive first
  const items = useMemo(() => (values || []).filter(v => v.category === "logged")
    .slice().sort((a, b) => (Number(a.points) - Number(b.points)) || String(a.label).localeCompare(String(b.label))), [values]);
  const byKey = useMemo(() => Object.fromEntries((values || []).map(v => [v.activity_key, v])), [values]);

  // name suggestions: two letters in, a quarter-second pause, at most eight back
  useEffect(() => {
    const q = first.trim();
    if (q.length < 2) { setSuggest([]); return undefined; }
    let alive = true;
    const t = setTimeout(async () => {
      const { data } = await supabase.rpc("rp_customer_suggest", { p_prefix: q });
      if (alive) setSuggest(Array.isArray(data) ? data : []);
    }, 250);
    return () => { alive = false; clearTimeout(t); };
  }, [first]);
  const pickCustomer = (c) => { setFirst(c.customer_first_name || ""); setInitial(c.customer_last_initial || ""); setSuggest([]); };

  const addActivity = (key) => { if (key) setActivities(list => [...list, { id: newPolicyId(), key }]); };
  const dropActivity = (id) => setActivities(list => list.filter(a => a.id !== id));
  const addPolicy = (line) => { if (line) setPolicies(list => [...list, { id: newPolicyId(), line, type: "", status: "", premium: "", vehicles: "1", isNewLine: true }]); };
  const editPolicy = (id, patch) => setPolicies(list => list.map(p => p.id === id ? { ...p, ...patch } : p));
  const dropPolicy = (id) => setPolicies(list => list.filter(p => p.id !== id));

  // ---- what is in the entry right now ----
  const hasSave = activities.some(a => a.key === "cancelation_saved");
  const hasReview = activities.some(a => a.key === "policy_review");
  const activityItems = activities.filter(a => byKey[a.key]).map(a =>
    a.key === "cancelation_saved" ? { activity_key: a.key, save_line: saveLine, save_reason: saveReason.trim() } : { activity_key: a.key });
  const activityTotal = activityItems.reduce((s, it) => s + Number(byKey[it.activity_key]?.points || 0), 0);
  const quoted = policies.filter(p => p.status === "quoted" || p.status === "quoted_sold");
  const sold = policies.filter(p => p.status === "sold" || p.status === "quoted_sold");
  const canceled = policies.filter(p => p.status === "canceled");
  const saleTotal = sold.reduce((s, p) => s + (Number(p.premium) || 0), 0);

  const hasActivity = activityItems.length > 0;
  const hasQuote = quoted.length > 0;
  const hasSale = sold.length > 0;
  const hasCxl = canceled.length > 0;
  const hasAnything = hasActivity || hasQuote || hasSale || hasCxl;
  const customerOk = !!first.trim() && /^[A-Za-z]$/.test(initial.trim());
  const isReferral = source === "referral";
  const householdFresh = relationship === "new" || relationship === "winback";
  const needsType = (line) => (types[line] || []).length > 0;
  const isSold = (p) => p.status === "sold" || p.status === "quoted_sold";
  const needsMoney = (p) => isSold(p) || p.status === "canceled";
  const showDate = dateOpen || date !== today;
  const showSuggest = suggest.length > 0 && !(suggest.length === 1 && suggest[0].customer_first_name === first.trim() && (suggest[0].customer_last_initial || "") === initial.trim().toUpperCase());

  // ---- what still needs fixing, in plain words (mirrors the server rules) ----
  const problems = [];
  if (!customerOk) problems.push("Customer first name and last initial.");
  if (!hasAnything) problems.push("Add a retention activity or a policy.");
  if (policies.some(p => !p.status)) problems.push("Each policy needs Quoted, Sold, or Canceled.");
  if (policies.some(p => needsType(p.line) && !p.type)) problems.push("Each Auto or Fire policy needs its type.");
  if (policies.some(p => needsMoney(p) && (p.premium === "" || !(Number(p.premium) >= 0)))) problems.push("Each sold or canceled policy needs its premium.");
  if (policies.some(p => needsMoney(p) && p.line === "auto" && !(Number(p.vehicles) >= 1))) problems.push("Each sold or canceled auto policy needs its number of cars.");
  if ((hasActivity || hasQuote) && date < addDays(today, -7)) problems.push("Activity and quotes are logged within 7 days. Pick a later date or split the entry.");
  if (hasSale && date < addDays(today, -30)) problems.push("A sale is logged within 30 days of the bind.");
  if (hasCxl && date < addDays(today, -90)) problems.push("A cancelation is logged within 90 days.");
  if (hasSave) {
    if (date !== today) problems.push("A save is logged the same business day it comes in. Set the date to today.");
    if (!saveLine || !saveReason.trim()) problems.push("The save needs the policy line at risk and the reason the customer gave.");
  }
  if (hasReview && !note.trim()) problems.push("The policy review needs a note on what you covered.");
  if (hasSale) {
    if (!relationship) problems.push("A sale needs the relationship type.");
    if (!source) problems.push("A sale needs the marketing type.");
    if (gnc === "") problems.push("A sale needs to say whether Good Neighbor Connect was used.");
    if (!ecrm.trim()) problems.push("A sale needs the ECRM opportunity link.");
  }
  if (hasSale && hasCxl) {
    const soldLines = new Set(sold.map(p => p.line));
    const clash = [...new Set(canceled.filter(p => soldLines.has(p.line)).map(p => p.line))];
    if (clash.length) problems.push(`${clash.map(k => PRODUCT_SHORT[k]).join(", ")} is both sold and canceled in this entry. Log those as two entries.`);
  }
  if (ecrm.trim() && !/^https?:\/\//i.test(ecrm.trim())) problems.push("The ECRM link must start with http.");

  const reset = (keep) => {
    if (!keep) { setFirst(""); setInitial(""); setDate(today); setDateOpen(false); }
    setSuggest([]);
    setRelationship(""); setGnc(""); setSource(""); setSourcedBy("");
    setActivities([]); setSaveLine(""); setSaveReason("");
    setPolicies([]); setCReason(""); setEcrm(""); setNote("");
    setAttempted(false);
  };

  const submit = async () => {
    setErr(""); setOk("");
    setAttempted(true);
    if (busy || problems.length > 0) return;
    setBusy(true);
    try {
      const row = (p) => ({ line_of_business: p.line, product_type: p.type || null });
      const money = (p) => ({ premium: Number(p.premium), vehicle_count: p.line === "auto" ? Number(p.vehicles) : null });
      const payload = {
        customer_first: first.trim(), customer_last_initial: initial.trim(), occurred_on: date,
        ecrm_url: ecrm.trim() || null, note: note.trim() || null, team_member_id: logFor,
        relationship_type: relationship || null,
        gnc_used: gnc === "" ? null : gnc === "yes",
        marketing_source: source || null,
        sourced_by_team_member_id: isReferral && sourcedBy ? sourcedBy : null,
        activity: hasActivity ? { items: activityItems } : null,
        quote: hasQuote ? { items: quoted.map(row) } : null,
        sale: hasSale ? { products: sold.map(p => ({ ...row(p), ...money(p), policy_count: 1, is_new_line: householdFresh ? true : !!p.isNewLine })) } : null,
        cancelation: hasCxl ? { items: canceled.map(p => ({ ...row(p), ...money(p) })), reason: cReason.trim() || null } : null,
      };
      const { data, error } = await supabase.rpc("rp_log_entry", { p_payload: payload });
      if (error) { setErr(errText(error)); return; }
      if (!data?.ok) { setErr(errText(data)); return; }
      setOk(summarizeEntry(data));
      setLast({ result: data, first: first.trim(), initial: initial.trim(), date });
      reset();
      onLogged?.();
    } catch (e) { setErr(errText(e)); } finally { setBusy(false); }
  };

  const undo = async () => {
    if (!last || busy) return;
    setBusy(true);
    try {
      const { data, error } = await supabase.rpc("rp_undo_entry", { p_result: last.result });
      if (error) { setErr(errText(error)); return; }
      setOk(`Undone. ${data?.undone || 0} row${data?.undone === 1 ? "" : "s"} removed.`);
      setLast(null);
      onLogged?.();
    } catch (e) { setErr(errText(e)); } finally { setBusy(false); }
  };
  const logAnother = () => {
    if (!last) return;
    setFirst(last.first); setInitial(last.initial); setDate(last.date);
    setOk(""); setLast(null);
  };

  const preview = first.trim() && /^[A-Za-z]$/.test(initial.trim()) ? `${first.trim()} ${initial.trim().toUpperCase()}.` : "";

  return (
    <div>
      <div style={cardStyle}>
        <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900, marginBottom: 4 }}>What happened with this customer?</div>
        <div style={{ fontSize: 13, color: T.slate500, marginBottom: 16 }}>Add what happened. One button saves it all.</div>

        {/* ---- row 1: every first field, wrapping ---- */}
        <div style={wrapRow}>
          {isOwner && (
            <div style={field(130)}>
              <label style={labelStyle}>Log for</label>
              <select style={inputBase} value={logFor || ""} onChange={e => setLogFor(e.target.value || null)}>
                <option value="">Myself</option>
                {(roster || []).map(t => <option key={t.id} value={t.id}>{t.first_name}</option>)}
              </select>
            </div>
          )}
          <div style={{ ...field(150), position: "relative" }}>
            <label style={labelStyle}>First name</label>
            <input style={inputBase} value={first} onChange={e => setFirst(e.target.value)} placeholder="Anna" autoComplete="off" />
            {showSuggest && (
              <div style={{ position: "absolute", top: "100%", left: 0, right: 0, zIndex: 5, background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 8, boxShadow: "0 6px 16px rgba(0,0,0,0.08)", marginTop: 4, overflow: "hidden" }}>
                {suggest.map(c => (
                  <button key={c.customer_label} type="button" onClick={() => pickCustomer(c)}
                    style={{ display: "block", width: "100%", textAlign: "left", padding: "8px 12px", border: "none", background: "transparent", fontSize: 14, color: T.slate800, cursor: "pointer", fontFamily: "inherit" }}>
                    {c.customer_label} <span style={{ color: T.slate400, fontSize: 12 }}>on file</span>
                  </button>
                ))}
              </div>
            )}
          </div>
          <div style={field(90)}>
            <label style={labelStyle}>Last initial {preview ? <span style={hintStyle}>→ {preview}</span> : null}</label>
            <input style={inputBase} value={initial} maxLength={1} onChange={e => setInitial(e.target.value)} placeholder="S" />
          </div>
          <div style={field(160)}>
            <label style={labelStyle}>Relationship type</label>
            <select style={inputBase} value={relationship} onChange={e => setRelationship(e.target.value)}>
              <option value="">Pick one</option>
              {RELATIONSHIPS.map(r => <option key={r.key} value={r.key}>{r.label}</option>)}
            </select>
          </div>
          <div style={field(160)}>
            <label style={labelStyle}>Good Neighbor Connect used?</label>
            <select style={inputBase} value={gnc} onChange={e => setGnc(e.target.value)}>
              <option value="">Pick one</option>
              <option value="yes">Yes</option>
              <option value="no">No</option>
            </select>
          </div>
          {showDate && (
            <div style={field(150)}>
              <label style={labelStyle}>Date</label>
              <input type="date" style={inputBase} value={date} max={today} min={addDays(today, -90)} onChange={e => setDate(e.target.value)} />
            </div>
          )}
        </div>
        {!showDate && (
          <div style={{ marginTop: 8, fontSize: 13, color: T.slate500 }}>
            Today · <button type="button" style={linkBtn} onClick={() => setDateOpen(true)}>change the date</button>
          </div>
        )}

        {/* ---- retention activity: Add dropdown + pills on one wrapping row ---- */}
        <div style={blockStyle}>
          <div style={{ ...wrapRow, alignItems: "center" }}>
            <select style={addSelect} value="" onChange={e => addActivity(e.target.value)}>
              <option value="">+ Add Activity</option>
              {items.map(v => <option key={v.activity_key} value={v.activity_key}>{itemLabel(v)}</option>)}
            </select>
            {activities.map(a => byKey[a.key] && (
              <span key={a.id} style={pill}>
                {itemLabel(byKey[a.key])}
                <button type="button" style={pillX} onClick={() => dropActivity(a.id)} aria-label="remove">×</button>
              </span>
            ))}
          </div>
          {hasSave && (
            <div style={{ ...wrapRow, marginTop: 10, padding: 12, background: T.slate50, borderRadius: 8 }}>
              <div style={field(160)}>
                <label style={labelStyle}>Policy line at risk</label>
                <select style={inputBase} value={saveLine} onChange={e => setSaveLine(e.target.value)}>
                  <option value="">Pick one</option>
                  {PRODUCTS.map(p => <option key={p.key} value={p.key}>{p.label}</option>)}
                </select>
              </div>
              <div style={field(260)}>
                <label style={labelStyle}>Reason the customer gave</label>
                <input style={inputBase} value={saveReason} onChange={e => setSaveReason(e.target.value)} placeholder="Rate went up at renewal; found a cheaper quote" />
              </div>
            </div>
          )}
        </div>

        {/* ---- policies: Add dropdown + marketing type, then one row per policy ---- */}
        <div style={blockStyle}>
          <div style={wrapRow}>
            <select style={addSelect} value="" onChange={e => addPolicy(e.target.value)}>
              <option value="">+ Add Policy</option>
              {PRODUCTS.map(p => <option key={p.key} value={p.key}>{p.label}</option>)}
            </select>
          </div>

          {policies.length > 0 && (
            <div style={{ marginTop: 10, display: "grid", gap: 8 }}>
              {policies.map(p => (
                <div key={p.id} style={{ ...wrapRow, padding: 10, background: T.slate50, borderRadius: 8 }}>
                  <div style={{ fontWeight: 700, color: T.slate800, flex: "0 0 auto", paddingBottom: 10 }}>{PRODUCT_LABEL[p.line]}</div>
                  {needsType(p.line) && (
                    <div style={field(150)}>
                      <label style={labelStyle}>Type</label>
                      <select style={inputBase} value={p.type} onChange={e => editPolicy(p.id, { type: e.target.value })}>
                        <option value="">Pick one</option>
                        {(types[p.line] || []).map(t => <option key={t.type_key} value={t.type_key}>{t.label}</option>)}
                      </select>
                    </div>
                  )}
                  <div style={field(130)}>
                    <label style={labelStyle}>What happened</label>
                    <select style={inputBase} value={p.status} onChange={e => editPolicy(p.id, { status: e.target.value })}>
                      <option value="">Pick one</option>
                      {STATUSES.map(st => <option key={st.key} value={st.key}>{st.label}</option>)}
                    </select>
                  </div>
                  {needsMoney(p) && (
                    <div style={field(120)}>
                      <label style={labelStyle}>Premium</label>
                      <input type="number" inputMode="decimal" min="0" step="0.01" style={inputBase} value={p.premium} onChange={e => editPolicy(p.id, { premium: e.target.value })} placeholder="0.00" />
                    </div>
                  )}
                  {needsMoney(p) && p.line === "auto" && (
                    <div style={field(80)}>
                      <label style={labelStyle}>Cars</label>
                      <input type="number" inputMode="numeric" min="1" step="1" style={inputBase} value={p.vehicles} onChange={e => editPolicy(p.id, { vehicles: e.target.value })} />
                    </div>
                  )}
                  {isSold(p) && relationship === "existing" && (
                    <label style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 13, color: T.slate700, paddingBottom: 10, flex: "0 0 auto" }}>
                      <input type="checkbox" checked={!!p.isNewLine} onChange={e => editPolicy(p.id, { isNewLine: e.target.checked })} />
                      New line
                    </label>
                  )}
                  <button type="button" style={{ ...removeBtn, marginLeft: "auto", marginBottom: 6 }} onClick={() => dropPolicy(p.id)}>×</button>
                </div>
              ))}
              {hasCxl && (
                <div>
                  <label style={labelStyle}>Why did it cancel? <span style={hintStyle}>(optional)</span></label>
                  <input style={inputBase} value={cReason} onChange={e => setCReason(e.target.value)} placeholder="what they told us" />
                </div>
              )}
              {hasSale && (
                <div style={{ fontSize: 13, color: T.slate700 }}>
                  <strong>Total premium sold: ${fmtPts(saleTotal)}.</strong> <span style={{ color: T.slate500 }}>Multiline and Referral credits are added on their own, once per line.</span>
                </div>
              )}
            </div>
          )}
        </div>

        {/* ---- bottom row: ECRM link (sale), note, marketing type (sale or quote), sourced by (referral) ---- */}
        <div style={{ ...wrapRow, ...blockStyle }}>
          {hasSale && (
            <div style={field(220)}>
              <label style={labelStyle}>ECRM link <span style={{ color: T.red }}>(required for a sale)</span></label>
              <input style={inputBase} value={ecrm} onChange={e => setEcrm(e.target.value)} placeholder="https://…" />
            </div>
          )}
          <div style={field(220)}>
            <label style={labelStyle}>Note {hasReview ? <span style={{ color: T.red }}>(required for a policy review)</span> : null}</label>
            <input style={inputBase} value={note} onChange={e => setNote(e.target.value)} placeholder="Reviewed liability limits and umbrella; added rental reimbursement" />
          </div>
          {(hasSale || hasQuote) && (
            <div style={field(160)}>
              <label style={labelStyle}>Marketing type</label>
              <select style={inputBase} value={source} onChange={e => setSource(e.target.value)}>
                <option value="">Pick one</option>
                {(sources || []).map(s => <option key={s.source_key} value={s.source_key}>{s.label}</option>)}
              </select>
            </div>
          )}
          {(hasSale || hasQuote) && isReferral && (
            <div style={field(160)}>
              <label style={labelStyle}>Who sourced the lead?</label>
              <select style={inputBase} value={sourcedBy} onChange={e => setSourcedBy(e.target.value)}>
                <option value="">{logFor ? "The person logged for" : "Me"}</option>
                {(roster || []).map(t => <option key={t.id} value={t.id}>{t.first_name}</option>)}
              </select>
            </div>
          )}
        </div>

        <div style={{ display: "flex", flexWrap: "wrap", gap: 12, alignItems: "center", marginTop: 18 }}>
          <button style={btnPrimary(busy)} disabled={busy} onClick={submit}>{busy ? "Saving…" : `Log it${activityTotal ? ` · $${fmtPts(activityTotal)}` : ""}`}</button>
        </div>
        {attempted && problems.length > 0 && (
          <div style={{ marginTop: 12, fontSize: 12, color: T.slate600, lineHeight: 1.6 }}>
            <div style={{ fontWeight: 700, color: T.slate700 }}>Still needed</div>
            {problems.map((p, i) => <div key={i}>· {p}</div>)}
          </div>
        )}
        <Notice kind="error">{err}</Notice>
        <Notice kind="ok">{ok}</Notice>
        {ok && last && (
          <div style={{ display: "flex", flexWrap: "wrap", gap: 16, marginTop: 8, fontSize: 13 }}>
            <button type="button" style={linkBtn} onClick={undo} disabled={busy}>Undo</button>
            <button type="button" style={linkBtn} onClick={logAnother}>Log another for {last.first} {last.initial.toUpperCase()}.</button>
          </div>
        )}
      </div>
      <PendingSaves refreshKey={refreshKey} />
    </div>
  );
}

// =====================================================================
// Saves still waiting to clear — read-only list under the entry page
// =====================================================================
function PendingSaves({ refreshKey }) {
  const [rows, setRows] = useState([]);

  useEffect(() => {
    let alive = true;
    (async () => {
      const { data } = await supabase
        .from("rp_saves_clearing_soon")
        .select("id, team_member_id, first_name, customer_label, save_line, occurred_on, credit_available_on, days_until_clear, points")
        .eq("agency_id", AGENCY_ID)
        .order("credit_available_on");
      if (alive) setRows(Array.isArray(data) ? data : []);
    })();
    return () => { alive = false; };
  }, [refreshKey]);

  if (!(rows || []).length) return null;

  return (
    <div style={{ ...cardStyle, marginTop: 16 }}>
      <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900, marginBottom: 4 }}>Saves still waiting to clear</div>
      <div style={{ fontSize: 13, color: T.slate500, marginBottom: 14 }}>
        A save pays once the policy has stayed active 30 days. If one of these canceled anyway, log the cancelation above and the credit comes off before it is ever paid.
      </div>
      <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
        <table style={{ width: "100%", borderCollapse: "collapse" }}>
          <thead>
            <tr>
              <th style={tableTh}>Who</th>
              <th style={tableTh}>Customer</th>
              <th style={tableTh}>Line</th>
              <th style={tableTh}>Saved</th>
              <th style={tableTh}>Clears</th>
              <th style={tableTh}>Days left</th>
              <th style={tableTh}>Points</th>
            </tr>
          </thead>
          <tbody>
            {(rows || []).map(r => (
              <tr key={r.id}>
                <td style={tableTd}>{r.first_name || "\u2014"}</td>
                <td style={tableTd}>{r.customer_label}</td>
                <td style={tableTd}>{PRODUCT_LABEL[r.save_line] || r.save_line}</td>
                <td style={tableTd}>{fmtDate(r.occurred_on)}</td>
                <td style={tableTd}>{fmtDate(r.credit_available_on)}</td>
                <td style={tableTd}>{r.days_until_clear}</td>
                <td style={tableTd}>{fmtPts(r.points)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

// =====================================================================
// Week view — points table + this week's entries
// =====================================================================
function WeekView({ isAdmin, myTeamId, roster, values, refreshKey }) {
  const [weekEnd, setWeekEnd, weekHref] = useTabParam("week", weekEndOf(todayCentral()));
  const [rows, setRows] = useState([]);
  const [acts, setActs] = useState([]);
  const [sales, setSales] = useState([]);
  const [quotes, setQuotes] = useState([]);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState("");

  const nameOf = useMemo(() => {
    const m = new Map();
    for (const t of roster || []) m.set(t.id, t.first_name);
    return (id) => m.get(id) || "—";
  }, [roster]);
  const labelOf = useMemo(() => Object.fromEntries((values || []).map(v => [v.activity_key, v.label])), [values]);
  const safeWeek = /^\d{4}-\d{2}-\d{2}$/.test(weekEnd || "") ? weekEnd : weekEndOf(todayCentral());
  const weekStart = addDays(safeWeek, -6);

  const load = useCallback(async () => {
    setLoading(true); setErr("");
    try {
      const [p, a, s, q] = await Promise.all([
        supabase.rpc("compute_weekly_retention_points", { p_agency_id: AGENCY_ID, p_week_end_date: safeWeek }),
        supabase.from("retention_activity_log").select("id, team_member_id, activity_key, occurred_on, credited_week_end_date, credit_available_on, customer_label, note, save_reason, save_line, points, status, source, created_at")
          .eq("agency_id", AGENCY_ID).eq("status", "credited").or(`week_end_date.eq.${safeWeek},credited_week_end_date.eq.${safeWeek}`).order("occurred_on", { ascending: false }),
        supabase.from("sales_log").select("id, team_member_id, sourced_by_team_member_id, sale_date, customer_label, household_status, marketing_source, gnc_used, vehicle_count, total_premium, status, created_at, sales_log_products(line_of_business, premium, policy_count, is_new_line)")
          .eq("agency_id", AGENCY_ID).eq("status", "active").eq("week_end_date", safeWeek).order("sale_date", { ascending: false }),
        supabase.from("quote_log").select("id, team_member_id, quote_date, customer_label, is_existing_customer, products_discussed, status, created_at")
          .eq("agency_id", AGENCY_ID).eq("status", "active").eq("week_end_date", safeWeek).order("quote_date", { ascending: false }),
      ]);
      if (p.error) throw p.error;
      setRows(Array.isArray(p.data) ? p.data : []);
      setActs(Array.isArray(a.data) ? a.data : []);
      setSales(Array.isArray(s.data) ? s.data : []);
      setQuotes(Array.isArray(q.data) ? q.data : []);
    } catch (e) { setErr(errText(e)); } finally { setLoading(false); }
  }, [safeWeek]);

  useEffect(() => { load(); }, [load, refreshKey]);

  const mine = (r) => isAdmin || r.team_member_id === myTeamId;
  const visibleRows = rows.filter(mine);
  const teamNet = rows.reduce((s, r) => s + Number(r.net_points || 0), 0);
  const myActs = acts.filter(mine);
  const mySales = sales.filter(r => isAdmin || r.team_member_id === myTeamId || r.sourced_by_team_member_id === myTeamId);
  const myQuotes = quotes.filter(mine);

  const voidRow = async (fn, id, what) => {
    if (!window.confirm(`Remove this ${what}?`)) return;
    const { data, error } = await supabase.rpc(fn, { p_id: id, p_reason: null });
    if (error || !data?.ok) { window.alert(errText(error || data)); return; }
    load();
  };

  return (
    <div style={{ display: "grid", gap: 16 }}>
      <div style={{ ...cardStyle, display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center", justifyContent: "space-between" }}>
        <div>
          <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>Week of {fmtDate(weekStart)} – {fmtDate(safeWeek)}</div>
          <div style={{ fontSize: 12, color: T.slate500 }}>Sunday through Saturday. Hours and calls come from the systems; the rest from what was logged.</div>
        </div>
        <div style={{ display: "flex", gap: 8 }}>
          <TabLink href={weekHref(addDays(safeWeek, -7))} onSelect={() => setWeekEnd(addDays(safeWeek, -7))} style={btnGhost}>← Prior week</TabLink>
          <TabLink href={weekHref(weekEndOf(todayCentral()))} onSelect={() => setWeekEnd(weekEndOf(todayCentral()))} style={btnGhost}>This week</TabLink>
          <TabLink href={weekHref(addDays(safeWeek, 7))} onSelect={() => setWeekEnd(addDays(safeWeek, 7))} style={btnGhost} disabled={safeWeek >= weekEndOf(todayCentral())}>Next week →</TabLink>
        </div>
      </div>

      {err && <Notice kind="error">{err}</Notice>}

      <div style={cardStyle}>
        <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900, marginBottom: 10 }}>Retention Points {loading ? <span style={{ color: T.slate400, fontWeight: 400 }}>· loading…</span> : null}</div>
        <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
          <table style={{ width: "100%", borderCollapse: "collapse" }}>
            <thead><tr>
              <th style={tableTh}>Who</th><th style={tableTh}>Hours in office</th><th style={tableTh}>Calls answered</th><th style={tableTh}>Team missed %</th>
              <th style={tableTh}>Logged</th><th style={tableTh}>From sales</th><th style={tableTh}>Gross</th><th style={tableTh}>Reduction</th><th style={tableTh}>Net points</th>
            </tr></thead>
            <tbody>
              {visibleRows.map(r => (
                <tr key={r.team_member_id}>
                  <td style={tableTd}><strong>{r.first_name}</strong> <span style={{ color: T.slate400, fontSize: 11 }}>{r.role_category}</span></td>
                  <td style={tableTd}>{fmtPts(r.hours_in_office)} <span style={{ color: T.slate400 }}>(${fmtPts(r.hour_points)})</span></td>
                  <td style={tableTd}>{r.calls_answered} <span style={{ color: T.slate400 }}>(${fmtPts(r.call_points)})</span></td>
                  <td style={tableTd}>{fmtPts(r.missed_pct)}%</td>
                  <td style={tableTd}>${fmtPts(r.logged_points)}</td>
                  <td style={tableTd}>${fmtPts(r.derived_points)}</td>
                  <td style={tableTd}>${fmtPts(r.gross_points)}</td>
                  <td style={tableTd}>{fmtPts(r.reduction_pct)}%</td>
                  <td style={{ ...tableTd, fontWeight: 700, color: T.slate900 }}>${fmtPts(r.net_points)}</td>
                </tr>
              ))}
              {!loading && visibleRows.length === 0 && <tr><td style={tableTd} colSpan={9}>Nothing to show for this week yet.</td></tr>}
            </tbody>
          </table>
        </div>
        <div style={{ fontSize: 12, color: T.slate500, marginTop: 8 }}>Team total: <strong style={{ color: T.slate800 }}>${fmtPts(teamNet)}</strong> net points. One point = one dollar.</div>
        {rows[0]?.detail && (
          <div style={{ fontSize: 12, color: T.slate500, marginTop: 4 }}>
            Team missed {Number(rows[0].detail.team_missed_calls || 0)} of {Number(rows[0].detail.team_calls_answered || 0) + Number(rows[0].detail.team_missed_calls || 0)} calls. The phone rings everyone, so a call nobody picked up — hung up or left a voicemail — counts against the whole team.
          </div>
        )}
      </div>

      <div style={cardStyle}>
        <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900, marginBottom: 10 }}>Logged this week</div>
        <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
          <table style={{ width: "100%", borderCollapse: "collapse" }}>
            <thead><tr><th style={tableTh}>Date</th>{isAdmin && <th style={tableTh}>Who</th>}<th style={tableTh}>What</th><th style={tableTh}>Customer</th><th style={tableTh}>Note</th><th style={tableTh}>Points</th><th style={tableTh}></th></tr></thead>
            <tbody>
              {myActs.map(r => (
                <tr key={r.id}>
                  <td style={tableTd}>{fmtDate(r.occurred_on)}</td>
                  {isAdmin && <td style={tableTd}>{nameOf(r.team_member_id)}</td>}
                  <td style={tableTd}>{labelOf[r.activity_key] || r.activity_key}{r.credit_available_on ? <div style={{ fontSize: 11, color: T.amber }}>clears {fmtDate(r.credit_available_on)}</div> : null}</td>
                  <td style={tableTd}>{r.customer_label || "—"}</td>
                  <td style={{ ...tableTd, maxWidth: 320 }}>{r.save_reason ? `${PRODUCT_LABEL[r.save_line] || r.save_line}: ${r.save_reason}` : (r.note || "—")}</td>
                  <td style={tableTd}>${fmtPts(r.points)}</td>
                  <td style={tableTd}>{r.source === "manual" ? <button style={btnGhost} onClick={() => voidRow("rp_void_activity", r.id, "entry")}>Remove</button> : <span style={{ fontSize: 11, color: T.slate400 }}>from sale</span>}</td>
                </tr>
              ))}
              {!loading && myActs.length === 0 && <tr><td style={tableTd} colSpan={isAdmin ? 7 : 6}>Nothing logged yet this week.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>

      <div style={cardStyle}>
        <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900, marginBottom: 10 }}>Sales this week</div>
        <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
          <table style={{ width: "100%", borderCollapse: "collapse" }}>
            <thead><tr><th style={tableTh}>Date</th><th style={tableTh}>Who</th><th style={tableTh}>Customer</th><th style={tableTh}>Household</th><th style={tableTh}>Products</th><th style={tableTh}>Cars</th><th style={tableTh}>Premium</th><th style={tableTh}>Source</th><th style={tableTh}>GNC</th><th style={tableTh}></th></tr></thead>
            <tbody>
              {mySales.map(r => (
                <tr key={r.id}>
                  <td style={tableTd}>{fmtDate(r.sale_date)}</td>
                  <td style={tableTd}>{nameOf(r.team_member_id)}{r.sourced_by_team_member_id !== r.team_member_id ? <div style={{ fontSize: 11, color: T.slate400 }}>sourced by {nameOf(r.sourced_by_team_member_id)}</div> : null}</td>
                  <td style={tableTd}>{r.customer_label}</td>
                  <td style={tableTd}>{r.household_status === "new" ? "New" : r.household_status === "winback" ? "Winback" : "Existing"}</td>
                  <td style={tableTd}>{(r.sales_log_products || []).map(p => `${PRODUCT_LABEL[p.line_of_business] || p.line_of_business} $${fmtPts(p.premium)}`).join(", ")}</td>
                  <td style={tableTd}>{r.vehicle_count ?? "—"}</td>
                  <td style={tableTd}>${fmtPts(r.total_premium)}</td>
                  <td style={tableTd}>{r.marketing_source}</td>
                  <td style={tableTd}>{r.gnc_used ? "Yes" : "No"}</td>
                  <td style={tableTd}><button style={btnGhost} onClick={() => voidRow("rp_void_sale", r.id, "sale")}>Remove</button></td>
                </tr>
              ))}
              {!loading && mySales.length === 0 && <tr><td style={tableTd} colSpan={10}>No sales logged this week.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>

      <div style={cardStyle}>
        <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900, marginBottom: 10 }}>Quotes this week <span style={{ color: T.slate400, fontWeight: 400 }}>· {myQuotes.length}</span></div>
        <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
          <table style={{ width: "100%", borderCollapse: "collapse" }}>
            <thead><tr><th style={tableTh}>Date</th>{isAdmin && <th style={tableTh}>Who</th>}<th style={tableTh}>Customer</th><th style={tableTh}>Products discussed</th><th style={tableTh}></th></tr></thead>
            <tbody>
              {myQuotes.map(r => (
                <tr key={r.id}>
                  <td style={tableTd}>{fmtDate(r.quote_date)}</td>
                  {isAdmin && <td style={tableTd}>{nameOf(r.team_member_id)}</td>}
                  <td style={tableTd}>{r.customer_label}{r.is_existing_customer ? <span style={{ fontSize: 11, color: T.slate400 }}> · existing</span> : null}</td>
                  <td style={tableTd}>{(r.products_discussed || []).map(k => PRODUCT_LABEL[k] || k).join(", ")}</td>
                  <td style={tableTd}><button style={btnGhost} onClick={() => voidRow("rp_void_quote", r.id, "quote")}>Remove</button></td>
                </tr>
              ))}
              {!loading && myQuotes.length === 0 && <tr><td style={tableTd} colSpan={isAdmin ? 5 : 4}>No quotes logged this week.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}

// =====================================================================
// Module shell
// =====================================================================
export default function ActivityLog({ userRole }) {
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "12px" : _vp.isTablet ? "16px 18px" : "20px 24px";
  const [tab, setTab, tabHref] = useTabParam("tab", "log", TABS);
  const [values, setValues] = useState([]);
  const [sources, setSources] = useState([]);
  const [types, setTypes] = useState({});
  const [roster, setRoster] = useState([]);
  const [myTeamId, setMyTeamId] = useState(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const isAdmin = ["owner", "manager"].includes(userRole);
  // Logging on someone else's behalf is the owner's alone. The server enforces
  // it too (rp_resolve_actor), so hiding the picker is not the only thing
  // stopping it. isAdmin still governs seeing the whole team's week.
  const isOwner = userRole === "owner";

  useEffect(() => {
    let alive = true;
    (async () => {
      const [v, s, pt, r, me] = await Promise.all([
        supabase.from("retention_point_values").select("activity_key, label, points, category, requires_note, sort_order, description").eq("agency_id", AGENCY_ID).eq("is_active", true).order("sort_order"),
        supabase.from("sales_marketing_sources").select("source_key, label, sort_order").eq("agency_id", AGENCY_ID).eq("is_active", true).order("sort_order"),
        supabase.from("product_types").select("line_of_business, type_key, label, sort_order").eq("agency_id", AGENCY_ID).eq("is_active", true).order("sort_order"),
        supabase.from("team_directory").select("id, first_name, role_category, is_admin_backoffice, is_test_user, archived_at, category").eq("agency_id", AGENCY_ID).eq("is_active", true).order("first_name"),
        supabase.rpc("current_team_member_id"),
      ]);
      if (!alive) return;
      setValues(Array.isArray(v.data) ? v.data : []);
      setSources(Array.isArray(s.data) ? s.data : []);
      // types under each line, e.g. { auto: [Private Passenger, Classic, ...] }.
      // A line with no rows logs as the line itself.
      const grouped = {};
      for (const t of (Array.isArray(pt.data) ? pt.data : [])) {
        (grouped[t.line_of_business] = grouped[t.line_of_business] || []).push(t);
      }
      setTypes(grouped);
      setRoster((Array.isArray(r.data) ? r.data : []).filter(t => !t.archived_at && !t.is_test_user && !t.is_admin_backoffice && t.category === "agency"));
      setMyTeamId(me?.data || null);
    })();
    return () => { alive = false; };
  }, []);

  const bump = () => setRefreshKey(k => k + 1);
  const tabs = [
    { id: "log", label: "Log" },
    { id: "week", label: "My week" },
  ];

  return (
    <div style={{ padding: _pad, display: "grid", gap: 16 }}>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 12, alignItems: "center", justifyContent: "space-between" }}>
        <div>
          <div style={{ fontSize: 20, fontWeight: 800, color: T.slate900 }}>Production</div>
          <div style={{ fontSize: 13, color: T.slate500 }}>What you wrote, quoted, kept, and lost. Logged as it happens.</div>
        </div>
      </div>
      <div style={{ display: "flex", gap: 6, overflowX: "auto", whiteSpace: "nowrap", borderBottom: `1px solid ${T.slate200}`, paddingBottom: 6 }}>
        {tabs.map(t => (
          <TabLink key={t.id} href={tabHref(t.id)} onSelect={() => setTab(t.id)} style={{
            flexShrink: 0, padding: "8px 14px", borderRadius: 8, fontSize: 13, fontWeight: 700, textDecoration: "none",
            background: tab === t.id ? T.blueLt : "transparent", color: tab === t.id ? T.blue : T.slate600,
          }}>{t.label}</TabLink>
        ))}
      </div>

      {tab === "log"  && <EntryPage values={values} sources={sources} types={types} isOwner={isOwner} roster={roster} onLogged={bump} refreshKey={refreshKey} />}
      {tab === "week" && <WeekView isAdmin={isAdmin} myTeamId={myTeamId} roster={roster} values={values} refreshKey={refreshKey} />}
    </div>
  );
}
