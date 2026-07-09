import { useState, useEffect } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { useViewport } from "../lib/hooks.js";
import { T } from "../lib/theme.js";

// =============================================================
// CPR DETAIL PAGE — Full weekly report
// Reachable at /cpr/{YYYY-MM-DD} where YYYY-MM-DD is week-ending Saturday.
// Renders the full Weekly CPR for that week — everything the
// Saturday email leaves out, plus everything it includes.
// Auth-gated by the parent shell.
// Layout authoritative source: persistent_memory.operational_rule
//   "CPR weekly email — canonical layout (locked 2026-06-17, refined 2026-06-18)"
// =============================================================

// ── Date helpers ─────────────────────────────────────────────
function isValidISODate(s) {
  return typeof s === "string" && /^\d{4}-\d{2}-\d{2}$/.test(s);
}

function addDaysISO(iso, days) {
  if (!isValidISODate(iso)) return null;
  const d = new Date(iso + "T00:00:00");
  d.setDate(d.getDate() + days);
  return d.toISOString().slice(0, 10);
}

function todayISO() {
  const d = new Date();
  const yyyy = d.getFullYear();
  const mm = String(d.getMonth() + 1).padStart(2, "0");
  const dd = String(d.getDate()).padStart(2, "0");
  return `${yyyy}-${mm}-${dd}`;
}

function fmtDateLong(iso) {
  if (!isValidISODate(iso)) return "—";
  try {
    return new Date(iso + "T00:00:00").toLocaleDateString("en-US", {
      weekday: "long", month: "long", day: "numeric", year: "numeric",
    });
  } catch { return iso; }
}

function fmtRange(satISO) {
  // Sat is week-ending; week starts the prior Sunday (6 days before)
  if (!isValidISODate(satISO)) return "—";
  try {
    const end = new Date(satISO + "T00:00:00");
    const start = new Date(end);
    start.setDate(end.getDate() - 6);
    const opts = { month: "short", day: "numeric" };
    return `${start.toLocaleDateString("en-US", opts)} – ${end.toLocaleDateString("en-US", opts)}`;
  } catch { return satISO; }
}

function fmtMMDD(iso) {
  if (!isValidISODate(iso)) return "—";
  try {
    const d = new Date(iso + "T00:00:00");
    return `${d.getMonth() + 1}/${d.getDate()}`;
  } catch { return iso; }
}

