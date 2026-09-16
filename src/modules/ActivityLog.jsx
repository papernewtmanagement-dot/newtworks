import { useState, useEffect, useMemo, useCallback, useRef } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useViewport } from "../lib/hooks.js";
import { useTabParam, TabLink } from "../lib/routing.jsx";
import TimeHub from "./TimeHub.jsx";
import PFA from "./PFA.jsx";
import Development from "./Development.jsx";
import { T } from "../lib/theme.js";
import { mdToHtml } from "../lib/markdown.js";
import { ManualBodyStyles } from "../lib/manualBodyStyles.jsx";
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
//    Scorecards page writes it; Scoreboard shows the week's average.
//  * Bottom row, only what applies: ECRM link (sale), Marketing type
//    (sale or quote), Lead source (referral), then the note.
//  * A canceled policy is matched server-side to the sale that wrote it
//    (same customer + line, 6-month window on auto, 12 on the rest) and
//    the Multiline credit comes back prorated; the green bar says so.
//  * Earning Potential (owner only) lives here as its own tab, moved from
//    Team; it is the shared EarningPotentialTab component untouched.
//  * Scoreboard is the week's standings: whole team, ranked, four point cards plus
//    the conversation card in one row; your own week (with the conversation
//    score) sits beside the title on every tab.
//  * Canceled has its own tab: search the customer, tap the policy, log it.
//    Not on file → this entry page opens in a popup with Canceled allowed.
//  * The household key is first name + last initial + phone last four
//    (required on every record; older rows without a phone match any phone).
//  * A sold line the household already has on file asks: replaces it, added,
//    or a different household. "Replaces it" cancels the old policy in the
//    same click (second rp_log_entry, replacement: true) as a normal
//    cancelation — chargeback and multiline rules unchanged; the answer is
//    stored on the sale and shown on the Scoreboard. A repeat quote for
//    the same household in a week is flagged here and marked on the Scoreboard;
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
const TABS = ["log", "checklist", "hours", "deposits", "week", "issued", "development", "changes", "history"];
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
// Money reads right-aligned so the digits line up column to column.
const moneyInput = { ...inputBase, textAlign: "right" };
// Password managers (LastPass, 1Password, Bitwarden, Dashlane, Proton Pass)
// read these customer boxes as login or address fields and put their icon in
// them. Spread this onto every one: the data attributes are each vendor's own
// opt-out. Two things the attributes alone do not cover, both handled here:
// LastPass ignores autoComplete "off", so each box gets a nonsense token
// instead; and when a box has no name or id LastPass falls back to guessing
// from the nearby label, so each box gets a meaningless name and id. Pass a
// short opaque key that says nothing about the field.
// Suppressing one box only moves the offer to the next one, so they all carry it.
const noPwManager = (key) => ({
  name: `nw${key}`, id: `nw${key}`, autoComplete: `nw${key}-x`,
  "data-lpignore": "true", "data-1p-ignore": true, "data-bwignore": true,
  "data-protonpass-ignore": true, "data-form-type": "other",
});
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
function EntryPage({ values, sources, types, isOwner, roster, onLogged, refreshKey, allowCancel = false, presetFirst = "", editing = null, onCloseEdit }) {
  const today = todayCentral();
  const [first, setFirst] = useState(presetFirst || "");
  const statuses = allowCancel ? STATUSES : STATUSES.filter(st => st.key !== "canceled");
  const [dupQuotes, setDupQuotes] = useState([]);   // this week's quotes already on file for this household
  const [onFileAnswer, setOnFileAnswer] = useState({}); // policy id -> "replaces" | "added" | "different" when the household already has that line
  const [initial, setInitial] = useState("");
  const [phone, setPhone] = useState("");            // customer phone, last four digits: part of the household key
  const [date, setDate] = useState(today);
  const [dateOpen, setDateOpen] = useState(false);
  const [logFor, setLogFor] = useState(null);
  const [suggest, setSuggest] = useState([]);      // customer names on file that match what's typed
  const [suggestOpen, setSuggestOpen] = useState(false); // the list closes on a pick, on Escape, or on a click away
  const nameBoxRef = useRef(null);
  const [onFile, setOnFile] = useState([]);        // this customer's active sold policies (rp_sold_on_file)
  const [relationship, setRelationship] = useState("");
  const [source, setSource] = useState("");
  const [activities, setActivities] = useState([]);  // [{id, key, line, type, premium, reason}]
  const [sourcedBy, setSourcedBy] = useState("");   // quotes only: who sourced the referral
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

  // ---- Edit mode ----------------------------------------------------------
  // Peter 2026-09-14. There is ONE entry form. Editing opens this same form on a
  // record that already exists: rp_entry_for_edit fills it, and Save hands only
  // the keys that record owns to the matching rp_edit_* function.
  const [editRec, setEditRec] = useState(null);
  const isEdit = !!editRec;
  useEffect(() => {
    if (!editing?.id) { setEditRec(null); return undefined; }
    let alive = true;
    (async () => {
      const r = await supabase.rpc("rp_entry_for_edit", { p_kind: editing.kind, p_id: editing.id });
      if (!alive) return;
      if (r.error) { setErr(errText(r.error)); return; }
      const d = r.data || {};
      setEditRec(d);
      setFirst(d.customer_first || ""); setInitial(d.customer_last_initial || "");
      setPhone(d.phone_last4 || ""); setDate(d.date || today); setDateOpen(true);
      setRelationship(d.relationship || ""); setSource(d.marketing_source || "");
      setSourcedBy(d.sourced_by_team_member_id || ""); setEcrm(d.ecrm_url || "");
      setNote(d.note || "");
      setSuggest([]); setSuggestOpen(false); setOk(""); setErr(""); setAttempted(false); setLast(null);
      setActivities([]); setPolicies([]); setActivePolicy(null); setScores({}); setCReason("");
      setRecTurned(false); setRecUrl(""); setOnFileAnswer({});
      if (d.kind === "sale" || d.kind === "quote") {
        setPolicies((d.products || []).map(x => ({
          id: newPolicyId(), dbId: x.id, line: x.line_of_business, type: x.product_type || "",
          status: d.kind === "sale" ? "sold" : "quoted",
          premium: x.premium == null ? "" : String(x.premium),
          vehicles: x.vehicle_count == null ? "" : String(x.vehicle_count),
          isNewLine: x.is_new_line !== false, addedToExisting: !!x.added_to_existing, autopay: !!x.autopay,
        })));
      } else if (d.kind === "cancelation") {
        setPolicies([{ id: newPolicyId(), dbId: null, line: d.policy_line, type: d.product_type || "",
          status: "canceled", premium: d.premium == null ? "" : String(d.premium),
          vehicles: d.vehicle_count == null ? "" : String(d.vehicle_count),
          isNewLine: false, addedToExisting: false, autopay: false }]);
        setCReason(d.reason || "");
      } else if (d.kind === "activity") {
        setActivities([{ id: newPolicyId(), key: d.activity_key,
          line: d.save_line || d.policy_line || "", type: d.product_type || "",
          premium: d.premium == null ? "" : String(d.premium), reason: d.save_reason || "" }]);
      } else if (d.kind === "scorecard") {
        setScores(Object.fromEntries(Object.entries(d.scores || {}).filter(([, v]) => v != null)));
        setRecTurned(!!d.recording_turned_in); setRecUrl(d.recording_url || "");
      }
    })();
    return () => { alive = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [editing?.kind, editing?.id]);

  // Which parts of the form belong to the record being edited. Logging shows them all.
  const showActivityBlock = !isEdit || editRec.kind === "activity";
  const showPolicyBlock   = !isEdit || editRec.kind === "sale" || editRec.kind === "quote" || editRec.kind === "cancelation";
  const showBottomRow     = !isEdit || editRec.kind !== "scorecard";
  const showCardBlock     = !isEdit || editRec.kind === "scorecard";

  // name suggestions: two letters in, a quarter-second pause, at most eight back
  useEffect(() => {
    const q = first.trim();
    if (q.length < 2) { setSuggest([]); return undefined; }
    let alive = true;
    const t = setTimeout(async () => {
      const { data } = await supabase.rpc("rp_customer_suggest2", { p_prefix: q });
      if (alive) setSuggest(Array.isArray(data) ? data : []);
    }, 250);
    return () => { alive = false; clearTimeout(t); };
  }, [first]);
  // A click or tap anywhere off the name box closes the list. Without this it
  // sat over the fields below until a name was picked.
  useEffect(() => {
    if (!suggestOpen) return undefined;
    const away = (e) => { if (nameBoxRef.current && !nameBoxRef.current.contains(e.target)) setSuggestOpen(false); };
    document.addEventListener("mousedown", away);
    document.addEventListener("touchstart", away);
    return () => { document.removeEventListener("mousedown", away); document.removeEventListener("touchstart", away); };
  }, [suggestOpen]);
  const pickCustomer = (c) => { setFirst(c.customer_first_name || ""); setInitial(c.customer_last_initial || ""); if (c.phone_last4) setPhone(c.phone_last4); setSuggest([]); setSuggestOpen(false); };
  const phoneOk = /^\d{4}$/.test(phone);

  // same household quoted already this week? Logs anyway; the same household counts once for HH quotes.
  useEffect(() => {
    const f = first.trim(), i = initial.trim().toUpperCase();
    if (!f || !/^[A-Z]$/.test(i)) { setDupQuotes([]); return undefined; }
    let alive = true;
    const t = setTimeout(async () => {
      let qq = supabase.from("quote_log").select("id, team_member_id, quote_date")
        .eq("agency_id", AGENCY_ID).eq("status", "active").eq("customer_label", `${f} ${i}.`).eq("week_end_date", weekEndOf(date));
      if (phoneOk) qq = qq.or(`phone_last4.is.null,phone_last4.eq.${phone}`);
      const { data } = await qq;
      if (alive) setDupQuotes(Array.isArray(data) ? data : []);
    }, 300);
    return () => { alive = false; clearTimeout(t); };
  }, [first, initial, date, phone]);

  // what this customer has on file, once the name is complete
  useEffect(() => {
    const f = first.trim(), i = initial.trim();
    if (!f || !/^[A-Za-z]$/.test(i)) { setOnFile([]); return undefined; }
    let alive = true;
    const t = setTimeout(async () => {
      const { data } = await supabase.rpc("rp_sold_on_file2", { p_customer_first: f, p_customer_last_initial: i, p_phone_last4: phoneOk ? phone : null });
      if (alive) setOnFile(Array.isArray(data) ? data : []);
    }, 300);
    return () => { alive = false; clearTimeout(t); };
  }, [first, initial, phone]);
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
    setPolicies(list => [...list, { id, line, type: "", status: "", premium: "", vehicles: "1", isNewLine: true, addedToExisting: false }]);
    setActivePolicy(id);
  };
  const editPolicy = (id, patch) => setPolicies(list => list.map(p => p.id === id ? { ...p, ...patch } : p));
  // Policies this customer still has, that are not already sitting in this entry.
  // One tap drops one in as canceled, with its premium, cars, type and the sale it
  // will be matched to already filled from what we recorded when it sold.
  const cancelable = !allowCancel ? [] : onFile.filter(r => !r.already_canceled
    && !policies.some(p => p.matchedId === r.sale_product_id));
  const cancelOnFile = (r) => {
    const id = newPolicyId();
    setPolicies(list => [...list, { id, line: r.line_of_business, type: r.product_type || "",
      status: "canceled", premium: String(r.premium ?? ""),
      vehicles: r.line_of_business === "auto" ? String(r.vehicle_count || 1) : "1",
      isNewLine: false, addedToExisting: false, matchedId: r.sale_product_id }]);
    setActivePolicy(id);
  };
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
    a.key === "cancelation_saved" ? { activity_key: a.key, save_line: a.line, product_type: a.type || null, save_reason: (a.reason || "").trim() }
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
  const flagged = isEdit ? [] : sold.filter(p => oldOnFile(p));   // a record being edited would match itself
  const replaces = flagged.filter(p => onFileAnswer[p.id] === "replaces");
  const showSuggest = suggestOpen && suggest.length > 0 && !(suggest.length === 1 && suggest[0].customer_first_name === first.trim() && (suggest[0].customer_last_initial || "") === initial.trim().toUpperCase());

  // ---- what still needs fixing, in plain words (mirrors the server rules) ----
  const problems = [];
  if (!customerOk) problems.push("Customer first name and last initial.");
  if (!phoneOk) problems.push("Customer phone, last four digits.");
  if (!hasAnything) problems.push("Add an activity or a policy, or score the conversation.");
  if (policies.some(p => !p.status)) problems.push("Each policy needs Quoted, Sold, or Canceled.");
  if (policies.some(p => needsType(p.line) && !p.type)) problems.push("Each Auto or Fire policy needs its type.");
  if (policies.some(p => needsMoney(p) && (p.premium === "" || !(Number(p.premium) >= 0)))) problems.push("Each sold or canceled policy needs its premium.");
  if (policies.some(p => needsMoney(p) && p.line === "auto" && !(Number(p.vehicles) >= 1))) problems.push("Each sold or canceled auto policy needs its number of cars.");
  if ((hasActivity || hasQuote) && date < addDays(today, -7)) problems.push("Activity and quotes are logged within 7 days. Pick a later date or split the entry.");
  if (hasSale && date < addDays(today, -30)) problems.push("A sale is logged within 30 days of the bind.");
  if (hasCxl && date < addDays(today, -90)) problems.push("A cancelation is logged within 90 days.");
  if (hasSave && date !== today) problems.push("A save is logged the same day it comes in. Set the date to today.");
  if (activities.some(a => a.key === "cancelation_saved" && (!a.line || (needsType(a.line) && !a.type) || !(a.reason || "").trim()))) problems.push("Each save needs the policy line, its type, and the reason the customer gave.");
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
    if (!keep) { setFirst(""); setInitial(""); setPhone(""); setDate(today); setDateOpen(false); }
    setSuggest([]);
    setRelationship(""); setSource(""); setSourcedBy("");
    setActivities([]);
    setPolicies([]); setActivePolicy(null); setCReason(""); setScores({}); setRecTurned(false); setRecUrl(""); setEcrm(""); setNote(""); setOnFileAnswer({});
    setAttempted(false);
  };

  // Only the keys this record owns go back. rp_edit_* applies what it is given and
  // leaves the rest alone, so a field nobody touched stays exactly as it was.
  const submitEdit = async () => {
    setErr(""); setOk(""); setAttempted(true);
    if (busy || !editRec) return;
    const k = editRec.kind;
    // A historical sale usually has no phone on file. Only insist on one when the
    // record already carried one, or when something has been typed into the box.
    const who = { customer_first: first.trim(), customer_last_initial: initial.trim() };
    if (phoneOk) who.phone_last4 = phone;
    const gate = [];
    if (!first.trim()) gate.push("First name.");
    if (k !== "scorecard" && !/^[A-Za-z]$/.test(initial.trim())) gate.push("Last initial.");
    if (phone && !phoneOk) gate.push("Customer phone: four digits, or leave it blank.");
    if (!phone && editRec.phone_last4) gate.push("Customer phone, last four digits.");
    if (k === "sale" && sold.length === 0) gate.push("A sale needs at least one sold policy.");
    if (k === "quote" && quoted.length === 0) gate.push("A quote needs at least one quoted policy.");
    if (k === "cancelation" && policies.length !== 1) gate.push("A cancelation is one policy. Log a second one separately.");
    if (k === "sale" && sold.some(p => p.premium === "" || !(Number(p.premium) >= 0))) gate.push("Every sold policy needs a premium.");
    if (k === "sale" && !ecrm.trim()) gate.push(editRec.entry_source === "historical_backfill"
      ? "Moving this into the production log needs the ECRM opportunity link."
      : "A sale needs the ECRM opportunity link.");
    if (gate.length) { setErr(gate.join(" ")); return; }
    setBusy(true);
    try {
      let fn, changes;
      if (k === "sale") {
        fn = "rp_edit_sale";
        changes = { ...who, submitted_date: date, household_status: relationship || undefined,
          marketing_source: source || undefined,
          sourced_by_team_member_id: isReferral ? (sourcedBy || "") : "",
          ecrm_opportunity_url: ecrm.trim(), note: note.trim(),
          products: sold.map(p => ({ id: p.dbId || null, line_of_business: p.line, product_type: p.type || null,
            premium: Number(p.premium), policy_count: 1,
            vehicle_count: p.line === "auto" ? Number(p.vehicles) : null,
            added_to_existing: p.line === "auto" && !!p.addedToExisting,
            is_new_line: !!p.isNewLine, autopay: !!p.autopay })) };
      } else if (k === "quote") {
        fn = "rp_edit_quote";
        changes = { ...who, quote_date: date, relationship_type: relationship || undefined,
          marketing_source: source || undefined,
          sourced_by_team_member_id: isReferral ? (sourcedBy || "") : "",
          ecrm_opportunity_url: ecrm.trim(), note: note.trim(),
          products: quoted.map(p => ({ id: p.dbId || null, line_of_business: p.line, product_type: p.type || null })) };
      } else if (k === "cancelation") {
        const one = policies[0] || {};
        fn = "rp_edit_cancelation";
        changes = { ...who, canceled_on: date, policy_line: one.line, product_type: one.type || null,
          premium: one.premium === "" ? null : Number(one.premium),
          vehicle_count: one.line === "auto" && one.vehicles !== "" ? Number(one.vehicles) : null,
          reason: cReason.trim(), note: note.trim() };
      } else if (k === "activity") {
        const a = activities[0] || {};
        fn = "rp_edit_activity";
        const isSave = a.key === "cancelation_saved";
        changes = { ...who, occurred_on: date, activity_key: a.key, note: note.trim(), ecrm_url: ecrm.trim(),
          ...(isSave
            ? { save_line: a.line || "", save_reason: (a.reason || "").trim(), product_type: a.type || "" }
            : { policy_line: a.line || "", product_type: a.type || "",
                premium: a.premium === "" ? null : Number(a.premium) }) };
      } else {
        fn = "rp_edit_scorecard";
        changes = { customer_first_name: first.trim(), ...(phoneOk ? { phone_last4: phone } : {}), scorecard_date: date,
          notes: note.trim(), recording_turned_in: !!recTurned, recording_url: recTurned ? (recUrl || "") : "",
          ...Object.fromEntries(CARD_PARTS.map(pt => [pt.key, scores[pt.key] == null ? null : Number(scores[pt.key])])) };
      }
      const { data, error } = await supabase.rpc(fn, { p_id: editRec.id, p_changes: changes });
      if (error) { setErr(errText(error)); return; }
      if (data && data.ok === false) { setErr(errText(data)); return; }
      onLogged?.();
      onCloseEdit?.(data?.moved_from_historical
        ? "Saved. That record left the historical load and sits in the production log now."
        : "Saved.");
    } catch (e) { setErr(errText(e)); } finally { setBusy(false); }
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
        customer_first: first.trim(), customer_last_initial: initial.trim(), phone_last4: phone, occurred_on: date,
        ecrm_url: ecrm.trim() || null, note: note.trim() || null, team_member_id: logFor,
        relationship_type: relationship || null,
        marketing_source: source || null,
        sourced_by_team_member_id: hasQuote && isReferral && sourcedBy ? sourcedBy : null,
        activity: hasActivity ? { items: activityItems } : null,
        quote: hasQuote ? { items: quoted.map(row) } : null,
        sale: hasSale ? {
          products: sold.map(p => ({ ...row(p), ...money(p), policy_count: 1, added_to_existing: p.line === "auto" && !!p.addedToExisting, is_new_line: householdFresh ? true : !!p.isNewLine, autopay: !!p.autopay })),
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
          customer_first: first.trim(), customer_last_initial: initial.trim(), phone_last4: phone, occurred_on: date, team_member_id: logFor, relationship_type: "existing",
          cancelation: { items, reason: "Replaced by the new policy logged with the sale" },
        } });
        if (c.error || !c.data?.ok) summary += ` The old ${replaces.map(p => PRODUCT_SHORT[p.line]).join(", ")} could not be canceled: ${errText(c.error || c.data)}. Cancel it on the Canceled tab.`;
        else { cxlResult = c.data; summary += ` Old policy ${summarizeEntry(c.data).replace(/^Logged for [^:]*: /, "")}`; }
      }
      setOk(summary);
      setLast({ result: data, cxlResult, first: first.trim(), initial: initial.trim(), phone, date });
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
    setFirst(last.first); setInitial(last.initial); setPhone(last.phone || ""); setDate(last.date);
    setOk(""); setLast(null);
  };

  const preview = first.trim() && /^[A-Za-z]$/.test(initial.trim()) ? `${first.trim()} ${initial.trim().toUpperCase()}.${phoneOk ? ` ·${phone}` : ""}` : "";
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
        <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900, marginBottom: 4 }}>
          {isEdit ? `Editing this ${editRec.kind === "scorecard" ? "conversation score" : editRec.kind}` : "What happened with this customer?"}
        </div>
        <div style={{ fontSize: 13, color: T.slate500, marginBottom: 16, display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center" }}>
          <span>{isEdit ? "Change what needs changing and save." : "Add what happened. One button saves it all."}</span>
          {isEdit && editRec.entry_source === "historical_backfill" && (
            <span style={{ padding: "3px 9px", borderRadius: 999, background: T.amberLt, color: T.amber, fontSize: 12, fontWeight: 700 }}>
              Saving moves this out of the historical load and into the production log
            </span>
          )}
          {isEdit && <button type="button" style={linkBtn} onClick={() => onCloseEdit?.("")}>Cancel</button>}
        </div>

        {/* ---- row 1: every first field, wrapping ---- */}
        <div style={wrapRow}>
          {isOwner && !isEdit && (
            <div style={{ flex: "0 1 120px", minWidth: 0 }}>
              <label style={labelStyle}>Log for</label>
              <select style={inputBase} value={logFor || ""} onChange={e => setLogFor(e.target.value || null)}>
                <option value="">Myself</option>
                {(roster || []).map(t => <option key={t.id} value={t.id}>{t.first_name}</option>)}
              </select>
            </div>
          )}
          <div ref={nameBoxRef} style={{ ...field(150), position: "relative" }}>
            <label style={labelStyle}>First name</label>
            <input {...noPwManager("a1")} style={inputBase} value={first} placeholder="Anna"
              onChange={e => { setFirst(e.target.value); setSuggestOpen(true); }}
              onFocus={() => setSuggestOpen(true)}
              onKeyDown={e => { if (e.key === "Escape") { e.stopPropagation(); setSuggestOpen(false); } }} />
            {showSuggest && (
              <div style={{ position: "absolute", top: "100%", left: 0, right: 0, zIndex: 5, background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 8, boxShadow: "0 6px 16px rgba(0,0,0,0.08)", marginTop: 4, overflow: "hidden" }}>
                {suggest.map(c => (
                  <button key={c.customer_label} type="button" onClick={() => pickCustomer(c)}
                    style={{ display: "block", width: "100%", textAlign: "left", padding: "8px 12px", border: "none", background: "transparent", fontSize: 14, color: T.slate800, cursor: "pointer", fontFamily: "inherit" }}>
                    {c.customer_label}{c.phone_last4 ? <span style={{ color: T.slate500 }}> ·{c.phone_last4}</span> : null} <span style={{ color: T.slate400, fontSize: 12 }}>{Number(c.policies_on_file) > 0 ? plural(c.policies_on_file, "policy").replace("policys", "policies") + " on file" : "on file"}{c.last_seen ? ` · ${fmtDate(c.last_seen)}` : ""}</span>
                  </button>
                ))}
              </div>
            )}
          </div>
          <div style={{ flex: "0 0 78px" }}>
            <label style={labelStyle}>Initial</label>
            <input style={{ ...inputBase, textAlign: "center" }} value={initial} maxLength={1} onChange={e => setInitial(e.target.value)} placeholder="S" {...noPwManager("a2")} />
          </div>
          <div style={{ flex: "0 0 126px" }}>
            <label style={labelStyle}>Phone last 4</label>
            <input {...noPwManager("a3")} inputMode="numeric" style={{ ...inputBase, textAlign: "center" }} value={phone} maxLength={4} onChange={e => setPhone(e.target.value.replace(/\D/g, "").slice(0, 4))} placeholder="4417" />
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
        {showActivityBlock && (
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
                <input type="number" inputMode="decimal" min="0" step="0.01" style={moneyInput} value={a.premium} onChange={e => editActivity(a.id, { premium: e.target.value })} placeholder="0.00" />
              </div>
            </div>
          ))}
          {activities.filter(a => a.key === "cancelation_saved").map(a => (
            <div key={a.id} style={{ ...wrapRow, marginTop: 10, padding: 10, background: T.slate50, borderRadius: 8 }}>
              <div style={{ fontWeight: 700, color: T.slate800, flex: "0 0 auto", paddingBottom: 10 }}>Saved</div>
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
              <div style={field(260)}>
                <label style={labelStyle}>Reason the customer gave</label>
                <input style={inputBase} value={a.reason || ""} onChange={e => editActivity(a.id, { reason: e.target.value })} placeholder="Rate went up at renewal; found a cheaper quote" />
              </div>
            </div>
          ))}
        </div>
        )}

        {!isEdit && cancelable.length > 0 && (
          <div style={blockStyle}>
            <div style={labelStyle}>On file for this customer — tap what canceled</div>
            <div style={chipRow}>
              {cancelable.map(r => (
                <span key={r.sale_product_id} style={chip(false)} onClick={() => cancelOnFile(r)}>
                  {PRODUCT_SHORT[r.line_of_business] || r.line_of_business}
                  {r.product_type ? ` ${r.product_type}` : ""}
                  {r.premium != null ? ` · $${fmtPts(r.premium)}` : ""}
                </span>
              ))}
            </div>
          </div>
        )}

        {/* ---- policies: Add dropdown + pills on one row; the pill tapped last is edited below ---- */}
        {showPolicyBlock && (
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
                  <input type="number" inputMode="decimal" min="0" step="0.01" style={moneyInput} value={active.premium} onChange={e => editPolicy(active.id, { premium: e.target.value })} placeholder="0.00" />
                </div>
              )}
              {needsMoney(active) && active.line === "auto" && (
                <div style={field(70)}>
                  <label style={labelStyle}>Cars</label>
                  <input type="number" inputMode="numeric" min="1" step="1" style={inputBase} value={active.vehicles} onChange={e => editPolicy(active.id, { vehicles: e.target.value })} />
                </div>
              )}
              {isSold(active) && active.line === "auto" && (
                <div style={field(190)}>
                  <label style={labelStyle}>Auto policy</label>
                  <select style={inputBase} value={active.addedToExisting ? "added" : "new"}
                          onChange={e => editPolicy(active.id, { addedToExisting: e.target.value === "added" })}>
                    <option value="new">A new policy</option>
                    <option value="added">Added to one they had</option>
                  </select>
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
          {!isEdit && hasQuote && dupQuotes.length > 0 && (
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
        )}

        {/* ---- bottom row: ECRM link (sale), marketing source (quote or sale), lead source (referral), note ---- */}
        {showBottomRow && (
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
          {hasQuote && isReferral && (
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
        )}

        {/* ---- scorecard: one compact row, 10 parts, x / 1 / 2 / 3; every part on a quote or sale ---- */}
        {showCardBlock && (
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
        )}

        <div style={{ display: "flex", flexWrap: "wrap", gap: 12, alignItems: "center", marginTop: 18, position: "sticky", bottom: 8, background: T.white, padding: "8px 0", zIndex: 3 }}>
          <button style={btnPrimary(busy)} disabled={busy} onClick={isEdit ? submitEdit : submit}>
            {busy ? "Saving…" : isEdit ? "Save changes" : `Log it${activityTotal ? ` · $${fmtPts(activityTotal)}` : ""}`}
          </button>
          {isEdit && <button type="button" style={btnGhost} disabled={busy} onClick={() => onCloseEdit?.("")}>Cancel</button>}
        </div>
        {attempted && !isEdit && problems.length > 0 && (
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
      {!isEdit && <PendingSaves refreshKey={refreshKey} />}
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
// Records panel — one table used in two places (Peter 2026-09-14): the
// Pending tab, and the card at the bottom of Scoreboard that used
// to be "Sales this week". Same table both times. The toggle picks what
// it lists; the scope decides what shows up.
//   scope "pending" — what we have not paid on yet: policies that have
//     not issued, appointments that have not been kept or sold, saves
//     still counting down. We do not pay on any of it until it is not
//     going to cancel.
//   scope "week"    — everything logged in the week being shown.
// A new Private Passenger auto policy never sits in the pending list: it
// issues the day it is submitted (trigger trg_rp_auto_issue). Everything
// else waits until someone confirms it issued with no contingencies.
//
// Appointments are ONE record that moves through its states, the same
// shape as a policy going submitted then issued (Peter 2026-09-11):
// marked set, then kept, then sold. Setting it pays nothing. Kept and
// Sold only pay when the appointment was handed to someone else, and the
// money goes to whoever handed it over, never the seller.
// =====================================================================
const RECORD_KINDS = [
  { key: "appointments", label: "Appointments" },
  { key: "activities",   label: "Activities" },
  { key: "sales",        label: "Sales" },
];
const SALE_SELECT = "id, team_member_id, submitted_date, week_end_date, customer_label, customer_first_name, customer_last_initial, phone_last4, household_status, marketing_source, vehicle_count, total_premium, note, ecrm_opportunity_url, on_file_answer, entry_source, sales_log_products(id, line_of_business, product_type, premium, policy_count, vehicle_count, is_new_line, is_added_to_existing, issued_date, issued_premium, autopay_enrolled)";
const APPT_SELECT = "id, team_member_id, escalated_to_team_member_id, set_on, week_end_date, kept_on, no_show_on, sold_on, customer_label, customer_first_name, customer_last_initial, phone_last4, line_of_business, product_type, note, ecrm_url";
const ACT_SELECT = "id, team_member_id, activity_key, occurred_on, customer_label, customer_first_name, customer_last_initial, phone_last4, note, points, source, policy_line, product_type, premium, credit_available_on, ecrm_url";
const relLabel = (k) => k === "new" ? "New" : k === "winback" ? "Winback" : "Existing";
const onFileLabel = (k) => k === "replaces" ? "replaced old policy" : k === "added" ? "added to on-file" : "different household";
const daysBetween = (a, b) => Math.round((new Date(b + "T00:00:00") - new Date(a + "T00:00:00")) / 86400000);
const smallInput = { fontSize: 13, padding: "5px 7px", borderRadius: 7, border: `1px solid ${T.slate200}`, boxSizing: "border-box" };
const apptState = (r) => r.sold_on ? "Sold" : r.no_show_on ? "No show" : r.kept_on ? "Kept" : "Set";
// Whoever the appointment was handed to. Nobody took it over, it belongs to
// the person who set it. Only that person marks it kept, a no show or sold:
// the setter is the one who gets paid for it, so the setter does not get to
// mark their own (Peter 2026-09-13). The server enforces the same rule.
const apptHost = (r) => (r.escalated_to_team_member_id && r.escalated_to_team_member_id !== r.team_member_id)
  ? r.escalated_to_team_member_id : r.team_member_id;

function RecordsPanel({ scope, weekEnd, title, blurb, values, sources, types, roster, nameOf, isOwner, isAdmin, myTeamId, refreshKey, onChanged }) {
  const [kind, setKind] = useState("sales");
  const [rows, setRows] = useState(null);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState("");
  const [done, setDone] = useState("");
  const [busy, setBusy] = useState(null);
  const [dates, setDates] = useState({});
  const [prems, setPrems] = useState({});
  const [editing, setEditing] = useState(null);   // { kind, row }
  const [adding, setAdding] = useState(false);

  const actLabel = useMemo(() => {
    const m = new Map();
    for (const v of values || []) m.set(v.activity_key, v.label);
    return (k) => m.get(k) || k;
  }, [values]);

  const load = useCallback(async () => {
    setLoading(true); setErr("");
    try {
      const today = todayCentral();
      if (kind === "sales") {
        let q = supabase.from("sales_log").select(SALE_SELECT).eq("agency_id", AGENCY_ID).eq("status", "active");
        if (scope === "week") {
          q = q.eq("week_end_date", weekEnd);
        } else {
          const pend = await supabase.from("sales_log_products").select("sales_log_id").eq("agency_id", AGENCY_ID).is("issued_date", null);
          const ids = Array.from(new Set((pend.data || []).map(r => r.sales_log_id)));
          if (!ids.length) { setRows([]); return; }
          q = q.in("id", ids);
        }
        const r = await q.order("submitted_date", { ascending: scope === "pending" });
        if (r.error) throw r.error;
        setRows(Array.isArray(r.data) ? r.data : []);
      } else if (kind === "appointments") {
        let q = supabase.from("appointment_log").select(APPT_SELECT).eq("agency_id", AGENCY_ID).eq("status", "active");
        if (scope === "week") q = q.eq("week_end_date", weekEnd);
        else q = q.is("sold_on", null).is("no_show_on", null);
        const r = await q.order("set_on", { ascending: scope === "pending" });
        if (r.error) throw r.error;
        setRows(Array.isArray(r.data) ? r.data : []);
      } else {
        let q = supabase.from("retention_activity_log").select(ACT_SELECT).eq("agency_id", AGENCY_ID).eq("status", "active");
        if (scope === "week") q = q.eq("week_end_date", weekEnd);
        else q = q.gt("credit_available_on", today);
        const r = await q.order("occurred_on", { ascending: scope === "pending" });
        if (r.error) throw r.error;
        setRows(Array.isArray(r.data) ? r.data : []);
      }
    } catch (e) { setErr(errText(e)); setRows([]); } finally { setLoading(false); }
  }, [kind, scope, weekEnd]);

  useEffect(() => { load(); }, [load, refreshKey]);

  const after = () => { if (onChanged) onChanged(); else load(); };
  const canTouch = (tm) => isAdmin || tm === myTeamId;

  const setAutopay = async (productId, on) => {
    setBusy(productId); setErr("");
    const { error } = await supabase.rpc("rp_set_sale_autopay", { p_sale_product_id: productId, p_on: on });
    setBusy(null);
    if (error) { setErr(errText(error)); return; }
    after();
  };

  const markIssued = async (sale, p) => {
    const prem = prems[p.id] === undefined ? String(p.premium ?? "") : prems[p.id];
    if (prem === "" || !(Number(prem) >= 0)) { setErr("Enter the issued premium first."); return; }
    setBusy(p.id); setErr(""); setDone("");
    const r = await supabase.rpc("rp_mark_issued", {
      p_items: [{ sale_product_id: p.id, issued_date: dates[p.id] || todayCentral(), issued_premium: Number(prem) }],
    });
    setBusy(null);
    if (r.error) { setErr(errText(r.error)); return; }
    setDone(`${sale.customer_label} — ${typeLabel(types || {}, p.line_of_business, p.product_type) || PRODUCT_SHORT[p.line_of_business] || p.line_of_business} marked issued.`);
    after();
  };

  const unIssue = async (p) => {
    if (!window.confirm("Put this policy back in the to-be-issued list?")) return;
    setBusy(p.id); setErr("");
    const { data, error } = await supabase.rpc("rp_unmark_issued", { p_sale_product_id: p.id });
    setBusy(null);
    if (error || !data?.ok) { setErr(errText(error || data)); return; }
    after();
  };

  const moveAppt = async (row, state) => {
    setBusy(row.id); setErr(""); setDone("");
    const { data, error } = await supabase.rpc("rp_set_appointment_state", {
      p_id: row.id, p_state: state, p_on: dates[row.id] || todayCentral(),
    });
    setBusy(null);
    if (error || !data?.ok) { setErr(errText(error || data)); return; }
    setDone(`${row.customer_label} — appointment marked ${state === "no_show" ? "a no show" : state}.`);
    after();
  };

  const removeRow = async (recordKind, id, what) => {
    if (!window.confirm(`Delete this ${what}? It comes off the week's points.`)) return;
    const { data, error } = await supabase.rpc("rp_delete_record", { p_kind: recordKind, p_id: id, p_reason: null });
    if (error || !data?.ok) { window.alert(errText(error || data)); return; }
    after();
  };

  const emptyWord = scope === "pending"
    ? { sales: "Everything submitted has been issued. Nothing waiting.", appointments: "No appointments still open.", activities: "Nothing still counting down." }[kind]
    : { sales: "No sales logged this week.", appointments: "No appointments set this week.", activities: "No activities logged this week." }[kind];

  return (
    <div style={cardStyle}>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center", justifyContent: "space-between", marginBottom: 10 }}>
        <div>
          <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>{title}{loading ? <span style={{ color: T.slate400, fontWeight: 400, fontSize: 12 }}> · loading…</span> : null}</div>
          {blurb && <div style={{ fontSize: 12, color: T.slate500 }}>{blurb}</div>}
        </div>
        <div style={{ display: "flex", flexWrap: "wrap", gap: 8, alignItems: "center" }}>
          {kind === "appointments" && (
            <button type="button" style={btnGhost} onClick={() => setAdding(true)}>Add appointment</button>
          )}
          <div style={chipRow}>
            {RECORD_KINDS.map(k => (
              <span key={k.key} onClick={() => setKind(k.key)} style={{ ...chip(kind === k.key), padding: "6px 12px", fontSize: 12 }}>{k.label}</span>
            ))}
          </div>
        </div>
      </div>

      {err && <Notice kind="error">{err}</Notice>}
      {done && <Notice kind="ok">{done}</Notice>}

      {rows && rows.length === 0 && !loading && (
        <div style={{ fontSize: 13, color: T.slate600, padding: "6px 0" }}>{emptyWord}</div>
      )}

      {rows && rows.length > 0 && (
        <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
          <table style={{ width: "100%", borderCollapse: "collapse" }}>
            {kind === "sales" && (
              <thead><tr>
                <th style={tableTh}>Date</th><th style={tableTh}>Who</th><th style={tableTh}>Customer</th>
                <th style={tableTh}>Relationship</th><th style={tableTh}>Policies</th><th style={tableTh}>Cars</th>
                <th style={tableTh}>Premium</th><th style={tableTh}>Source</th>
                <th style={tableTh}>Waiting</th><th style={tableTh}></th>
              </tr></thead>
            )}
            {kind === "appointments" && (
              <thead><tr>
                <th style={tableTh}>Set</th><th style={tableTh}>Who</th><th style={tableTh}>Handed to</th>
                <th style={tableTh}>Customer</th><th style={tableTh}>About</th><th style={tableTh}>State</th><th style={tableTh}>Move it along</th>
                <th style={tableTh}>Waiting</th><th style={tableTh}>Note</th><th style={tableTh}></th>
              </tr></thead>
            )}
            {kind === "activities" && (
              <thead><tr>
                <th style={tableTh}>Date</th><th style={tableTh}>Who</th><th style={tableTh}>Customer</th>
                <th style={tableTh}>Activity</th><th style={tableTh}>Policy</th><th style={tableTh}>Points</th>
                <th style={tableTh}>Clears</th><th style={tableTh}>Note</th><th style={tableTh}></th>
              </tr></thead>
            )}
            <tbody>
              {kind === "sales" && rows.map(r => {
                const ps = r.sales_log_products || [];
                const anyOpen = ps.some(p => !p.issued_date);
                const wait = anyOpen ? daysBetween(r.submitted_date, todayCentral()) : null;
                return (
                  <tr key={r.id}>
                    <td style={tableTd}>{fmtDate(r.submitted_date)}</td>
                    <td style={tableTd}>
                      {nameOf(r.team_member_id)}
                    </td>
                    <td style={tableTd}>{r.customer_label}{r.phone_last4 ? <div style={{ fontSize: 11, color: T.slate400 }}>·{r.phone_last4}</div> : null}</td>
                    <td style={tableTd}>
                      {relLabel(r.household_status)}
                      {r.on_file_answer && <div style={{ fontSize: 11, color: T.amber }}>{onFileLabel(r.on_file_answer)}</div>}
                    </td>
                    <td style={tableTd}>
                      {ps.map((p, i) => (
                        <div key={p.id || i} style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap", padding: "2px 0" }}>
                          <span>
                            {typeLabel(types || {}, p.line_of_business, p.product_type) || PRODUCT_SHORT[p.line_of_business] || p.line_of_business}
                            {" $"}{fmtPts(p.premium)}
                            {p.vehicle_count ? ` · ${plural(p.vehicle_count, "car")}` : ""}
                          </span>
                          {p.id && (
                            <label style={{ display: "flex", alignItems: "center", gap: 4, fontSize: 11, color: p.autopay_enrolled ? T.green : T.slate500, cursor: busy === p.id ? "wait" : "pointer" }}
                              title="Tick this when the customer signs up for automatic payment, even if that happens after the sale. One autopay credit per policy.">
                              <input type="checkbox" checked={!!p.autopay_enrolled} disabled={busy === p.id}
                                onChange={e => setAutopay(p.id, e.target.checked)} />
                              Autopay
                            </label>
                          )}
                          {p.issued_date ? (
                            <span style={{ fontSize: 11, color: T.green }}>
                              issued {fmtDate(p.issued_date)}{p.issued_premium != null ? ` · $${fmtPts(p.issued_premium)}` : ""}
                              {canTouch(r.team_member_id) && <button type="button" style={{ ...miniBtn, marginLeft: 6 }} onClick={() => unIssue(p)}>Undo</button>}
                            </span>
                          ) : (
                            <span style={{ display: "inline-flex", alignItems: "center", gap: 5, flexWrap: "wrap" }}>
                              <input type="number" inputMode="decimal" min="0" step="0.01" title="Issued premium"
                                value={prems[p.id] === undefined ? String(p.premium ?? "") : prems[p.id]}
                                onChange={e => setPrems(d => ({ ...d, [p.id]: e.target.value }))}
                                style={{ ...smallInput, width: 100, textAlign: "right" }} />
                              <input type="date" title="Date it issued"
                                value={dates[p.id] || todayCentral()}
                                min={r.submitted_date} max={todayCentral()}
                                onChange={e => setDates(d => ({ ...d, [p.id]: e.target.value }))}
                                style={smallInput} />
                              <button type="button" onClick={() => markIssued(r, p)} disabled={busy === p.id}
                                style={{ padding: "5px 11px", borderRadius: 7, border: "none", cursor: "pointer", background: T.blue, color: "#fff", fontSize: 12, fontWeight: 700, opacity: busy === p.id ? 0.6 : 1 }}>
                                Issue
                              </button>
                            </span>
                          )}
                        </div>
                      ))}
                    </td>
                    <td style={tableTd}>{r.vehicle_count ?? "—"}</td>
                    <td style={tableTd}>${fmtPts(r.total_premium)}</td>
                    <td style={tableTd}>{r.marketing_source}</td>
                    <td style={{ ...tableTd, color: wait != null && wait > 14 ? T.red : T.slate600, fontWeight: wait != null && wait > 14 ? 700 : 400 }}>
                      {wait == null ? "—" : `${wait}d`}
                    </td>
                    <td style={tableTd}>
                      {canTouch(r.team_member_id) && (
                        <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
                          <button type="button" style={miniBtn} onClick={() => setEditing({ kind: "sale", row: r })}>Edit</button>
                          <button type="button" style={{ ...miniBtn, color: T.red }} onClick={() => removeRow("sale", r.id, "sale")}>Delete</button>
                        </div>
                      )}
                    </td>
                  </tr>
                );
              })}

              {kind === "appointments" && rows.map(r => {
                const escalated = r.escalated_to_team_member_id && r.escalated_to_team_member_id !== r.team_member_id;
                return (
                  <tr key={r.id}>
                    <td style={tableTd}>{fmtDate(r.set_on)}</td>
                    <td style={tableTd}>{nameOf(r.team_member_id)}</td>
                    <td style={tableTd}>
                      {escalated ? nameOf(r.escalated_to_team_member_id)
                        : <span style={{ color: T.slate400 }} title="An appointment you keep for yourself pays nothing here. It pays through the sale.">kept it</span>}
                    </td>
                    <td style={tableTd}>{r.customer_label}{r.phone_last4 ? <div style={{ fontSize: 11, color: T.slate400 }}>·{r.phone_last4}</div> : null}</td>
                    <td style={tableTd}>
                      {r.line_of_business
                        ? (typeLabel(types || {}, r.line_of_business, r.product_type) || PRODUCT_SHORT[r.line_of_business] || r.line_of_business)
                        : <span style={{ color: T.slate400 }}>—</span>}
                    </td>
                    <td style={tableTd}>
                      {apptState(r)}
                      {r.sold_on ? <div style={{ fontSize: 11, color: T.green }}>sold {fmtDate(r.sold_on)}</div>
                        : r.no_show_on ? <div style={{ fontSize: 11, color: T.red }}>{fmtDate(r.no_show_on)}</div>
                        : r.kept_on ? <div style={{ fontSize: 11, color: T.slate500 }}>{fmtDate(r.kept_on)}</div> : null}
                    </td>
                    <td style={tableTd}>
                      {canTouch(apptHost(r)) ? (
                        <span style={{ display: "inline-flex", alignItems: "center", gap: 5, flexWrap: "wrap" }}>
                          <input type="date" title="Date it happened"
                            value={dates[r.id] || todayCentral()} min={r.set_on} max={todayCentral()}
                            onChange={e => setDates(d => ({ ...d, [r.id]: e.target.value }))} style={smallInput} />
                          {!r.kept_on && <button type="button" style={miniBtn} disabled={busy === r.id} onClick={() => moveAppt(r, "kept")}>Kept</button>}
                          {!r.sold_on && <button type="button" style={miniBtn} disabled={busy === r.id} onClick={() => moveAppt(r, "sold")}>Sold</button>}
                          {!r.no_show_on && !r.sold_on && <button type="button" style={miniBtn} disabled={busy === r.id} onClick={() => moveAppt(r, "no_show")}>No show</button>}
                          {(r.kept_on || r.sold_on || r.no_show_on) && <button type="button" style={miniBtn} disabled={busy === r.id} onClick={() => moveAppt(r, "open")}>Undo</button>}
                        </span>
                      ) : "—"}
                    </td>
                    <td style={tableTd}>{`${daysBetween(r.set_on, todayCentral())}d`}</td>
                    <td style={tableTd}>{r.note || "—"}</td>
                    <td style={tableTd}>
                      {canTouch(r.team_member_id) && (
                        <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
                          <button type="button" style={miniBtn} onClick={() => setEditing({ kind: "appointment", row: r })}>Edit</button>
                          <button type="button" style={{ ...miniBtn, color: T.red }} onClick={() => removeRow("appointment", r.id, "appointment")}>Delete</button>
                        </div>
                      )}
                    </td>
                  </tr>
                );
              })}

              {kind === "activities" && rows.map(r => (
                <tr key={r.id}>
                  <td style={tableTd}>{fmtDate(r.occurred_on)}</td>
                  <td style={tableTd}>{nameOf(r.team_member_id)}</td>
                  <td style={tableTd}>{r.customer_label || "—"}{r.phone_last4 ? <div style={{ fontSize: 11, color: T.slate400 }}>·{r.phone_last4}</div> : null}</td>
                  <td style={tableTd}>{actLabel(r.activity_key)}{r.source !== "manual" && <div style={{ fontSize: 11, color: T.slate400 }}>from a sale</div>}</td>
                  <td style={tableTd}>
                    {r.policy_line
                      ? <>{typeLabel(types || {}, r.policy_line, r.product_type) || PRODUCT_SHORT[r.policy_line] || r.policy_line}{r.premium != null ? ` · $${fmtPts(r.premium)}` : ""}</>
                      : "—"}
                  </td>
                  <td style={tableTd}>${fmtPts(r.points)}</td>
                  <td style={tableTd}>{r.credit_available_on ? fmtDate(r.credit_available_on) : "—"}</td>
                  <td style={tableTd}>{r.note || "—"}</td>
                  <td style={tableTd}>
                    {canTouch(r.team_member_id) && r.source === "manual" && (
                      <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
                        <button type="button" style={miniBtn} onClick={() => setEditing({ kind: "activity", row: r })}>Edit</button>
                        <button type="button" style={{ ...miniBtn, color: T.red }} onClick={() => removeRow("activity", r.id, "entry")}>Delete</button>
                      </div>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {adding && (
        <AddAppointment roster={roster} myTeamId={myTeamId} types={types}
          onClose={() => setAdding(false)}
          onSaved={(who) => { setAdding(false); setKind("appointments"); setDone(`Appointment set with ${who}.`); after(); }} />
      )}

      {editing && (
        <EditRecord
          kind={editing.kind} row={editing.row} sources={sources} types={types} roster={roster} isOwner={isOwner}
          onClose={() => setEditing(null)}
          onSaved={() => { setEditing(null); setDone("Saved."); after(); }}
        />
      )}
    </div>
  );
}

// ---------------------------------------------------------------------
// Set an appointment. Who you hand it to is the whole point: an
// appointment you keep for yourself pays nothing here (Peter 2026-09-11).
// ---------------------------------------------------------------------
function AddAppointment({ roster, myTeamId, types, onClose, onSaved }) {
  const [f, setF] = useState({ customer_first: "", customer_last_initial: "", phone_last4: "", set_on: todayCentral(), escalated_to: "", line_of_business: "", product_type: "", note: "" });
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState("");
  const set = (k, v) => setF(d => ({ ...d, [k]: v }));

  const save = async () => {
    setSaving(true); setErr("");
    const { data, error } = await supabase.rpc("rp_log_appointment", {
      p_payload: {
        customer_first: f.customer_first, customer_last_initial: f.customer_last_initial,
        phone_last4: f.phone_last4, set_on: f.set_on,
        line_of_business: f.line_of_business, product_type: f.product_type || null,
        escalated_to_team_member_id: f.escalated_to || null, note: f.note,
      },
    });
    setSaving(false);
    if (error || !data?.ok) { setErr(errText(error || data)); return; }
    onSaved(data.customer || f.customer_first);
  };

  return (
    <Modal title="Set an appointment" onClose={onClose}>
      <div style={{ ...cardStyle, display: "grid", gap: 12 }}>
        {err && <Notice kind="error">{err}</Notice>}
        <div style={gridForm}>
          <div>
            <label style={labelStyle}>First name</label>
            <input value={f.customer_first} onChange={e => set("customer_first", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }} {...noPwManager("afn")} />
          </div>
          <div>
            <label style={labelStyle}>Last initial</label>
            <input value={f.customer_last_initial} maxLength={1} onChange={e => set("customer_last_initial", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }} {...noPwManager("ali")} />
          </div>
          <div>
            <label style={labelStyle}>Phone, last four</label>
            <input value={f.phone_last4} maxLength={4} inputMode="numeric" onChange={e => set("phone_last4", e.target.value.replace(/\D/g, ""))} style={{ ...smallInput, width: "100%", padding: "9px 10px" }} {...noPwManager("ap4")} />
          </div>
          <div>
            <label style={labelStyle}>Date set</label>
            <input type="date" value={f.set_on} max={todayCentral()} onChange={e => set("set_on", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }} />
          </div>
          <div>
            <label style={labelStyle}>About</label>
            <select value={f.line_of_business} onChange={e => setF(d => ({ ...d, line_of_business: e.target.value, product_type: "" }))} style={{ ...smallInput, width: "100%", padding: "9px 10px" }}>
              <option value="">Pick one</option>
              {PRODUCTS.map(p => <option key={p.key} value={p.key}>{p.label}</option>)}
            </select>
          </div>
          {((types || {})[f.line_of_business] || []).length > 0 && (
            <div>
              <label style={labelStyle}>Type</label>
              <select value={f.product_type} onChange={e => set("product_type", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }}>
                <option value="">Pick one</option>
                {((types || {})[f.line_of_business] || []).map(t => <option key={t.type_key} value={t.type_key}>{t.label}</option>)}
              </select>
            </div>
          )}
          <div>
            <label style={labelStyle}>Handed to <span style={hintStyle}>pays only if you hand it over</span></label>
            <select value={f.escalated_to} onChange={e => set("escalated_to", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }}>
              <option value="">I am keeping it</option>
              {(roster || []).filter(t => t.id !== myTeamId).map(t => <option key={t.id} value={t.id}>{t.first_name}</option>)}
            </select>
          </div>
        </div>
        <div>
          <label style={labelStyle}>Note</label>
          <input value={f.note} onChange={e => set("note", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }} {...noPwManager("anote")} />
        </div>
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <button type="button" style={btnPrimary(saving)} disabled={saving} onClick={save}>{saving ? "Saving…" : "Set it"}</button>
          <button type="button" style={btnGhost} onClick={onClose}>Cancel</button>
        </div>
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------------
// Edit a record in place. Never delete and re-create: the change history
// on the row has to survive (Peter 2026-09-14). Sales edit their policies
// too; appointments and activities edit the customer, date and note.
// ---------------------------------------------------------------------
function EditRecord({ kind, row, sources, types, roster, isOwner, onClose, onSaved }) {
  const [f, setF] = useState(() => ({
    customer_first: row.customer_first_name || "",
    customer_last_initial: row.customer_last_initial || "",
    phone_last4: row.phone_last4 || "",
    on_date: row.submitted_date || row.set_on || row.occurred_on || todayCentral(),
    relationship: row.household_status || "existing",
    marketing_source: row.marketing_source || "",
    escalated_to: row.escalated_to_team_member_id || "",
    appt_line: row.line_of_business || "",
    appt_type: row.product_type || "",
    owner: row.team_member_id || "",
    note: row.note || "",
    ecrm: row.ecrm_opportunity_url || row.ecrm_url || "",
    products: (row.sales_log_products || []).map(p => ({ ...p, added_to_existing: !!p.is_added_to_existing })),
  }));
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState("");
  const set = (k, v) => setF(d => ({ ...d, [k]: v }));
  const setProd = (i, k, v) => setF(d => ({ ...d, products: d.products.map((p, j) => j === i ? { ...p, [k]: v } : p) }));

  // A sale in the production log carries the ECRM opportunity link. A historical
  // row has none, and saving moves it into the production log, so the link is
  // what that move costs. Say so here rather than let the table's own check
  // constraint throw its name at the screen.
  const save = async () => {
    setErr("");
    if (kind === "sale" && !f.ecrm.trim()) {
      setErr(row.entry_source === "historical_backfill"
        ? "Moving this into the production log needs the ECRM opportunity link."
        : "A sale needs the ECRM opportunity link.");
      return;
    }
    if (kind === "sale" && !/^https?:\/\//i.test(f.ecrm.trim())) {
      setErr("The ECRM link must start with http."); return;
    }
    setSaving(true);
    let fn, changes;
    if (kind === "sale") {
      fn = "rp_edit_sale";
      changes = {
        customer_first: f.customer_first, customer_last_initial: f.customer_last_initial, phone_last4: f.phone_last4,
        submitted_date: f.on_date, household_status: f.relationship, marketing_source: f.marketing_source,
        note: f.note,
        products: f.products.map(p => ({
          id: p.id, line_of_business: p.line_of_business, product_type: p.product_type,
          premium: String(p.premium ?? ""), policy_count: String(p.policy_count ?? 1),
          vehicle_count: p.vehicle_count == null ? "" : String(p.vehicle_count),
          is_new_line: !!p.is_new_line,
          added_to_existing: p.line_of_business === "auto" && !!p.added_to_existing,
          issued_date: p.issued_date || "", issued_premium: p.issued_premium == null ? "" : String(p.issued_premium),
          autopay: !!p.autopay_enrolled,
        })),
      };
      changes.ecrm_opportunity_url = f.ecrm.trim();
    } else if (kind === "appointment") {
      fn = "rp_edit_appointment";
      changes = {
        customer_first: f.customer_first, customer_last_initial: f.customer_last_initial, phone_last4: f.phone_last4,
        set_on: f.on_date, escalated_to_team_member_id: f.escalated_to || null, note: f.note,
        line_of_business: f.appt_line, product_type: f.appt_type || null,
      };
    } else {
      fn = "rp_edit_activity";
      changes = {
        customer_first: f.customer_first, customer_last_initial: f.customer_last_initial, phone_last4: f.phone_last4,
        occurred_on: f.on_date, note: f.note,
      };
    }
    const { data, error } = await supabase.rpc(fn, { p_id: row.id, p_changes: changes });
    if (error || !data?.ok) { setSaving(false); setErr(errText(error || data)); return; }
    // Moving it to someone else is its own call — the edit functions do not own
    // who a record belongs to.
    if (isOwner && f.owner && f.owner !== row.team_member_id) {
      const mv = await supabase.rpc("rp_reassign_record", { p_kind: kind, p_id: row.id, p_team_member_id: f.owner });
      if (mv.error || !mv.data?.ok) { setSaving(false); setErr(errText(mv.error || mv.data)); return; }
    }
    setSaving(false);
    onSaved();
  };

  const titleWord = kind === "sale" ? "sale" : kind === "appointment" ? "appointment" : "entry";
  return (
    <Modal title={`Edit this ${titleWord}`} onClose={onClose}>
      <div style={{ ...cardStyle, display: "grid", gap: 12 }}>
        {err && <Notice kind="error">{err}</Notice>}
        {kind === "sale" && row.entry_source === "historical_backfill" && (
          <div style={{ justifySelf: "start", padding: "3px 9px", borderRadius: 999, background: T.amberLt, color: T.amber, fontSize: 12, fontWeight: 700 }}>
            Saving moves this out of the historical load and into the production log
          </div>
        )}
        <div style={gridForm}>
          <div>
            <label style={labelStyle}>First name</label>
            <input value={f.customer_first} onChange={e => set("customer_first", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }} {...noPwManager("efn")} />
          </div>
          <div>
            <label style={labelStyle}>Last initial</label>
            <input value={f.customer_last_initial} maxLength={1} onChange={e => set("customer_last_initial", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }} {...noPwManager("eli")} />
          </div>
          <div>
            <label style={labelStyle}>Phone, last four</label>
            <input value={f.phone_last4} maxLength={4} inputMode="numeric" onChange={e => set("phone_last4", e.target.value.replace(/\D/g, ""))} style={{ ...smallInput, width: "100%", padding: "9px 10px" }} {...noPwManager("ep4")} />
          </div>
          <div>
            <label style={labelStyle}>Date</label>
            <input type="date" value={f.on_date} max={todayCentral()} onChange={e => set("on_date", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }} />
          </div>
          {isOwner && (
            <div>
              <label style={labelStyle}>Belongs to</label>
              <select value={f.owner} onChange={e => set("owner", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }}>
                {(roster || []).map(t => <option key={t.id} value={t.id}>{t.first_name}</option>)}
                {!(roster || []).some(t => t.id === f.owner) && f.owner
                  ? <option value={f.owner}>{row.owner_name || "former teammate"}</option> : null}
              </select>
            </div>
          )}
          {kind === "appointment" && (
            <div>
              <label style={labelStyle}>About</label>
              <select value={f.appt_line} onChange={e => setF(d => ({ ...d, appt_line: e.target.value, appt_type: "" }))} style={{ ...smallInput, width: "100%", padding: "9px 10px" }}>
                <option value="">Pick one</option>
                {PRODUCTS.map(p => <option key={p.key} value={p.key}>{p.label}</option>)}
              </select>
            </div>
          )}
          {kind === "appointment" && ((types || {})[f.appt_line] || []).length > 0 && (
            <div>
              <label style={labelStyle}>Type</label>
              <select value={f.appt_type} onChange={e => set("appt_type", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }}>
                <option value="">Pick one</option>
                {((types || {})[f.appt_line] || []).map(t => <option key={t.type_key} value={t.type_key}>{t.label}</option>)}
              </select>
            </div>
          )}
          {kind === "appointment" && (
            <div>
              <label style={labelStyle}>Handed to</label>
              <select value={f.escalated_to} onChange={e => set("escalated_to", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }}>
                <option value="">I am keeping it</option>
                {(roster || []).filter(t => t.id !== row.team_member_id).map(t => <option key={t.id} value={t.id}>{t.first_name}</option>)}
              </select>
            </div>
          )}
          {kind === "sale" && (
            <div>
              <label style={labelStyle}>Relationship</label>
              <select value={f.relationship} onChange={e => set("relationship", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }}>
                {RELATIONSHIPS.map(r => <option key={r.key} value={r.key}>{r.label}</option>)}
              </select>
            </div>
          )}
          {kind === "sale" && (
            <div>
              <label style={labelStyle}>Marketing source</label>
              <select value={f.marketing_source} onChange={e => set("marketing_source", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }}>
                <option value="">Pick one</option>
                {(sources || []).map(s => <option key={s.source_key} value={s.source_key}>{s.label}</option>)}
              </select>
            </div>
          )}
        </div>

        {kind === "sale" && f.products.map((p, i) => (
          <div key={p.id || i} style={policyRow}>
            <div>
              <label style={labelStyle}>Policy</label>
              <select value={p.product_type || ""} onChange={e => setProd(i, "product_type", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }}>
                {((types || {})[p.line_of_business] || []).map(t => <option key={t.type_key} value={t.type_key}>{t.label}</option>)}
              </select>
            </div>
            <div>
              <label style={labelStyle}>Premium</label>
              <input type="number" min="0" step="0.01" value={p.premium ?? ""} onChange={e => setProd(i, "premium", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }} />
            </div>
            {p.line_of_business === "auto" && (
              <div>
                <label style={labelStyle}>Cars</label>
                <input type="number" min="1" step="1" value={p.vehicle_count ?? 1} onChange={e => setProd(i, "vehicle_count", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }} />
              </div>
            )}
            {p.line_of_business === "auto" && (
              <div>
                <label style={labelStyle}>Auto policy</label>
                <select value={p.added_to_existing ? "added" : "new"}
                        onChange={e => setProd(i, "added_to_existing", e.target.value === "added")}
                        style={{ ...smallInput, width: "100%", padding: "9px 10px" }}>
                  <option value="new">A new policy</option>
                  <option value="added">Added to one they had</option>
                </select>
              </div>
            )}
          </div>
        ))}

        {kind === "sale" && (
          <div>
            <label style={labelStyle}>ECRM opportunity link</label>
            <input value={f.ecrm} onChange={e => set("ecrm", e.target.value)} placeholder="https://…" style={{ ...smallInput, width: "100%", padding: "9px 10px" }} {...noPwManager("eecrm")} />
          </div>
        )}

        <div>
          <label style={labelStyle}>Note</label>
          <input value={f.note} onChange={e => set("note", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }} {...noPwManager("enote")} />
        </div>

        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <button type="button" style={btnPrimary(saving)} disabled={saving} onClick={save}>{saving ? "Saving…" : "Save changes"}</button>
          <button type="button" style={btnGhost} onClick={onClose}>Cancel</button>
        </div>
      </div>
    </Modal>
  );
}

function IssuedTab({ values, sources, types, roster, nameOf, isOwner, isAdmin, myTeamId, refreshKey, onChanged }) {
  return (
    <RecordsPanel
      scope="pending"
      title="Pending"
      blurb="What we have not paid on yet. A new Private Passenger auto issues by itself the day it is submitted; everything else waits until someone confirms it issued with no contingencies."
      values={values} sources={sources} types={types} roster={roster} nameOf={nameOf} isOwner={isOwner}
      isAdmin={isAdmin} myTeamId={myTeamId} refreshKey={refreshKey} onChanged={onChanged}
    />
  );
}


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
  ecrm_opportunity_url: "ECRM link", ecrm_url: "ECRM link", team_member_id: "person",
  saves_voided: "saves voided", chargeback_points: "chargeback",
  is_added_to_existing: "added to a policy they had",
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
const RESTORE_KIND = {
  sales_log: "sale",
  quote_log: "quote",
  retention_activity_log: "activity",
  appointment_log: "appointment",
  cancelation_log: "cancelation",
};

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

// One day at a time, arrows to move. Rows that came from a single click on the
// Log tab collapse to one line. These are the same lines the daily alert and the
// Telegram note carry, because all three read production_changes_for_day. The
// Telegram link lands here: ?tab=changes&day=YYYY-MM-DD
function ChangeDay({ day, setDay }) {
  const [lines, setLines] = useState(null);
  const [err, setErr] = useState("");
  useEffect(() => {
    let alive = true;
    (async () => {
      setErr(""); setLines(null);
      const r = await supabase.rpc("production_changes_for_day", { p_agency_id: AGENCY_ID, p_day: day });
      if (!alive) return;
      if (r.error) { setErr(errText(r.error)); setLines([]); return; }
      setLines(Array.isArray(r.data) ? r.data : []);
    })();
    return () => { alive = false; };
  }, [day]);

  const today = todayCentral();
  const arrow = { ...btnGhost, padding: "6px 12px", fontSize: 15, lineHeight: 1 };
  return (
    <div style={cardStyle}>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center", justifyContent: "space-between", marginBottom: 12 }}>
        <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>
          {day === today ? "Today" : fmtDate(day)}
          {lines && lines.length > 0 ? <span style={{ color: T.slate500, fontWeight: 600, fontSize: 13 }}> &middot; {plural(lines.length, "change")}</span> : null}
        </div>
        <div style={{ display: "flex", gap: 6, alignItems: "center" }}>
          <button style={arrow} onClick={() => setDay(addDays(day, -1))} aria-label="previous day">&lsaquo;</button>
          <input type="date" style={{ ...inputBase, width: "auto", fontSize: 13, padding: "6px 10px" }} value={day} max={today}
            onChange={e => { if (e.target.value) setDay(e.target.value); }} />
          <button style={arrow} disabled={day >= today} onClick={() => setDay(addDays(day, 1))} aria-label="next day">&rsaquo;</button>
        </div>
      </div>
      {err && <Notice kind="error">{err}</Notice>}
      {lines === null ? (
        <div style={{ color: T.slate500, fontSize: 13 }}>Loading&hellip;</div>
      ) : lines.length === 0 ? (
        <div style={{ color: T.slate600, fontSize: 14 }}>Nothing was edited or removed on this day.</div>
      ) : (
        <div style={{ display: "grid", gap: 8 }}>
          {lines.map(l => (
            <div key={l.txid} style={{ fontSize: 13, color: T.slate800, padding: "8px 10px", background: T.slate50, borderRadius: 8 }}>{l.line}</div>
          ))}
        </div>
      )}
    </div>
  );
}

function ChangesTab({ roster, nameOf, values, types, onChanged }) {
  const [day, setDay] = useTabParam("day", "");
  const [view, setView] = useState("day");
  const [days, setDays] = useState(30);
  const [who, setWho] = useState("");
  const [rows, setRows] = useState(null);
  const [err, setErr] = useState("");
  const [busyId, setBusyId] = useState(null);
  const [reload, setReload] = useState(0);
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
  }, [days, who, reload]);

  const selectStyle = { ...inputBase, width: "auto", fontSize: 13, padding: "7px 10px" };
  const verb = { insert: "Added", update: "Changed", delete: "Removed" };

  // Where a record stands right now. Rows come newest first, so the first time
  // a record shows a status is its current one.
  const statusNow = useMemo(() => {
    const m = new Map();
    for (const r of rows || []) {
      const st = (r.new_row || {}).status;
      if (st && !m.has(r.row_id)) m.set(r.row_id, st);
    }
    return m;
  }, [rows]);

  // A change that took a record out, on a record that is still out.
  const removedHere = (r) => !!RESTORE_KIND[r.table_name]
    && (r.new_row || {}).status === "void"
    && (r.old_row || {}).status !== "void"
    && statusNow.get(r.row_id) === "void";

  const restore = async (r) => {
    const kind = RESTORE_KIND[r.table_name];
    if (!window.confirm(`Put this ${kind} back for ${r.subject || "this customer"}? It goes back on the week's points.`)) return;
    setBusyId(r.id);
    const res = await supabase.rpc("rp_restore_record", { p_kind: kind, p_id: r.row_id });
    setBusyId(null);
    if (res.error || !res.data?.ok) { window.alert(errText(res.error || res.data)); return; }
    setReload(n => n + 1);
    if (onChanged) onChanged();
  };

  if (view === "day") {
    return (
      <div style={{ display: "grid", gap: 12 }}>
        <div style={{ display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center", justifyContent: "space-between" }}>
          <div style={{ fontSize: 13, color: T.slate500 }}>Edits and removals, one day at a time.</div>
          <button style={btnGhost} onClick={() => setView("all")}>See every change</button>
        </div>
        <ChangeDay day={day || todayCentral()} setDay={setDay} />
      </div>
    );
  }

  return (
    <div style={{ display: "grid", gap: 12 }}>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center", justifyContent: "space-between" }}>
        <div style={{ fontSize: 13, color: T.slate500 }}>Who changed what, and when. Everything on this module, newest first.</div>
        <div style={{ display: "flex", gap: 8 }}>
          <button style={btnGhost} onClick={() => setView("day")}>Back to one day</button>
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
                <th style={tableTh} />
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
                    <td style={{ ...tableTd, textAlign: "right", whiteSpace: "nowrap" }}>
                      {removedHere(r) && (
                        <button type="button" style={miniBtn} disabled={busyId === r.id} onClick={() => restore(r)}>
                          {busyId === r.id ? "Putting back…" : "Restore"}
                        </button>
                      )}
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
// Score — the week's standings (Peter 2026-09-11). Everyone sees the whole
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

function WeekView({ isAdmin, isOwner, myTeamId, roster, nameOf, values, sources, types, refreshKey, onChanged }) {
  const [weekEnd, setWeekEnd, weekHref] = useTabParam("week", weekEndOf(todayCentral()));
  const [board, setBoard] = useState(null);
  const [open, setOpen] = useState({});      // card -> team_member_id whose items are showing
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState("");

  const unit = (k) => Number(((values || []).find(v => v.activity_key === k) || {}).points || 0);
  const safeWeek = /^\d{4}-\d{2}-\d{2}$/.test(weekEnd || "") ? weekEnd : weekEndOf(todayCentral());
  const weekStart = addDays(safeWeek, -6);

  const load = useCallback(async () => {
    setLoading(true); setErr("");
    try {
      const b = await supabase.rpc("rp_week_scoreboard", { p_week_end: safeWeek });
      if (b.error) throw b.error;
      if (b.data && b.data.ok === false) throw new Error(b.data.error || "Could not load the week.");
      setBoard(b.data || null);
    } catch (e) { setErr(errText(e)); } finally { setLoading(false); }
  }, [safeWeek]);

  useEffect(() => { load(); }, [load, refreshKey]);

  const people = Array.isArray(board?.people) ? board.people : [];
  const team = board?.team || {};
  // Peter 2026-09-14. Weeks through 2026-09-12 show Marketing and Sales only, from
  // what was reported, because the capture module was still being built. The server
  // says which blocks a week is allowed to show; older sessions default to all four.
  const show = board?.show || { marketing: true, sales: true, quotes: true, retention: true };
  const reported = board?.mode === "reported";
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
        <span>{fmtDate(it.on_date)}</span><span>{it.customer || "—"}{it.phone ? <span style={{ color: T.slate400 }}> ·{it.phone}</span> : null}</span>
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
        <span>{fmtDate(it.issued_on)}</span><span>{it.customer || "—"}{it.phone ? <span style={{ color: T.slate400 }}> ·{it.phone}</span> : null}</span>
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
            {reported && <div style={{ fontSize: 12, color: T.slate500 }}>Marketing and Sales only this week, from what was reported at the time.</div>}
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
          subOf={p => `${fmtPts(p.marketing?.qtd_points)} this quarter`}
          renderItems={marketingItems} open={open.m} onToggle={toggle("m")} />
        {show.quotes && <ScoreCard title="HH Quotes" total={Number(team.quotes || 0)} people={people}
          rankOf={p => Number(p.quotes?.count || 0)} valueOf={p => Number(p.quotes?.count || 0)}
          renderItems={quoteItems} open={open.q} onToggle={toggle("q")} />}
        <ScoreCard title="Sales Points" total={fmtPts(team.sales)} note="Counted the week a policy issues." people={people}
          rankOf={p => Number(p.sales?.points || 0)} valueOf={p => fmtPts(p.sales?.points)}
          subOf={p => `${fmtPts(p.sales?.qtd_points)} this quarter`}
          renderItems={salesItems} open={open.s} onToggle={toggle("s")} />
        {show.retention && <ScoreCard title="Retention Points" total={fmtMoney(team.retention_net)} note="Net, after the team missed-call reduction." people={people}
          rankOf={p => Number(p.retention?.net || 0)} valueOf={p => fmtMoney(p.retention?.net)}
          subOf={p => `${fmtMoney(p.retention?.gross)} gross · missed ${fmtPts(p.retention?.missed_pct)}% calls`}
          renderItems={retentionItems} open={open.r} onToggle={toggle("r")} />}
        <ScoreCard title="Conversations" total={teamAvg == null ? "—" : teamAvg.toFixed(2)} note="Conversation score, 1 to 3. Pivots are tracked, not paid." people={people}
          rankOf={p => Number(p.conversations?.avg || 0)} valueOf={p => p.conversations?.avg == null ? "—" : Number(p.conversations.avg).toFixed(2)}
          subOf={p => `${plural(p.conversations?.scorecards || 0, "scored conversation")} · ${plural(p.conversations?.pivots || 0, "pivot")}`} />
      </div>

      {/* This week — same table as Pending, one toggle away (Peter 2026-09-14). */}
      {!reported && (
        <RecordsPanel
          scope="week"
          weekEnd={safeWeek}
          title="This week"
          blurb="Everything logged in this week. Same format as Pending."
          values={values} sources={sources} types={types} roster={roster} nameOf={nameOf} isOwner={isOwner}
          isAdmin={isAdmin} myTeamId={myTeamId} refreshKey={refreshKey} onChanged={onChanged || load}
        />
      )}
    </div>
  );
}

// =====================================================================
// Checklist tab — the daily team list and the weekly wrap-up on one
// screen (Peter 2026-09-12). Ticks write to daily_checklist_ticks through
// daily_checklist_tick; the wrap-up writes straight into the CPR record
// (weekly_cpr_team_detail) through my_wrapup_save, in the same six-part
// shape the wrap-up email parser used to store, so the CPR reads it
// unchanged. Replaces the Daily Wrap-up page and the wrap-up email.
//
// Three things Peter set on 2026-09-12:
//  * The wrap-up is not open all week. It opens on its own on the last
//    workday of the CPR week (Friday, or the last workday before a
//    closure) and stays open through the weekend. Every other day it is
//    one collapsed line with a link to open it early. No checkbox gates
//    it: a trigger you have to remember is worse than a cue that shows
//    up by itself (Gollwitzer 1999 on cue-bound intentions), and the
//    team list grows a self-ticking "Weekly wrap-up" row on that day so
//    the progress is visible without adding a step.
//  * Code Reds and Code Yellows are raised here any day, stored in
//    code_flags, and rolled into the CPR week automatically. No more
//    Code Red emails.
//  * Every item carries the explanation that used to live on the Daily
//    Wrap-up processes page, behind the ⓘ on the right of the row.
// =====================================================================

// Sections are lines starting "1. " .. "6. ", taken in ascending order
// only, so an answer that happens to begin with a number is left alone.
function splitWrapup(text) {
  const out = ["", "", "", "", "", ""];
  if (!text || !String(text).trim()) return out;
  const buf = [[], [], [], [], [], []];
  let cur = -1;
  for (const ln of String(text).split("\n")) {
    const m = ln.match(/^(\d)\.\s+\S/);
    if (m && Number(m[1]) === cur + 2) { cur = Number(m[1]) - 1; continue; }
    if (cur >= 0) buf[cur].push(ln);
  }
  for (let i = 0; i < 6; i++) out[i] = buf[i].join("\n").trim();
  return out;
}

// The help panel renders manual content, so it uses the manual renderer and the
// manual stylesheet — that is what makes a table in a shared fragment look like
// a table. The item's own words come first, then the fragment underneath it.
function HelpPanel({ item }) {
  const [excerpt, setExcerpt] = useState(null);
  useEffect(() => {
    if (!item.help_excerpt_id) return undefined;
    let alive = true;
    supabase.from("manuals").select("content").eq("id", item.help_excerpt_id).maybeSingle()
      .then(r => { if (alive) setExcerpt(r?.data?.content || ""); });
    return () => { alive = false; };
  }, [item.help_excerpt_id]);
  const body = [item.help_text, excerpt].filter(p => (p || "").trim()).join("\n\n");
  const waiting = !!item.help_excerpt_id && excerpt === null;
  const box = { margin: "2px 0 10px 26px", padding: "10px 12px", background: T.slate50, borderRadius: 8, fontSize: 12.5, color: T.slate700, lineHeight: 1.6 };
  if (!body) {
    return <div style={box}>{waiting ? "Loading…" : <span style={{ color: T.slate500 }}>No extra detail on this one.</span>}</div>;
  }
  return (
    <>
      <ManualBodyStyles />
      <div className="newtworks-handbook-body" style={box} dangerouslySetInnerHTML={{ __html: mdToHtml(body) }} />
    </>
  );
}

// One checklist row, used by the team list AND the personal list, so the row
// only ever has one shape to change. Owner-only controls (move up, move down,
// edit) appear on the same row while the list is in edit mode.
const checklistRowBtn = {
  flexShrink: 0, width: 22, height: 20, lineHeight: "18px", textAlign: "center", padding: 0,
  borderRadius: 6, cursor: "pointer", fontFamily: "inherit", fontSize: 12, fontWeight: 700,
  boxSizing: "border-box", border: `1px solid ${T.slate300}`, background: T.white, color: T.slate600,
};

function ChecklistRow({ item, checked, byLabel, busy, onToggle, openHelp, setOpenHelp, editMode, onEdit, onMove, children }) {
  const open = openHelp === item.id;
  return (
    <div>
      <div style={{ display: "flex", gap: 10, alignItems: "flex-start", padding: "8px 2px", borderBottom: open || children ? "none" : `1px solid ${T.slate100}` }}>
        <input
          type="checkbox"
          id={`chk_${item.id}`}
          checked={!!checked}
          onChange={() => onToggle(item, !checked)}
          disabled={busy}
          style={{ marginTop: 2, width: 16, height: 16, flexShrink: 0, accentColor: T.blue, boxSizing: "border-box", cursor: busy ? "wait" : "pointer" }}
        />
        <label htmlFor={`chk_${item.id}`} style={{ flex: 1, fontSize: 13, lineHeight: 1.4, cursor: busy ? "wait" : "pointer", color: checked ? T.slate500 : T.slate800 }}>{item.title}</label>
        {item.link_url && (
          <a href={item.link_url} target="_blank" rel="noopener noreferrer" title="Open the link for this item"
             style={{ flexShrink: 0, fontSize: 11, fontWeight: 700, color: T.blue, textDecoration: "none", marginTop: 1 }}>open ↗</a>
        )}
        {byLabel && <span style={{ fontSize: 11, color: T.slate400, textAlign: "right", whiteSpace: editMode ? "nowrap" : "normal", flexShrink: 0 }}>{byLabel}</span>}
        {editMode && (
          <>
            <button type="button" title="Move up" aria-label="Move up" onClick={() => onMove(item, "up")} style={checklistRowBtn}>↑</button>
            <button type="button" title="Move down" aria-label="Move down" onClick={() => onMove(item, "down")} style={checklistRowBtn}>↓</button>
            <button type="button" title="Edit this item" aria-label="Edit this item" onClick={() => onEdit(item)} style={{ ...checklistRowBtn, borderColor: T.blue, color: T.blue }}>✎</button>
          </>
        )}
        <button type="button" title="What this means" aria-label="What this means"
          onClick={() => setOpenHelp(h => (h === item.id ? null : item.id))}
          style={{ flexShrink: 0, width: 18, height: 18, lineHeight: "16px", textAlign: "center", padding: 0, borderRadius: 999, cursor: "pointer", fontFamily: "inherit", fontSize: 11, fontWeight: 700, boxSizing: "border-box", border: `1px solid ${open ? T.blue : T.slate300}`, background: open ? T.blueLt : T.white, color: open ? T.blue : T.slate500 }}>i</button>
      </div>
      {children}
      {open && !children && <HelpPanel item={item} />}
    </div>
  );
}

// The owner's editor for one item: its title, its link, and its explanation,
// each edited on its own. The character count is there because the morning
// kickoff prints the first 30 characters of the title and nothing more.
function ChecklistEditor({ draft, onChange, onSave, onCancel, saving, err }) {
  const title = draft.title || "";
  return (
    <div style={{ margin: "2px 0 12px 26px", padding: 12, background: T.slate50, borderRadius: 8, display: "grid", gap: 10 }}>
      <div>
        <label style={labelStyle}>Title</label>
        <input value={title} maxLength={80} onChange={e => onChange({ ...draft, title: e.target.value })}
               style={{ ...inputBase, fontSize: 13, padding: "8px 10px" }} />
        <div style={{ fontSize: 11, marginTop: 4, color: title.length > 30 ? T.amber : T.slate500 }}>
          {title.length} characters{title.length > 30 ? " · the kickoff will cut this to the first 30" : " · fits the kickoff on one line"}
        </div>
      </div>
      <div>
        <label style={labelStyle}>Link <span style={hintStyle}>optional</span></label>
        <input value={draft.link_url || ""} placeholder="https://" onChange={e => onChange({ ...draft, link_url: e.target.value })}
               style={{ ...inputBase, fontSize: 13, padding: "8px 10px" }} />
      </div>
      <div>
        <label style={labelStyle}>Explanation <span style={hintStyle}>what shows behind the i</span></label>
        <textarea rows={8} value={draft.help_text || ""} onChange={e => onChange({ ...draft, help_text: e.target.value })}
                  style={{ ...inputBase, fontSize: 13, padding: "8px 10px", lineHeight: 1.5, resize: "vertical" }} />
      </div>
      {err && <div style={{ fontSize: 12, color: T.red }}>{err}</div>}
      <div style={{ display: "flex", gap: 10, alignItems: "center" }}>
        <button type="button" onClick={onSave} disabled={saving} style={btnPrimary(saving)}>{saving ? "Saving…" : "Save"}</button>
        <button type="button" onClick={onCancel} style={btnGhost}>Cancel</button>
      </div>
    </div>
  );
}

function ChecklistTab() {
  const _vp = useViewport();
  const [state, setState] = useState(null);
  const [openHelp, setOpenHelp] = useState(null);
  const [wrap, setWrap] = useState(null);
  const [parts, setParts] = useState(["", "", "", "", "", ""]);
  const [inbox, setInbox] = useState(false);
  const [wrapOpen, setWrapOpen] = useState(false);
  const [flags, setFlags] = useState([]);
  const [flagDraft, setFlagDraft] = useState(null);   // {severity, note, correction}
  const [busy, setBusy] = useState(false);
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState("");
  const [ok, setOk] = useState("");
  const [tickKey, setTickKey] = useState(0);
  const [flagKey, setFlagKey] = useState(0);
  // Editing the list itself is the owner's alone. The server says so too
  // (checklist_require_owner), so hiding the controls is not the only guard.
  const [editMode, setEditMode] = useState(false);
  const [editing, setEditing] = useState(null);    // {id, title, link_url, help_text}
  const [itemSaving, setItemSaving] = useState(false);
  const [itemErr, setItemErr] = useState("");

  useEffect(() => {
    let alive = true;
    supabase.rpc("daily_checklist_state", { p_date: null })
      .then(r => { if (alive) setState(r?.data || null); });
    return () => { alive = false; };
  }, [tickKey]);

  useEffect(() => {
    let alive = true;
    supabase.rpc("code_flags_mine", { p_week_ending: null })
      .then(r => { if (alive) setFlags(Array.isArray(r?.data) ? r.data : []); });
    return () => { alive = false; };
  }, [flagKey]);

  // Loaded once. Never reload under the user's typing.
  useEffect(() => {
    let alive = true;
    supabase.rpc("my_wrapup_get", { p_week_ending: null }).then(r => {
      if (!alive || !r?.data) return;
      const d = r.data;
      setWrap(d);
      setParts(splitWrapup(d.wrapup_text));
      setInbox(!!d.inbox_done);
    });
    return () => { alive = false; };
  }, []);

  const toggle = async (item, on) => {
    if (!state?.date || busy) return;
    setBusy(true); setErr("");
    const { error } = await supabase.rpc("daily_checklist_tick", {
      p_item_id: item.id, p_date: state.date, p_on: on,
    });
    setBusy(false);
    if (error) { setErr(error.message || "Could not save that tick."); return; }
    setTickKey(k => k + 1);
  };

  const startEdit = (item) => {
    setItemErr("");
    setOpenHelp(null);
    setEditing({ id: item.id, title: item.title || "", link_url: item.link_url || "", help_text: item.help_text || "" });
  };

  const saveItem = async () => {
    if (!editing) return;
    if (!editing.title.trim()) { setItemErr("The title cannot be empty."); return; }
    setItemSaving(true); setItemErr("");
    const { error } = await supabase.rpc("checklist_item_save", {
      p_id: editing.id,
      p_title: editing.title.trim(),
      p_help_text: editing.help_text || "",
      p_link_url: editing.link_url || "",
    });
    setItemSaving(false);
    if (error) { setItemErr(error.message || "Could not save that item."); return; }
    setEditing(null);
    setTickKey(k => k + 1);
  };

  const moveItem = async (item, direction) => {
    setItemErr("");
    const { error } = await supabase.rpc("checklist_item_move", { p_id: item.id, p_direction: direction });
    if (error) { setItemErr(error.message || "Could not move that item."); return; }
    setTickKey(k => k + 1);
  };

  const save = async () => {
    setSaving(true); setErr(""); setOk("");
    const { data, error } = await supabase.rpc("my_wrapup_save", {
      p_parts: parts, p_inbox_done: inbox, p_code_reds: null, p_code_yellows: null, p_week_ending: null,
    });
    setSaving(false);
    if (error) { setErr(error.message || "Could not save the wrap-up."); return; }
    setOk(data?.wrapup_done ? "Saved — all six answered." : "Saved. Some answers are still blank.");
    setWrap(w => (w ? { ...w, wrapup_done: !!data?.wrapup_done } : w));
  };

  const addFlag = async () => {
    if (!flagDraft?.note?.trim()) { setErr("Say what happened."); return; }
    setBusy(true); setErr("");
    const { error } = await supabase.rpc("code_flag_add", {
      p_severity: flagDraft.severity, p_note: flagDraft.note.trim(),
      p_correction: (flagDraft.correction || "").trim() || null, p_date: null,
    });
    setBusy(false);
    if (error) { setErr(error.message || "Could not save that."); return; }
    setFlagDraft(null);
    setFlagKey(k => k + 1);
  };

  const dropFlag = async (id) => {
    const { error } = await supabase.rpc("code_flag_delete", { p_id: id });
    if (error) { setErr(error.message); return; }
    setFlagKey(k => k + 1);
  };

  const canEdit = !!state?.can_edit;
  const items = Array.isArray(state?.items) ? state.items : [];
  const cleared = items.filter(i => i.ticked_at).length;
  const personal = Array.isArray(state?.personal) ? state.personal : [];
  const prompts = Array.isArray(wrap?.prompts) ? wrap.prompts : [];
  const answered = parts.filter(p => (p || "").trim()).length;
  // The cue: the wrap-up opens itself on the last workday of the week and
  // stays open over the weekend — and early for anyone already off for the
  // rest of the week, since their last workday is today. Any other day it is
  // one line they can open themselves.
  const wrapCue = !!state?.is_last_workday || !!wrap?.wrap_cue;
  const showWrap = wrapCue || wrapOpen;
  const reds = flags.filter(f => f.severity === "red");
  const yellows = flags.filter(f => f.severity === "yellow");

  return (
    <div style={{ display: "grid", gridTemplateColumns: _vp.isPhone ? "1fr" : "repeat(auto-fit, minmax(340px, 1fr))", gap: 16, alignItems: "start" }}>

      {/* ── Daily team list ───────────────────────────────── */}
      <div style={cardStyle}>
        <div style={{ display: "flex", flexWrap: "wrap", gap: 8, alignItems: "baseline", justifyContent: "space-between" }}>
          <div>
            <div style={{ fontSize: 15, fontWeight: 800, color: T.slate900 }}>Team list</div>
            <div style={{ fontSize: 12, color: T.slate500 }}>
              {state?.label || "Loading"}{state?.leader ? ` · ${state.leader} leads this week` : ""}
            </div>
          </div>
          <div style={{ display: "flex", gap: 10, alignItems: "baseline", flexShrink: 0 }}>
            <span style={{ fontSize: 12, fontWeight: 700, color: cleared === items.length && items.length ? T.green : T.slate600 }}>
              {cleared} of {items.length} cleared
            </span>
            {canEdit && (
              <button type="button" onClick={() => { setEditMode(v => !v); setEditing(null); setItemErr(""); }} style={linkBtn}>
                {editMode ? "Done editing" : "Edit list"}
              </button>
            )}
          </div>
        </div>

        {Number(state?.at_risk_count || 0) > 0 && (
          <div style={{ marginTop: 8, fontSize: 12, color: T.red, fontWeight: 600 }}>
            This week at risk: {state.at_risk_count} item{Number(state.at_risk_count) === 1 ? "" : "s"}
          </div>
        )}

        <div style={{ marginTop: 12 }}>
          {items.length === 0
            ? <div style={{ fontSize: 13, color: T.slate500 }}>No items for this day.</div>
            : items.map(it => (
                <ChecklistRow
                  key={it.id}
                  item={it}
                  checked={!!it.ticked_at}
                  byLabel={it.ticked_at ? it.ticked_by : null}
                  busy={busy}
                  onToggle={toggle}
                  openHelp={openHelp}
                  setOpenHelp={setOpenHelp}
                  editMode={editMode}
                  onEdit={startEdit}
                  onMove={moveItem}
                >
                  {editing?.id === it.id && (
                    <ChecklistEditor draft={editing} onChange={setEditing} onSave={saveItem}
                                     onCancel={() => { setEditing(null); setItemErr(""); }}
                                     saving={itemSaving} err={itemErr} />
                  )}
                </ChecklistRow>
              ))}
        </div>

        {personal.length > 0 && (
          <div style={{ marginTop: 16, paddingTop: 14, borderTop: `1px solid ${T.slate200}` }}>
            <div style={{ fontSize: 13, fontWeight: 700, color: T.slate900 }}>Personal checklist</div>
            <div style={{ fontSize: 11, color: T.slate500, marginBottom: 6 }}>Everyone ticks these for themselves. The whole team can see who has.</div>
            {personal.map(it => (
              <ChecklistRow
                key={it.id}
                item={it}
                checked={!!it.mine}
                byLabel={Array.isArray(it.ticked_by) && it.ticked_by.length > 0 ? it.ticked_by.join(", ") : null}
                busy={busy}
                onToggle={toggle}
                openHelp={openHelp}
                setOpenHelp={setOpenHelp}
                editMode={editMode}
                onEdit={startEdit}
                onMove={moveItem}
              >
                {editing?.id === it.id && (
                  <ChecklistEditor draft={editing} onChange={setEditing} onSave={saveItem}
                                   onCancel={() => { setEditing(null); setItemErr(""); }}
                                   saving={itemSaving} err={itemErr} />
                )}
              </ChecklistRow>
            ))}
          </div>
        )}

        {/* Code Reds / Yellows — any day, no email */}
        <div style={{ marginTop: 16, paddingTop: 14, borderTop: `1px solid ${T.slate200}` }}>
          <div style={{ display: "flex", flexWrap: "wrap", gap: 8, alignItems: "baseline", justifyContent: "space-between" }}>
            <div style={{ fontSize: 13, fontWeight: 700, color: T.slate900 }}>Code Reds & Yellows</div>
            <span style={{ fontSize: 11, color: T.slate500 }}>this week · {reds.length} red, {yellows.length} yellow</span>
          </div>

          {flags.length > 0 && (
            <div style={{ marginTop: 8 }}>
              {flags.map(f => (
                <div key={f.id} style={{ display: "flex", gap: 8, alignItems: "flex-start", padding: "6px 0", borderBottom: `1px solid ${T.slate100}` }}>
                  <span style={{ flexShrink: 0 }}>{f.severity === "red" ? "🔴" : "🟡"}</span>
                  <div style={{ flex: 1, fontSize: 12.5, color: T.slate800, lineHeight: 1.5 }}>
                    {f.note}
                    {f.correction && <div style={{ color: T.slate500 }}>Fix: {f.correction}</div>}
                    <div style={{ color: T.slate400, fontSize: 11 }}>{fmtDate(f.flag_date)}</div>
                  </div>
                  <button type="button" onClick={() => dropFlag(f.id)} style={{ ...btnGhost, color: T.red, flexShrink: 0 }}>Remove</button>
                </div>
              ))}
            </div>
          )}

          {!flagDraft ? (
            <div style={{ display: "flex", gap: 10, marginTop: 10 }}>
              <button type="button" onClick={() => setFlagDraft({ severity: "red", note: "", correction: "" })} style={{ ...linkBtn, color: T.red }}>+ Add a Code Red</button>
              <button type="button" onClick={() => setFlagDraft({ severity: "yellow", note: "", correction: "" })} style={{ ...linkBtn, color: T.amber }}>+ Add a Code Yellow</button>
            </div>
          ) : (
            <div style={{ marginTop: 10, display: "grid", gap: 10, padding: 12, background: T.slate50, borderRadius: 8 }}>
              <div style={chipRow}>
                {["red", "yellow"].map(s => (
                  <span key={s} onClick={() => setFlagDraft(d => ({ ...d, severity: s }))} style={chip(flagDraft.severity === s)}>
                    {s === "red" ? "🔴 Code Red" : "🟡 Code Yellow"}
                  </span>
                ))}
              </div>
              <div>
                <label style={labelStyle}>What happened</label>
                <textarea rows={2} value={flagDraft.note} onChange={e => setFlagDraft(d => ({ ...d, note: e.target.value }))}
                          style={{ ...inputBase, fontSize: 13, padding: "8px 10px", lineHeight: 1.5, resize: "vertical" }} />
              </div>
              <div>
                <label style={labelStyle}>The correction <span style={hintStyle}>optional</span></label>
                <textarea rows={2} value={flagDraft.correction} onChange={e => setFlagDraft(d => ({ ...d, correction: e.target.value }))}
                          style={{ ...inputBase, fontSize: 13, padding: "8px 10px", lineHeight: 1.5, resize: "vertical" }} />
              </div>
              <div style={{ display: "flex", gap: 10, alignItems: "center" }}>
                <button type="button" onClick={addFlag} disabled={busy} style={btnPrimary(busy)}>{busy ? "Saving…" : "Save it"}</button>
                <button type="button" onClick={() => setFlagDraft(null)} style={linkBtn}>Never mind</button>
              </div>
            </div>
          )}
        </div>
      </div>

      {/* ── Weekly wrap-up ────────────────────────────────── */}
      <div style={cardStyle}>
        <div style={{ display: "flex", flexWrap: "wrap", gap: 8, alignItems: "baseline", justifyContent: "space-between" }}>
          <div>
            <div style={{ fontSize: 15, fontWeight: 800, color: T.slate900 }}>Weekly wrap-up</div>
            <div style={{ fontSize: 12, color: T.slate500 }}>
              {wrap?.week_ending ? `Week ending ${fmtDate(wrap.week_ending)}` : "Loading"} · goes straight onto the CPR
            </div>
          </div>
          {showWrap && <span style={{ fontSize: 12, fontWeight: 700, color: answered === 6 ? T.green : T.slate600 }}>{answered} of 6</span>}
        </div>

        {showWrap && wrap?.off_rest_of_week && (
          <div style={{ marginTop: 10, padding: "8px 10px", borderRadius: 8, background: T.blueLt, color: T.blue, fontSize: 12, lineHeight: 1.5 }}>
            You're off the rest of the week, so this is your last workday. Wrap up before you go.
          </div>
        )}

        {!showWrap && (
          <div style={{ marginTop: 12, fontSize: 13, color: T.slate600, lineHeight: 1.6 }}>
            {answered === 6
              ? <span style={{ color: T.green, fontWeight: 600 }}>Done for this week.</span>
              : <>Opens on your last workday of the week. </>}
            {" "}
            <button type="button" onClick={() => setWrapOpen(true)} style={linkBtn}>{answered > 0 ? "Open it" : "Start it early"}</button>
          </div>
        )}

        {showWrap && wrap && wrap.ok === false && (
          <div style={{ marginTop: 12, fontSize: 13, color: T.slate600 }}>This login is not matched to a teammate, so there is no wrap-up to write.</div>
        )}
        {showWrap && wrap?.ok && !wrap.report_id && (
          <div style={{ marginTop: 12, fontSize: 13, color: T.slate600 }}>This week's CPR is not open yet. The wrap-up opens with it.</div>
        )}

        {showWrap && wrap?.ok && wrap.report_id && (
          <div style={{ marginTop: 12, display: "grid", gap: 12 }}>
            {prompts.map((p, i) => (
              <div key={p.n}>
                <label style={labelStyle}>{p.n}. {p.title} <span style={hintStyle}>{p.hint}</span></label>
                <textarea
                  rows={2}
                  value={parts[i] || ""}
                  onChange={e => setParts(v => { const n = [...v]; n[i] = e.target.value; return n; })}
                  style={{ ...inputBase, fontSize: 13, padding: "8px 10px", lineHeight: 1.5, resize: "vertical" }}
                />
              </div>
            ))}

            <label style={{ display: "flex", gap: 10, alignItems: "center", cursor: "pointer" }}>
              <input type="checkbox" checked={inbox} onChange={e => setInbox(e.target.checked)}
                     style={{ width: 16, height: 16, accentColor: T.blue, boxSizing: "border-box" }} />
              <span style={{ fontSize: 13, color: T.slate800 }}>My inbox is cleared</span>
            </label>

            <div style={{ display: "flex", flexWrap: "wrap", gap: 12, alignItems: "center" }}>
              <button type="button" onClick={save} disabled={saving} style={btnPrimary(saving)}>
                {saving ? "Saving…" : "Save wrap-up"}
              </button>
              {ok && <span style={{ fontSize: 12, color: T.green, fontWeight: 600 }}>{ok}</span>}
            </div>
          </div>
        )}

        {err && <div style={{ marginTop: 10, fontSize: 12, color: T.red, fontWeight: 600 }}>{err}</div>}
      </div>
    </div>
  );
}

// =====================================================================
// Log tab — opens with "Canceling something?" (Peter 2026-09-12). The
// Canceled tab is gone: No keeps today's entry page, Yes drops the
// cancelation search in its place, same code as before, no popup.
// =====================================================================
function LogTab({ values, sources, types, isOwner, isAdmin, myTeamId, roster, nameOf, onLogged, refreshKey }) {
  const [canceling, setCanceling] = useState(false);
  return (
    <div style={{ display: "grid", gap: 16 }}>
      <div style={{ ...cardStyle, padding: "12px 16px", display: "flex", flexWrap: "wrap", gap: 12, alignItems: "center" }}>
        <span style={{ fontSize: 13, fontWeight: 700, color: T.slate900 }}>Canceling something?</span>
        <div style={chipRow}>
          <span onClick={() => setCanceling(false)} style={chip(!canceling)}>No</span>
          <span onClick={() => setCanceling(true)} style={chip(canceling)}>Yes</span>
        </div>
      </div>
      {/* Peter 2026-09-15: canceling still gets the whole standard log, because the same
          visit often has a review or other activity to record. Saying Yes only turns on the
          Canceled status and the one-tap list of policies already on file. */}
      <EntryPage values={values} sources={sources} types={types} isOwner={isOwner} roster={roster}
        onLogged={onLogged} refreshKey={refreshKey} allowCancel={canceling} />
    </div>
  );
}

// =====================================================================
// History — every record, with Edit and Delete (Peter 2026-09-15). Its own
// tab now; it used to sit under the entry form on Log. Editing takes over
// the tab: one record, one form, nothing else to trip over.
// =====================================================================
function HistoryTab({ values, sources, types, isOwner, isAdmin, myTeamId, roster, nameOf, onLogged, refreshKey }) {
  const [editing, setEditing] = useState(null);
  const [flash, setFlash] = useState("");
  const [listKey, setListKey] = useState(0);
  const closeEdit = (msg) => { setEditing(null); setFlash(msg || ""); setListKey(k => k + 1); };
  const openEdit = (target) => {
    setFlash(""); setEditing(target);
    if (typeof window !== "undefined") window.scrollTo({ top: 0, behavior: "smooth" });
  };
  if (editing) {
    return (
      <div style={{ display: "grid", gap: 16 }}>
        <EntryPage values={values} sources={sources} types={types} isOwner={isOwner} roster={roster}
          onLogged={onLogged} refreshKey={refreshKey} allowCancel editing={editing} onCloseEdit={closeEdit} />
      </div>
    );
  }
  return (
    <div style={{ display: "grid", gap: 16 }}>
      <RecentEntries isAdmin={isAdmin} roster={roster} refreshKey={refreshKey + listKey} onEdit={openEdit} flash={flash} />
    </div>
  );
}

// =====================================================================
// Recent entries — what was logged, with Edit and Delete (Peter 2026-09-14).
// rp_recent_entries decides per row whether this person may change it, so a
// button only appears where the server would allow the change anyway.
// Typing in the search box reaches all the way back, which is how the
// historical load gets edited: editing one moves it into the production log.
// =====================================================================
const KIND_LABEL = { sale: "Sale", quote: "Quote", cancelation: "Cancelation", activity: "Activity", scorecard: "Conversation score" };
const KIND_COLOR = { sale: T.green, quote: T.blue, cancelation: T.red, activity: T.purple, scorecard: T.teal };

const ENTRY_KIND_FILTERS = [
  { key: "", label: "Everything" },
  { key: "sale", label: "Sales" },
  { key: "quote", label: "Quotes" },
  { key: "cancelation", label: "Cancelations" },
  { key: "activity", label: "Activities" },
  { key: "scorecard", label: "Conversation scores" },
];

function RecentEntries({ isAdmin, roster, refreshKey, onEdit, flash }) {
  const [rows, setRows] = useState(null);
  const [who, setWho] = useState("");
  const [q, setQ] = useState("");
  const [term, setTerm] = useState("");
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const [recKind, setRecKind] = useState("");
  const [err, setErr] = useState("");
  const [busyId, setBusyId] = useState(null);

  useEffect(() => { const t = setTimeout(() => setTerm(q.trim()), 300); return () => clearTimeout(t); }, [q]);

  useEffect(() => {
    let alive = true;
    (async () => {
      setErr("");
      const r = await supabase.rpc("rp_recent_entries", {
        p_days: 14, p_team_member_id: who || null, p_limit: 200, p_search: term || null,
        p_from: from || null, p_to: to || null, p_kind: recKind || null,
      });
      if (!alive) return;
      if (r.error) { setErr(errText(r.error)); setRows([]); return; }
      setRows(Array.isArray(r.data) ? r.data : []);
    })();
    return () => { alive = false; };
  }, [who, term, from, to, recKind, refreshKey]);

  const remove = async (row) => {
    const what = (KIND_LABEL[row.kind] || row.kind).toLowerCase();
    if (!window.confirm(`Delete this ${what} for ${row.customer_label || "this customer"}? It stops counting straight away.`)) return;
    setBusyId(row.id); setErr("");
    try {
      const { data, error } = await supabase.rpc("rp_delete_record", { p_kind: row.kind, p_id: row.id, p_reason: null });
      if (error) { setErr(errText(error)); return; }
      if (data && data.ok === false) { setErr(errText(data)); return; }
      setRows(list => (list || []).filter(x => !(x.id === row.id && x.kind === row.kind)));
    } catch (e) { setErr(errText(e)); } finally { setBusyId(null); }
  };

  const selectStyle = { ...inputBase, width: "auto", fontSize: 13, padding: "7px 10px" };
  return (
    <div style={cardStyle}>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center", justifyContent: "space-between", marginBottom: 12 }}>
        <div>
          <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>History</div>
          <div style={{ fontSize: 13, color: T.slate500 }}>The last two weeks. Search a name, or set a From date, to go further back.</div>
        </div>
        <div style={{ display: "flex", flexWrap: "wrap", gap: 8 }}>
          <select value={recKind} onChange={e => setRecKind(e.target.value)} style={selectStyle}>
            {ENTRY_KIND_FILTERS.map(k => <option key={k.key} value={k.key}>{k.label}</option>)}
          </select>
          <input type="date" value={from} max={to || todayCentral()} title="From"
            onChange={e => setFrom(e.target.value)} style={selectStyle} />
          <input type="date" value={to} min={from || undefined} max={todayCentral()} title="To"
            onChange={e => setTo(e.target.value)} style={selectStyle} />
          {(from || to || recKind) && (
            <button type="button" style={miniBtn} onClick={() => { setFrom(""); setTo(""); setRecKind(""); }}>Clear</button>
          )}
          {isAdmin && (
            <select value={who} onChange={e => setWho(e.target.value)} style={selectStyle}>
              <option value="">Everyone</option>
              {(roster || []).map(t => <option key={t.id} value={t.id}>{t.first_name}</option>)}
            </select>
          )}
          <input style={{ ...selectStyle, width: 190 }} value={q} placeholder="Search a customer"
            onChange={e => setQ(e.target.value)} {...noPwManager("r1")} />
        </div>
      </div>
      {flash && <Notice kind="ok">{flash}</Notice>}
      {err && <Notice kind="error">{err}</Notice>}
      {rows === null ? (
        <div style={{ color: T.slate500, fontSize: 13 }}>Loading…</div>
      ) : rows.length === 0 ? (
        <div style={{ color: T.slate600, fontSize: 14 }}>{term ? `Nothing on file for “${term}”.` : (from || to || recKind) ? "Nothing matches those filters." : "Nothing logged in the last two weeks."}</div>
      ) : (
        <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
          <table style={{ width: "100%", borderCollapse: "collapse" }}>
            <thead>
              <tr>
                <th style={tableTh}>Date</th>
                <th style={tableTh}>What</th>
                <th style={tableTh}>Customer</th>
                {isAdmin && <th style={tableTh}>Who</th>}
                <th style={tableTh}>Details</th>
                <th style={tableTh}></th>
              </tr>
            </thead>
            <tbody>
              {rows.map(r => (
                <tr key={`${r.kind}:${r.id}`}>
                  <td style={{ ...tableTd, whiteSpace: "nowrap" }}>{fmtDate(r.occurred_on)}</td>
                  <td style={{ ...tableTd, whiteSpace: "nowrap" }}>
                    <span style={{ fontWeight: 700, color: KIND_COLOR[r.kind] || T.slate700 }}>{KIND_LABEL[r.kind] || r.kind}</span>
                    {r.entry_source === "historical_backfill" && (
                      <span style={{ marginLeft: 6, padding: "1px 7px", borderRadius: 999, background: T.slate100, color: T.slate600, fontSize: 11, fontWeight: 700 }}>Historical</span>
                    )}
                  </td>
                  <td style={tableTd}>{r.customer_label || "—"}{r.phone_last4 ? <span style={{ color: T.slate400 }}> ·{r.phone_last4}</span> : null}</td>
                  {isAdmin && <td style={{ ...tableTd, whiteSpace: "nowrap" }}>{r.who}</td>}
                  <td style={tableTd}>
                    {r.summary || "—"}
                    {r.amount != null && r.kind !== "scorecard" ? <span style={{ color: T.slate500 }}> · ${fmtPts(r.amount)}</span> : null}
                  </td>
                  <td style={{ ...tableTd, whiteSpace: "nowrap", textAlign: "right" }}>
                    {r.can_change ? (
                      <>
                        <button style={{ ...miniBtn, marginRight: 6 }} disabled={busyId === r.id} onClick={() => onEdit({ kind: r.kind, id: r.id })}>Edit</button>
                        <button style={{ ...miniBtn, color: T.red }} disabled={busyId === r.id} onClick={() => remove(r)}>Delete</button>
                      </>
                    ) : <span style={{ color: T.slate400, fontSize: 12 }}>closed</span>}
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
// Module shell
// =====================================================================
export default function ActivityLog({ userRole, userId }) {
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "12px" : _vp.isTablet ? "16px 18px" : "20px 24px";
  const [tab, setTab, tabHref] = useTabParam("tab", "log", [...TABS, "earnings", "history"]);
  const [values, setValues] = useState([]);
  const [sources, setSources] = useState([]);
  const [types, setTypes] = useState({});
  const [roster, setRoster] = useState([]);
  const [directory, setDirectory] = useState([]);   // everyone who has ever been on the team, so old rows keep a name
  const [myTeamId, setMyTeamId] = useState(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const [head, setHead] = useState(null);   // this week's scoreboard, shown beside the title on every tab (your own row; team when you have none)
  const [commitInfo, setCommitInfo] = useState(null);  // today's commit, shown with the week's points (Peter 2026-09-14)
  const isAdmin = ["owner", "manager"].includes(userRole);
  // Logging on someone else's behalf is the owner's alone. The server enforces
  // it too (rp_resolve_actor), so hiding the picker is not the only thing
  // stopping it. isAdmin still governs seeing the whole team's week.
  const isOwner = userRole === "owner";
  // The only place a team id turns into a name. Every tab uses this one.
  const nameOf = useMemo(() => {
    const m = new Map();
    for (const t of directory) m.set(t.id, t.first_name);
    return (id) => m.get(id) || (id ? "former teammate" : "—");
  }, [directory]);

  useEffect(() => {
    let alive = true;
    (async () => {
      const [v, s, pt, r, me] = await Promise.all([
        supabase.from("retention_point_values").select("activity_key, label, points, category, requires_note, sort_order, description").eq("agency_id", AGENCY_ID).eq("is_active", true).order("sort_order"),
        supabase.from("sales_marketing_sources").select("source_key, label, sort_order").eq("agency_id", AGENCY_ID).eq("is_active", true).order("sort_order"),
        supabase.from("product_types").select("line_of_business, type_key, label, sort_order").eq("agency_id", AGENCY_ID).eq("is_active", true).order("sort_order"),
        supabase.from("team_directory").select("id, first_name, role_category, is_admin_backoffice, is_test_user, archived_at, category, is_active").eq("agency_id", AGENCY_ID).order("first_name"),
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
      const dir = (Array.isArray(r.data) ? r.data : []).filter(t => !t.is_test_user);
      setDirectory(dir);
      // Two different lists on purpose. The roster is who you can pick in a
      // dropdown today. The directory is everyone ever, so a record left behind
      // by someone who has since left still shows their name.
      setRoster(dir.filter(t => t.is_active && !t.archived_at && !t.is_admin_backoffice && t.category === "agency"));
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

  useEffect(() => {
    let alive = true;
    supabase.rpc("kickoff_commits_mine")
      .then(r => { if (alive) setCommitInfo(r?.data && typeof r.data === "object" ? r.data : null); });
    return () => { alive = false; };
  }, [refreshKey, myTeamId]);

  const bump = () => setRefreshKey(k => k + 1);
  // Peter 2026-09-15: the production run of tabs first — what you log, how it
  // scored, what it could earn, what is waiting, what changed, and the whole
  // record behind it. Then a divider, then everything else.
  const tabs = [
    { id: "log", label: "Log" },
    { id: "week", label: "Score" },
    { id: "earnings", label: "Earnings" },  // everyone (Peter 2026-09-04); Retention + Life Specialist curves inside are admin only
    { id: "issued", label: "Pending" },
    ...(isAdmin ? [{ id: "changes", label: "Changes" }] : []),  // who changed what and when (Peter 2026-09-10)
    { id: "history", label: "History" },
    { type: "divider", id: "_dv_rest" },
    { id: "checklist", label: "Checklist" },
    { id: "hours", label: "Hours" },
    { id: "deposits", label: "Deposits" },
    { id: "development", label: "Development" },
  ];

  return (
    <div style={{ padding: _pad, display: "grid", gap: 16 }}>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 12, alignItems: "center", justifyContent: "space-between" }}>
        <div>
          <div style={{ fontSize: 20, fontWeight: 800, color: T.slate900 }}>Dashboard</div>
          <div style={{ fontSize: 13, color: T.slate500 }}>Everything you touch in a day, in one place.</div>
        </div>
        <div style={{ display: "grid", gap: 6, justifyItems: "start" }}>
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
        {commitInfo?.member_id ? (
          <div style={{ fontSize: 12, color: T.slate600, maxWidth: 520 }} title="Your commit for today">
            {commitInfo.today
              ? <>🎯 {commitInfo.today.commit_text}{commitInfo.today.hit === true ? " ✅" : commitInfo.today.hit === false ? " ❌" : ""}</>
              : <span style={{ color: T.slate500 }}>🎯 No commit saved today</span>}
          </div>
        ) : null}
        </div>
      </div>
      <div style={{ display: "flex", gap: 6, overflowX: "auto", whiteSpace: "nowrap", borderBottom: `1px solid ${T.slate200}`, paddingBottom: 6 }}>
        {tabs.map(t => (
          t.type === "divider"
            ? <span key={t.id} aria-hidden="true" style={{ flexShrink: 0, alignSelf: "stretch", width: 1, background: T.slate200, margin: "2px 6px" }} />
            : <TabLink key={t.id} href={tabHref(t.id)} onSelect={() => setTab(t.id)} style={{
                flexShrink: 0, padding: "8px 14px", borderRadius: 8, fontSize: 13, fontWeight: 700, textDecoration: "none",
                background: tab === t.id ? T.blueLt : "transparent", color: tab === t.id ? T.blue : T.slate600,
              }}>{t.label}</TabLink>
        ))}
      </div>

      {tab === "log" && <LogTab values={values} sources={sources} types={types} isOwner={isOwner} isAdmin={isAdmin} myTeamId={myTeamId} roster={roster} nameOf={nameOf} onLogged={bump} refreshKey={refreshKey} />}
      {tab === "checklist" && <ChecklistTab />}
      {tab === "issued" && <IssuedTab values={values} sources={sources} types={types} roster={roster} nameOf={nameOf} isOwner={isOwner} isAdmin={isAdmin} myTeamId={myTeamId} refreshKey={refreshKey} onChanged={bump} />}
      {tab === "week" && <WeekView isAdmin={isAdmin} isOwner={isOwner} myTeamId={myTeamId} roster={roster} nameOf={nameOf} values={values} sources={sources} types={types} refreshKey={refreshKey} onChanged={bump} />}
      {tab === "hours" && <TimeHub embedded userRole={userRole} />}
      {tab === "deposits" && <PFA userRole={userRole} embedded />}
      {tab === "development" && <Development userRole={userRole} userId={userId} embedded />}
      {tab === "earnings" && <EarningPotentialTab isAdmin={isAdmin} />}
      {tab === "changes" && isAdmin && <ChangesTab roster={roster} nameOf={nameOf} values={values} types={types} onChanged={bump} />}
      {tab === "history" && <HistoryTab values={values} sources={sources} types={types} isOwner={isOwner} isAdmin={isAdmin} myTeamId={myTeamId} roster={roster} nameOf={nameOf} onLogged={bump} refreshKey={refreshKey} />}
    </div>
  );
}
