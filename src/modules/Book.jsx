import { useState, useEffect, useMemo } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";


import { useTabParam, TabLink } from "../lib/routing.jsx";
import { fmtMoney } from "../lib/format.jsx";
// ============================================================
// Newtworks BOOK MODULE
// Newtworks — State Farm Agent Edition
//
// Two tabs:
//   • Snapshot — agency-level snapshots (premium, PIFs, households)
//                Unified table showing WoW/MoM/QoQ/YoY/since-appt side-by-side per item.
//                Reads: v_agency_growth_summary, v_agency_snapshot_with_changes.
//   • Assignments — alphabet split of household service
//                   assignments across the team. Snapshot-per-date.
//                   Reads: book_alpha via rp_book_alpha, team.
// ============================================================

// ─── Local Design Tokens & Helpers ────────────────────────────
const Card = ({ children, style={} }) => (
  <div style={{ background:T.white, border:`1px solid ${T.slate200}`, borderRadius:12, padding:"16px 18px", ...style }}>
    {children}
  </div>
);

const KPICard = ({ label, value, sub, color = T.slate900, border }) => (
  <div style={{
    background: T.white,
    border: `1px solid ${border || T.slate200}`,
    borderRadius: 12,
    padding: "14px 16px",
    borderTop: border ? `3px solid ${border}` : undefined,
  }}>
    <div style={{ fontSize: 11, color: T.slate500, fontWeight: 500, marginBottom: 6 }}>{label}</div>
    <div style={{ fontSize: 20, fontWeight: 700, color, letterSpacing: "-0.02em", marginBottom: 4 }}>{value}</div>
    {sub && <div style={{ fontSize: 11, color: T.slate400 }}>{sub}</div>}
  </div>
);

const TabBar = ({ tabs, active, onChange, hrefFor }) => (
  <div style={{
    display: "flex", gap: 2,
    background: T.slate100,
    borderRadius: 8, padding: 3,
    marginBottom: 16,
    flexWrap: "wrap",
  }}>
    {tabs.map(t => (
      <TabLink key={t.id} href={hrefFor ? hrefFor(t.id) : undefined} onSelect={() => onChange(t.id)} style={{
        padding: "6px 14px", fontSize: 12, fontWeight: active === t.id ? 600 : 400,
        color: active === t.id ? T.slate900 : T.slate500,
        background: active === t.id ? T.white : "transparent",
        border: "none", borderRadius: 6, cursor: "pointer",
        transition: "all 0.12s",
        boxShadow: active === t.id ? "0 1px 3px rgba(0,0,0,0.08)" : "none",
      }}>{t.label}</TabLink>
    ))}
  </div>
);

const fmt = (n) => fmtMoney(n, { decimals: 0, dashOnZero: true });

// ============================================================
// TAB 1 — Book Snapshot (agency size + growth, all horizons side-by-side)
// ============================================================
function useBookData() {
  const [data, setData] = useState({ summary: null, history: [] });
  const [loading, setLoading] = useState(true);
  const [refreshKey, setRefreshKey] = useState(0);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      setLoading(true);
      try {
        const [summaryRes, historyRes] = await Promise.all([
          supabase.from("v_agency_growth_summary").select("*").eq("agency_id", AGENCY_ID),
          supabase.from("v_agency_snapshot_with_changes").select("*").eq("agency_id", AGENCY_ID).order("snapshot_date", { ascending: false }).limit(120),
        ]);
        if (cancelled) return;
        const summaries = Array.isArray(summaryRes?.data) ? summaryRes.data : [];
        const isPopulated = (r) => r && (
          r.auto_premium != null || r.fire_premium != null || r.life_premium != null ||
          r.auto_pif != null || r.fire_pif != null || r.life_pif != null ||
          r.household_count != null
        );
        const weeklySum = summaries.find(r => r?.cadence === "weekly" && isPopulated(r));
        const monthlySum = summaries.find(r => r?.cadence === "monthly" && isPopulated(r));
        setData({
          summary: weeklySum || monthlySum || null,
          history: Array.isArray(historyRes?.data) ? historyRes.data : [],
        });
      } catch (err) {
        console.error("useBookData load failed:", err);
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    load();
    return () => { cancelled = true; };
  }, [refreshKey]);

  return { data, loading, refresh: () => setRefreshKey(k => k + 1) };
}

