import { useState, useEffect, useMemo, useCallback, useRef } from "react";
import { DayDoneStyles, Confetti, Dancer, useDancers } from "../components/Critters.jsx";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useViewport } from "../lib/hooks.js";
import { useTabParam, TabLink, hrefWithParam } from "../lib/routing.jsx";
import { AccountCtx, CustomerName, parseAcctToken } from "../lib/customerAccount.jsx";
import { ChangeDiffs, changeDiffList, changeEvents, changeTone, changeItemKind, CHANGE_KINDS, ChangeGroups, groupChangesByOwner } from "../lib/changeLog.jsx";
import TimeHub from "./TimeHub.jsx";
import PFA from "./PFA.jsx";
import Development from "./Development.jsx";
import { T } from "../lib/theme.js";
import BackfillTab from "../components/BackfillTab.jsx";
import { mdToHtml, commitOptions } from "../lib/markdown.js";
import { kickoffToday } from "../lib/kickoff.js";
import CommitPicker from "../components/CommitPicker.jsx";
import InfoDot from "../components/InfoDot.jsx";
import { ManualBodyStyles } from "../lib/manualBodyStyles.jsx";
import { checklistBands } from "../lib/checklist.js";
import EarningPotentialTab from "../components/EarningPotentialTab.jsx";
import DeweyOwe from "../components/DeweyOwe.jsx";
import { noPwManager } from "../lib/forms.js";
import { CARD_PARTS, SCORE_MEANING } from "../lib/fitParts.js";
import { makeScriptLibrary, buildCall, stackTables, FIT_PAGE_ID, canSeeLive, liveSourceProblems } from "../lib/liveCall.js";
import { fetchExcerptRows, fetchFaqRows, fetchManualPages } from "../lib/manualSources.js";
import { RELATIONSHIPS, REVIEW_SITES, relationshipLabel, reviewSiteLabel } from "../lib/logChoices.js";
import LiveSourceWarning from "../components/LiveSourceWarning.jsx";

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
//    pills = two rows). Pivot is paid like any other activity (Peter 2026-10-05).
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
// RELATIONSHIPS and REVIEW_SITES are the Log's own choices, in src/lib/logChoices.js.
// Peter 2026-10-03: a policy review names the policy reviewed (line, and type where
// the line has types); a pivot names the line it pivoted to.
const LINE_REQUIRED = { policy_review: "type", pivot: "type" };   // Peter 2026-10-05: a pivot names its product too
// Peter 2026-10-03: service work is for a customer already on the books, so any of
// these sets the relationship to Existing. Not autopay: it can ride on a new sale.
const EXISTING_ONLY = new Set(["pivot", "policy_review", "service_task", "service_task_company",
  "service_task_coi", "cancelation_saved"]);
const TABS = ["live", "log", "checklist", "hours", "deposits", "week", "issued", "development", "changes", "spotcheck", "backfill", "history", "billing"];
// Earnings tab: owner only for now (Peter 2026-10-05), hidden from the team until the raise ladder is settled.
const canSeeEarnings = (role) => role === "owner";
// The ten scorecard parts live in src/lib/fitParts.js (CARD_PARTS), shared with the Live tab.
const GENDERS = [["male", "Male"], ["female", "Female"]];

// ---------- styles ----------
const inputBase = {
  width: "100%", padding: "10px 12px", borderRadius: 8,
  border: `1px solid ${T.slate300}`, background: T.white, color: T.slate900,
  fontSize: 15, outline: "none", boxSizing: "border-box",
};
// Money reads right-aligned so the digits line up column to column.
const moneyInput = { ...inputBase, textAlign: "right" };
// Password managers put their icon in customer boxes; noPwManager (src/lib/forms.js)
// is the one opt-out, spread onto every customer box.
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
// The pill toggle: History's sub-tabs and the Spot-check's To check / Checked and Day / Week switches.
// One look, used by all of them.
// adminOnly = a pill only admins can see. It shows plum instead of cream, so an
// admin can tell at a glance what the team doesn't see (Peter 2026-09-26).
// Text stays at 4.5:1 contrast or better on both (WCAG 2.2, 1.4.3).
const segWrap = { display: "inline-flex", gap: 2, padding: 3, borderRadius: 999, background: T.slate100 };
// The admin-only pills sit at the end of the track in a plum stretch of their own, so the bar behind them
// is their color instead of grey (Peter 2026-09-26).
const segAdminPart = { display: "inline-flex", gap: 2, margin: "-3px -3px -3px 0", padding: 3, borderRadius: "0 999px 999px 0", background: T.purpleLt };
const segTab = (on, adminOnly = false) => ({
  flexShrink: 0, padding: "6px 14px", borderRadius: 999, fontSize: 12, fontWeight: 700, textDecoration: "none",
  background: adminOnly ? (on ? T.purple : T.purpleLt) : (on ? T.white : "transparent"),
  color: adminOnly ? (on ? T.white : T.slate800) : (on ? T.slate900 : T.slate600),
  boxShadow: on ? "0 1px 2px rgba(0,0,0,0.08)" : "none",
});
// A pill row with admin-only pills in it: drops them for everyone else and puts
// them at the end for admins, otherwise in the order written (Peter 2026-09-26).
const adminLast = (list, isAdmin) => [
  ...list.filter(s => !s.adminOnly),
  ...(isAdmin ? list.filter(s => s.adminOnly) : []),
];
const chip = (on) => ({
  padding: "8px 12px", borderRadius: 999, fontSize: 13, fontWeight: 600, cursor: "pointer", userSelect: "none",
  border: `1px solid ${on ? T.blue : T.slate300}`, background: on ? T.blueLt : T.white, color: on ? T.blue : T.slate700,
});
const chipRow = { display: "flex", flexWrap: "wrap", gap: 8 };
// A Non-Owned auto policy covers the driver, not a car, so it never carries a
// car count. Every other auto type does. One place decides, so the form, the
// saver and the edit screens all agree.
const hasCars = (line, type) => line === "auto" && type !== "non_owned";

const gridForm = { display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(180px, 1fr))", gap: 12 };
const policyRow = { display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(150px, 1fr))", gap: 10, padding: 12, background: T.slate50, borderRadius: 8, alignItems: "end" };
const removeBtn = { ...btnGhost, color: T.red, borderColor: T.slate300, alignSelf: "center", whiteSpace: "nowrap" };
const wrapRow = { display: "flex", flexWrap: "wrap", gap: 10, alignItems: "flex-end" };
const linkBtn = { background: "none", border: "none", padding: 0, color: T.blue, fontSize: 13, fontWeight: 600, cursor: "pointer", fontFamily: "inherit" };
const field = (min = 150) => ({ flex: `1 1 ${min}px`, minWidth: 0 });

