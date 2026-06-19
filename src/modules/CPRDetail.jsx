import { useState, useEffect } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
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
  if (!isFinite(v)) return "—";
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

const SectionHeader = ({ icon, title, hint }) => (
  <div style={{ marginBottom: 12 }}>
    <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
      {icon ? <span style={{ fontSize: 18 }}>{icon}</span> : null}
      <span style={{
        fontSize: 13, fontWeight: 800, color: T.slate800,
        textTransform: "uppercase", letterSpacing: 0.6,
      }}>{title}</span>
    </div>
    {hint ? (
      <div style={{ fontSize: 11, color: T.slate500, marginTop: 3, marginLeft: icon ? 28 : 0 }}>
        {hint}
      </div>
    ) : null}
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

const Td = ({ children, align = "left", style = {} }) => (
  <td style={{
    padding: "8px 8px", fontSize: 12, color: T.slate800,
    textAlign: align, borderBottom: `1px solid ${T.slate100}`,
    fontVariantNumeric: "tabular-nums", ...style,
  }}>{children}</td>
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
  report: ["notes"], // weekly_cpr_reports
  detail: [           // weekly_cpr_team_detail
    "code_reds", "code_yellows",
    "carryover", "missed", "cost", "total", "paid", "owed",
    "shareds_done", "texts_done", "deposits_done", "appts_done", "tasks_done",
    "cases_done", "no_onboarding_done", "no_fu_task_done", "new_opps_done",
    "no_phone_done", "bad_data_done",
    "cpr_reply_done", "wrapup_done", "inbox_done",
    "mon_hours", "mon_location", "tue_hours", "tue_location",
    "wed_hours", "wed_location", "thu_hours", "thu_location",
    "fri_hours", "fri_location",
  ],
};

// Roles allowed to edit a CPR. Mirrors the BCC role taxonomy.
const EDIT_ROLES = new Set(["owner", "manager"]);

// ── Checklist constants ─────────────────────────────────────
const TEAM_CHECKLIST_KEYS = [
  ["shareds_done", "Shared Outlook folders"],
  ["texts_done", "Texts recorded"],
  ["deposits_done", "Deposits finalized"],
  ["appts_done", "Appointments formatted"],
  ["tasks_done", "Tasks cleared"],
  ["cases_done", "Onboarding cases"],
  ["no_onboarding_done", "Non-onboarding closed"],
  ["no_fu_task_done", "No follow-up tasks"],
  ["new_opps_done", "New contacts"],
  ["no_phone_done", "No phone"],
  ["bad_data_done", "Quotes w/ missing data"],
];

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
  const [form, setForm] = useState({ report: {}, details: {} });
  const [dirty, setDirty] = useState({ report: new Set(), details: {} });
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState(null);

  const begin = (report, details) => {
    const r = {};
    for (const k of EDIT_FIELDS.report) r[k] = report?.[k] ?? null;
    const d = {};
    for (const row of details || []) {
      const v = {};
      for (const k of EDIT_FIELDS.detail) v[k] = row?.[k] ?? null;
      d[row.id] = v;
    }
    setForm({ report: r, details: d });
    setDirty({ report: new Set(), details: {} });
    setSaveError(null);
    setActive(true);
  };
  const cancel = () => {
    setForm({ report: {}, details: {} });
    setDirty({ report: new Set(), details: {} });
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
  const isDetailDirty = (rowId, field) => !!dirty.details[rowId]?.has(field);
  const totalDirty = dirty.report.size +
    Object.values(dirty.details).reduce((s, set) => s + set.size, 0);

  return {
    active, form, dirty, saving, saveError,
    begin, cancel,
    setReportField, setDetailField,
    isReportDirty, isDetailDirty,
    totalDirty,
    setSaving, setSaveError,
    finishSave: () => { setActive(false); setForm({ report: {}, details: {} }); setDirty({ report: new Set(), details: {} }); setSaveError(null); setSaving(false); },
  };
}

// ── Data fetcher ────────────────────────────────────────────
function useCPRData(weekDate) {
  const [reloadKey, setReloadKey] = useState(0);
  const [state, setState] = useState({
    loading: true,
    error: null,
    report: null,        // weekly_cpr_reports row
    details: [],         // weekly_cpr_team_detail rows
    team: [],            // team table (active, by tenure)
    snapshot: null,      // sf_on_time_snapshot row (most recent <= week end)
    snapshotPrior: null, // sf_on_time_snapshot row (prior week)
    bookYearStart: null, // book_snapshot row at year start
    bookCurrent: null,   // book_snapshot row (most recent)
    goals: [],           // book_performance_goals rows (current year)
    campaigns: [],       // cpr_campaigns rows (most recent per type)
    truePayHistory: {},  // {team_member_id: [{week_ending_date, true_pay_bonus}]}
  });

  useEffect(() => {
    if (!isValidISODate(weekDate) || !supabase) return;
    let cancelled = false;

    async function load() {
      setState(s => ({ ...s, loading: true, error: null }));
      try {
        const year = parseInt(weekDate.slice(0, 4), 10);

        // 1. Team (active, tenure order)
        const { data: teamRows } = await supabase
          .from("team")
          .select("id, full_name, hire_date, role, role_level, category")
          .eq("agency_id", AGENCY_ID)
          .eq("is_active", true)
          .order("hire_date", { ascending: true })
          .order("full_name", { ascending: true });

        // 2. Report row for this week
        const { data: reportRow } = await supabase
          .from("weekly_cpr_reports")
          .select("*")
          .eq("agency_id", AGENCY_ID)
          .eq("week_ending_date", weekDate)
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

        // 4. sf_on_time_snapshot — most recent on/before week end
        const { data: snapRows } = await supabase
          .from("sf_on_time_snapshot")
          .select("*")
          .eq("agency_id", AGENCY_ID)
          .lte("snapshot_date", weekDate)
          .order("snapshot_date", { ascending: false })
          .limit(2);
        const snapshot = (snapRows && snapRows[0]) || null;
        const snapshotPrior = (snapRows && snapRows[1]) || null;

        // 5. book_snapshot — year-start anchor + most recent
        const yearStart = `${year}-01-01`;
        const { data: bookYS } = await supabase
          .from("book_snapshot")
          .select("*")
          .eq("agency_id", AGENCY_ID)
          .eq("snapshot_date", yearStart)
          .maybeSingle();
        const { data: bookNowRows } = await supabase
          .from("book_snapshot")
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

        // 7. cpr_campaigns — most recent per type (we sort client-side)
        const { data: campRows } = await supabase
          .from("cpr_campaigns")
          .select("*")
          .eq("agency_id", AGENCY_ID)
          .order("created_on", { ascending: false })
          .limit(50);

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
        if (histReports && histReports.length > 0) {
          const reportIds = histReports.map(r => r.id);
          const { data: histDetail } = await supabase
            .from("weekly_cpr_team_detail")
            .select("team_member_id, weekly_cpr_report_id, true_pay_bonus")
            .eq("agency_id", AGENCY_ID)
            .in("weekly_cpr_report_id", reportIds);
          // Index report id → date for lookups
          const reportDateById = {};
          histReports.forEach(r => { reportDateById[r.id] = r.week_ending_date; });
          // Group by team_member_id
          (histDetail || []).forEach(d => {
            const tmId = d.team_member_id;
            if (!truePayHistory[tmId]) truePayHistory[tmId] = [];
            truePayHistory[tmId].push({
              week_ending_date: reportDateById[d.weekly_cpr_report_id],
              true_pay_bonus: Number(d.true_pay_bonus) || 0,
            });
          });
          // Sort each person's history desc
          Object.keys(truePayHistory).forEach(k => {
            truePayHistory[k].sort((a, b) => b.week_ending_date.localeCompare(a.week_ending_date));
          });
        }

        if (cancelled) return;

        setState({
          loading: false, error: null,
          report: reportRow || null,
          details: detailRows,
          team: teamRows || [],
          snapshot,
          snapshotPrior,
          bookYearStart: bookYS || null,
          bookCurrent,
          goals: goalRows || [],
          campaigns: campRows || [],
          truePayHistory,
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
  // Opener is Claude-drafted, stored in weekly_cpr_reports.notes for the page.
  // In edit mode: render textarea wired to form. In view mode: render text or Awaiting.
  const text = report?.notes && report.notes.trim().length > 0 ? report.notes : null;
  return (
    <Card>
      <div style={{ fontSize: 11, color: T.slate500, marginBottom: 6, fontWeight: 600, letterSpacing: 0.4, textTransform: "uppercase" }}>
        CPR Recap — Week ending {fmtDateLong(weekDate)}
      </div>
      {editMode ? (
        <TextArea
          value={formValue}
          onChange={v => onChange("notes", v)}
          dirty={dirty}
          rows={8}
          style={{ fontSize: 14, lineHeight: 1.7 }}
        />
      ) : text ? (
        <div style={{
          fontSize: 14, color: T.slate800, lineHeight: 1.7, whiteSpace: "pre-wrap",
        }}>{text}</div>
      ) : (
        <Awaiting message="Opener pending — will be drafted from this week's data" />
      )}
    </Card>
  );
}

// 3 — Looking At Next Week (Claude-drafted; not stored in DB yet)
function LookingNextWeekSection() {
  return (
    <div>
      <SectionHeader icon="🎯" title="Looking at Next Week" hint="Focus items drafted from real data" />
      <Card>
        <Awaiting message="Next-week focus items pending" />
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
          <SectionHeader title="Code Reds / Code Yellows" hint="Edit per-person notes" />
          <Card><Awaiting message="No team detail rows yet — code reds/yellows can be added once detail rows exist" /></Card>
        </div>
      );
    }
    return (
      <div>
        <SectionHeader title="Code Reds / Code Yellows" hint="Edit per-person notes" />
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
                  <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12 }}>
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
function TeamChecklistSection({ details, team, editMode, formDetails, isDirty, onChange }) {
  if (!details || details.length === 0) {
    return (
      <div>
        <SectionHeader icon="✅" title="Team Checklist" hint="11 daily-ops + opportunity items, full per-person grid" />
        <Card><Awaiting /></Card>
      </div>
    );
  }
  // Detail rows ordered by tenure
  const sorted = sortByTenure(details, team);
  return (
    <div>
      <SectionHeader icon="✅" title="Team Checklist" hint={editMode ? "Toggle each cell — yellow = unsaved" : "Daily ops + opportunity lists, 11 items per person"} />
      <Card style={{ padding: 0, overflow: "hidden" }}>
        <div style={{ overflowX: "auto" }}>
          <table style={{ width: "100%", borderCollapse: "collapse", minWidth: 720 }}>
            <thead>
              <tr>
                <Th align="left">Item</Th>
                {sorted.map(d => (
                  <Th key={d.team_member_id} align="center">{firstName(d.__name)}</Th>
                ))}
              </tr>
            </thead>
            <tbody>
              {TEAM_CHECKLIST_KEYS.map(([key, label]) => (
                <tr key={key}>
                  <Td style={{ paddingLeft: 14, color: T.slate700 }}>{label}</Td>
                  {sorted.map(d => {
                    const formVal = editMode ? (formDetails[d.id]?.[key] ?? null) : d[key];
                    if (editMode) {
                      return (
                        <Td key={d.team_member_id} align="center" style={{ padding: 4 }}>
                          <Checkbox
                            checked={formVal === true}
                            onChange={v => onChange(d.id, key, v)}
                            dirty={isDirty(d.id, key)}
                          />
                        </Td>
                      );
                    }
                    return (
                      <Td key={d.team_member_id} align="center">
                        {d[key] === false
                          ? <span style={{ color: T.red, fontSize: 14 }}>✕</span>
                          : <span style={{ color: T.green, fontSize: 14 }}>✓</span>}
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

// 7 — Personal Checklist (CPR Reply / Wrap-up / Inbox per person)
function PersonalChecklistSection({ details, team, editMode, formDetails, isDirty, onChange }) {
  if (!details || details.length === 0) {
    return (
      <div>
        <SectionHeader icon="🧍" title="Personal Checklist" hint="CPR Reply, Wrap-up, Inbox per person" />
        <Card><Awaiting /></Card>
      </div>
    );
  }
  const sorted = sortByTenure(details, team);
  return (
    <div>
      <SectionHeader icon="🧍" title="Personal Checklist" hint="CPR Reply, Wrap-up, Inbox per person" />
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
                        {d[key] === false
                          ? <span style={{ color: T.red, fontSize: 14 }}>✕</span>
                          : <span style={{ color: T.green, fontSize: 14 }}>✓</span>}
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
function RequirementsSection({ details, team, editMode, formDetails, isDirty, onChange }) {
  if (!details || details.length === 0) {
    return (
      <div>
        <SectionHeader icon="⭐" title="Requirements" hint="Per-person quote requirements, by tenure" />
        <Card><Awaiting /></Card>
      </div>
    );
  }
  const sorted = sortByTenure(details, team);
  const REQ_KEYS = ["carryover", "missed", "cost", "total", "paid", "owed"];
  return (
    <div>
      <SectionHeader icon="⭐" title="Requirements" hint="Quote counts — not dollars" />
      <Card style={{ padding: 0, overflow: "hidden" }}>
        <div style={{ overflowX: "auto" }}>
          <table style={{ width: "100%", borderCollapse: "collapse", minWidth: 600 }}>
            <thead>
              <tr>
                <Th align="left">Person</Th>
                <Th align="right">Last Wk</Th>
                <Th align="right">This Wk</Th>
                <Th align="right">Cost</Th>
                <Th align="right">Total</Th>
                <Th align="right">Paid</Th>
                <Th align="right">Next Wk</Th>
              </tr>
            </thead>
            <tbody>
              {sorted.map(d => (
                <tr key={d.team_member_id}>
                  <Td style={{ paddingLeft: 14, color: T.slate700, fontWeight: 600 }}>{firstName(d.__name)}</Td>
                  {REQ_KEYS.map(key => {
                    if (editMode) {
                      return (
                        <Td key={key} align="right" style={{ padding: 6 }}>
                          <NumberInput
                            value={formDetails[d.id]?.[key]}
                            onChange={v => onChange(d.id, key, v)}
                            dirty={isDirty(d.id, key)}
                            min={0}
                            step={1}
                          />
                        </Td>
                      );
                    }
                    const isOwed = key === "owed";
                    return (
                      <Td key={key} align="right" style={isOwed ? { fontWeight: 700, color: T.slate900 } : {}}>
                        {fmtInt(d[key])}
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

// 10 — Agency Performance (full version — all rows the email dropped)
function AgencyPerformanceSection({ snapshot, snapshotPrior, bookYearStart, goals }) {
  if (!snapshot) {
    return (
      <div>
        <SectionHeader icon="🎯" title="Agency Performance" hint="Full LOB breakdown — Auto, Fire, Life" />
        <Card><Awaiting message="No on-time snapshot loaded yet for this week" /></Card>
      </div>
    );
  }
  const autoYsPIF = bookYearStart?.auto_pif || null;
  const firePIF_YS = bookYearStart?.fire_pif || null;
  const lifePIF_YS = bookYearStart?.life_pif || null;

  const lines = [
    {
      label: "Auto Gain",
      ytd: ((snapshot.auto_production_ytd || 0) - (snapshot.auto_lapse_ytd || 0)),
      goal: goalFor(goals, "auto", "gain"),
    },
    {
      label: "Fire Gain",
      ytd: ((snapshot.fire_production_ytd || 0) - (snapshot.fire_lapse_ytd || 0)),
      goal: goalFor(goals, "fire", "gain"),
    },
    {
      label: "Life Gain",
      ytd: ((snapshot.life_production_ytd || 0) - (snapshot.life_loss_ytd || 0)),
      goal: goalFor(goals, "life", "gain"),
    },
    {
      label: "Life Paid #",
      ytd: snapshot.life_paid_count_ytd || 0,
      goal: goalFor(goals, "life", "net_paid_for"),
    },
    {
      label: "Life Premium",
      ytd: Number(snapshot.life_premium_credits_ytd) || 0,
      goal: goalFor(goals, "life", "premium"),
      isMoney: true,
    },
  ];

  return (
    <div>
      <SectionHeader icon="🎯" title="Agency Performance" hint="Five goal-pointing rows — Scorecard $ / SMVC % / Chairman's Circle" />
      <Card style={{ padding: 0, overflow: "hidden" }}>
        <div style={{ overflowX: "auto" }}>
          <table style={{ width: "100%", borderCollapse: "collapse", minWidth: 540 }}>
            <thead>
              <tr>
                <Th align="left">Metric</Th>
                <Th align="right" style={{ background: T.slate50 }}>YTD</Th>
                <Th align="right" style={{ background: T.blueLt, color: T.slate800 }}>Goal</Th>
                <Th align="right" style={{ background: T.blueLt, color: T.slate800 }}>Diff</Th>
              </tr>
            </thead>
            <tbody>
              {lines.map(line => {
                const diff = line.goal !== null ? (Number(line.ytd) - Number(line.goal)) : null;
                return (
                  <tr key={line.label}>
                    <Td style={{ paddingLeft: 14, color: T.slate700, fontWeight: 600 }}>{line.label}</Td>
                    <Td align="right">{line.isMoney ? fmtMoney(line.ytd) : fmtInt(line.ytd)}</Td>
                    <Td align="right" style={{ background: T.blueLt }}>
                      {line.goal === null ? "—" : (line.isMoney ? fmtMoney(line.goal) : fmtInt(line.goal))}
                    </Td>
                    <Td align="right" style={{ background: T.blueLt, fontWeight: 700, color: diff === null ? T.slate500 : (diff >= 0 ? T.green : T.red) }}>
                      {diff === null ? "—" : (line.isMoney ? (diff >= 0 ? "+" : "") + fmtMoney(diff) : fmtSigned(diff))}
                    </Td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
        {(autoYsPIF || firePIF_YS || lifePIF_YS) ? (
          <div style={{
            padding: "10px 18px", borderTop: `1px solid ${T.slate100}`,
            fontSize: 11, color: T.slate500,
          }}>
            Year-start PIF anchors: Auto {fmtInt(autoYsPIF)} &nbsp;·&nbsp; Fire {fmtInt(firePIF_YS)} &nbsp;·&nbsp; Life {fmtInt(lifePIF_YS)}
          </div>
        ) : null}
      </Card>
    </div>
  );
}

// 11 — SMVC & Scorecard
function SMVCScorecardSection({ snapshot }) {
  if (!snapshot) {
    return (
      <div>
        <SectionHeader icon="🎯" title="SMVC & Scorecard" />
        <Card><Awaiting /></Card>
      </div>
    );
  }
  return (
    <div>
      <SectionHeader icon="🎯" title="SMVC & Scorecard" />
      <Card>
        <Awaiting message="SMVC/Scorecard runtime calc pending — depends on the SMVC weekly calculator (deferred work item)" />
      </Card>
    </div>
  );
}

// 12 — Claims
function ClaimsSection({ report }) {
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

// 13 — Non-Pays
function NonPaysSection({ report }) {
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
function CampaignsSection({ campaigns }) {
  const TYPES = ["defectors", "single_line", "af_renewals", "onboarding"];
  const LABELS = {
    defectors: "Defectors",
    single_line: "Single-Line At-Risk",
    af_renewals: "A/F Renewals",
    onboarding: "Onboarding",
  };
  const latestByType = {};
  (campaigns || []).forEach(c => {
    if (!latestByType[c.campaign_type] || c.created_on > latestByType[c.campaign_type]) {
      latestByType[c.campaign_type] = c.created_on;
    }
  });
  return (
    <div>
      <SectionHeader icon="📋" title="Campaigns" />
      <Card>
        <div style={{ fontSize: 13, color: T.slate800, display: "flex", flexWrap: "wrap", gap: 14 }}>
          {TYPES.map(t => (
            <span key={t}>
              <strong>{LABELS[t]}</strong>: {latestByType[t] ? fmtMMDD(latestByType[t]) : "—"}
            </span>
          ))}
        </div>
      </Card>
    </div>
  );
}

// 16 — Hours Worked (Mon-Fri grid + total)
function HoursWorkedSection({ details, team, editMode, formDetails, isDirty, onChange }) {
  if (!details || details.length === 0) {
    return (
      <div>
        <SectionHeader icon="🕐" title="Hours Worked" hint="🟢 in-office &nbsp;·&nbsp; 🟣 remote" />
        <Card><Awaiting /></Card>
      </div>
    );
  }
  const sorted = sortByTenure(details, team);
  const DAYS = ["mon", "tue", "wed", "thu", "fri"];
  const DAY_LABELS = { mon: "Mon", tue: "Tue", wed: "Wed", thu: "Thu", fri: "Fri" };
  return (
    <div>
      <SectionHeader icon="🕐" title="Hours Worked" hint={editMode ? "hours + location per day, per person" : "🟢 in-office  ·  🟣 remote"} />
      <Card style={{ padding: 0, overflow: "hidden" }}>
        <div style={{ overflowX: "auto" }}>
          <table style={{ width: "100%", borderCollapse: "collapse", minWidth: editMode ? 880 : 600 }}>
            <thead>
              <tr>
                <Th align="left">Person</Th>
                {DAYS.map(day => <Th key={day} align="center">{DAY_LABELS[day]}</Th>)}
                {!editMode && <Th align="right">Total</Th>}
              </tr>
            </thead>
            <tbody>
              {sorted.map(d => {
                if (editMode) {
                  const row = formDetails[d.id] || {};
                  return (
                    <tr key={d.team_member_id}>
                      <Td style={{ paddingLeft: 14, color: T.slate700, fontWeight: 600 }}>{firstName(d.__name)}</Td>
                      {DAYS.map(day => (
                        <Td key={day} align="center" style={{ padding: 6 }}>
                          <div style={{ display: "flex", flexDirection: "column", gap: 4, alignItems: "center" }}>
                            <NumberInput
                              value={row[`${day}_hours`]}
                              onChange={v => onChange(d.id, `${day}_hours`, v)}
                              dirty={isDirty(d.id, `${day}_hours`)}
                              min={0} max={24} step={0.5}
                              style={{ width: 64 }}
                            />
                            <LocationSelect
                              value={row[`${day}_location`]}
                              onChange={v => onChange(d.id, `${day}_location`, v)}
                              dirty={isDirty(d.id, `${day}_location`)}
                            />
                          </div>
                        </Td>
                      ))}
                    </tr>
                  );
                }
                const total = DAYS.reduce((sum, day) => sum + (Number(d[`${day}_hours`]) || 0), 0);
                return (
                  <tr key={d.team_member_id}>
                    <Td style={{ paddingLeft: 14, color: T.slate700, fontWeight: 600 }}>{firstName(d.__name)}</Td>
                    {DAYS.map(day => (
                      <Td key={day} align="center">
                        {d[`${day}_hours`] != null ? (
                          <span>
                            {Number(d[`${day}_hours`]).toFixed(1)}
                            {d[`${day}_location`] === "remote" ? " 🟣" : d[`${day}_location`] === "office" ? " 🟢" : ""}
                          </span>
                        ) : "—"}
                      </Td>
                    ))}
                    <Td align="right" style={{ fontWeight: 700 }}>{total > 0 ? total.toFixed(1) : "—"}</Td>
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

// 17 — Team Activity (Quotes / Net Quotes / Sales Pts / ↑ 1%)
function TeamActivitySection({ details, team, truePayHistory }) {
  if (!details || details.length === 0) {
    return (
      <div>
        <SectionHeader icon="📊" title="Team Activity" hint="Quotes, Net Quotes, Sales Points, and 13-wk delta" />
        <Card><Awaiting /></Card>
      </div>
    );
  }
  const sorted = sortByTenure(details, team);
  return (
    <div>
      <SectionHeader icon="📊" title="Team Activity" />
      <Card style={{ padding: 0, overflow: "hidden" }}>
        <div style={{ overflowX: "auto" }}>
          <table style={{ width: "100%", borderCollapse: "collapse", minWidth: 540 }}>
            <thead>
              <tr>
                <Th align="left">Person</Th>
                <Th align="right">Quotes</Th>
                <Th align="right">Net Quotes</Th>
                <Th align="right">Sales Pts</Th>
                <Th align="right">↑ 1% vs 13-wk</Th>
              </tr>
            </thead>
            <tbody>
              {sorted.map(d => (
                <tr key={d.team_member_id}>
                  <Td style={{ paddingLeft: 14, color: T.slate700, fontWeight: 600 }}>{firstName(d.__name)}</Td>
                  <Td align="right">{fmtInt(d.quotes_discussed)}</Td>
                  <Td align="right">{fmtInt(d.quotes_net)}</Td>
                  <Td align="right">{d.sales_points != null ? Number(d.sales_points).toFixed(2) : "—"}</Td>
                  <Td align="right">—</Td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <div style={{ padding: "10px 18px", borderTop: `1px solid ${T.slate100}`, fontSize: 11, color: T.slate500 }}>
          13-wk delta column wiring pending (needs sales-points history aggregation).
        </div>
      </Card>
    </div>
  );
}

// 18 — Team Performance (3-line block: quotes flow, sales pace, won the week)
function TeamPerformanceSection({ report }) {
  if (!report) {
    return (
      <div>
        <SectionHeader icon="📊" title="Team Performance" />
        <Card><Awaiting /></Card>
      </div>
    );
  }
  const wonStr = report.won_the_week === true ? "✅ Yes" : report.won_the_week === false ? "❌ No" : "—";
  const target = Number(report.quarterly_sales_points_target) || 0;
  const qtd = Number(report.quarterly_sales_points_qtd) || 0;
  const pacePct = target > 0 ? (qtd / target * 100).toFixed(1) : "—";
  return (
    <div>
      <SectionHeader icon="📊" title="Team Performance" />
      <Card>
        <div style={{ fontSize: 13, lineHeight: 1.9, color: T.slate800 }}>
          <div>
            Quotes: {fmtInt(report.quotes_owed_carryover)} owed last wk → {fmtInt(report.quotes_fresh_needed)} fresh needed → {fmtInt(report.quotes_total_net)} net → <strong>{fmtInt(report.quotes_owed_next_week)} owed next wk</strong>
          </div>
          <div>
            Quarterly sales points: {qtd.toFixed(2)} / {target.toFixed(2)} QTD ({pacePct === "—" ? "—" : pacePct + "%"} pace)
          </div>
          <div>
            Won the Week: <strong>{wonStr}</strong>
          </div>
        </div>
      </Card>
    </div>
  );
}

// 19 — Payroll (per-person columns, pay component rows)
function PayrollSection({ details, team }) {
  if (!details || details.length === 0) {
    return (
      <div>
        <SectionHeader icon="💰" title="Payroll" hint="Per-person pay components" />
        <Card><Awaiting /></Card>
      </div>
    );
  }
  const sorted = sortByTenure(details, team);
  const ROWS = [
    ["weekly_pay", "Weekly Pay"],
    ["base_advance", "Base Advance"],
    ["health_bonus", "Health Bonus"],
    ["service_surge_share", "Service Surge"],
    ["true_pay_bonus", "True Pay Bonus"],
    ["manager_bonus", "Manager Bonus"],
    ["agency_profit_share", "Agency Profit"],
  ];
  return (
    <div>
      <SectionHeader icon="💰" title="Payroll" />
      <Card style={{ padding: 0, overflow: "hidden" }}>
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
              <tr>
                <Td style={{ paddingLeft: 14, color: T.slate900, fontWeight: 800, borderTop: `2px solid ${T.slate300}` }}>Week total</Td>
                {sorted.map(d => {
                  const total = ROWS.reduce((sum, [k]) => sum + (Number(d[k]) || 0), 0);
                  return (
                    <Td key={d.team_member_id} align="right" style={{ fontWeight: 800, borderTop: `2px solid ${T.slate300}` }}>
                      {fmtMoneyCents(total)}
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
  const sorted = [...(team || [])];
  if (!truePayHistory || Object.keys(truePayHistory).length === 0) {
    return (
      <div>
        <SectionHeader icon="📈" title="True Pay Bonus History" hint="Full weekly history + 5 averages (page-only detail)" />
        <Card><Awaiting message="No True Pay Bonus history yet — populates as weekly_cpr_team_detail accumulates" /></Card>
      </div>
    );
  }
  // Collect unique week-ending dates across all people (most recent 13 for the table)
  const weekSet = new Set();
  Object.values(truePayHistory).forEach(rows => rows.forEach(r => weekSet.add(r.week_ending_date)));
  const weeks = Array.from(weekSet).sort((a, b) => b.localeCompare(a)).slice(0, 13);

  // Build cell lookup
  const lookup = {};
  Object.entries(truePayHistory).forEach(([tmId, rows]) => {
    lookup[tmId] = {};
    rows.forEach(r => { lookup[tmId][r.week_ending_date] = r.true_pay_bonus; });
  });

  // Averages helper — over a list of values (only weeks that have data for that person)
  const avgOver = (tmId, n) => {
    const rows = (truePayHistory[tmId] || []).slice(0, n);
    if (rows.length === 0) return null;
    const sum = rows.reduce((s, r) => s + (Number(r.true_pay_bonus) || 0), 0);
    return sum / rows.length;
  };

  return (
    <div>
      <SectionHeader icon="📈" title="True Pay Bonus History" hint="Most recent 13 weeks + multi-window averages" />
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
        <div style={{ padding: "10px 18px", borderTop: `1px solid ${T.slate100}`, fontSize: 11, color: T.slate500 }}>
          Last Q / Q-2 / Q-3 averages pending — depend on quarter boundary helpers being wired.
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
function PrizeCartSection() {
  return (
    <div>
      <SectionHeader icon="🏆" title="Prize Cart" />
      <Card>
        <Awaiting message="Prize Cart wiring pending — 13 prizes for the quarter" />
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
export default function CPRDetail({ weekDate, onClose = () => {}, userRole = null }) {
  const data = useCPRData(weekDate);
  const edit = useEditForm();
  const canEdit = EDIT_ROLES.has(userRole);

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
    edit.begin(data.report, data.details);
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

  return (
    <div style={{ maxWidth: 1100, margin: "0 auto" }}>
      {/* Top breadcrumb / back / edit */}
      <div style={{
        display: "flex", alignItems: "center", justifyContent: "space-between",
        marginBottom: 16, gap: 12,
      }}>
        <div>
          <div style={{ fontSize: 22, fontWeight: 800, color: T.slate900, letterSpacing: "-0.02em" }}>
            📊 CPR Recap {edit.active && <span style={{ fontSize: 13, color: T.amber700 || "#a16207", fontWeight: 700, marginLeft: 10 }}>· Editing</span>}
          </div>
          <div style={{ fontSize: 12, color: T.slate500, marginTop: 4 }}>
            Week ending {fmtDateLong(weekDate)} &nbsp;·&nbsp; ({fmtRange(weekDate)})
          </div>
        </div>
        <div style={{ display: "flex", gap: 8 }}>
          {canEdit && !edit.active && (
            <button
              onClick={doStartEdit}
              style={{
                padding: "8px 14px", fontSize: 12, fontWeight: 700,
                background: T.blue, color: T.white, border: "none",
                borderRadius: 8, cursor: "pointer",
              }}
            >✎ Edit</button>
          )}
          <button
            onClick={onClose}
            disabled={edit.active && edit.totalDirty > 0 ? false : false}
            style={{
              padding: "8px 14px", fontSize: 12, fontWeight: 600,
              background: T.white, color: T.slate700, border: `1px solid ${T.slate300}`,
              borderRadius: 8, cursor: "pointer",
            }}
          >← Back to BCC</button>
        </div>
      </div>

      {/* 1. Opener */}
      <Section>
        <OpenerSection
          weekDate={weekDate} report={data.report}
          editMode={edit.active}
          formValue={edit.form.report.notes}
          dirty={edit.isReportDirty("notes")}
          onChange={edit.setReportField}
        />
      </Section>

      {/* 3. Looking at next week */}
      <Section><LookingNextWeekSection /></Section>

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

      {/* 6. Team checklist */}
      <Section>
        <TeamChecklistSection
          details={data.details} team={data.team}
          editMode={edit.active}
          formDetails={edit.form.details}
          isDirty={edit.isDetailDirty}
          onChange={edit.setDetailField}
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

      {/* 8. Requirements */}
      <Section>
        <RequirementsSection
          details={data.details} team={data.team}
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
        />
      </Section>

      {/* 11. SMVC & Scorecard */}
      <Section><SMVCScorecardSection snapshot={data.snapshot} /></Section>

      {/* 12. Claims */}
      <Section><ClaimsSection report={data.report} /></Section>

      {/* 13. Non-pays */}
      <Section><NonPaysSection report={data.report} /></Section>

      {/* 14. Campaigns */}
      <Section><CampaignsSection campaigns={data.campaigns} /></Section>

      <Divider />

      {/* 16. Hours worked */}
      <Section>
        <HoursWorkedSection
          details={data.details} team={data.team}
          editMode={edit.active}
          formDetails={edit.form.details}
          isDirty={edit.isDetailDirty}
          onChange={edit.setDetailField}
        />
      </Section>

      {/* 17. Team activity */}
      <Section>
        <TeamActivitySection details={data.details} team={data.team} truePayHistory={data.truePayHistory} />
      </Section>

      {/* 18. Team performance */}
      <Section><TeamPerformanceSection report={data.report} /></Section>

      {/* 19. Payroll */}
      <Section><PayrollSection details={data.details} team={data.team} /></Section>

      {/* 20. True Pay Bonus history (full + averages) */}
      <Section><TruePayHistorySection team={data.team} truePayHistory={data.truePayHistory} weekDate={weekDate} /></Section>

      {/* 21. Leaderboards */}
      <Section><LeaderboardsSection /></Section>

      {/* 22. Prize Cart */}
      <Section><PrizeCartSection /></Section>

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