const fmtSnapDate = (d) => {
  if (!d) return "—";
  try { return new Date(d + "T00:00:00").toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" }); }
  catch { return String(d); }
};

const fmtPct = (n) => {
  if (n === null || n === undefined || !Number.isFinite(Number(n))) return "—";
  const v = Number(n);
  return `${v > 0 ? "+" : ""}${v.toFixed(2)}%`;
};

const pctColor = (n) => {
  if (n === null || n === undefined || !Number.isFinite(Number(n))) return T.slate500;
  const v = Number(n);
  if (v > 0) return T.green;
  if (v < 0) return T.red;
  return T.slate500;
};

const bookThStyle = { textAlign: "left", padding: "8px 10px", fontWeight: 600, color: T.slate600, fontSize: 10, textTransform: "uppercase", letterSpacing: "0.05em" };
const bookTdStyle = { padding: "8px 10px", color: T.slate700, fontSize: 11 };

const CollapseHeader = ({ title, open, onToggle }) => (
  <div onClick={onToggle} style={{ display: "flex", justifyContent: "space-between", alignItems: "center", cursor: "pointer", userSelect: "none" }}>
    <div style={{ fontSize: 13, fontWeight: 600, color: T.slate800 }}>{title}</div>
    <div style={{ fontSize: 14, color: T.slate500 }}>{open ? "▾" : "▸"}</div>
  </div>
);

const BookSizeAddForm = ({ onAdded }) => {
  const today = new Date().toISOString().slice(0, 10);
  const emptyForm = {
    snapshot_date: today, cadence: "weekly",
    auto_premium: "", fire_premium: "", life_premium: "",
    auto_pif: "", fire_pif: "", life_pif: "",
    household_count: "",
    auto_new_ytd: "", auto_lost_ytd: "",
    fire_new_ytd: "", fire_lost_ytd: "",
    life_new_ytd: "", life_lost_ytd: "",
    life_paid_for_count_ytd: "", life_paid_for_premium_ytd: "",
    ips_new_money_ytd: "",
    notes: "",
  };
  const [form, setForm] = useState(emptyForm);
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState(null);
  const [existingSource, setExistingSource] = useState(null);
  const [loadingExisting, setLoadingExisting] = useState(false);

  const set = (k, v) => setForm(f => ({ ...f, [k]: v }));

  // Treat numeric input that looks like a percentage (e.g. 82 for 82%) as decimal (0.82)
  // ONLY for the two pct fields. Everything else is parsed as-is.
  const numOrNull = (v) => {
    if (v === "" || v == null) return null;
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  };
  const pctOrNull = (v) => {
    if (v === "" || v == null) return null;
    const n = Number(v);
    if (!Number.isFinite(n)) return null;
    return n > 1.5 ? n / 100 : n;
  };
  const fmtPctForInput = (v) => {
    if (v === null || v === undefined) return "";
    const n = Number(v);
    if (!Number.isFinite(n)) return "";
    return String(n);
  };

  // Pre-fill: when date or cadence changes, look up the existing row and populate the form
  useEffect(() => {
    if (!form.snapshot_date || !form.cadence) return;
    let cancelled = false;
    (async () => {
      setLoadingExisting(true);
      setErr(null);
      try {
        const { data, error } = await supabase
          .from("agency_snapshot")
          .select("*")
          .eq("agency_id", AGENCY_ID)
          .eq("snapshot_date", form.snapshot_date)
          .eq("cadence", form.cadence)
          .maybeSingle();
        if (cancelled) return;
        if (error) {
          // .maybeSingle() throws on multi-row, otherwise returns null cleanly; surface but don't block
          console.warn("BookSizeAddForm pre-fill lookup failed:", error);
          setExistingSource(null);
          return;
        }
        if (data) {
          setForm(f => ({
            ...f,
            auto_premium:              data.auto_premium              ?? "",
            fire_premium:              data.fire_premium              ?? "",
            life_premium:              data.life_premium              ?? "",
            auto_pif:                  data.auto_pif                  ?? "",
            fire_pif:                  data.fire_pif                  ?? "",
            life_pif:                  data.life_pif                  ?? "",
            household_count:           data.household_count           ?? "",
            auto_new_ytd:              data.auto_new_ytd              ?? "",
            auto_lost_ytd:             data.auto_lost_ytd             ?? "",
            fire_new_ytd:              data.fire_new_ytd              ?? "",
            fire_lost_ytd:             data.fire_lost_ytd             ?? "",
            life_new_ytd:              data.life_new_ytd              ?? "",
            life_lost_ytd:             data.life_lost_ytd             ?? "",
            life_paid_for_count_ytd:   data.life_paid_for_count_ytd   ?? "",
            life_paid_for_premium_ytd: data.life_paid_for_premium_ytd ?? "",
            ips_new_money_ytd:         data.ips_new_money_ytd         ?? "",
            notes:                     data.notes                     ?? "",
          }));
          setExistingSource(data.source || null);
        } else {
          setExistingSource(null);
        }
      } catch (e) {
        if (!cancelled) console.warn("BookSizeAddForm pre-fill error:", e);
      } finally {
        if (!cancelled) setLoadingExisting(false);
      }
    })();
    return () => { cancelled = true; };
  }, [form.snapshot_date, form.cadence]);

  const save = async () => {
    setSaving(true); setErr(null);
    try {
      const row = {
        agency_id: AGENCY_ID,
        snapshot_date: form.snapshot_date,
        cadence: form.cadence,
        auto_premium:              numOrNull(form.auto_premium),
        fire_premium:              numOrNull(form.fire_premium),
        life_premium:              numOrNull(form.life_premium),
        auto_pif:                  numOrNull(form.auto_pif),
        fire_pif:                  numOrNull(form.fire_pif),
        life_pif:                  numOrNull(form.life_pif),
        household_count:           numOrNull(form.household_count),
        auto_new_ytd:              numOrNull(form.auto_new_ytd),
        auto_lost_ytd:             numOrNull(form.auto_lost_ytd),
        fire_new_ytd:              numOrNull(form.fire_new_ytd),
        fire_lost_ytd:             numOrNull(form.fire_lost_ytd),
        life_new_ytd:              numOrNull(form.life_new_ytd),
        life_lost_ytd:             numOrNull(form.life_lost_ytd),
        life_paid_for_count_ytd:   numOrNull(form.life_paid_for_count_ytd),
        life_paid_for_premium_ytd: numOrNull(form.life_paid_for_premium_ytd),
        ips_new_money_ytd:         numOrNull(form.ips_new_money_ytd),
        source: existingSource && existingSource.startsWith("sf_crm_analytics_email")
          ? "sf_crm_analytics_email_manual_review"
          : "manual_entry_newtworks",
        notes: form.notes || null,
      };
      const { error } = await supabase
        .from("agency_snapshot")
        .upsert(row, { onConflict: "agency_id,snapshot_date,cadence" });
      if (error) throw error;

      // Resolve any open weekly-book-snapshot alert for this Saturday
      if (form.cadence === "weekly") {
        await supabase
          .from("alerts")
          .update({ is_resolved: true, resolved_at: new Date().toISOString() })
          .eq("agency_id", AGENCY_ID)
          .eq("module_reference", `agency_snapshot_weekly_alert:${form.snapshot_date}`)
          .eq("is_resolved", false);
      }

      onAdded?.();
    } catch (e) {
      setErr(e?.message || String(e));
    } finally {
      setSaving(false);
    }
  };

  const inputStyle = { width: "100%", padding: "6px 8px", fontSize: 12, border: `1px solid ${T.slate200}`, borderRadius: 6, background: T.white, color: T.slate900 };
  const labelStyle = { fontSize: 10, color: T.slate500, fontWeight: 500, marginBottom: 3, display: "block" };
  const groupHeaderStyle = { fontSize: 10, color: T.slate600, fontWeight: 700, textTransform: "uppercase", letterSpacing: "0.06em", marginTop: 8, marginBottom: 6 };
  const fld = (key, label, type = "number", placeholder = "") => (
    <div key={key}>
      <label style={labelStyle}>{label}</label>
      <input type={type} value={form[key]} onChange={e => set(key, e.target.value)} placeholder={placeholder} style={inputStyle} />
    </div>
  );

  const isAutoImport = existingSource && existingSource.startsWith("sf_crm_analytics_email");

  return (
    <div>
      {loadingExisting && (
        <div style={{ fontSize: 11, color: T.slate500, marginBottom: 8 }}>Checking for an existing row for this date…</div>
      )}
      {isAutoImport && !loadingExisting && (
        <div style={{ fontSize: 11, color: T.blue, background: T.slate50, border: `1px solid ${T.slate200}`, borderRadius: 6, padding: "8px 10px", marginBottom: 12 }}>
          Auto-imported from the SF CRM Analytics email. Premium and PIF fields are pre-filled. Add YTD new/lost, life paid-for count + premium, and IPS new money from the weekly CPR YTD column, then save.
        </div>
      )}

      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))", gap: 10, marginBottom: 4 }}>
        {fld("snapshot_date", "Date", "date")}
        <div>
          <label style={labelStyle}>Cadence</label>
          <select value={form.cadence} onChange={e => set("cadence", e.target.value)} style={inputStyle}>
            <option value="weekly">Weekly</option>
            <option value="monthly">Monthly</option>
          </select>
        </div>
        {fld("household_count", "Household count")}
      </div>

      <div style={groupHeaderStyle}>Premium ($)</div>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))", gap: 10, marginBottom: 4 }}>
        {fld("auto_premium", "Auto premium")}
        {fld("fire_premium", "Fire premium")}
        {fld("life_premium", "Life premium")}
      </div>

      <div style={groupHeaderStyle}>Policies in force</div>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))", gap: 10, marginBottom: 4 }}>
        {fld("auto_pif", "Auto PIF")}
        {fld("fire_pif", "Fire PIF")}
        {fld("life_pif", "Life PIF")}
      </div>

      <div style={groupHeaderStyle}>YTD new / lost (from CPR YTD column)</div>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))", gap: 10, marginBottom: 4 }}>
        {fld("auto_new_ytd",  "Auto new YTD")}
        {fld("auto_lost_ytd", "Auto lost YTD")}
        {fld("fire_new_ytd",  "Fire new YTD")}
        {fld("fire_lost_ytd", "Fire lost YTD")}
        {fld("life_new_ytd",  "Life new YTD")}
        {fld("life_lost_ytd", "Life lost YTD")}
      </div>

      <div style={groupHeaderStyle}>Life paid-for + IPS (YTD)</div>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))", gap: 10, marginBottom: 4 }}>
        {fld("life_paid_for_count_ytd",   "Life paid-for count YTD")}
        {fld("life_paid_for_premium_ytd", "Life paid-for premium YTD ($)")}
        {fld("ips_new_money_ytd",         "IPS new money YTD ($)")}
      </div>

      <div style={{ marginTop: 10, marginBottom: 12 }}>
        <label style={labelStyle}>Notes (optional)</label>
        <textarea value={form.notes} onChange={e => set("notes", e.target.value)} rows={2}
          style={{ ...inputStyle, fontFamily: "inherit" }}
          placeholder="Source of data, anomalies, step-changes, etc." />
      </div>

      {err && <div style={{ fontSize: 11, color: T.red, marginBottom: 10 }}>Error: {err}</div>}
      <button onClick={save} disabled={saving || !form.snapshot_date}
        style={{ background: T.blue, color: T.white, border: "none", borderRadius: 7, padding: "8px 16px", fontSize: 12, fontWeight: 600, cursor: saving ? "not-allowed" : "pointer", opacity: saving ? 0.6 : 1 }}>
        {saving ? "Saving…" : (existingSource ? "Save changes" : "Add snapshot")}
      </button>
    </div>
  );
};