// ── Formatters ───────────────────────────────────────────────
const fmtMoney = (n) => {
  if (n === null || n === undefined || n === "") return "—";
  const v = Number(n);
  if (!isFinite(v)) return "—";
  return v.toLocaleString("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 });
};
const fmtMoneyCents = (n) => {
  if (n === null || n === undefined || n === "") return "—";
  const v = Number(n);
  if (!isFinite(v) || v === 0) return "—";
  return v.toLocaleString("en-US", { style: "currency", currency: "USD", minimumFractionDigits: 2, maximumFractionDigits: 2 });
};
const fmtInt = (n) => {
  if (n === null || n === undefined || n === "") return "—";
  const v = Number(n);
  if (!isFinite(v)) return "—";
  return Math.round(v).toLocaleString("en-US");
};
const fmtSigned = (n) => {
  if (n === null || n === undefined || n === "") return "—";
  const v = Number(n);
  if (!isFinite(v)) return "—";
  const r = Math.round(v);
  return r > 0 ? `+${r.toLocaleString("en-US")}` : r.toLocaleString("en-US");
};
const fmtPct = (n, decimals = 2) => {
  if (n === null || n === undefined || n === "") return "—";
  const v = Number(n);
  if (!isFinite(v)) return "—";
  return v.toFixed(decimals) + "%";
};

// ── Layout primitives ─────────────────────────────────────────
const Section = ({ children, style = {} }) => (
  <section style={{ marginBottom: 20, ...style }}>{children}</section>
);

const Card = ({ children, style = {} }) => (
  <div style={{
    background: T.white, borderRadius: 12,
    border: `1px solid ${T.slate200}`,
    padding: "18px 20px", ...style,
  }}>{children}</div>
);

const SectionHeader = ({ icon, title, accessory }) => (
  <div style={{ marginBottom: 12 }}>
    <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
      {icon ? <span style={{ fontSize: 18 }}>{icon}</span> : null}
      <span style={{
        fontSize: 13, fontWeight: 800, color: T.slate800,
        textTransform: "uppercase", letterSpacing: 0.6,
      }}>{title}</span>
      {accessory ? <span style={{ fontSize: 11, fontWeight: 400, color: T.slate500 }}>{accessory}</span> : null}
    </div>
  </div>
);

const Divider = () => (
  <div style={{
    height: 1, background: T.slate200,
    margin: "20px 0",
  }} aria-hidden="true" />
);

const Awaiting = ({ message = "Awaiting data" }) => (
  <div style={{
    display: "inline-flex", alignItems: "center", gap: 6,
    background: T.amberLt, color: T.slate700,
    borderRadius: 20, padding: "4px 12px",
    fontSize: 11, fontWeight: 600,
    border: "1px solid #FDE68A",
  }}>⏳ {message}</div>
);

const Th = ({ children, align = "left", w, style = {} }) => (
  <th style={{
    padding: "8px 8px", fontSize: 10, fontWeight: 700, color: T.slate500,
    textTransform: "uppercase", letterSpacing: 0.4, textAlign: align,
    borderBottom: `1px solid ${T.slate200}`, whiteSpace: "nowrap",
    ...(w ? { width: w } : {}), ...style,
  }}>{children}</th>
);

const Td = ({ children, align = "left", style = {}, ...rest }) => (
  <td
    {...rest}
    style={{
      padding: "8px 8px", fontSize: 12, color: T.slate800,
      textAlign: align, borderBottom: `1px solid ${T.slate100}`,
      fontVariantNumeric: "tabular-nums", ...style,
    }}
  >{children}</td>
);

// ── Edit-mode primitives ────────────────────────────────────
// Lightweight controlled inputs. All call onChange(value) — the section
// component wires that to the form dispatcher.
const inputBase = {
  fontSize: 13, color: T.slate900, padding: "6px 8px",
  border: `1px solid ${T.slate300}`, borderRadius: 6,
  background: T.white, fontFamily: "inherit",
  outline: "none", transition: "border-color 0.15s",
};
const focusStyle = (e) => { e.target.style.borderColor = T.blue; };
const blurStyle = (e) => { e.target.style.borderColor = T.slate300; };

function TextInput({ value, onChange, dirty, style = {} }) {
  return (
    <input
      type="text"
      value={value ?? ""}
      onChange={e => onChange(e.target.value)}
      onFocus={focusStyle}
      onBlur={blurStyle}
      style={{
        ...inputBase,
        width: "100%", boxSizing: "border-box",
        background: dirty ? T.amber50 || "#fef3c7" : T.white,
        ...style,
      }}
    />
  );
}
function NumberInput({ value, onChange, dirty, min, max, step = 1, style = {} }) {
  return (
    <input
      type="number"
      value={value === null || value === undefined ? "" : value}
      onChange={e => {
        const v = e.target.value;
        onChange(v === "" ? null : Number(v));
      }}
      onFocus={focusStyle}
      onBlur={blurStyle}
      min={min} max={max} step={step}
      style={{
        ...inputBase, width: 72, textAlign: "right",
        background: dirty ? T.amber50 || "#fef3c7" : T.white,
        ...style,
      }}
    />
  );
}
function TextArea({ value, onChange, dirty, rows = 3, style = {} }) {
  return (
    <textarea
      value={value ?? ""}
      onChange={e => onChange(e.target.value)}
      onFocus={focusStyle}
      onBlur={blurStyle}
      rows={rows}
      style={{
        ...inputBase,
        width: "100%", boxSizing: "border-box",
        lineHeight: 1.5, resize: "vertical",
        background: dirty ? T.amber50 || "#fef3c7" : T.white,
        ...style,
      }}
    />
  );
}
function Checkbox({ checked, onChange, dirty }) {
  return (
    <label style={{
      display: "inline-flex", alignItems: "center", justifyContent: "center",
      cursor: "pointer", padding: 4,
      background: dirty ? (T.amber50 || "#fef3c7") : "transparent",
      borderRadius: 4,
    }}>
      <input
        type="checkbox"
        checked={checked === true}
        onChange={e => onChange(e.target.checked)}
        style={{ width: 18, height: 18, cursor: "pointer", margin: 0 }}
      />
    </label>
  );
}
function LocationSelect({ value, onChange, dirty, style = {} }) {
  return (
    <select
      value={value ?? ""}
      onChange={e => onChange(e.target.value === "" ? null : e.target.value)}
      onFocus={focusStyle}
      onBlur={blurStyle}
      style={{
        ...inputBase, width: 90, padding: "5px 6px",
        background: dirty ? (T.amber50 || "#fef3c7") : T.white,
        ...style,
      }}
    >
      <option value="">—</option>
      <option value="office">office</option>
      <option value="remote">remote</option>
    </select>
  );
}

// ── Edit schema — which fields are editable + their DB table ────
// Used by useEditForm to initialize form state and by save() to build UPDATEs.
const EDIT_FIELDS = {
  report: [
    // Opener + Looking-at-Next-Week (canonical fields, read by send_weekly_cpr_recap)
    "opener_text", "looking_next_week_text",
    // Team checklist — single, report-level (was per-person × 5)
    "shareds_done", "texts_done", "deposits_done", "appts_done", "tasks_done",
    "cases_done", "no_onboarding_done", "no_fu_task_done", "new_opps_done",
    "no_phone_done", "bad_data_done",
    // Auto/Fire retention bonus
    "auto_ratio_pct", "auto_rank", "auto_bonus",
    "fire_ratio_pct", "fire_rank", "fire_bonus",
    // Claims + Non-Pays
    "non_pays", "new_claims", "open_claims", "unreviewed_claims",
    // Campaigns — stored on the CPR row (per-week snapshot); prefilled from most recent prior week
    "campaign_onboarding_date", "campaign_defectors_date",
    "campaign_single_line_date", "campaign_af_renewals_date",
    // EUR notes (free-form, weekly)
    "eur",
  ],
  // Agency Performance YTD fields — live on agency_snapshot (single source of truth).
  // Row keyed by (agency_id, snapshot_date=week_ending_date, cadence='weekly').
  // Prefill trigger fills these from prior weekly row on INSERT.
  // Lapse rate is intentionally NOT here — computed at runtime via compute_lapse_rate.
  snapshot: [
    "auto_new_ytd", "auto_lost_ytd",
    "fire_new_ytd", "fire_lost_ytd",
    "life_new_ytd", "life_lost_ytd",
    "life_paid_for_count_ytd",
    "life_paid_for_premium_ytd",
  ],
  detail: [
    "code_reds", "code_yellows",
    "cpr_reply_done", "wrapup_done", "inbox_done",
    "quotes_discussed", "sales_points",
    "quotes_modified",
  ],
};

// Roles allowed to edit a CPR. Mirrors the Newtworks role taxonomy.
const EDIT_ROLES = new Set(["owner", "manager"]);

// ── Checklist constants ─────────────────────────────────────
// Daily ops — items the team handles every day.
const DAILY_OPS_KEYS = [
  ["shareds_done", "Shared Outlook folders"],
  ["texts_done", "Texts recorded"],
  ["deposits_done", "Deposits finalized"],
  ["appts_done", "Appointments formatted"],
  ["tasks_done", "Tasks cleared"],
  ["cases_done", "Onboarding cases created"],
  ["no_onboarding_done", "Non-onboarding cases closed"],
];

// Opp lists cleared — opportunity backlog hygiene.
const OPP_LISTS_KEYS = [
  ["no_fu_task_done", "Missing follow-up"],
  ["new_opps_done", "New leads"],
  ["no_phone_done", "No phone"],
  ["bad_data_done", "Quotes w/ missing data"],
];

// Combined — used for hit/miss counting and the report-level booleans.
const TEAM_CHECKLIST_KEYS = [...DAILY_OPS_KEYS, ...OPP_LISTS_KEYS];

const PERSONAL_CHECKLIST_KEYS = [
  ["cpr_reply_done", "CPR Reply"],
  ["wrapup_done", "Wrap-up"],
  ["inbox_done", "Inbox"],
];

// ── Edit form hook ──────────────────────────────────────────
// Manages a working copy of editable fields + dirty tracking. Initialized
// from a snapshot of report + details when entering edit mode. Cancel
// discards; Save returns the dirty diff for the caller to persist.
function useEditForm() {
  const [active, setActive] = useState(false);
  const [form, setForm] = useState({ report: {}, snapshot: {}, details: {} });
  const [dirty, setDirty] = useState({ report: new Set(), snapshot: new Set(), details: {} });
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState(null);

  // begin(report, details, snapshot, prefills) — snapshot is the agency_snapshot row for
  // the current week (prefill trigger guarantees it exists for weekly-cadence rows).
  // prefills is an optional { field_name: fallback_value } dict for report-level fields.
  const begin = (report, details, snapshot = {}, prefills = {}) => {
    const r = {};
    for (const k of EDIT_FIELDS.report) {
      const dbVal = report?.[k];
      r[k] = (dbVal !== null && dbVal !== undefined) ? dbVal : (prefills[k] ?? null);
    }
    const s = {};
    for (const k of EDIT_FIELDS.snapshot) {
      const dbVal = snapshot?.[k];
      s[k] = (dbVal !== null && dbVal !== undefined) ? dbVal : null;
    }
    const d = {};
    for (const row of details || []) {
      const v = {};
      for (const k of EDIT_FIELDS.detail) v[k] = row?.[k] ?? null;
      d[row.id] = v;
    }
    setForm({ report: r, snapshot: s, details: d });
    setDirty({ report: new Set(), snapshot: new Set(), details: {} });
    setSaveError(null);
    setActive(true);
  };
  const cancel = () => {
    setForm({ report: {}, snapshot: {}, details: {} });
    setDirty({ report: new Set(), snapshot: new Set(), details: {} });
    setSaveError(null);
    setActive(false);
  };
  const setReportField = (field, value) => {
    setForm(f => ({ ...f, report: { ...f.report, [field]: value } }));
    setDirty(d => {
      const next = new Set(d.report); next.add(field);
      return { ...d, report: next };
    });
  };
  const setSnapshotField = (field, value) => {
    setForm(f => ({ ...f, snapshot: { ...f.snapshot, [field]: value } }));
    setDirty(d => {
      const next = new Set(d.snapshot); next.add(field);
      return { ...d, snapshot: next };
    });
  };
  const setDetailField = (rowId, field, value) => {
    setForm(f => ({
      ...f,
      details: { ...f.details, [rowId]: { ...f.details[rowId], [field]: value } },
    }));
    setDirty(d => {
      const existing = d.details[rowId] || new Set();
      const next = new Set(existing); next.add(field);
      return { ...d, details: { ...d.details, [rowId]: next } };
    });
  };
  const isReportDirty = (field) => dirty.report.has(field);
  const isSnapshotDirty = (field) => dirty.snapshot.has(field);
  const isDetailDirty = (rowId, field) => !!dirty.details[rowId]?.has(field);
  const totalDirty = dirty.report.size + dirty.snapshot.size +
    Object.values(dirty.details).reduce((s, set) => s + set.size, 0);

  return {
    active, form, dirty, saving, saveError,
    begin, cancel,
    setReportField, setSnapshotField, setDetailField,
    isReportDirty, isSnapshotDirty, isDetailDirty,
    totalDirty,
    setSaving, setSaveError,
    finishSave: () => {
      setActive(false);
      setForm({ report: {}, snapshot: {}, details: {} });
      setDirty({ report: new Set(), snapshot: new Set(), details: {} });
      setSaveError(null);
      setSaving(false);
    },
  };
}

// ── Data fetcher ────────────────────────────────────────────
function useCPRData(weekDate) {
  const [reloadKey, setReloadKey] = useState(0);
  const [state, setState] = useState({
    loading: true,
    error: null,
    report: null,        // weekly_cpr_reports row
    reportPrior: null,   // weekly_cpr_reports row for prior week (for Last Wk + Δ display)
    details: [],         // weekly_cpr_team_detail rows
    team: [],            // team table (active, by tenure)
    snapshot: null,      // agency_snapshot row with YTD data (most recent <= week end)
    snapshotPrior: null, // agency_snapshot row with YTD data (prior week)
    bookYearStart: null, // agency_snapshot row at year start
    bookCurrent: null,   // agency_snapshot row (most recent)
    goals: [],           // book_performance_goals rows (current year)
    campaignPriors: {},  // {onboarding_date, defectors_date, single_line_date, af_renewals_date} — most recent prior non-null per type
    truePayHistory: {},  // {team_member_id: [{week_ending_date, true_pay_bonus}]}
    anchorPayrollYtd: {},  // {team_member_id: payroll_ytd_paid as of 2026-04-04 anchor (or current cycle's prior-quarter-end)}
    retentionBudgetAnnual: null,  // annual retention budget from compute_retention_budget_weekly().budget — surfaces next to Service Share
    lastWeekSalesPointsByMember: {},  // {team_member_id: prior-week sales_points} — drives Team Activity WoW delta indicator
    cycleStartISO: null,  // current cycle start (YYYY-MM-DD) — used to suppress WoW delta across quarter boundary
    runtimeHours: {},    // {team_member_id: {mon|tue|wed|thu|fri: {hours, location}}}
    runtimeReqs: {},     // {team_member_id: {carryover, missed, cost, total, paid, owed, net_quotes, quotes_discussed, personal_misses, team_misses}}
    section11: null,     // get_cpr_section_11 result — SMVC & Scorecard data
  });

  useEffect(() => {
    if (!isValidISODate(weekDate) || !supabase) return;
    let cancelled = false;

    async function load() {
      setState(s => ({ ...s, loading: true, error: null }));
      try {
        const year = parseInt(weekDate.slice(0, 4), 10);

        // 1. Team (ALL members, including archived, tenure order).
        // Historical CPR rows can reference team_detail for members who have
        // since been terminated/archived. Filtering by is_active here would
        // leave those team_detail rows orphaned and display "(unknown)" on the page.
        const { data: teamRows } = await supabase
          .from("team")
          .select("id, first_name, last_name, nickname, hire_date, start_date, role, role_level, category, is_active, archived_at, annual_benefits_value")
          .eq("agency_id", AGENCY_ID)
          .eq("is_admin_backoffice", false)
          .order("hire_date", { ascending: true })
          .order("first_name", { ascending: true });

        // 2. Report row for this week
        const { data: reportRow } = await supabase
          .from("weekly_cpr_reports")
          .select("*")
          .eq("agency_id", AGENCY_ID)
          .eq("week_ending_date", weekDate)
          .maybeSingle();

        // 2b. Prior week's report row (for Last Wk + Δ display in Retention/Production section)
        const priorWeekDate = addDaysISO(weekDate, -7);
        const { data: reportPriorRow } = await supabase
          .from("weekly_cpr_reports")
          .select("*")
          .eq("agency_id", AGENCY_ID)
          .eq("week_ending_date", priorWeekDate)
          .maybeSingle();

        // 3. Detail rows for this week
        let detailRows = [];
        if (reportRow?.id) {
          const { data: dr } = await supabase
            .from("weekly_cpr_team_detail")
            .select("*")
            .eq("agency_id", AGENCY_ID)
            .eq("weekly_cpr_report_id", reportRow.id);
          detailRows = dr || [];
        }

        // 4. agency_snapshot — most recent row WITH YTD data on/before week end
        const { data: snapRows } = await supabase
          .from("agency_snapshot")
          .select("*")
          .eq("agency_id", AGENCY_ID)
          .lte("snapshot_date", weekDate)
          .not("auto_new_ytd", "is", null)
          .order("snapshot_date", { ascending: false })
          .limit(2);
        const snapshot = (snapRows && snapRows[0]) || null;
        const snapshotPrior = (snapRows && snapRows[1]) || null;

        // 4b. Lapse rate (canonical, server-computed). Single source of truth via
        // public.compute_lapse_rate(agency_id, as_of). See op-rule
        // "Lapse rate — never store, compute at runtime".
        const { data: lapseRows } = await supabase
          .rpc("compute_lapse_rate", { p_agency_id: AGENCY_ID, p_as_of: weekDate });
        const lapseRates = {};
        for (const r of (lapseRows || [])) {
          // annualized_rate is a decimal (0.3169 = 31.69%); consumers want percent
          if (r && r.line && r.annualized_rate != null) {
            lapseRates[r.line] = parseFloat(r.annualized_rate) * 100;
          }
        }

        // 5. agency_snapshot — year-start anchor + most recent (stock data)
        const yearStart = `${year}-01-01`;
        const { data: bookYS } = await supabase
          .from("agency_snapshot")
          .select("*")
          .eq("agency_id", AGENCY_ID)
          .eq("snapshot_date", yearStart)
          .maybeSingle();
        const { data: bookNowRows } = await supabase
          .from("agency_snapshot")
          .select("*")
          .eq("agency_id", AGENCY_ID)
          .lte("snapshot_date", weekDate)
          .order("snapshot_date", { ascending: false })
          .limit(1);
        const bookCurrent = (bookNowRows && bookNowRows[0]) || null;

        // 6. book_performance_goals — current year
        const { data: goalRows } = await supabase
          .from("book_performance_goals")
          .select("*")
          .eq("agency_id", AGENCY_ID)
          .eq("year", year);

        // 7. Campaign prefills — most recent prior week with a non-null value per type.
        // Stored directly on weekly_cpr_reports (one column per campaign type).
        const { data: priorCampRows } = await supabase
          .from("weekly_cpr_reports")
          .select("week_ending_date, campaign_onboarding_date, campaign_defectors_date, campaign_single_line_date, campaign_af_renewals_date")
          .eq("agency_id", AGENCY_ID)
          .lt("week_ending_date", weekDate)
          .order("week_ending_date", { ascending: false })
          .limit(30);
        const campaignPriors = {
          onboarding_date: null, defectors_date: null, single_line_date: null, af_renewals_date: null,
        };
        (priorCampRows || []).forEach(r => {
          if (!campaignPriors.onboarding_date && r.campaign_onboarding_date) campaignPriors.onboarding_date = r.campaign_onboarding_date;
          if (!campaignPriors.defectors_date  && r.campaign_defectors_date)  campaignPriors.defectors_date  = r.campaign_defectors_date;
          if (!campaignPriors.single_line_date && r.campaign_single_line_date) campaignPriors.single_line_date = r.campaign_single_line_date;
          if (!campaignPriors.af_renewals_date && r.campaign_af_renewals_date) campaignPriors.af_renewals_date = r.campaign_af_renewals_date;
        });

        // 8. True Pay Bonus history — last 39 weeks of weekly_cpr_team_detail
        // Pulls detail rows joined to reports ordered by week_ending_date desc
        const { data: histReports } = await supabase
          .from("weekly_cpr_reports")
          .select("id, week_ending_date")
          .eq("agency_id", AGENCY_ID)
          .lte("week_ending_date", weekDate)
          .order("week_ending_date", { ascending: false })
          .limit(39);
        let truePayHistory = {};
        let lastWeekSalesPointsByMember = {};
        if (histReports && histReports.length > 0) {
          const reportIds = histReports.map(r => r.id);
          const { data: histDetail } = await supabase
            .from("weekly_cpr_team_detail")
            .select("team_member_id, weekly_cpr_report_id, true_pay_bonus, sales_points")
            .eq("agency_id", AGENCY_ID)
            .in("weekly_cpr_report_id", reportIds);
          const reportDateById = {};
          histReports.forEach(r => { reportDateById[r.id] = r.week_ending_date; });
          (histDetail || []).forEach(d => {
            const tmId = d.team_member_id;
            if (!truePayHistory[tmId]) truePayHistory[tmId] = [];
            truePayHistory[tmId].push({
              week_ending_date: reportDateById[d.weekly_cpr_report_id],
              true_pay_bonus: Number(d.true_pay_bonus) || 0,
            });
          });
          Object.keys(truePayHistory).forEach(k => {
            truePayHistory[k].sort((a, b) => a.week_ending_date.localeCompare(b.week_ending_date));
          });
          // Last week's Q Sales Pts per member — used for the WoW delta indicator in Team Activity
          const lastWeekDate = (() => {
            const dt = new Date(weekDate + "T00:00:00Z");
            dt.setUTCDate(dt.getUTCDate() - 7);
            return dt.toISOString().slice(0, 10);
          })();
          (histDetail || []).forEach(d => {
            const wkDate = reportDateById[d.weekly_cpr_report_id];
            if (wkDate === lastWeekDate && d.sales_points != null) {
              lastWeekSalesPointsByMember[d.team_member_id] = Number(d.sales_points);
            }
          });
        }

        // Prior-quarter-end payroll YTD anchor for this week. Cycle anchor 2026-04-05 means
        // prior-quarter-end for any week in cycle 2 is 2026-04-04. Generic: floor((week-anchor)/91)*91
        // + anchor - 1 day = the Saturday before this cycle began.
        let anchorPayrollYtd = {};
        let cycleStartISO = null;
        try {
          const ANCHOR_DATE = "2026-04-05"; // cycle anchor (per settings cycle_anchor_date)
          const anchorMs = Date.UTC(2026, 3, 5);
          const wkMs = Date.UTC(
            parseInt(weekDate.slice(0,4),10),
            parseInt(weekDate.slice(5,7),10) - 1,
            parseInt(weekDate.slice(8,10),10)
          );
          const daysSince = Math.floor((wkMs - anchorMs) / 86400000);
          const cyclesCompleted = Math.max(0, Math.floor(daysSince / 91));
          const cycleStartMs = anchorMs + cyclesCompleted * 91 * 86400000;
          cycleStartISO = new Date(cycleStartMs).toISOString().slice(0,10);
          const priorQtrEndMs = cycleStartMs - 86400000;
          const priorQtrEndDate = new Date(priorQtrEndMs).toISOString().slice(0,10);
          const { data: anchorReport } = await supabase
            .from("weekly_cpr_reports")
            .select("id")
            .eq("agency_id", AGENCY_ID)
            .eq("week_ending_date", priorQtrEndDate)
            .maybeSingle();
          if (anchorReport?.id) {
            const { data: anchorDetail } = await supabase
              .from("weekly_cpr_team_detail")
              .select("team_member_id, payroll_ytd_paid")
              .eq("agency_id", AGENCY_ID)
              .eq("weekly_cpr_report_id", anchorReport.id);
            (anchorDetail || []).forEach(d => {
              anchorPayrollYtd[d.team_member_id] = d.payroll_ytd_paid;
            });
          }
        } catch (e) {
          console.warn("anchor payroll YTD fetch failed:", e);
        }

        // Retention budget (annual). Shown as parenthetical next to "Retention" label.
        let retentionBudgetAnnual = null;
        try {
          const { data: rbData } = await supabase
            .rpc("compute_retention_budget_weekly", {
              p_agency_id: AGENCY_ID,
              p_week_ending_date: weekDate,
            });
          if (rbData && typeof rbData === "object" && rbData.budget != null) {
            retentionBudgetAnnual = Number(rbData.budget);
          }
        } catch (e) {
          console.warn("compute_retention_budget_weekly failed:", e);
        }

        // 9. Runtime hours — get_weekly_cpr_hours blends TimeClock + work_location
        const { data: hoursRows, error: hoursError } = await supabase.rpc("get_weekly_cpr_hours", {
          p_agency_id: AGENCY_ID,
          p_week_ending_date: weekDate,
        });
        if (hoursError) {
          console.error("get_weekly_cpr_hours failed:", hoursError);
        }
        const runtimeHours = {};
        (hoursRows || []).forEach(h => {
          if (!runtimeHours[h.team_member_id]) runtimeHours[h.team_member_id] = {};
          runtimeHours[h.team_member_id][h.day_label] = {
            hours: h.hours != null ? Number(h.hours) : null,
            location: h.location || null,
            work_date: h.work_date || null,
          };
        });

        // 10. Runtime requirements — get_weekly_cpr_requirements computes
        // carryover/missed/cost/total/paid/owed/net_quotes per person.
        const { data: reqsRows, error: reqsError } = await supabase.rpc("get_weekly_cpr_requirements", {
          p_agency_id: AGENCY_ID,
          p_week_ending_date: weekDate,
        });
        if (reqsError) {
          console.error("get_weekly_cpr_requirements failed:", reqsError);
        }
        const runtimeReqs = {};
        (reqsRows || []).forEach(r => {
          runtimeReqs[r.team_member_id] = {
            carryover: Number(r.carryover) || 0,
            personal_misses: Number(r.personal_misses) || 0,
            team_misses: Number(r.team_misses) || 0,
            missed: Number(r.missed) || 0,
            cost: Number(r.cost) || 0,
            total: Number(r.total) || 0,
            modified: Number(r.modified) || 0,
            quotes_discussed: Number(r.quotes_discussed) || 0,
            paid: Number(r.paid) || 0,
            owed: Number(r.owed) || 0,
            net_quotes: Number(r.net_quotes) || 0,
          };
        });

        if (cancelled) return;

        // Section 11 data (SMVC & Scorecard) — fetched live via RPC
        let section11 = null;
        try {
          const { data: sec11Data } = await supabase
            .rpc("get_cpr_section_11", { p_agency_id: AGENCY_ID, p_week_ending_date: weekDate });
          if (!cancelled) section11 = sec11Data || null;
        } catch (e) {
          // Section 11 fetch failure shouldn't block the rest of the page
          console.warn("get_cpr_section_11 failed:", e);
        }

        // Prize Cart — 13 prizes for the cycle containing this week.
        // Filter: smallest quarter_ending_date >= weekDate, ordered by display_order.
        let prizeCart = [];
        try {
          const { data: prizeCartRows } = await supabase
            .from("prize_cart")
            .select("id, display_order, prize_description, prize_url, prize_value, winner_team_member_id, won_on")
            .eq("agency_id", AGENCY_ID)
            .gte("quarter_ending_date", weekDate)
            .order("quarter_ending_date", { ascending: true })
            .order("display_order", { ascending: true })
            .limit(13);
          if (!cancelled) prizeCart = prizeCartRows || [];
        } catch (e) {
          console.warn("prize_cart fetch failed:", e);
        }

        setState({
          loading: false, error: null,
          report: reportRow || null,
          reportPrior: reportPriorRow || null,
          details: detailRows,
          team: (teamRows || []).map(t => ({ ...t, full_name: t.nickname || t.first_name || "(no name)" })),
          snapshot,
          snapshotPrior,
          lapseRates,
          bookYearStart: bookYS || null,
          bookCurrent,
          goals: goalRows || [],
          campaignPriors,
          truePayHistory,
          anchorPayrollYtd,
          retentionBudgetAnnual,
          lastWeekSalesPointsByMember,
          cycleStartISO,
          runtimeHours,
          runtimeReqs,
          section11,
          prizeCart,
        });
      } catch (err) {
        if (!cancelled) {
          setState(s => ({ ...s, loading: false, error: err?.message || "Failed to load CPR data" }));
        }
      }
    }

    load();
    return () => { cancelled = true; };
  }, [weekDate, reloadKey]);

  return { ...state, refresh: () => setReloadKey(k => k + 1) };
}

// ── Goals lookup helper ──────────────────────────────────────
function goalFor(goals, lob, metric) {
  if (!goals) return null;
  const row = goals.find(g => g.lob === lob && g.metric === metric);
  return row ? Number(row.target_value) : null;
}

// ─────────────────────────────────────────────────────────────
// SECTIONS
// ─────────────────────────────────────────────────────────────

// 1 — Opener
function OpenerSection({ weekDate, report, editMode, formValue, dirty, onChange }) {
  // Opener stored in weekly_cpr_reports.opener_text.
  // Same field is read by send_weekly_cpr_recap when the Saturday email goes out.
  // In edit mode: render textarea wired to form. In view mode: render text or Awaiting.
  const text = report?.opener_text && report.opener_text.trim().length > 0 ? report.opener_text : null;
  return (
    <Card>
      <div style={{ fontSize: 11, color: T.slate500, marginBottom: 6, fontWeight: 600, letterSpacing: 0.4, textTransform: "uppercase" }}>
        CPR Recap — Week ending {fmtDateLong(weekDate)}
      </div>
      {editMode ? (
        <TextArea
          value={formValue}
          onChange={v => onChange("opener_text", v)}
          dirty={dirty}
          rows={8}
          style={{ fontSize: 14, lineHeight: 1.7 }}
        />
      ) : text ? (
        <div style={{
          fontSize: 14, color: T.slate800, lineHeight: 1.7, whiteSpace: "pre-wrap",
        }}>{text}</div>
      ) : (
        <Awaiting message="Opener pending" />
      )}
    </Card>
  );
}

// 3 — Looking At Next Week
function LookingNextWeekSection({ report, editMode, formValue, dirty, onChange }) {
  // Stored in weekly_cpr_reports.looking_next_week_text. Same field is read by
  // send_weekly_cpr_recap when the Saturday email goes out.
  const text = report?.looking_next_week_text && report.looking_next_week_text.trim().length > 0 ? report.looking_next_week_text : null;
  return (
    <div>
      <SectionHeader icon="🎯" title="Looking at Next Week" />
      <Card>
        {editMode ? (
          <TextArea
            value={formValue}
            onChange={v => onChange("looking_next_week_text", v)}
            dirty={dirty}
            rows={6}
            style={{ fontSize: 14, lineHeight: 1.7 }}
          />
        ) : text ? (
          <div style={{
            fontSize: 14, color: T.slate800, lineHeight: 1.7, whiteSpace: "pre-wrap",
          }}>{text}</div>
        ) : (
          <Awaiting message="Next-week focus items pending" />
        )}
      </Card>
    </div>
  );
}

// 5 — Code Reds / Yellows
function CodeRedsYellowsSection({ details, team, editMode, formDetails, isDirty, onChange }) {
  if (editMode) {
    // Edit mode: render per-person code_reds / code_yellows textareas
    const sorted = sortByTenure(details || [], team);
    if (sorted.length === 0) {
      return (
        <div>
          <SectionHeader title="Code Reds / Code Yellows" />
          <Card><Awaiting message="No team detail rows yet — code reds/yellows can be added once detail rows exist" /></Card>
        </div>
      );
    }
    return (
      <div>
        <SectionHeader title="Code Reds / Code Yellows" />
        <Card>
          <div style={{ display: "grid", gridTemplateColumns: "1fr", gap: 16 }}>
            {sorted.map(d => {
              const row = formDetails[d.id] || {};
              return (
                <div key={d.team_member_id} style={{
                  borderTop: `1px solid ${T.slate100}`, paddingTop: 12,
                }}>
                  <div style={{
                    fontSize: 12, fontWeight: 700, color: T.slate800, marginBottom: 8,
                  }}>{firstName(d.__name)}</div>
                  <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(220px, 1fr))", gap: 12 }}>
                    <div>
                      <div style={{ fontSize: 11, color: T.red, fontWeight: 700, marginBottom: 4 }}>🔴 Code Reds</div>
                      <TextArea
                        value={row.code_reds}
                        onChange={v => onChange(d.id, "code_reds", v)}
                        dirty={isDirty(d.id, "code_reds")}
                        rows={3}
                      />
                    </div>
                    <div>
                      <div style={{ fontSize: 11, color: T.amber, fontWeight: 700, marginBottom: 4 }}>🟡 Code Yellows</div>
                      <TextArea
                        value={row.code_yellows}
                        onChange={v => onChange(d.id, "code_yellows", v)}
                        dirty={isDirty(d.id, "code_yellows")}
                        rows={3}
                      />
                    </div>
                  </div>
                </div>
              );
            })}
          </div>
        </Card>
      </div>
    );
  }
  // View mode (unchanged from v1)
  // Aggregate code_reds / code_yellows text from detail rows
  const reds = [];
  const yellows = [];
  (details || []).forEach(d => {
    if (d.code_reds && d.code_reds.trim()) reds.push(d.code_reds.trim());
    if (d.code_yellows && d.code_yellows.trim()) yellows.push(d.code_yellows.trim());
  });
  const hasAny = reds.length > 0 || yellows.length > 0;
  return (
    <div>
      <SectionHeader title="Code Reds / Code Yellows" />
      <Card>
        {!hasAny ? (
          <div style={{ fontSize: 13, color: T.slate600 }}>
            🔴 0 reds &nbsp;•&nbsp; 🟡 0 yellows
          </div>
        ) : (
          <div>
            {reds.length > 0 && (
              <div style={{ marginBottom: yellows.length > 0 ? 14 : 0 }}>
                <div style={{ fontSize: 12, fontWeight: 700, color: T.red, marginBottom: 6 }}>
                  🔴 CODE REDS ({reds.length})
                </div>
                <ul style={{ margin: 0, paddingLeft: 18, fontSize: 13, color: T.slate800, lineHeight: 1.6 }}>
                  {reds.map((r, i) => <li key={i}>{r}</li>)}
                </ul>
              </div>
            )}
            {yellows.length > 0 && (
              <div>
                <div style={{ fontSize: 12, fontWeight: 700, color: T.amber, marginBottom: 6 }}>
                  🟡 CODE YELLOWS ({yellows.length})
                </div>
                <ul style={{ margin: 0, paddingLeft: 18, fontSize: 13, color: T.slate800, lineHeight: 1.6 }}>
                  {yellows.map((y, i) => <li key={i}>{y}</li>)}
                </ul>
              </div>
            )}
          </div>
        )}
      </Card>
    </div>
  );
}

