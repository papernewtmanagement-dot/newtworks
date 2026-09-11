import { useState, useEffect, useMemo, useCallback } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useViewport } from "../lib/hooks.js";
import { useTabParam, TabLink } from "../lib/routing.jsx";
import { T } from "../lib/theme.js";
import EarningPotentialTab from "../components/EarningPotentialTab.jsx";

// ============================================================
// ActivityLog — the Production module (nav label "Production", route
// /production; the old /activity route still resolves). Team capture
// for Retention Points, sales, quotes, and cancelations.
//
// ONE flat page, Peter's layout (2026-09-04):
//  * Row 1, one wrapping row: Log for (owner), first name, last initial,
//    Relationship (New / Existing / Winback). Date reads "Today" with a
//    link to change it; the date box appears only when it is not today.
//  * First name suggests customers already on file (rp_customer_suggest,
//    eight matches per keystroke after two letters, nothing cached), so
//    "Anna S." is spelled one way and cancelations can match sales.
//  * "Add Activity" dropdown, cheapest first. Each pick is a pill with
//    an x; the same item can be added twice (two policy changes = two
//    pills = two rows). Pivot is on the list at $0: tracked, not paid.
//  * "Add Policy" dropdown adds a pill on its own row, like activities.
//    The pill you tapped last is the one being edited below it: type,
//    Quoted / Sold / Quoted and sold / Canceled, premium and cars once
//    money is involved. The pill shows what it has so far.
//  * The FIT conversation scorecard is one compact row under the note:
//    10 parts, tap 1 / 2 / 3, blank means it didn't come up. Score any
//    part and it rides on the entry into fit_scorecards exactly as the
//    Scorecards page writes it; My week shows the week's average.
//  * Bottom row, only what applies: ECRM link (sale), Marketing type
//    (sale or quote), Lead source (referral), then the note.
//  * A canceled policy is matched server-side to the sale that wrote it
//    (same customer + line, 6-month window on auto, 12 on the rest) and
//    the Multiline credit comes back prorated; the green bar says so.
//  * Earning Potential (owner only) lives here as its own tab, moved from
//    Team; it is the shared EarningPotentialTab component untouched.
//  * My week is the scoreboard: whole team, ranked, four point cards plus
//    the conversation card in one row; your own week (with the conversation
//    score) sits beside the title on every tab.
//  * Canceled has its own tab: search the customer, tap the policy, log it.
//    Not on file → this entry page opens in a popup with Canceled allowed.
//  * A sold line the household already has on file asks: replaces it, added,
//    or a different household. "Replaces it" cancels the old policy in the
//    same click (second rp_log_entry, replacement: true, no chargeback); the
//    answer is stored on the sale and shown on My week. A repeat quote for
//    the same household in a week is flagged here and marked on My week;
//    HH Quotes count distinct households, so it never counts twice.
//  * Scorecard is x / 1 / 2 / 3 (x averages as 0) and every part is scored on a quote or sale;
//    GNC Used is Setup GNC scored 3. Marketing source and Relationship are
//    required on every entry. Autopay is per policy: a tick on a sold policy,
//    or line + type + premium on the activity; the server allows one per policy.
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
  { key: "fire",     label: "Fire",                 short: "Fire" },
  { key: "life",     label: "Life",                 short: "Life" },
  { key: "health",   label: "Health",               short: "Health" },
  { key: "variable", label: "Variable",             short: "Variable" },
  { key: "bank",     label: "Bank",                 short: "Bank" },
];
const PRODUCT_LABEL = Object.fromEntries(PRODUCTS.map(p => [p.key, p.label]));
const PRODUCT_SHORT = Object.fromEntries(PRODUCTS.map(p => [p.key, p.short]));
const SERVICE_PREFIX = "service_task";
const RELATIONSHIPS = [
  { key: "new",      label: "New" },
  { key: "existing", label: "Existing" },
  { key: "winback",  label: "Winback" },
];
const TABS = ["log", "issued", "canceled", "week", "changes"];
const CARD_PARTS = [
  { key: "demeanor_score",        label: "Demeanor",              short: "Demeanor" },
  { key: "frogs_score",           label: "FROGS",                 short: "FROGS" },
  { key: "intro_score",           label: "Intro",                 short: "Intro" },
  { key: "eligibility_score",     label: "Determine Eligibility", short: "Eligibility" },
  { key: "setup_gnc_score",       label: "Setup GNC",             short: "Setup GNC" },
  { key: "uncover_gap_score",     label: "Uncover the Gap",       short: "Uncover" },
  { key: "bridge_gap_score",      label: "Bridge the Gap",        short: "Bridge" },
  { key: "customize_close_score", label: "Customize & Close",     short: "Close" },
  { key: "set_followup_score",    label: "Set FU",                short: "Set FU" },
  { key: "review_referral_score", label: "Review & Referral",     short: "Rev & Ref" },
];

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
const radioRow = { display: "flex", gap: 12, alignItems: "center", height: 41, fontSize: 14, color: T.slate800 };
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
    const back = cs.filter(c => Number(c.chargeback_points) > 0);
    parts.push(`canceled: ${lines}` + (voided > 0 ? `, ${voided} unpaid save${voided === 1 ? "" : "s"} taken back` : "")
      + (back.length ? `, $${fmtPts(back.reduce((n, c) => n + Number(c.chargeback_points), 0))} Multiline credit charged back (${back.map(c => `${PRODUCT_SHORT[c.policy_line]} sold ${fmtDate(c.matched_submitted_date)}, ${Math.round(Number(c.window_fraction_left) * 100)}% of the window left`).join("; ")})` : ""));
  }
  const sc = data?.scorecard;
  if (sc) parts.push(`scorecard ${sc.average_score == null ? "" : Number(sc.average_score).toFixed(2)} across ${sc.scored} part${sc.scored === 1 ? "" : "s"}`);
  return `Logged for ${data?.customer || "the customer"}: ${parts.join("; ")}.`;
}