const BookSnapshotSection = () => {
  const { data, loading, refresh } = useBookData();
  const [showHistory, setShowHistory] = useState(false);
  const [showAdd, setShowAdd] = useState(false);

  const summary = data?.summary;
  const history = Array.isArray(data?.history) ? data.history : [];

  if (loading) {
    return <Card><div style={{ color: T.slate500, fontSize: 12 }}>Loading book snapshot…</div></Card>;
  }
  if (!summary) {
    return (
      <Card>
        <div style={{ color: T.slate500, fontSize: 12, marginBottom: 12 }}>
          No snapshots yet. Add the first weekly entry below.
        </div>
        <BookSizeAddForm onAdded={refresh} />
      </Card>
    );
  }

  const cadence = summary.cadence;
  const isMonthly = cadence !== "weekly";
  const hh = Number(summary.household_count) || 0;
  const perHH = (n) => (hh > 0 && n != null ? (Number(n) / hh).toFixed(2) : null);
  const pifCell = (pif) => {
    if (pif == null) return "—";
    const p = perHH(pif);
    return `${Number(pif).toLocaleString()}${p ? ` · ${p}/HH` : ""}`;
  };

  // View exposes *_wow/mom/qoq/yoy/cum_pct for auto, fire, life, pc, hh.
  const rows = [
    { label: "Households", value: hh > 0 ? hh.toLocaleString() : "—", pif: null,                     prefix: "hh",   hasCum: true },
    { label: "Auto",       value: fmt(summary.auto_premium),          pif: pifCell(summary.auto_pif), prefix: "auto", hasCum: true },
    { label: "Fire",       value: fmt(summary.fire_premium),          pif: pifCell(summary.fire_pif), prefix: "fire", hasCum: true },
    { label: "P&C total",  value: fmt(summary.pc_premium),            pif: null,                     prefix: "pc",   hasCum: true },
    { label: "Life",       value: fmt(summary.life_premium),          pif: pifCell(summary.life_pif), prefix: "life", hasCum: true },
  ];

  const horizons = [
    { id: "wow", label: "WoW",        date: summary.wow_compare_date },
    { id: "mom", label: "MoM",        date: summary.mom_compare_date },
    { id: "qoq", label: "QoQ",        date: summary.qoq_compare_date },
    { id: "yoy", label: "YoY",        date: summary.yoy_compare_date },
    { id: "cum", label: "Since appt", date: summary.anchor_date },
  ];

  const pctValue = (row, h) => {
    if (!row.prefix) return null;
    if (h.id === "wow" && isMonthly) return null;
    if (h.id === "cum" && !row.hasCum) return null;
    return summary[`${row.prefix}_${h.id}_pct`];
  };

  const stickyThFirst = { ...bookThStyle, position: "sticky", left: 0, background: T.slate50, zIndex: 2 };
  const stickyTdFirst = { ...bookTdStyle, position: "sticky", left: 0, background: T.white, zIndex: 1 };

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
      <Card>
        <div style={{ fontSize: 13, fontWeight: 600, color: T.slate800 }}>
          As of {fmtSnapDate(summary.current_snapshot_date)} <span style={{ color: T.slate400, fontWeight: 400 }}>· {cadence}</span>
        </div>
        {isMonthly && (
          <div style={{ fontSize: 11, color: T.slate500, marginTop: 2 }}>
            WoW unavailable for monthly snapshots
          </div>
        )}

        <div style={{ overflowX: "auto", marginTop: 14 }}>
          <table style={{ width: "100%", fontSize: 11, borderCollapse: "collapse", minWidth: 640 }}>
            <thead>
              <tr style={{ background: T.slate50, borderBottom: `1px solid ${T.slate200}` }}>
                <th style={stickyThFirst}>Item</th>
                <th style={{ ...bookThStyle, textAlign: "right" }}>Value</th>
                {horizons.map(h => (
                  <th key={h.id} style={{ ...bookThStyle, textAlign: "right" }}>
                    {h.label}
                    <div style={{ fontSize: 9, fontWeight: 400, color: T.slate400, marginTop: 2, textTransform: "none", letterSpacing: 0 }}>
                      {h.date ? fmtSnapDate(h.date) : "—"}
                    </div>
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {rows.map((row, i) => (
                <tr key={i} style={{ borderBottom: `1px solid ${T.slate100}` }}>
                  <td style={stickyTdFirst}>
                    <div style={{ fontWeight: 600, color: T.slate800 }}>
                      {row.label}
                      {row.pif && (
                        <span style={{ fontWeight: 400, color: T.slate500, marginLeft: 8 }}>{row.pif}</span>
                      )}
                    </div>
                  </td>
                  <td style={{ ...bookTdStyle, textAlign: "right", fontWeight: 600, color: T.slate900 }}>{row.value}</td>
                  {horizons.map(h => {
                    const v = pctValue(row, h);
                    return (
                      <td key={h.id} style={{ ...bookTdStyle, textAlign: "right", color: pctColor(v) }}>
                        {fmtPct(v)}
                      </td>
                    );
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Card>

      <Card>
        <CollapseHeader title={`History (${history.length} snapshots)`} open={showHistory} onToggle={() => setShowHistory(!showHistory)} />
        {showHistory && (
          <div style={{ marginTop: 12, overflowX: "auto" }}>
            <table style={{ width: "100%", fontSize: 11, borderCollapse: "collapse" }}>
              <thead>
                <tr style={{ background: T.slate50, borderBottom: `1px solid ${T.slate200}` }}>
                  <th style={bookThStyle}>Date</th>
                  <th style={bookThStyle}>Cadence</th>
                  <th style={{ ...bookThStyle, textAlign: "right" }}>P&C</th>
                  <th style={{ ...bookThStyle, textAlign: "right" }}>L&H</th>
                  <th style={{ ...bookThStyle, textAlign: "right" }}>HH</th>
                  <th style={{ ...bookThStyle, textAlign: "right" }}>Auto PIF</th>
                  <th style={{ ...bookThStyle, textAlign: "right" }}>Fire PIF</th>
                  <th style={{ ...bookThStyle, textAlign: "right" }}>Life PIF</th>
                </tr>
              </thead>
              <tbody>
                {history.slice(0, 80).map((r, i) => (
                  <tr key={r?.id || i} style={{ borderBottom: `1px solid ${T.slate100}` }}>
                    <td style={bookTdStyle}>{fmtSnapDate(r?.snapshot_date)}</td>
                    <td style={bookTdStyle}>{r?.cadence}</td>
                    <td style={{ ...bookTdStyle, textAlign: "right", fontWeight: 600 }}>{fmt(r?.pc_premium)}</td>
                    <td style={{ ...bookTdStyle, textAlign: "right" }}>{fmt(r?.life_premium)}</td>
                    <td style={{ ...bookTdStyle, textAlign: "right" }}>{r?.household_count ?? "—"}</td>
                    <td style={{ ...bookTdStyle, textAlign: "right" }}>{r?.auto_pif ?? "—"}</td>
                    <td style={{ ...bookTdStyle, textAlign: "right" }}>{r?.fire_pif ?? "—"}</td>
                    <td style={{ ...bookTdStyle, textAlign: "right" }}>{r?.life_pif ?? "—"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            {history.length > 80 && (
              <div style={{ fontSize: 10, color: T.slate400, marginTop: 8, textAlign: "center" }}>
                Showing 80 most recent of {history.length}.
              </div>
            )}
          </div>
        )}
      </Card>

      <Card>
        <CollapseHeader title="Add snapshot manually" open={showAdd} onToggle={() => setShowAdd(!showAdd)} />
        {showAdd && (
          <div style={{ marginTop: 12 }}>
            <BookSizeAddForm onAdded={() => { setShowAdd(false); refresh(); }} />
          </div>
        )}
      </Card>
    </div>
  );
};


// ============================================================
// TAB 2 — Book Growth Goals (reads book_performance_goals)
// ============================================================
// Read-only: goals are managed directly in book_performance_goals.
// Rows are keyed by (agency_id, year, lob, metric). Current values pulled
// from agency_snapshot (latest populated weekly). For PIF metrics, pace
// is calculated from the year-start baseline (first populated snapshot
// of the target year).

const LOB_LABELS = { auto: "Auto", fire: "Fire", life: "Life", health: "Health" };
const LOB_COLORS = { auto: "#3B82F6", fire: "#F59E0B", life: "#8B5CF6", health: "#10B981" };

// Maps (lob, metric) from book_performance_goals to:
//  - label      : card title
//  - fmt        : "money" | "int"
//  - kind       : "delta" (PIF — pace measured from year-start baseline)
//                 "ytd"   (YTD flow — pace measured from zero)
//  - current    : function (snap) => current value from agency_snapshot
//  - baseline   : function (snap0) => year-start value (only used for kind='delta')
const METRIC_MAP = {
  "auto:pif":           { label: "Auto PIF",      fmt: "int",   kind: "delta", current: s => s?.auto_pif, baseline: s => s?.auto_pif },
  "fire:pif":           { label: "Fire PIF",      fmt: "int",   kind: "delta", current: s => s?.fire_pif, baseline: s => s?.fire_pif },
  "life:pif":           { label: "Life PIF",      fmt: "int",   kind: "delta", current: s => s?.life_pif, baseline: s => s?.life_pif },
  "auto:gain":          { label: "Auto Gain",     fmt: "int",   kind: "ytd",   current: s => (Number(s?.auto_new_ytd)||0) - (Number(s?.auto_lost_ytd)||0) },
  "fire:gain":          { label: "Fire Gain",     fmt: "int",   kind: "ytd",   current: s => (Number(s?.fire_new_ytd)||0) - (Number(s?.fire_lost_ytd)||0) },
  "life:gain":          { label: "Life Gain",     fmt: "int",   kind: "ytd",   current: s => (Number(s?.life_new_ytd)||0) - (Number(s?.life_lost_ytd)||0) },
  "life:net_paid_for":  { label: "Life Paid #",   fmt: "int",   kind: "ytd",   current: s => s?.life_paid_for_count_ytd },
  "life:premium":       { label: "Life Premium",  fmt: "money", kind: "ytd",   current: s => s?.life_paid_for_premium_ytd },
};

const goalsFmt = (v, fmt) => {
  if (v === null || v === undefined || !Number.isFinite(Number(v))) return "—";
  const n = Number(v);
  if (fmt === "money") return "$" + Math.round(n).toLocaleString("en-US");
  return Math.round(n).toLocaleString("en-US");
};

const elapsedFraction = (year) => {
  const now = new Date();
  const start = new Date(year, 0, 1);
  const end = new Date(year + 1, 0, 1);
  const clamped = Math.max(0, Math.min(end - start, now - start));
  return clamped / (end - start);
};

const paceColor = (paceFrac, elapsedFrac) => {
  if (paceFrac == null || elapsedFrac == null) return T.slate500;
  if (paceFrac >= elapsedFrac) return T.green;
  if (paceFrac >= elapsedFrac - 0.05) return T.amber;
  return T.red;
};

const paceLabel = (paceFrac, elapsedFrac) => {
  if (paceFrac == null || elapsedFrac == null) return "no target";
  const diff = paceFrac - elapsedFrac;
  if (diff >= 0.02) return "ahead";
  if (diff >= -0.02) return "on pace";
  if (diff >= -0.05) return "slightly behind";
  return "behind";
};

function useBookGoalsData(year) {
  const [state, setState] = useState({ goals: [], latest: null, yearStart: null, loading: true });
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        // Goals for the year
        const { data: goals } = await supabase
          .from("book_performance_goals")
          .select("lob, metric, target_value, notes")
          .eq("agency_id", AGENCY_ID)
          .eq("year", year);

        // Latest populated weekly snapshot
        const { data: snaps } = await supabase
          .from("agency_snapshot")
          .select("*")
          .eq("agency_id", AGENCY_ID)
          .eq("cadence", "weekly")
          .order("snapshot_date", { ascending: false })
          .limit(10);
        const isPopulated = (r) => r && (
          r.auto_premium != null || r.fire_premium != null || r.life_premium != null ||
          r.auto_pif != null || r.fire_pif != null || r.life_pif != null ||
          r.household_count != null
        );
        const latest = (Array.isArray(snaps) ? snaps : []).find(isPopulated) || null;

        // Year-start baseline: earliest 2026 snapshot with populated PIFs
        const { data: startRows } = await supabase
          .from("agency_snapshot")
          .select("snapshot_date, auto_pif, fire_pif, life_pif")
          .eq("agency_id", AGENCY_ID)
          .gte("snapshot_date", `${year}-01-01`)
          .lte("snapshot_date", `${year}-12-31`)
          .order("snapshot_date", { ascending: true })
          .limit(5);
        const yearStart = (Array.isArray(startRows) ? startRows : [])
          .find(r => r.auto_pif != null || r.fire_pif != null || r.life_pif != null) || null;

        if (!cancelled) setState({ goals: goals || [], latest, yearStart, loading: false });
      } catch (e) {
        console.error("useBookGoalsData failed:", e);
        if (!cancelled) setState(s => ({ ...s, loading: false }));
      }
    })();
    return () => { cancelled = true; };
  }, [year]);
  return state;
}

const BookGoalsSection = () => {
  const now = new Date();
  const [year, setYear] = useState(now.getFullYear());
  const { goals, latest, yearStart, loading } = useBookGoalsData(year);

  const elapsed = elapsedFraction(year);
  const totalWeeks = 52;
  const weeksRemaining = Math.max(0, Math.round(totalWeeks - (elapsed * totalWeeks)));

  if (loading) return <Card><div style={{ color: T.slate500, fontSize: 12 }}>Loading growth goals…</div></Card>;

  if (!goals || goals.length === 0) {
    return (
      <Card>
        <div style={{ fontSize: 12, color: T.slate500 }}>
          No goals set for {year} in <code style={{ fontSize: 11 }}>book_performance_goals</code>.
        </div>
      </Card>
    );
  }

  // Order goals deterministically
  const ORDER = ["auto:pif","fire:pif","life:pif","auto:gain","fire:gain","life:gain","life:net_paid_for","life:premium"];
  const sortedGoals = [...goals].sort((a, b) => {
    const ai = ORDER.indexOf(`${a.lob}:${a.metric}`); const bi = ORDER.indexOf(`${b.lob}:${b.metric}`);
    return (ai === -1 ? 99 : ai) - (bi === -1 ? 99 : bi);
  });

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
      <Card>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 8, flexWrap: "wrap" }}>
          <div>
            <div style={{ fontSize: 13, fontWeight: 600, color: T.slate800 }}>Growth Goals · {year}</div>
            <div style={{ fontSize: 11, color: T.slate500, marginTop: 2 }}>
              {(elapsed * 100).toFixed(1)}% through the year · ~{weeksRemaining} weeks remaining
              {latest?.snapshot_date ? ` · current as of ${latest.snapshot_date}` : ""}
              {yearStart?.snapshot_date ? ` · baseline ${yearStart.snapshot_date}` : ""}
            </div>
          </div>
          <select value={year} onChange={e => setYear(Number(e.target.value))}
            style={{ padding: "6px 10px", fontSize: 12, border: `1px solid ${T.slate200}`, borderRadius: 6, background: T.white, color: T.slate900 }}>
            {[now.getFullYear() - 1, now.getFullYear(), now.getFullYear() + 1].map(y =>
              <option key={y} value={y}>{y}</option>
            )}
          </select>
        </div>
      </Card>

      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(220px, 1fr))", gap: 10 }}>
        {sortedGoals.map(g => {
          const key = `${g.lob}:${g.metric}`;
          const m = METRIC_MAP[key];
          const targetVal = Number(g.target_value);
          if (!m || !Number.isFinite(targetVal)) {
            return (
              <Card key={key} style={{ padding: "14px 16px" }}>
                <div style={{ fontSize: 11, color: T.slate500, fontWeight: 500, marginBottom: 6 }}>
                  {(LOB_LABELS[g.lob] || g.lob)} · {g.metric}
                </div>
                <div style={{ fontSize: 18, fontWeight: 700, color: T.slate900 }}>{goalsFmt(targetVal, "int")}</div>
                <div style={{ fontSize: 10, color: T.slate400, marginTop: 4 }}>No mapping — raw target only</div>
              </Card>
            );
          }

          const currentVal = m.current(latest);
          let paceFrac = null;
          let deltaCurrent = null;
          let deltaTarget = null;

          if (m.kind === "delta") {
            const startVal = m.baseline(yearStart);
            if (startVal != null && Number.isFinite(Number(startVal)) && currentVal != null) {
              deltaCurrent = Number(currentVal) - Number(startVal);
              deltaTarget = targetVal - Number(startVal);
              if (deltaTarget > 0) paceFrac = deltaCurrent / deltaTarget;
            }
          } else {
            if (currentVal != null && targetVal > 0) paceFrac = Number(currentVal) / targetVal;
          }

          const color = paceColor(paceFrac, elapsed);
          const label = paceLabel(paceFrac, elapsed);
          const pct = paceFrac != null ? Math.min(1.5, paceFrac) : 0;
          const lobColor = LOB_COLORS[g.lob] || T.slate500;
          const projectedYE = (m.kind === "ytd" && currentVal != null && elapsed > 0) ? Number(currentVal) / elapsed : null;
          const nextYearPrep = /prep for next year|does not drive this year/i.test(g.notes || "");

          return (
            <Card key={key} style={{ padding: "14px 16px", borderTop: `3px solid ${lobColor}`, opacity: nextYearPrep ? 0.7 : 1 }}>
              <div style={{ fontSize: 11, color: T.slate500, fontWeight: 500, marginBottom: 6 }}>{m.label}</div>
              <div style={{ fontSize: 22, fontWeight: 700, color: T.slate900, letterSpacing: "-0.02em", lineHeight: 1.1 }}>
                {goalsFmt(currentVal, m.fmt)}
              </div>
              <div style={{ fontSize: 11, color: T.slate500, marginTop: 3 }}>
                {m.kind === "delta"
                  ? `+${goalsFmt(deltaCurrent, "int")} of +${goalsFmt(deltaTarget, "int")} target · ends at ${goalsFmt(targetVal, "int")}`
                  : `of ${goalsFmt(targetVal, m.fmt)} target`}
              </div>
              <div style={{ marginTop: 8, height: 6, background: T.slate100, borderRadius: 3, overflow: "hidden" }}>
                <div style={{ width: `${Math.min(100, pct * 100)}%`, height: "100%", background: color, transition: "width 0.3s" }} />
              </div>
              <div style={{ display: "flex", justifyContent: "space-between", marginTop: 6, fontSize: 11 }}>
                <span style={{ color, fontWeight: 600 }}>{label}</span>
                <span style={{ color: T.slate500 }}>{paceFrac != null ? `${(paceFrac * 100).toFixed(1)}%` : "—"}</span>
              </div>
              {m.kind === "ytd" && projectedYE != null && (
                <div style={{ fontSize: 10, color: T.slate400, marginTop: 6, paddingTop: 6, borderTop: `1px solid ${T.slate100}` }}>
                  Projected YE: <span style={{ color: T.slate600, fontWeight: 600 }}>{goalsFmt(projectedYE, m.fmt)}</span>
                  {" · "}
                  <span style={{ color: projectedYE >= targetVal ? T.green : T.red }}>
                    {projectedYE >= targetVal ? "+" : ""}{goalsFmt(projectedYE - targetVal, m.fmt)}
                  </span>
                </div>
              )}
              {nextYearPrep && (
                <div style={{ fontSize: 10, color: T.slate400, marginTop: 6, fontStyle: "italic" }}>
                  Prep for next year — does not drive this year
                </div>
              )}
            </Card>
          );
        })}
      </div>
    </div>
  );
};

// ============================================================
// TAB 3 — Book Assignments (alphabet split)
// ============================================================

// ─── Book Assignments Section ────────────────────────────────
// Who owns which letters of the alphabet, and how many households sit under
// each one. One live answer, not a history of snapshots — edit it in place.
// Reads and writes book_alpha through rp_book_alpha / rp_book_alpha_save.

// One place that turns a failed call into something readable.
const alphaError = (e) => (e && (e.message || e.error || e.hint)) || "Something went wrong. Try again.";

const bookInputStyle = { padding:"5px 8px", fontSize:12, border:`1px solid ${T.slate200}`, borderRadius:6, background:T.white, color:T.slate800 };
const bookBtnPrimary = { padding:"7px 14px", fontSize:12, fontWeight:600, color:T.white, background:T.blue, border:"none", borderRadius:7, cursor:"pointer" };
const bookBtnSecondary = { padding:"7px 14px", fontSize:12, fontWeight:600, color:T.slate700, background:T.white, border:`1px solid ${T.slate200}`, borderRadius:7, cursor:"pointer" };

const BookAssignmentsSection = () => {
  const [letters, setLetters] = useState([]);     // [{letter, team_member_id, household_count}]
  const [teamList, setTeamList] = useState([]);   // who a letter can be given to
  const [canEdit, setCanEdit] = useState(false);
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  const load = async () => {
    setLoading(true); setError(null);
    const [alpha, team] = await Promise.all([
      supabase.rpc("rp_book_alpha"),
      supabase.from("team").select("id, first_name, last_name, nickname, is_active, archived_at, is_admin_backoffice")
        .eq("agency_id", AGENCY_ID).order("first_name"),
    ]);
    if (alpha.error || !alpha.data?.ok) { setError(alphaError(alpha.error || alpha.data)); setLoading(false); return; }
    // Flatten the grid back to one row per letter — that is what we edit and save.
    const flat = [];
    for (const p of alpha.data.people || []) {
      for (const l of p.letters || []) flat.push({ letter: l.letter, team_member_id: p.team_member_id, household_count: l.household_count });
    }
    for (const l of alpha.data.unassigned || []) flat.push({ letter: l.letter, team_member_id: null, household_count: l.household_count });
    flat.sort((a, b) => a.letter.localeCompare(b.letter));
    setLetters(flat);
    setCanEdit(!!alpha.data.can_edit);
    const roster = Array.isArray(team.data) ? team.data : [];
    setTeamList(roster.filter(t => t.is_active && !t.archived_at && !t.is_admin_backoffice));
    setLoading(false);
  };

  useEffect(() => { load(); }, []);

  const rows = editing ? draft : letters;

  // One column per person who holds letters, plus anything nobody owns yet.
  const columns = useMemo(() => {
    const byPerson = new Map();
    const loose = [];
    for (const r of rows) {
      if (!r.team_member_id) { loose.push(r); continue; }
      if (!byPerson.has(r.team_member_id)) byPerson.set(r.team_member_id, []);
      byPerson.get(r.team_member_id).push(r);
    }
    const nameOf = (id) => {
      const m = teamList.find(t => t.id === id);
      if (!m) return "Former teammate";
      return m.nickname || m.first_name;
    };
    const out = [...byPerson.entries()]
      .map(([id, ls]) => ({
        team_member_id: id,
        name: nameOf(id),
        letters: ls,
        total: ls.reduce((s, l) => s + (Number(l.household_count) || 0), 0),
      }))
      .sort((a, b) => a.name.localeCompare(b.name));
    if (loose.length) {
      out.push({ team_member_id: null, name: "Nobody yet", letters: loose,
                 total: loose.reduce((s, l) => s + (Number(l.household_count) || 0), 0) });
    }
    return out;
  }, [rows, teamList]);

  const startEdit = () => { setDraft(letters.map(r => ({ ...r }))); setEditing(true); };
  const cancelEdit = () => { setDraft([]); setEditing(false); setError(null); };
  const setLetter = (letter, field, value) =>
    setDraft(d => d.map(r => r.letter === letter ? { ...r, [field]: value } : r));

  const save = async () => {
    setSaving(true); setError(null);
    const r = await supabase.rpc("rp_book_alpha_save", {
      p_rows: draft.map(x => ({
        letter: x.letter,
        team_member_id: x.team_member_id || null,
        household_count: String(Number(x.household_count) || 0),
      })),
    });
    setSaving(false);
    if (r.error || !r.data?.ok) { setError(alphaError(r.error || r.data)); return; }
    setEditing(false); setDraft([]);
    await load();
  };

  if (loading) return <Card><div style={{ color:T.slate500, fontSize:12 }}>Loading the alphabet split…</div></Card>;

  const grandTotal = columns.reduce((s, c) => s + c.total, 0);

  return (
    <div style={{ display:"grid", gap:12 }}>
      <div style={{ display:"flex", alignItems:"center", justifyContent:"space-between", flexWrap:"wrap", gap:10 }}>
        <div style={{ fontSize:12, color:T.slate500 }}>
          {grandTotal.toLocaleString()} households across {rows.length} letters.
        </div>
        {canEdit && (editing ? (
          <div style={{ display:"flex", gap:8 }}>
            <button style={bookBtnSecondary} onClick={cancelEdit} disabled={saving}>Cancel</button>
            <button style={bookBtnPrimary} onClick={save} disabled={saving}>{saving ? "Saving…" : "Save"}</button>
          </div>
        ) : (
          <button style={bookBtnSecondary} onClick={startEdit}>Edit</button>
        ))}
      </div>

      {error && <Card><div style={{ color:T.red, fontSize:12 }}>{error}</div></Card>}

      <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit, minmax(210px, 1fr))", gap:12, alignItems:"start" }}>
        {columns.map(col => (
          <Card key={col.team_member_id || "none"} style={{ padding:"12px 14px" }}>
            <div style={{ display:"flex", alignItems:"baseline", justifyContent:"space-between", gap:8, marginBottom:8 }}>
              <div style={{ fontSize:14, fontWeight:700, color:T.slate900 }}>{col.name}</div>
              <div style={{ fontSize:13, fontWeight:600, color:T.slate700 }}>{col.total.toLocaleString()}</div>
            </div>
            <div style={{ display:"grid", gap:4 }}>
              {col.letters.map(l => (
                <div key={l.letter} style={{ display:"flex", alignItems:"center", justifyContent:"space-between", gap:8,
                                             padding:"3px 0", borderTop:`1px solid ${T.slate100}` }}>
                  <div style={{ fontSize:13, fontWeight:600, color:T.slate800, minWidth:34 }}>{l.letter}</div>
                  {editing ? (
                    <div style={{ display:"flex", gap:6, alignItems:"center" }}>
                      <select value={l.team_member_id || ""} onChange={e => setLetter(l.letter, "team_member_id", e.target.value || null)}
                              style={{ ...bookInputStyle, maxWidth:110 }}>
                        <option value="">Nobody</option>
                        {teamList.map(t => <option key={t.id} value={t.id}>{t.nickname || t.first_name}</option>)}
                      </select>
                      <input type="number" min="0" value={l.household_count ?? 0}
                             onChange={e => setLetter(l.letter, "household_count", e.target.value)}
                             style={{ ...bookInputStyle, width:64, textAlign:"right" }} />
                    </div>
                  ) : (
                    <div style={{ fontSize:13, color:T.slate700 }}>{Number(l.household_count || 0).toLocaleString()}</div>
                  )}
                </div>
              ))}
            </div>
          </Card>
        ))}
      </div>
    </div>
  );
};

// ─── Section: Retention Budget ───────────────────────────────

// ─── Growth Budget Section ───────────────────────────────────
// Per-ramping-teammate breakdown + agency summary + forecasting UI.
// Reads: v_growth_budget_current, v_growth_budget_ytd,
//        get_growth_budget_ceiling RPC, get_growth_budget_forecast RPC.
// See op-rule "New team integration + Growth budget" for canonical mechanics.
// ─── Growth Budget Header ─────────────────────────────────────
// Compressed persistent strip: "Growth Budget · $YTD / $Ceiling · [bar] · % · [▾ Ramping (n)]"
// Ramping expands inline (one line per teammate). Always visible in the Growth tab.


export default function Book() {
  const [tab, setTab, tabHref] = useTabParam("tab", "snapshot", ["snapshot","goals","assignments"]);

  const tabs = [
    { id: "snapshot",    label: "Snapshot" },
    { id: "goals",       label: "Goals" },
    { id: "assignments", label: "Assignments" },
  ];

  const subtitle =
    tab === "snapshot"    ? "Agency-level book size + growth across every horizon" :
    tab === "goals"       ? "Year-end targets and YTD pace" :
    tab === "assignments" ? "Household alphabet split across the team" :
    "";

  return (
    <div>
      {/* Module Header */}
      <div style={{ display:"flex", alignItems:"flex-start", justifyContent:"space-between", marginBottom:16, flexWrap:"wrap", gap:10 }}>
        <div>
          <div style={{ fontSize:20, fontWeight:700, color:T.slate900, letterSpacing:"-0.02em" }}>Book</div>
          <div style={{ fontSize:12, color:T.slate500, marginTop:3 }}>{subtitle}</div>
        </div>
      </div>

      <TabBar tabs={tabs} active={tab} onChange={setTab} hrefFor={tabHref} />

      {tab === "snapshot" && <BookSnapshotSection />}
      {tab === "goals" && <BookGoalsSection />}
      {tab === "assignments" && <BookAssignmentsSection />}
    </div>
  );
}