// 6 — Team Checklist (full enumeration)
function TeamChecklistSection({ report, editMode, formReport, isReportDirty, onReportChange }) {
  if (!report) {
    return (
      <div>
        <SectionHeader icon="✅" title="Team Checklist" />
        <Card><Awaiting /></Card>
      </div>
    );
  }
  // Count hits when not editing — across both subsections combined
  // NULL = false per Peter directive 2026-07-05 (only strict true counts as a hit)
  const hits = TEAM_CHECKLIST_KEYS.filter(([k]) => report[k] === true).length;
  const total = TEAM_CHECKLIST_KEYS.length;
  const misses = TEAM_CHECKLIST_KEYS.filter(([k]) => report[k] !== true);

  // Render one subsection's grid
  const renderGrid = (keys) => (
    <div style={{
      display: "grid",
      gridTemplateColumns: "repeat(auto-fill, minmax(220px, 1fr))",
      gap: "10px 18px",
    }}>
      {keys.map(([key, label]) => {
        const val = editMode ? (formReport[key] ?? null) : report[key];
        const dirty = editMode ? isReportDirty(key) : false;
        return (
          <div key={key} style={{
            display: "flex", alignItems: "center", gap: 10,
            padding: "6px 8px", borderRadius: 6,
            background: dirty ? (T.amber50 || "#fef3c7") : "transparent",
          }}>
            {editMode ? (
              <Checkbox
                checked={val === true}
                onChange={v => onReportChange(key, v)}
                dirty={dirty}
              />
            ) : (
              <span style={{ fontSize: 14, width: 16, display: "inline-block", textAlign: "center" }}>
                {val === true
                  ? <span style={{ color: T.green }}>✓</span>
                  : <span style={{ color: T.red }}>✕</span>}
              </span>
            )}
            <span style={{ fontSize: 12, color: T.slate700 }}>{label}</span>
          </div>
        );
      })}
    </div>
  );

  const subheading = (text) => (
    <div style={{
      fontSize: 10, fontWeight: 800, color: T.slate500,
      letterSpacing: 0.6, textTransform: "uppercase",
      marginBottom: 6,
    }}>{text}</div>
  );

  return (
    <div>
      <SectionHeader
        icon="✅"
        title="Team Checklist"
      />
      <Card>
        {subheading("Daily Ops")}
        {renderGrid(DAILY_OPS_KEYS)}
        <div style={{ height: 14 }} />
        {subheading("Opp Lists Cleared")}
        {renderGrid(OPP_LISTS_KEYS)}
      </Card>
    </div>
  );
}