// =====================================================================
// Entry page — one customer, one contact, everything that happened, on
// one flat page. One Log button; one RPC that saves all of it or none.
// =====================================================================
function EntryPage({ values, sources, types, isOwner, roster, onLogged, refreshKey, allowCancel = false, presetFirst = "" }) {
  const today = todayCentral();
  const [first, setFirst] = useState(presetFirst || "");
  const statuses = allowCancel ? STATUSES : STATUSES.filter(st => st.key !== "canceled");
  const [dupQuotes, setDupQuotes] = useState([]);   // this week's quotes already on file for this household
  const [onFileAnswer, setOnFileAnswer] = useState({}); // policy id -> "replaces" | "added" | "different" when the household already has that line
  const [initial, setInitial] = useState("");
  const [date, setDate] = useState(today);
  const [dateOpen, setDateOpen] = useState(false);
  const [logFor, setLogFor] = useState(null);
  const [suggest, setSuggest] = useState([]);      // customer names on file that match what's typed
  const [onFile, setOnFile] = useState([]);        // this customer's active sold policies (rp_sold_on_file)
  const [relationship, setRelationship] = useState("");
  const [source, setSource] = useState("");
  const [sourcedBy, setSourcedBy] = useState("");
  const [activities, setActivities] = useState([]);  // [{id, key}]
  const [saveLine, setSaveLine] = useState("");
  const [saveReason, setSaveReason] = useState("");
  const [policies, setPolicies] = useState([]);      // [{id, line, type, status, premium, vehicles, isNewLine}]
  const [activePolicy, setActivePolicy] = useState(null);   // id of the policy pill being edited
  const [cReason, setCReason] = useState("");
  const [scores, setScores] = useState({});                 // scorecard parts scored on this entry (blank = didn't come up)
  const [recTurned, setRecTurned] = useState(false);
  const [recUrl, setRecUrl] = useState("");
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

  // same household quoted already this week? Logs anyway; the same household counts once for HH quotes.
  useEffect(() => {
    const f = first.trim(), i = initial.trim().toUpperCase();
    if (!f || !/^[A-Z]$/.test(i)) { setDupQuotes([]); return undefined; }
    let alive = true;
    const t = setTimeout(async () => {
      const { data } = await supabase.from("quote_log").select("id, team_member_id, quote_date")
        .eq("agency_id", AGENCY_ID).eq("status", "active").eq("customer_label", `${f} ${i}.`).eq("week_end_date", weekEndOf(date));
      if (alive) setDupQuotes(Array.isArray(data) ? data : []);
    }, 300);
    return () => { alive = false; clearTimeout(t); };
  }, [first, initial, date]);

  // what this customer has on file, once the name is complete
  useEffect(() => {
    const f = first.trim(), i = initial.trim();
    if (!f || !/^[A-Za-z]$/.test(i)) { setOnFile([]); return undefined; }
    let alive = true;
    const t = setTimeout(async () => {
      const { data } = await supabase.rpc("rp_sold_on_file", { p_customer_first: f, p_customer_last_initial: i });
      if (alive) setOnFile(Array.isArray(data) ? data : []);
    }, 300);
    return () => { alive = false; clearTimeout(t); };
  }, [first, initial]);
  // the sold policy on file that a canceled row would be matched to (same line, same type first, most recent, not already canceled)
  const soldMatch = (p) => onFile
    .filter(r => r.line_of_business === p.line && !r.already_canceled && (!date || r.submitted_date <= date) && (!date || r.window_end > date))
    .sort((a, b) => ((b.product_type === p.type) - (a.product_type === p.type)) || (a.submitted_date < b.submitted_date ? 1 : -1))[0] || null;

  const addActivity = (key) => { if (key) setActivities(list => [...list, { id: newPolicyId(), key, line: "", type: "", premium: "" }]); };
  const editActivity = (id, patch) => setActivities(list => list.map(a => a.id === id ? { ...a, ...patch } : a));
  const dropActivity = (id) => setActivities(list => list.filter(a => a.id !== id));
  const addPolicy = (line) => {
    if (!line) return;
    const id = newPolicyId();
    setPolicies(list => [...list, { id, line, type: "", status: "", premium: "", vehicles: "1", isNewLine: true }]);
    setActivePolicy(id);
  };
  const editPolicy = (id, patch) => setPolicies(list => list.map(p => p.id === id ? { ...p, ...patch } : p));
  // Canceled: bring in the premium and cars we recorded on the sale, editable; blank when nothing is on file
  const setStatus = (p, status) => {
    const patch = { status };
    if (status === "canceled") {
      const m = soldMatch(p);
      patch.matchedId = m ? m.sale_product_id : null;
      if (m && p.premium === "") patch.premium = String(m.premium ?? "");
      if (m && p.line === "auto" && m.vehicle_count) patch.vehicles = String(m.vehicle_count);
      if (m && !p.type && m.product_type) patch.type = m.product_type;
    } else {
      patch.matchedId = null;
    }
    editPolicy(p.id, patch);
  };
  const dropPolicy = (id) => { setPolicies(list => list.filter(p => p.id !== id)); setActivePolicy(a => a === id ? null : a); };
  const setScore = (k, v) => setScores(sc => ({ ...sc, [k]: sc[k] === v ? null : v }));
  const cardChosen = CARD_PARTS.filter(pt => scores[pt.key] != null).length;          // x counts as chosen
  const cardAvg = cardChosen ? CARD_PARTS.reduce((s, pt) => s + (scores[pt.key] != null ? Number(scores[pt.key]) : 0), 0) / cardChosen : null;   // x averages as 0

  // ---- what is in the entry right now ----
  const hasSave = activities.some(a => a.key === "cancelation_saved");
  const hasReview = activities.some(a => a.key === "policy_review");
  const activityItems = activities.filter(a => byKey[a.key]).map(a =>
    a.key === "cancelation_saved" ? { activity_key: a.key, save_line: saveLine, save_reason: saveReason.trim() }
    : a.key === "autopay_enrollment" ? { activity_key: a.key, policy_line: a.line, product_type: a.type || null, premium: a.premium === "" ? null : Number(a.premium) }
    : { activity_key: a.key });
  const activityTotal = activityItems.reduce((s, it) => s + Number(byKey[it.activity_key]?.points || 0), 0);
  const quoted = policies.filter(p => p.status === "quoted" || p.status === "quoted_sold");
  const sold = policies.filter(p => p.status === "sold" || p.status === "quoted_sold");
  const canceled = policies.filter(p => p.status === "canceled");
  const saleTotal = sold.reduce((s, p) => s + (Number(p.premium) || 0), 0);

  const hasActivity = activityItems.length > 0;
  const hasQuote = quoted.length > 0;
  const hasSale = sold.length > 0;
  const hasCxl = canceled.length > 0;
  const hasCard = cardChosen > 0;
  const needsCard = hasQuote || hasSale || cardChosen > 0;
  const hasAnything = hasActivity || hasQuote || hasSale || hasCxl || hasCard;
  const customerOk = !!first.trim() && /^[A-Za-z]$/.test(initial.trim());
  const isReferral = source === "referral";
  const householdFresh = relationship === "new" || relationship === "winback";
  const needsType = (line) => (types[line] || []).length > 0;
  const isSold = (p) => p.status === "sold" || p.status === "quoted_sold";
  const needsMoney = (p) => isSold(p) || p.status === "canceled";
  const showDate = dateOpen || date !== today;
  const oldOnFile = (p) => onFile.filter(x => x.line_of_business === p.line && !x.already_canceled).sort((a, b) => (a.submitted_date < b.submitted_date ? 1 : -1))[0] || null;
  const flagged = sold.filter(p => oldOnFile(p));
  const replaces = flagged.filter(p => onFileAnswer[p.id] === "replaces");
  const showSuggest = suggest.length > 0 && !(suggest.length === 1 && suggest[0].customer_first_name === first.trim() && (suggest[0].customer_last_initial || "") === initial.trim().toUpperCase());

  // ---- what still needs fixing, in plain words (mirrors the server rules) ----
  const problems = [];
  if (!customerOk) problems.push("Customer first name and last initial.");
  if (!hasAnything) problems.push("Add an activity or a policy, or score the conversation.");
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
  if (!relationship) problems.push("Pick the relationship.");
  if ((hasSale || hasQuote) && !source) problems.push("Pick the marketing source.");
  if (hasSale && !ecrm.trim()) problems.push("A sale needs the ECRM opportunity link.");
  if (needsCard && cardChosen < CARD_PARTS.length) problems.push("Score every part of the scorecard. Tap x on a part you did not do.");
  if (activities.some(a => a.key === "autopay_enrollment" && (!a.line || (needsType(a.line) && !a.type) || a.premium === "" || !(Number(a.premium) >= 0)))) problems.push("Each autopay needs the policy line, type, and premium.");
  if (flagged.some(p => !onFileAnswer[p.id])) problems.push("Say whether the new policy replaces the one on file, is added to it, or is a different household.");
  if (hasSale && hasCxl) {
    const soldLines = new Set(sold.map(p => p.line));
    const clash = [...new Set(canceled.filter(p => soldLines.has(p.line)).map(p => p.line))];
    if (clash.length) problems.push(`${clash.map(k => PRODUCT_SHORT[k]).join(", ")} is both sold and canceled in this entry. Log those as two entries.`);
  }
  if (ecrm.trim() && !/^https?:\/\//i.test(ecrm.trim())) problems.push("The ECRM link must start with http.");

  const reset = (keep) => {
    if (!keep) { setFirst(""); setInitial(""); setDate(today); setDateOpen(false); }
    setSuggest([]);
    setRelationship(""); setSource(""); setSourcedBy("");
    setActivities([]); setSaveLine(""); setSaveReason("");
    setPolicies([]); setActivePolicy(null); setCReason(""); setScores({}); setRecTurned(false); setRecUrl(""); setEcrm(""); setNote(""); setOnFileAnswer({});
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
      const matched = (p) => ({ matched_sale_product_id: p.matchedId || null });
      const payload = {
        customer_first: first.trim(), customer_last_initial: initial.trim(), occurred_on: date,
        ecrm_url: ecrm.trim() || null, note: note.trim() || null, team_member_id: logFor,
        relationship_type: relationship || null,
        gnc_used: scores.setup_gnc_score === 3,
        marketing_source: source || null,
        sourced_by_team_member_id: isReferral && sourcedBy ? sourcedBy : null,
        activity: hasActivity ? { items: activityItems } : null,
        quote: hasQuote ? { items: quoted.map(row) } : null,
        sale: hasSale ? {
          products: sold.map(p => ({ ...row(p), ...money(p), policy_count: 1, is_new_line: oldOnFile(p) ? false : (householdFresh ? true : !!p.isNewLine), autopay: !!p.autopay })),
          on_file_answer: flagged.length ? (replaces.length ? "replaces" : flagged.some(p => onFileAnswer[p.id] === "added") ? "added" : "different") : null,
          replaced_sale_product_id: replaces.length ? oldOnFile(replaces[0]).sale_product_id : null,
        } : null,
        cancelation: hasCxl ? { items: canceled.map(p => ({ ...row(p), ...money(p), ...matched(p) })), reason: cReason.trim() || null } : null,
        scorecard: hasCard ? { ...scores, recording_turned_in: !!recTurned, recording_url: recTurned ? (recUrl || null) : null } : null,
      };
      const { data, error } = await supabase.rpc("rp_log_entry", { p_payload: payload });
      if (error) { setErr(errText(error)); return; }
      if (!data?.ok) { setErr(errText(data)); return; }
      let summary = summarizeEntry(data);
      let cxlResult = null;
      if (replaces.length) {
        // the confirmed replacements cancel the old policies now, in the same click; no chargeback (the household kept the line)
        const items = replaces.map(p => { const o = oldOnFile(p); return { line_of_business: o.line_of_business, product_type: o.product_type || null, premium: Number(o.premium ?? 0),
          vehicle_count: o.line_of_business === "auto" ? Number(o.vehicle_count || 1) : null, matched_sale_product_id: o.sale_product_id, replacement: true }; });
        const c = await supabase.rpc("rp_log_entry", { p_payload: {
          customer_first: first.trim(), customer_last_initial: initial.trim(), occurred_on: date, team_member_id: logFor, relationship_type: "existing",
          cancelation: { items, reason: "Replaced by the new policy logged with the sale" },
        } });
        if (c.error || !c.data?.ok) summary += ` The old ${replaces.map(p => PRODUCT_SHORT[p.line]).join(", ")} could not be canceled: ${errText(c.error || c.data)}. Cancel it on the Canceled tab.`;
        else { cxlResult = c.data; summary += ` Old ${replaces.map(p => PRODUCT_SHORT[p.line]).join(", ")} canceled as replaced, no chargeback.`; }
      }
      setOk(summary);
      setLast({ result: data, cxlResult, first: first.trim(), initial: initial.trim(), date });
      reset();
      onLogged?.();
    } catch (e) { setErr(errText(e)); } finally { setBusy(false); }
  };

  const undo = async () => {
    if (!last || busy) return;
    setBusy(true);
    try {
      let undone = 0;
      if (last.cxlResult) {
        const u = await supabase.rpc("rp_undo_entry", { p_result: last.cxlResult });
        if (u.error) { setErr(errText(u.error)); return; }
        undone += Number(u.data?.undone || 0);
      }
      const { data, error } = await supabase.rpc("rp_undo_entry", { p_result: last.result });
      if (error) { setErr(errText(error)); return; }
      undone += Number(data?.undone || 0);
      setOk(`Undone. ${undone} row${undone === 1 ? "" : "s"} removed.`);
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
  useEffect(() => { /* keep matches fresh if the name changes after a row was marked canceled */
    setPolicies(list => list.map(p => p.status === "canceled" ? { ...p, matchedId: (soldMatch(p) || {}).sale_product_id || null } : p));
  }, [onFile]);
  const policyPill = (p) => {
    const bits = [PRODUCT_SHORT[p.line]];
    const t = (types[p.line] || []).find(x => x.type_key === p.type); if (t) bits.push(t.label);
    const st = STATUSES.find(x => x.key === p.status); bits.push(st ? st.label : "needs details");
    if (needsMoney(p) && p.premium !== "") bits.push(`$${fmtPts(p.premium)}`);
    return bits.join(" · ");
  };
  const active = policies.find(p => p.id === activePolicy) || null;

  return (
    <div>
      <div style={cardStyle}>
        <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900, marginBottom: 4 }}>What happened with this customer?</div>
        <div style={{ fontSize: 13, color: T.slate500, marginBottom: 16 }}>Add what happened. One button saves it all.</div>

        {/* ---- row 1: every first field, wrapping ---- */}
        <div style={wrapRow}>
          {isOwner && (
            <div style={{ flex: "0 1 120px", minWidth: 0 }}>
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
          <div style={{ flex: "0 0 58px" }}>
            <label style={labelStyle}>Initial</label>
            <input style={{ ...inputBase, textAlign: "center" }} value={initial} maxLength={1} onChange={e => setInitial(e.target.value)} placeholder="S" />
          </div>
          <div style={{ flex: "0 1 150px", minWidth: 0 }}>
            <label style={labelStyle}>Relationship</label>
            <select style={inputBase} value={relationship} onChange={e => setRelationship(e.target.value)}>
              <option value="">Pick one</option>
              {RELATIONSHIPS.map(r => <option key={r.key} value={r.key}>{r.label}</option>)}
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
          {activities.filter(a => a.key === "autopay_enrollment").map(a => (
            <div key={a.id} style={{ ...wrapRow, marginTop: 10, padding: 10, background: T.slate50, borderRadius: 8 }}>
              <div style={{ fontWeight: 700, color: T.slate800, flex: "0 0 auto", paddingBottom: 10 }}>Autopay on</div>
              <div style={field(130)}>
                <label style={labelStyle}>Line</label>
                <select style={inputBase} value={a.line} onChange={e => editActivity(a.id, { line: e.target.value, type: "" })}>
                  <option value="">Pick one</option>
                  {PRODUCTS.map(pr => <option key={pr.key} value={pr.key}>{pr.label}</option>)}
                </select>
              </div>
              {needsType(a.line) && (
                <div style={field(150)}>
                  <label style={labelStyle}>Type</label>
                  <select style={inputBase} value={a.type} onChange={e => editActivity(a.id, { type: e.target.value })}>
                    <option value="">Pick one</option>
                    {(types[a.line] || []).map(t => <option key={t.type_key} value={t.type_key}>{t.label}</option>)}
                  </select>
                </div>
              )}
              <div style={field(130)}>
                <label style={labelStyle}>Premium</label>
                <input type="number" inputMode="decimal" min="0" step="0.01" style={inputBase} value={a.premium} onChange={e => editActivity(a.id, { premium: e.target.value })} placeholder="0.00" />
              </div>
            </div>
          ))}
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

        {/* ---- policies: Add dropdown + pills on one row; the pill tapped last is edited below ---- */}
        <div style={blockStyle}>
          <div style={{ ...wrapRow, alignItems: "center" }}>
            <select style={addSelect} value="" onChange={e => addPolicy(e.target.value)}>
              <option value="">+ Add Policy</option>
              {PRODUCTS.map(p => <option key={p.key} value={p.key}>{p.label}</option>)}
            </select>
            {policies.map(p => (
              <span key={p.id} style={{ ...pill, cursor: "pointer", outline: p.id === activePolicy ? `2px solid ${T.blue}` : "none" }} onClick={() => setActivePolicy(p.id)}>
                {policyPill(p)}
                <button type="button" style={pillX} onClick={e => { e.stopPropagation(); dropPolicy(p.id); }} aria-label="remove">×</button>
              </span>
            ))}
          </div>

          {active && (
            <div style={{ ...wrapRow, marginTop: 10, padding: 10, background: T.slate50, borderRadius: 8 }}>
              <div style={{ fontWeight: 700, color: T.slate800, flex: "0 0 auto", paddingBottom: 10 }}>{PRODUCT_LABEL[active.line]}</div>
              {needsType(active.line) && (
                <div style={field(150)}>
                  <label style={labelStyle}>Type</label>
                  <select style={inputBase} value={active.type} onChange={e => editPolicy(active.id, { type: e.target.value })}>
                    <option value="">Pick one</option>
                    {(types[active.line] || []).map(t => <option key={t.type_key} value={t.type_key}>{t.label}</option>)}
                  </select>
                </div>
              )}
              <div style={field(150)}>
                <label style={labelStyle}>What happened</label>
                <select style={inputBase} value={active.status} onChange={e => setStatus(active, e.target.value)}>
                  <option value="">Pick one</option>
                  {statuses.map(st => <option key={st.key} value={st.key}>{st.label}</option>)}
                </select>
              </div>
              {needsMoney(active) && (
                <div style={field(140)}>
                  <label style={labelStyle}>Premium{active.status === "canceled" ? (() => { const m = soldMatch(active); return m
                    ? <span style={{ color: T.blue, fontWeight: 400 }}> · on file ${fmtPts(m.premium)}, sold {fmtDate(m.submitted_date)}</span>
                    : <span style={hintStyle}> · no sale on file</span>; })() : null}</label>
                  <input type="number" inputMode="decimal" min="0" step="0.01" style={inputBase} value={active.premium} onChange={e => editPolicy(active.id, { premium: e.target.value })} placeholder="0.00" />
                </div>
              )}
              {needsMoney(active) && active.line === "auto" && (
                <div style={field(70)}>
                  <label style={labelStyle}>Cars</label>
                  <input type="number" inputMode="numeric" min="1" step="1" style={inputBase} value={active.vehicles} onChange={e => editPolicy(active.id, { vehicles: e.target.value })} />
                </div>
              )}
              {isSold(active) && (
                <label style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 13, color: T.slate700, paddingBottom: 10, flex: "0 0 auto" }} title="The policy went on automatic payment as you set it up. One autopay credit per policy.">
                  <input type="checkbox" checked={!!active.autopay} onChange={e => editPolicy(active.id, { autopay: e.target.checked })} />
                  Autopay
                </label>
              )}
              {isSold(active) && relationship === "existing" && (
                <label style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 13, color: T.slate700, paddingBottom: 10, flex: "0 0 auto" }}>
                  <input type="checkbox" checked={!!active.isNewLine} onChange={e => editPolicy(active.id, { isNewLine: e.target.checked })} />
                  New line
                </label>
              )}
              <button type="button" style={{ ...btnGhost, marginLeft: "auto", marginBottom: 6 }} onClick={() => setActivePolicy(null)}>Done</button>
            </div>
          )}
          {hasCxl && (
            <div style={{ marginTop: 10 }}>
              <label style={labelStyle}>Why did it cancel? <span style={hintStyle}>(optional)</span></label>
              <input style={inputBase} value={cReason} onChange={e => setCReason(e.target.value)} placeholder="what they told us" />
            </div>
          )}
          {flagged.map(p => {
            const r = oldOnFile(p);
            const oldLabel = typeLabel(types, r.line_of_business, r.product_type) || PRODUCT_SHORT[p.line];
            const pick = (v) => setOnFileAnswer(a => ({ ...a, [p.id]: v }));
            return (
              <div key={p.id} style={{ padding: "10px 12px", borderRadius: 8, background: T.amberLt, color: T.amber, fontSize: 13, fontWeight: 600, marginTop: 10 }}>
                <div>{preview} already has {oldLabel} on file: ${fmtPts(r.premium)}{r.vehicle_count ? `, ${plural(r.vehicle_count, "car")}` : ""}, sold {fmtDate(r.submitted_date)}. This new {PRODUCT_SHORT[p.line]}:</div>
                <div style={{ ...chipRow, marginTop: 8 }}>
                  <span style={chip(onFileAnswer[p.id] === "replaces")} onClick={() => pick("replaces")}>Replaces it — cancel the old one for me</span>
                  <span style={chip(onFileAnswer[p.id] === "added")} onClick={() => pick("added")}>Added — they keep both</span>
                  <span style={chip(onFileAnswer[p.id] === "different")} onClick={() => pick("different")}>Different household</span>
                </div>
              </div>
            );
          })}
          {hasQuote && dupQuotes.length > 0 && (
            <div style={{ padding: "8px 12px", borderRadius: 8, background: T.amberLt, color: T.amber, fontSize: 13, fontWeight: 600, marginTop: 10 }}>
              {preview} was already quoted this week ({dupQuotes.map(d => `${(roster || []).find(t => t.id === d.team_member_id)?.first_name || "someone"} on ${fmtDate(d.quote_date)}`).join(", ")}). It still logs; the same household counts once for HH quotes.
            </div>
          )}
          {hasSale && (
            <div style={{ fontSize: 13, color: T.slate700, marginTop: 8 }}>
              <strong>Total premium sold: ${fmtPts(saleTotal)}.</strong> <span style={{ color: T.slate500 }}>Multiline and Referral credits are added on their own, once per line.</span>
            </div>
          )}
        </div>

        {/* ---- bottom row: ECRM link (sale), marketing source (quote or sale), lead source (referral), note ---- */}
        <div style={{ ...wrapRow, ...blockStyle }}>
          {hasSale && (
            <div style={field(200)}>
              <label style={labelStyle}>ECRM link <span style={{ color: T.red }}>(required)</span></label>
              <input style={inputBase} value={ecrm} onChange={e => setEcrm(e.target.value)} placeholder="https://…" />
            </div>
          )}
          {(hasSale || hasQuote) && (
            <div style={{ flex: "0 1 150px", minWidth: 0 }}>
              <label style={labelStyle}>Marketing source</label>
              <select style={inputBase} value={source} onChange={e => setSource(e.target.value)}>
                <option value="">Pick one</option>
                {(sources || []).map(s => <option key={s.source_key} value={s.source_key}>{s.label}</option>)}
              </select>
            </div>
          )}
          {(hasSale || hasQuote) && isReferral && (
            <div style={{ flex: "0 1 140px", minWidth: 0 }}>
              <label style={labelStyle}>Lead source</label>
              <select style={inputBase} value={sourcedBy} onChange={e => setSourcedBy(e.target.value)}>
                <option value="">{logFor ? "The person logged for" : "Me"}</option>
                {(roster || []).map(t => <option key={t.id} value={t.id}>{t.first_name}</option>)}
              </select>
            </div>
          )}
          <div style={field(220)}>
            <label style={labelStyle}>Note {hasReview ? <span style={{ color: T.red }}>(required for a policy review)</span> : null}</label>
            <input style={inputBase} value={note} onChange={e => setNote(e.target.value)} placeholder="Reviewed liability limits and umbrella; added rental reimbursement" />
          </div>
        </div>

        {/* ---- scorecard: one compact row, 10 parts, x / 1 / 2 / 3; every part on a quote or sale ---- */}
        <div style={{ marginTop: 14 }}>
          <div style={{ ...labelStyle, display: "flex", flexWrap: "wrap", gap: 8, alignItems: "baseline" }}>
            <span>Scorecard {cardAvg != null ? <span style={{ color: T.blue }}>· {cardAvg.toFixed(2)}</span> : null}{needsCard ? <span style={{ color: T.red }}> (every part)</span> : null}</span>
            <span style={hintStyle}>x didn't do it · 1 did it poorly, didn't land · 2 did it well, didn't land · 3 did it well, landed. Setup GNC at 3 means GNC was used.</span>
          </div>
          <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
            {CARD_PARTS.map(pt => (
              <div key={pt.key} style={{ flex: "1 1 88px", minWidth: 88, padding: "6px 6px 5px", background: T.slate50, borderRadius: 8, textAlign: "center" }}>
                <div style={{ fontSize: 10, fontWeight: 700, color: T.slate600, textTransform: "uppercase", letterSpacing: 0.3, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", marginBottom: 4 }} title={pt.label}>{pt.short}</div>
                <div style={{ display: "flex", justifyContent: "center", gap: 3 }}>
                  {[0, 1, 2, 3].map(v => (
                    <span key={v} onClick={() => setScore(pt.key, v)} title={v === 0 ? "Didn't do it" : v === 1 ? "Did it poorly, didn't land" : v === 2 ? "Did it well, didn't land" : "Did it well, landed"} style={{
                      width: 22, height: 24, lineHeight: "22px", borderRadius: 6, fontSize: 12, fontWeight: 700, cursor: "pointer", userSelect: "none", boxSizing: "border-box",
                      border: `1px solid ${scores[pt.key] === v ? (v === 0 ? T.slate500 : T.blue) : T.slate300}`,
                      background: scores[pt.key] === v ? (v === 0 ? T.slate500 : T.blue) : T.white, color: scores[pt.key] === v ? T.white : T.slate600,
                    }}>{v === 0 ? "x" : v}</span>
                  ))}
                </div>
              </div>
            ))}
          </div>
          {hasCard && (
            <div style={{ ...wrapRow, alignItems: "center", marginTop: 8 }}>
              <label style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 13, color: T.slate700 }}>
                <input type="checkbox" checked={recTurned} onChange={e => setRecTurned(e.target.checked)} /> Recording turned in
              </label>
              {recTurned && <div style={field(220)}><input style={inputBase} value={recUrl} onChange={e => setRecUrl(e.target.value)} placeholder="recording link" /></div>}
            </div>
          )}
        </div>

        <div style={{ display: "flex", flexWrap: "wrap", gap: 12, alignItems: "center", marginTop: 18, position: "sticky", bottom: 8, background: T.white, padding: "8px 0", zIndex: 3 }}>
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
// Monthly spot-check (core principle 450). Admin only. Ten random
// self-logged entries from the chosen month, stable until verified.
// Verify stamps verified_at; Remove is the same void the tables use.
// =====================================================================
function SpotCheck({ isAdmin }) {
  const today = todayCentral();
  const prevMonth = (() => { const [y, m] = today.split("-").map(Number); const d = new Date(Date.UTC(y, m - 2, 1)); return d.toISOString().slice(0, 10); })();
  const [month, setMonth] = useState(prevMonth);
  const [rows, setRows] = useState([]);
  const [remaining, setRemaining] = useState(0);
  const [busyId, setBusyId] = useState(null);
  const [err, setErr] = useState("");
  const [tick, setTick] = useState(0);

  useEffect(() => {
    if (!isAdmin) return undefined;
    let alive = true;
    (async () => {
      const { data, error } = await supabase.rpc("rp_spot_check_sample", { p_month: month, p_limit: 10 });
      if (!alive) return;
      if (error) { setErr(errText(error)); return; }
      const list = Array.isArray(data) ? data : [];
      setRows(list); setRemaining(list.length ? Number(list[0].remaining) : 0);
    })();
    return () => { alive = false; };
  }, [isAdmin, month, tick]);

  const act = async (fn, id) => {
    setErr(""); setBusyId(id);
    try {
      const { error } = await fn();
      if (error) setErr(errText(error)); else setTick(t => t + 1);
    } finally { setBusyId(null); }
  };
  const monthLabel = (iso) => { const [y, m] = iso.split("-").map(Number); return new Date(Date.UTC(y, m - 1, 1)).toLocaleDateString("en-US", { month: "long", year: "numeric", timeZone: "UTC" }); };
  const months = [0, 1, 2].map(k => { const [y, m] = today.split("-").map(Number); return new Date(Date.UTC(y, m - 1 - k, 1)).toISOString().slice(0, 10); });

  if (!isAdmin) return null;
  return (
    <div style={cardStyle}>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center", justifyContent: "space-between", marginBottom: 4 }}>
        <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>Spot-check</div>
        <select style={{ ...inputBase, width: "auto" }} value={month} onChange={e => setMonth(e.target.value)}>
          {months.map(m => <option key={m} value={m}>{monthLabel(m)}</option>)}
        </select>
      </div>
      <div style={{ fontSize: 12, color: T.slate500, marginBottom: 12 }}>
        Ten random self-logged entries from the month, the same ten until you clear them. Open the ECRM link, check the note, tap Verified. {remaining > 10 ? `${remaining} still unverified this month.` : remaining > 0 ? `${remaining} left this month.` : "Nothing left to check this month."}
      </div>
      {rows.length > 0 && (
        <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
          <table style={{ width: "100%", borderCollapse: "collapse" }}>
            <thead><tr><th style={tableTh}>Who</th><th style={tableTh}>Date</th><th style={tableTh}>What</th><th style={tableTh}>Customer</th><th style={tableTh}>Note</th><th style={tableTh}>Points</th><th style={tableTh}></th></tr></thead>
            <tbody>
              {rows.map(r => (
                <tr key={r.id}>
                  <td style={tableTd}>{r.first_name || "\u2014"}</td>
                  <td style={tableTd}>{fmtDate(r.occurred_on)}</td>
                  <td style={tableTd}>{r.label || r.activity_key}</td>
                  <td style={tableTd}>{r.ecrm_url ? <a href={r.ecrm_url} target="_blank" rel="noreferrer" style={{ color: T.blue }}>{r.customer_label}</a> : r.customer_label}</td>
                  <td style={{ ...tableTd, maxWidth: 260 }}>{r.note || "\u2014"}</td>
                  <td style={tableTd}>{fmtPts(r.points)}</td>
                  <td style={{ ...tableTd, whiteSpace: "nowrap" }}>
                    <button style={{ ...btnGhost, color: T.green, marginRight: 6 }} disabled={busyId === r.id} onClick={() => act(() => supabase.rpc("rp_verify_activity", { p_id: r.id }), r.id)}>Verified</button>
                    <button style={{ ...btnGhost, color: T.red }} disabled={busyId === r.id} onClick={() => { if (window.confirm(`Remove ${r.label || r.activity_key} for ${r.customer_label}? It will not be paid.`)) act(() => supabase.rpc("rp_void_activity", { p_id: r.id, p_reason: "spot-check: could not verify" }), r.id); }}>Remove</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <Notice kind="error">{err}</Notice>
    </div>
  );
}

// =====================================================================
// Week view — points table + this week's entries
// =====================================================================
function IssuedTab({ types, refreshKey }) {
  const [rows, setRows] = useState(null);
  const [dates, setDates] = useState({});
  const [prems, setPrems] = useState({});   // issued premium per policy, defaults to what was submitted
  const [busy, setBusy] = useState(null);
  const [err, setErr] = useState("");
  const [done, setDone] = useState("");

  const load = useCallback(async () => {
    const r = await supabase.rpc("rp_pending_issue");
    setRows(Array.isArray(r.data) ? r.data : []);
  }, []);
  useEffect(() => { load(); }, [load, refreshKey]);

  const mark = async (row) => {
    setBusy(row.sale_product_id); setErr(""); setDone("");
    const prem = prems[row.sale_product_id] === undefined ? String(row.premium ?? "") : prems[row.sale_product_id];
    if (prem === "" || !(Number(prem) >= 0)) { setBusy(null); setErr("Enter the issued premium first."); return; }
    const r = await supabase.rpc("rp_mark_issued", {
      p_items: [{ sale_product_id: row.sale_product_id, issued_date: dates[row.sale_product_id] || todayCentral(), issued_premium: Number(prem) }],
    });
    setBusy(null);
    if (r.error) { setErr(errText(r.error)); return; }
    setDone(`${row.customer_label} — ${PRODUCT_SHORT[row.line_of_business] || row.line_of_business} marked issued.`);
    load();
  };

  if (rows === null) return <div style={{ ...cardStyle, color: T.slate500, fontSize: 13 }}>Loading…</div>;

  return (
    <div style={{ display: "grid", gap: 12 }}>
      <div style={{ fontSize: 13, color: T.slate500 }}>
        Policies that have been submitted but are not issued yet. Enter the issued premium, set the date it issued, and mark it.
      </div>
      {err && <Notice kind="error">{err}</Notice>}
      {done && <Notice kind="ok">{done}</Notice>}
      {rows.length === 0 ? (
        <div style={{ ...cardStyle, color: T.slate600, fontSize: 14 }}>Everything submitted has been issued. Nothing waiting.</div>
      ) : (
        <div style={{ ...cardStyle, overflowX: "auto" }}>
          <table style={{ width: "100%", borderCollapse: "collapse" }}>
            <thead>
              <tr>
                <th style={tableTh}>Customer</th>
                <th style={tableTh}>Policy</th>
                <th style={tableTh}>Submitted</th>
                <th style={tableTh}>Waiting</th>
                <th style={tableTh}>Issued premium</th>
                <th style={tableTh}>Issued</th>
                <th style={tableTh}></th>
              </tr>
            </thead>
            <tbody>
              {rows.map(r => (
                <tr key={r.sale_product_id}>
                  <td style={tableTd}>
                    {r.customer_label}
                    {r.seller && <div style={{ fontSize: 11, color: T.slate500 }}>{r.seller}</div>}
                  </td>
                  <td style={tableTd}>
                    {typeLabel(types || {}, r.line_of_business, r.product_type) || PRODUCT_SHORT[r.line_of_business] || r.line_of_business}
                    <div style={{ fontSize: 11, color: T.slate500 }}>
                      ${fmtPts(r.premium)}{r.vehicle_count ? ` · ${r.vehicle_count} car${r.vehicle_count > 1 ? "s" : ""}` : ""}
                    </div>
                  </td>
                  <td style={tableTd}>{fmtDate(r.submitted_date)}</td>
                  <td style={{ ...tableTd, color: r.days_waiting > 14 ? T.red : T.slate600, fontWeight: r.days_waiting > 14 ? 700 : 400 }}>
                    {r.days_waiting}d
                  </td>
                  <td style={tableTd}>
                    <input type="number" inputMode="decimal" min="0" step="0.01"
                      value={prems[r.sale_product_id] === undefined ? String(r.premium ?? "") : prems[r.sale_product_id]}
                      onChange={e => setPrems(d => ({ ...d, [r.sale_product_id]: e.target.value }))}
                      style={{ fontSize: 13, padding: "5px 7px", borderRadius: 7, border: `1px solid ${T.slate200}`, width: 110 }}
                    />
                  </td>
                  <td style={tableTd}>
                    <input
                      type="date"
                      value={dates[r.sale_product_id] || todayCentral()}
                      min={r.submitted_date}
                      max={todayCentral()}
                      onChange={e => setDates(d => ({ ...d, [r.sale_product_id]: e.target.value }))}
                      style={{ fontSize: 13, padding: "5px 7px", borderRadius: 7, border: `1px solid ${T.slate200}` }}
                    />
                  </td>
                  <td style={tableTd}>
                    <button
                      onClick={() => mark(r)}
                      disabled={busy === r.sale_product_id}
                      style={{
                        padding: "6px 12px", borderRadius: 7, border: "none", cursor: "pointer",
                        background: T.blue, color: "#fff", fontSize: 13, fontWeight: 700,
                        opacity: busy === r.sale_product_id ? 0.6 : 1,
                      }}
                    >Mark issued</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}


// =====================================================================
// Canceled — its own tab (Peter 2026-09-11). Search the customer, pick the
// policy that canceled, log it in two taps. Not on file? The full entry
// page opens in a popup with the Canceled option turned on; the standard
// Log tab does not offer Canceled at all.
// =====================================================================
function Modal({ title, onClose, children }) {
  return (
    <div onClick={onClose} style={{ position: "fixed", inset: 0, background: "rgba(15,23,42,0.45)", zIndex: 50, display: "flex", alignItems: "flex-start", justifyContent: "center", padding: "24px 8px", overflowY: "auto" }}>
      <div onClick={e => e.stopPropagation()} style={{ background: T.slate50, borderRadius: 14, width: "min(980px, 100%)", boxShadow: "0 20px 60px rgba(0,0,0,0.25)", padding: 12 }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "4px 8px 10px" }}>
          <div style={{ fontSize: 15, fontWeight: 700, color: T.slate900 }}>{title}</div>
          <button type="button" style={btnGhost} onClick={onClose}>Close</button>
        </div>
        {children}
      </div>
    </div>
  );
}

function CanceledTab({ values, sources, types, isOwner, isAdmin, myTeamId, roster, onLogged, refreshKey }) {
  const today = todayCentral();
  const [q, setQ] = useState("");
  const [suggest, setSuggest] = useState([]);
  const [picked, setPicked] = useState(null);      // {customer_first_name, customer_last_initial, customer_label}
  const [onFile, setOnFile] = useState([]);
  const [drafts, setDrafts] = useState({});        // sale_product_id -> {open, date, premium, vehicles, reason}
  const [recent, setRecent] = useState([]);
  const [popup, setPopup] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const [ok, setOk] = useState("");
  const nameOf = (id) => (roster || []).find(t => t.id === id)?.first_name || "—";

  useEffect(() => {
    const s = q.trim();
    if (s.length < 2) { setSuggest([]); return undefined; }
    let alive = true;
    const t = setTimeout(async () => {
      const { data } = await supabase.rpc("rp_customer_suggest", { p_prefix: s });
      if (alive) setSuggest(Array.isArray(data) ? data : []);
    }, 250);
    return () => { alive = false; clearTimeout(t); };
  }, [q]);

  useEffect(() => {
    if (!picked) { setOnFile([]); return undefined; }
    let alive = true;
    (async () => {
      const { data } = await supabase.rpc("rp_sold_on_file", { p_customer_first: picked.customer_first_name, p_customer_last_initial: picked.customer_last_initial });
      if (alive) setOnFile(Array.isArray(data) ? data : []);
    })();
    return () => { alive = false; };
  }, [picked, refreshKey]);

  useEffect(() => {
    let alive = true;
    (async () => {
      const { data } = await supabase.from("cancelation_log").select("id, team_member_id, canceled_on, customer_label, policy_line, premium, reason, status")
        .eq("agency_id", AGENCY_ID).eq("status", "active").gte("canceled_on", addDays(todayCentral(), -30)).order("canceled_on", { ascending: false }).limit(50);
      if (alive) setRecent(Array.isArray(data) ? data : []);
    })();
    return () => { alive = false; };
  }, [refreshKey]);

  const draft = (r) => drafts[r.sale_product_id] || {};
  const edit = (r, patch) => setDrafts(d => ({ ...d, [r.sale_product_id]: { ...(d[r.sale_product_id] || {}), ...patch } }));
  const cancelPolicy = async (r) => {
    const d = draft(r);
    const premium = d.premium === undefined ? String(r.premium ?? "") : d.premium;
    const vehicles = d.vehicles === undefined ? String(r.vehicle_count || 1) : d.vehicles;
    if (premium === "" || !(Number(premium) >= 0)) { setErr("Enter the premium."); return; }
    if (r.line_of_business === "auto" && !(Number(vehicles) >= 1)) { setErr("How many cars were on it?"); return; }
    setBusy(true); setErr(""); setOk("");
    try {
      const payload = {
        customer_first: picked.customer_first_name, customer_last_initial: picked.customer_last_initial, occurred_on: d.date || today,
        relationship_type: "existing", team_member_id: null,
        cancelation: { items: [{ line_of_business: r.line_of_business, product_type: r.product_type || null, premium: Number(premium),
                                 vehicle_count: r.line_of_business === "auto" ? Number(vehicles) : null, matched_sale_product_id: r.sale_product_id }],
                       reason: (d.reason || "").trim() || null },
      };
      const { data, error } = await supabase.rpc("rp_log_entry", { p_payload: payload });
      if (error) { setErr(errText(error)); return; }
      if (!data?.ok) { setErr(errText(data)); return; }
      setOk(summarizeEntry(data));
      setDrafts(x => ({ ...x, [r.sale_product_id]: {} }));
      onLogged?.();
    } catch (e) { setErr(errText(e)); } finally { setBusy(false); }
  };
  const removeCancel = async (id) => {
    if (!window.confirm("Remove this cancelation?")) return;
    const { data, error } = await supabase.rpc("rp_void_cancelation", { p_id: id, p_reason: null });
    if (error || !data?.ok) { window.alert(errText(error || data)); return; }
    onLogged?.();
  };

  return (
    <div style={{ display: "grid", gap: 16 }}>
      <div style={cardStyle}>
        <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900, marginBottom: 4 }}>Who canceled?</div>
        <div style={{ fontSize: 13, color: T.slate500, marginBottom: 12 }}>Start typing the first name. Pick the customer, then the policy.</div>
        <div style={{ ...wrapRow, alignItems: "flex-end" }}>
          <div style={{ ...field(220), position: "relative" }}>
            <input style={inputBase} value={q} onChange={e => { setQ(e.target.value); setPicked(null); }} placeholder="Anna" autoComplete="off" />
            {suggest.length > 0 && !picked && (
              <div style={{ position: "absolute", top: "100%", left: 0, right: 0, zIndex: 5, background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 8, boxShadow: "0 6px 16px rgba(0,0,0,0.08)", marginTop: 4, overflow: "hidden" }}>
                {suggest.map(c => (
                  <button key={c.customer_label} type="button" onClick={() => { setPicked(c); setQ(c.customer_label); setSuggest([]); setOk(""); setErr(""); }}
                    style={{ display: "block", width: "100%", textAlign: "left", padding: "8px 12px", border: "none", background: "transparent", fontSize: 14, color: T.slate800, cursor: "pointer", fontFamily: "inherit" }}>
                    {c.customer_label}
                  </button>
                ))}
              </div>
            )}
          </div>
          <button type="button" style={{ ...btnGhost, padding: "10px 14px" }} onClick={() => setPopup(true)}>Not on file? Log the customer</button>
        </div>
        {picked && (
          <div style={{ marginTop: 14 }}>
            <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900, marginBottom: 6 }}>{picked.customer_label} · on file</div>
            {onFile.length === 0 && <div style={{ fontSize: 13, color: T.slate500 }}>No sold policies on file. Use "Log the customer" to record the cancelation with the policy details.</div>}
            {onFile.map(r => {
              const d = draft(r);
              const label = typeLabel(types || {}, r.line_of_business, r.product_type) || PRODUCT_SHORT[r.line_of_business] || r.line_of_business;
              return (
                <div key={r.sale_product_id} style={{ borderTop: `1px solid ${T.slate100}`, padding: "8px 0" }}>
                  <div style={{ display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center" }}>
                    <span style={{ fontWeight: 600, color: T.slate800 }}>{label}</span>
                    <span style={{ fontSize: 12, color: T.slate500 }}>${fmtPts(r.premium)}{r.vehicle_count ? ` · ${plural(r.vehicle_count, "car")}` : ""} · sold {fmtDate(r.submitted_date)}</span>
                    {r.already_canceled ? <span style={{ fontSize: 12, color: T.red, fontWeight: 600 }}>canceled</span>
                      : <button type="button" style={btnGhost} onClick={() => edit(r, { open: !d.open })}>{d.open ? "Never mind" : "Canceled"}</button>}
                  </div>
                  {d.open && !r.already_canceled && (
                    <div style={{ ...wrapRow, marginTop: 8, padding: 10, background: T.slate50, borderRadius: 8 }}>
                      <div style={field(140)}><label style={labelStyle}>Canceled on</label><input type="date" style={inputBase} value={d.date || today} max={today} min={addDays(today, -90)} onChange={e => edit(r, { date: e.target.value })} /></div>
                      <div style={field(120)}><label style={labelStyle}>Premium</label><input type="number" inputMode="decimal" min="0" step="0.01" style={inputBase} value={d.premium === undefined ? String(r.premium ?? "") : d.premium} onChange={e => edit(r, { premium: e.target.value })} /></div>
                      {r.line_of_business === "auto" && <div style={field(70)}><label style={labelStyle}>Cars</label><input type="number" inputMode="numeric" min="1" step="1" style={inputBase} value={d.vehicles === undefined ? String(r.vehicle_count || 1) : d.vehicles} onChange={e => edit(r, { vehicles: e.target.value })} /></div>}
                      <div style={field(200)}><label style={labelStyle}>Why <span style={hintStyle}>(optional)</span></label><input style={inputBase} value={d.reason || ""} onChange={e => edit(r, { reason: e.target.value })} placeholder="what they told us" /></div>
                      <button type="button" style={btnPrimary(busy)} disabled={busy} onClick={() => cancelPolicy(r)}>{busy ? "Saving…" : "Log the cancelation"}</button>
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        )}
        <Notice kind="error">{err}</Notice>
        <Notice kind="ok">{ok}</Notice>
      </div>

      <div style={cardStyle}>
        <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900, marginBottom: 10 }}>Canceled in the last 30 days <span style={{ color: T.slate400, fontWeight: 400 }}>· {recent.length}</span></div>
        <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
          <table style={{ width: "100%", borderCollapse: "collapse" }}>
            <thead><tr><th style={tableTh}>Date</th><th style={tableTh}>Who</th><th style={tableTh}>Customer</th><th style={tableTh}>Line</th><th style={tableTh}>Premium</th><th style={tableTh}>Why</th><th style={tableTh}></th></tr></thead>
            <tbody>
              {recent.map(r => (
                <tr key={r.id}>
                  <td style={tableTd}>{fmtDate(r.canceled_on)}</td>
                  <td style={tableTd}>{nameOf(r.team_member_id)}</td>
                  <td style={tableTd}>{r.customer_label}</td>
                  <td style={tableTd}>{PRODUCT_SHORT[r.policy_line] || r.policy_line}</td>
                  <td style={tableTd}>${fmtPts(r.premium)}</td>
                  <td style={{ ...tableTd, maxWidth: 320 }}>{r.reason || "—"}</td>
                  <td style={tableTd}>{(isAdmin || r.team_member_id === myTeamId) && <button style={btnGhost} onClick={() => removeCancel(r.id)}>Remove</button>}</td>
                </tr>
              ))}
              {recent.length === 0 && <tr><td style={tableTd} colSpan={7}>Nothing canceled in the last 30 days.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>

      {popup && (
        <Modal title="Log the customer" onClose={() => setPopup(false)}>
          <EntryPage values={values} sources={sources} types={types} isOwner={isOwner} roster={roster} refreshKey={refreshKey} allowCancel presetFirst={picked ? "" : q.trim()}
            onLogged={() => { onLogged?.(); }} />
        </Modal>
      )}
    </div>
  );
}

// =====================================================================
// Changes — who changed what and when on this module (Peter 2026-09-10).
// Admin only. Reads change_log_recent(); its rows come from the trigger on
// the seven Production tables, so page clicks, undo, voids, issued marks,
// and maintenance SQL all land here. Rows written by one Log click share a
// txid and are shown as one group.
// =====================================================================
const CHANGE_LABEL = {
  premium: "premium", total_premium: "total premium", issued_date: "issued", status: "status", void_reason: "void reason",
  note: "note", customer_label: "customer", customer_first_name: "first name", customer_last_initial: "last initial",
  marketing_source: "source", marketing_source_import: "source as imported", household_status: "relationship",
  relationship_type: "relationship", submitted_date: "submitted", quote_date: "quote date", occurred_on: "date",
  canceled_on: "canceled on", vehicle_count: "cars", policy_count: "policies", line_of_business: "line", policy_line: "line",
  save_line: "line", product_type: "product", is_new_line: "new line", points: "points", activity_key: "activity",
  save_reason: "save reason", reason: "reason", week_end_date: "week", credited_week_end_date: "credited week",
  credit_available_on: "clears on", products_discussed: "products discussed", is_existing_customer: "existing customer",
  gnc_used: "GNC used", ecrm_opportunity_url: "ECRM link", ecrm_url: "ECRM link", team_member_id: "person",
  sourced_by_team_member_id: "sourced by", saves_voided: "saves voided", chargeback_points: "chargeback",
  window_fraction_left: "window left", verified_at: "verified", scorecard_date: "date", average_score: "average",
  recording_turned_in: "recording turned in", recording_url: "recording", opportunity_ref: "opportunity",
};
// Bookkeeping columns that say nothing a person needs to read.
const CHANGE_HIDE = /^(id|agency_id|created_by|created_by_user_id|created_at|updated_at|voided_by|voided_at|verified_by|source|source_id|sales_log_id|quote_log_id|multiline_credit_id|matched_sale_product_id|chargeback_activity_id|entry_source|tenure_tier_at_entry|entry_type)$/;
const CHANGE_WINDOWS = [
  { days: 7,  label: "Last 7 days" },
  { days: 30, label: "Last 30 days" },
  { days: 90, label: "Last 90 days" },
];

function changeLabel(key) {
  return CHANGE_LABEL[key] || key.replace(/_score$/, "").replace(/_/g, " ");
}
function changeWhen(ts) {
  const d = new Date(ts);
  return isNaN(d) ? "—" : d.toLocaleString("en-US", { timeZone: "America/Chicago", month: "numeric", day: "numeric", hour: "numeric", minute: "2-digit" });
}
function ChangeVal({ k, v, ctx }) {
  if (v === null || v === undefined || v === "") return "—";
  if (typeof v === "boolean") return v ? "yes" : "no";
  if (/team_member_id$/.test(k)) return ctx.nameOf(v);
  if (/(premium|points)$/.test(k)) return `$${fmtPts(v)}`;
  if (k === "window_fraction_left") return `${Math.round(Number(v) * 100)}%`;
  if (k === "activity_key") return ctx.labelOf[v] || v;
  if (Array.isArray(v)) return v.map(x => PRODUCT_SHORT[x] || x).join(", ") || "—";
  if (/^(line_of_business|policy_line|save_line)$/.test(k)) return PRODUCT_SHORT[v] || v;
  if (k === "household_status" || k === "relationship_type") return (RELATIONSHIPS.find(r => r.key === v) || {}).label || v;
  if (typeof v === "string" && /^\d{4}-\d{2}-\d{2}/.test(v)) return fmtDate(v.slice(0, 10));
  return String(v);
}
// One line that says what the row is, for adds and removals.
function changeSummary(r, ctx) {
  const row = r.new_row || r.old_row || {};
  const money = (k) => row[k] == null ? "" : ` · $${fmtPts(row[k])}`;
  const cars = row.vehicle_count ? ` · ${row.vehicle_count} car${row.vehicle_count > 1 ? "s" : ""}` : "";
  const line = (k) => PRODUCT_SHORT[row[k]] || row[k] || "";
  const product = (k) => row.product_type ? ` ${typeLabel(ctx.types, row[k], row.product_type) || row.product_type}` : "";
  switch (r.table_name) {
    case "sales_log":              return `Sale${money("total_premium")}${cars}${row.marketing_source ? ` · ${row.marketing_source}` : ""}`;
    case "sales_log_products":     return `${line("line_of_business")}${product("line_of_business")}${money("premium")}${cars}${row.issued_date ? ` · issued ${fmtDate(row.issued_date)}` : " · not issued"}`;
    case "quote_log":              return `Quote${Array.isArray(row.products_discussed) && row.products_discussed.length ? ` · ${row.products_discussed.map(x => PRODUCT_SHORT[x] || x).join(", ")}` : ""}`;
    case "quote_log_products":     return `Quoted ${line("line_of_business")}${product("line_of_business")}`;
    case "cancelation_log":        return `Canceled ${line("policy_line")}${money("premium")}${row.canceled_on ? ` on ${fmtDate(row.canceled_on)}` : ""}${row.reason ? ` · ${row.reason}` : ""}`;
    case "retention_activity_log": return `${ctx.labelOf[row.activity_key] || row.activity_key || "Activity"}${row.points != null ? ` · $${fmtPts(row.points)}` : ""}${row.credit_available_on ? ` · clears ${fmtDate(row.credit_available_on)}` : ""}`;
    case "fit_scorecards":         return `FIT scorecard${row.average_score != null ? ` · ${Number(row.average_score).toFixed(2)}` : ""}`;
    default:                       return r.item;
  }
}

function ChangesTab({ roster, values, types }) {
  const [days, setDays] = useState(30);
  const [who, setWho] = useState("");
  const [rows, setRows] = useState(null);
  const [err, setErr] = useState("");
  const nameOf = useCallback((id) => (roster.find(t => t.id === id) || {}).first_name || (id ? "former teammate" : "—"), [roster]);
  const labelOf = useMemo(() => Object.fromEntries((values || []).map(v => [v.activity_key, v.label])), [values]);
  const ctx = useMemo(() => ({ nameOf, labelOf, types: types || {} }), [nameOf, labelOf, types]);

  useEffect(() => {
    let alive = true;
    (async () => {
      setErr("");
      const r = await supabase.rpc("change_log_recent", { p_days: days, p_team_member_id: who || null, p_limit: 300 });
      if (!alive) return;
      if (r.error) { setErr(errText(r.error)); setRows([]); return; }
      setRows(Array.isArray(r.data) ? r.data : []);
    })();
    return () => { alive = false; };
  }, [days, who]);

  const selectStyle = { ...inputBase, width: "auto", fontSize: 13, padding: "7px 10px" };
  const verb = { insert: "Added", update: "Changed", delete: "Removed" };

  return (
    <div style={{ display: "grid", gap: 12 }}>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center", justifyContent: "space-between" }}>
        <div style={{ fontSize: 13, color: T.slate500 }}>Who changed what, and when. Everything on this module, newest first.</div>
        <div style={{ display: "flex", gap: 8 }}>
          <select value={who} onChange={e => setWho(e.target.value)} style={selectStyle}>
            <option value="">Everyone</option>
            {roster.map(t => <option key={t.id} value={t.id}>{t.first_name}</option>)}
          </select>
          <select value={days} onChange={e => setDays(Number(e.target.value))} style={selectStyle}>
            {CHANGE_WINDOWS.map(w => <option key={w.days} value={w.days}>{w.label}</option>)}
          </select>
        </div>
      </div>
      {err && <Notice kind="error">{err}</Notice>}
      {rows === null ? (
        <div style={{ ...cardStyle, color: T.slate500, fontSize: 13 }}>Loading…</div>
      ) : rows.length === 0 ? (
        <div style={{ ...cardStyle, color: T.slate600, fontSize: 14 }}>No changes in the last {days} days.</div>
      ) : (
        <div style={{ ...cardStyle, overflowX: "auto" }}>
          <table style={{ width: "100%", borderCollapse: "collapse" }}>
            <thead>
              <tr>
                <th style={tableTh}>When</th>
                <th style={tableTh}>Who</th>
                <th style={tableTh}>What</th>
                <th style={tableTh}>Customer</th>
                <th style={tableTh}>Details</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r, i) => {
                const sameClick = i > 0 && rows[i - 1].txid === r.txid;
                const fields = (r.changed_fields || []).filter(k => !CHANGE_HIDE.test(k));
                return (
                  <tr key={r.id} style={sameClick ? { background: T.slate50 } : undefined}>
                    <td style={{ ...tableTd, whiteSpace: "nowrap", color: sameClick ? T.slate300 : T.slate800 }}>{sameClick ? "〃" : changeWhen(r.changed_at)}</td>
                    <td style={{ ...tableTd, whiteSpace: "nowrap", color: sameClick ? T.slate300 : T.slate800 }}>{sameClick ? "〃" : r.who}</td>
                    <td style={{ ...tableTd, whiteSpace: "nowrap" }}>
                      <span style={{ fontWeight: 700, color: r.action === "delete" ? T.red : r.action === "update" ? T.amber : T.green }}>{verb[r.action] || r.action}</span> {r.item === "FIT scorecard" ? r.item : r.item.toLowerCase()}
                    </td>
                    <td style={tableTd}>{r.subject || "—"}</td>
                    <td style={{ ...tableTd, maxWidth: 420 }}>
                      {r.action === "update" ? (
                        fields.length ? fields.map(k => (
                          <div key={k}>
                            <span style={{ color: T.slate500 }}>{changeLabel(k)}:</span>{" "}
                            <ChangeVal k={k} v={(r.old_row || {})[k]} ctx={ctx} /> → <ChangeVal k={k} v={(r.new_row || {})[k]} ctx={ctx} />
                          </div>
                        )) : <span style={{ color: T.slate500 }}>{(r.changed_fields || []).map(changeLabel).join(", ") || "—"}</span>
                      ) : changeSummary(r, ctx)}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

// =====================================================================
// My week — the scoreboard (Peter 2026-09-11). Everyone sees the whole
// team, and every list is ranked. rp_week_scoreboard brings each
// teammate's Marketing Points, HH Quotes, Sales Points, Retention Points
// and conversation scorecards for the week, with the items behind every
// number. Marketing Points come from marketing_point_values (base plus a
// step for each prior event this year); Sales Points from
// compute_sp_from_production on issued policies quarter to date (this
// week = the quarter's total after this week minus after last week);
// Retention Points from compute_weekly_retention_points.
// =====================================================================
const cardGrid = { display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(230px, 1fr))", gap: 12, alignItems: "start" };
const rowBtn = { display: "flex", alignItems: "center", gap: 6, width: "100%", padding: "8px 0", border: "none", background: "transparent", fontFamily: "inherit", fontSize: 13, textAlign: "left" };
const itemLine = { fontSize: 12, color: T.slate600, display: "flex", flexWrap: "wrap", gap: "2px 8px", alignItems: "center" };
const miniBtn = { ...btnGhost, padding: "2px 7px", fontSize: 11 };
const fmtMoney = (n) => `$${fmtPts(n)}`;
const ratePct = (r) => r == null ? "—" : `${(Number(r) * 100).toFixed(2)}%`;
const nth = (n) => { const s = ["th", "st", "nd", "rd"], v = n % 100; return n + (s[(v - 20) % 10] || s[v] || s[0]); };
const plural = (n, w) => `${n} ${w}${Number(n) === 1 ? "" : "s"}`;

function Stat({ label, value }) {
  return (
    <div style={{ background: T.slate50, borderRadius: 8, padding: "8px 10px" }}>
      <div style={{ fontSize: 11, color: T.slate500 }}>{label}</div>
      <div style={{ fontSize: 18, fontWeight: 800, color: T.slate900 }}>{value}</div>
    </div>
  );
}

// One card: title, team total, then everyone ranked. Tap a name to see what
// contributed. Cards without items (Conversations) are not expandable.
function ScoreCard({ title, total, note, people, rankOf, valueOf, subOf, renderItems, open, onToggle }) {
  const ranked = people.slice().sort((a, b) => (rankOf(b) - rankOf(a)) || String(a.first_name).localeCompare(String(b.first_name)));
  return (
    <div style={{ ...cardStyle, padding: "14px 16px" }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", gap: 8, marginBottom: note ? 2 : 6 }}>
        <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>{title}</div>
        <div style={{ fontSize: 15, fontWeight: 800, color: T.slate900, whiteSpace: "nowrap" }}>{total}</div>
      </div>
      {note && <div style={{ fontSize: 11, color: T.slate500, marginBottom: 6 }}>{note}</div>}
      {ranked.map((p, i) => {
        const isOpen = !!renderItems && open === p.team_member_id;
        return (
          <div key={p.team_member_id} style={{ borderTop: `1px solid ${T.slate100}` }}>
            <button type="button" onClick={() => renderItems && onToggle(p.team_member_id)} style={{ ...rowBtn, cursor: renderItems ? "pointer" : "default" }}>
              <span style={{ color: T.slate400, width: 16, flexShrink: 0 }}>{i + 1}</span>
              <span style={{ flex: 1, minWidth: 0, fontWeight: 600, color: T.slate800 }}>
                {p.first_name}
                {subOf && <span style={{ display: "block", fontSize: 11, fontWeight: 400, color: T.slate500 }}>{subOf(p)}</span>}
              </span>
              <span style={{ fontWeight: 700, color: T.slate900, whiteSpace: "nowrap" }}>{valueOf(p)}</span>
              {renderItems && <span style={{ color: T.slate400, width: 12, textAlign: "right" }}>{isOpen ? "▾" : "▸"}</span>}
            </button>
            {isOpen && <div style={{ padding: "0 0 10px 22px", display: "grid", gap: 5 }}>{renderItems(p)}</div>}
          </div>
        );
      })}
      {people.length === 0 && <div style={{ fontSize: 12, color: T.slate500 }}>Nobody on the roster this week.</div>}
    </div>
  );
}

function WeekView({ isAdmin, myTeamId, roster, values, types, refreshKey }) {
  const [weekEnd, setWeekEnd, weekHref] = useTabParam("week", weekEndOf(todayCentral()));
  const [board, setBoard] = useState(null);
  const [sales, setSales] = useState([]);
  const [open, setOpen] = useState({});      // card -> team_member_id whose items are showing
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState("");

  const nameOf = useMemo(() => {
    const m = new Map();
    for (const t of roster || []) m.set(t.id, t.first_name);
    return (id) => m.get(id) || "—";
  }, [roster]);
  const unit = (k) => Number(((values || []).find(v => v.activity_key === k) || {}).points || 0);
  const safeWeek = /^\d{4}-\d{2}-\d{2}$/.test(weekEnd || "") ? weekEnd : weekEndOf(todayCentral());
  const weekStart = addDays(safeWeek, -6);

  const load = useCallback(async () => {
    setLoading(true); setErr("");
    try {
      const [b, s] = await Promise.all([
        supabase.rpc("rp_week_scoreboard", { p_week_end: safeWeek }),
        supabase.from("sales_log").select("id, team_member_id, sourced_by_team_member_id, submitted_date, customer_label, household_status, marketing_source, gnc_used, vehicle_count, total_premium, status, created_at, on_file_answer, sales_log_products(line_of_business, product_type, premium, policy_count, is_new_line, issued_date)")
          .eq("agency_id", AGENCY_ID).eq("status", "active").eq("week_end_date", safeWeek).order("submitted_date", { ascending: false }),
      ]);
      if (b.error) throw b.error;
      if (b.data && b.data.ok === false) throw new Error(b.data.error || "Could not load the week.");
      setBoard(b.data || null);
      setSales(Array.isArray(s.data) ? s.data : []);
    } catch (e) { setErr(errText(e)); } finally { setLoading(false); }
  }, [safeWeek]);

  useEffect(() => { load(); }, [load, refreshKey]);

  const people = Array.isArray(board?.people) ? board.people : [];
  const team = board?.team || {};
  const canRemove = (tm) => isAdmin || tm === myTeamId;
  const toggle = (card) => (id) => setOpen(o => ({ ...o, [card]: o[card] === id ? null : id }));
  const cardN = people.reduce((s, p) => s + Number(p.conversations?.scorecards || 0), 0);
  const teamAvg = cardN ? people.reduce((s, p) => s + Number(p.conversations?.avg || 0) * Number(p.conversations?.scorecards || 0), 0) / cardN : null;

  const voidRow = async (fn, id, what) => {
    if (!window.confirm(`Remove this ${what}?`)) return;
    const { data, error } = await supabase.rpc(fn, { p_id: id, p_reason: null });
    if (error || !data?.ok) { window.alert(errText(error || data)); return; }
    load();
  };

  const marketingItems = (p) => {
    const items = p.marketing?.items || [];
    if (!items.length) return <div style={itemLine}>Nothing this week.</div>;
    return items.map(it => (
      <div key={it.id} style={itemLine}>
        <span>{fmtDate(it.on_date)}</span><span>{it.customer || "—"}</span>
        <span>{it.label}{Number(it.nth) > 1 ? <span style={{ color: T.slate400 }}> · {nth(Number(it.nth))} this year</span> : null}</span>
        <strong style={{ color: T.slate900 }}>{fmtPts(it.points)}</strong>
      </div>
    ));
  };
  const quoteItems = (p) => {
    const items = p.quotes?.items || [];
    if (!items.length) return <div style={itemLine}>No quotes this week.</div>;
    return items.map(it => (
      <div key={it.id} style={itemLine}>
        <span>{fmtDate(it.on_date)}</span><span>{it.customer || "—"}</span>
        <span>{it.types || (it.products || []).map(k => PRODUCT_SHORT[k] || k).join(", ") || "—"}</span>
        {it.source && <span style={{ color: T.slate400 }}>{it.source}</span>}
        {it.dup && <span style={{ color: T.amber, fontWeight: 700 }} title="This household was already quoted this week. It counts once.">repeat this week</span>}
        {canRemove(p.team_member_id) && <button type="button" style={miniBtn} onClick={() => voidRow("rp_void_quote", it.id, "quote")}>Remove</button>}
      </div>
    ));
  };
  const salesItems = (p) => {
    const s = p.sales || {};
    const rows = (s.items || []).map(it => (
      <div key={it.id} style={itemLine}>
        <span>{fmtDate(it.issued_on)}</span><span>{it.customer || "—"}</span>
        <span>{it.type}{it.vehicles ? ` · ${plural(it.vehicles, "car")}` : ""}</span>
        {it.on_file_answer && <span style={{ color: T.amber, fontWeight: 700 }}>{it.on_file_answer === "replaces" ? "replaced the old one" : it.on_file_answer === "added" ? "added to what's on file" : "different household"}</span>}
        <strong style={{ color: T.slate900 }}>{fmtMoney(it.premium)}</strong>
      </div>
    ));
    if (!rows.length) rows.push(<div key="none" style={itemLine}>Nothing issued this week.</div>);
    rows.push(<div key="qtd" style={{ ...itemLine, color: T.slate400 }}>Quarter to date {fmtPts(s.qtd_points)} · P&C rate {ratePct(s.pc_rate)} · L&H rate {ratePct(s.lh_rate)}</div>);
    return rows;
  };
  const retentionItems = (p) => {
    const r = p.retention || {};
    const rows = [
      <div key="hours" style={itemLine}><span>Hours in office</span><span>{fmtPts(r.hours_in_office)} × {fmtMoney(unit("hour_in_office"))}</span><strong style={{ color: T.slate900 }}>{fmtMoney(r.hour_points)}</strong></div>,
      <div key="calls" style={itemLine}><span>Calls answered</span><span>{r.calls_answered} × {fmtMoney(unit("call_answered"))}</span><strong style={{ color: T.slate900 }}>{fmtMoney(r.call_points)}</strong></div>,
    ];
    for (const it of r.items || []) {
      rows.push(
        <div key={it.id} style={itemLine}>
          <span>{fmtDate(it.on_date)}</span><span>{it.customer || "—"}</span>
          <span>{it.label}{it.clears_on ? <span style={{ color: T.amber }}> · clears {fmtDate(it.clears_on)}</span> : null}</span>
          {it.note && <span style={{ color: T.slate400 }}>{it.note}</span>}
          <strong style={{ color: T.slate900 }}>{fmtMoney(it.points)}</strong>
          {it.source === "manual" && canRemove(p.team_member_id) && <button type="button" style={miniBtn} onClick={() => voidRow("rp_void_activity", it.id, "entry")}>Remove</button>}
        </div>
      );
    }
    if (Number(r.reduction_pct) > 0) rows.push(<div key="red" style={{ ...itemLine, color: T.red }}><span>Missed {fmtPts(r.missed_pct)}% calls</span><strong>−{fmtPts(r.reduction_pct)}% of gross</strong></div>);
    return rows;
  };

  return (
    <div style={{ display: "grid", gap: 16 }}>
      <SpotCheck isAdmin={isAdmin} />
      <div style={cardStyle}>
        <div style={{ display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center", justifyContent: "space-between" }}>
          <div>
            <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>Week of {fmtDate(weekStart)} – {fmtDate(safeWeek)} {loading ? <span style={{ color: T.slate400, fontWeight: 400, fontSize: 13 }}>· loading…</span> : null}</div>
            <div style={{ fontSize: 12, color: T.slate500 }}>Sunday through Saturday. Whole team, ranked. Tap a name to see what counted.</div>
          </div>
          <div style={{ display: "flex", gap: 8 }}>
            <TabLink href={weekHref(addDays(safeWeek, -7))} onSelect={() => setWeekEnd(addDays(safeWeek, -7))} style={btnGhost}>← Prior week</TabLink>
            <TabLink href={weekHref(weekEndOf(todayCentral()))} onSelect={() => setWeekEnd(weekEndOf(todayCentral()))} style={btnGhost}>This week</TabLink>
            <TabLink href={weekHref(addDays(safeWeek, 7))} onSelect={() => setWeekEnd(addDays(safeWeek, 7))} style={btnGhost} disabled={safeWeek >= weekEndOf(todayCentral())}>Next week →</TabLink>
          </div>
        </div>
      </div>

      {err && <Notice kind="error">{err}</Notice>}

      <div style={cardGrid}>
        <ScoreCard title="Marketing Points" total={fmtPts(team.marketing)} people={people}
          rankOf={p => Number(p.marketing?.points || 0)} valueOf={p => fmtPts(p.marketing?.points)}
          renderItems={marketingItems} open={open.m} onToggle={toggle("m")} />
        <ScoreCard title="HH Quotes" total={Number(team.quotes || 0)} people={people}
          rankOf={p => Number(p.quotes?.count || 0)} valueOf={p => Number(p.quotes?.count || 0)}
          renderItems={quoteItems} open={open.q} onToggle={toggle("q")} />
        <ScoreCard title="Sales Points" total={fmtPts(team.sales)} note="Counted the week a policy issues." people={people}
          rankOf={p => Number(p.sales?.points || 0)} valueOf={p => fmtPts(p.sales?.points)}
          subOf={p => `${fmtPts(p.sales?.qtd_points)} this quarter`}
          renderItems={salesItems} open={open.s} onToggle={toggle("s")} />
        <ScoreCard title="Retention Points" total={fmtMoney(team.retention_net)} note="Net, after the team missed-call reduction." people={people}
          rankOf={p => Number(p.retention?.net || 0)} valueOf={p => fmtMoney(p.retention?.net)}
          subOf={p => `${fmtMoney(p.retention?.gross)} gross · missed ${fmtPts(p.retention?.missed_pct)}% calls`}
          renderItems={retentionItems} open={open.r} onToggle={toggle("r")} />
        <ScoreCard title="Conversations" total={teamAvg == null ? "—" : teamAvg.toFixed(2)} note="Scorecard average, 1 to 3. Pivots are tracked, not paid." people={people}
          rankOf={p => Number(p.conversations?.avg || 0)} valueOf={p => p.conversations?.avg == null ? "—" : Number(p.conversations.avg).toFixed(2)}
          subOf={p => `${plural(p.conversations?.scorecards || 0, "scorecard")} · ${plural(p.conversations?.pivots || 0, "pivot")}`} />
      </div>

      <div style={cardStyle}>
        <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900, marginBottom: 10 }}>Sales this week</div>
        <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
          <table style={{ width: "100%", borderCollapse: "collapse" }}>
            <thead><tr><th style={tableTh}>Date</th><th style={tableTh}>Who</th><th style={tableTh}>Customer</th><th style={tableTh}>Relationship</th><th style={tableTh}>Products</th><th style={tableTh}>Cars</th><th style={tableTh}>Premium</th><th style={tableTh}>Source</th><th style={tableTh}>GNC</th><th style={tableTh}></th></tr></thead>
            <tbody>
              {sales.map(r => (
                <tr key={r.id}>
                  <td style={tableTd}>{fmtDate(r.submitted_date)}</td>
                  <td style={tableTd}>{nameOf(r.team_member_id)}{r.sourced_by_team_member_id && r.sourced_by_team_member_id !== r.team_member_id ? <div style={{ fontSize: 11, color: T.slate400 }}>sourced by {nameOf(r.sourced_by_team_member_id)}</div> : null}</td>
                  <td style={tableTd}>{r.customer_label}</td>
                  <td style={tableTd}>{r.household_status === "new" ? "New" : r.household_status === "winback" ? "Winback" : "Existing"}{r.on_file_answer && <div style={{ fontSize: 11, color: T.amber }}>{r.on_file_answer === "replaces" ? "replaced old policy" : r.on_file_answer === "added" ? "added to on-file" : "different household"}</div>}</td>
                  <td style={tableTd}>{(r.sales_log_products || []).map((p, i) => <div key={i}>{typeLabel(types || {}, p.line_of_business, p.product_type) || PRODUCT_SHORT[p.line_of_business] || p.line_of_business} ${fmtPts(p.premium)}{p.issued_date ? "" : <span style={{ color: T.amber }}> · not issued</span>}</div>)}</td>
                  <td style={tableTd}>{r.vehicle_count ?? "—"}</td>
                  <td style={tableTd}>${fmtPts(r.total_premium)}</td>
                  <td style={tableTd}>{r.marketing_source}</td>
                  <td style={tableTd}>{r.gnc_used ? "Yes" : "No"}</td>
                  <td style={tableTd}>{canRemove(r.team_member_id) && <button style={btnGhost} onClick={() => voidRow("rp_void_sale", r.id, "sale")}>Remove</button>}</td>
                </tr>
              ))}
              {!loading && sales.length === 0 && <tr><td style={tableTd} colSpan={10}>No sales logged this week.</td></tr>}
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
  const [tab, setTab, tabHref] = useTabParam("tab", "log", [...TABS, "earnings"]);
  const [values, setValues] = useState([]);
  const [sources, setSources] = useState([]);
  const [types, setTypes] = useState({});
  const [roster, setRoster] = useState([]);
  const [myTeamId, setMyTeamId] = useState(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const [head, setHead] = useState(null);   // this week's scoreboard, shown beside the title on every tab (your own row; team when you have none)
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

  useEffect(() => {
    let alive = true;
    supabase.rpc("rp_week_scoreboard", { p_week_end: weekEndOf(todayCentral()) })
      .then(r => { if (alive && r?.data?.ok) setHead(r.data); });
    return () => { alive = false; };
  }, [refreshKey, myTeamId]);

  const bump = () => setRefreshKey(k => k + 1);
  const tabs = [
    { id: "log", label: "Log" },
    { id: "issued", label: "To be issued" },
    { id: "canceled", label: "Canceled" },
    { id: "week", label: "My week" },
    { id: "earnings", label: "Earning Potential" },  // everyone (Peter 2026-09-04); Retention + Life Specialist curves inside are admin only
    ...(isAdmin ? [{ id: "changes", label: "Changes" }] : []),  // who changed what and when (Peter 2026-09-10)
  ];

  return (
    <div style={{ padding: _pad, display: "grid", gap: 16 }}>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 12, alignItems: "center", justifyContent: "space-between" }}>
        <div>
          <div style={{ fontSize: 20, fontWeight: 800, color: T.slate900 }}>Production</div>
          <div style={{ fontSize: 13, color: T.slate500 }}>What you wrote, quoted, kept, and lost. Logged as it happens.</div>
        </div>
        {head && (() => {
          const me = (Array.isArray(head.people) ? head.people : []).find(p => p.team_member_id === myTeamId);
          const t = head.team || {};
          const cardN = (head.people || []).reduce((s, p) => s + Number(p.conversations?.scorecards || 0), 0);
          const teamAvg = cardN ? (head.people || []).reduce((s, p) => s + Number(p.conversations?.avg || 0) * Number(p.conversations?.scorecards || 0), 0) / cardN : null;
          const conv = me ? me.conversations?.avg : teamAvg;
          const chips = me
            ? [["Marketing", fmtPts(me.marketing?.points)], ["HH Quotes", Number(me.quotes?.count || 0)], ["Sales Pts", fmtPts(me.sales?.points)], ["Retention", `$${fmtPts(me.retention?.net)}`]]
            : [["Marketing", fmtPts(t.marketing)], ["HH Quotes", Number(t.quotes || 0)], ["Sales Pts", fmtPts(t.sales)], ["Retention", `$${fmtPts(t.retention_net)}`]];
          chips.push(["Conversations", conv == null ? "—" : Number(conv).toFixed(2)]);
          return (
          <div style={{ display: "flex", flexWrap: "wrap", gap: 6, alignItems: "center" }} title={me ? "Your week so far" : "Team, this week so far"}>
            {chips.map(([l, v]) => (
              <span key={l} style={{ display: "inline-flex", gap: 5, alignItems: "baseline", padding: "5px 10px", borderRadius: 999, background: T.blueLt, color: T.blue, fontSize: 12, fontWeight: 600 }}>
                <span style={{ fontWeight: 500, opacity: 0.8 }}>{l}</span><strong style={{ fontSize: 13 }}>{v}</strong>
              </span>
            ))}
          </div>
          );
        })()}
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
      {tab === "issued" && <IssuedTab types={types} refreshKey={refreshKey} />}
      {tab === "canceled" && <CanceledTab values={values} sources={sources} types={types} isOwner={isOwner} isAdmin={isAdmin} myTeamId={myTeamId} roster={roster} onLogged={bump} refreshKey={refreshKey} />}
      {tab === "week" && <WeekView isAdmin={isAdmin} myTeamId={myTeamId} roster={roster} values={values} types={types} refreshKey={refreshKey} />}
      {tab === "earnings" && <EarningPotentialTab isAdmin={isAdmin} />}
      {tab === "changes" && isAdmin && <ChangesTab roster={roster} values={values} types={types} />}
    </div>
  );
}