// A two-or-three-way switch. ONE component: person / organization, gender,
// and inbound / outbound all use it. Do not write this markup out again.
function SegToggle({ value, onChange, options, big = false }) {
  return (
    <div style={{ display: "flex", border: `1px solid ${T.slate200}`, borderRadius: 8, overflow: "hidden", width: "fit-content" }}>
      {options.map(([k, lbl]) => (
        <button key={k} type="button" onClick={() => onChange(k)}
          style={{ padding: big ? "10px 18px" : "9px 12px", border: "none", cursor: "pointer", fontFamily: "inherit", fontSize: big ? 14 : 13,
                   background: value === k ? T.blue : T.white,
                   color: value === k ? T.white : T.slate600,
                   fontWeight: value === k ? 700 : 400 }}>{lbl}</button>
      ))}
    </div>
  );
}
// The person / organization switch, used by the logging form, the appointment
// form, the edit form and the Live tab.
function KindToggle({ value, onChange }) {
  return <SegToggle value={value} onChange={onChange} options={[["person", "Person"], ["org", "Organization"]]} />;
}
// The customer name box, with names already on file suggested under it (two
// letters in, a quarter-second pause, at most eight back). ONE component: the
// entry form and the Live tab's start card both use it.
function CustomerNameBox({ first, initial, isOrg, onChange, onPick, autoFocus = false }) {
  const [suggest, setSuggest] = useState([]);
  const [open, setOpen] = useState(false);   // closes on a pick, on Escape, or on a click away
  const boxRef = useRef(null);
  useEffect(() => {
    const q = String(first || "").trim();
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
    if (!open) return undefined;
    const away = (e) => { if (boxRef.current && !boxRef.current.contains(e.target)) setOpen(false); };
    document.addEventListener("mousedown", away);
    document.addEventListener("touchstart", away);
    return () => { document.removeEventListener("mousedown", away); document.removeEventListener("touchstart", away); };
  }, [open]);
  const f = String(first || "").trim();
  const show = open && suggest.length > 0 && !(suggest.length === 1 && suggest[0].customer_first_name === f && (suggest[0].customer_last_initial || "") === String(initial || "").trim().toUpperCase());
  return (
    <div ref={boxRef} style={{ ...field(isOrg ? 228 : 150), position: "relative" }}>
      <label style={labelStyle}>{isOrg ? "Organization" : "First name"}</label>
      <input {...noPwManager("a1")} style={inputBase} value={first} placeholder={isOrg ? "Premier Online Marketing LLC" : "Anna"} autoFocus={autoFocus}
        onChange={e => { onChange(e.target.value); setOpen(true); }}
        onFocus={() => setOpen(true)}
        onKeyDown={e => { if (e.key === "Escape") { e.stopPropagation(); setOpen(false); } }} />
      {show && (
        <div style={{ position: "absolute", top: "100%", left: 0, right: 0, zIndex: 5, background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 8, boxShadow: "0 6px 16px rgba(0,0,0,0.08)", marginTop: 4, overflow: "hidden" }}>
          {suggest.map(c => (
            <button key={c.customer_label} type="button" onClick={() => { setSuggest([]); setOpen(false); onPick(c); }}
              style={{ display: "block", width: "100%", textAlign: "left", padding: "8px 12px", border: "none", background: "transparent", fontSize: 14, color: T.slate800, cursor: "pointer", fontFamily: "inherit" }}>
              {c.customer_label}{c.phone_last4 ? <span style={{ color: T.slate500 }}> ·{c.phone_last4}</span> : null} <span style={{ color: T.slate400, fontSize: 12 }}>{Number(c.policies_on_file) > 0 ? plural(c.policies_on_file, "policy").replace("policys", "policies") + " on file" : "on file"}{c.last_seen ? ` · ${fmtDate(c.last_seen)}` : ""}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

// Who the customer is: person or organization, name, initial, phone last four,
// and on the Live tab their age and gender. ONE set of fields for the entry
// form and the Live tab's start card. onChange gets just what changed.
function CustomerFields({ kind, first, initial, phone, age, gender, withAgeGender = false, onChange, onPick, autoFocus = false }) {
  const isOrg = kind === "org";
  return (
    <>
      <div style={{ flex: "0 0 auto" }}>
        <label style={labelStyle}>Customer</label>
        <KindToggle value={kind} onChange={k => onChange(k === "org" ? { kind: k, initial: "" } : { kind: k })} />
      </div>
      <CustomerNameBox first={first} initial={initial} isOrg={isOrg} onChange={v => onChange({ first: v })} onPick={onPick} autoFocus={autoFocus} />
      {!isOrg && (
        <div style={{ flex: "0 0 78px" }}>
          <label style={labelStyle}>Initial</label>
          <input style={{ ...inputBase, textAlign: "center" }} value={initial} maxLength={1} onChange={e => onChange({ initial: e.target.value })} placeholder="S" {...noPwManager("a2")} />
        </div>
      )}
      <div style={{ flex: "0 0 126px" }}>
        <label style={labelStyle}>Phone last 4</label>
        <input {...noPwManager("a3")} inputMode="numeric" style={{ ...inputBase, textAlign: "center" }} value={phone} maxLength={4} onChange={e => onChange({ phone: e.target.value.replace(/\D/g, "").slice(0, 4) })} placeholder="4417" />
      </div>
      {withAgeGender && !isOrg && (
        <div style={{ flex: "0 0 74px" }}>
          <label style={labelStyle}>Age</label>
          <input {...noPwManager("a4")} inputMode="numeric" style={{ ...inputBase, textAlign: "center" }} value={age} maxLength={3} onChange={e => onChange({ age: e.target.value.replace(/\D/g, "").slice(0, 3) })} placeholder="34" />
        </div>
      )}
      {withAgeGender && !isOrg && (
        <div style={{ flex: "0 0 auto" }}>
          <label style={labelStyle}>Gender</label>
          <SegToggle value={gender} onChange={g => onChange({ gender: g })} options={GENDERS} />
        </div>
      )}
    </>
  );
}
// The same age rule the database holds (rp_log_entry): a whole number, 15 to 110.
const ageOk = (a) => /^\d{1,3}$/.test(String(a ?? "").trim()) && Number(a) >= 15 && Number(a) <= 110;

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
// A time typed on this page means that time in San Antonio, whatever clock the
// phone is set to. Work out how far Central sits from UTC on that date, then
// apply it, so 10:00 is 10:00 in the office from anywhere.
function centralParts(iso) {
  const d = iso ? new Date(iso) : null;
  if (!d || isNaN(d)) return { date: todayCentral(), time: "10:00" };
  const p = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Chicago", hour12: false,
    year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" })
    .formatToParts(d).reduce((a, x) => (a[x.type] = x.value, a), {});
  return { date: `${p.year}-${p.month}-${p.day}`, time: `${p.hour % 24}`.padStart(2, "0") + `:${p.minute}` };
}
function centralIso(dateStr, timeStr) {
  if (!dateStr || !timeStr) return null;
  const [y, m, d] = dateStr.split("-").map(Number);
  const [hh, mm] = timeStr.split(":").map(Number);
  const guess = Date.UTC(y, m - 1, d, hh, mm);
  const shown = new Date(guess).toLocaleString("en-US", {
    timeZone: "America/Chicago", hour12: false,
    year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" });
  const [dpart, tpart] = shown.split(", ");
  const [mo, da, yr] = dpart.split("/").map(Number);
  const [h2, mi2] = tpart.split(":").map(Number);
  const offset = guess - Date.UTC(yr, mo - 1, da, h2 % 24, mi2);
  return new Date(guess + offset).toISOString();
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
// Weekly points are shown whole and rounded DOWN (Peter 2026-09-16). Quarter-to-date
// and the breakdown lines keep their cents so the detail still adds up.
function fmtWk(n) {
  const x = Number(n);
  return isFinite(x) ? Math.floor(x).toLocaleString() : "0";
}
function errText(e) {
  return e?.message || e?.error || (typeof e === "string" ? e : "Something went wrong.");
}
let _pid = 0;
const newPolicyId = () => `p${++_pid}`;
// Peter 2026-10-04: the stack resets each week, so the Log form shows what the
// next one of each kind pays this week (rp_next_values), not the bare base.
const itemLabel = (v, next) => {
  const pts = Number(next?.[v.activity_key] ?? v.points);
  return pts > 0 ? `${v.label} · ${fmtPts(pts)} pts` : v.label;
};

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
    parts.push(`${n} activity item${n === 1 ? "" : "s"} for ${fmtPts(a.points_total)} points` +
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
// Live tab (Peter 2026-10-04): the end of a call opens this same form with what
// the call recorded already filled in (prefill), asks the customer's age and
// gender (withAgeGender), and wants the conversation scored whenever a FIT
// conversation happened (requireCard). onSaved fires once per successful log.
function EntryPage({ values, sources, types, isOwner, roster, onLogged, refreshKey, allowCancel = false, presetFirst = "", editing = null, onCloseEdit, appointment = null,
  prefill = null, withAgeGender = false, requireCard = false, hidePending = false, heading = "", subheading = "", onSaved }) {
  const today = todayCentral();
  const pf = prefill || {};
  const [first, setFirst] = useState(appointment?.customer_first_name || pf.first || presetFirst || "");
  const statuses = allowCancel ? STATUSES : STATUSES.filter(st => st.key !== "canceled");
  const [dupQuotes, setDupQuotes] = useState([]);   // this week's quotes already on file for this household
  const [onFileAnswer, setOnFileAnswer] = useState({}); // policy id -> "replaces" | "added" | "different" when the household already has that line
  const [initial, setInitial] = useState(appointment?.customer_last_initial || pf.initial || "");
  // Peter 2026-09-20: a customer is a person or an organization. A person is
  // first name plus last initial; an organization is one name, no initial.
  const [custKind, setCustKind] = useState(appointment?.customer_kind || pf.custKind || "person");
  const [phone, setPhone] = useState(appointment?.phone_last4 || pf.phone || "");   // customer phone, last four digits: part of the household key
  const [age, setAge] = useState(pf.age == null ? "" : String(pf.age));      // Live tab only
  const [gender, setGender] = useState(pf.gender || "");                      // Live tab only
  const [date, setDate] = useState(today);
  const [dateOpen, setDateOpen] = useState(false);
  const [logFor, setLogFor] = useState(null);
  // Peter 2026-10-05: licensed team don't log a Pivot. Quoting an existing customer writes it
  // (rp_derive_quote_pivot). The Pivot activity is offered to unlicensed team only.
  const [meId, setMeId] = useState(null);
  useEffect(() => { supabase.rpc("current_team_member_id").then(r => setMeId(r?.data || null)); }, []);
  const loggerRow = (roster || []).find(t => t.id === (logFor || meId));
  const licensed = !!(loggerRow && (loggerRow.license_pc || loggerRow.license_lh));
  const [onFile, setOnFile] = useState([]);        // this customer's active sold policies (rp_sold_on_file)
  const [relationship, setRelationship] = useState(pf.relationship || "");
  const [source, setSource] = useState(pf.source || "");
  const [activities, setActivities] = useState(() => (pf.activities || []).map(a => ({   // [{id, key, line, type, premium, reason}]
    id: newPolicyId(), key: a.key, line: a.line || "", type: a.type || "", premium: "", reason: "", site: a.site || "" })));
  const [sourcedBy, setSourcedBy] = useState("");   // quotes only: who sourced the referral
  const [policies, setPolicies] = useState(() => (pf.policies || []).map(p => ({   // [{id, line, type, status, premium, vehicles, isNewLine}]
    id: newPolicyId(), line: p.line, type: p.type || "", status: p.status || "", premium: "",
    vehicles: p.vehicles || "1", isNewLine: null, addedToExisting: !!p.addedToExisting, insured: "" })));
  const [activePolicy, setActivePolicy] = useState(null);   // id of the policy pill being edited
  const [scores, setScores] = useState(() => ({ ...(pf.scores || {}) }));   // scorecard parts scored on this entry (blank = didn't come up)
  const [ecrm, setEcrm] = useState("");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const [ok, setOk] = useState("");
  const [attempted, setAttempted] = useState(!!prefill); // show what's missing only after a Log tap (at the end of a Live call, right away)
  const [last, setLast] = useState(null);            // {result, first, initial, date} of the entry just logged, for Undo / Log another

  // every Retention Points item, least expensive first
  const items = useMemo(() => (values || []).filter(v => v.category === "logged" && !(licensed && v.activity_key === "pivot"))
    .slice().sort((a, b) => (Number(a.points) - Number(b.points)) || String(a.label).localeCompare(String(b.label))), [values, licensed]);
  const [infoOpen, setInfoOpen] = useState(false);
  const byKey = useMemo(() => Object.fromEntries((values || []).map(v => [v.activity_key, v])), [values]);
  const [nextPts, setNextPts] = useState({});   // activity_key -> what the next one pays this week
  useEffect(() => {
    let alive = true;
    supabase.rpc("rp_next_values", { p_team_member_id: logFor || null, p_on: date || null })
      .then(r => {
        if (!alive) return;
        const m = {};
        for (const row of (Array.isArray(r?.data) ? r.data : [])) m[row.activity_key] = Number(row.next_points);
        setNextPts(m);
      });
    return () => { alive = false; };
  }, [logFor, date, refreshKey]);

  // ---- Edit mode ----------------------------------------------------------
  // Peter 2026-09-14. There is ONE entry form. Editing opens this same form on a
  // record that already exists: rp_entry_for_edit fills it, and Save hands only
  // the keys that record owns to the matching rp_edit_* function.
  const [editRec, setEditRec] = useState(null);
  const isEdit = !!editRec;
  // A pivot a Live call recorded drops out for licensed team: their quote writes it.
  useEffect(() => { if (licensed && !isEdit) setActivities(list => list.filter(a => a.key !== "pivot" || a.orig)); }, [licensed, isEdit]);
  useEffect(() => {
    if (!editing?.id) { setEditRec(null); return undefined; }
    let alive = true;
    (async () => {
      const r = await supabase.rpc("rp_entry_for_edit", { p_kind: editing.kind, p_id: editing.id });
      if (!alive) return;
      if (r.error) { setErr(errText(r.error)); return; }
      const d = r.data || {};
      setEditRec(d);
      setCustKind(d.customer_kind || "person");
      setFirst(d.customer_first || ""); setInitial(d.customer_last_initial || "");
      setPhone(d.phone_last4 || ""); setDate(d.date || today); setDateOpen(true);
      setRelationship(d.relationship || (d.kind === "activity" && EXISTING_ONLY.has(d.activity_key) ? "existing" : "")); setSource(d.marketing_source || "");
      setSourcedBy(d.sourced_by_team_member_id || ""); setEcrm(d.ecrm_url || "");
      setNote(d.note || "");
      setOk(""); setErr(""); setAttempted(false); setLast(null);
      setActivities([]); setPolicies([]); setActivePolicy(null); setScores({});
      setOnFileAnswer({});
      if (d.kind === "sale" || d.kind === "quote") {
        setPolicies((d.products || []).map(x => ({
          id: newPolicyId(), dbId: x.id, line: x.line_of_business, type: x.product_type || "",
          status: d.kind === "sale" ? "sold" : "quoted",
          premium: x.premium == null ? "" : String(x.premium),
          vehicles: x.vehicle_count == null ? "" : String(x.vehicle_count),
          isNewLine: x.is_new_line !== false, addedToExisting: !!x.added_to_existing, autopay: !!x.autopay,
          insured: x.insured_name || "",
          issuedPremium: x.issued_premium == null ? "" : String(x.issued_premium),
          issuedDate: x.issued_date || "",
        })));
      } else if (d.kind === "cancelation") {
        setPolicies([{ id: newPolicyId(), dbId: null, line: d.policy_line, type: d.product_type || "",
          status: "canceled", premium: d.premium == null ? "" : String(d.premium),
          vehicles: d.vehicle_count == null ? "" : String(d.vehicle_count),
          isNewLine: false, addedToExisting: false, autopay: false }]);
      } else if (d.kind === "activity") {
        setActivities([{ id: newPolicyId(), orig: true, key: d.activity_key,
          line: d.save_line || d.policy_line || "", type: d.product_type || "",
          premium: d.premium == null ? "" : String(d.premium), reason: d.save_reason || "",
          site: d.review_platform || "" }]);
      } else if (d.kind === "scorecard") {
        setScores(Object.fromEntries(Object.entries(d.scores || {}).filter(([, v]) => v != null)));
      }
    })();
    return () => { alive = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [editing?.kind, editing?.id]);

  // Which parts of the form belong to the record being edited. Logging shows them all.
  const showActivityBlock = !isEdit || editRec.kind === "activity";
  // Peter 2026-09-26: an activity being edited can gain a quote, or turn into one (a Policy Change that was
  // really a quote). Only Quoted is offered there; take the activity off and the quote takes its place.
  const quoteOnly = isEdit && editRec.kind === "activity";
  const showPolicyBlock   = !isEdit || quoteOnly || editRec.kind === "sale" || editRec.kind === "quote" || editRec.kind === "cancelation";
  const showBottomRow     = !isEdit || editRec.kind !== "scorecard";
  const showCardBlock     = !isEdit || editRec.kind === "scorecard";

  // Name suggestions live in CustomerNameBox; picking one fills the household key.
  const pickCustomer = (c) => { setCustKind(c.customer_kind || "person"); setFirst(c.customer_first_name || ""); setInitial(c.customer_last_initial || ""); if (c.phone_last4) setPhone(c.phone_last4); };
  const onCustomer = (p) => {
    if ("kind" in p) setCustKind(p.kind);
    if ("first" in p) setFirst(p.first);
    if ("initial" in p) setInitial(p.initial);
    if ("phone" in p) setPhone(p.phone);
    if ("age" in p) setAge(p.age);
    if ("gender" in p) setGender(p.gender);
  };
  const phoneOk = /^\d{4}$/.test(phone);
  // One place decides whether the name is complete and what the household is
  // called. The household key is still that name plus the phone last four.
  const isOrg = custKind === "org";
  const nameOk = !!first.trim() && (isOrg || /^[A-Za-z]$/.test(initial.trim()));
  const householdLabel = isOrg ? first.trim() : `${first.trim()} ${initial.trim().toUpperCase()}.`;

  // same household quoted already this week? Logs anyway; the same household counts once for HH quotes.
  useEffect(() => {
    if (!nameOk) { setDupQuotes([]); return undefined; }
    let alive = true;
    const t = setTimeout(async () => {
      let qq = supabase.from("quote_log").select("id, team_member_id, quote_date")
        .eq("agency_id", AGENCY_ID).eq("status", "active").eq("customer_label", householdLabel).eq("week_end_date", weekEndOf(date));
      if (phoneOk) qq = qq.or(`phone_last4.is.null,phone_last4.eq.${phone}`);
      const { data } = await qq;
      if (alive) setDupQuotes(Array.isArray(data) ? data : []);
    }, 300);
    return () => { alive = false; clearTimeout(t); };
  }, [first, initial, custKind, date, phone]);

  // what this customer has on file, once the name is complete
  useEffect(() => {
    const f = first.trim(), i = initial.trim();
    if (!nameOk) { setOnFile([]); return undefined; }
    let alive = true;
    const t = setTimeout(async () => {
      const { data } = await supabase.rpc("rp_sold_on_file2", { p_customer_first: f, p_customer_last_initial: i, p_phone_last4: phoneOk ? phone : null, p_customer_kind: custKind });
      if (alive) setOnFile(Array.isArray(data) ? data : []);
    }, 300);
    return () => { alive = false; clearTimeout(t); };
  }, [first, initial, custKind, phone]);
  // the sold policy on file that a canceled row would be matched to (same line, same type first, most recent, not already canceled)
  const soldMatch = (p) => onFile
    .filter(r => r.line_of_business === p.line && !r.already_canceled && (!date || r.submitted_date <= date) && (!date || r.window_end > date))
    .sort((a, b) => ((b.product_type === p.type) - (a.product_type === p.type)) || (a.submitted_date < b.submitted_date ? 1 : -1))[0] || null;

  const addActivity = (key) => {
    if (!key) return;
    setActivities(list => [...list, { id: newPolicyId(), key, line: "", type: "", premium: "" }]);
    if (EXISTING_ONLY.has(key)) setRelationship(r => r || "existing");
  };
  const editActivity = (id, patch) => setActivities(list => list.map(a => a.id === id ? { ...a, ...patch } : a));
  const dropActivity = (id) => setActivities(list => list.filter(a => a.id !== id));
  const addPolicy = (line) => {
    if (!line) return;
    const id = newPolicyId();
    const only = (types[line] || []).length === 1 ? types[line][0].type_key : "";   // Bank, Variable: one product
    setPolicies(list => [...list, { id, line, type: only, status: quoteOnly ? "quoted" : "", premium: "", vehicles: "1", isNewLine: null, addedToExisting: false, insured: "" }]);
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
  // Peter 2026-09-19: an Online Review has to say where it landed (REVIEW_SITES, src/lib/logChoices.js).
  const needsSite = (key) => !!(values || []).find(v => v.activity_key === key)?.requires_platform;
  const hasSave = activities.some(a => a.key === "cancelation_saved");
  const hasReview = activities.some(a => a.key === "policy_review");
  // One shape per activity, for logging and for anything added while editing.
  const toItem = (a) =>
    a.key === "cancelation_saved" ? { activity_key: a.key, save_line: a.line, product_type: a.type || null, save_reason: (a.reason || "").trim() }
    : a.key === "autopay_enrollment" ? { activity_key: a.key, policy_line: a.line, product_type: a.type || null, premium: a.premium === "" ? null : Number(a.premium) }
    : needsSite(a.key) ? { activity_key: a.key, review_platform: a.site || null }
    : LINE_REQUIRED[a.key] ? { activity_key: a.key, policy_line: a.line || null, product_type: a.type || null }
    : { activity_key: a.key };
  const activityItems = activities.filter(a => byKey[a.key]).map(toItem);
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
  // Peter 2026-09-19: a sale already needed the ECRM link. A cancelation needs
  // one too, and so does any activity marked for it in the point values table
  // (Policy Change, to start with).
  // Peter 2026-10-03: the link is required when the entry is logged. An edit never
  // asks for one the record went without; only what the edit adds can need it, and a
  // sale always carries it. The box still shows on a record that uses one.
  const ecrmKind = (list) => list.some(a => (values || []).some(v => v.activity_key === a.key && v.requires_ecrm));
  const needsEcrm = hasSale || (!isEdit && hasCxl) || ecrmKind(activities.filter(a => !a.orig));
  const showEcrm = needsEcrm || hasCxl || ecrmKind(activities) || !!ecrm.trim();
  // The rules that hold both when something is logged and when it is edited
  // later. Logging and editing each used to carry their own copy of these and
  // drifted apart, so a review could be edited without naming the site.
  const sharedGate = (saleBackfill) => {
    const out = [];
    if (needsEcrm && !ecrm.trim()) out.push(saleBackfill
      ? "Moving this into the production log needs the ECRM opportunity link."
      : "This needs the ECRM opportunity link.");
    if (activities.some(a => needsSite(a.key) && !a.site)) out.push("Say where the review was left: Google, Facebook or Yelp.");
    if (hasSale && !note.trim()) out.push("A sale needs a note on what happened.");
    if (hasCxl && !note.trim()) out.push("A cancelation needs a note on why it canceled.");
    return out;
  };
  const needsCard = requireCard || hasQuote || hasSale || cardChosen > 0;
  const hasAnything = hasActivity || hasQuote || hasSale || hasCxl || hasCard;
  const customerOk = nameOk;
  const isReferral = source === "referral";
  const householdFresh = relationship === "new" || relationship === "winback";
  const needsType = (line) => (types[line] || []).length > 0;
  const isSold = (p) => p.status === "sold" || p.status === "quoted_sold";
  const needsMoney = (p) => isSold(p) || p.status === "canceled";
  const showDate = dateOpen || date !== today;
  // What this household had on file before this entry: not canceled, not the record being edited.
  const onFileBefore = onFile.filter(x => !x.already_canceled && !policies.some(p => p.dbId && p.dbId === x.sale_product_id)
    && (!date || x.submitted_date <= date));
  const hasRecords = onFileBefore.length > 0;
  // Peter 2026-10-05: the same product. Same line and type; a life counts only when it sold in the last
  // 60 days (a new life past that is a new product). Mirrors rp_household_on_file on the server.
  const sameProductOnFile = (p) => onFileBefore
    .filter(x => x.line_of_business === p.line && (p.line === "life"
      ? x.submitted_date >= addDays(date || today, -60)
      : (x.product_type || "") === (p.type || "")))
    .sort((a, b) => (a.submitted_date < b.submitted_date ? 1 : -1))[0] || null;
  // Peter 2026-09-26: a household holds one PLUP and one PAP. A new one replaces the older one of the same
  // type on its own when it is logged (rp_replace_one_per_household), so it is not asked about.
  const onePerHousehold = (p) => !!(types[p.line] || []).find(t => t.type_key === p.type)?.one_per_household;
  const autoReplaced = isEdit ? [] : sold.filter(p => onePerHousehold(p) && sameProductOnFile(p));
  // Peter 2026-10-05: the same fire product already on file (other than PLUP and PAP) is the one thing
  // the team is asked about: does it replace the one on file, or do they keep both.
  const flagged = isEdit ? [] : sold.filter(p => p.line === "fire" && !onePerHousehold(p) && sameProductOnFile(p));
  const replaces = flagged.filter(p => onFileAnswer[p.id] === "replaces");
  const otherHousehold = flagged.some(p => onFileAnswer[p.id] === "different");
  // The same auto product goes in as an added auto, and a life inside 60 days counts as the
  // replacement. Both on their own, no question; the server does the same (rp_log_sale,
  // rp_household_on_file). Said here so the team sees why.
  const autoAdded = isEdit || otherHousehold ? [] : sold.filter(p => p.line === "auto" && !p.addedToExisting && sameProductOnFile(p));
  const lifeRepeat = isEdit || otherHousehold ? [] : sold.filter(p => p.line === "life" && sameProductOnFile(p));
  // Peter 2026-10-05: a New or Winback customer with policies still on file is a mix-up to clear up:
  // the cancelation was never logged, or they are really Existing.
  const mixUp = !isEdit && (relationship === "new" || relationship === "winback") && hasRecords && (hasSale || hasQuote);
  // Multiline is worked out from what is on file. Only an Existing customer we hold no records for
  // is asked, per policy: new for them, or a replacement.
  const askNewLine = (p) => isSold(p) && relationship === "existing" && !(p.line === "auto" && p.addedToExisting)
    && (!hasRecords || otherHousehold);

  // Line, then type where the line has types: the one pair of pickers wherever an
  // activity names a policy (autopay, save, policy review, pivot).
  const lineFields = (a, withType = true) => (
    <>
      <div style={field(130)}>
        <label style={labelStyle}>Line</label>
        <select style={inputBase} value={a.line} onChange={e => editActivity(a.id, { line: e.target.value, type: "" })}>
          <option value="">Pick one</option>
          {PRODUCTS.map(pr => <option key={pr.key} value={pr.key}>{pr.label}</option>)}
        </select>
      </div>
      {withType && needsType(a.line) && (
        <div style={field(150)}>
          <label style={labelStyle}>Type</label>
          <select style={inputBase} value={a.type} onChange={e => editActivity(a.id, { type: e.target.value })}>
            <option value="">Pick one</option>
            {(types[a.line] || []).map(t => <option key={t.type_key} value={t.type_key}>{t.label}</option>)}
          </select>
        </div>
      )}
    </>
  );
  // Peter 2026-10-05: a policy review names the POLICY reviewed, not the line. One "Policy" pick
  // (Home, Renters, Term Life...) sets the line and type together, and the customer's policies
  // on file sit above it as one-tap choices.
  const policyFields = (a, withOnFile = true) => {
    // Peter 2026-10-05: when the household has policies in our logs, the review picks one of
    // those. The full list only opens on "Not on this list".
    const mine = withOnFile ? onFile.filter(r => !r.already_canceled) : [];
    const picked = !lineMissing(a);
    const done = picked
      ? <button type="button" style={{ ...btnGhost, marginBottom: 6 }} onClick={() => editActivity(a.id, { done: true })}>Done</button>
      : null;
    if (mine.length > 0 && !a.other) return (
      <>
        <div style={{ ...chipRow, flex: "1 1 100%" }}>
          {mine.map(r => (
            <span key={r.sale_product_id} style={chip(a.pick === r.sale_product_id)}
                  onClick={() => editActivity(a.id, { line: r.line_of_business, type: r.product_type || "", pick: r.sale_product_id })}>
              {typeLabel(types, r.line_of_business, r.product_type) || PRODUCT_LABEL[r.line_of_business]} · ${fmtPts(r.premium)}
            </span>
          ))}
          <span style={chip(false)} onClick={() => editActivity(a.id, { other: true, line: "", type: "", pick: null })}>Not on this list</span>
        </div>
        {done}
      </>
    );
    return (
      <>
        <div style={field(200)}>
          <label style={labelStyle}>{!withOnFile ? "Product" : "Policy"}</label>
          <select style={inputBase} value={a.line ? `${a.line}|${a.type || ""}` : ""}
                  onChange={e => { const [line, type] = e.target.value.split("|"); editActivity(a.id, { line: line || "", type: type || "", pick: null }); }}>
            <option value="">Pick one</option>
            {PRODUCTS.map(pr => (types[pr.key] || []).length
              ? <optgroup key={pr.key} label={pr.label}>{types[pr.key].map(t => <option key={t.type_key} value={`${pr.key}|${t.type_key}`}>{t.label}</option>)}</optgroup>
              : <option key={pr.key} value={`${pr.key}|`}>{pr.label}</option>)}
          </select>
        </div>
        {done}
      </>
    );
  };
  // Peter 2026-10-03: what a review or pivot has to name.
  const lineMissing = (a) => !!LINE_REQUIRED[a.key] && (!a.line || (LINE_REQUIRED[a.key] === "type" && needsType(a.line) && !a.type));
  // What each activity has to carry. Logging checks every activity in the entry;
  // an edit checks only the ones it adds.
  const activityChecks = (list) => {
    const out = [];
    // The server refuses an activity marked requires_note without a note (a save's
    // reason counts). Say so here, before the Log tap, instead of after it.
    const noteFor = list.filter(a => byKey[a.key]?.requires_note && a.key !== "policy_review"
      && !(a.key === "cancelation_saved" && (a.reason || "").trim()));
    if (noteFor.length && !note.trim()) out.push(`A note on what you did (${[...new Set(noteFor.map(a => byKey[a.key].label))].join(", ")}).`);
    if (list.some(a => a.key === "cancelation_saved" && (!a.line || (needsType(a.line) && !a.type) || !(a.reason || "").trim()))) out.push("Each save needs the policy line, its type, and the reason the customer gave.");
    if (list.some(a => a.key === "policy_review") && !note.trim()) out.push("The policy review needs a note on what you covered.");
    if (list.some(a => a.key === "policy_review" && lineMissing(a))) out.push("Pick the policy reviewed.");
    if (list.some(a => a.key === "pivot" && lineMissing(a))) out.push("The pivot needs the product it pivoted to.");
    if (list.some(a => a.key === "autopay_enrollment" && (!a.line || (needsType(a.line) && !a.type) || a.premium === "" || !(Number(a.premium) >= 0)))) out.push("Each autopay needs the policy line, type, and premium.");
    return out;
  };
  // ---- what still needs fixing, in plain words (mirrors the server rules) ----
  const problems = [];
  if (!customerOk) problems.push(isOrg ? "The organization name." : "Customer first name and last initial.");
  if (!phoneOk) problems.push("Customer phone, last four digits.");
  if (withAgeGender && !isOrg && !ageOk(age)) problems.push("Customer age, 15 to 110.");
  if (withAgeGender && !isOrg && !gender) problems.push("Customer gender.");
  if (!hasAnything) problems.push("Add an activity or a policy, or score the conversation.");
  if (policies.some(p => !p.status)) problems.push("Each policy needs Quoted, Sold, or Canceled.");
  if (policies.some(p => needsType(p.line) && !p.type)) problems.push("Each Auto or Fire policy needs its type.");
  if (policies.some(p => needsMoney(p) && (p.premium === "" || !(Number(p.premium) >= 0)))) problems.push("Each sold or canceled policy needs its premium.");
  if (policies.some(p => needsMoney(p) && hasCars(p.line, p.type) && !(Number(p.vehicles) >= 1))) problems.push("Each sold or canceled auto policy needs its number of cars.");
  if ((hasActivity || hasQuote) && date < addDays(today, -7)) problems.push("Activity and quotes are logged within 7 days. Pick a later date or split the entry.");
  if (hasSale && date < addDays(today, -30)) problems.push("A sale is logged within 30 days of the bind.");
  if (hasCxl && date < addDays(today, -90)) problems.push("A cancelation is logged within 90 days.");
  if (hasSave && date !== today) problems.push("A save is logged the same day it comes in. Set the date to today.");
  activityChecks(activities).forEach(m => problems.push(m));
  if (!relationship) problems.push("Pick the relationship.");
  if ((hasSale || hasQuote) && !source) problems.push("Pick the marketing source.");
  sharedGate(false).forEach(m => problems.push(m));
  if (needsCard && cardChosen < CARD_PARTS.length) problems.push("Score every part of the scorecard. Tap x on a part you did not do.");
  if (flagged.some(p => !onFileAnswer[p.id])) problems.push("Say whether the new policy replaces the one on file, is added to it, or is a different household.");
  if (mixUp) problems.push(`They already have policies on file, so they are not ${relationship === "new" ? "New" : "a Winback"}. Switch to Existing, or log the cancelation of what is on file first.`);
  if (sold.some(p => askNewLine(p) && p.isNewLine == null)) problems.push("Say whether each policy sold is new for them or a replacement.");
  if (hasSale && hasCxl) {
    const soldLines = new Set(sold.map(p => p.line));
    const clash = [...new Set(canceled.filter(p => soldLines.has(p.line)).map(p => p.line))];
    if (clash.length) problems.push(`${clash.map(k => PRODUCT_SHORT[k]).join(", ")} is both sold and canceled in this entry. Log those as two entries.`);
  }
  if (ecrm.trim() && !/^https?:\/\//i.test(ecrm.trim())) problems.push("The ECRM link must start with http.");

  const reset = (keep) => {
    if (!keep) { setCustKind("person"); setFirst(""); setInitial(""); setPhone(""); setAge(""); setGender(""); setDate(today); setDateOpen(false); }
    setRelationship(""); setSource(""); setSourcedBy("");
    setActivities([]);
    setPolicies([]); setActivePolicy(null); setScores({}); setEcrm(""); setNote(""); setOnFileAnswer({});
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
    const who = { customer_first: first.trim(), customer_last_initial: initial.trim(), customer_kind: custKind };
    if (phoneOk) who.phone_last4 = phone;
    const gate = [];
    if (!first.trim()) gate.push(isOrg ? "The organization name." : "First name.");
    if (k !== "scorecard" && !isOrg && !/^[A-Za-z]$/.test(initial.trim())) gate.push("Last initial.");
    if (phone && !phoneOk) gate.push("Customer phone: four digits, or leave it blank.");
    if (!phone && editRec.phone_last4) gate.push("Customer phone, last four digits.");
    if (k === "sale" && sold.length === 0) gate.push("A sale needs at least one sold policy.");
    if (k === "quote" && quoted.length === 0) gate.push("A quote needs at least one quoted policy.");
    if (k === "cancelation" && policies.length !== 1) gate.push("A cancelation is one policy. Log a second one separately.");
    if (k === "sale" && sold.some(p => p.premium === "" || !(Number(p.premium) >= 0))) gate.push("Every sold policy needs a premium.");
    sharedGate(k === "sale" && editRec.entry_source === "historical_backfill").forEach(m => gate.push(m));
    if (k === "sale" && sold.some(p => askNewLine(p) && p.isNewLine == null)) gate.push("Say whether each policy sold is new for them or a replacement.");
    // An activity can gain a quote here, and a quote can take the activity's place.
    const addQuote = k === "activity" && quoted.length > 0;
    // Peter 2026-10-03: only the record's own activity is edited. Anything added here
    // is logged as its own entry, checked the way logging checks it.
    const own = k === "activity" ? activities.find(a => a.orig) : null;
    const extras = k === "activity" ? activities.filter(a => !a.orig && byKey[a.key]) : [];
    if (k === "activity" && !own && extras.length === 0 && !addQuote) gate.push("Nothing left to save. Use Delete to remove the record.");
    if (extras.length) {
      if (!phoneOk) gate.push("Customer phone, last four digits.");
      if (!relationship) gate.push("Pick the relationship.");
      activityChecks(extras).forEach(m => gate.push(m));
    }
    if (addQuote) {
      if (!phoneOk) gate.push("Customer phone, last four digits.");
      if (!relationship) gate.push("Pick the relationship for the quote.");
      if (!source) gate.push("Pick the marketing source for the quote.");
      if (quoted.some(p => needsType(p.line) && !p.type)) gate.push("Each Auto or Fire policy needs its type.");
    }
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
            vehicle_count: hasCars(p.line, p.type) ? Number(p.vehicles) : null,
            added_to_existing: p.line === "auto" && !!p.addedToExisting,
            is_new_line: !!p.isNewLine, autopay: !!p.autopay,
            insured_name: p.line === "life" ? ((p.insured || "").trim() || null) : null,
            issued_premium: p.issuedPremium === "" || p.issuedPremium == null ? null : Number(p.issuedPremium),
            issued_date: p.issuedDate || null })) };
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
          vehicle_count: hasCars(one.line, one.type) && one.vehicles !== "" ? Number(one.vehicles) : null,
          note: note.trim() };
      } else if (k === "activity") {
        if (addQuote || extras.length) {
          // Logged the way the entry page logs them, for the same person, day and household.
          const q = await supabase.rpc("rp_log_entry", { p_payload: {
            customer_first: first.trim(), customer_last_initial: initial.trim(), customer_kind: custKind, phone_last4: phone,
            occurred_on: date, ecrm_url: ecrm.trim() || null, note: note.trim() || null, team_member_id: editRec.team_member_id,
            relationship_type: relationship, marketing_source: source || null,
            sourced_by_team_member_id: addQuote && isReferral && sourcedBy ? sourcedBy : null,
            activity: extras.length ? { items: extras.map(toItem) } : null,
            quote: addQuote ? { items: quoted.map(p => ({ line_of_business: p.line, product_type: p.type || null })) } : null } });
          if (q.error) { setErr(errText(q.error)); return; }
          if (!q.data?.ok) { setErr(errText(q.data)); return; }
        }
        if (!own) {
          const d = await supabase.rpc("rp_delete_record", { p_kind: "activity", p_id: editRec.id, p_reason: addQuote ? "changed to a quote" : "replaced while editing" });
          if (d.error) { setErr(`What you added is logged, but the old activity is still on file: ${errText(d.error)}`); return; }
          onLogged?.();
          onCloseEdit?.(addQuote ? "Saved. The activity is a quote now." : "Saved. The old activity is replaced by what you added.");
          return;
        }
        const a = own;
        fn = "rp_edit_activity";
        const isSave = a.key === "cancelation_saved";
        changes = { ...who, occurred_on: date, activity_key: a.key, note: note.trim(), ecrm_url: ecrm.trim(),
          ...(isSave
            ? { save_line: a.line || "", save_reason: (a.reason || "").trim(), product_type: a.type || "" }
            : { policy_line: a.line || "", product_type: a.type || "",
                premium: a.premium === "" ? null : Number(a.premium) }),
          ...(needsSite(a.key) ? { review_platform: a.site || "" } : {}) };
      } else {
        fn = "rp_edit_scorecard";
        changes = { customer_first_name: first.trim(), ...(phoneOk ? { phone_last4: phone } : {}), scorecard_date: date,
          notes: note.trim(),
          ...Object.fromEntries(CARD_PARTS.map(pt => [pt.key, scores[pt.key] == null ? null : Number(scores[pt.key])])) };
      }
      const { data, error } = await supabase.rpc(fn, { p_id: editRec.id, p_changes: changes });
      if (error) { setErr(errText(error)); return; }
      if (data && data.ok === false) { setErr(errText(data)); return; }
      onLogged?.();
      onCloseEdit?.(data?.moved_from_historical
        ? "Saved. That record left the historical load and sits in the production log now."
        : addQuote ? "Saved. The quote is logged too." : extras.length ? "Saved. What you added is logged as its own entry." : "Saved.");
    } catch (e) { setErr(errText(e)); } finally { setBusy(false); }
  };

  const submit = async () => {
    setErr(""); setOk("");
    setAttempted(true);
    if (busy || problems.length > 0) return;
    setBusy(true);
    // The Live tab's customer age and gender ride on every record this entry writes.
    const ageGender = withAgeGender && !isOrg ? { customer_age: ageOk(age) ? Number(age) : null, customer_gender: gender || null } : {};
    try {
      const row = (p) => ({ line_of_business: p.line, product_type: p.type || null });
      const money = (p) => ({ premium: Number(p.premium), vehicle_count: hasCars(p.line, p.type) ? Number(p.vehicles) : null });
      const matched = (p) => ({ matched_sale_product_id: p.matchedId || null });
      const payload = {
        customer_first: first.trim(), customer_last_initial: initial.trim(), customer_kind: custKind, phone_last4: phone, occurred_on: date,
        ...ageGender,
        ecrm_url: ecrm.trim() || null, note: note.trim() || null, team_member_id: logFor,
        relationship_type: relationship || null,
        marketing_source: source || null,
        sourced_by_team_member_id: hasQuote && isReferral && sourcedBy ? sourcedBy : null,
        activity: hasActivity ? { items: activityItems } : null,
        quote: hasQuote ? { items: quoted.map(row) } : null,
        sale: hasSale ? {
          products: sold.map(p => ({ ...row(p), ...money(p), policy_count: 1, added_to_existing: p.line === "auto" && !!p.addedToExisting, is_new_line: askNewLine(p) ? p.isNewLine === true : true, autopay: !!p.autopay,
            insured_name: p.line === "life" ? ((p.insured || "").trim() || null) : null })),
          on_file_answer: flagged.length ? (replaces.length ? "replaces" : flagged.some(p => onFileAnswer[p.id] === "added") ? "added" : "different") : null,
          replaced_sale_product_id: replaces.length ? sameProductOnFile(replaces[0]).sale_product_id : null,
        } : null,
        cancelation: hasCxl ? { items: canceled.map(p => ({ ...row(p), ...money(p), ...matched(p) })) } : null,
        scorecard: hasCard ? { ...scores } : null,
      };
      const { data, error } = await supabase.rpc("rp_log_entry", { p_payload: payload });
      if (error) { setErr(errText(error)); return; }
      if (!data?.ok) { setErr(errText(data)); return; }
      let summary = summarizeEntry(data);
      // Logged from inside an appointment row: point the sale (or the quote) at
      // it, which is what marks the appointment sold or kept. Only the person it
      // was handed to can move the state, so the link is recorded either way.
      if (appointment?.id && (data.sale?.sale_id || data.quote?.quote_id)) {
        const at = await supabase.rpc("rp_attach_entry_to_appointment", {
          p_appointment_id: appointment.id,
          p_sale_id: data.sale?.sale_id || null,
          p_quote_id: data.quote?.quote_id || null,
        });
        if (at.error || !at.data?.ok) summary += ` It did not attach to the appointment: ${errText(at.error || at.data)}.`;
        else if (at.data.marked) summary += ` The appointment is marked ${at.data.state}.`;
        else summary += ` Attached to the appointment, but not marked: ${at.data.why_not || "only the person it was handed to can mark it"}.`;
      }
      let cxlResult = null;
      if (replaces.length) {
        // the confirmed replacements cancel the old policies now, in the same click; no chargeback (the household kept the line)
        const items = replaces.map(p => { const o = sameProductOnFile(p); return { line_of_business: o.line_of_business, product_type: o.product_type || null, premium: Number(o.premium ?? 0),
          vehicle_count: hasCars(o.line_of_business, o.product_type) ? Number(o.vehicle_count || 1) : null, matched_sale_product_id: o.sale_product_id, replacement: true }; });
        const c = await supabase.rpc("rp_log_entry", { p_payload: {
          customer_first: first.trim(), customer_last_initial: initial.trim(), customer_kind: custKind, phone_last4: phone, occurred_on: date, team_member_id: logFor, relationship_type: "existing",
          ...ageGender,
          ecrm_url: ecrm.trim(), note: "Replaced by the new policy logged with the sale",
          cancelation: { items },
        } });
        if (c.error || !c.data?.ok) summary += ` The old ${replaces.map(p => PRODUCT_SHORT[p.line]).join(", ")} could not be canceled: ${errText(c.error || c.data)}. Cancel it on the Canceled tab.`;
        else { cxlResult = c.data; summary += ` Old policy ${summarizeEntry(c.data).replace(/^Logged for [^:]*: /, "")}`; }
      }
      setOk(summary);
      setLast({ result: data, cxlResult, first: first.trim(), initial: initial.trim(), kind: custKind, label: householdLabel, phone, age, gender, date });
      reset();
      onSaved?.(data);
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
    setCustKind(last.kind || "person"); setFirst(last.first); setInitial(last.initial); setPhone(last.phone || ""); setAge(last.age || ""); setGender(last.gender || ""); setDate(last.date);
    setOk(""); setLast(null);
  };

  const preview = nameOk ? `${householdLabel}${phoneOk ? ` ·${phone}` : ""}` : "";
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
          {isEdit ? `Editing this ${editRec.kind === "scorecard" ? "conversation score" : editRec.kind}` : (heading || "What happened with this customer?")}
        </div>
        <div style={{ fontSize: 13, color: T.slate500, marginBottom: 16, display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center" }}>
          <span>{isEdit ? "Change what needs changing and save." : (subheading || "Add what happened. One button saves it all.")}</span>
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
          <CustomerFields kind={custKind} first={first} initial={initial} phone={phone} age={age} gender={gender}
            withAgeGender={withAgeGender} onChange={onCustomer} onPick={pickCustomer} />
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
              {items.map(v => <option key={v.activity_key} value={v.activity_key}>{itemLabel(v, isEdit ? null : nextPts)}</option>)}
            </select>
            {activities.map(a => byKey[a.key] && (
              <span key={a.id} style={{ ...pill, cursor: a.done ? "pointer" : "default" }} onClick={() => a.done && editActivity(a.id, { done: false })}>
                {itemLabel(byKey[a.key], isEdit ? null : nextPts)}{a.done && a.line ? ` · ${typeLabel(types, a.line, a.type) || PRODUCT_LABEL[a.line]}` : ""}
                <button type="button" style={pillX} onClick={e => { e.stopPropagation(); dropActivity(a.id); }} aria-label="remove">×</button>
              </span>
            ))}
            <button type="button" onClick={() => setInfoOpen(o => !o)} aria-label="What each activity means" title="What each activity means"
                    style={{ width: 26, height: 26, borderRadius: 999, border: `1px solid ${infoOpen ? T.blue : T.slate300}`, background: infoOpen ? T.blueLt : T.white,
                             color: infoOpen ? T.blue : T.slate500, fontWeight: 800, fontSize: 13, cursor: "pointer", fontFamily: "inherit", flex: "0 0 auto" }}>i</button>
          </div>
          {infoOpen && (
            <div style={{ marginTop: 10, padding: 12, background: T.slate50, borderRadius: 8, fontSize: 13, color: T.slate700, lineHeight: 1.5 }}>
              <div style={{ fontWeight: 700, color: T.slate800, marginBottom: 6 }}>Most calls are simple phone calls. Answering the phone, taking a payment, sending ID cards and answering basic questions count as calls answered on their own, so there is nothing to log. Log an activity only when the call did one of these:</div>
              {items.map(v => (
                <div key={v.activity_key} style={{ marginTop: 6 }}><strong>{v.label}:</strong> {v.description || ""}</div>
              ))}
            </div>
          )}
          {activities.filter(a => a.key === "autopay_enrollment").map(a => (
            <div key={a.id} style={{ ...wrapRow, marginTop: 10, padding: 10, background: T.slate50, borderRadius: 8 }}>
              <div style={{ fontWeight: 700, color: T.slate800, flex: "0 0 auto", paddingBottom: 10 }}>Autopay on</div>
              {lineFields(a)}
              <div style={field(130)}>
                <label style={labelStyle}>Premium</label>
                <input type="number" inputMode="decimal" min="0" step="0.01" style={moneyInput} value={a.premium} onChange={e => editActivity(a.id, { premium: e.target.value })} placeholder="0.00" />
              </div>
            </div>
          ))}
          {activities.filter(a => needsSite(a.key)).map(a => (
            <div key={a.id} style={{ ...wrapRow, marginTop: 10, padding: 10, background: T.slate50, borderRadius: 8 }}>
              <div style={{ fontWeight: 700, color: T.slate800, flex: "0 0 auto", paddingBottom: 10 }}>Review left on</div>
              <div style={field(150)}>
                <label style={labelStyle}>Site <span style={{ color: T.red }}>(required)</span></label>
                <select style={inputBase} value={a.site || ""} onChange={e => editActivity(a.id, { site: e.target.value })}>
                  <option value="">Pick one</option>
                  {REVIEW_SITES.map(s => <option key={s.key} value={s.key}>{s.label}</option>)}
                </select>
              </div>
            </div>
          ))}
          {activities.filter(a => LINE_REQUIRED[a.key] && !a.done).map(a => (
            <div key={a.id} style={{ ...wrapRow, marginTop: 10, padding: 10, background: T.slate50, borderRadius: 8 }}>
              <div style={{ fontWeight: 700, color: T.slate800, flex: "0 0 auto", paddingBottom: 10 }}>{a.key === "pivot" ? "Pivoted to" : "Policy reviewed"}</div>
              {policyFields(a, a.key === "policy_review")}
            </div>
          ))}
          {activities.filter(a => a.key === "cancelation_saved").map(a => (
            <div key={a.id} style={{ ...wrapRow, marginTop: 10, padding: 10, background: T.slate50, borderRadius: 8 }}>
              <div style={{ fontWeight: 700, color: T.slate800, flex: "0 0 auto", paddingBottom: 10 }}>Saved</div>
              {lineFields(a)}
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
                  {(quoteOnly ? statuses.filter(st => st.key === "quoted") : statuses).map(st => <option key={st.key} value={st.key}>{st.label}</option>)}
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
              {needsMoney(active) && hasCars(active.line, active.type) && (
                <div style={field(70)}>
                  <label style={labelStyle}>Cars</label>
                  <input type="number" inputMode="numeric" min="1" step="1" style={inputBase} value={active.vehicles} onChange={e => editPolicy(active.id, { vehicles: e.target.value })} />
                </div>
              )}
              {isSold(active) && active.line === "auto" && (
                <div style={field(150)}>
                  <label style={labelStyle}>Auto policy</label>
                  <select style={inputBase} value={active.addedToExisting ? "added" : "new"}
                          onChange={e => editPolicy(active.id, { addedToExisting: e.target.value === "added" })}>
                    <option value="new">New Policy</option>
                    <option value="added">Added to Policy</option>
                  </select>
                </div>
              )}
              {isSold(active) && active.line === "life" && (
                // Peter 2026-09-26: a life policy on the same insured within 60 days of the last one does not
                // count, so the insured is recorded. Left blank, it is the customer.
                <div style={field(170)}>
                  <label style={labelStyle}>Insured <span style={hintStyle}>(if not the customer)</span></label>
                  <input style={inputBase} value={active.insured || ""} placeholder={nameOk ? householdLabel : "First name, last initial"}
                         onChange={e => editPolicy(active.id, { insured: e.target.value })} />
                </div>
              )}
              {isEdit && isSold(active) && (
                <div style={field(150)}>
                  <label style={labelStyle}>Issued premium <span style={hintStyle}>(what it issued at)</span></label>
                  <input type="number" inputMode="decimal" min="0" step="0.01" style={moneyInput}
                         value={active.issuedPremium || ""} placeholder="0.00"
                         onChange={e => editPolicy(active.id, { issuedPremium: e.target.value })} />
                </div>
              )}
              {isEdit && isSold(active) && (
                <div style={field(150)}>
                  <label style={labelStyle}>Issued date</label>
                  <input type="date" max={todayCentral()} style={inputBase}
                         value={active.issuedDate || ""}
                         onChange={e => editPolicy(active.id, { issuedDate: e.target.value })} />
                </div>
              )}
              {isSold(active) && (
                <label style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 13, color: T.slate700, paddingBottom: 10, flex: "0 0 auto" }} title="The policy went on automatic payment as you set it up. One autopay credit per policy.">
                  <input type="checkbox" checked={!!active.autopay} onChange={e => editPolicy(active.id, { autopay: e.target.checked })} />
                  Autopay
                </label>
              )}
              {askNewLine(active) && (
                <div style={field(170)}>
                  <label style={labelStyle}>New for them, or a replacement?</label>
                  <div style={{ ...chipRow, paddingBottom: 4 }}>
                    <span style={chip(active.isNewLine === true)} onClick={() => editPolicy(active.id, { isNewLine: true })}>New</span>
                    <span style={chip(active.isNewLine === false)} onClick={() => editPolicy(active.id, { isNewLine: false })}>Replacement</span>
                  </div>
                </div>
              )}
              <button type="button" style={{ ...btnGhost, marginLeft: "auto", marginBottom: 6 }} onClick={() => setActivePolicy(null)}>Done</button>
            </div>
          )}
          {flagged.map(p => {
            const r = sameProductOnFile(p);
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
          {autoReplaced.map(p => {
            const r = sameProductOnFile(p);
            return (
              <div key={p.id} style={{ padding: "8px 12px", borderRadius: 8, background: T.amberLt, color: T.amber, fontSize: 13, fontWeight: 600, marginTop: 10 }}>
                {preview} already has {typeLabel(types, p.line, p.type)} on file, sold {fmtDate(r.submitted_date)}. A household has one, so logging this cancels the old one as a replacement.
              </div>
            );
          })}
          {autoAdded.map(p => {
            const r = sameProductOnFile(p);
            return (
              <div key={p.id} style={{ padding: "8px 12px", borderRadius: 8, background: T.slate50, color: T.slate700, fontSize: 13, fontWeight: 600, marginTop: 10 }}>
                {preview} already has {typeLabel(types, p.line, p.type) || "this auto"} on file, sold {fmtDate(r.submitted_date)}, so this goes in as an added auto.
              </div>
            );
          })}
          {lifeRepeat.map(p => {
            const r = sameProductOnFile(p);
            return (
              <div key={p.id} style={{ padding: "8px 12px", borderRadius: 8, background: T.slate50, color: T.slate700, fontSize: 13, fontWeight: 600, marginTop: 10 }}>
                {preview} had a life sold {fmtDate(r.submitted_date)}, inside 60 days, so this one counts as the replacement, not a new product.
              </div>
            );
          })}
          {mixUp && (
            <div style={{ padding: "10px 12px", borderRadius: 8, background: T.amberLt, color: T.amber, fontSize: 13, fontWeight: 600, marginTop: 10 }}>
              <div>{preview} already has {[...new Set(onFileBefore.map(x => typeLabel(types, x.line_of_business, x.product_type) || PRODUCT_SHORT[x.line_of_business]))].join(", ")} on file, so they are not {relationship === "new" ? "a new customer" : "a winback"}. Either the cancelation was never logged, or they are an existing customer.</div>
              <div style={{ ...chipRow, marginTop: 8 }}>
                <span style={chip(false)} onClick={() => setRelationship("existing")}>They're an existing customer</span>
              </div>
              <div style={{ marginTop: 6, fontWeight: 400 }}>If what's on file canceled, log that cancelation first, then this.</div>
            </div>
          )}
          {(!isEdit || quoteOnly) && hasQuote && dupQuotes.length > 0 && (
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
          {showEcrm && (
            <div style={field(200)}>
              <label style={labelStyle}>ECRM link {needsEcrm && <span style={{ color: T.red }}>(required)</span>}</label>
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
            <label style={labelStyle}>Note {hasCxl ? <span style={hintStyle}>(say why it canceled)</span> : hasReview ? <span style={{ color: T.red }}>(required for a policy review)</span> : null}</label>
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
            <button type="button" style={linkBtn} onClick={logAnother}>Log another for {last.label}</button>
          </div>
        )}
      </div>
      {!isEdit && !hidePending && <PendingSaves refreshKey={refreshKey} />}
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
                <td style={tableTd}><CustomerName label={r.customer_label} /></td>
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
// Weekly spot-check (core principle 450). Owner and managers only, on its own
// tab — Peter 2026-09-16 took it off the top of the Score tab and put it on a
// week, not a month. Opens on the current week; only falls back to the newest
// week with entries when the current week is empty. Ten random self-logged
// entries from that week, stable until verified. "Self-logged" means the
// person who earned the points typed them in: rp_spot_check_sample drops
// anything backfilled (no created_by) or logged for someone else, so the
// historical records Peter seeded himself are never checked back.
// Verify stamps verified_at; Remove is the same void the tables use.
// =====================================================================
// ---------------------------------------------------------------------
// Turning a flagged spot-check entry into the cancelation it really was.
// The household's policies on file come back ticked, with their line and
// premium already known. Anything sold before the log existed has to have
// its line typed, because nothing on the entry records it — a note saying
// "cancelled both auto and home" names two lines and no premium.
// The server does the rest: chargeback, voided saves and the 0.50 logging
// credit all behave exactly as they do on the normal cancelation screen.
// ---------------------------------------------------------------------
function CancelationConvert({ row, types, pool, onClose, onDone }) {
  const [onFile, setOnFile] = useState([]);
  const [picked, setPicked] = useState({});
  const [extras, setExtras] = useState([]);
  const [ecrm, setEcrm] = useState(row.ecrm_url || "");
  const [alsoVoid, setAlsoVoid] = useState({});   // other entries on this household, ticked by default
  const [edits, setEdits] = useState({});         // corrections to what the log says is on file

  // The same cancelation often gets typed more than once for one household.
  // Everything else on this household in the week is offered alongside.
  const seen = new Set([row.id]);
  const sibs = (pool || []).filter(p => {
    if (seen.has(p.id)) return false;
    if (p.kind && p.kind !== "activity") return false;   // a sale on the same household is not a duplicate cancelation
    if ((p.customer_label || "") !== (row.customer_label || "")) return false;
    if ((p.phone_last4 || "") !== (row.phone_last4 || "")) return false;
    seen.add(p.id); return true;
  });
  const onFor = (id) => alsoVoid[id] !== false;
  const editOf = (p) => edits[p.sale_product_id] || {};
  const setEdit = (id, patch) => setEdits(s => ({ ...s, [id]: { ...(s[id] || {}), ...patch } }));
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");

  useEffect(() => {
    let alive = true;
    (async () => {
      const { data, error } = await supabase.rpc("rp_sold_on_file2", {
        p_customer_first: row.customer_first_name,
        p_customer_last_initial: row.customer_last_initial,
        p_phone_last4: row.phone_last4 || null,
      });
      if (!alive) return;
      if (error) { setErr(errText(error)); return; }
      const list = (Array.isArray(data) ? data : []).filter(p => !p.already_canceled);
      setOnFile(list);
      setPicked(Object.fromEntries(list.map(p => [p.sale_product_id, true])));
    })();
    return () => { alive = false; };
  }, [row.id]);

  const addExtra = () => setExtras(x => [...x, { key: `x${x.length}${Date.now()}`, line: "", type: "", premium: "" }]);
  const editExtra = (k, patch) => setExtras(x => x.map(e => e.key === k ? { ...e, ...patch } : e));
  const dropExtra = (k) => setExtras(x => x.filter(e => e.key !== k));

  const save = async () => {
    const policies = [
      ...onFile.filter(p => picked[p.sale_product_id]).map(p => ({
        policy_line: p.line_of_business,
        product_type: editOf(p).type != null ? (editOf(p).type || null) : p.product_type,
        premium: editOf(p).premium != null ? editOf(p).premium
          : (p.premium == null ? "" : String(p.premium)),
        vehicle_count: p.vehicle_count == null ? "" : String(p.vehicle_count),
        matched_sale_product_id: p.sale_product_id,
      })),
      ...extras.filter(e => e.line).map(e => ({
        policy_line: e.line,
        product_type: e.type || null,
        premium: e.premium || "",
      })),
    ];
    if (!policies.length) { setErr("Tick at least one policy that canceled."); return; }
    if (!ecrm.trim()) { setErr("A cancelation needs the ECRM link."); return; }
    // A line that has types needs one picked, the same as the cancelation screen.
    if (extras.some(e => e.line && (types[e.line] || []).length > 0 && !e.type)) {
      setErr("Pick the policy type for each line you added."); return;
    }
    setBusy(true); setErr("");
    try {
      const { data, error } = await supabase.rpc("rp_convert_activity_to_cancelation",
        { p_activity_id: row.id, p_policies: policies, p_ecrm_url: ecrm.trim() || null,
          p_also_void: sibs.filter(s => onFor(s.id)).map(s => s.id) });
      if (error) { setErr(errText(error)); return; }
      if (data && data.ok === false) { setErr(errText(data)); return; }
      const n = Number(data?.count || policies.length);
      const also = Number(data?.also_removed || 0);
      onDone(`${row.customer_label}: ${n} cancelation${n === 1 ? "" : "s"} logged, and ${1 + also} entr${(1 + also) === 1 ? "y" : "ies"} removed.`);
    } catch (e) { setErr(errText(e)); } finally { setBusy(false); }
  };

  return (
    <Modal title={`Cancelation for ${row.customer_label}`} onClose={onClose}>
      <div style={{ ...cardStyle, display: "grid", gap: 12 }}>
        {err && <Notice kind="error">{err}</Notice>}
        <div style={{ fontSize: 13, color: T.slate600 }}>
          Canceled {fmtDate(row.occurred_on)}, credited to {row.first_name}. The note said: {row.note || "—"}
        </div>

        <div style={field(240)}>
          <label style={labelStyle}>ECRM link <span style={{ color: T.red }}>(required)</span></label>
          <input style={inputBase} value={ecrm} onChange={e => setEcrm(e.target.value)} placeholder="https://…" />
        </div>

        <div>
          <div style={{ fontSize: 13, fontWeight: 700, color: T.slate900, marginBottom: 6 }}>Policies on file</div>
          {onFile.length === 0 ? (
            <div style={{ fontSize: 13, color: T.slate600 }}>Nothing in force on file for this household. Add what canceled below.</div>
          ) : onFile.map(p => (
            <div key={p.sale_product_id} style={{ display: "flex", flexWrap: "wrap", gap: 8, alignItems: "flex-end", padding: "4px 0" }}>
              <input type="checkbox" style={{ marginBottom: 10 }} checked={!!picked[p.sale_product_id]}
                     onChange={e => setPicked(s => ({ ...s, [p.sale_product_id]: e.target.checked }))} />
              <div style={{ ...field(120), fontSize: 13, color: T.slate800, paddingBottom: 10 }}>
                {PRODUCT_SHORT[p.line_of_business] || p.line_of_business}
                <div style={{ fontSize: 11, color: T.slate400 }}>sold {fmtDate(p.submitted_date)}</div>
              </div>
              {(types[p.line_of_business] || []).length > 0 && (
                <div style={field(140)}>
                  <label style={labelStyle}>Type</label>
                  <select style={inputBase}
                          value={editOf(p).type != null ? editOf(p).type : (p.product_type || "")}
                          onChange={e => setEdit(p.sale_product_id, { type: e.target.value })}>
                    <option value="">Pick one</option>
                    {(types[p.line_of_business] || []).map(t => <option key={t.type_key} value={t.type_key}>{t.label}</option>)}
                  </select>
                </div>
              )}
              <div style={field(120)}>
                <label style={labelStyle}>Premium</label>
                <input type="number" inputMode="decimal" min="0" step="0.01" style={moneyInput}
                       value={editOf(p).premium != null ? editOf(p).premium : (p.premium == null ? "" : String(p.premium))}
                       onChange={e => setEdit(p.sale_product_id, { premium: e.target.value })} />
              </div>
            </div>
          ))}
        </div>

        {sibs.length > 0 && (
          <div>
            <div style={{ fontSize: 13, fontWeight: 700, color: T.slate900, marginBottom: 2 }}>Other entries on this household</div>
            <div style={{ fontSize: 12, color: T.slate500, marginBottom: 6 }}>Ticked ones are removed with this one. Untick anything that really was separate.</div>
            {sibs.map(s => (
              <label key={s.id} style={{ display: "flex", gap: 8, alignItems: "flex-start", fontSize: 13, padding: "3px 0" }}>
                <input type="checkbox" checked={onFor(s.id)}
                       onChange={e => setAlsoVoid(v => ({ ...v, [s.id]: e.target.checked }))} />
                <span>
                  {s.label || s.activity_key}{" · "}{fmtDate(s.occurred_on)}{" · "}{s.first_name}
                  {s.note ? <div style={{ fontSize: 11, color: T.slate500 }}>{s.note}</div> : null}
                </span>
              </label>
            ))}
          </div>
        )}

        <div>
          <div style={{ fontSize: 13, fontWeight: 700, color: T.slate900, marginBottom: 6 }}>Not on file</div>
          {extras.map(e => (
            <div key={e.key} style={{ display: "flex", flexWrap: "wrap", gap: 8, alignItems: "flex-end", marginBottom: 6 }}>
              <div style={field(130)}>
                <label style={labelStyle}>Line</label>
                <select style={inputBase} value={e.line} onChange={ev => editExtra(e.key, { line: ev.target.value, type: "" })}>
                  <option value="">Pick one</option>
                  {PRODUCTS.map(pr => <option key={pr.key} value={pr.key}>{pr.label}</option>)}
                </select>
              </div>
              {(types[e.line] || []).length > 0 && (
                <div style={field(150)}>
                  <label style={labelStyle}>Type</label>
                  <select style={inputBase} value={e.type} onChange={ev => editExtra(e.key, { type: ev.target.value })}>
                    <option value="">Pick one</option>
                    {(types[e.line] || []).map(t => <option key={t.type_key} value={t.type_key}>{t.label}</option>)}
                  </select>
                </div>
              )}
              <div style={field(120)}>
                <label style={labelStyle}>Premium <span style={hintStyle}>(if known)</span></label>
                <input type="number" inputMode="decimal" min="0" step="0.01" style={moneyInput} value={e.premium}
                       placeholder="0.00" onChange={ev => editExtra(e.key, { premium: ev.target.value })} />
              </div>
              <button type="button" style={{ ...btnGhost, color: T.red, marginBottom: 10 }} onClick={() => dropExtra(e.key)}>Remove</button>
            </div>
          ))}
          <button type="button" style={btnGhost} onClick={addExtra}>Add a policy</button>
        </div>

        <div style={{ display: "flex", gap: 8 }}>
          <button type="button" style={btnPrimary(busy)} disabled={busy} onClick={save}>{busy ? "Saving…" : "Log the cancelation"}</button>
          <button type="button" style={btnGhost} disabled={busy} onClick={onClose}>Cancel</button>
        </div>
      </div>
    </Modal>
  );
}

function SpotCheck({ isAdmin, values, sources, types, isOwner, roster }) {
  const thisWeek = weekEndOf(todayCentral());
  const [weeks, setWeeks] = useState([]);
  const [week, setWeek] = useState(thisWeek);
  const [rows, setRows] = useState([]);
  const [remaining, setRemaining] = useState(0);        // entries still unverified this week
  const [housesLeft, setHousesLeft] = useState(0);      // households still unchecked this week
  const [busyId, setBusyId] = useState(null);
  const [err, setErr] = useState("");
  const [tick, setTick] = useState(0);
  const [editing, setEditing] = useState(null);   // { kind, id } of the entry being changed
  const [flags, setFlags] = useState([]);         // entries this week whose note says cancel
  const [converting, setConverting] = useState(null);  // the flagged entry being turned into a cancelation
  const [msg, setMsg] = useState("");
  const [notes, setNotes] = useState({});        // spot-check notes he is typing, by entry
  // Policy Changes whose note says something came off, but not clearly a vehicle, with an added auto for the
  // same household within 30 days. Peter says swap or not (rp_vehicle_swap_review, 2026-09-26).
  const [swaps, setSwaps] = useState([]);
  // Two views (Peter 2026-09-26): what is still to check, and what has already been checked, a day or a week
  // at a time, with the same buttons plus Undo. The view, Day or Week, and the day or week picked all live in
  // the URL, so a refresh stays put.
  const [view, setView, viewHref] = useTabParam("scview", "tocheck", ["tocheck", "checked"]);
  const [by, setBy, byHref] = useTabParam("scby", "day", ["day", "week"]);
  const [on, setOn] = useTabParam("scon", "");
  const [days, setDays] = useState([]);          // days with checks on them: checked_on, week_end, verified, removed
  const [checked, setChecked] = useState([]);    // the records checked on the day or in the week picked
  const _vp = useViewport();

  // Which weeks the picker offers, and which one we land on. A week stays in
  // the list once it is cleared, so the week being worked does not disappear
  // out from under the dropdown as entries get verified.
  useEffect(() => {
    if (!isAdmin || view !== "tocheck") return undefined;
    let alive = true;
    (async () => {
      const { data, error } = await supabase.rpc("rp_spot_check_weeks", { p_weeks: 12 });
      if (!alive) return;
      if (error) { setErr(errText(error)); return; }
      const list = Array.isArray(data) ? data : [];
      setWeeks(list);
      setWeek(w => (
        list.some(x => x.week_end === w) ? w
          : list.some(x => x.week_end === thisWeek) ? thisWeek
          : list.length ? list[0].week_end : thisWeek
      ));
    })();
    return () => { alive = false; };
  }, [isAdmin, view, thisWeek, tick]);

  useEffect(() => {
    if (!isAdmin || !week || view !== "tocheck") return undefined;
    let alive = true;
    (async () => {
      const [sample, cancels, sw] = await Promise.all([
        supabase.rpc("rp_spot_check_sample", { p_week_end: week, p_limit: 10 }),
        supabase.rpc("rp_cancel_word_review", { p_week_end: week }),
        supabase.rpc("rp_vehicle_swap_review"),
      ]);
      if (!alive) return;
      if (sample.error) { setErr(errText(sample.error)); return; }
      if (cancels.error) { setErr(errText(cancels.error)); return; }
      if (sw.error) { setErr(errText(sw.error)); return; }
      setSwaps(Array.isArray(sw.data) ? sw.data : []);
      const list = Array.isArray(sample.data) ? sample.data : [];
      setRows(list);
      setRemaining(list.length ? Number(list[0].remaining) : 0);
      setHousesLeft(list.length ? Number(list[0].households_left) : 0);
      setFlags(Array.isArray(cancels.data) ? cancels.data : []);
    })();
    return () => { alive = false; };
  }, [isAdmin, view, week, tick]);

  // Checked view: the days with checks on them in the last 90, newest first.
  useEffect(() => {
    if (!isAdmin || view !== "checked") return undefined;
    let alive = true;
    (async () => {
      const { data, error } = await supabase.rpc("rp_spot_check_checked_days", { p_days: 90 });
      if (!alive) return;
      if (error) { setErr(errText(error)); return; }
      setDays(Array.isArray(data) ? data : []);
    })();
    return () => { alive = false; };
  }, [isAdmin, view, tick]);

  const act = async (fn, id) => {
    setErr(""); setBusyId(id);
    try {
      const { error } = await fn();
      if (error) setErr(errText(error)); else setTick(t => t + 1);
    } finally { setBusyId(null); }
  };
  const weekLabel = (iso) => `Week of ${fmtDate(addDays(iso, -6))} \u2013 ${fmtDate(iso)}`;
  const dayName = (iso) => {
    const [y, m, d] = iso.split("-").map(Number);
    return `${new Date(Date.UTC(y, m - 1, d)).toLocaleDateString("en-US", { weekday: "short", timeZone: "UTC" })} ${m}/${d}`;
  };
  // The Checked view's picker, built from the days list. A day is one choice; a week gathers its days. The
  // server says which week each day falls in, so there is no week math here.
  const dayOpts = days.map(d => ({ key: d.checked_on, from: d.checked_on, to: d.checked_on,
    v: Number(d.verified) || 0, r: Number(d.removed) || 0, name: dayName(d.checked_on) }));
  const weekOpts = [];
  days.forEach(d => {
    const w = weekOpts.find(x => x.key === d.week_end);
    if (w) { w.v += Number(d.verified) || 0; w.r += Number(d.removed) || 0; return; }
    weekOpts.push({ key: d.week_end, from: addDays(d.week_end, -6), to: d.week_end,
      v: Number(d.verified) || 0, r: Number(d.removed) || 0, name: weekLabel(d.week_end) });
  });
  const opts = by === "week" ? weekOpts : dayOpts;
  // Flipping between Day and Week keeps the same stretch of time: a day opens its week, a week opens its
  // latest day. Nothing picked yet, the newest.
  const wanted = by === "week"
    ? (days.find(d => d.checked_on === on)?.week_end || on)
    : (days.some(d => d.checked_on === on) ? on : (days.find(d => d.week_end === on)?.checked_on || on));
  const pick = opts.find(o => o.key === wanted) || opts[0] || null;
  useEffect(() => {
    if (!isAdmin || view !== "checked" || !pick) { setChecked([]); return undefined; }
    let alive = true;
    (async () => {
      const { data, error } = await supabase.rpc("rp_spot_check_checked", { p_from: pick.from, p_to: pick.to });
      if (!alive) return;
      if (error) { setErr(errText(error)); return; }
      setChecked(Array.isArray(data) ? data : []);
    })();
    return () => { alive = false; };
  }, [isAdmin, view, pick?.from, pick?.to, tick]);
  // Peter 2026-09-19: a note left while checking reads on the CPR change
  // report, so Verified carries whatever is in the box with it.
  const noteFor = (r) => notes[r.id] !== undefined ? notes[r.id] : (r.spot_check_note || "");
  // Two kinds of record share this screen now: entries off the activity log,
  // and the sales that issued in the week. Every button sends the kind along
  // so the server hands the work to the function that owns that table.
  const kindOf = (r) => r.kind || "activity";
  // The household now arrives whole: prior weeks, backfill, and the credits a
  // sale wrote on its own all show for context. Only the rows still open to
  // checking carry buttons and a note box.
  const canCheck = (r) => !!r.in_scope && !r.verified_at;
  // A sale carries a premium where an entry carries points.
  const worth = (r) => (kindOf(r) === "sale" ? fmtMoney(r.premium) : fmtPts(r.points));
  // The buttons, each written once. The Checked view uses the same ones, with Undo where Verified was.
  // A credit a sale or cancelation wrote on its own (autopay, multiline) is changed through that record, which
  // sits in the same household, so it has no Edit of its own.
  const canEdit = (r) => r.entry_source !== "sales_log" && r.entry_source !== "cancelation_log";
  const editButton = (r) => !canEdit(r) ? null : (
    <button style={{ ...btnGhost, marginRight: 6 }} disabled={busyId === r.id} onClick={() => setEditing({ kind: kindOf(r), id: r.id })}>Edit</button>
  );
  const verifyButton = (r) => (
    <button style={{ ...btnGhost, color: T.green, marginRight: 6 }} disabled={busyId === r.id} onClick={() => act(() => supabase.rpc("rp_spot_check_verify", { p_kind: kindOf(r), p_id: r.id, p_note: noteFor(r) || null }), r.id)}>Verified</button>
  );
  const removeButton = (r) => (
    <button style={{ ...btnGhost, color: T.red, marginRight: 6 }} disabled={busyId === r.id} onClick={() => { if (window.confirm(`Remove ${r.label || r.activity_key} for ${r.customer_label}? It will not be paid.`)) act(() => supabase.rpc("rp_spot_check_remove", { p_kind: kindOf(r), p_id: r.id, p_reason: "spot-check: could not verify" }), r.id); }}>Remove</button>
  );
  // Undo takes the check back: a verified record goes back on the list to check, a removed one comes back
  // and gets paid again (rp_spot_check_undo).
  const undoButton = (r) => (
    <button style={{ ...btnGhost, color: T.blue, marginRight: 6 }} disabled={busyId === r.id} onClick={() => act(() => supabase.rpc("rp_spot_check_undo", { p_kind: kindOf(r), p_id: r.id }), r.id)}>Undo</button>
  );
  // The Checked view shows each household whole, like To check (Peter 2026-09-26). A record that has been
  // checked, on any day, gets the checked buttons; everything else in the household reads as it does on To check.
  const rowActions = (r) => {
    if (view === "checked" && r.outcome) return (
      <>
        {r.outcome === "verified" && editButton(r)}
        {undoButton(r)}
        {r.outcome === "verified" && removeButton(r)}
      </>
    );
    return !canCheck(r) ? (
      <span style={{ color: r.verified_at ? T.green : T.slate400, fontWeight: r.verified_at ? 700 : 400 }}>
        {r.verified_at ? "Verified" : "\u2014"}
      </span>
    ) : (
      <>
        {view === "tocheck" && flags.find(f => f.id === r.id) && (
          <button style={{ ...btnGhost, color: T.amber, marginRight: 6 }} disabled={busyId === r.id}
                  onClick={() => { setMsg(""); setConverting(flags.find(f => f.id === r.id)); }}>This was a cancelation</button>
        )}
        {editButton(r)}
        {verifyButton(r)}
        {removeButton(r)}
      </>
    );
  };
  // A spot-check note can be typed on anything still to check, and on anything already checked.
  const canNote = (r) => (view === "checked" && !!r.outcome) || canCheck(r);
  // Was this record checked in the day or week picked? The rest of its household is there for context.
  const inPick = (r) => !!(pick && r.outcome && r.checked_on && r.checked_on >= pick.from && r.checked_on <= pick.to);
  // How and when a checked record was checked: "Verified 6:36 PM by Peter", "Removed 6:41 PM by Peter · could
  // not verify". A week shows the day too, and a record checked outside the day or week picked shows its date.
  const checkedLine = (r) => {
    if (!r.outcome) return <span style={{ color: T.slate400 }}>{canCheck(r) ? "Not checked" : "—"}</span>;
    const d = r.checked_at ? new Date(r.checked_at) : null;
    const dayPart = !inPick(r) ? { weekday: "short", month: "numeric", day: "numeric" } : by === "week" ? { weekday: "short" } : {};
    const when = d && !isNaN(d)
      ? d.toLocaleString("en-US", { timeZone: "America/Chicago", ...dayPart, hour: "numeric", minute: "2-digit" })
      : "";
    const why = r.outcome === "removed" ? String(r.void_reason || "").replace(/^spot-check:\s*/i, "") : "";
    return (
      <span style={{ fontWeight: 700, color: r.outcome === "removed" ? T.red : T.green }}>
        {r.outcome === "removed" ? "Removed" : "Verified"}
        <span style={{ fontWeight: 400, color: T.slate500 }}>{` ${when}${r.checked_by ? ` by ${r.checked_by}` : ""}${why ? ` \u00b7 ${why}` : ""}`}</span>
      </span>
    );
  };
  // The record's own note, the cancel warning, and the spot-check note box. Table and phone both use it.
  const noteCell = (r) => (
    <>
      {r.note || "\u2014"}
      {view === "tocheck" && flags.some(f => f.id === r.id) && (
        <div style={{ fontSize: 11, fontWeight: 700, color: T.amber }}>Note says cancel — policy change or cancelation?</div>
      )}
      {canNote(r) && (
        <div style={{ display: "flex", gap: 6, alignItems: "center", marginTop: 4 }}>
          <input style={{ ...inputBase, fontSize: 12, padding: "4px 6px", minWidth: 0 }}
                 value={noteFor(r)} placeholder="Spot-check note (goes on the change report)"
                 onChange={e => setNotes(s => ({ ...s, [r.id]: e.target.value }))} />
          {noteFor(r) !== (r.spot_check_note || "") && (
            <button type="button" style={{ ...miniBtn, whiteSpace: "nowrap" }} disabled={busyId === r.id}
                    onClick={() => act(() => supabase.rpc("rp_spot_check_note", { p_kind: kindOf(r), p_id: r.id, p_note: noteFor(r) }), r.id)}>Save note</button>
          )}
        </div>
      )}
    </>
  );
  // Flagged entries already in the ten below are marked there instead, so
  // the same entry never gets two sets of buttons.
  const flagsAbove = view === "tocheck" ? flags.filter(f => !rows.some(r => r.id === f.id)) : [];
  // Both lists come back as entries, ordered by household (the Checked one in the order the households were
  // first checked). Walking them in order keeps each household together without sorting again here.
  const shown = view === "checked" ? checked : rows;
  const households = [];
  shown.forEach(r => {
    const key = `${(r.customer_label || "").trim().toLowerCase()}|${r.phone_last4 || ""}`;
    const last = households[households.length - 1];
    if (last && last.key === key) last.entries.push(r);
    else households.push({ key, label: r.customer_label, phone: r.phone_last4,
                           first: r.customer_first_name, initial: r.customer_last_initial, entries: [r] });
  });
  households.forEach(h => { h.toCheck = h.entries.filter(canCheck).length; h.checkedHere = h.entries.filter(inPick).length; });

  if (!isAdmin) return null;
  return (
    <div style={cardStyle}>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center", justifyContent: "space-between", marginBottom: 4 }}>
        <div style={{ display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center" }}>
          <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>Spot-check</div>
          <div style={segWrap}>
            {[["tocheck", "To check"], ["checked", "Checked"]].map(([k, lbl]) => (
              <TabLink key={k} href={viewHref(k)} onSelect={() => setView(k)} style={segTab(view === k)}>{lbl}</TabLink>
            ))}
          </div>
        </div>
        {view === "tocheck" ? (
          <select style={{ ...inputBase, width: "auto" }} value={week} onChange={e => setWeek(e.target.value)}>
            {(weeks.length ? weeks : [{ week_end: thisWeek }]).map(w => (
              <option key={w.week_end} value={w.week_end}>{weekLabel(w.week_end)}</option>
            ))}
          </select>
        ) : (
          <div style={{ display: "flex", flexWrap: "wrap", gap: 8, alignItems: "center" }}>
            <div style={segWrap}>
              {[["day", "Day"], ["week", "Week"]].map(([k, lbl]) => (
                <TabLink key={k} href={byHref(k)} onSelect={() => setBy(k)} style={segTab(by === k)}>{lbl}</TabLink>
              ))}
            </div>
            {opts.length > 0 && (
              <select style={{ ...inputBase, width: "auto", maxWidth: "100%" }} value={pick ? pick.key : ""} onChange={e => setOn(e.target.value)}>
                {opts.map(o => <option key={o.key} value={o.key}>{`${o.name} \u00b7 ${o.v + o.r} checked`}</option>)}
              </select>
            )}
          </div>
        )}
      </div>
      {view === "checked" ? (
        <div style={{ fontSize: 12, color: T.slate500, marginBottom: 12 }}>
          {pick
            ? `${pick.v + pick.r} checked ${by === "week" ? "that week" : `on ${pick.name}`}: ${pick.v} verified, ${pick.r} removed. `
            : "Nothing checked in the last 90 days. "}
          Each household shows its whole file, like To check. Undo sends a record back to the list to check. A removed record comes back and gets paid again.
        </div>
      ) : (
      <div style={{ fontSize: 12, color: T.slate500, marginBottom: 12 }}>
        Ten households from the week, with their whole file: this week's entries and sales, plus prior weeks, backfill, and the credits a sale wrote on its own. Only the rows still open to checking have buttons. Clear a household and the next one takes its place, so the list refills until the week is done. A verified entry never comes back unless it gets changed. Open the ECRM link, check the notes, tap Verified. {housesLeft > 10 ? `${housesLeft} households still unchecked this week, ${remaining} entries in all.` : housesLeft > 0 ? `${housesLeft} households left this week.` : "Nothing left to check this week."}
      </div>
      )}
      {view === "tocheck" && swaps.length > 0 && (
        <div style={{ border: `1px solid ${T.amber}`, background: "#fffbeb", borderRadius: 10, padding: 12, marginBottom: 14 }}>
          <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>
            {swaps.length === 1 ? "A Policy Change might be a vehicle swap" : `${swaps.length} Policy Changes might be vehicle swaps`}
          </div>
          <div style={{ fontSize: 12, color: T.slate600, marginBottom: 6 }}>
            The note says something came off, and the household added an auto within 30 days. Swap turns the added auto into a replacement Policy Change.
          </div>
          {swaps.map(w => (
            <div key={`${w.removal_id}-${w.product_id}`} style={{ padding: "10px 0", borderTop: `1px solid ${T.slate100}` }}>
              <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>
                <CustomerName label={w.customer_label} phone4={w.phone_last4} />
                {w.phone_last4 ? <span style={{ color: T.slate400, fontWeight: 400 }}> ·{w.phone_last4}</span> : null}
              </div>
              <div style={{ fontSize: 13, color: T.slate800, marginTop: 2 }}>
                Policy Change {fmtDate(w.removal_on)}, {w.removal_by || "—"}: “{w.removal_note || ""}”
              </div>
              <div style={{ fontSize: 13, color: T.slate800, marginTop: 2 }}>
                Added {w.sale_label} {fmtDate(w.sold_on)}, {w.sold_by || "—"}: {fmtMoney(w.premium)}{Number(w.vehicle_count) > 1 ? `, ${w.vehicle_count} cars` : ""}
              </div>
              <div style={{ display: "flex", flexWrap: "wrap", alignItems: "center", gap: 6, marginTop: 6 }}>
                {w.ecrm_url && <a href={w.ecrm_url} target="ecrm" rel="noreferrer" style={{ color: T.blue, fontSize: 13, marginRight: 6 }}>ECRM</a>}
                <button style={{ ...btnGhost, color: T.green }} disabled={busyId === w.removal_id}
                        onClick={() => act(() => supabase.rpc("rp_vehicle_swap_decide", { p_removal_id: w.removal_id, p_product_id: w.product_id, p_swap: true }), w.removal_id)}>Swap</button>
                <button style={btnGhost} disabled={busyId === w.removal_id}
                        onClick={() => act(() => supabase.rpc("rp_vehicle_swap_decide", { p_removal_id: w.removal_id, p_product_id: w.product_id, p_swap: false }), w.removal_id)}>Not a swap</button>
              </div>
            </div>
          ))}
        </div>
      )}
      {flagsAbove.length > 0 && (
        <div style={{ border: `1px solid ${T.amber}`, background: "#fffbeb", borderRadius: 10, padding: 12, marginBottom: 14 }}>
          <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900 }}>
            {flagsAbove.length} {flagsAbove.length === 1 ? "entry" : "entries"} this week say cancel in the note
          </div>
          <div style={{ fontSize: 12, color: T.slate600, marginBottom: 10 }}>
            None of these were logged as a Cancelation Saved. Decide whether each one was a policy change or a cancelation.
          </div>
          <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
            <table style={{ width: "100%", borderCollapse: "collapse" }}>
              <thead><tr><th style={tableTh}>Who</th><th style={tableTh}>Date</th><th style={tableTh}>Logged as</th><th style={tableTh}>Customer</th><th style={tableTh}>Note</th><th style={tableTh}>ECRM</th><th style={tableTh}>Points</th><th style={tableTh}>Cancelation on file</th><th style={tableTh}></th></tr></thead>
              <tbody>
                {flagsAbove.map(r => (
                  <tr key={r.id}>
                    <td style={tableTd}>{r.first_name || "\u2014"}</td>
                    <td style={{ ...tableTd, whiteSpace: "nowrap" }}>{fmtDate(r.occurred_on)}</td>
                    <td style={tableTd}>{r.label || r.activity_key}</td>
                    <td style={tableTd}>
                      {r.ecrm_url ? <a href={r.ecrm_url} target="ecrm" rel="noreferrer" style={{ color: T.blue }}>{r.customer_label}</a> : r.customer_label}
                      {r.phone_last4 ? <span style={{ color: T.slate400 }}> ·{r.phone_last4}</span> : null}
                    </td>
                    <td style={{ ...tableTd, maxWidth: 260 }}>
                      {r.note || "\u2014"}
                      <div style={{ display: "flex", gap: 6, alignItems: "center", marginTop: 4 }}>
                        <input style={{ ...inputBase, fontSize: 12, padding: "4px 6px" }}
                               value={noteFor(r)} placeholder="Spot-check note (goes on the change report)"
                               onChange={e => setNotes(s => ({ ...s, [r.id]: e.target.value }))} />
                        {noteFor(r) !== (r.spot_check_note || "") && (
                          <button type="button" style={miniBtn} disabled={busyId === r.id}
                                  onClick={() => act(() => supabase.rpc("rp_spot_check_note", { p_kind: kindOf(r), p_id: r.id, p_note: noteFor(r) }), r.id)}>Save note</button>
                        )}
                      </div>
                    </td>
                    <td style={{ ...tableTd, whiteSpace: "nowrap" }}>
                      {r.ecrm_url ? <a href={r.ecrm_url} target="ecrm" rel="noreferrer" style={{ color: T.blue }}>ECRM</a>
                        : <span style={{ color: T.slate300 }}>—</span>}
                    </td>
                    <td style={tableTd}>{worth(r)}</td>
                    <td style={{ ...tableTd, whiteSpace: "nowrap", fontWeight: 700, color: r.has_cancelation ? T.green : T.red }}>{r.has_cancelation ? "Yes" : "No"}</td>
                    <td style={{ ...tableTd, whiteSpace: "nowrap" }}>{rowActions(r)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
      {shown.length > 0 && (
        <div style={{ display: "grid", gap: 12 }}>
          {households.map(h => (
            <div key={h.key} style={{ border: `1px solid ${T.slate200}`, borderRadius: 10, padding: 12, background: T.white }}>
              <div style={{ display: "flex", flexWrap: "wrap", gap: 8, alignItems: "baseline", marginBottom: 8 }}>
                <div style={{ fontSize: 15, fontWeight: 700 }}>
                  <CustomerName label={h.label} phone4={h.phone} />
                  {h.phone ? <span style={{ color: T.slate400, fontWeight: 400 }}> ·{h.phone}</span> : null}
                </div>
                {view === "checked" ? (
                  <div style={{ fontSize: 12, color: T.slate500 }}>
                    {h.entries.length} {h.entries.length === 1 ? "record" : "records"} on file · {h.checkedHere} checked {by === "week" ? "that week" : "that day"}{h.toCheck > 0 ? ` · ${h.toCheck} to check` : ""}
                  </div>
                ) : (
                  <div style={{ fontSize: 12, color: h.toCheck > 2 ? T.amber : T.slate500, fontWeight: h.toCheck > 2 ? 700 : 400 }}>
                    {h.entries.length} {h.entries.length === 1 ? "record" : "records"} on file · {h.toCheck} to check
                  </div>
                )}
              </div>
              {_vp.isPhone ? (
                // A phone gets each record as a few short lines, never a table that scrolls sideways.
                <div>
                  {h.entries.map(r => (
                    <div key={r.id} style={{ padding: "10px 0", borderTop: `1px solid ${T.slate100}` }}>
                      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", gap: 8 }}>
                        <div style={{ fontSize: 14, fontWeight: 700, color: T.slate900, minWidth: 0 }}>{r.label || r.activity_key}</div>
                        <div style={{ fontSize: 13, color: T.slate700, whiteSpace: "nowrap" }}>{worth(r)}</div>
                      </div>
                      <div style={{ fontSize: 12, color: T.slate500, marginTop: 2 }}>
                        {r.first_name || "—"} · {fmtDate(r.occurred_on)} · {r.ecrm_url
                          ? <a href={r.ecrm_url} target="ecrm" rel="noreferrer" style={{ color: T.blue }}>ECRM</a>
                          : "no ECRM link"}
                      </div>
                      <div style={{ fontSize: 13, color: T.slate800, marginTop: 4 }}>{noteCell(r)}</div>
                      {view === "checked" && r.outcome && <div style={{ fontSize: 12, marginTop: 4 }}>{checkedLine(r)}</div>}
                      <div style={{ display: "flex", flexWrap: "wrap", rowGap: 6, alignItems: "center", marginTop: 6, fontSize: 13 }}>{rowActions(r)}</div>
                    </div>
                  ))}
                </div>
              ) : (
              <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
                <table style={{ width: "100%", borderCollapse: "collapse" }}>
                  <thead><tr><th style={tableTh}>Who</th><th style={tableTh}>Date</th><th style={tableTh}>What</th><th style={tableTh}>Note</th><th style={tableTh}>ECRM</th><th style={tableTh}>Points</th>{view === "checked" && <th style={tableTh}>Checked</th>}<th style={tableTh}></th></tr></thead>
                  <tbody>
                    {h.entries.map(r => (
                      <tr key={r.id}>
                        <td style={tableTd}>{r.first_name || "—"}</td>
                        <td style={{ ...tableTd, whiteSpace: "nowrap" }}>{fmtDate(r.occurred_on)}</td>
                        <td style={tableTd}>{r.label || r.activity_key}</td>
                        <td style={{ ...tableTd, maxWidth: 260 }}>{noteCell(r)}</td>
                        <td style={{ ...tableTd, whiteSpace: "nowrap" }}>
                          {r.ecrm_url ? <a href={r.ecrm_url} target="ecrm" rel="noreferrer" style={{ color: T.blue }}>ECRM</a>
                            : <span style={{ color: T.slate300 }}>—</span>}
                        </td>
                        <td style={tableTd}>{worth(r)}</td>
                        {view === "checked" && <td style={{ ...tableTd, whiteSpace: "nowrap" }}>{checkedLine(r)}</td>}
                        <td style={{ ...tableTd, whiteSpace: "nowrap" }}>{rowActions(r)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              )}
            </div>
          ))}
        </div>
      )}
      {editing && (
        <Modal title="Editing a record already on file" onClose={() => { setEditing(null); setTick(t => t + 1); }}>
          <RecordEditor target={editing} values={values} sources={sources} types={types} isOwner={isOwner}
            roster={roster} onLogged={() => setTick(t => t + 1)} refreshKey={tick}
            onClose={() => { setEditing(null); setTick(t => t + 1); }} />
        </Modal>
      )}
      {msg && <Notice kind="ok">{msg}</Notice>}
      {converting && (
        <CancelationConvert row={converting} types={types} pool={[...rows, ...flags]} onClose={() => setConverting(null)}
          onDone={(mm) => { setConverting(null); setMsg(mm); setTick(t => t + 1); }} />
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
const SALE_SELECT = "id, team_member_id, created_at, can_change:rp_sale_can_change, can_edit:rp_sale_edit_ok, can_note:rp_sale_can_note, submitted_date, week_end_date, customer_label, customer_first_name, customer_last_initial, customer_kind, phone_last4, household_status, marketing_source, vehicle_count, total_premium, note, ecrm_opportunity_url, on_file_answer, entry_source, sales_log_products(id, line_of_business, product_type, premium, policy_count, vehicle_count, is_new_line, is_added_to_existing, issued_date, issued_premium, autopay_enrolled, can_reissue:rp_issue_change_ok, can_autopay:rp_autopay_ok)";
const APPT_SELECT = "id, team_member_id, created_at, can_change:rp_appt_can_change, can_mark:rp_appt_mark_ok, can_note:rp_appt_can_note, escalated_to_team_member_id, set_on, week_end_date, kept_on, no_show_on, sold_on, customer_label, customer_first_name, customer_last_initial, customer_kind, phone_last4, line_of_business, product_type, starts_at, duration_minutes, is_video, meet_url, calendar_error, note, ecrm_url";
const ACT_SELECT = "id, team_member_id, created_at, can_change:rp_act_can_change, can_note:rp_act_can_note, activity_key, occurred_on, customer_label, customer_first_name, customer_last_initial, customer_kind, phone_last4, note, points, source, policy_line, product_type, premium, credit_available_on, ecrm_url";
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
const fmtWhen = (iso) => {
  const d = iso ? new Date(iso) : null;
  return d && !isNaN(d)
    ? d.toLocaleString("en-US", { timeZone: "America/Chicago", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })
    : "—";
};
const howFarOff = (iso) => {
  const d = iso ? new Date(iso) : null;
  if (!d || isNaN(d)) return "";
  const days = Math.round((d - new Date()) / 86400000);
  if (days > 1) return `in ${days}d`;
  if (days === 1) return "tomorrow";
  if (days === 0) return "today";
  return `${-days}d ago`;
};

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
  const [logging, setLogging] = useState(null);   // appointment whose sale is being logged

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
          // Points are earned the week a policy ISSUES, not the week it was
          // written (Peter 2026-09-16). Keyed on the submitted week, this card
          // showed policies that were not earning yet and hid ones that were.
          const iss = await supabase.from("sales_log_products").select("sales_log_id")
            .eq("agency_id", AGENCY_ID).gte("issued_date", addDays(weekEnd, -6)).lte("issued_date", weekEnd);
          if (iss.error) throw iss.error;
          const ids = Array.from(new Set((iss.data || []).map(r => r.sales_log_id)));
          if (!ids.length) { setRows([]); return; }
          q = q.in("id", ids);
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
        // Soonest first while it is still waiting; newest first once the week is done.
        const r = await q.order("starts_at", { ascending: scope === "pending", nullsFirst: false });
        if (r.error) throw r.error;
        setRows(Array.isArray(r.data) ? r.data : []);
      } else {
        let q = supabase.from("retention_activity_now").select(ACT_SELECT).eq("agency_id", AGENCY_ID).eq("status", "active");
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
    if (data.off_calendar === false) {
      setErr(`Deleted here, but it is still on the calendar: ${data.calendar_error || "the calendar did not answer"}. Take it off by hand.`);
    } else if (data.off_calendar === true) {
      setDone("Deleted, and taken off the calendar.");
    }
    after();
  };

  const emptyWord = scope === "pending"
    ? { sales: "Everything submitted has been issued. Nothing waiting.", appointments: "No appointments still open.", activities: "Nothing still counting down." }[kind]
    : { sales: "Nothing issued this week.", appointments: "No appointments set this week.", activities: "No activities logged this week." }[kind];

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
                <th style={tableTh}>When</th><th style={tableTh}>Who</th><th style={tableTh}>Handed to</th>
                <th style={tableTh}>Customer</th><th style={tableTh}>About</th><th style={tableTh}>State</th><th style={tableTh}>Move it along</th>
                <th style={tableTh}>Set</th><th style={tableTh}>Note</th><th style={tableTh}></th>
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
                    <td style={tableTd}><CustomerName label={r.customer_label} phone4={r.phone_last4} />{r.phone_last4 ? <div style={{ fontSize: 11, color: T.slate400 }}>·{r.phone_last4}</div> : null}</td>
                    <td style={tableTd}>
                      {relationshipLabel(r.household_status)}
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
                              <input type="checkbox" checked={!!p.autopay_enrolled} disabled={busy === p.id || p.can_autopay === false}
                                onChange={e => setAutopay(p.id, e.target.checked)} />
                              Autopay
                            </label>
                          )}
                          {p.issued_date ? (
                            <span style={{ fontSize: 11, color: T.green }}>
                              issued {fmtDate(p.issued_date)}{p.issued_premium != null ? ` · $${fmtPts(p.issued_premium)}` : ""}
                              {p.can_reissue && <button type="button" style={{ ...miniBtn, marginLeft: 6 }} onClick={() => unIssue(p)}>Undo</button>}
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
                      <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
                        {r.can_edit && <button type="button" style={miniBtn} onClick={() => setEditing({ kind: "sale", row: r })}>Edit</button>}
                        {r.can_change && <button type="button" style={{ ...miniBtn, color: T.red }} onClick={() => removeRow("sale", r.id, "sale")}>Delete</button>}
                        {!r.can_change && r.can_note && <AddNoteButton kind="sale" id={r.id} onSaved={after} />}
                      </div>
                    </td>
                  </tr>
                );
              })}

              {kind === "appointments" && rows.map(r => {
                const escalated = r.escalated_to_team_member_id && r.escalated_to_team_member_id !== r.team_member_id;
                return (
                  <tr key={r.id}>
                    <td style={tableTd}>
                      {fmtWhen(r.starts_at)}
                      <div style={{ fontSize: 11, color: T.slate400 }}>
                        {howFarOff(r.starts_at)}{r.is_video ? " · Google Meet" : ""}
                      </div>
                      {r.calendar_error
                        ? <div style={{ fontSize: 11, color: T.red }}>not on the calendar: {r.calendar_error}</div>
                        : null}
                    </td>
                    <td style={tableTd}>{nameOf(r.team_member_id)}</td>
                    <td style={tableTd}>
                      {escalated ? nameOf(r.escalated_to_team_member_id)
                        : <span style={{ color: T.slate400 }} title="An appointment you keep for yourself pays nothing here. It pays through the sale.">kept it</span>}
                    </td>
                    <td style={tableTd}><CustomerName label={r.customer_label} phone4={r.phone_last4} />{r.phone_last4 ? <div style={{ fontSize: 11, color: T.slate400 }}>·{r.phone_last4}</div> : null}</td>
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
                      {r.can_mark ? (
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
                    <td style={tableTd}>{fmtDate(r.set_on)}</td>
                    <td style={tableTd}>{r.note || "—"}</td>
                    <td style={tableTd}>
                      <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
                        {canTouch(apptHost(r)) && !r.sold_on && (
                          <button type="button" style={miniBtn} onClick={() => setLogging(r)}>Log the sale</button>
                        )}
                        {r.can_change && (
                          <>
                            <button type="button" style={miniBtn} onClick={() => setEditing({ kind: "appointment", row: r })}>Edit</button>
                            <button type="button" style={{ ...miniBtn, color: T.red }} onClick={() => removeRow("appointment", r.id, "appointment")}>Delete</button>
                          </>
                        )}
                        {!r.can_change && r.can_note && <AddNoteButton kind="appointment" id={r.id} onSaved={after} />}
                      </div>
                    </td>
                  </tr>
                );
              })}

              {kind === "activities" && rows.map(r => (
                <tr key={r.id}>
                  <td style={tableTd}>{fmtDate(r.occurred_on)}</td>
                  <td style={tableTd}>{nameOf(r.team_member_id)}</td>
                  <td style={tableTd}><CustomerName label={r.customer_label} phone4={r.phone_last4} />{r.phone_last4 ? <div style={{ fontSize: 11, color: T.slate400 }}>·{r.phone_last4}</div> : null}</td>
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
                    {r.can_change && r.source === "manual" && (
                      <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
                        <button type="button" style={miniBtn} onClick={() => setEditing({ kind: "activity", row: r })}>Edit</button>
                        <button type="button" style={{ ...miniBtn, color: T.red }} onClick={() => removeRow("activity", r.id, "entry")}>Delete</button>
                      </div>
                    )}
                    {!r.can_change && r.source === "manual" && r.can_note && <AddNoteButton kind="activity" id={r.id} onSaved={after} />}
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
          onSaved={(who, d) => {
            setAdding(false); setKind("appointments");
            setDone(`Appointment set with ${who}.` + (d?.on_calendar
              ? " It is on the calendar."
              : ` It is not on the calendar: ${d?.calendar_error || "the calendar did not answer"}.`));
            after();
          }} />
      )}

      {logging && (
        <Modal title={`What came off the appointment with ${logging.customer_label}`} onClose={() => setLogging(null)}>
          <EntryPage values={values} sources={sources} types={types} isOwner={isOwner} roster={roster}
            refreshKey={refreshKey} appointment={logging} onLogged={after} />
        </Modal>
      )}

      {editing && (
        <EditRecord
          kind={editing.kind} row={editing.row} sources={sources} types={types} roster={roster} isOwner={isOwner}
          onClose={() => setEditing(null)}
          onSaved={(d) => {
            setEditing(null);
            setDone("Saved." + (d?.on_calendar === false
              ? ` The calendar did not move with it: ${d.calendar_error || "the calendar did not answer"}.`
              : d?.on_calendar === true ? " The calendar moved with it." : ""));
            after();
          }}
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
  const [f, setF] = useState({ customer_first: "", customer_last_initial: "", customer_kind: "person", phone_last4: "", set_on: todayCentral(),
    when_date: todayCentral(), when_time: "10:00", duration_minutes: "30", is_video: false,
    escalated_to: "", line_of_business: "", product_type: "", note: "" });
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState("");
  const set = (k, v) => setF(d => ({ ...d, [k]: v }));

  const save = async () => {
    const startsAt = centralIso(f.when_date, f.when_time);
    if (!startsAt) { setErr("When is the appointment?"); return; }
    setSaving(true); setErr("");
    const { data, error } = await supabase.rpc("rp_log_appointment", {
      p_payload: {
        customer_first: f.customer_first, customer_last_initial: f.customer_last_initial, customer_kind: f.customer_kind,
        phone_last4: f.phone_last4, set_on: f.set_on,
        line_of_business: f.line_of_business, product_type: f.product_type || null,
        starts_at: startsAt, duration_minutes: f.duration_minutes, is_video: !!f.is_video,
        escalated_to_team_member_id: f.escalated_to || null, note: f.note,
      },
    });
    setSaving(false);
    if (error || !data?.ok) { setErr(errText(error || data)); return; }
    onSaved(data.customer || f.customer_first, data);
  };

  return (
    <Modal title="Set an appointment" onClose={onClose}>
      <div style={{ ...cardStyle, display: "grid", gap: 12 }}>
        {err && <Notice kind="error">{err}</Notice>}
        <div style={gridForm}>
          <div>
            <label style={labelStyle}>Customer</label>
            <KindToggle value={f.customer_kind}
              onChange={k => setF(d => ({ ...d, customer_kind: k, customer_last_initial: k === "org" ? "" : d.customer_last_initial }))} />
          </div>
          <div>
            <label style={labelStyle}>{f.customer_kind === "org" ? "Organization" : "First name"}</label>
            <input value={f.customer_first} onChange={e => set("customer_first", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }} {...noPwManager("afn")} />
          </div>
          {f.customer_kind !== "org" && (
            <div>
              <label style={labelStyle}>Last initial</label>
              <input value={f.customer_last_initial} maxLength={1} onChange={e => set("customer_last_initial", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }} {...noPwManager("ali")} />
            </div>
          )}
          <div>
            <label style={labelStyle}>Phone, last four</label>
            <input value={f.phone_last4} maxLength={4} inputMode="numeric" onChange={e => set("phone_last4", e.target.value.replace(/\D/g, ""))} style={{ ...smallInput, width: "100%", padding: "9px 10px" }} {...noPwManager("ap4")} />
          </div>
          <div>
            <label style={labelStyle}>Date set</label>
            <input type="date" value={f.set_on} max={todayCentral()} onChange={e => set("set_on", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }} />
          </div>
          <div>
            <label style={labelStyle}>Appointment date</label>
            <input type="date" value={f.when_date} min={todayCentral()} onChange={e => set("when_date", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }} />
          </div>
          <div>
            <label style={labelStyle}>Time <span style={hintStyle}>San Antonio</span></label>
            <input type="time" value={f.when_time} onChange={e => set("when_time", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }} />
          </div>
          <div>
            <label style={labelStyle}>How long</label>
            <select value={f.duration_minutes} onChange={e => set("duration_minutes", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }}>
              <option value="15">15 minutes</option>
              <option value="30">30 minutes</option>
              <option value="45">45 minutes</option>
              <option value="60">1 hour</option>
            </select>
          </div>
          <div>
            <label style={labelStyle}>Where</label>
            <select value={f.is_video ? "video" : "office"} onChange={e => set("is_video", e.target.value === "video")} style={{ ...smallInput, width: "100%", padding: "9px 10px" }}>
              <option value="office">In the office</option>
              <option value="video">Google Meet</option>
            </select>
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
function EditRecord({ kind, row, sources, types, roster, isOwner, onClose, onSaved, bare = false }) {
  const [f, setF] = useState(() => ({
    customer_first: row.customer_first_name || "",
    customer_last_initial: row.customer_last_initial || "",
    customer_kind: row.customer_kind || "person",
    phone_last4: row.phone_last4 || "",
    on_date: row.submitted_date || row.set_on || row.occurred_on || todayCentral(),
    relationship: row.household_status || "existing",
    marketing_source: row.marketing_source || "",
    escalated_to: row.escalated_to_team_member_id || "",
    appt_line: row.line_of_business || "",
    appt_type: row.product_type || "",
    appt_when_date: centralParts(row.starts_at).date,
    appt_when_time: centralParts(row.starts_at).time,
    appt_minutes: String(row.duration_minutes || 30),
    appt_video: !!row.is_video,
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
        customer_first: f.customer_first, customer_last_initial: f.customer_last_initial, customer_kind: f.customer_kind, phone_last4: f.phone_last4,
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
        customer_first: f.customer_first, customer_last_initial: f.customer_last_initial, customer_kind: f.customer_kind, phone_last4: f.phone_last4,
        set_on: f.on_date, escalated_to_team_member_id: f.escalated_to || null, note: f.note,
        line_of_business: f.appt_line, product_type: f.appt_type || null,
        starts_at: centralIso(f.appt_when_date, f.appt_when_time),
        duration_minutes: f.appt_minutes, is_video: !!f.appt_video,
      };
    } else {
      fn = "rp_edit_activity";
      changes = {
        customer_first: f.customer_first, customer_last_initial: f.customer_last_initial, customer_kind: f.customer_kind, phone_last4: f.phone_last4,
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
    onSaved(data);
  };

  const titleWord = kind === "sale" ? "sale" : kind === "appointment" ? "appointment" : "entry";
  // Peter 2026-09-22: after the day a sale was entered, only its policies that
  // have not issued can be fixed. The server enforces it; this greys the rest.
  const limited = kind === "sale" && row.can_change === false;
  // bare drops the popup shell, for when this is opened inside one already.
  const body = (
      <div style={{ ...cardStyle, display: "grid", gap: 12 }}>
        {err && <Notice kind="error">{err}</Notice>}
        {limited && (
          <div style={{ fontSize: 13, color: T.slate600 }}>
            Only policies that have not issued can be changed now. Notes stay as written. Use Add note to add one.
          </div>
        )}
        {kind === "sale" && row.entry_source === "historical_backfill" && (
          <div style={{ justifySelf: "start", padding: "3px 9px", borderRadius: 999, background: T.amberLt, color: T.amber, fontSize: 12, fontWeight: 700 }}>
            Saving moves this out of the historical load and into the production log
          </div>
        )}
        <div style={gridForm}>
          <div>
            <label style={labelStyle}>Customer</label>
            <KindToggle value={f.customer_kind}
              onChange={k => setF(d => ({ ...d, customer_kind: k, customer_last_initial: k === "org" ? "" : d.customer_last_initial }))} />
          </div>
          <div>
            <label style={labelStyle}>{f.customer_kind === "org" ? "Organization" : "First name"}</label>
            <input value={f.customer_first} onChange={e => set("customer_first", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }} {...noPwManager("efn")} />
          </div>
          {f.customer_kind !== "org" && (
            <div>
              <label style={labelStyle}>Last initial</label>
              <input value={f.customer_last_initial} maxLength={1} onChange={e => set("customer_last_initial", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }} {...noPwManager("eli")} />
            </div>
          )}
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
              <label style={labelStyle}>Appointment date</label>
              <input type="date" value={f.appt_when_date} onChange={e => set("appt_when_date", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }} />
            </div>
          )}
          {kind === "appointment" && (
            <div>
              <label style={labelStyle}>Time <span style={hintStyle}>San Antonio</span></label>
              <input type="time" value={f.appt_when_time} onChange={e => set("appt_when_time", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }} />
            </div>
          )}
          {kind === "appointment" && (
            <div>
              <label style={labelStyle}>How long</label>
              <select value={f.appt_minutes} onChange={e => set("appt_minutes", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px" }}>
                <option value="15">15 minutes</option>
                <option value="30">30 minutes</option>
                <option value="45">45 minutes</option>
                <option value="60">1 hour</option>
              </select>
            </div>
          )}
          {kind === "appointment" && (
            <div>
              <label style={labelStyle}>Where</label>
              <select value={f.appt_video ? "video" : "office"} onChange={e => set("appt_video", e.target.value === "video")} style={{ ...smallInput, width: "100%", padding: "9px 10px" }}>
                <option value="office">In the office</option>
                <option value="video">Google Meet</option>
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
          <div key={p.id || i} style={limited && p.issued_date ? { ...policyRow, opacity: 0.55, pointerEvents: "none" } : policyRow}>
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
            {hasCars(p.line_of_business, p.product_type) && (
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
                  <option value="new">New Policy</option>
                  <option value="added">Added to Policy</option>
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
          <input value={f.note} readOnly={limited} onChange={e => set("note", e.target.value)} style={{ ...smallInput, width: "100%", padding: "9px 10px", ...(limited ? { background: T.slate50, color: T.slate500 } : {}) }} {...noPwManager("enote")} />
        </div>

        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <button type="button" style={btnPrimary(saving)} disabled={saving} onClick={save}>{saving ? "Saving…" : "Save changes"}</button>
          <button type="button" style={btnGhost} onClick={onClose}>Cancel</button>
        </div>
      </div>
  );
  return bare ? body : <Modal title={`Edit this ${titleWord}`} onClose={onClose}>{body}</Modal>;
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


// Peter 2026-09-22: once a record is closed, the person it belongs to can still add
// a note. Earlier notes stay as written; the server dates and names the new one.
function AddNoteButton({ kind, id, onSaved }) {
  const [open, setOpen] = useState(false);
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const close = () => { setOpen(false); setText(""); setErr(""); };
  const save = async () => {
    if (!text.trim()) { setErr("Write the note first."); return; }
    setBusy(true); setErr("");
    const { data, error } = await supabase.rpc("rp_add_note", { p_kind: kind, p_id: id, p_note: text.trim() });
    setBusy(false);
    if (error || !data?.ok) { setErr(errText(error || data)); return; }
    close();
    if (onSaved) onSaved(data);
  };
  return (
    <>
      <button type="button" style={miniBtn} onClick={() => setOpen(true)}>Add note</button>
      {open && (
        <Modal title="Add a note" onClose={close}>
          <div style={{ ...cardStyle, display: "grid", gap: 10 }}>
            {err && <Notice kind="error">{err}</Notice>}
            <textarea value={text} onChange={e => setText(e.target.value)} rows={4} autoFocus
              style={{ ...smallInput, width: "100%", padding: "9px 10px", fontFamily: "inherit", resize: "vertical" }} />
            <div style={{ fontSize: 12, color: T.slate500 }}>It is added under the notes already there, with today's date and your name.</div>
            <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
              <button type="button" style={btnPrimary(busy)} disabled={busy} onClick={save}>{busy ? "Saving…" : "Add note"}</button>
              <button type="button" style={btnGhost} onClick={close}>Cancel</button>
            </div>
          </div>
        </Modal>
      )}
    </>
  );
}

function Modal({ title, onClose, children }) {
  return (
    <div onClick={onClose} style={{ position: "fixed", inset: 0, background: "rgba(15,23,42,0.45)", zIndex: 160, display: "flex", alignItems: "flex-start", justifyContent: "center", padding: "24px 8px", overflowY: "auto" }}>
      <div onClick={e => e.stopPropagation()} style={{ background: T.slate50, borderRadius: 14, width: "min(980px, 100%)", maxWidth: "100%", minWidth: 0, boxSizing: "border-box", boxShadow: "0 20px 60px rgba(0,0,0,0.25)", padding: 12, overflowX: "hidden" }}>
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
// The plain-English field names, the bookkeeping columns that are hidden, and
// the way a stored value reads are all decided in the database by
// change_field_label, change_field_hidden and change_value_text. They arrive
// already done in the `changes` column and are drawn by ChangeDiffs.
const CHANGE_WINDOWS = [
  { days: 7,  label: "Last 7 days" },
  { days: 30, label: "Last 30 days" },
  { days: 90, label: "Last 90 days" },
];

const RESTORE_KIND = {
  sales_log: "sale",
  quote_log: "quote",
  retention_activity_log: "activity",
  appointment_log: "appointment",
  cancelation_log: "cancelation",
};
// Which record a change belongs to, so Edit can open the original (Peter
// 2026-09-19). A change on a policy line opens the sale it sits on; a change on
// a quoted product opens the quote. The change history itself is never editable
// by anyone; editing the original writes a fresh change of its own.
const EDIT_TARGET = (r) => {
  const nw = r.new_row || {};
  const od = r.old_row || {};
  switch (r.table_name) {
    case "sales_log":              return { kind: "sale", id: r.row_id };
    case "sales_log_products":     return { kind: "sale", id: nw.sales_log_id || od.sales_log_id || null };
    case "quote_log":              return { kind: "quote", id: r.row_id };
    case "quote_log_products":     return { kind: "quote", id: nw.quote_log_id || od.quote_log_id || null };
    case "retention_activity_log": return { kind: "activity", id: r.row_id };
    case "cancelation_log":        return { kind: "cancelation", id: r.row_id };
    case "appointment_log":        return { kind: "appointment", id: r.row_id };
    case "fit_scorecards":         return { kind: "scorecard", id: r.row_id };
    default:                       return null;
  }
};
const sortHead = { border: "none", background: "transparent", padding: 0, font: "inherit", fontWeight: 700, color: "inherit", cursor: "pointer", whiteSpace: "nowrap" };

function changeWhen(ts) {
  const d = new Date(ts);
  return isNaN(d) ? "—" : d.toLocaleString("en-US", { timeZone: "America/Chicago", month: "numeric", day: "numeric", hour: "numeric", minute: "2-digit" });
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

// One week at a time, Sunday to Saturday, arrows to move (Peter 2026-09-21:
// the change log is for the week, not the day). Reads the same
// production_changes_for_range call the CPR makes — the week's changes plus any
// later change to a policy that issued that week — and draws it with the same
// ChangeGroups, so the two read the same way. Each change is filed under the
// CPR week whose sales points it moved (cpr_week_for in the database): a
// Sunday fix before last week's CPR goes out lands on last week. The Telegram link still lands
// here with ?tab=changes&day=YYYY-MM-DD: the module shell turns that into History, which
// opens Notes (the first kind, where the Changes group used to open) on that day's week.
function weekStartOf(iso) {
  const d = new Date(`${iso}T12:00:00`);
  return addDays(iso, -d.getDay());
}
function ChangeWeek({ day, setDay, kind, isAdmin, myTeamId, onCounts }) {
  const start = weekStartOf(day);
  const end = addDays(start, 6);
  const [rows, setRows] = useState(null);
  const [err, setErr] = useState("");
  useEffect(() => {
    let alive = true;
    (async () => {
      setErr(""); setRows(null);
      const r = await supabase.rpc("production_changes_for_range", {
        p_agency_id: AGENCY_ID, p_start: start, p_end: end, p_by_cpr_week: true,
      });
      if (!alive) return;
      if (r.error) { setErr(errText(r.error)); setRows([]); return; }
      setRows(Array.isArray(r.data) ? r.data : []);
    })();
    return () => { alive = false; };
  }, [start, end]);

  const today = todayCentral();
  const thisWeek = weekStartOf(today);
  const arrow = { ...btnGhost, padding: "6px 12px", fontSize: 15, lineHeight: 1 };
  // A teammate sees only the changes to their own entries; managers see all
  // (Peter 2026-09-21). Their own group sits at the top, then fewest to most.
  const mine = useMemo(() => (rows || []).filter(l => isAdmin || l.owner_id === myTeamId), [rows, isAdmin, myTeamId]);
  const kindOf = (l) => l.kind || "change";
  const list = mine.filter(l => kindOf(l) === kind);
  const counts = useMemo(() => ({
    change: mine.filter(l => kindOf(l) === "change").length,
    issue: mine.filter(l => kindOf(l) === "issue").length,
    canceled: mine.filter(l => kindOf(l) === "canceled").length,
    spot_check: mine.filter(l => kindOf(l) === "spot_check").length,
  }), [mine]); // eslint-disable-line react-hooks/exhaustive-deps
  // The counts show on the History sub-tabs now (Peter 2026-09-25).
  useEffect(() => { if (onCounts) onCounts(rows ? counts : {}); }, [rows, counts, onCounts]);
  const groups = groupChangesByOwner(list, null, myTeamId);
  return (
    <div style={cardStyle}>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center", justifyContent: "space-between", marginBottom: 12 }}>
        <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900 }}>
          {start === thisWeek ? <>This week <span style={{ color: T.slate500, fontWeight: 600, fontSize: 13 }}>&middot; </span></> : null}
          {fmtDate(start)} to {fmtDate(end)}
        </div>
        <div style={{ display: "flex", gap: 6, alignItems: "center" }}>
          <button style={arrow} onClick={() => setDay(addDays(start, -7))} aria-label="previous week">&lsaquo;</button>
          <input type="date" style={{ ...inputBase, width: "auto", fontSize: 13, padding: "6px 10px" }} value={day} max={today}
            onChange={e => { if (e.target.value) setDay(e.target.value); }} />
          <button style={arrow} disabled={start >= thisWeek} onClick={() => setDay(addDays(start, 7))} aria-label="next week">&rsaquo;</button>
        </div>
      </div>
      {err && <Notice kind="error">{err}</Notice>}
      {rows === null ? (
        <div style={{ color: T.slate500, fontSize: 13 }}>Loading&hellip;</div>
      ) : groups.length === 0 ? (
        <div style={{ color: T.slate600, fontSize: 14 }}>
          {kind === "issue" ? "No policies were issued or un-issued this week."
            : kind === "canceled" ? "No cancelations this week."
            : kind === "spot_check" ? "No notes this week."
            : "Nothing was edited or removed this week."}
        </div>
      ) : (
        <ChangeGroups groups={groups} kind={kind} maxHeight={null} />
      )}
    </div>
  );
}

// kind = which of the four kinds shows. It is picked by the History sub-tab
// now (Peter 2026-09-25); the kinds are still kept apart, Notes first
// (2026-09-21). onCounts hands each kind's count up to the sub-tab labels.
function ChangesTab({ kind, onCounts, roster, nameOf, values, sources, types, isOwner, isAdmin, myTeamId, refreshKey, onChanged }) {
  const [day, setDay] = useTabParam("day", "");
  const [view, setView] = useState("day");
  const [days, setDays] = useState(30);
  const [who, setWho] = useState("");
  const [rows, setRows] = useState(null);
  const [err, setErr] = useState("");
  const [busyId, setBusyId] = useState(null);
  const [reload, setReload] = useState(0);
  const [editing, setEditing] = useState(null);
  const [flash, setFlash] = useState("");
  // Newest first is how the list reads by default. Click a heading to sort.
  const [sort, setSort] = useState({ by: "", dir: "desc" });
  const labelOf = useMemo(() => Object.fromEntries((values || []).map(v => [v.activity_key, v.label])), [values]);
  const ctx = useMemo(() => ({ nameOf, labelOf, types: types || {} }), [nameOf, labelOf, types]);

  useEffect(() => {
    let alive = true;
    (async () => {
      if (!isAdmin) { setRows([]); return; }
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

  const closeEdit = (msg) => {
    setEditing(null);
    setFlash(msg || "");
    setReload(n => n + 1);
    if (msg && onChanged) onChanged();
  };

  const sortBy = (by) => setSort(s => s.by === by
    ? { by, dir: s.dir === "asc" ? "desc" : "asc" }
    : { by, dir: by === "when" ? "desc" : "asc" });
  const sortArrow = (by) => sort.by !== by ? "" : sort.dir === "asc" ? " \u25B2" : " \u25BC";

  // Which toggle a history row shows under. A row can land under more than
  // one: a policy line that was issued and had its phone filled in shows the
  // issue under Issued policies and the phone under Changes.
  const hasKind = (r, k) => {
    // A cancelation being logged sits under Canceled.
    if (r.table_name === "cancelation_log" && r.action === "insert") return k === "canceled";
    return r.action !== "update" ? k === "change" : changeDiffList(r.changes).some(c => changeItemKind(c) === k);
  };
  const inKind = (r) => hasKind(r, kind);
  const onlyKind = (c) => changeItemKind(c) === kind;
  const kindCounts = useMemo(() => ({
    change: (rows || []).filter(r => hasKind(r, "change")).length,
    issue: (rows || []).filter(r => hasKind(r, "issue")).length,
    canceled: (rows || []).filter(r => hasKind(r, "canceled")).length,
    spot_check: (rows || []).filter(r => hasKind(r, "spot_check")).length,
  }), [rows]); // eslint-disable-line react-hooks/exhaustive-deps

  const shown = useMemo(() => {
    const list = (rows || []).filter(inKind);
    if (!sort.by) return list;
    const keyOf = (r) => {
      if (sort.by === "when") return String(r.changed_at || "");
      if (sort.by === "who") return String(r.who || "").toLowerCase();
      if (sort.by === "what") return (changeEvents(r.changes).filter(onlyKind).map(c => c.label).join(" ") || `${r.item || ""} ${r.action || ""}`).toLowerCase();
      return String(r.subject || "").toLowerCase();
    };
    const dir = sort.dir === "asc" ? 1 : -1;
    return [...list].sort((a, b) => {
      const x = keyOf(a), y = keyOf(b);
      return x < y ? -dir : x > y ? dir : 0;
    });
  }, [rows, sort, kind]); // eslint-disable-line react-hooks/exhaustive-deps

  // The every-change list sends its counts up to the sub-tab labels; the week
  // view's ChangeWeek sends its own. Leaving these sub-tabs clears them.
  useEffect(() => { if (view === "all" && onCounts) onCounts(rows ? kindCounts : {}); }, [view, rows, kindCounts, onCounts]);
  useEffect(() => () => { if (onCounts) onCounts({}); }, [onCounts]);

  if (view === "day") {
    return (
      <div style={{ display: "grid", gap: 12 }}>
        <div style={{ display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center", justifyContent: "space-between" }}>
          <div style={{ fontSize: 13, color: T.slate500 }}>{isAdmin
            ? "Edits, removals, issued policies, cancelations and spot-check notes, one week at a time, by whose entry it is."
            : "Changes made to your entries, one week at a time."}</div>
          {isAdmin ? <button style={btnGhost} onClick={() => setView("all")}>See every change</button> : null}
        </div>
        <ChangeWeek day={day || todayCentral()} setDay={setDay} kind={kind} isAdmin={isAdmin} myTeamId={myTeamId} onCounts={onCounts} />
      </div>
    );
  }

  return (
    <div style={{ display: "grid", gap: 12 }}>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 10, alignItems: "center", justifyContent: "space-between" }}>
        <div style={{ fontSize: 13, color: T.slate500 }}>Who changed what, and when. Everything on this module, newest first.</div>
        <div style={{ display: "flex", gap: 8 }}>
          <button style={btnGhost} onClick={() => setView("day")}>Back to one week</button>
          <select value={who} onChange={e => setWho(e.target.value)} style={selectStyle}>
            <option value="">Everyone</option>
            {roster.map(t => <option key={t.id} value={t.id}>{t.first_name}</option>)}
          </select>
          <select value={days} onChange={e => setDays(Number(e.target.value))} style={selectStyle}>
            {CHANGE_WINDOWS.map(w => <option key={w.days} value={w.days}>{w.label}</option>)}
          </select>
        </div>
      </div>
      {flash && <Notice kind="ok">{flash}</Notice>}
      {err && <Notice kind="error">{err}</Notice>}
      {rows === null ? (
        <div style={{ ...cardStyle, color: T.slate500, fontSize: 13 }}>Loading…</div>
      ) : shown.length === 0 ? (
        <div style={{ ...cardStyle, color: T.slate600, fontSize: 14 }}>{kind === "issue" ? `No policies issued or un-issued in the last ${days} days.` : kind === "canceled" ? `No cancelations in the last ${days} days.` : kind === "spot_check" ? `No notes in the last ${days} days.` : `No changes in the last ${days} days.`}</div>
      ) : (
        <div style={{ ...cardStyle, overflowX: "auto" }}>
          <table style={{ width: "100%", borderCollapse: "collapse" }}>
            <thead>
              <tr>
                <th style={tableTh}><button type="button" style={sortHead} onClick={() => sortBy("when")}>When{sortArrow("when")}</button></th>
                <th style={tableTh}><button type="button" style={sortHead} onClick={() => sortBy("who")}>Who{sortArrow("who")}</button></th>
                <th style={tableTh}><button type="button" style={sortHead} onClick={() => sortBy("what")}>What{sortArrow("what")}</button></th>
                <th style={tableTh}><button type="button" style={sortHead} onClick={() => sortBy("customer")}>Customer{sortArrow("customer")}</button></th>
                <th style={tableTh}>Details</th>
                <th style={tableTh} />
              </tr>
            </thead>
            <tbody>
              {shown.map((r, i) => {
                // The "same click" marks only make sense while the list is in
                // its own order, so they drop away once a heading is sorted.
                const sameClick = !sort.by && i > 0 && shown[i - 1].txid === r.txid;
                const target = EDIT_TARGET(r);
                const canEdit = !!(target && target.id && r.action !== "delete" && statusNow.get(r.row_id) !== "void");
                return (
                  <tr key={r.id} style={sameClick ? { background: T.slate50 } : undefined}>
                    <td style={{ ...tableTd, whiteSpace: "nowrap", fontWeight: sameClick ? 400 : 700, color: sameClick ? T.slate300 : T.blue }}>{sameClick ? "〃" : changeWhen(r.changed_at)}</td>
                    <td style={{ ...tableTd, whiteSpace: "nowrap", color: sameClick ? T.slate300 : T.slate800 }}>{sameClick ? "〃" : r.who}</td>
                    <td style={{ ...tableTd, whiteSpace: "nowrap" }}>
                      {/* A named event (Policy issued, Sale removed...) says what happened
                          better than "Changed sold policy" does. */}
                      {changeEvents(r.changes).filter(onlyKind).length ? (
                        changeEvents(r.changes).filter(onlyKind).map((c, k) => (
                          <div key={c.field + k} style={{ fontWeight: 700, color: changeTone(c) }}>{c.label}</div>
                        ))
                      ) : (
                        <><span style={{ fontWeight: 700, color: r.action === "delete" ? T.red : r.action === "update" ? T.amber : T.green }}>{verb[r.action] || r.action}</span> {r.item === "FIT scorecard" ? r.item : r.item.toLowerCase()}</>
                      )}
                    </td>
                    <td style={tableTd}><CustomerName label={r.subject} phone4={r.phone_last4} />{r.phone_last4 ? <div style={{ fontSize: 11, color: T.slate400 }}>·{r.phone_last4}</div> : null}</td>
                    <td style={{ ...tableTd, maxWidth: 420 }}>
                      {r.action === "update" ? (
                        changeDiffList(r.changes).filter(onlyKind).some(c => !c.event || c.after)
                          ? <ChangeDiffs changes={r.changes} eventsAsDetail only={onlyKind} />
                          : <span style={{ color: T.slate500 }}>&mdash;</span>
                      ) : changeSummary(r, ctx)}
                    </td>
                    <td style={{ ...tableTd, textAlign: "right", whiteSpace: "nowrap" }}>
                      {removedHere(r) ? (
                        <button type="button" style={miniBtn} disabled={busyId === r.id} onClick={() => restore(r)}>
                          {busyId === r.id ? "Putting back…" : "Restore"}
                        </button>
                      ) : canEdit ? (
                        <button type="button" style={miniBtn} onClick={() => { setFlash(""); setEditing(target); }}>Edit</button>
                      ) : null}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
      {editing && (
        <Modal title="Editing a record already on file" onClose={() => closeEdit("")}>
          <RecordEditor target={editing} values={values} sources={sources} types={types} isOwner={isOwner}
            roster={roster} onLogged={onChanged} refreshKey={refreshKey} onClose={closeEdit} />
        </Modal>
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
// step for each prior event this quarter); Sales Points from
// compute_sp_from_production on issued policies quarter to date (this
// week = the quarter's total after this week minus after last week);
// Retention Points from compute_weekly_retention_points.
// =====================================================================
const cardGrid = { display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(230px, 1fr))", gap: 12, alignItems: "start" };
const rowBtn = { display: "flex", alignItems: "center", gap: 6, width: "100%", padding: "8px 0", border: "none", background: "transparent", fontFamily: "inherit", fontSize: 13, textAlign: "left" };
const itemLine = { fontSize: 12, color: T.slate600, display: "flex", flexWrap: "wrap", gap: "2px 8px", alignItems: "center" };
const miniBtn = { ...btnGhost, padding: "2px 7px", fontSize: 11 };
// One shape for every points breakdown on this page (Peter 2026-09-16): a header
// line carrying the total, a note line under it, then a bullet for each thing
// that built the total. Sales, Marketing and Retention all read the same way.
const HeadLine = ({ label, value }) => (
  <div style={itemLine}>
    <span style={{ flex: 1, minWidth: 90, fontWeight: 700, color: T.slate800 }}>{label}</span>
    <strong style={{ color: T.slate900 }}>{value}</strong>
  </div>
);
const NoteLine = ({ children }) => <div style={{ ...itemLine, color: T.slate500, paddingLeft: 10 }}>{children}</div>;
const Bullet = ({ children }) => (
  <div style={{ ...itemLine, color: T.slate600, paddingLeft: 10 }}>
    <span style={{ color: T.slate400 }}>•</span><span>{children}</span>
  </div>
);
const Divider = () => <div style={{ borderTop: `1px solid ${T.slate100}`, marginTop: 3 }} />;
// Roll a list of items up into one row per label, biggest first.
const byLabel = (rows, labelOf, valueOf) => {
  const m = new Map();
  for (const r of rows || []) {
    const k = labelOf(r) || "Other";
    const cur = m.get(k) || { n: 0, v: 0 };
    m.set(k, { n: cur.n + 1, v: cur.v + Number(valueOf(r) || 0) });
  }
  return Array.from(m, ([label, x]) => ({ label, ...x })).sort((a, b) => b.v - a.v);
};
const fmtMoney = (n) => `$${fmtPts(n)}`;
const ratePct = (r) => r == null ? "—" : `${Number((Number(r) * 100).toFixed(3))}%`;
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
  const toggle = (card) => (id) => setOpen(o => ({ ...o, [card]: o[card] === id ? null : id }));
  const cardN = people.reduce((s, p) => s + Number(p.conversations?.scorecards || 0), 0);
  const teamAvg = cardN ? people.reduce((s, p) => s + Number(p.conversations?.avg || 0) * Number(p.conversations?.scorecards || 0), 0) / cardN : null;

  const voidRow = async (fn, id, what) => {
    if (!window.confirm(`Remove this ${what}?`)) return;
    const { data, error } = await supabase.rpc(fn, { p_id: id, p_reason: null });
    if (error || !data?.ok) { window.alert(errText(error || data)); return; }
    load();
  };

  // Quarter to date only (Peter 2026-09-16). The week's number is already on the
  // row; the expander exists to show how the quarter total was built.
  const marketingItems = (p) => {
    const m = p.marketing || {};
    const mix = m.qtd_mix || [];
    const rows = [<div key="qtd"><HeadLine label="Quarter to date" value={fmtPts(m.qtd_points)} /></div>];
    for (const g of mix) {
      rows.push(<div key={`q-${g.kind}`}><Bullet>{`${g.label}: ${g.n} = ${fmtPts(g.points)}`}</Bullet></div>);
    }
    if (Number(m.qtd_reported)) {
      rows.push(<div key="qrep"><Bullet>{`Weekly report, not itemised: ${fmtPts(m.qtd_reported)}`}</Bullet></div>);
    }
    if (!mix.length && !Number(m.qtd_reported)) rows.push(<div key="none"><NoteLine>Nothing this quarter.</NoteLine></div>);
    return rows;
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
        {it.can_change && <button type="button" style={miniBtn} onClick={() => voidRow("rp_void_quote", it.id, "quote")}>Remove</button>}
      </div>
    ));
  };
  // Tap a name on Sales Points and you get the summary of the quarter: how much
  // of the total is P&C, how much is life, the rate each sits at, and the issued
  // business that got them there. The policy-by-policy detail for the week moved
  // to the This week card at the bottom (Peter 2026-09-16). Every number here is
  // read straight off the board. Nothing is worked out on this page.
  const salesSummary = (p) => {
    const s = p.sales || {};
    const t = s.tiers, u = s.units || {}, rt = s.rates || {};
    if (!t) return [
      <div key="rep" style={itemLine}>
        <span>From what was reported at the time.</span>
        <strong style={{ color: T.slate900 }}>{fmtPts(s.qtd_points)} this quarter</strong>
      </div>,
    ];

    const n = (v) => Number(v || 0);
    const atCap = (tiers, cap) => cap != null && n(tiers) >= n(cap) ? ` (at the ${cap} cap)` : "";
    const capped = (raw, cap) => n(raw) > n(cap) ? ` \u00b7 capped at ${ratePct(cap)}` : "";
    const pcTiers = n(t.auto_tiers_at_6) + n(t.fire_tiers_at_3) + n(t.life_tiers_pc_at_200);
    const tierWord = (k) => plural(n(k), "tier");

    const rows = [];
    rows.push(<div key="pc"><HeadLine label="P&C" value={fmtPts(s.pc_points)} /></div>);
    if (n(s.pc_premium)) {
      rows.push(<div key="pc1"><NoteLine>{`${ratePct(s.pc_rate)} of ${fmtMoney(s.pc_premium)} issued`}</NoteLine></div>);
      rows.push(<div key="pc2"><NoteLine>{`${ratePct(rt.pc_base_pct)} base + ${ratePct(rt.pc_step_pct)} / ${tierWord(pcTiers)}${capped(rt.pc_rate_raw, rt.pc_rate_capped)}`}</NoteLine></div>);
      if (n(u.auto_apps)) rows.push(<div key="pcA"><Bullet>{`Auto: ${plural(n(u.auto_apps), "car")} = ${tierWord(t.auto_tiers_at_6)}${atCap(t.auto_tiers_at_6, t.auto_rep_cap)}`}</Bullet></div>);
      if (n(u.fire_apps)) rows.push(<div key="pcF"><Bullet>{`Fire: ${plural(n(u.fire_apps), "app")} = ${tierWord(t.fire_tiers_at_3)}${atCap(t.fire_tiers_at_3, t.fire_rep_cap)}`}</Bullet></div>);
      if (n(u.life_premium)) rows.push(<div key="pcL"><Bullet>{`Life: ${fmtMoney(u.life_premium)} = ${tierWord(t.life_tiers_pc_at_200)}`}</Bullet></div>);
    } else {
      rows.push(<div key="pc0"><NoteLine>No auto or fire issued this quarter.</NoteLine></div>);
    }

    rows.push(<div key="lh"><HeadLine label="Life & Health" value={fmtPts(s.lh_points)} /></div>);
    if (n(s.lh_premium)) {
      rows.push(<div key="lh1"><NoteLine>{`${ratePct(s.lh_rate)} of ${fmtMoney(s.lh_premium)} issued`}</NoteLine></div>);
      rows.push(<div key="lh2"><NoteLine>{`${ratePct(rt.lh_base_pct)} base + ${ratePct(rt.lh_step_pct)} / ${tierWord(t.life_tiers_lh_at_200)}${capped(rt.lh_rate_raw, rt.lh_rate_capped)}`}</NoteLine></div>);
      if (n(u.life_premium)) rows.push(<div key="lhL"><Bullet>{`Life: ${fmtMoney(u.life_premium)} = ${tierWord(t.life_tiers_lh_at_200)}`}</Bullet></div>);
    } else {
      rows.push(<div key="lh0"><NoteLine>No life or health issued this quarter.</NoteLine></div>);
    }

    // Life, all in (Peter 2026-10-04): its own rate plus what it added to the P&C rate,
    // and what the next life step pays. Read straight off the board.
    const lf = s.life || {};
    if (lf.next_step_pay != null) {
      rows.push(<div key="lf"><Divider /><HeadLine label="Life, all in" value={fmtPts(lf.pay)} /></div>);
      if (n(lf.premium)) rows.push(<div key="lf1"><NoteLine>{`${lf.pct}% of ${fmtMoney(lf.premium)} life: ${fmtMoney(lf.own)} at the life rate + ${fmtMoney(lf.bump)} it added to your P&C rate`}</NoteLine></div>);
      rows.push(<div key="lf2"><NoteLine>{`Next $${lf.step_dollars ?? 200} of life pays ${fmtMoney(lf.next_step_pay)} today, and adds ${ratePct(rt.pc_step_pct)} to your rate on every auto and fire dollar you write the rest of the quarter.`}</NoteLine></div>);
    }

    rows.push(<div key="qtd"><Divider /><HeadLine label="Quarter to date" value={fmtPts(s.qtd_points)} /></div>);
    return rows;
  };
  const retentionItems = (p) => {
    const r = p.retention || {};
    const rows = [<div key="h"><HeadLine label="Net this week" value={fmtWk(r.net)} /></div>];
    rows.push(<div key="g"><NoteLine>{`${fmtPts(r.gross)} gross${Number(r.reduction_pct) > 0 ? `, less ${fmtPts(r.reduction_pct)}% for ${fmtPts(r.missed_pct)}% missed calls` : ""}`}</NoteLine></div>);
    rows.push(<div key="hrs"><Bullet>{`Hours in office: ${fmtPts(r.hours_in_office)} = ${fmtPts(r.hour_points)}`}</Bullet></div>);
    rows.push(<div key="cal"><Bullet>{`Calls answered: ${r.calls_answered || 0} = ${fmtPts(r.call_points)}`}</Bullet></div>);
    for (const g of byLabel(r.items, it => it.label, it => it.points)) {
      rows.push(<div key={`g-${g.label}`}><Bullet>{`${g.label}: ${g.n} = ${fmtPts(g.v)}`}</Bullet></div>);
    }
    return rows;
  };

  return (
    <div style={{ display: "grid", gap: 16 }}>
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
        <ScoreCard title="Marketing Points" total={fmtWk(team.marketing)} people={people}
          rankOf={p => Number(p.marketing?.points || 0)} valueOf={p => fmtWk(p.marketing?.points)}
          subOf={p => `${fmtPts(p.marketing?.qtd_points)} this quarter`}
          renderItems={marketingItems} open={open.m} onToggle={toggle("m")} />
        {show.quotes && <ScoreCard title="HH Quotes" total={Number(team.quotes || 0)} people={people}
          rankOf={p => Number(p.quotes?.count || 0)} valueOf={p => Number(p.quotes?.count || 0)}
          renderItems={quoteItems} open={open.q} onToggle={toggle("q")} />}
        <ScoreCard title="Sales Points" total={fmtWk(team.sales)} note="Counted the week a policy issues." people={people}
          rankOf={p => Number(p.sales?.points || 0)} valueOf={p => fmtWk(p.sales?.points)}
          subOf={p => `${fmtPts(p.sales?.qtd_points)} this quarter${p.sales?.life?.next_step_pay != null ? ` \u00b7 next $${p.sales.life.step_dollars ?? 200} of life: +${fmtMoney(p.sales.life.next_step_pay)} so far` : ""}`}
          renderItems={salesSummary} open={open.s} onToggle={toggle("s")} />
        {show.retention && <ScoreCard title="Retention Points" total={fmtWk(team.retention_net)} note="Net, after the team missed-call reduction." people={people}
          rankOf={p => Number(p.retention?.net || 0)} valueOf={p => fmtWk(p.retention?.net)}
          subOf={p => `${fmtPts(p.retention?.gross)} gross · missed ${fmtPts(p.retention?.missed_pct)}% calls`}
          renderItems={retentionItems} open={open.r} onToggle={toggle("r")} />}
        <ScoreCard title="Conversations" total={teamAvg == null ? "—" : teamAvg.toFixed(2)} note="Conversation score, 1 to 3." people={people}
          rankOf={p => Number(p.conversations?.avg || 0)} valueOf={p => p.conversations?.avg == null ? "—" : Number(p.conversations.avg).toFixed(2)}
          subOf={p => `${plural(p.conversations?.scorecards || 0, "scored conversation")} · ${plural(p.conversations?.pivots || 0, "pivot")}`} />
      </div>

      {/* This week — same table as Pending, one toggle away (Peter 2026-09-14). */}
      {!reported && (
        <RecordsPanel
          scope="week"
          weekEnd={safeWeek}
          title="This week"
          blurb="Everything that moved points this week. Policies show up the week they issue."
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
//    code_flags, and rolled into the CPR week automatically. Saving one
//    emails the whole agency team at their State Farm addresses
//    (trigger trg_code_flag_notify_team on code_flags).
//  * Every item carries the explanation that used to live on the Daily
//    Wrap-up processes page, behind the ⓘ on the right of the row.
// =====================================================================

// Sections are lines starting "1. " .. "n. ", taken in ascending order
// only, so an answer that happens to begin with a number is left alone.
// n is the number of wrap-up questions (five since Peter deleted the
// lapse/cancel question on 2026-09-21 — the production log holds those now).
function splitWrapup(text, n = 5) {
  const out = Array.from({ length: n }, () => "");
  if (!text || !String(text).trim()) return out;
  const buf = Array.from({ length: n }, () => []);
  let cur = -1;
  for (const ln of String(text).split("\n")) {
    const m = ln.match(/^(\d)\.\s+\S/);
    if (m && Number(m[1]) === cur + 2 && Number(m[1]) <= n) { cur = Number(m[1]) - 1; continue; }
    if (cur >= 0) buf[cur].push(ln);
  }
  for (let i = 0; i < n; i++) out[i] = buf[i].join("\n").trim();
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
// What shows behind the i on the commit row of the personal list.
const COMMIT_HELP = "The commit you made at this morning's kickoff.\n\nTick it when you have done it. Leave it unticked if you did not get there. The next morning's kickoff message shows a tick against every commit that was hit and a cross against every one that was not.";

const checklistRowBtn = {
  flexShrink: 0, width: 22, height: 20, lineHeight: "18px", textAlign: "center", padding: 0,
  borderRadius: 6, cursor: "pointer", fontFamily: "inherit", fontSize: 12, fontWeight: 700,
  boxSizing: "border-box", border: `1px solid ${T.slate300}`, background: T.white, color: T.slate600,
};

function ChecklistRow({ item, checked, byLabel, byOwner, busy, disabled, onToggle, openHelp, setOpenHelp, editMode, onEdit, onMove, band, children }) {
  const open = openHelp === item.id;
  const off = !!busy || !!disabled;
  // Team rows carry their group's background (Peter 2026-09-25). The color
  // reaches 8px past the words on each side, so nothing on the row moves.
  const round = (on) => (on ? 8 : 0);
  const bandStyle = band ? {
    background: band.bg, margin: "0 -8px", padding: "0 8px",
    borderTopLeftRadius: round(band.first), borderTopRightRadius: round(band.first),
    borderBottomLeftRadius: round(band.last), borderBottomRightRadius: round(band.last),
  } : undefined;
  const noRule = open || children || band?.last;
  return (
    <div style={bandStyle}>
      <div style={{ display: "flex", gap: 10, alignItems: "flex-start", padding: "8px 2px", borderBottom: noRule ? "none" : `1px solid ${band ? band.rule : T.slate100}` }}>
        <input
          type="checkbox"
          id={`chk_${item.id}`}
          checked={!!checked}
          onChange={() => onToggle(item, !checked)}
          disabled={off}
          style={{ marginTop: 2, width: 16, height: 16, flexShrink: 0, accentColor: T.blue, boxSizing: "border-box", cursor: disabled ? "default" : busy ? "wait" : "pointer" }}
        />
        <label htmlFor={`chk_${item.id}`} style={{ flex: 1, fontSize: 13, lineHeight: 1.4, cursor: disabled ? "default" : busy ? "wait" : "pointer", color: checked || disabled ? T.slate500 : T.slate800 }}>{item.title}</label>
        {item.link_url && (
          <a href={item.link_url} target="_blank" rel="noopener noreferrer" title="Open the link for this item"
             style={{ flexShrink: 0, fontSize: 11, fontWeight: 700, color: T.blue, textDecoration: "none", marginTop: 1 }}>open ↗</a>
        )}
        {byLabel && (
          byOwner
            ? <span title="The owner cleared this one for the team" style={{ fontSize: 11, fontWeight: 700, color: T.blue, background: T.blueLt, borderRadius: 999, padding: "1px 8px", whiteSpace: "nowrap", flexShrink: 0 }}>{byLabel} did this</span>
            : <span style={{ fontSize: 11, color: T.slate400, textAlign: "right", whiteSpace: editMode ? "nowrap" : "normal", flexShrink: 0 }}>{byLabel}</span>
        )}
        {editMode && (
          <>
            <button type="button" title="Move up" aria-label="Move up" onClick={() => onMove(item, "up")} style={checklistRowBtn}>↑</button>
            <button type="button" title="Move down" aria-label="Move down" onClick={() => onMove(item, "down")} style={checklistRowBtn}>↓</button>
            <button type="button" title="Edit this item" aria-label="Edit this item" onClick={() => onEdit(item)} style={{ ...checklistRowBtn, borderColor: T.blue, color: T.blue }}>✎</button>
          </>
        )}
        <InfoDot open={open} title="What this means" onClick={() => setOpenHelp(h => (h === item.id ? null : item.id))} />
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

// =====================================================================
// Day done — the reward for clearing everything (Peter 2026-09-17). When
// the team list is clear, the person's own list is clear, and the wrap-up
// is settled for the day, the checklist crumbles away and this takes its
// place: confetti, a dancing pug, the week's numbers so far, and a line
// telling them to leave.
//
// Nothing here writes anything. "Back to the list" and unticking anything
// both put the checklist straight back.
// =====================================================================
const DAY_LINES  = ["Your Day is Done!",  "Now Go Home!", "Gyet!", "Scat!"];
const WEEK_LINES = ["Your Week is Done!", "Now Go Home!", "Gyet!", "Scat!"];

function DayDone({ stats, reduce, onBack, weekDone }) {
  // Same four lines either way; only the first one changes when the whole
  // week is closed out rather than just the day (Peter 2026-09-17).
  const lines = weekDone ? WEEK_LINES : DAY_LINES;
  // A fresh animal at random every time the panel comes up. Picked in a state
  // initialiser so it holds still for as long as the panel is showing and
  // re-rolls the next time it opens (Peter 2026-09-17).
  // Guest dancers (ninja, boss cat, boxing dolphin) are in the draw too (Peter 2026-09-22).
  // The characters come from the dancers table, so the pick waits until it has been read.
  const { all: allDancers, animals, ready: dancersReady } = useDancers();
  const pickDancer = () => (allDancers.length ? allDancers[Math.floor(Math.random() * allDancers.length)].key : null);
  const [which, setWhich] = useState(() => (dancersReady ? pickDancer() : null));
  useEffect(() => { if (dancersReady && which === null) setWhich(pickDancer()); }, [dancersReady]); // eslint-disable-line react-hooks/exhaustive-deps
  const _vp = useViewport();
  const [line, setLine] = useState(0);
  const [confettiOn, setConfettiOn] = useState(!reduce);

  useEffect(() => {
    const t = setInterval(() => setLine(i => (i + 1) % lines.length), 1500);
    return () => clearInterval(t);
  }, []);

  // A party, not a screensaver. It stops on its own.
  useEffect(() => {
    if (!confettiOn) return;
    const t = setTimeout(() => setConfettiOn(false), 9000);
    return () => clearTimeout(t);
  }, [confettiOn]);

  // The standard five, in the Scoreboard's order, read straight off the
  // Scoreboard. A week the board does not show Quotes or Retention for does
  // not show them here either.
  const missing = stats && (stats.ok === false || stats.on_board === false);
  const show = stats?.show || { quotes: true, retention: true };
  const cells = [
    {
      label: "Marketing Points", color: T.purple,
      value: stats ? fmtWk(stats.marketing_points) : "—",
      sub: stats ? `${fmtPts(stats.marketing_qtd)} this quarter` : null,
    },
    {
      label: "HH Quotes", color: T.blue, on: show.quotes !== false,
      value: stats ? String(Number(stats.quotes) || 0) : "—",
    },
    {
      label: "Sales Points", color: T.green,
      value: stats ? fmtWk(stats.sales_points) : "—",
      sub: stats ? `${fmtPts(stats.sales_qtd)} this quarter` : null,
    },
    {
      label: "Retention Points", color: T.teal, on: show.retention !== false,
      value: stats ? fmtWk(stats.retention_net) : "—",
      sub: stats ? `${fmtPts(stats.retention_gross)} gross` : null,
    },
    {
      label: "Conversations", color: T.amber,
      value: stats && stats.conversation_avg != null ? Number(stats.conversation_avg).toFixed(2) : "—",
      sub: stats ? `${plural(stats.conversations || 0, "scored conversation")} \u00b7 ${plural(stats.pivots || 0, "pivot")}` : null,
    },
  ].filter(c => c.on !== false);

  return (
    <div style={{ position: "relative" }}>
      <DayDoneStyles />
      {confettiOn && <Confetti />}

      <div style={{
        ...cardStyle,
        padding: _vp.isPhone ? 20 : 32,
        textAlign: "center",
        background: `linear-gradient(180deg, ${T.white} 0%, ${T.slate50} 100%)`,
        animation: reduce ? undefined : "nwRise 520ms ease-out both",
      }}>
        {weekDone ? (
          <div style={{ display: "flex", flexWrap: "wrap", justifyContent: "center", alignItems: "flex-end" }}>
            {animals.map((d, i) => (
              <Dancer key={d.key} which={d.key} size={_vp.isPhone ? 78 : 104} delay={i * 110} />
            ))}
          </div>
        ) : which ? (
          <Dancer which={which} size={_vp.isPhone ? 144 : 176} />
        ) : (
          <svg width={_vp.isPhone ? 144 : 176} height={_vp.isPhone ? 144 : 176} aria-hidden="true" />
        )}

        <div key={line} style={{
          fontSize: _vp.isPhone ? 26 : 34, fontWeight: 900, color: T.slate900, lineHeight: 1.2,
          minHeight: _vp.isPhone ? 34 : 44,
          animation: reduce ? undefined : "nwPop 420ms ease-out both",
        }}>
          {lines[line]}
        </div>
        <div style={{ marginTop: 4, fontSize: 13, color: T.slate500 }}>
          Everything is ticked and your wrap-up is settled.
        </div>

        <div style={{ marginTop: 24, textAlign: "left" }}>
          <div style={{ display: "flex", flexWrap: "wrap", gap: 8, alignItems: "baseline", justifyContent: "space-between", marginBottom: 10 }}>
            <div style={{ fontSize: 15, fontWeight: 800, color: T.slate900 }}>Your week so far</div>
            <span style={{ fontSize: 12, color: T.slate500 }}>
              {stats?.week_ending ? `Week ending ${fmtDate(stats.week_ending)}` : "Loading"}
            </span>
          </div>

          {missing ? (
            <div style={{ fontSize: 13, color: T.slate600 }}>
              {stats.ok === false
                ? "This login is not matched to a teammate, so there are no numbers to show."
                : "You are not on this week's scoreboard, so there are no numbers to show."}
            </div>
          ) : (
            <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))", gap: 10 }}>
              {cells.map(c => (
                <div key={c.label} style={{
                  padding: "14px 12px", borderRadius: 10, background: T.white,
                  border: `1px solid ${T.slate200}`, boxSizing: "border-box",
                }}>
                  <div style={{ fontSize: 26, fontWeight: 800, color: c.color, lineHeight: 1.1 }}>{c.value}</div>
                  <div style={{ fontSize: 12, color: T.slate600, marginTop: 4 }}>{c.label}</div>
                  {c.sub && <div style={{ fontSize: 11, color: T.slate400, marginTop: 2 }}>{c.sub}</div>}
                </div>
              ))}
            </div>
          )}
        </div>

        <div style={{ marginTop: 20 }}>
          <button type="button" onClick={onBack} style={linkBtn}>Back to the list</button>
        </div>
      </div>
    </div>
  );
}

function ChecklistTab() {
  const _vp = useViewport();
  const [state, setState] = useState(null);
  const [openHelp, setOpenHelp] = useState(null);
  const [wrap, setWrap] = useState(null);
  const [parts, setParts] = useState(["", "", "", "", ""]);
  // The wrap-up sits on screen every day now. Two pieces of state decide how
  // it looks: hiddenToday (they said it is not their last day, so it is put
  // away until tomorrow) and finished (they clicked that nothing is left to
  // type, which is what the day-done check reads). Peter 2026-09-17.
  const [hiddenToday, setHiddenToday] = useState(false);
  const [finished, setFinished] = useState(false);
  const [flags, setFlags] = useState([]);
  const [flagDraft, setFlagDraft] = useState(null);   // {severity, note, correction}
  const [busy, setBusy] = useState(false);
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState("");
  const [ok, setOk] = useState("");
  const [tickKey, setTickKey] = useState(0);
  const [flagKey, setFlagKey] = useState(0);
  // Today's commit from the morning kickoff. It is ticked off here, on the
  // personal list, instead of being answered on the kickoff page the next
  // morning (Peter 2026-09-16).
  const [commit, setCommit] = useState(null);
  // Everyone's commit for today, so the row names who has ticked theirs off —
  // same visibility the rest of the personal list has (Peter 2026-09-16).
  const [commitPeople, setCommitPeople] = useState([]);
  // Until today's commit is saved, the week's commit choices sit at the top
  // of the personal list; once saved, that spot shows the commit itself
  // (Peter 2026-09-21). hasMember is false for a login with no team record,
  // which has nothing to save a commit against.
  const [hasMember, setHasMember] = useState(false);
  const [commitChoices, setCommitChoices] = useState([]);
  const kickoffWeek = useMemo(() => kickoffToday(), []);
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
    supabase.rpc("kickoff_commits_mine")
      .then(r => {
        if (!alive) return;
        setCommit(r?.data?.today || null);
        setHasMember(!!r?.data?.member_id);
      });
    return () => { alive = false; };
  }, [tickKey]);

  // The choices come off the Daily Kickoff page, filtered to this week of the
  // cycle by the same code the page renders with.
  useEffect(() => {
    let alive = true;
    supabase.rpc("kickoff_commit_block")
      .then(r => { if (alive) setCommitChoices(commitOptions(r?.data || "", kickoffWeek.week, kickoffWeek.day)); });
    return () => { alive = false; };
  }, [kickoffWeek]);

  useEffect(() => {
    let alive = true;
    supabase.rpc("kickoff_commits_today")
      .then(r => { if (alive) setCommitPeople(Array.isArray(r?.data?.people) ? r.data.people : []); });
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
      setParts(splitWrapup(d.wrapup_text, (d.prompts || []).length || 5));
      setHiddenToday(!!d.hidden_today);
      setFinished(!!d.wrapup_finished);
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

  // Ticked means you did it, unticked means you did not. Same two answers the
  // kickoff page used to ask for, so the morning message still prints a tick or
  // a cross against yesterday's commit.
  const toggleCommit = async (row, on) => {
    if (!row?.id || busy) return;
    setBusy(true); setErr("");
    const { error } = await supabase.rpc("kickoff_commit_mark", { p_id: row.id, p_hit: on });
    setBusy(false);
    if (error) { setErr(error.message || "Could not save that."); return; }
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
      p_parts: parts, p_week_ending: null,
    });
    setSaving(false);
    if (error) { setErr(error.message || "Could not save the wrap-up."); return false; }
    setOk(data?.wrapup_done ? "Saved. Every question answered." : "Saved. Some answers are still blank.");
    setWrap(w => (w ? { ...w, wrapup_done: !!data?.wrapup_done } : w));
    return { done: !!data?.wrapup_done };
  };

  // "This is not my last day this week" puts the wrap-up away until tomorrow.
  // The server refuses it on a known last workday, which is the same answer
  // that takes the control off the screen.
  const setHide = async (on) => {
    setErr("");
    const { error } = await supabase.rpc("my_wrapup_hide_set", { p_on: on, p_date: null });
    if (error) { setErr(error.message || "Could not save that."); return; }
    setHiddenToday(on);
  };

  // Typing is the answer to the question the toggle asks, so it clears it.
  const editPart = (i, val) => {
    setParts(v => { const n = [...v]; n[i] = val; return n; });
    if (hiddenToday) setHide(false);
  };

  // Reopening a closed week. Saving is what closes it, so there is no
  // separate "I am done" button any more.
  const finish = async (on) => {
    setErr("");
    const { data, error } = await supabase.rpc("my_wrapup_finish", { p_on: on, p_week_ending: null });
    if (error) { setErr(error.message || "Could not save that."); return; }
    setFinished(!!data?.wrapup_finished);
    setOk(on ? "Week closed." : "");
  };

  // The toggle acts the moment it is flipped: the form goes away entirely, so
  // nobody is left looking at six boxes wondering whether they have to fill
  // them in today (Peter 2026-09-17). Anything already typed is saved on the
  // way out. Flipping it back brings the form straight back.
  const toggleNotLastDay = async (on) => {
    if (on) {
      if (wrap?.ok && wrap?.report_id && parts.some(p => (p || "").trim())) {
        if (!(await save())) return;
      }
      await setHide(true);
      setOk("");
    } else {
      await setHide(false);
      setOk("");
    }
  };

  // The one button on the form, and the only way the week gets closed.
  // Peter 2026-09-21: the week only closes once every answer is in. Until then
  // the same button just saves, and the server refuses a close anyway.
  const submitWrapup = async () => {
    const res = await save();
    if (!res) return;
    if (!res.done) { setOk(`Saved. Answer all ${prompts.length} to close your week.`); return; }
    await finish(true);
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
  // Each team row's background, by its group (Peter 2026-09-25).
  const bands = checklistBands(items.map((i) => i.item_type));
  const cleared = items.filter(i => i.ticked_at).length;
  const personal = Array.isArray(state?.personal) ? state.personal : [];
  const commitHitNames = commitPeople.filter(p => p.hit === true).map(p => p.name).join(", ");
  const prompts = Array.isArray(wrap?.prompts) ? wrap.prompts : [];
  const answered = parts.filter(p => (p || "").trim()).length;
  const allAnswered = prompts.length > 0 && answered >= prompts.length;
  // On screen every day. On a day the system already knows is their last
  // workday there is no way to put it away — that is the day it exists for.
  // Any earlier day carries the "not my last day" checkbox instead.
  const knownLastDay = !!wrap?.wrap_cue;
  const showWrap = !hiddenToday;
  const reds = flags.filter(f => f.severity === "red");
  const yellows = flags.filter(f => f.severity === "yellow");

  // ── Day done ──────────────────────────────────────────────────────
  // Three things have to be true: the team list is clear, this person's
  // own list is clear, and the wrap-up is settled for the day.
  const teamClear = items.length > 0 && items.every(i => i.ticked_at);
  // A commit answered "no" still counts as answered. Requiring a yes would
  // cost an honest miss the whole thing, and that buys dishonest ticks.
  const commitClear = !commit || commit.hit === true || commit.hit === false;
  const personalClear = commitClear && personal.every(i => i.mine);
  // Nothing to settle counts as settled: put away for today, clicked
  // finished, no teammate record, or this week's CPR is not open yet.
  const wrapSettled = !!wrap && (hiddenToday || finished || wrap.ok === false || !wrap.report_id);
  const dayDone = teamClear && personalClear && wrapSettled;

  const [dayPhase, setDayPhase] = useState("list");   // list | crumbling | done
  const [dismissed, setDismissed] = useState(false);
  const [weekStats, setWeekStats] = useState(null);
  const reduceMotion = useMemo(
    () => typeof window !== "undefined" && typeof window.matchMedia === "function"
      && window.matchMedia("(prefers-reduced-motion: reduce)").matches,
    []
  );

  useEffect(() => {
    if (!dayDone) { setDayPhase("list"); setDismissed(false); setWeekStats(null); return; }
    if (dismissed) return;
    if (reduceMotion) { setDayPhase("done"); return; }
    setDayPhase("crumbling");
    const t = setTimeout(() => setDayPhase("done"), 950);
    return () => clearTimeout(t);
  }, [dayDone, dismissed, reduceMotion]);

  useEffect(() => {
    if (dayPhase !== "done" || weekStats) return;
    let alive = true;
    supabase.rpc("my_week_stats", { p_week_ending: null })
      .then(r => { if (alive) setWeekStats(r?.data || null); });
    return () => { alive = false; };
  }, [dayPhase, weekStats]);

  if (dayPhase === "done") {
    return (
      <DayDone
        stats={weekStats}
        reduce={reduceMotion}
        weekDone={!!finished}
        onBack={() => { setDismissed(true); setDayPhase("list"); }}
      />
    );
  }

  return (
    <>
      <DayDoneStyles />
      <div
        className={dayPhase === "crumbling" ? "nw-crumble" : undefined}
        style={{ display: "grid", gridTemplateColumns: _vp.isPhone ? "1fr" : "repeat(auto-fit, minmax(340px, 1fr))", gap: 16, alignItems: "start" }}
      >

      {/* ── Left column: the daily team list ──────────────── */}
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

        <div style={{ marginTop: 12 }}>
          {items.length === 0
            ? <div style={{ fontSize: 13, color: T.slate500 }}>No items for this day.</div>
            : items.map((it, idx) => (
                <ChecklistRow
                  key={it.id}
                  item={it}
                  band={bands[idx]}
                  checked={!!it.ticked_at}
                  byLabel={it.ticked_at ? it.ticked_by : null}
                  byOwner={!!it.by_owner}
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
      </div>

      {/* ── Right column, in the order the day is worked: what went ──
          wrong, then your own list, then the wrap-up. Peter 2026-09-17. ── */}
      <div style={{ display: "grid", gap: 16, alignItems: "start" }}>

        {/* Code Reds / Yellows — any day, no email */}
        <div style={cardStyle}>
          <div style={{ display: "flex", flexWrap: "wrap", gap: 8, alignItems: "baseline", justifyContent: "space-between" }}>
            <div style={{ fontSize: 15, fontWeight: 800, color: T.slate900 }}>Code Reds & Yellows</div>
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

        {/* Personal checklist */}
        <div style={cardStyle}>
          <div style={{ fontSize: 15, fontWeight: 800, color: T.slate900 }}>Personal checklist</div>
          <div style={{ fontSize: 11, color: T.slate500, marginBottom: 6 }}>Everyone ticks these for themselves. The whole team can see who has.</div>
          {!commit && hasMember ? (
            <div style={{ padding: "8px 10px", margin: "4px 0 8px", background: T.slate50, borderRadius: 8 }}>
              <div style={{ fontSize: 13, fontWeight: 700, color: T.slate900, marginBottom: 2 }}>🎯 Pick today's commit</div>
              <div style={{ fontSize: 11, color: T.slate500, marginBottom: 4 }}>Once saved it is locked for the day.</div>
              <CommitPicker items={commitChoices} week={kickoffWeek.week} style={{ fontSize: 13, lineHeight: 1.4, color: T.slate800 }}
                            onSaved={(row) => { setCommit(row || null); setTickKey(k => k + 1); }} />
            </div>
          ) : (
          <ChecklistRow
            item={{ id: commit ? commit.id : "nocommit", title: commit ? `Commit completed \u2014 ${commit.commit_text}` : "Commit completed", help_text: COMMIT_HELP }}
            checked={!!commit && commit.hit === true}
            byLabel={commitHitNames || null}
            busy={busy}
            disabled={!commit}
            onToggle={(_it, on) => toggleCommit(commit, on)}
            openHelp={openHelp}
            setOpenHelp={setOpenHelp}
            editMode={false}
            onEdit={() => {}}
            onMove={() => {}}
          />
          )}
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

        {/* Weekly wrap-up */}
        <div style={cardStyle}>
          <div style={{ display: "flex", flexWrap: "wrap", gap: 8, alignItems: "baseline", justifyContent: "space-between" }}>
            <div>
              <div style={{ fontSize: 15, fontWeight: 800, color: T.slate900 }}>Weekly wrap-up</div>
              <div style={{ fontSize: 12, color: T.slate500 }}>
                {wrap?.week_ending ? `Week ending ${fmtDate(wrap.week_ending)}` : "Loading"} · goes straight onto the CPR
              </div>
            </div>
            {showWrap && prompts.length > 0 && <span style={{ fontSize: 12, fontWeight: 700, color: allAnswered ? T.green : T.slate600 }}>{answered} of {prompts.length}</span>}
          </div>

          {showWrap && wrap?.off_rest_of_week && (
            <div style={{ marginTop: 10, padding: "8px 10px", borderRadius: 8, background: T.blueLt, color: T.blue, fontSize: 12, lineHeight: 1.5 }}>
              You're off the rest of the week, so this is your last workday. Wrap up before you go.
            </div>
          )}

          {!knownLastDay && !finished && (
            <div style={{ marginTop: 12 }}>
              <button
                type="button"
                role="switch"
                aria-checked={hiddenToday}
                onClick={() => toggleNotLastDay(!hiddenToday)}
                style={{ display: "inline-flex", alignItems: "center", gap: 10, background: "none", border: "none", padding: 0, cursor: "pointer", textAlign: "left" }}
              >
                <span style={{ position: "relative", width: 36, height: 20, borderRadius: 999, flexShrink: 0, boxSizing: "border-box", background: hiddenToday ? T.blue : T.slate200 }}>
                  <span style={{ position: "absolute", top: 2, left: hiddenToday ? 18 : 2, width: 16, height: 16, borderRadius: "50%", background: T.white, boxSizing: "border-box" }} />
                </span>
                <span style={{ fontSize: 13, color: T.slate800 }}>This is not my last day this week</span>
              </button>
            </div>
          )}

          {hiddenToday && (
            <div style={{ marginTop: 10, fontSize: 13, color: T.slate600, lineHeight: 1.6 }}>
              Nothing to do here today. The wrap-up is back tomorrow.
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
                    onChange={e => editPart(i, e.target.value)}
                    style={{ ...inputBase, fontSize: 13, padding: "8px 10px", lineHeight: 1.5, resize: "vertical" }}
                  />
                </div>
              ))}

              {finished ? (
                <div style={{ display: "flex", flexWrap: "wrap", gap: 12, alignItems: "center" }}>
                  <span style={{ fontSize: 13, color: T.green, fontWeight: 700 }}>Week closed.</span>
                  <button type="button" onClick={() => finish(false)} style={linkBtn}>Reopen it</button>
                </div>
              ) : (
                <div style={{ display: "flex", flexWrap: "wrap", gap: 12, alignItems: "center" }}>
                  <button type="button" onClick={submitWrapup} disabled={saving} style={btnPrimary(saving)}>
                    {saving ? "Saving…" : allAnswered ? "Save and close my week" : "Save my answers"}
                  </button>
                  {!allAnswered && !ok && <span style={{ fontSize: 12, color: T.slate500 }}>Answer all {prompts.length} to close your week.</span>}
                  {ok && <span style={{ fontSize: 12, color: T.green, fontWeight: 600 }}>{ok}</span>}
                </div>
              )}
            </div>
          )}

          {err && <div style={{ marginTop: 10, fontSize: 12, color: T.red, fontWeight: 600 }}>{err}</div>}
        </div>

      </div>
      </div>
    </>
  );
}

// =====================================================================
// Live — the call, one step at a time (Peter 2026-10-04).
//
// Pick Inbound or Outbound, say who's on the line, and the script shows only
// the next thing to say or the next choice to make, never the whole page.
// Every word and every list of call types comes from the Processes manual
// (FIT Conversations and Retention), loaded through the manual's own loader
// and read by src/lib/liveCall.js, so a script edited there changes here too.
// The manual is the one source; nothing is copied (Peter 2026-10-04). If an
// edit to the manual breaks something the walker hooks into, the tab and the
// Processes pages both name it.
//
// Only Peter sees this tab until he says it is finished (canSeeLive).
//
// While the call runs it records, without anyone picking from a list:
//   * a Pivot, with its line, the moment a service call pivots to a product
//   * the quote, once the close attempt is made ("Did they say yes?")
//   * the sale (quoted and sold) when they say yes; a save, an added car, a
//     policy review or an online review when the script reaches it
// A small tag on the side names the part of the FIT conversation the call is
// in and takes its score. At the end the call opens the Log tab's own form
// with all of it filled in. The ECRM link, premiums and anything else still
// needed go in there, so the Log's rules and its one save (rp_log_entry) apply.
//
// The call in progress is kept in this browser, so a refresh or a closed tab
// picks it back up. It is cleared once the call is logged or ended.
// =====================================================================
const LIVE_TAB_CSS = `
  .nw-live-dot { width: 8px; height: 8px; border-radius: 50%; background: ${T.red}; flex-shrink: 0; animation: nwLivePulse 1.5s ease-out 3; }
  .nw-live-dot.open { box-shadow: 0 0 0 3px ${T.red}40; animation: none; }
  @keyframes nwLivePulse { 0% { box-shadow: 0 0 0 0 ${T.red}99; } 70% { box-shadow: 0 0 0 7px ${T.red}00; } 100% { box-shadow: 0 0 0 0 ${T.red}00; } }
  @media (prefers-reduced-motion: reduce) { .nw-live-dot { animation: none; } }
`;
const LIVE_STORE = (uid) => `nw.live.v1.${uid || "me"}`;
const LIVE_MODE_STORE = "nw.live.mode";
const MODES = [["inbound", "Inbound"], ["outbound", "Outbound"]];
function readStore(key) { try { return window.localStorage.getItem(key); } catch { return null; } }
function writeStore(key, v) {
  try { if (v == null) window.localStorage.removeItem(key); else window.localStorage.setItem(key, v); } catch { /* storage off: the call just isn't kept */ }
}
function freshCall(mode) {
  return { v: 1, mode: mode === "outbound" ? "outbound" : "inbound", started: false,
    who: { kind: "person", first: "", initial: "", phone: "", age: "", gender: "" },
    picks: {}, order: [], extra: [], scores: {}, at: null, finishing: false, logged: false, onFile: 0, plain: false };
}
function loadCall(uid) {
  try { const s = JSON.parse(readStore(LIVE_STORE(uid)) || "null"); return s && s.v === 1 ? s : null; } catch { return null; }
}
function liveCallOpen(uid) { const s = loadCall(uid); return !!(s && s.started && !s.logged); }

// Everything the walker reads, loaded once each time the tab opens, through
// the same loader the Processes manual uses, with the same who-sees-what rule.
// The Daily Kickoff is skipped: a third of a megabyte no call script pulls from.
function useScriptLibrary(userRole) {
  const [lib, setLib] = useState(null);
  const [err, setErr] = useState("");
  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        const [pages, excerpts, faqs] = await Promise.all([
          fetchManualPages("processes", userRole, { skip: ["daily-kickoff"] }), fetchExcerptRows(), fetchFaqRows().catch(() => [])]);
        if (alive) setLib(makeScriptLibrary({ pages, excerpts, faqs }));
      } catch (e) { if (alive) setErr(errText(e)); }
    })();
    return () => { alive = false; };
  }, [userRole]);
  const problems = useMemo(() => (lib ? liveSourceProblems(lib) : []), [lib]);
  return { lib, err, problems };
}

// A script step as HTML: the manual's own renderer, tables stacked on a phone,
// numbering kept when a numbered list is split into steps, and links to other
// FIT pages turned into buttons that add that product to the conversation.
function liveHtml(md, lib, { isPhone = false, olStart = null, inCall = null } = {}) {
  let html = mdToHtml(isPhone ? stackTables(md) : md, { resolveFaq: lib.resolveFaq });
  if (olStart && olStart > 1) html = html.replace("<ol>", `<ol start="${olStart}">`);
  if (inCall) {
    html = html.replace(/<a href="\/processes\/([^"?#]+)((?:\?[^"]*)?)"([^>]*)>/g, (m, id, q, rest) =>
      (lib.isProductPage(id) ? `<a href="/processes/${id}${q}" data-live-product="${id}" class="nw-live-prod${inCall.includes(id) ? " on" : ""}"${rest}>` : m));
  }
  return html;
}

const LIVE_CSS = `
  .nw-live .newtworks-handbook-body { font-size: 16px; line-height: 1.65; }
  .nw-live .newtworks-handbook-body h2, .nw-live .newtworks-handbook-body h3 { font-size: 15px; margin: 2px 0 10px 0; }
  .nw-live .newtworks-handbook-body > :first-child { margin-top: 0; }
  .nw-live .newtworks-handbook-body > :last-child { margin-bottom: 0; }
  .nw-live a.nw-live-prod { display: inline-block; padding: 3px 12px; margin: 2px 0; border-radius: 999px; border: 1px solid ${T.blue}; background: ${T.blueLt}; color: ${T.blue}; text-decoration: none; font-weight: 700; font-size: 14px; }
  .nw-live a.nw-live-prod.on { background: ${T.blue}; color: ${T.white}; }
  .nw-live a.nw-live-prod.on::after { content: " \\2713"; }
  .nw-live details.nw-live-more > summary { cursor: pointer; font-size: 13px; font-weight: 700; color: ${T.slate500}; }
`;
const choiceBtn = (on) => ({
  padding: "12px 14px", borderRadius: 10, fontSize: 14, fontWeight: 700, cursor: "pointer", textAlign: "left", fontFamily: "inherit",
  border: `1px solid ${on ? T.blue : T.slate300}`, background: on ? T.blue : T.white, color: on ? T.white : T.slate800,
});
const scoreBtn = (on, v) => ({
  width: 34, height: 32, borderRadius: 8, fontSize: 14, fontWeight: 800, cursor: "pointer", fontFamily: "inherit", boxSizing: "border-box",
  border: `1px solid ${on ? (v === 0 ? T.slate500 : T.blue) : T.slate300}`,
  background: on ? (v === 0 ? T.slate500 : T.blue) : T.white, color: on ? T.white : T.slate600,
});

// What the call has recorded so far, in plain words, for the tag.
function liveRecorded(rec, values, types) {
  const out = [];
  const label = (k) => ((values || []).find(v => v.activity_key === k) || {}).label || k;
  for (const a of rec.activities || []) {
    if (a.key === "pivot") out.push(`Pivot to ${typeLabel(types, a.line, a.type) || PRODUCT_LABEL[a.line] || a.line}`);
    else if (a.key === "google_review") out.push(`${label(a.key)} · ${reviewSiteLabel(a.site)}`);
    else if (a.key === "policy_review") out.push(`${label(a.key)} · ${PRODUCT_LABEL[a.line] || a.line}`);
    else out.push(label(a.key));
  }
  for (const p of rec.policies || []) {
    const st = STATUSES.find(x => x.key === p.status);
    out.push(`${typeLabel(types, p.line, p.type) || PRODUCT_LABEL[p.line] || p.line} · ${st ? st.label : p.status}`);
  }
  if (rec.allowCancel) out.push("Canceled: pick the policy at the end");
  return out;
}

function LiveStart({ who, resuming, onWho, onPick, onStart }) {
  const [tried, setTried] = useState(false);
  const isOrg = who.kind === "org";
  const need = [];
  if (!String(who.first || "").trim() || (!isOrg && !/^[A-Za-z]$/.test(String(who.initial || "").trim()))) need.push(isOrg ? "the organization name" : "first name and last initial");
  if (!/^\d{4}$/.test(who.phone || "")) need.push("phone last 4");
  return (
    <div style={cardStyle}>
      <div style={{ fontSize: 16, fontWeight: 700, color: T.slate900, marginBottom: 4 }}>Who's on the line?</div>
      <div style={{ fontSize: 13, color: T.slate500, marginBottom: 16 }}>Age and gender can wait until the end of the call.</div>
      <div style={wrapRow}>
        <CustomerFields kind={who.kind} first={who.first} initial={who.initial} phone={who.phone} age={who.age} gender={who.gender}
          withAgeGender onChange={onWho} onPick={onPick} autoFocus={!resuming} />
      </div>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 12, alignItems: "center", marginTop: 16 }}>
        <button type="button" style={btnPrimary(false)} onClick={() => { setTried(true); if (!need.length) onStart(); }}>
          {resuming ? "Back to the call" : "Start the call"}
        </button>
        {tried && need.length > 0 && <span style={{ fontSize: 12, color: T.slate600 }}>Still needed: {need.join(" and ")}.</span>}
      </div>
    </div>
  );
}

// One step of the script, or one choice.
function LiveNode({ node, lib, isPhone, inCall, onPick, onProduct }) {
  const html = useMemo(() => (node.kind === "step" ? liveHtml(node.md, lib, { isPhone, olStart: node.olStart, inCall }) : ""), [node, lib, isPhone, inCall]);
  const leadHtml = useMemo(() => (node.lead ? liveHtml(node.lead, lib, { isPhone, inCall }) : ""), [node, lib, isPhone, inCall]);
  const moreHtml = useMemo(() => (node.more ? liveHtml(node.more, lib, { isPhone }) : ""), [node, lib, isPhone]);
  // A product link adds that product to the conversation. A right-click, a
  // middle-click or a click with a modifier key still opens the manual page.
  const click = (e) => {
    const a = e.target?.closest?.("a[data-live-product]");
    if (!a || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    e.preventDefault();
    onProduct(a.getAttribute("data-live-product"), a.getAttribute("href"));
  };
  if (node.kind === "decide") {
    return (
      <div>
        {leadHtml && <div className="newtworks-handbook-body" style={{ marginBottom: 12 }} dangerouslySetInnerHTML={{ __html: leadHtml }} />}
        <div style={{ fontSize: 17, fontWeight: 800, color: T.slate900, marginBottom: node.note ? 4 : 12 }}>{node.title}</div>
        {node.note && <div style={{ fontSize: 13, color: T.slate500, marginBottom: 12 }}>{node.note}</div>}
        {node.many ? (
          <select style={{ ...inputBase, maxWidth: 560 }} value={node.pick || ""} onChange={e => e.target.value && onPick(e.target.value)}>
            <option value="">Pick one</option>
            {/* Options that share a group (the manual's own heading for them) sit under it. */}
            {node.options.reduce((runs, o) => {
              const last = runs[runs.length - 1];
              if (o.group && last && last.group === o.group) last.items.push(o); else runs.push({ group: o.group || "", items: [o] });
              return runs;
            }, []).map((run, i) => (run.group
              ? <optgroup key={`g${i}`} label={run.group}>{run.items.map(o => <option key={o.key} value={o.key}>{o.label}</option>)}</optgroup>
              : run.items.map(o => <option key={o.key} value={o.key}>{o.label}</option>)))}
          </select>
        ) : (
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(170px, 1fr))", gap: 8 }}>
            {node.options.map(o => (
              <button key={o.key} type="button" onClick={() => onPick(o.key)} style={choiceBtn(node.pick === o.key)}>
                {o.label}{o.hint ? <span style={{ fontWeight: 500, opacity: 0.75 }}> · {o.hint}</span> : null}
              </button>
            ))}
          </div>
        )}
      </div>
    );
  }
  // A script the walker needs is gone from the manual: say so here, and let
  // the call carry on.
  if (node.kind === "missing") {
    return (
      <div style={{ padding: "12px 16px", borderRadius: 10, border: `1px solid ${T.amber}`, background: T.amberLt, color: T.slate800, fontSize: 14, lineHeight: 1.5 }}>
        ⚠️ <strong>{node.what}</strong> isn't in the Processes manual right now, so this step has no script. The rest of the call carries on.
      </div>
    );
  }
  return (
    <div>
      <div className="newtworks-handbook-body" onClick={click} dangerouslySetInnerHTML={{ __html: html }} />
      {moreHtml && (
        <details className="nw-live-more" style={{ marginTop: 16, paddingTop: 12, borderTop: `1px solid ${T.slate100}` }}>
          <summary>More from {node.moreFrom || "the FIT page"}</summary>
          <div className="newtworks-handbook-body" style={{ marginTop: 10 }} dangerouslySetInnerHTML={{ __html: moreHtml }} />
        </details>
      )}
    </div>
  );
}

// The tag on the side: which part of the FIT conversation this is, its score,
// the products being talked about, and what the call has recorded.
function LiveTag({ part, scores, onScore, rec, lib, values, types, partsIn, onJump, onAdd, onRemove }) {
  const p = CARD_PARTS.find(x => x.key === part);
  const caption = p ? ((lib.fitPage(FIT_PAGE_ID, {}).parts[p.key] || {}).caption || "") : "";
  const recorded = liveRecorded(rec, values, types);
  const first = (rec.products || [])[0];
  const products = rec.fit ? (rec.products || []).map(id => lib.product(id)).filter(Boolean) : [];
  const addable = rec.fit ? lib.products.filter(x => !(rec.products || []).includes(x.page)) : [];
  const small = { fontSize: 11, fontWeight: 700, color: T.slate500, textTransform: "uppercase", letterSpacing: 0.4 };
  if (!p && !products.length && !recorded.length) return null;
  return (
    <div style={{ ...cardStyle, padding: 14, display: "grid", gap: 14 }}>
      {p && (
        <div>
          <div style={small}>Conversation · {CARD_PARTS.indexOf(p) + 1} of 10</div>
          <div style={{ fontSize: 15, fontWeight: 800, color: T.slate900, marginTop: 2 }}>{p.label}</div>
          {caption && <div style={{ fontSize: 12, color: T.slate500, marginTop: 2 }}>{caption}</div>}
          <div style={{ display: "flex", gap: 6, marginTop: 10 }}>
            {[0, 1, 2, 3].map(v => (
              <button key={v} type="button" title={SCORE_MEANING[v]} onClick={() => onScore(p.key, v)} style={scoreBtn(scores[p.key] === v, v)}>{v === 0 ? "x" : v}</button>
            ))}
          </div>
          <div style={{ display: "flex", gap: 5, marginTop: 10, flexWrap: "wrap" }}>
            {CARD_PARTS.map(x => {
              const sc = scores[x.key];
              const here = x.key === p.key;
              return (
                <span key={x.key} title={`${x.label}: ${sc == null ? "not scored yet" : sc === 0 ? "x" : sc}`}
                  onClick={() => partsIn.includes(x.key) && onJump(x.key)}
                  style={{ width: 12, height: 12, borderRadius: "50%", boxSizing: "border-box", cursor: partsIn.includes(x.key) ? "pointer" : "default",
                    background: sc != null ? T.blue : T.white, border: `2px solid ${here ? T.slate900 : sc != null ? T.blue : T.slate300}` }} />
              );
            })}
          </div>
        </div>
      )}
      {products.length > 0 && (
        <div>
          <div style={small}>Talking about</div>
          <div style={{ ...chipRow, gap: 6, marginTop: 6 }}>
            {products.map(x => (
              <span key={x.page} style={{ ...pill, padding: x.page === first ? "6px 12px" : "6px 6px 6px 12px", fontSize: 12 }}>
                {x.label}
                {x.page !== first && <button type="button" style={pillX} onClick={() => onRemove(x.page)} aria-label={`Take ${x.label} out`}>×</button>}
              </span>
            ))}
          </div>
          {addable.length > 0 && (
            <select style={{ ...inputBase, marginTop: 8, fontSize: 13, padding: "8px 10px" }} value="" onChange={e => e.target.value && onAdd(e.target.value)}>
              <option value="">+ Add a product</option>
              {addable.map(x => <option key={x.page} value={x.page}>{x.label}</option>)}
            </select>
          )}
        </div>
      )}
      {recorded.length > 0 && (
        <div>
          <div style={small}>Recorded</div>
          <div style={{ display: "grid", gap: 4, marginTop: 6, fontSize: 13, color: T.slate700 }}>
            {recorded.map((r, i) => <div key={i}>✓ {r}</div>)}
          </div>
        </div>
      )}
    </div>
  );
}

function LiveTab({ values, sources, types, isOwner, isAdmin, myTeamId, roster, nameOf, onLogged, refreshKey, userId, userRole }) {
  const vp = useViewport();
  const narrow = vp.isPhone || vp.isTablet;
  const { lib, err: libErr, problems } = useScriptLibrary(userRole);
  const [st, setSt] = useState(() => loadCall(userId) || freshCall(readStore(LIVE_MODE_STORE)));
  useEffect(() => { writeStore(LIVE_STORE(userId), JSON.stringify(st)); }, [st, userId]);
  const built = useMemo(() => (lib && st.started ? buildCall(st, lib) : null), [lib, st]);
  const nodes = built ? built.nodes : [];
  let pos = nodes.findIndex(n => n.id === st.at);
  if (pos < 0) pos = 0;
  const node = nodes[pos] || null;
  // Next moves on from a step, from a gap where a script is missing, or from a choice already made.
  const canNext = !!node && (node.kind === "step" || node.kind === "missing" || node.pick != null);
  const rec = built ? built.rec : null;
  const [justLogged, setJustLogged] = useState(false);
  const [finishKey, setFinishKey] = useState(0);
  const savedRef = useRef(false);

  const setMode = (m) => { writeStore(LIVE_MODE_STORE, m); setSt(s => ({ ...s, mode: m })); };
  const goTo = (id) => setSt(s => ({ ...s, at: id, finishing: false }));
  const next = () => { if (nodes[pos + 1]) goTo(nodes[pos + 1].id); };
  const back = () => {
    if (st.finishing) { setSt(s => ({ ...s, finishing: false })); return; }
    if (pos > 0) goTo(nodes[pos - 1].id);
  };
  // A choice. Changing an earlier answer clears every answer given after it,
  // so the call never carries on down a path it has left.
  const pick = (id, key) => {
    let picks = { ...st.picks };
    let order = [...(st.order || [])];
    if (picks[id] !== key) {
      const i = order.indexOf(id);
      if (i >= 0) { for (const later of order.slice(i)) delete picks[later]; order = order.slice(0, i); }
      picks[id] = key;
      order.push(id);
    }
    const s1 = { ...st, picks, order, finishing: false };
    const nb = buildCall(s1, lib).nodes;
    const i = nb.findIndex(n => n.id === id);
    setSt({ ...s1, at: (nb[i + 1] || nb[i] || {}).id || id });
  };
  const score = (key, v) => setSt(s => ({ ...s, scores: { ...s.scores, [key]: s.scores[key] === v ? null : v } }));
  // A product joins the conversation: from a link in the script (its Uncover and
  // Bridge follow the step you are on) or from the tag (the call goes there now).
  const addProduct = (id, href, jump = false) => {
    const first = rec?.products?.[0];
    if (!id || id === first || (st.extra || []).includes(id)) return;
    const op = /[?&]opener=([^&#]+)/.exec(href || "");
    const s1 = { ...st, extra: [...(st.extra || []), id] };
    if (op) { s1.picks = { ...st.picks, [`op.${id}`]: decodeURIComponent(op[1]) }; s1.order = [...(st.order || []), `op.${id}`]; }
    if (jump) {
      const nb = buildCall(s1, lib).nodes;
      const hit = nb.find(n => n.id.startsWith(`fit.${id}.`) || n.id === `op.${id}`);
      if (hit) s1.at = hit.id;
    }
    setSt(s1);
  };
  const removeProduct = (id) => setSt(s => ({ ...s, extra: (s.extra || []).filter(x => x !== id) }));
  const endCall = () => {
    if (!window.confirm("End this call without logging it?")) return;
    setJustLogged(false);
    setSt(freshCall(st.mode));
  };
  const nextCall = () => { setJustLogged(false); setSt(freshCall(st.mode)); };

  // Arrow keys move through the script when nobody is typing.
  useEffect(() => {
    if (!st.started || st.finishing || !node || node.kind === "finish") return undefined;
    const onKey = (e) => {
      if (e.target?.closest?.("input, textarea, select, [contenteditable]")) return;
      if (e.key === "ArrowRight" && canNext) { e.preventDefault(); next(); }
      if (e.key === "ArrowLeft") { e.preventDefault(); back(); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  const modeBar = (
    <div style={{ display: "flex", flexWrap: "wrap", gap: 12, alignItems: "center", justifyContent: "space-between" }}>
      <SegToggle value={st.mode} onChange={setMode} options={MODES} big />
      {!st.started && !st.at && (
        <button type="button" style={linkBtn} onClick={() => setSt(s => ({ ...s, plain: !s.plain }))}>{st.plain ? "Back to calls" : "Log without a script"}</button>
      )}
    </div>
  );

  if (!st.started) {
    return (
      <div className="nw-live" style={{ display: "grid", gap: 16 }}>
        {modeBar}
        <LiveSourceWarning problems={problems} />
        {st.plain && !st.at
          ? <LogTab values={values} sources={sources} types={types} isOwner={isOwner} isAdmin={isAdmin} myTeamId={myTeamId} roster={roster} nameOf={nameOf} onLogged={onLogged} refreshKey={refreshKey} />
          : <LiveStart who={st.who} resuming={!!st.at}
              onWho={(p) => setSt(s => ({ ...s, who: { ...s.who, ...p } }))}
              onPick={(c) => setSt(s => ({ ...s, onFile: Number(c.policies_on_file || 0),
                who: { ...s.who, kind: c.customer_kind || "person", first: c.customer_first_name || "", initial: c.customer_last_initial || "", phone: c.phone_last4 || s.who.phone } }))}
              onStart={() => setSt(s => ({ ...s, started: true, plain: false }))} />}
      </div>
    );
  }
  if (libErr) return <Notice kind="error">The scripts did not load: {libErr}</Notice>;
  if (!lib || !built || !node) return <div style={{ ...cardStyle, color: T.slate500, fontSize: 13 }}>Loading the scripts…</div>;

  const finishing = st.finishing || node.kind === "finish";
  const who = st.who;
  const label = who.kind === "org" ? who.first : `${who.first} ${String(who.initial || "").toUpperCase()}.`;
  const inCall = rec.fit && (rec.products || []).length ? rec.products : null;
  const partsIn = [...new Set(nodes.filter(n => n.part).map(n => n.part))];
  const jumpToPart = (key) => { const hit = nodes.find(n => n.part === key); if (hit) goTo(hit.id); };
  const prefill = {
    custKind: who.kind, first: who.first, initial: who.initial, phone: who.phone, age: who.age, gender: who.gender,
    relationship: rec.relationship, source: rec.source, activities: rec.activities, policies: rec.policies, scores: st.scores,
  };
  const requireCard = !!rec.fit || Object.values(st.scores || {}).some(v => v != null);
  const logCallHtml = built.logCall ? liveHtml(built.logCall, lib, { isPhone: vp.isPhone }) : "";
  const tag = !finishing ? (
    <LiveTag part={node.part} scores={st.scores || {}} onScore={score} rec={rec} lib={lib} values={values} types={types}
      partsIn={partsIn} onJump={jumpToPart} onAdd={(id) => addProduct(id, "", true)} onRemove={removeProduct} />
  ) : null;

  return (
    <div className="nw-live" style={{ display: "grid", gap: 16 }}>
      <ManualBodyStyles />
      <style>{LIVE_CSS}</style>
      {modeBar}
      <LiveSourceWarning problems={problems} />
      <div style={{ ...cardStyle, padding: "10px 14px", display: "flex", flexWrap: "wrap", gap: "6px 14px", alignItems: "center" }}>
        <span style={{ fontWeight: 800, color: T.slate900 }}>{label}</span>
        <span style={{ fontSize: 13, color: T.slate500 }}>·{who.phone}{who.age ? ` · ${who.age}` : ""}{who.gender ? ` · ${who.gender === "male" ? "Male" : "Female"}` : ""}</span>
        {!st.logged && <button type="button" style={linkBtn} onClick={() => setSt(s => ({ ...s, started: false }))}>Edit</button>}
        <span style={{ marginLeft: "auto", display: "flex", flexWrap: "wrap", gap: 16 }}>
          {!finishing && <button type="button" style={linkBtn} onClick={() => setSt(s => ({ ...s, finishing: true }))}>Finish the call</button>}
          {!st.logged && <button type="button" style={{ ...linkBtn, color: T.red }} onClick={endCall}>End without logging</button>}
        </span>
      </div>

      {finishing ? (
        st.logged && !justLogged ? (
          <div style={cardStyle}>
            <div style={{ fontSize: 15, fontWeight: 700, color: T.slate900 }}>This call is logged.</div>
            <button type="button" style={{ ...btnPrimary(false), marginTop: 12 }} onClick={nextCall}>Start the next call</button>
          </div>
        ) : (
          <div style={{ display: "grid", gap: 12 }}>
            {justLogged && (
              <div style={{ ...cardStyle, display: "flex", flexWrap: "wrap", gap: 12, alignItems: "center", justifyContent: "space-between" }}>
                <span style={{ fontSize: 15, fontWeight: 700, color: T.slate900 }}>Logged.</span>
                <button type="button" style={btnPrimary(false)} onClick={nextCall}>Start the next call</button>
              </div>
            )}
            {!justLogged && logCallHtml && (
              <details className="nw-live-more" style={{ ...cardStyle, padding: "12px 16px" }}>
                <summary>How to log it in ECRM</summary>
                <div className="newtworks-handbook-body" style={{ marginTop: 10 }} dangerouslySetInnerHTML={{ __html: logCallHtml }} />
              </details>
            )}
            <EntryPage key={finishKey} values={values} sources={sources} types={types} isOwner={isOwner} roster={roster} refreshKey={refreshKey}
              prefill={prefill} withAgeGender={who.kind !== "org"} requireCard={requireCard} hidePending allowCancel={!!rec.allowCancel}
              heading="Finish the call" subheading="Fill in what's left. One button saves it all."
              onSaved={() => { savedRef.current = true; setJustLogged(true); setSt(s => ({ ...s, logged: true })); }}
              onLogged={() => {
                if (savedRef.current) { savedRef.current = false; onLogged?.(); return; }
                // Undo: the call is open again, with everything it recorded.
                setJustLogged(false); setSt(s => ({ ...s, logged: false })); setFinishKey(k => k + 1); onLogged?.();
              }} />
            {!justLogged && <button type="button" style={{ ...linkBtn, justifySelf: "start" }} onClick={back}>‹ Back to the script</button>}
          </div>
        )
      ) : (
        <div style={{ display: "grid", gridTemplateColumns: narrow ? "minmax(0, 1fr)" : "minmax(0, 1fr) 250px", gap: 16, alignItems: "start" }}>
          {narrow && tag}
          <div style={cardStyle}>
            <LiveNode node={node} lib={lib} isPhone={vp.isPhone} inCall={inCall} onPick={(k) => pick(node.id, k)} onProduct={(id, href) => addProduct(id, href)} />
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 12, marginTop: 20 }}>
              <button type="button" style={{ ...btnGhost, padding: "9px 14px", fontSize: 13, opacity: pos === 0 ? 0.4 : 1 }} disabled={pos === 0} onClick={back}>‹ Back</button>
              {canNext && <button type="button" style={btnPrimary(false)} onClick={next}>Next ›</button>}
            </div>
          </div>
          {!narrow && tag}
        </div>
      )}
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
// ---------------------------------------------------------------------
// Opening a record to edit it. The five logged kinds share the one entry
// form; an appointment has its own editor and needs its row fetched first.
// History and the customer popup both come through here, so neither has to
// know which kind goes where.
// ---------------------------------------------------------------------
function RecordEditor({ target, values, sources, types, isOwner, roster, onLogged, refreshKey, onClose }) {
  const [apptRow, setApptRow] = useState(null);
  const [err, setErr] = useState("");
  const isAppt = target?.kind === "appointment";
  useEffect(() => {
    if (!isAppt) { setApptRow(null); return undefined; }
    let alive = true;
    setErr(""); setApptRow(null);
    (async () => {
      const { data, error } = await supabase.from("appointment_log").select(APPT_SELECT).eq("id", target.id).maybeSingle();
      if (!alive) return;
      if (error || !data) { setErr(errText(error || "that appointment is not on file any more")); return; }
      setApptRow(data);
    })();
    return () => { alive = false; };
  }, [isAppt, target?.id]);

  if (err) return <Notice kind="error">{err}</Notice>;
  if (isAppt) {
    if (!apptRow) return <div style={{ ...cardStyle, color: T.slate500, fontSize: 13 }}>Loading…</div>;
    return <EditRecord bare kind="appointment" row={apptRow} sources={sources} types={types} roster={roster}
      isOwner={isOwner} onClose={() => onClose("")} onSaved={() => onClose("Saved.")} />;
  }
  return <EntryPage values={values} sources={sources} types={types} isOwner={isOwner} roster={roster}
    onLogged={onLogged} refreshKey={refreshKey} allowCancel editing={target} onCloseEdit={onClose} />;
}

function HistoryTab({ values, sources, types, isOwner, isAdmin, myTeamId, roster, nameOf, onLogged, refreshKey }) {
  const [editing, setEditing] = useState(null);
  const [flash, setFlash] = useState("");
  const [listKey, setListKey] = useState(0);
  const closeEdit = (msg) => { setEditing(null); setFlash(msg || ""); setListKey(k => k + 1); };
  const openEdit = (target) => { setFlash(""); setEditing(target); };
  return (
    <div style={{ display: "grid", gap: 16 }}>
      <RecentEntries isAdmin={isAdmin} roster={roster} refreshKey={refreshKey + listKey} onEdit={openEdit} flash={flash} />
      {editing && (
        <Modal title="Editing a record already on file" onClose={() => closeEdit("")}>
          <RecordEditor target={editing} values={values} sources={sources} types={types} isOwner={isOwner}
            roster={roster} onLogged={onLogged} refreshKey={refreshKey} onClose={closeEdit} />
        </Modal>
      )}
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
// One name and one colour per kind of record. Every screen that lists them
// reads this, so History and the customer popup never drift apart.
const KIND_META = {
  sale:        { label: "Sale",               color: T.green },
  quote:       { label: "Quote",              color: T.blue },
  cancelation: { label: "Cancelation",        color: T.red },
  activity:    { label: "Activity",           color: T.purple },
  scorecard:   { label: "Conversation score", color: T.teal },
  appointment: { label: "Appointment",        color: T.amber },
};
const kindMeta = (k) => KIND_META[k] || { label: String(k || ""), color: T.slate700 };

const ENTRY_KIND_FILTERS = [
  { key: "", label: "Everything" },
  { key: "sale", label: "Sales" },
  { key: "quote", label: "Quotes" },
  { key: "cancelation", label: "Cancelations" },
  { key: "activity", label: "Activities" },
  { key: "appointment", label: "Appointments" },
  { key: "scorecard", label: "Conversation scores" },
];

// Peter 2026-09-22: History opens on the last 13 weeks, filled into the date
// boxes so it is plain what is showing. Any range can be picked.
const HISTORY_DEFAULT_WEEKS = 13;
const HISTORY_LIMIT = 2000;
function historyDefaultFrom() {
  const d = new Date(todayCentral() + "T12:00:00");
  d.setDate(d.getDate() - HISTORY_DEFAULT_WEEKS * 7);
  return d.toISOString().slice(0, 10);
}

function RecentEntries({ isAdmin, roster, refreshKey, onEdit, flash }) {
  const defFrom = historyDefaultFrom();
  const defTo = todayCentral();
  const [rows, setRows] = useState(null);
  const [who, setWho] = useState("");
  const [q, setQ] = useState("");
  const [term, setTerm] = useState("");
  const [from, setFrom] = useState(defFrom);
  const [to, setTo] = useState(defTo);
  const [recKind, setRecKind] = useState("");
  const [err, setErr] = useState("");
  const [busyId, setBusyId] = useState(null);
  // Cancelations still inside their reinstatement window (home 30 days, auto 15).
  // The server decides the window; this only shows the button where it would allow it.
  const [reinstate, setReinstate] = useState({});
  const [noted, setNoted] = useState(0);   // bumps after a note is added so the list reloads

  useEffect(() => { const t = setTimeout(() => setTerm(q.trim()), 300); return () => clearTimeout(t); }, [q]);

  useEffect(() => {
    let alive = true;
    (async () => {
      setErr("");
      const r = await supabase.rpc("rp_recent_entries", {
        // A name search reaches all the way back unless the dates were changed.
        p_days: 14, p_team_member_id: who || null, p_limit: HISTORY_LIMIT, p_search: term || null,
        p_from: (term && from === defFrom && to === defTo) ? null : (from || null),
        p_to: (term && from === defFrom && to === defTo) ? null : (to || null), p_kind: recKind || null,
      });
      if (!alive) return;
      if (r.error) { setErr(errText(r.error)); setRows([]); return; }
      setRows(Array.isArray(r.data) ? r.data : []);
      const ri = await supabase.rpc("rp_reinstatable_cancelations");
      if (alive && !ri.error) setReinstate(Object.fromEntries((ri.data || []).map(x => [x.id, x])));
    })();
    return () => { alive = false; };
  }, [who, term, from, to, recKind, refreshKey, noted]);

  const doReinstate = async (row) => {
    if (!window.confirm(`Reinstate this policy for ${row.customer_label || "this customer"}? The chargeback comes back, less the days it was out of force.`)) return;
    setBusyId(row.id); setErr("");
    try {
      const { data, error } = await supabase.rpc("rp_reinstate_cancelation", { p_id: row.id });
      if (error) { setErr(errText(error)); return; }
      const today = todayCentral();
      setReinstate(m => ({ ...m, [row.id]: { ...(m[row.id] || {}), reinstated_on: (data && data.reinstated_on) || today } }));
      setRows(list => (list || []).map(x => x.id === row.id && x.kind === row.kind
        ? { ...x, summary: `${x.summary || ""} · Reinstated ${fmtDate((data && data.reinstated_on) || today)}` } : x));
    } catch (e) { setErr(errText(e)); } finally { setBusyId(null); }
  };

  const remove = async (row) => {
    const what = kindMeta(row.kind).label.toLowerCase();
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
          <div style={{ fontSize: 13, color: T.slate500 }}>Anything dated or entered between these dates. A name search looks all the way back.</div>
        </div>
        <div style={{ display: "flex", flexWrap: "wrap", gap: 8 }}>
          <select value={recKind} onChange={e => setRecKind(e.target.value)} style={selectStyle}>
            {ENTRY_KIND_FILTERS.map(k => <option key={k.key} value={k.key}>{k.label}</option>)}
          </select>
          <input type="date" value={from} max={to || todayCentral()} title="From"
            onChange={e => setFrom(e.target.value)} style={selectStyle} />
          <input type="date" value={to} min={from || undefined} max={todayCentral()} title="To"
            onChange={e => setTo(e.target.value)} style={selectStyle} />
          {(from !== defFrom || to !== defTo || recKind) && (
            <button type="button" style={miniBtn} onClick={() => { setFrom(defFrom); setTo(defTo); setRecKind(""); }}>Clear</button>
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
        <div style={{ color: T.slate600, fontSize: 14 }}>{term ? `Nothing on file for “${term}”.` : "Nothing matches those filters."}</div>
      ) : (
        <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
          {rows.length >= HISTORY_LIMIT && (
            <div style={{ fontSize: 13, color: T.slate600, margin: "4px 0 10px" }}>Showing the newest {HISTORY_LIMIT.toLocaleString()}. Narrow the dates to see the rest.</div>
          )}
          <table style={{ width: "100%", borderCollapse: "collapse" }}>
            <thead>
              <tr>
                <th style={tableTh}>Date</th>
                <th style={tableTh}>What</th>
                <th style={tableTh}>Customer</th>
                {isAdmin && <th style={tableTh}>Who</th>}
                <th style={tableTh}>Details</th>
                <th style={tableTh}>Issued</th>
                <th style={tableTh}>ECRM</th>
                <th style={tableTh}></th>
              </tr>
            </thead>
            <tbody>
              {rows.map(r => (
                <tr key={`${r.kind}:${r.id}`}>
                  <td style={{ ...tableTd, whiteSpace: "nowrap" }}>{fmtDate(r.occurred_on)}</td>
                  <td style={{ ...tableTd, whiteSpace: "nowrap" }}>
                    <span style={{ fontWeight: 700, color: kindMeta(r.kind).color }}>{kindMeta(r.kind).label}</span>
                    {r.entry_source === "historical_backfill" && (
                      <span style={{ marginLeft: 6, padding: "1px 7px", borderRadius: 999, background: T.slate100, color: T.slate600, fontSize: 11, fontWeight: 700 }}>Historical</span>
                    )}
                  </td>
                  <td style={tableTd}><CustomerName label={r.customer_label} phone4={r.phone_last4} />{r.phone_last4 ? <span style={{ color: T.slate400 }}> ·{r.phone_last4}</span> : null}</td>
                  {isAdmin && <td style={{ ...tableTd, whiteSpace: "nowrap" }}>{r.who}</td>}
                  <td style={tableTd}>
                    {r.summary || "—"}
                    {r.amount != null && r.kind !== "scorecard" ? <span style={{ color: T.slate500 }}> · ${fmtPts(r.amount)}</span> : null}
                  </td>
                  <td style={{ ...tableTd, whiteSpace: "nowrap" }}>
                    {r.kind !== "sale" ? <span style={{ color: T.slate300 }}>—</span>
                      : r.issued_amount != null ? `$${fmtPts(r.issued_amount)}`
                      : <span style={{ color: T.slate400 }}>waiting</span>}
                  </td>
                  <td style={{ ...tableTd, whiteSpace: "nowrap" }}>
                    {r.ecrm_url ? <a href={r.ecrm_url} target="ecrm" rel="noreferrer" style={{ color: T.blue }}>ECRM</a>
                      : <span style={{ color: T.slate300 }}>—</span>}
                  </td>
                  <td style={{ ...tableTd, whiteSpace: "nowrap", textAlign: "right" }}>
                    {r.kind === "cancelation" && reinstate[r.id] && !reinstate[r.id].reinstated_on && (
                      <button style={{ ...miniBtn, marginRight: 6, color: T.green }} disabled={busyId === r.id}
                        title={`Can be reinstated through ${fmtDate(reinstate[r.id].reinstate_until)}`}
                        onClick={() => doReinstate(r)}>Reinstate</button>
                    )}
                    {r.can_change ? (
                      <>
                        <button style={{ ...miniBtn, marginRight: 6 }} disabled={busyId === r.id} onClick={() => onEdit({ kind: r.kind, id: r.id })}>Edit</button>
                        <button style={{ ...miniBtn, color: T.red }} disabled={busyId === r.id} onClick={() => remove(r)}>Delete</button>
                      </>
                    ) : r.can_note
                      ? <AddNoteButton kind={r.kind} id={r.id} onSaved={() => setNoted(n => n + 1)} />
                      : <span style={{ color: T.slate400, fontSize: 12 }}>closed</span>}
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
// Customer account — one household's whole record, in a popup.
// Peter 2026-09-18: click a customer's name on any tab and see everything
// on file for them, newest first, and change any of it without leaving
// the popup.
//
// Reads rp_customer_account, which matches on the same household key the
// log uses: first name, last initial, last four of the phone. A record
// logged before the phone rule has no phone and still matches. When more
// than one phone turns up under one name the popup says so, because that
// is two households sharing a name.
//
// Edit opens inside this popup, not somewhere else. The five logged kinds
// open the one entry form, the same form the History tab uses, so there
// is still only one place that knows how to edit an entry. An appointment
// has its own editor and opens that, with its popup shell dropped since
// this one is already open. The server decides per row whether this
// person may change it, so Edit only shows where the change would go
// through anyway.
//
// The name itself is <CustomerName> from lib/customerAccount.jsx. It reads
// the provider set up in the shell below, so no tab passes anything down.
// =====================================================================
function CustomerAccount({ token, values, sources, types, isOwner, roster, onLogged, onClose }) {
  const { label, phone4 } = parseAcctToken(token);
  const [data, setData] = useState(null);
  const [err, setErr] = useState("");
  const [flash, setFlash] = useState("");
  const [reload, setReload] = useState(0);
  const [editing, setEditing] = useState(null);   // { kind, id } of the record being changed
  const [busyId, setBusyId] = useState(null);

  useEffect(() => {
    let alive = true;
    setData(null); setErr("");
    (async () => {
      const r = await supabase.rpc("rp_customer_account", { p_label: label, p_phone_last4: phone4 || null });
      if (!alive) return;
      if (r.error) { setErr(errText(r.error)); return; }
      if (r.data && r.data.ok === false) { setErr(errText(r.data)); return; }
      setData(r.data && typeof r.data === "object" ? r.data : null);
    })();
    return () => { alive = false; };
  }, [label, phone4, reload]);

  const closeEdit = (msg) => {
    setEditing(null); setFlash(msg || "");
    setReload(k => k + 1);
    onLogged?.();
  };

  const openEdit = (r) => { setFlash(""); setErr(""); setEditing({ kind: r.kind, id: r.id }); };

  const c = data?.customer || {};
  const t = data?.totals || {};
  const policies = Array.isArray(data?.policies) ? data.policies : [];
  const timeline = Array.isArray(data?.timeline) ? data.timeline : [];
  const phones = Array.isArray(c.phones) ? c.phones : [];
  const prod = (line, key) => typeLabel(types || {}, line, key) || PRODUCT_SHORT[line] || line || "—";
  const plain = (s) => s ? String(s).replace(/_/g, " ") : "";
  const editingSomething = !!editing;
  const title = editingSomething
    ? `Editing a record on file for ${c.label || label}`
    : `${c.label || label}${c.phone_last4 ? ` · ${c.phone_last4}` : ""}`;

  const remove = async (r) => {
    const what = kindMeta(r.kind).label.toLowerCase();
    if (!window.confirm(`Delete this ${what} for ${c.label || label}? It stops counting straight away.`)) return;
    setBusyId(r.id); setErr(""); setFlash("");
    try {
      const { data: res, error } = await supabase.rpc("rp_delete_record", { p_kind: r.kind, p_id: r.id, p_reason: null });
      if (error) { setErr(errText(error)); return; }
      if (res && res.ok === false) { setErr(errText(res)); return; }
      setFlash("Deleted."); setReload(k => k + 1); onLogged?.();
    } catch (e) { setErr(errText(e)); } finally { setBusyId(null); }
  };

  return (
    <Modal title={title} onClose={editingSomething ? () => closeEdit("") : onClose}>
      {err && <Notice kind="error">{err}</Notice>}

      {editing && (
        <RecordEditor target={editing} values={values} sources={sources} types={types} isOwner={isOwner}
          roster={roster} onLogged={onLogged} refreshKey={reload} onClose={closeEdit} />
      )}

      {!editingSomething && !data && !err && <div style={{ ...cardStyle, color: T.slate500, fontSize: 13 }}>Loading…</div>}

      {!editingSomething && data && (
        <div style={{ display: "grid", gap: 12 }}>
          {flash && <Notice kind="ok">{flash}</Notice>}

          <div style={{ ...cardStyle, padding: 14, display: "grid", gap: 10 }}>
            <div style={{ fontSize: 13, color: T.slate600 }}>
              {c.relationship ? relationshipLabel(c.relationship) : "Not set"}
              {c.marketing_source ? ` · came from ${plain(c.marketing_source)}` : ""}
              {c.first_seen ? ` · first on file ${fmtDate(c.first_seen)}` : ""}
              {c.last_seen ? ` · last touched ${fmtDate(c.last_seen)}` : ""}
            </div>
            <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(110px, 1fr))", gap: 8 }}>
              <Stat label="Policies in force" value={`${Number(t.policies_in_force || 0)} of ${Number(t.policies || 0)}`} />
              <Stat label="Premium in force" value={`$${fmtPts(t.premium_in_force || 0)}`} />
              <Stat label="Quotes" value={Number(t.quotes || 0)} />
              <Stat label="Cancelations" value={Number(t.cancelations || 0)} />
              <Stat label="Activities" value={Number(t.activities || 0)} />
              <Stat label="Appointments" value={Number(t.appointments || 0)} />
            </div>
            {phones.length > 1 && (
              <div style={{ fontSize: 12, color: T.amber, fontWeight: 600 }}>
                More than one phone is on file under this name ({phones.join(", ")}). Everything under the name is shown together.
              </div>
            )}
          </div>

          <div style={{ ...cardStyle, padding: 14 }}>
            <div style={{ fontSize: 15, fontWeight: 700, color: T.slate900, marginBottom: 8 }}>Policies</div>
            {policies.length === 0 ? (
              <div style={{ fontSize: 13, color: T.slate600 }}>Nothing sold to this household yet.</div>
            ) : (
              <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
                <table style={{ width: "100%", borderCollapse: "collapse" }}>
                  <thead>
                    <tr>
                      <th style={tableTh}>Policy</th>
                      <th style={tableTh}>Submitted at</th>
                      <th style={tableTh}>Issued at</th>
                      <th style={tableTh}>Submitted</th>
                      <th style={tableTh}>Issued</th>
                      <th style={tableTh}>Standing</th>
                      <th style={tableTh}>Sold by</th>
                    </tr>
                  </thead>
                  <tbody>
                    {policies.map(p => (
                      <tr key={p.sale_product_id}>
                        <td style={tableTd}>
                          {prod(p.line_of_business, p.product_type)}
                          {p.vehicle_count ? <span style={{ color: T.slate500 }}> · {plural(p.vehicle_count, "car")}</span> : null}
                          {p.is_added_to_existing ? <div style={{ fontSize: 11, color: T.slate400 }}>added to one they had</div> : null}
                        </td>
                        <td style={tableTd}>${fmtPts(p.premium)}</td>
                        <td style={tableTd}>{p.issued_premium != null ? `$${fmtPts(p.issued_premium)}` : <span style={{ color: T.slate400 }}>—</span>}</td>
                        <td style={{ ...tableTd, whiteSpace: "nowrap" }}>{fmtDate(p.submitted_date)}</td>
                        <td style={{ ...tableTd, whiteSpace: "nowrap" }}>{p.issued_date ? fmtDate(p.issued_date) : <span style={{ color: T.slate400 }}>waiting</span>}</td>
                        <td style={{ ...tableTd, whiteSpace: "nowrap" }}>
                          {p.canceled_on
                            ? <span style={{ color: T.red, fontWeight: 700 }}>canceled {fmtDate(p.canceled_on)}</span>
                            : <span style={{ color: T.green, fontWeight: 700 }}>in force</span>}
                          {p.autopay_enrolled ? <div style={{ fontSize: 11, color: T.slate500 }}>autopay</div> : null}
                        </td>
                        <td style={{ ...tableTd, whiteSpace: "nowrap" }}>{p.sold_by}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>

          <div style={{ ...cardStyle, padding: 14 }}>
            <div style={{ fontSize: 15, fontWeight: 700, color: T.slate900, marginBottom: 2 }}>Everything logged</div>
            <div style={{ fontSize: 12, color: T.slate500, marginBottom: 10 }}>Newest first. Tap Edit on any of it.</div>
            {timeline.length === 0 ? (
              <div style={{ fontSize: 13, color: T.slate600 }}>Nothing on file for this household.</div>
            ) : (
              <div style={{ display: "grid", gap: 8 }}>
                {timeline.map(r => {
                  const k = kindMeta(r.kind);
                  const m = r.meta || {};
                  return (
                    <div key={`${r.kind}:${r.id}`} style={{ display: "flex", flexWrap: "wrap", gap: 10, alignItems: "flex-start", padding: "8px 0", borderTop: `1px solid ${T.slate100}` }}>
                      <div style={{ width: 78, flexShrink: 0, fontSize: 12, color: T.slate500, whiteSpace: "nowrap" }}>{fmtDate(r.occurred_on)}</div>
                      <div style={{ width: 110, flexShrink: 0 }}>
                        <span style={{ fontSize: 12, fontWeight: 700, color: k.color }}>{k.label}</span>
                        {r.entry_source === "historical_backfill" && (
                          <div style={{ fontSize: 10, color: T.slate400, fontWeight: 700 }}>Historical</div>
                        )}
                        {m.derived && <div style={{ fontSize: 10, color: T.slate400 }}>from a sale</div>}
                      </div>
                      <div style={{ flex: "1 1 200px", minWidth: 0, fontSize: 13, color: T.slate800 }}>
                        {r.summary || "—"}
                        {r.amount != null && r.kind !== "scorecard" ? <span style={{ color: T.slate500 }}> · ${fmtPts(r.amount)}</span> : null}
                        {r.issued_amount != null ? <span style={{ color: T.slate500 }}> · issued ${fmtPts(r.issued_amount)}</span> : null}
                        {m.reason ? <div style={{ fontSize: 11, color: T.slate500 }}>reason: {plain(m.reason)}</div> : null}
                        {m.save_reason ? <div style={{ fontSize: 11, color: T.slate500 }}>{m.save_reason}</div> : null}
                        {r.note ? <div style={{ fontSize: 12, color: T.slate500, marginTop: 2 }}>{r.note}</div> : null}
                        {r.ecrm_url ? <div><a href={r.ecrm_url} target="ecrm" rel="noreferrer" style={{ fontSize: 11, color: T.blue }}>ECRM</a></div> : null}
                      </div>
                      <div style={{ width: 84, flexShrink: 0, textAlign: "right", fontSize: 12, color: T.slate500 }}>{r.who}</div>
                      <div style={{ width: 110, flexShrink: 0, textAlign: "right", whiteSpace: "nowrap" }}>
                        {m.derived
                          ? <span style={{ color: T.slate300, fontSize: 11 }}>auto</span>
                          : r.can_change ? (
                            <>
                              <button type="button" style={{ ...miniBtn, marginRight: 6 }} disabled={busyId === r.id} onClick={() => openEdit(r)}>Edit</button>
                              <button type="button" style={{ ...miniBtn, color: T.red }} disabled={busyId === r.id} onClick={() => remove(r)}>Delete</button>
                            </>
                          ) : r.can_note
                            ? <AddNoteButton kind={r.kind} id={r.id} onSaved={() => setReload(n => n + 1)} />
                            : <span style={{ color: T.slate400, fontSize: 11 }}>closed</span>}
                      </div>
                    </div>
                  );
                })}
              </div>
            )}
          </div>

        </div>
      )}
    </Modal>
  );
}

// =====================================================================
// History and its sub-tabs (Peter 2026-09-25): Changes, Spot-check and
// Backfill moved in under History. Each is the same component it was as a
// top tab, with the same rule on who sees it. An old link to ?tab=changes,
// ?tab=spotcheck or ?tab=backfill (the daily change digest sends
// ?tab=changes&day=...) opens History on that sub-tab.
// Later the same day (Peter 2026-09-25): the four kinds that sat inside
// Changes (Notes, Issued, Canceled, Changes) moved up to be History sub-tabs
// of their own, in Changes' old spot and in CHANGE_KINDS order. Everyone sees
// them, as everyone saw Changes. Each one's URL name is its kind key
// (spot_check is Notes, not the Spot-check sub-tab). An old link to the
// Changes group (htab=changes) opens Notes, which is where the group opened.
// Peter 2026-09-26: History moved to the end of the everyone sub-tabs. It is
// still where History opens. Admin-only sub-tabs show plum and sit last.
// =====================================================================
const KIND_SUBTABS = CHANGE_KINDS.map(k => k.key);
const HISTORY_SUBTABS = [...KIND_SUBTABS, "history", "spotcheck", "backfill"];
const MOVED_UNDER_HISTORY = ["changes", "spotcheck", "backfill"];
function HistoryGroup({ values, sources, types, isOwner, isAdmin, myTeamId, roster, nameOf, refreshKey, onChanged }) {
  const [sub, setSub, subHref] = useTabParam("htab", "history", [...HISTORY_SUBTABS, "changes"]);
  // Each kind's count for the week or list on screen, sent up by ChangesTab.
  const [kindCounts, setKindCounts] = useState({});
  const subs = adminLast([
    // who changed what and when (Peter 2026-09-10); teammates see their own entries (2026-09-21)
    ...CHANGE_KINDS.map(k => ({ id: k.key, label: k.label })),
    { id: "history", label: "History" },
    { id: "spotcheck", label: "Spot-check", adminOnly: true },  // monthly check of self-logged entries, owner and managers only (Peter 2026-09-16)
    { id: "backfill", label: "Backfill", adminOnly: true },  // gaps on older records: phone, marketing source, ECRM link (Peter 2026-09-17)
  ], isAdmin);
  const want = sub === "changes" ? KIND_SUBTABS[0] : sub;
  const cur = subs.some(s => s.id === want) ? want : "history";
  const onKind = KIND_SUBTABS.includes(cur);
  // A sub-tab this person can't open falls back to History, and so does the URL.
  useEffect(() => { if (sub !== cur) setSub(cur); }, [sub, cur, setSub]);
  const subTab = (s) => (
    <TabLink key={s.id} href={subHref(s.id)} onSelect={() => setSub(s.id)} style={segTab(cur === s.id, s.adminOnly)}
      title={s.adminOnly ? "Only admins see this" : undefined}>{s.label}{onKind && kindCounts[s.id] != null ? ` (${kindCounts[s.id]})` : ""}</TabLink>
  );
  return (
    <div style={{ display: "grid", gap: 14 }}>
      <div style={{ display: "flex", maxWidth: "100%", overflowX: "auto", whiteSpace: "nowrap" }}>
        <div style={segWrap}>
          {subs.filter(s => !s.adminOnly).map(subTab)}
          {subs.some(s => s.adminOnly) && <span style={segAdminPart}>{subs.filter(s => s.adminOnly).map(subTab)}</span>}
        </div>
      </div>
      {cur === "history" && <HistoryTab values={values} sources={sources} types={types} isOwner={isOwner} isAdmin={isAdmin}
        myTeamId={myTeamId} roster={roster} nameOf={nameOf} onLogged={onChanged} refreshKey={refreshKey} />}
      {onKind && <ChangesTab kind={cur} onCounts={setKindCounts} roster={roster} nameOf={nameOf} values={values} sources={sources}
        types={types} isOwner={isOwner} isAdmin={isAdmin} myTeamId={myTeamId} refreshKey={refreshKey} onChanged={onChanged} />}
      {cur === "spotcheck" && isAdmin && <SpotCheck isAdmin={isAdmin} values={values} sources={sources}
        types={types} isOwner={isOwner} roster={roster} />}
      {cur === "backfill" && isAdmin && <BackfillTab sources={sources} roster={roster} types={types} />}
    </div>
  );
}

// =====================================================================
// Module shell
// =====================================================================
export default function ActivityLog({ userRole, userId }) {
  const _vp = useViewport();
  const _pad = _vp.isPhone ? "12px" : _vp.isTablet ? "16px 18px" : "20px 24px";
  // The Live tab is Peter's alone until he says it is finished (2026-10-04): for
  // anyone else it is not in the row, and a link to ?tab=live opens Log.
  const liveOn = canSeeLive(userRole);
  const [tab, setTab, tabHref] = useTabParam("tab", "log", [...TABS.filter(t => liveOn || t !== "live"), ...(canSeeEarnings(userRole) ? ["earnings"] : []), "history"]);
  const [acct, setAcct] = useTabParam("acct", "");   // the customer account popup, open from any tab
  // Changes, Spot-check and Backfill live under History now (Peter 2026-09-25).
  // A link to one of the old tabs opens History on that sub-tab instead.
  useEffect(() => {
    if (!MOVED_UNDER_HISTORY.includes(tab)) return;
    window.history.replaceState({}, "", hrefWithParam("htab", tab, "history"));
    setTab("history");
  }, [tab, setTab]);
  const [values, setValues] = useState([]);
  const [sources, setSources] = useState([]);
  const [types, setTypes] = useState({});
  const [roster, setRoster] = useState([]);
  const [directory, setDirectory] = useState([]);   // everyone who has ever been on the team, so old rows keep a name
  const [myTeamId, setMyTeamId] = useState(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const [head, setHead] = useState(null);   // this week's scoreboard, shown beside the title on every tab (your own row; team when you have none)
  const [commitInfo, setCommitInfo] = useState(null);  // today's commit, shown with the week's points (Peter 2026-09-14)
  const isAdmin = ["owner", "admin"].includes(userRole);
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
        supabase.from("retention_point_values").select("activity_key, label, points, category, requires_note, requires_ecrm, requires_platform, sort_order, description").eq("agency_id", AGENCY_ID).eq("is_active", true).order("sort_order"),
        supabase.from("sales_marketing_sources").select("source_key, label, sort_order").eq("agency_id", AGENCY_ID).eq("is_active", true).order("sort_order"),
        supabase.from("product_types").select("line_of_business, type_key, label, sort_order, one_per_household").eq("agency_id", AGENCY_ID).eq("is_active", true).order("sort_order"),
        supabase.from("team_directory").select("id, first_name, role_category, is_admin_backoffice, is_test_user, archived_at, category, is_active, license_pc, license_lh, authorized").eq("agency_id", AGENCY_ID).order("first_name"),
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
  // A call left open on the Live tab keeps a ring on its dot from any other tab.
  const callOpen = liveOn && tab !== "live" && liveCallOpen(userId);
  // Peter 2026-09-15: the production run of tabs first — what you log, how it
  // scored, what it could earn, what is waiting, what changed, and the whole
  // record behind it. Then a divider, then everything else.
  // Peter 2026-10-04: Live sits first. It walks a call one step at a time and will
  // take over from Log; until then Log stays as it is.
  const tabs = [
    ...(liveOn ? [{ id: "live", label: "Live" }] : []),
    { id: "log", label: "Log" },
    { id: "week", label: "Score" },
    ...(canSeeEarnings(userRole) ? [{ id: "earnings", label: "Earnings" }] : []),  // hidden for now (Peter 2026-10-05); was everyone (Peter 2026-09-04); Retention + Life Specialist curves inside are admin only
    { id: "issued", label: "Pending" },
    { id: "history", label: "History" },  // Changes, Spot-check and Backfill are its sub-tabs (Peter 2026-09-25)
    { type: "divider", id: "_dv_rest" },
    { id: "checklist", label: "Checklist" },
    { id: "hours", label: "Hours" },
    { id: "deposits", label: "Deposits" },
    { id: "development", label: "Development" },
    { id: "billing", label: "Dewey" },  // the billing explainer; one word (Peter 2026-09-25)
  ];

  // One provider for the whole Dashboard. Every customer name on every tab
  // reads it, including the tabs that live in their own file.
  const account = useMemo(() => ({
    open: (tok) => setAcct(tok),
    hrefFor: (tok) => hrefWithParam("acct", tok, ""),
  }), [setAcct]);

  return (
    <AccountCtx.Provider value={account}>
    <div style={{ padding: _pad, display: "grid", gap: 16 }}>
      {acct ? <CustomerAccount token={acct} values={values} sources={sources} types={types} isOwner={isOwner}
                roster={roster} onLogged={bump} onClose={() => setAcct("")} /> : null}
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
            ? [["Marketing", fmtWk(me.marketing?.points)], ["HH Quotes", Number(me.quotes?.count || 0)], ["Sales Pts", fmtWk(me.sales?.points)], ["Retention", fmtWk(me.retention?.net)]]
            : [["Marketing", fmtWk(t.marketing)], ["HH Quotes", Number(t.quotes || 0)], ["Sales Pts", fmtWk(t.sales)], ["Retention", fmtWk(t.retention_net)]];
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
      <style>{LIVE_TAB_CSS}</style>
      <div style={{ display: "flex", gap: 6, overflowX: "auto", whiteSpace: "nowrap", borderBottom: `1px solid ${T.slate200}`, paddingBottom: 6 }}>
        {tabs.map(t => (
          t.type === "divider"
            ? <span key={t.id} aria-hidden="true" style={{ flexShrink: 0, alignSelf: "stretch", width: 1, background: T.slate200, margin: "2px 6px" }} />
            : <TabLink key={t.id} href={tabHref(t.id)} onSelect={() => setTab(t.id)} title={t.id === "live" && callOpen ? "A call is in progress" : undefined} style={{
                flexShrink: 0, padding: "8px 14px", borderRadius: 8, fontSize: 13, fontWeight: 700, textDecoration: "none",
                background: tab === t.id ? T.blueLt : "transparent", color: tab === t.id ? T.blue : T.slate600,
              }}>{t.id === "live"
                ? <span style={{ display: "inline-flex", alignItems: "center", gap: 7 }}><span aria-hidden="true" className={`nw-live-dot${callOpen ? " open" : ""}`} />{t.label}</span>
                : t.label}</TabLink>
        ))}
      </div>

      {tab === "live" && liveOn && <LiveTab values={values} sources={sources} types={types} isOwner={isOwner} isAdmin={isAdmin} myTeamId={myTeamId} roster={roster} nameOf={nameOf} onLogged={bump} refreshKey={refreshKey} userId={userId} userRole={userRole} />}
      {tab === "log" && <LogTab values={values} sources={sources} types={types} isOwner={isOwner} isAdmin={isAdmin} myTeamId={myTeamId} roster={roster} nameOf={nameOf} onLogged={bump} refreshKey={refreshKey} />}
      {tab === "checklist" && <ChecklistTab />}
      {tab === "issued" && <IssuedTab values={values} sources={sources} types={types} roster={roster} nameOf={nameOf} isOwner={isOwner} isAdmin={isAdmin} myTeamId={myTeamId} refreshKey={refreshKey} onChanged={bump} />}
      {tab === "week" && <WeekView isAdmin={isAdmin} isOwner={isOwner} myTeamId={myTeamId} roster={roster} nameOf={nameOf} values={values} sources={sources} types={types} refreshKey={refreshKey} onChanged={bump} />}
      {tab === "hours" && <TimeHub embedded userRole={userRole} />}
      {tab === "deposits" && <PFA userRole={userRole} embedded />}
      {tab === "development" && <Development userRole={userRole} userId={userId} embedded />}
      {tab === "earnings" && canSeeEarnings(userRole) && <EarningPotentialTab isAdmin={isAdmin} />}
      {tab === "history" && <HistoryGroup values={values} sources={sources} types={types} isOwner={isOwner} isAdmin={isAdmin}
        myTeamId={myTeamId} roster={roster} nameOf={nameOf} refreshKey={refreshKey} onChanged={bump} />}
      {tab === "billing" && <DeweyOwe />}
    </div>
    </AccountCtx.Provider>
  );
}