// 7 — Personal Checklist (CPR Reply / Wrap-up / Inbox per person)
function PersonalChecklistSection({ details, team, editMode, formDetails, isDirty, onChange }) {
  if (!details || details.length === 0) {
    return (
      <div>
        <SectionHeader icon="🧍" title="Personal Checklist" />
        <Card><Awaiting /></Card>
      </div>
    );
  }
  const sorted = sortByTenure(details, team);
  return (
    <div>
      <SectionHeader icon="🧍" title="Personal Checklist" />
      <Card style={{ padding: 0, overflow: "hidden" }}>
        <div style={{ overflowX: "auto" }}>
          <table style={{ width: "100%", borderCollapse: "collapse", minWidth: 480 }}>
            <thead>
              <tr>
                <Th align="left">Person</Th>
                {PERSONAL_CHECKLIST_KEYS.map(([key, label]) => (
                  <Th key={key} align="center">{label}</Th>
                ))}
              </tr>
            </thead>
            <tbody>
              {sorted.map(d => (
                <tr key={d.team_member_id}>
                  <Td style={{ paddingLeft: 14, color: T.slate700, fontWeight: 600 }}>{firstName(d.__name)}</Td>
                  {PERSONAL_CHECKLIST_KEYS.map(([key]) => {
                    if (editMode) {
                      return (
                        <Td key={key} align="center" style={{ padding: 4 }}>
                          <Checkbox
                            checked={(formDetails[d.id]?.[key] ?? null) === true}
                            onChange={v => onChange(d.id, key, v)}
                            dirty={isDirty(d.id, key)}
                          />
                        </Td>
                      );
                    }
                    return (
                      <Td key={key} align="center">
                        {d[key] === true
                          ? <span style={{ color: T.green, fontSize: 14 }}>✓</span>
                          : <span style={{ color: T.red, fontSize: 14 }}>✕</span>}
                      </Td>
                    );
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Card>
    </div>
  );
}

// 8 — Requirements (per-person Last Wk / This Wk / Cost / Total / Paid / Next Wk)
function RequirementsSection({ details, team, runtimeReqs, editMode, formDetails, isDirty, onChange }) {
  if (!details || details.length === 0) {
    return (
      <div>
        <SectionHeader icon="⭐" title="Requirements" />
        <Card><Awaiting /></Card>
      </div>
    );
  }
  const sorted = sortByTenure(details, team);
  // Math (locked 2026-06-20):
  //   Total      = (Last Wk + This Wk + Modified) × Cost
  //   Paid       = team-pool allocation against the new Total (server-computed)
  //   Next Wk    = Total − Paid
  // In edit mode we live-recompute Total + Next Wk from the dirty form value of
  // quotes_modified so the impact is visible before save. Paid is server-computed
  // and won't refresh until save.
  return (
    <div>
      <SectionHeader
        icon="⭐"
        title="Requirements"
      />
      <Card style={{ padding: 0, overflow: "hidden" }}>
        <div style={{ overflowX: "auto" }}>
          <table style={{ width: "100%", borderCollapse: "collapse", minWidth: 680 }}>
            <thead>
              <tr>
                <Th align="left">Person</Th>
                <Th align="right">Last Wk</Th>
                <Th align="right">This Wk</Th>
                <Th align="right">Modified</Th>
                <Th align="right">Cost</Th>
                <Th align="right">Total</Th>
                <Th align="right">Paid</Th>
                <Th align="right">Next Wk</Th>
              </tr>
            </thead>
            <tbody>
              {sorted.map(d => {
                const r = runtimeReqs?.[d.team_member_id] || {};
                const formMod = editMode ? (formDetails?.[d.id]?.quotes_modified ?? r.modified ?? 0) : (r.modified ?? 0);
                const dirty = editMode ? isDirty?.(d.id, "quotes_modified") : false;
                // Live-recompute Total + Next Wk when editing Modified.
                // Total = (carryover + missed + modified) × cost
                // Next Wk = Total − Paid  (Paid is server-computed; refreshes on save)
                const liveTotal = editMode
                  ? ((Number(r.carryover) || 0) + (Number(r.missed) || 0) + (Number(formMod) || 0)) * (Number(r.cost) || 1)
                  : r.total;
                const liveOwed = editMode
                  ? ((Number(liveTotal) || 0) - (Number(r.paid) || 0))
                  : r.owed;
                return (
                  <tr key={d.team_member_id}>
                    <Td style={{ paddingLeft: 14, color: T.slate700, fontWeight: 600 }}>{firstName(d.__name)}</Td>
                    <Td align="right">{fmtInt(r.carryover)}</Td>
                    <Td align="right">{fmtInt(r.missed)}</Td>
                    <Td align="right" style={{ padding: editMode ? 4 : undefined, background: dirty ? (T.amber50 || "#fef3c7") : undefined }}>
                      {editMode ? (
                        <NumberInput
                          value={formMod}
                          onChange={v => onChange(d.id, "quotes_modified", Number(v) || 0)}
                          dirty={dirty}
                          step={1}
                          style={{ width: 70 }}
                        />
                      ) : (
                        <span style={{ color: (Number(r.modified) || 0) === 0 ? T.slate500 : T.slate900 }}>{fmtSigned(Number(r.modified) || 0)}</span>
                      )}
                    </Td>
                    <Td align="right">{fmtInt(r.cost)}</Td>
                    <Td align="right">{fmtInt(liveTotal)}</Td>
                    <Td align="right">{fmtInt(r.paid)}</Td>
                    <Td align="right" style={{ fontWeight: 700, color: T.slate900 }}>{fmtInt(liveOwed)}</Td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </Card>
    </div>
  );
}

// 10 — Agency Performance (full version — all rows the email dropped)
function AgencyPerformanceSection({ snapshot, snapshotPrior, bookYearStart, goals, weekDate, lapseRates, report, reportPrior, editMode, formReport, isReportDirty, onReportChange, formSnapshot, isSnapshotDirty, onSnapshotChange }) {
  if (!snapshot) {
    return (
      <div>
        <SectionHeader icon="🎯" title="Agency Performance" />
        <Card><Awaiting message="No on-time snapshot loaded yet for this week" /></Card>
      </div>
    );
  }
  const autoYsPIF = bookYearStart?.auto_pif || null;
  const firePIF_YS = bookYearStart?.fire_pif || null;
  const lifePIF_YS = bookYearStart?.life_pif || null;

  // Helper: weekly delta (this snapshot vs prior week's snapshot)
  const wkDelta = (cur, prev) => {
    if (cur === null || cur === undefined || prev === null || prev === undefined) return null;
    return Number(cur) - Number(prev);
  };

  // On Time = year-end projection from current YTD pace.
  const daysElapsedIntoYear = (iso) => {
    if (!iso) return 1;
    const d = new Date(iso + "T00:00:00Z");
    const start = new Date(Date.UTC(d.getUTCFullYear(), 0, 1));
    return Math.max(1, Math.floor((d - start) / 86400000) + 1);
  };
  const daysElapsed = daysElapsedIntoYear(weekDate);

  // agency_snapshot is single source of truth for these 8 YTD fields.
  // In edit mode: show in-progress form values (still typing). Else: show saved snapshot row.
  const src = editMode ? (formSnapshot || {}) : (snapshot || {});
  const resolvedAutoNew     = src.auto_new_ytd;
  const resolvedAutoLost    = src.auto_lost_ytd;
  const resolvedFireNew     = src.fire_new_ytd;
  const resolvedFireLost    = src.fire_lost_ytd;
  const resolvedLifeNew     = src.life_new_ytd;
  const resolvedLifeLost    = src.life_lost_ytd;
  const resolvedLifeCount   = src.life_paid_for_count_ytd;
  const resolvedLifePremium = src.life_paid_for_premium_ytd;

  // Prior week's values — always from prior snapshot row (never editable).
  // Weekly deltas are computed against THESE so they reflect week-over-week change.
  const priorAutoNew     = snapshotPrior?.auto_new_ytd;
  const priorAutoLost    = snapshotPrior?.auto_lost_ytd;
  const priorFireNew     = snapshotPrior?.fire_new_ytd;
  const priorFireLost    = snapshotPrior?.fire_lost_ytd;
  const priorLifeNew     = snapshotPrior?.life_new_ytd;
  const priorLifeLost    = snapshotPrior?.life_lost_ytd;
  const priorLifeCount   = snapshotPrior?.life_paid_for_count_ytd;
  const priorLifePremium = snapshotPrior?.life_paid_for_premium_ytd;

  // Pull metrics (numeric, resolved)
  const auto_new   = Number(resolvedAutoNew)  || 0;
  const auto_lost  = Number(resolvedAutoLost) || 0;
  const fire_new   = Number(resolvedFireNew)  || 0;
  const fire_lost  = Number(resolvedFireLost) || 0;
  const life_new   = Number(resolvedLifeNew)  || 0;
  const life_lost  = Number(resolvedLifeLost) || 0;
  const life_count = Number(resolvedLifeCount) || 0;
  const life_prem  = Number(resolvedLifePremium) || 0;

  // Combined wk-delta for the On Time column when it represents Gain (new - lost).
  // Takes resolved values so it stays accurate when manual overrides are in play.
  const gainWkDR = (curNew, priorNew, curLost, priorLost) => {
    const a = wkDelta(curNew, priorNew);
    const b = wkDelta(curLost, priorLost);
    return (a === null || b === null) ? null : (a - b);
  };

  // Row definitions — one row per LOB / metric category.
  // Auto/Fire/Life are editable (new/lost/lapse); Life #/Life $ remain read-only.
  // Weekly deltas compare RESOLVED values (this week's override or snapshot) against
  // RESOLVED prior values (prior week's override or prior snapshot).
  const rows = [
    {
      label: "Auto", editable: true,
      newKey: "auto_new_ytd", lostKey: "auto_lost_ytd", target: "snapshot",
      newYtd:  auto_new,  newWkD:  wkDelta(resolvedAutoNew,  priorAutoNew),
      lostYtd: auto_lost, lostWkD: wkDelta(resolvedAutoLost, priorAutoLost),
      gainYtd: auto_new - auto_lost,
      onTimeWkD: gainWkDR(resolvedAutoNew, priorAutoNew, resolvedAutoLost, priorAutoLost),
      goal: goalFor(goals, "auto", "gain"),
      lapseRate: (lapseRates && lapseRates.auto != null) ? lapseRates.auto : null,
    },
    {
      label: "Fire", editable: true,
      newKey: "fire_new_ytd", lostKey: "fire_lost_ytd", target: "snapshot",
      newYtd:  fire_new,  newWkD:  wkDelta(resolvedFireNew,  priorFireNew),
      lostYtd: fire_lost, lostWkD: wkDelta(resolvedFireLost, priorFireLost),
      gainYtd: fire_new - fire_lost,
      onTimeWkD: gainWkDR(resolvedFireNew, priorFireNew, resolvedFireLost, priorFireLost),
      goal: goalFor(goals, "fire", "gain"),
      lapseRate: (lapseRates && lapseRates.fire != null) ? lapseRates.fire : null,
    },
    {
      label: "Life", editable: true,
      newKey: "life_new_ytd", lostKey: "life_lost_ytd", target: "snapshot",
      newYtd:  life_new,  newWkD:  wkDelta(resolvedLifeNew,  priorLifeNew),
      lostYtd: life_lost, lostWkD: wkDelta(resolvedLifeLost, priorLifeLost),
      gainYtd: life_new - life_lost,
      onTimeWkD: gainWkDR(resolvedLifeNew, priorLifeNew, resolvedLifeLost, priorLifeLost),
      goal: goalFor(goals, "life", "gain"),
      lapseRate: (lapseRates && lapseRates.life != null) ? lapseRates.life : null,
    },
    {
      label: "Life #", editable: true,
      ytdKey: "life_paid_for_count_ytd", target: "snapshot",
      newYtd:  null, newWkD:  null,
      lostYtd: null, lostWkD: null,
      gainYtd: life_count,
      onTimeWkD: wkDelta(resolvedLifeCount, priorLifeCount),
      goal: goalFor(goals, "life", "net_paid_for"),
      lapseRate: null,
    },
    {
      label: "Life $", editable: true,
      ytdKey: "life_paid_for_premium_ytd", target: "snapshot",
      newYtd:  null, newWkD:  null,
      lostYtd: null, lostWkD: null,
      gainYtd: life_prem,
      onTimeWkD: wkDelta(resolvedLifePremium, priorLifePremium),
      goal: goalFor(goals, "life", "premium"),
      isMoney: true,
      lapseRate: null,
    },
  ];

  // Delta display: "-" if flat/null; otherwise signed number (or signed money)
  const deltaText = (d, isMoney) => {
    if (d === null || d === undefined) return "—";
    const v = isMoney ? d : Math.round(d);
    if (Math.abs(v) < 0.001) return "—";
    const sign = v > 0 ? "+" : "";
    return isMoney ? sign + fmtMoney(v) : sign + v.toLocaleString("en-US");
  };
  // Per spec: green if up, red if down, grey if flat — uniform across all three delta columns.
  const deltaColor = (d) => {
    if (d === null || d === undefined) return T.slate500;
    const v = Number(d);
    if (!isFinite(v) || Math.abs(v) < 0.001) return T.slate500;
    return v > 0 ? T.green : T.red;
  };
  // Diff color: positive (above goal) = green, negative (below goal) = red.
  const diffColor = (diff) => {
    if (diff === null || diff === undefined) return T.slate500;
    if (Math.abs(diff) < 0.001) return T.slate500;
    return diff > 0 ? T.green : T.red;
  };

  return (
    <div>
      <SectionHeader icon="🎯" title="Agency Performance" />
      <Card style={{ padding: 0, overflow: "hidden" }}>
        <div style={{ overflowX: "auto" }}>
          <table style={{ width: "100%", borderCollapse: "collapse", minWidth: 760 }}>
            <thead>
              <tr>
                <Th align="left">LOB</Th>
                <Th align="right">New</Th>
                <Th align="right">Lost</Th>
                <Th align="right">Lapse</Th>
                <Th align="right">YTD</Th>
                <Th align="right" style={{ background: T.slate50 }}>On Time</Th>
                <Th align="right" style={{ background: T.slate50 }}>Goal</Th>
                <Th align="right" style={{ background: T.blueLt, color: T.slate800 }}>Diff</Th>
              </tr>
            </thead>
            <tbody>
              {rows.map(r => {
                const onTime = (Number(r.gainYtd) * 365) / daysElapsed;
                const onTimeRounded = r.isMoney ? onTime : Math.round(onTime);
                const diff = (r.goal !== null && r.goal !== undefined)
                  ? (onTime - Number(r.goal))
                  : null;
                const formatYtd = (v) => (v === null || v === undefined)
                  ? "—"
                  : (r.isMoney ? fmtMoney(v) : fmtInt(v));

                const renderValDelta = (ytd, wkD, bg, weightBoost) => {
                  if (ytd === null || ytd === undefined) {
                    return (
                      <Td align="right" style={{ background: bg, color: T.slate400 }}>—</Td>
                    );
                  }
                  return (
                    <Td align="right" style={{ background: bg }}>
                      <span style={{ fontWeight: weightBoost ? 700 : 500, color: T.slate900 }}>
                        {formatYtd(ytd)}
                      </span>
                      <span style={{ marginLeft: 6, color: deltaColor(wkD), fontWeight: 600 }}>
                        {deltaText(wkD, r.isMoney)}
                      </span>
                    </Td>
                  );
                };

                const editableRow = editMode && r.editable;
                // Dispatch input to the right bucket. Rows with target='snapshot' write to
                // agency_snapshot; all others (none currently) write to weekly_cpr_reports.
                const isSnap = r.target === "snapshot";
                const bucketForm = isSnap ? formSnapshot : formReport;
                const bucketChange = isSnap ? onSnapshotChange : onReportChange;
                const bucketDirty = isSnap ? isSnapshotDirty : isReportDirty;
                const renderEditOrVal = (key, ytd, wkD, bg) => {
                  if (editableRow && key) {
                    return (
                      <Td align="right" style={{ background: bg, padding: 4, whiteSpace: "nowrap" }}>
                        <NumberInput
                          value={bucketForm?.[key]}
                          onChange={v => bucketChange(key, v)}
                          dirty={bucketDirty?.(key)}
                          min={0}
                          step={1}
                          style={{ width: 70 }}
                        />
                        <span style={{ marginLeft: 6, color: deltaColor(wkD), fontWeight: 600, fontSize: 11 }}>
                          {deltaText(wkD, r.isMoney)}
                        </span>
                      </Td>
                    );
                  }
                  return renderValDelta(ytd, wkD, bg, false);
                };
                return (
                  <tr key={r.label}>
                    <Td style={{ paddingLeft: 14, color: T.slate700, fontWeight: 600 }}>{r.label}</Td>
                    {renderEditOrVal(r.newKey,  r.newYtd,  r.newWkD,  undefined)}
                    {renderEditOrVal(r.lostKey, r.lostYtd, r.lostWkD, undefined)}
                    <Td align="right">
                      {(r.lapseRate === null || r.lapseRate === undefined)
                        ? <span style={{ color: T.slate400 }}>—</span>
                        : <span style={{ color: T.slate900, fontWeight: 500 }}>{Number(r.lapseRate).toFixed(1)}%</span>}
                    </Td>
                    {editableRow && r.ytdKey ? (
                      <Td align="right" style={{ padding: 4, whiteSpace: "nowrap" }}>
                        <NumberInput
                          value={bucketForm?.[r.ytdKey]}
                          onChange={v => bucketChange(r.ytdKey, v)}
                          dirty={bucketDirty?.(r.ytdKey)}
                          min={0}
                          step={1}
                          style={{ width: 70 }}
                        />
                        <span style={{ marginLeft: 6, color: deltaColor(r.onTimeWkD), fontWeight: 600, fontSize: 11 }}>
                          {deltaText(r.onTimeWkD, r.isMoney)}
                        </span>
                      </Td>
                    ) : renderValDelta(r.gainYtd, r.onTimeWkD, undefined, false)}
                    {renderValDelta(onTimeRounded, r.onTimeWkD, T.slate50, true)}
                    <Td align="right" style={{ background: T.slate50, color: T.slate700 }}>
                      {(r.goal === null || r.goal === undefined)
                        ? "—"
                        : (r.isMoney ? fmtMoney(r.goal) : fmtInt(r.goal))}
                    </Td>
                    <Td align="right" style={{ background: T.blueLt, fontWeight: 700, color: diffColor(diff) }}>
                      {diff === null
                        ? "—"
                        : (r.isMoney
                            ? (diff >= 0 ? "+" : "") + fmtMoney(diff)
                            : fmtSigned(Math.round(diff)))}
                    </Td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </Card>
    </div>
  );
}

// 11 — SMVC & Scorecard
// Renders the SMVC row from get_cpr_section_11 (live computed) + a Scorecard Bonus
// row + two budget lines as placeholders. The compute_scorecard_bonus() function
// and budget formulas are pending; those cells show "—" until built.
function SMVCScorecardSection({ section11 }) {
  if (!section11) {
    return (
      <div>
        <SectionHeader icon="🎯" title="SMVC & Scorecard" />
        <Card><Awaiting message="No SMVC data loaded yet for this week" /></Card>
      </div>
    );
  }

  const smvc = section11.smvc || {};
  const onTime   = smvc.on_time     != null ? Number(smvc.on_time)     : null;
  const lastWk   = smvc.last_wk     != null ? Number(smvc.last_wk)     : null;
  const lastQ    = smvc.last_q      != null ? Number(smvc.last_q)      : null;
  // "Last Year" column for SMVC = this year's applied SMVC rate (agency.smvc_rate_pc).
  // That rate is the realized outcome of last year's performance, paid out this year.
  // Backend exposes both smvc.last_year and smvc.applied (same value) for the rename.
  const lastYear = smvc.last_year   != null ? Number(smvc.last_year)   : null;
  const diff     = smvc.dollar_diff != null ? Number(smvc.dollar_diff) : null;

  const fmtPct = (v) => v == null ? "—" : (v * 100).toFixed(2) + "%";
  const fmtDiff = (v) => {
    if (v == null) return "—";
    const sign = v >= 0 ? "+" : "-";
    return sign + "$" + Math.abs(Math.round(v)).toLocaleString("en-US");
  };
  const diffColor = diff == null ? T.slate500 : (diff >= 0 ? T.green : T.red);

  return (
    <div>
      <SectionHeader icon="🎯" title="SMVC & Scorecard" />
      <Card style={{ padding: 0, overflow: "hidden" }}>
        <div style={{ overflowX: "auto" }}>
          <table style={{ width: "100%", borderCollapse: "collapse", minWidth: 560 }}>
            <thead>
              <tr>
                <Th align="left"></Th>
                <Th align="right">Last Wk</Th>
                <Th align="right">Last Q</Th>
                <Th align="right" style={{ background: T.slate50 }}>Last Year</Th>
                <Th align="right">On-Time</Th>
                <Th align="right" style={{ background: T.blueLt, color: T.slate800 }}>$ Diff</Th>
              </tr>
            </thead>
            <tbody>
              {/* SMVC row — Last Wk | Last Q | Last Year | On-Time | $ Diff */}
              <tr>
                <Td style={{ paddingLeft: 14, color: T.slate700, fontWeight: 600 }}>SMVC</Td>
                <Td align="right">{fmtPct(lastWk)}</Td>
                <Td align="right">{fmtPct(lastQ)}</Td>
                <Td align="right" style={{ background: T.slate50, fontWeight: 700 }}>{fmtPct(lastYear)}</Td>
                <Td align="right">{fmtPct(onTime)}</Td>
                <Td align="right" style={{ background: T.blueLt, fontWeight: 700, color: diffColor }}>{fmtDiff(diff)}</Td>
              </tr>
              {/* Scorecard Bonus row — Last Wk | Last Q | Last Year | On-Time | $ Diff */}
              {(() => {
                const sc = section11.scorecard_bonus || {};
                const scOnTime   = sc.on_time     != null ? Number(sc.on_time)     : null;
                const scLastWk   = sc.last_wk     != null ? Number(sc.last_wk)     : null;
                const scLastQ    = sc.last_q      != null ? Number(sc.last_q)      : null;
                const scLastYear = sc.last_year   != null ? Number(sc.last_year)   : null;
                const scDiff     = sc.dollar_diff != null ? Number(sc.dollar_diff) : null;
                const fmtMoney   = (v) => v == null ? "—" : "$" + Math.round(v).toLocaleString("en-US");
                const scDiffColor = scDiff == null ? T.slate500 : (scDiff >= 0 ? T.green : T.red);
                return (
                  <tr>
                    <Td style={{ paddingLeft: 14, color: T.slate700, fontWeight: 600 }}>Scorecard Bonus</Td>
                    <Td align="right" style={{ color: scLastWk == null ? T.slate500 : T.slate700 }}>{fmtMoney(scLastWk)}</Td>
                    <Td align="right" style={{ color: scLastQ == null ? T.slate500 : T.slate700 }}>{fmtMoney(scLastQ)}</Td>
                    <Td align="right" style={{ background: T.slate50, fontWeight: 700, color: scLastYear == null ? T.slate500 : T.slate800 }}>{fmtMoney(scLastYear)}</Td>
                    <Td align="right">{fmtMoney(scOnTime)}</Td>
                    <Td align="right" style={{ background: T.blueLt, fontWeight: 700, color: scDiffColor }}>{fmtDiff(scDiff)}</Td>
                  </tr>
                );
              })()}
            </tbody>
          </table>
        </div>
        {/* Budget row removed 2026-06-20 — Prize Cart Budget now appears inline on the Prize
            Cart section header; WtQ Trip Budget removed entirely per Peter. */}
      </Card>
    </div>
  );
}

// 12 — Claims

function ClaimsSection({ report, editMode, formReport, isReportDirty, onReportChange }) {
  if (editMode) {
    const fields = [
      ["new_claims", "New"],
      ["unreviewed_claims", "Unreviewed"],
      ["open_claims", "Open"],
    ];
    return (
      <div>
        <SectionHeader icon="🚨" title="Claims" />
        <Card>
          <div style={{ display: "flex", gap: 24, flexWrap: "wrap", alignItems: "flex-end" }}>
            {fields.map(([key, label]) => (
              <div key={key} style={{ display: "flex", flexDirection: "column", gap: 4 }}>
                <span style={{ fontSize: 11, color: T.slate500, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700 }}>{label}</span>
                <NumberInput
                  value={formReport[key]}
                  onChange={v => onReportChange(key, v)}
                  dirty={isReportDirty(key)}
                  min={0}
                  step={1}
                  style={{ width: 96 }}
                />
              </div>
            ))}
          </div>
        </Card>
      </div>
    );
  }
  return (
    <div>
      <SectionHeader icon="🚨" title="Claims" />
      <Card>
        <div style={{ fontSize: 13, color: T.slate800 }}>
          New: <strong>{fmtInt(report?.new_claims)}</strong> &nbsp;•&nbsp;
          Unreviewed: <strong>{fmtInt(report?.unreviewed_claims)}</strong> &nbsp;•&nbsp;
          Open: <strong>{fmtInt(report?.open_claims)}</strong>
        </div>
      </Card>
    </div>
  );
}

// 13.5 — EUR (Underwriting Reports) — free-form text, after Non-Pays
function EURSection({ report, editMode, formReport, isReportDirty, onReportChange }) {
  if (editMode) {
    return (
      <div>
        <SectionHeader icon="🧾" title="EUR" />
        <Card>
          <div style={{ fontSize: 11, color: T.slate500, marginBottom: 6, lineHeight: 1.4 }}>
            Underwriting Reports — customers with 3+ UW reports run on a single LOB this week. Tracked but not counted against Requirements.
          </div>
          <TextArea
            value={formReport.eur}
            onChange={v => onReportChange("eur", v)}
            dirty={isReportDirty("eur")}
            rows={4}
          />
        </Card>
      </div>
    );
  }
  return (
    <div>
      <SectionHeader icon="🧾" title="EUR" />
      <Card>
        {report?.eur
          ? <div style={{ fontSize: 13, color: T.slate800, whiteSpace: "pre-wrap", lineHeight: 1.5 }}>{report.eur}</div>
          : <div style={{ fontSize: 13, color: T.slate400, fontStyle: "italic" }}>No EUR notes for this week.</div>}
      </Card>
    </div>
  );
}

// 13 — Non-Pays
function NonPaysSection({ report, editMode, formReport, isReportDirty, onReportChange }) {
  if (editMode) {
    return (
      <div>
        <SectionHeader icon="🛑" title="Non-Pays" />
        <Card>
          <div style={{ display: "flex", flexDirection: "column", gap: 4, width: 140 }}>
            <span style={{ fontSize: 11, color: T.slate500, textTransform: "uppercase", letterSpacing: 0.4, fontWeight: 700 }}>This week</span>
            <NumberInput
              value={formReport.non_pays}
              onChange={v => onReportChange("non_pays", v)}
              dirty={isReportDirty("non_pays")}
              min={0}
              step={1}
              style={{ width: 96 }}
            />
          </div>
        </Card>
      </div>
    );
  }
  return (
    <div>
      <SectionHeader icon="🛑" title="Non-Pays" />
      <Card>
        <div style={{ fontSize: 13, color: T.slate800 }}>
          This week: <strong>{fmtInt(report?.non_pays)}</strong>
        </div>
      </Card>
    </div>
  );
}

// 14 — Campaigns (most recent created date per type)
function CampaignsSection({ report, campaignPriors, weekDate, editMode, formReport, isReportDirty, onReportChange }) {
  // Each row maps to one date column on weekly_cpr_reports.
  // cadence "week" → "this week" option = weekDate (Saturday)
  // cadence "month" → "this month" option = first-of-month YYYY-MM-01
  const TYPES = [
    { key: "campaign_onboarding_date",  priorKey: "onboarding_date",  label: "Onboarding",          cadence: "week"  },
    { key: "campaign_defectors_date",   priorKey: "defectors_date",   label: "Defectors",           cadence: "month" },
    { key: "campaign_single_line_date", priorKey: "single_line_date", label: "Single-Line At-Risk", cadence: "month" },
    { key: "campaign_af_renewals_date", priorKey: "af_renewals_date", label: "A/F Renewals",        cadence: "month" },
  ];

  const currentSat = weekDate || null;
  const currentMonth = weekDate ? (weekDate.slice(0, 7) + "-01") : null;
  // Month math: add n months to a YYYY-MM-01 date string, return YYYY-MM-01.
  const addMonths = (iso, n) => {
    if (!iso) return null;
    const [y, m] = iso.split("-").map(Number);
    const total = y * 12 + (m - 1) + n;
    const ny = Math.floor(total / 12);
    const nm = (total % 12) + 1;
    return `${ny}-${String(nm).padStart(2, "0")}-01`;
  };
  const fmtMonthYear = (iso) => {
    if (!iso) return "—";
    const d = new Date(iso + "T00:00:00Z");
    return d.toLocaleString("en-US", { month: "short", year: "numeric", timeZone: "UTC" });
  };
  const display = (iso, cadence) => {
    if (!iso) return "—";
    return cadence === "week" ? fmtMMDD(iso) : fmtMonthYear(iso);
  };

  return (
    <div>
      <SectionHeader icon="📋" title="Campaigns" />
      <Card>
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(220px, 1fr))", gap: "12px 18px" }}>
          {TYPES.map(t => {
            const savedValue = editMode ? formReport[t.key] : (report ? report[t.key] : null);
            const priorValue = campaignPriors ? campaignPriors[t.priorKey] : null;
            const currentValue = t.cadence === "week" ? currentSat : currentMonth;
            const displayValue = savedValue || priorValue;
            const dirty = editMode ? isReportDirty(t.key) : false;

            if (editMode) {
              // Build candidate list:
              //   - week cadence (Onboarding): this week + prior week.
              //   - month cadence (Defectors / Single-Line / A/F Renewals):
              //       month+2, month+1, this month, prior month.
              //   - Also include saved value as a fallback option so the select can
              //     always display whatever's currently stored.
              // Dedupe by value, then sort most recent first (date desc).
              const candidates = [];
              if (t.cadence === "month") {
                candidates.push({ value: addMonths(currentMonth, 2), kind: "future" });
                candidates.push({ value: addMonths(currentMonth, 1), kind: "future" });
              }
              if (currentValue) candidates.push({ value: currentValue, kind: "current" });
              if (priorValue)   candidates.push({ value: priorValue,   kind: "prior" });
              if (savedValue)   candidates.push({ value: savedValue,   kind: "saved" });

              const seen = new Set();
              const unique = [];
              for (const c of candidates) {
                if (!c.value || seen.has(c.value)) continue;
                seen.add(c.value);
                unique.push(c);
              }
              unique.sort((a, b) => (a.value < b.value ? 1 : a.value > b.value ? -1 : 0));

              const opts = unique.map(c => {
                const label = display(c.value, t.cadence);
                if (c.kind === "current") return { value: c.value, label: `${label} (this ${t.cadence})` };
                if (c.kind === "prior")   return { value: c.value, label: `${label} (prior)` };
                return { value: c.value, label };
              });
              return (
                <div key={t.key} style={{
                  display: "flex", flexDirection: "column", gap: 4,
                  padding: "6px 8px", borderRadius: 6,
                  background: dirty ? (T.amber50 || "#fef3c7") : "transparent",
                }}>
                  <span style={{ fontSize: 10, fontWeight: 800, color: T.slate500, letterSpacing: 0.4, textTransform: "uppercase" }}>
                    {t.label}
                  </span>
                  <select
                    value={savedValue || ""}
                    onChange={e => onReportChange(t.key, e.target.value || null)}
                    onFocus={focusStyle}
                    onBlur={blurStyle}
                    style={{
                      ...inputBase, width: "100%", fontSize: 13,
                      background: dirty ? (T.amber50 || "#fef3c7") : T.white,
                    }}
                  >
                    <option value="">— (clear / use prior)</option>
                    {opts.map(o => (
                      <option key={o.value} value={o.value}>{o.label}</option>
                    ))}
                  </select>
                </div>
              );
            }
            return (
              <span key={t.key} style={{ fontSize: 13, color: T.slate800 }}>
                <strong>{t.label}</strong>: {display(displayValue, t.cadence)}
                {!savedValue && priorValue ? <span style={{ color: T.slate500, fontSize: 11, marginLeft: 4 }}>(from prior)</span> : null}
              </span>
            );
          })}
        </div>
      </Card>
    </div>
  );
}

// 16 — Hours Worked (Mon-Fri grid + total)
function HoursWorkedSection({ details, team, runtimeHours }) {
  if (!details || details.length === 0) {
    return (
      <div>
        <SectionHeader icon="🕐" title="Hours Worked" />
        <Card><Awaiting /></Card>
      </div>
    );
  }
  const sorted = sortByTenure(details, team);
  const DAYS = ["mon", "tue", "wed", "thu", "fri"];
  const DAY_LABELS = { mon: "Mon", tue: "Tue", wed: "Wed", thu: "Thu", fri: "Fri" };
  return (
    <div>
      <SectionHeader icon="🕐" title="Hours Worked" />
      <Card style={{ padding: 0, overflow: "hidden" }}>
        <div style={{ overflowX: "auto" }}>
          <table style={{ width: "100%", borderCollapse: "collapse", minWidth: 600 }}>
            <thead>
              <tr>
                <Th align="left">Person</Th>
                {DAYS.map(day => <Th key={day} align="center">{DAY_LABELS[day]}</Th>)}
                <Th align="right">Total</Th>
              </tr>
            </thead>
            <tbody>
              {sorted.map(d => {
                const tmHours = runtimeHours?.[d.team_member_id] || {};
                let total = 0;
                DAYS.forEach(day => { total += Number(tmHours[day]?.hours) || 0; });
                return (
                  <tr key={d.team_member_id}>
                    <Td style={{ paddingLeft: 14, color: T.slate700, fontWeight: 600 }}>{firstName(d.__name)}</Td>
                    {DAYS.map(day => {
                      const cell = tmHours[day];
                      // Off entire day (no hours or 0 hours) renders blank — no icon either.
                      if (!cell || cell.hours == null || Number(cell.hours) === 0) {
                        return <Td key={day} align="center">—</Td>;
                      }
                      const loc = cell.location;
                      const icon = loc === "remote" ? " 🟣" : (loc === "in_office" || loc === "office") ? " 🟢" : "";
                      return (
                        <Td key={day} align="center">
                          <span>{Number(cell.hours).toFixed(2)}{icon}</span>
                        </Td>
                      );
                    })}
                    <Td align="right" style={{ fontWeight: 700 }}>{total > 0 ? total.toFixed(2) : "—"}</Td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </Card>
    </div>
  );
}

// 17 — Team Activity (Quotes / Net Quotes / Q Sales Pts / ↑ 1%)
function TeamActivitySection({ details, team, truePayHistory, runtimeReqs, report, editMode, formDetails, isDirty, onChange, weekDate, lastWeekSalesPointsByMember, cycleStartISO }) {
  if (!details || details.length === 0) {
    return (
      <div>
        <SectionHeader icon="📊" title="Team Activity" />
        <Card><Awaiting /></Card>
      </div>
    );
  }
  const sorted = sortByTenure(details, team);

  // Team Net Quotes Total = sum of per-person Net Quotes shown above (quotes_discussed − paid).
  // We compute at runtime so the team-total cell always equals the sum of the per-person cells.
  // Note: weekly_cpr_reports.quotes_total_net stores the team's GROSS quotes for the week
  // (sum of latest team_checkins.quotes_week per member, written by weekly_cpr_compute_outcome)
  // and is used by the Win-the-Week pass/fail math. It is NOT the Net Quotes display value.
  const teamNetQuotesTotal = sorted.reduce(
    (acc, d) => acc + (Number(runtimeReqs?.[d.team_member_id]?.net_quotes) || 0),
    0
  );
  const teamSalesPtsTotal = report?.quarterly_sales_points_qtd != null
    ? Number(report.quarterly_sales_points_qtd)
    : sorted.reduce((acc, d) => acc + (Number(d.sales_points) || 0), 0);

  const carryover = Number(report?.quotes_owed_carryover) || 0;
  const freshNeeded = Number(report?.quotes_fresh_needed) || 0;
  const quoteGoal = carryover + freshNeeded;
  const salesPtsGoal = Number(report?.quarterly_sales_points_target) || 0;

  // Team-level Win-the-Week pass/fail + per-goal shortfall — computed at view
  // time from carryover + fresh_needed vs team_net_quotes (and SP target vs QTD).
  // The per-person chain (get_weekly_cpr_requirements) handles per-person
  // checklist debt for Requirements + Payroll allocation, a separate concept.
  const quotesPass = teamNetQuotesTotal >= quoteGoal;
  const spPass = teamSalesPtsTotal >= salesPtsGoal;
  const quotesShort = Math.max(0, quoteGoal - teamNetQuotesTotal);
  const spShort = Math.max(0, salesPtsGoal - teamSalesPtsTotal);

  return (
    <div>
      <SectionHeader icon="📊" title="Team Activity" />
      <Card style={{ padding: 0, overflow: "hidden" }}>
        <div style={{ overflowX: "auto" }}>
          <table style={{ width: "100%", borderCollapse: "collapse", minWidth: 600 }}>
            <thead>
              <tr>
                <Th align="left">Person</Th>
                <Th align="right">Quotes</Th>
                <Th align="right">Net Quotes</Th>
                <Th align="right">Q Sales Pts</Th>
                <Th align="right">↑ 1% vs 13-wk</Th>
              </tr>
            </thead>
            <tbody>
              {sorted.map(d => {
                const row = formDetails?.[d.id] || {};
                const r = runtimeReqs?.[d.team_member_id] || {};
                // Net Quotes = quotes_discussed − paid.
                // Single formula matching get_weekly_cpr_requirements (server). In edit
                // mode, Quotes comes from the dirty form so a typing change is visible
                // immediately; Paid is server-computed and refreshes on save.
                const quotesNow = Number(editMode ? (row.quotes_discussed ?? d.quotes_discussed ?? 0) : (d.quotes_discussed ?? 0));
                const paidNow = Number(r.paid) || 0;
                const netPreview = quotesNow - paidNow;
                return (
                  <tr key={d.team_member_id}>
                    <Td style={{ paddingLeft: 14, color: T.slate700, fontWeight: 600 }}>{firstName(d.__name)}</Td>
                    {editMode ? (
                      <Td align="right" style={{ padding: 6 }}>
                        <NumberInput
                          value={row.quotes_discussed}
                          onChange={v => onChange(d.id, "quotes_discussed", v)}
                          dirty={isDirty(d.id, "quotes_discussed")}
                          min={0}
                          step={1}
                          style={{ width: 80 }}
                        />
                      </Td>
                    ) : (
                      <Td align="right">{fmtInt(d.quotes_discussed)}</Td>
                    )}
                    <Td align="right" style={{ color: T.slate500 }}>{fmtInt(netPreview)}</Td>
                    {editMode ? (
                      <Td align="right" style={{ padding: 6 }}>
                        <NumberInput
                          value={row.sales_points}
                          onChange={v => onChange(d.id, "sales_points", v)}
                          dirty={isDirty(d.id, "sales_points")}
                          step={0.01}
                          style={{ width: 88 }}
                        />
                      </Td>
                    ) : (
                      <Td align="right">
                        {d.sales_points != null ? Number(d.sales_points).toFixed(2) : "—"}
                        {(() => {
                          // WoW delta: this week's sales_points vs last week's, suppressed across cycle boundary.
                          if (d.sales_points == null) return null;
                          const last = lastWeekSalesPointsByMember?.[d.team_member_id];
                          if (last == null) return null;
                          // Suppress at start of a new cycle (last week belongs to prior quarter)
                          if (cycleStartISO && weekDate) {
                            const lastWeekDate = (() => {
                              const dt = new Date(weekDate + "T00:00:00Z");
                              dt.setUTCDate(dt.getUTCDate() - 7);
                              return dt.toISOString().slice(0, 10);
                            })();
                            if (lastWeekDate < cycleStartISO) return null;
                          }
                          const delta = Number(d.sales_points) - Number(last);
                          if (Math.abs(delta) < 0.005) return null;
                          const up = delta > 0;
                          return (
                            <span style={{ marginLeft: 6, fontSize: 11, fontWeight: 400, color: up ? T.green : T.red }}>
                              {up ? "▲" : "▼"}{Math.abs(delta).toFixed(2)}
                            </span>
                          );
                        })()}
                      </Td>
                    )}
                    <Td align="right">—</Td>
                  </tr>
                );
              })}

              {/* Team Total row */}
              <tr style={{ borderTop: `2px solid ${T.slate200}` }}>
                <Td style={{ paddingLeft: 14, fontWeight: 700, color: T.slate800 }}>Team Total</Td>
                <Td align="right"></Td>
                <Td align="right" style={{ fontWeight: 700, color: T.slate800 }}>{fmtInt(teamNetQuotesTotal)}</Td>
                <Td align="right" style={{ fontWeight: 700, color: T.slate800 }}>{teamSalesPtsTotal.toFixed(2)}</Td>
                <Td align="right"></Td>
              </tr>

              {/* Goal row — quotes goal includes carryover from prior week */}
              <tr>
                <Td style={{ paddingLeft: 14, fontWeight: 700, color: T.slate700 }}>
                  Goal{" "}
                  <span style={{ fontWeight: 400, color: T.slate500, fontSize: 11 }}>
                    ({carryover} carryover)
                  </span>
                </Td>
                <Td align="right"></Td>
                <Td align="right" style={{ fontWeight: 700, color: T.slate700 }}>{quoteGoal}</Td>
                <Td align="right" style={{ fontWeight: 700, color: T.slate700 }}>{salesPtsGoal.toFixed(2)}</Td>
                <Td align="right"></Td>
              </tr>

              {/* WtW Result row — one consolidated label spanning Net Quotes + Q Sales Pts.
                  Win  (both conditions cleared): ✓ Win the Week!  (green)
                  Loss (either missed):           Carryover: N quotes / M pts  (each piece shown only if > 0, red) */}
              <tr>
                <Td
                  colSpan={5}
                  align="center"
                  style={{ fontWeight: 700, color: (quotesPass && spPass) ? T.green : T.red }}
                >
                  {(quotesPass && spPass)
                    ? "✓ Win the Week!"
                    : (() => {
                        const parts = [];
                        if (quotesShort > 0) parts.push(`${quotesShort.toLocaleString()} quote${quotesShort === 1 ? "" : "s"}`);
                        if (spShort > 0) parts.push(`${Math.round(spShort).toLocaleString()} pts`);
                        return `Carryover: ${parts.join(" / ")}`;
                      })()}
                </Td>
              </tr>
            </tbody>
          </table>
        </div>
      </Card>
    </div>
  );
}

// 19 — Payroll (per-person columns, pay component rows)
// Admin can toggle Edit mode to enter payroll_ytd_paid (cumulative $
// paid year-to-date through SurePayroll, through end of last pay period).
// True Pay Bonus is computed off that value on save via write_weekly_pay RPC.
function PayrollSection({ details, team, weekDate, anchorPayrollYtd, retentionBudgetAnnual, onRefresh }) {
  // v2 payroll (residual pool + carveouts + marketing pool). Rollout 2026-07-11.
  const [editMode, setEditMode] = useState(false);
  const [drafts, setDrafts] = useState({});
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState(null);

  // When entering edit mode, seed drafts from current values
  useEffect(() => {
    if (editMode && details && details.length > 0) {
      const init = {};
      details.forEach(d => {
        init[d.team_member_id] = d.payroll_ytd_paid ?? null;
      });
      setDrafts(init);
      setSaveError(null);
    }
  }, [editMode, details]);

  if (!details || details.length === 0) {
    return (
      <div>
        <SectionHeader icon="💰" title="Payroll" />
        <Card><Awaiting /></Card>
      </div>
    );
  }
  const sorted = sortByTenure(details, team);

  // v2 pay components — every element that hits a check under the residual-pool structure.
  // Base + Comm are payroll-cycle earnings. Team Pool is residual bonus share (YTD-net).
  // Marketing is the separate marketing pool share. Mgr + Health are pre-pool carveouts.
  const ROWS = [
    ["base_salary",                   "Base"],
    ["commission",                    "Comm"],
    ["bonus",                         "Team Pool"],
    ["marketing_pool_earned_weekly",  "Marketing"],
    ["manager_bonus",                 "Mgr"],
    ["health_bonus",                  "Health"],
  ];

  async function handleSave() {
    if (!supabase || !weekDate) return;
    setSaving(true);
    setSaveError(null);
    try {
      // Find this week's report id
      const { data: reportRow, error: reportErr } = await supabase
        .from("weekly_cpr_reports")
        .select("id")
        .eq("agency_id", AGENCY_ID)
        .eq("week_ending_date", weekDate)
        .maybeSingle();
      if (reportErr) throw reportErr;
      if (!reportRow) throw new Error("No CPR report row for this week");

      // Update each team_detail row's payroll_ytd_paid
      for (const tmId of Object.keys(drafts)) {
        const raw = drafts[tmId];
        const val = raw === null || raw === undefined || raw === "" ? null : Number(raw);
        const { error: updErr } = await supabase
          .from("weekly_cpr_team_detail")
          .update({ payroll_ytd_paid: val })
          .eq("weekly_cpr_report_id", reportRow.id)
          .eq("team_member_id", tmId);
        if (updErr) throw updErr;
      }

      // Recompute the residual pool + carveouts + marketing pool for the week
      const { error: rpcErr } = await supabase.rpc("write_weekly_comp_v2", {
        p_agency_id: AGENCY_ID,
        p_week_end_date: weekDate,
      });
      if (rpcErr) throw rpcErr;

      setEditMode(false);
      if (onRefresh) onRefresh();
    } catch (err) {
      setSaveError(err.message || String(err));
    } finally {
      setSaving(false);
    }
  }

  return (
    <div>
      <SectionHeader icon="💰" title="Payroll" />
      <Card style={{ padding: 0, overflow: "hidden" }}>
        {/* Edit toolbar — small admin-only affordance */}
        <div style={{
          display: "flex", justifyContent: "flex-end", alignItems: "center",
          gap: 8, padding: "8px 14px", borderBottom: `1px solid ${T.slate200}`,
          background: editMode ? (T.amber50 || "#fef3c7") : T.white,
        }}>
          {editMode && saveError && (
            <span style={{ color: T.red600 || "#dc2626", fontSize: 12, marginRight: "auto" }}>
              {saveError}
            </span>
          )}
          {editMode ? (
            <>
              <button
                onClick={() => setEditMode(false)}
                disabled={saving}
                style={{
                  fontSize: 12, padding: "4px 10px", borderRadius: 4,
                  border: `1px solid ${T.slate300}`, background: T.white,
                  color: T.slate700, cursor: saving ? "default" : "pointer",
                }}>
                Cancel
              </button>
              <button
                onClick={handleSave}
                disabled={saving}
                style={{
                  fontSize: 12, padding: "4px 10px", borderRadius: 4,
                  border: `1px solid ${T.slate700}`, background: T.slate700,
                  color: T.white, cursor: saving ? "default" : "pointer",
                }}>
                {saving ? "Saving…" : "Save & recompute"}
              </button>
            </>
          ) : (
            <button
              onClick={() => setEditMode(true)}
              style={{
                fontSize: 12, padding: "4px 10px", borderRadius: 4,
                border: `1px solid ${T.slate300}`, background: T.white,
                color: T.slate700, cursor: "pointer",
              }}>
              Edit payroll YTD
            </button>
          )}
        </div>

        <div style={{ overflowX: "auto" }}>
          <table style={{ width: "100%", borderCollapse: "collapse", minWidth: 600 }}>
            <thead>
              <tr>
                <Th align="left">Component</Th>
                {sorted.map(d => (
                  <Th key={d.team_member_id} align="right">{firstName(d.__name)}</Th>
                ))}
              </tr>
            </thead>
            <tbody>
              {ROWS.map(([key, label]) => (
                <tr key={key}>
                  <Td style={{ paddingLeft: 14, color: T.slate700 }}>{label}</Td>
                  {sorted.map(d => (
                    <Td key={d.team_member_id} align="right">{fmtMoneyCents(d[key])}</Td>
                  ))}
                </tr>
              ))}
              {/* Benefits row — sourced from team.annual_benefits_value / 52.
                  Imputed non-cash value (group health). Included in Week Total.
                  Excluded from On-Time annualization (flat-added below to avoid compounding). */}
              <tr>
                <Td style={{ paddingLeft: 14, color: T.slate700 }}>Benefits</Td>
                {sorted.map(d => {
                  const member = (team || []).find(t => t.id === d.team_member_id);
                  const weeklyBenefits = Number(member?.annual_benefits_value || 0) / 52;
                  return (
                    <Td key={d.team_member_id} align="right">{fmtMoneyCents(weeklyBenefits)}</Td>
                  );
                })}
              </tr>
              {/* Edit-only row: payroll_ytd_paid (cumulative SurePayroll YTD paid through
                  end of last pay period). Combined with this-week components to derive
                  the On-Time annualization. Hidden in normal view. */}
              {editMode && (
                <tr style={{ background: T.amber50 || "#fef3c7" }}>
                  <Td style={{ paddingLeft: 14, color: T.slate900, fontStyle: "italic" }}>
                    Payroll YTD paid
                    <div style={{ fontSize: 11, color: T.slate600, fontWeight: 400 }}>
                      Cumulative $ paid year-to-date through last pay period (SurePayroll)
                    </div>
                  </Td>
                  {sorted.map(d => (
                    <Td key={d.team_member_id} align="right">
                      <NumberInput
                        value={drafts[d.team_member_id] ?? null}
                        onChange={v => setDrafts(prev => ({ ...prev, [d.team_member_id]: v }))}
                        dirty={drafts[d.team_member_id] !== (d.payroll_ytd_paid ?? null)}
                        step={0.01}
                        style={{ width: 100 }}
                      />
                    </Td>
                  ))}
                </tr>
              )}

              <tr>
                <Td style={{ paddingLeft: 14, color: T.slate900, fontWeight: 800, borderTop: `2px solid ${T.slate300}` }}>Week Total</Td>
                {sorted.map(d => {
                  const compsTotal = ROWS.reduce((sum, [k]) => sum + (Number(d[k]) || 0), 0);
                  const member = (team || []).find(t => t.id === d.team_member_id);
                  const weeklyBenefits = Number(member?.annual_benefits_value || 0) / 52;
                  const total = compsTotal + weeklyBenefits;
                  return (
                    <Td key={d.team_member_id} align="right" style={{ fontWeight: 800, borderTop: `2px solid ${T.slate300}` }}>
                      {fmtMoneyCents(total)}
                    </Td>
                  );
                })}
              </tr>
              <tr>
                <Td style={{ paddingLeft: 14, color: T.slate600 }}>YTD Paid</Td>
                {sorted.map(d => (
                  <Td key={d.team_member_id} align="right" style={{ color: T.slate600 }}>
                    {d.payroll_ytd_paid == null ? "—" : fmtMoneyCents(d.payroll_ytd_paid)}
                  </Td>
                ))}
              </tr>
              <tr>
                <Td style={{ paddingLeft: 14, color: T.slate600, fontStyle: "italic" }}>OT Annual</Td>
                {sorted.map(d => {
                  // On-Time = (payroll_ytd_paid + this_week_component_total) × 365 / days_employed_this_year + annual_benefits.
                  // Benefits flat-added (no compounding).
                  const ytdPaid = (d.payroll_ytd_paid === null || d.payroll_ytd_paid === undefined)
                    ? null : Number(d.payroll_ytd_paid);
                  const thisWeekTotal = ROWS.reduce((sum, [k]) => sum + (Number(d[k]) || 0), 0);
                  const ytdWithThisWeek = ytdPaid === null ? null : ytdPaid + thisWeekTotal;
                  const member = (team || []).find(t => t.id === d.team_member_id);
                  const daysEmployedThisYear = (() => {
                    if (!weekDate) return 1;
                    const dt = new Date(weekDate + "T00:00:00Z");
                    const ys = new Date(Date.UTC(dt.getUTCFullYear(), 0, 1));
                    const startDateStr = member && (member.start_date || member.hire_date);
                    const startDt = startDateStr
                      ? new Date(startDateStr + "T00:00:00Z")
                      : ys;
                    const effectiveStart = startDt > ys ? startDt : ys;
                    return Math.max(1, Math.floor((dt - effectiveStart) / 86400000) + 1);
                  })();
                  const annualBenefits = Number(member?.annual_benefits_value || 0);
                  const onTimeAnnual = ytdWithThisWeek === null ? null : ((ytdWithThisWeek * 365) / daysEmployedThisYear) + annualBenefits;
                  return (
                    <Td key={d.team_member_id} align="right" style={{ color: T.slate600, fontStyle: "italic" }}>
                      {onTimeAnnual === null ? "—" : fmtMoneyCents(onTimeAnnual)}
                    </Td>
                  );
                })}
              </tr>
            </tbody>
          </table>
        </div>
      </Card>
    </div>
  );
}


// 20 — True Pay Bonus History (weekly per-person + 5 averages — page version shows BOTH)
function TruePayHistorySection({ team, truePayHistory, weekDate }) {
  // True Pay Bonus History only shows currently-active agency team members,
  // excluding the Owner (Peter). Inactive (terminated/archived), admin-category,
  // and Owner staff are excluded — their historical bonuses still live in
  // weekly_cpr_team_detail but don't render here.
  const sorted = (team || []).filter(t =>
    t.is_active === true && !t.archived_at && t.category === "agency" && t.role_level !== "Owner"
  );
  if (!truePayHistory || Object.keys(truePayHistory).length === 0) {
    return (
      <div>
        <SectionHeader icon="📈" title="True Pay Bonus History" />
        <Card><Awaiting message="No True Pay Bonus history yet — populates as weekly_cpr_team_detail accumulates" /></Card>
      </div>
    );
  }
  // Collect unique week-ending dates across all people (most recent 13 for the table)
  const weekSet = new Set();
  Object.values(truePayHistory).forEach(rows => rows.forEach(r => weekSet.add(r.week_ending_date)));
  const weeks = Array.from(weekSet).sort((a, b) => a.localeCompare(b)).slice(-13);

  // Build cell lookup
  const lookup = {};
  Object.entries(truePayHistory).forEach(([tmId, rows]) => {
    lookup[tmId] = {};
    rows.forEach(r => { lookup[tmId][r.week_ending_date] = r.true_pay_bonus; });
  });

  // Averages helper — over a list of values (only weeks that have data for that person)
  const avgOver = (tmId, n) => {
    const rows = (truePayHistory[tmId] || []).slice(-n);
    if (rows.length === 0) return null;
    const sum = rows.reduce((s, r) => s + (Number(r.true_pay_bonus) || 0), 0);
    return sum / rows.length;
  };

  return (
    <div>
      <SectionHeader icon="📈" title="True Pay Bonus History" />
      <Card style={{ padding: 0, overflow: "hidden" }}>
        <div style={{ overflowX: "auto" }}>
          <table style={{ width: "100%", borderCollapse: "collapse", minWidth: 600 }}>
            <thead>
              <tr>
                <Th align="left">Week</Th>
                {sorted.map(t => <Th key={t.id} align="right">{firstName(t.full_name)}</Th>)}
              </tr>
            </thead>
            <tbody>
              {weeks.map(w => (
                <tr key={w}>
                  <Td style={{ paddingLeft: 14, color: T.slate700 }}>{fmtMMDD(w)}</Td>
                  {sorted.map(t => (
                    <Td key={t.id} align="right">{fmtMoneyCents(lookup[t.id]?.[w])}</Td>
                  ))}
                </tr>
              ))}
              {/* Averages */}
              {[
                ["13-wk avg", 13],
                ["39-wk avg", 39],
              ].map(([label, n]) => (
                <tr key={label}>
                  <Td style={{ paddingLeft: 14, color: T.slate900, fontWeight: 800, borderTop: `2px solid ${T.slate300}` }}>{label}</Td>
                  {sorted.map(t => (
                    <Td key={t.id} align="right" style={{ fontWeight: 800, borderTop: `2px solid ${T.slate300}` }}>
                      {fmtMoneyCents(avgOver(t.id, n))}
                    </Td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Card>
    </div>
  );
}

// 21 — Leaderboards + All-Stars
function LeaderboardsSection() {
  return (
    <div>
      <SectionHeader title="Leaderboards · All-Stars" />
      <Card>
        <Awaiting message="Leaderboard wiring pending (WtQ / Sales / Quotes rankings)" />
      </Card>
    </div>
  );
}

// 22 — Prize Cart
function PrizeCartSection({ prizeCart, team, prizeBudget }) {
  const safe = Array.isArray(prizeCart) ? prizeCart : [];
  const teamById = Object.fromEntries((team || []).map(t => [t.id, t]));
  const budgetAccessory = prizeBudget == null
    ? null
    : `($${Math.round(Number(prizeBudget)).toLocaleString("en-US")})`;

  if (safe.length === 0) {
    return (
      <div>
        <SectionHeader icon="🏆" title="Prize Cart" accessory={budgetAccessory} />
        <Card><Awaiting message="No prizes loaded for this quarter yet" /></Card>
      </div>
    );
  }

  return (
    <div>
      <SectionHeader icon="🏆" title="Prize Cart" accessory={budgetAccessory} />
      <Card style={{ padding: 0 }}>
        <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
        <table style={{ width: "100%", borderCollapse: "collapse" }}>
          <thead>
            <tr>
              <Th style={{ paddingLeft: 16 }}>Prize</Th>
              <Th>Winner</Th>
            </tr>
          </thead>
          <tbody>
            {safe.map(row => {
              const winner = row.winner_team_member_id ? teamById[row.winner_team_member_id] : null;
              const winnerLabel = winner ? (winner.nickname || winner.first_name || "(unknown)") : "—";
              return (
                <tr key={row.id}>
                  <Td style={{ paddingLeft: 16 }}>
                    {row.prize_url ? (
                      <a
                        href={row.prize_url}
                        target="_blank"
                        rel="noopener noreferrer"
                        style={{ color: T.slate800, textDecoration: "none" }}
                      >
                        {row.prize_description}
                      </a>
                    ) : (
                      row.prize_description
                    )}
                  </Td>
                  <Td style={{ color: winner ? T.slate800 : T.slate400 }}>
                    {winnerLabel}
                  </Td>
                </tr>
              );
            })}
          </tbody>
        </table>
        </div>
      </Card>
    </div>
  );
}

// ── Helpers ───────────────────────────────────────────────────
function sortByTenure(details, team) {
  // Annotate each detail row with the team member's name + hire_date
  const teamById = {};
  (team || []).forEach(t => { teamById[t.id] = t; });
  return (details || [])
    .map(d => ({
      ...d,
      __name: teamById[d.team_member_id]?.full_name || "(unknown)",
      __hire: teamById[d.team_member_id]?.hire_date || "9999-12-31",
    }))
    .sort((a, b) => {
      if (a.__hire !== b.__hire) return a.__hire.localeCompare(b.__hire);
      return a.__name.localeCompare(b.__name);
    });
}

function firstName(fullName) {
  if (!fullName) return "—";
  return fullName.split(" ")[0];
}

// ─────────────────────────────────────────────────────────────
// EditModeBar — sticky footer shown when editing
// ─────────────────────────────────────────────────────────────
function EditModeBar({ totalDirty, saving, saveError, onSave, onCancel }) {
  return (
    <div style={{
      position: "sticky", bottom: 0, zIndex: 10,
      background: T.white, borderTop: `1px solid ${T.slate200}`,
      boxShadow: "0 -4px 12px rgba(0,0,0,0.06)",
      padding: "12px 20px", marginTop: 30,
      display: "flex", alignItems: "center", justifyContent: "space-between", gap: 16,
    }}>
      <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
        <div style={{
          padding: "4px 10px", background: totalDirty > 0 ? (T.amber50 || "#fef3c7") : T.slate100,
          color: totalDirty > 0 ? (T.amber700 || "#a16207") : T.slate600,
          borderRadius: 999, fontSize: 12, fontWeight: 700,
        }}>
          {totalDirty} {totalDirty === 1 ? "change" : "changes"}
        </div>
        {saveError && (
          <div style={{ fontSize: 12, color: T.red, fontWeight: 600 }}>
            Save failed: {saveError}
          </div>
        )}
        {saving && (
          <div style={{ fontSize: 12, color: T.slate600 }}>Saving…</div>
        )}
      </div>
      <div style={{ display: "flex", gap: 10 }}>
        <button
          onClick={onCancel}
          disabled={saving}
          style={{
            padding: "8px 16px", fontSize: 12, fontWeight: 600,
            background: T.white, color: T.slate700, border: `1px solid ${T.slate300}`,
            borderRadius: 8, cursor: saving ? "not-allowed" : "pointer", opacity: saving ? 0.6 : 1,
          }}
        >Cancel</button>
        <button
          onClick={onSave}
          disabled={saving || totalDirty === 0}
          style={{
            padding: "8px 20px", fontSize: 12, fontWeight: 700,
            background: (saving || totalDirty === 0) ? T.slate300 : T.blue,
            color: T.white, border: "none", borderRadius: 8,
            cursor: (saving || totalDirty === 0) ? "not-allowed" : "pointer",
          }}
        >{saving ? "Saving…" : "Save Changes"}</button>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// MAIN COMPONENT
// ─────────────────────────────────────────────────────────────
export default function CPRDetail({ weekDate, onClose = () => {}, onNavigateWeek = null, userRole = null }) {
  const data = useCPRData(weekDate);
  const edit = useEditForm();
  const canEdit = EDIT_ROLES.has(userRole);

  // ── Week picker — dropdown listing every weekly CPR report this agency has ──
  // Fetched once on mount (no dependency on weekDate). Click any week to jump
  // to /cpr/<that-date> via the existing onNavigateWeek wiring.
  const [availableWeeks, setAvailableWeeks] = useState([]);
  const [pickerOpen, setPickerOpen] = useState(false);
  useEffect(() => {
    if (!supabase) return undefined;
    let cancelled = false;
    (async () => {
      const { data: rows, error: qErr } = await supabase
        .from("weekly_cpr_reports")
        .select("week_ending_date")
        .eq("agency_id", AGENCY_ID)
        .order("week_ending_date", { ascending: false });
      if (cancelled || qErr) return;
      setAvailableWeeks((rows || []).map(r => r.week_ending_date));
    })();
    return () => { cancelled = true; };
  }, []);
  // Click-outside closes the popover.
  useEffect(() => {
    if (!pickerOpen) return undefined;
    const onDoc = (e) => {
      const root = document.getElementById("cpr-week-picker");
      if (root && !root.contains(e.target)) setPickerOpen(false);
    };
    document.addEventListener("mousedown", onDoc);
    return () => document.removeEventListener("mousedown", onDoc);
  }, [pickerOpen]);

  // Beforeunload warning when there are unsaved edits.
  useEffect(() => {
    if (!edit.active || edit.totalDirty === 0) return undefined;
    const handler = (e) => { e.preventDefault(); e.returnValue = ""; return ""; };
    window.addEventListener("beforeunload", handler);
    return () => window.removeEventListener("beforeunload", handler);
  }, [edit.active, edit.totalDirty]);

  // Save handler — fires one UPDATE for report (if dirty) + N UPDATEs for
  // detail rows (one per dirty row), all in parallel via Promise.all.
  async function doSave() {
    if (!supabase) { edit.setSaveError("Supabase client not ready"); return; }
    edit.setSaving(true); edit.setSaveError(null);
    try {
      const ops = [];
      // Report-level UPDATE
      if (edit.dirty.report.size > 0 && data.report?.id) {
        const patch = {};
        for (const f of edit.dirty.report) patch[f] = edit.form.report[f];
        ops.push(
          supabase.from("weekly_cpr_reports")
            .update(patch).eq("id", data.report.id)
            .then(r => r.error ? Promise.reject(new Error("report: " + r.error.message)) : r)
        );
      }
      // Agency-snapshot UPDATE (8 YTD fields; row keyed by agency_id + week_ending_date + weekly)
      if (edit.dirty.snapshot.size > 0 && data.snapshot?.id) {
        const patch = {};
        for (const f of edit.dirty.snapshot) patch[f] = edit.form.snapshot[f];
        ops.push(
          supabase.from("agency_snapshot")
            .update(patch).eq("id", data.snapshot.id)
            .then(r => r.error ? Promise.reject(new Error("snapshot: " + r.error.message)) : r)
        );
      }
      // Per-detail-row UPDATEs
      for (const [rowId, fields] of Object.entries(edit.dirty.details)) {
        if (fields.size === 0) continue;
        const patch = {};
        for (const f of fields) patch[f] = edit.form.details[rowId][f];
        ops.push(
          supabase.from("weekly_cpr_team_detail")
            .update(patch).eq("id", rowId)
            .then(r => r.error ? Promise.reject(new Error("detail " + rowId.slice(0,8) + ": " + r.error.message)) : r)
        );
      }
      if (ops.length === 0) { edit.cancel(); return; }
      await Promise.all(ops);
      edit.finishSave();
      data.refresh();
    } catch (err) {
      edit.setSaving(false);
      edit.setSaveError(err?.message || "Unknown error");
    }
  }
  function doCancel() {
    if (edit.totalDirty > 0) {
      const ok = window.confirm(`Discard ${edit.totalDirty} unsaved change${edit.totalDirty === 1 ? "" : "s"}?`);
      if (!ok) return;
    }
    edit.cancel();
  }
  function doStartEdit() {
    // Agency Performance YTD fields live on agency_snapshot (single source of truth).
    // The prefill trigger on agency_snapshot fills the current-week row with prior-week
    // values on INSERT, so edit.begin pulls directly from data.snapshot.
    edit.begin(data.report, data.details, data.snapshot || {});
  }

  // Validate route param
  if (!isValidISODate(weekDate)) {
    return (
      <div style={{ padding: 30 }}>
        <Card>
          <div style={{ fontSize: 16, fontWeight: 700, color: T.red, marginBottom: 8 }}>
            Invalid week date in URL
          </div>
          <div style={{ fontSize: 13, color: T.slate600, lineHeight: 1.6 }}>
            Expected /cpr/YYYY-MM-DD (a Saturday week-ending date). Got: <code>{String(weekDate)}</code>
          </div>
          <button
            onClick={onClose}
            style={{
              marginTop: 14, padding: "8px 16px", fontSize: 12, fontWeight: 600,
              background: T.blue, color: T.white, border: "none", borderRadius: 8,
              cursor: "pointer",
            }}
          >Back to Dashboard</button>
        </Card>
      </div>
    );
  }

  if (data.loading) {
    return (
      <div style={{ padding: 30, fontSize: 13, color: T.slate500 }}>
        Loading CPR report for week ending {fmtDateLong(weekDate)}…
      </div>
    );
  }

  if (data.error) {
    return (
      <div style={{ padding: 30 }}>
        <Card>
          <div style={{ fontSize: 14, fontWeight: 700, color: T.red, marginBottom: 8 }}>
            Couldn't load CPR data
          </div>
          <div style={{ fontSize: 12, color: T.slate600, marginBottom: 12 }}>{data.error}</div>
          <button
            onClick={onClose}
            style={{
              padding: "8px 16px", fontSize: 12, fontWeight: 600,
              background: T.blue, color: T.white, border: "none", borderRadius: 8,
              cursor: "pointer",
            }}
          >Back to Dashboard</button>
        </Card>
      </div>
    );
  }

  const canGoNext = !!onNavigateWeek && addDaysISO(weekDate, 7) <= todayISO();

  return (
    <div style={{ maxWidth: 1100, margin: "0 auto" }}>
      {/* ── Top controls: title · week · nav · actions — one line, wraps on phone.
            Sticky to top of scroll container so it stays visible while scrolling. ── */}
      <div style={{
        display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap",
        position: "sticky", top: 0, zIndex: 30,
        background: T.white,
        paddingTop: 10, paddingBottom: 10,
        borderBottom: `1px solid ${T.slate200}`,
        marginBottom: 12,
      }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8, minWidth: 0 }}>
          <span style={{ fontSize: 18, lineHeight: 1 }} aria-hidden="true">📊</span>
          <span style={{
            fontSize: 15, fontWeight: 800, color: T.slate900,
            letterSpacing: "-0.02em", whiteSpace: "nowrap",
          }}>CPR</span>

          {/* Week picker — click the current week to pick another */}
          <div id="cpr-week-picker" style={{ position: "relative", flexShrink: 0 }}>
            <button
              type="button"
              onClick={() => !edit.active && availableWeeks.length > 0 && setPickerOpen(o => !o)}
              disabled={edit.active || availableWeeks.length === 0}
              aria-haspopup="listbox"
              aria-expanded={pickerOpen}
              title="Jump to another weekly CPR report"
              style={{
                padding: "5px 10px", fontSize: 13, fontWeight: 700,
                background: T.white, color: T.slate800,
                border: `1px solid ${T.slate300}`, borderRadius: 6,
                cursor: (edit.active || availableWeeks.length === 0) ? "default" : "pointer",
                display: "flex", alignItems: "center", gap: 6,
                whiteSpace: "nowrap", lineHeight: 1,
                opacity: edit.active ? 0.6 : 1,
              }}
            >
              <span>{fmtRange(weekDate)}</span>
              <span style={{ fontSize: 9, color: T.slate500 }} aria-hidden="true">▾</span>
            </button>
            {pickerOpen && (
              <div
                role="listbox"
                style={{
                  position: "absolute", top: "calc(100% + 4px)", left: 0,
                  background: T.white, border: `1px solid ${T.slate200}`,
                  borderRadius: 8, boxShadow: "0 10px 30px rgba(15,23,42,0.12)",
                  maxHeight: 360, overflowY: "auto", zIndex: 20,
                  minWidth: 220,
                }}
              >
                {availableWeeks.map(wk => {
                  const isActive = wk === weekDate;
                  return (
                    <button
                      key={wk}
                      type="button"
                      role="option"
                      aria-selected={isActive}
                      onClick={() => {
                        setPickerOpen(false);
                        if (wk !== weekDate && onNavigateWeek) onNavigateWeek(wk);
                      }}
                      style={{
                        display: "block", width: "100%", textAlign: "left",
                        padding: "9px 14px", fontSize: 12,
                        fontWeight: isActive ? 700 : 500,
                        color: isActive ? T.blue : T.slate700,
                        background: isActive ? T.blueLt : T.white,
                        border: "none",
                        borderBottom: `1px solid ${T.slate100}`,
                        cursor: "pointer", whiteSpace: "nowrap",
                      }}
                    >
                      {fmtDateLong(wk)}
                    </button>
                  );
                })}
              </div>
            )}
          </div>

          {edit.active && (
            <span style={{
              fontSize: 10, fontWeight: 700, color: "#a16207",
              background: "#fef3c7", padding: "2px 7px", borderRadius: 4,
              letterSpacing: 0.4, textTransform: "uppercase",
            }}>Editing</span>
          )}
        </div>
        {onNavigateWeek && !edit.active && (
          <div style={{ display: "flex", gap: 4, flexShrink: 0 }}>
            <button
              onClick={() => onNavigateWeek(addDaysISO(weekDate, -7))}
              title={`Week ending ${addDaysISO(weekDate, -7)}`}
              aria-label="Previous week"
              style={{
                padding: "5px 9px", fontSize: 12, fontWeight: 700,
                background: T.white, color: T.slate700,
                border: `1px solid ${T.slate300}`, borderRadius: 6,
                cursor: "pointer", lineHeight: 1,
              }}
            >◀</button>
            <button
              onClick={() => canGoNext && onNavigateWeek(addDaysISO(weekDate, 7))}
              disabled={!canGoNext}
              title={canGoNext ? `Week ending ${addDaysISO(weekDate, 7)}` : "No later week yet"}
              aria-label="Next week"
              style={{
                padding: "5px 9px", fontSize: 12, fontWeight: 700,
                background: T.white, color: canGoNext ? T.slate700 : T.slate400,
                border: `1px solid ${T.slate300}`, borderRadius: 6,
                cursor: canGoNext ? "pointer" : "not-allowed", lineHeight: 1,
                opacity: canGoNext ? 1 : 0.55,
              }}
            >▶</button>
          </div>
        )}
        <div style={{ flex: 1, minWidth: 4 }} aria-hidden="true" />
        {canEdit && !edit.active && (
          <button
            onClick={doStartEdit}
            style={{
              padding: "6px 12px", fontSize: 12, fontWeight: 700,
              background: T.blue, color: T.white, border: "none",
              borderRadius: 7, cursor: "pointer", flexShrink: 0,
            }}
          >✎ Edit</button>
        )}
        <button
          onClick={onClose}
          style={{
            padding: "6px 12px", fontSize: 12, fontWeight: 600,
            background: T.white, color: T.slate700, border: `1px solid ${T.slate300}`,
            borderRadius: 7, cursor: "pointer", flexShrink: 0,
          }}
        >← Back</button>
      </div>



      {/* 1. Opener */}
      <Section>
        <OpenerSection
          weekDate={weekDate} report={data.report}
          editMode={edit.active}
          formValue={edit.form.report.opener_text}
          dirty={edit.isReportDirty("opener_text")}
          onChange={edit.setReportField}
        />
      </Section>

      {/* 3. Looking at next week */}
      <Section>
        <LookingNextWeekSection
          report={data.report}
          editMode={edit.active}
          formValue={edit.form.report.looking_next_week_text}
          dirty={edit.isReportDirty("looking_next_week_text")}
          onChange={edit.setReportField}
        />
      </Section>

      <Divider />

      {/* 5. Code reds/yellows */}
      <Section>
        <CodeRedsYellowsSection
          details={data.details} team={data.team}
          editMode={edit.active}
          formDetails={edit.form.details}
          isDirty={edit.isDetailDirty}
          onChange={edit.setDetailField}
        />
      </Section>

      {/* 6. Team checklist — single, report-level */}
      <Section>
        <TeamChecklistSection
          report={data.report}
          editMode={edit.active}
          formReport={edit.form.report}
          isReportDirty={edit.isReportDirty}
          onReportChange={edit.setReportField}
        />
      </Section>

      {/* 7. Personal checklist */}
      <Section>
        <PersonalChecklistSection
          details={data.details} team={data.team}
          editMode={edit.active}
          formDetails={edit.form.details}
          isDirty={edit.isDetailDirty}
          onChange={edit.setDetailField}
        />
      </Section>

      {/* 8. Requirements — Modified column editable */}
      <Section>
        <RequirementsSection
          details={data.details} team={data.team}
          runtimeReqs={data.runtimeReqs}
          editMode={edit.active}
          formDetails={edit.form.details}
          isDirty={edit.isDetailDirty}
          onChange={edit.setDetailField}
        />
      </Section>

      <Divider />

      {/* 10. Agency performance */}
      <Section>
        <AgencyPerformanceSection
          snapshot={data.snapshot}
          snapshotPrior={data.snapshotPrior}
          bookYearStart={data.bookYearStart}
          goals={data.goals}
          weekDate={weekDate}
          lapseRates={data.lapseRates}
          report={data.report}
          reportPrior={data.reportPrior}
          editMode={edit.active}
          formReport={edit.form.report}
          isReportDirty={edit.isReportDirty}
          onReportChange={edit.setReportField}
        />
      </Section>

      {/* 11. SMVC & Scorecard */}
      <Section><SMVCScorecardSection section11={data.section11} /></Section>


      {/* 12. Claims */}
      <Section>
        <ClaimsSection
          report={data.report}
          editMode={edit.active}
          formReport={edit.form.report}
          isReportDirty={edit.isReportDirty}
          onReportChange={edit.setReportField}
        />
      </Section>

      {/* 13. Non-pays */}
      <Section>
        <NonPaysSection
          report={data.report}
          editMode={edit.active}
          formReport={edit.form.report}
          isReportDirty={edit.isReportDirty}
          onReportChange={edit.setReportField}
        />
      </Section>

      {/* 13.5. EUR (Underwriting Reports) — text notes */}
      <Section>
        <EURSection
          report={data.report}
          editMode={edit.active}
          formReport={edit.form.report}
          isReportDirty={edit.isReportDirty}
          onReportChange={edit.setReportField}
        />
      </Section>

      {/* 14. Campaigns */}
      <Section>
        <CampaignsSection
          report={data.report}
          campaignPriors={data.campaignPriors}
          weekDate={weekDate}
          editMode={edit.active}
          formReport={edit.form.report}
          isReportDirty={edit.isReportDirty}
          onReportChange={edit.setReportField}
        />
      </Section>

      <Divider />

      {/* 16. Hours worked — read-only, runtime-computed from TimeClock */}
      <Section>
        <HoursWorkedSection
          details={data.details} team={data.team}
          runtimeHours={data.runtimeHours}
        />
      </Section>

      {/* 17. Team activity */}
      <Section>
        <TeamActivitySection
          details={data.details} team={data.team}
          truePayHistory={data.truePayHistory}
          runtimeReqs={data.runtimeReqs}
          report={data.report}
          editMode={edit.active}
          formDetails={edit.form.details}
          isDirty={edit.isDetailDirty}
          onChange={edit.setDetailField}
        weekDate={weekDate} lastWeekSalesPointsByMember={data.lastWeekSalesPointsByMember} cycleStartISO={data.cycleStartISO} />
      </Section>

      {/* 19. Payroll */}
      <Section><PayrollSection details={data.details} team={data.team} weekDate={weekDate} anchorPayrollYtd={data.anchorPayrollYtd} retentionBudgetAnnual={data.retentionBudgetAnnual} onRefresh={data.refresh} /></Section>

      {/* 20. True Pay Bonus history — HIDDEN per Peter 2026-06-20; restore by uncommenting */}
      {/* <Section><TruePayHistorySection team={data.team} truePayHistory={data.truePayHistory} weekDate={weekDate} /></Section> */}

      {/* 21. Leaderboards */}
      <Section><LeaderboardsSection /></Section>

      {/* 22. Prize Cart */}
      <Section><PrizeCartSection prizeCart={data.prizeCart} team={data.team} prizeBudget={data.section11?.prize_cart_budget?.value ?? null} /></Section>

      {/* Footer signoff */}
      <div style={{
        textAlign: "center", padding: "30px 0 10px",
        fontSize: 13, fontStyle: "italic", color: T.slate600,
      }}>
        — Peter
      </div>

      {edit.active && (
        <EditModeBar
          totalDirty={edit.totalDirty}
          saving={edit.saving}
          saveError={edit.saveError}
          onSave={doSave}
          onCancel={doCancel}
        />
      )}
    </div>
  );
}
