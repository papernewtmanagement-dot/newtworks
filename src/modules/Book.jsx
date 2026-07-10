import { useState, useEffect, useMemo } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";


// ============================================================
// Newtworks BOOK MODULE
// Newtworks — State Farm Agent Edition
//
// Two tabs:
//   • Size — agency-level snapshots (premium, PIFs, households)
//            with WoW/MoM/QoQ/YoY/since-appt comparisons.
//            Reads: v_agency_growth_summary, v_agency_snapshot_with_changes.
//   • Assignments — alphabet split of household service
//                   assignments across the team. Snapshot-per-date.
//                   Reads: book_alpha_split, team.
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

const TabBar = ({ tabs, active, onChange }) => (
  <div style={{
    display: "flex", gap: 2,
    background: T.slate100,
    borderRadius: 8, padding: 3,
    marginBottom: 16,
    flexWrap: "wrap",
  }}>
    {tabs.map(t => (
      <button key={t.id} onClick={() => onChange(t.id)} style={{
        padding: "6px 14px", fontSize: 12, fontWeight: active === t.id ? 600 : 400,
        color: active === t.id ? T.slate900 : T.slate500,
        background: active === t.id ? T.white : "transparent",
        border: "none", borderRadius: 6, cursor: "pointer",
        transition: "all 0.12s",
        boxShadow: active === t.id ? "0 1px 3px rgba(0,0,0,0.08)" : "none",
      }}>{t.label}</button>
    ))}
  </div>
);

const fmt = (n) => {
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  if (v === 0) return "—";
  return "$" + v.toLocaleString("en-US", { minimumFractionDigits: 0 });
};

// ============================================================
// TAB 1 — Book Size (agency growth over time)
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

const BookSizeSection = () => {
  const { data, loading, refresh } = useBookData();
  const [horizon, setHorizon] = useState("mom");
  const [showLOB, setShowLOB] = useState(true);
  const [showHistory, setShowHistory] = useState(false);
  const [showAdd, setShowAdd] = useState(false);

  const summary = data?.summary;
  const history = Array.isArray(data?.history) ? data.history : [];

  const horizonLabel = { wow: "vs last wk", mom: "vs last mo", qoq: "vs last qtr", yoy: "YoY", cum: "since appt" }[horizon];
  const horizonDate = summary ? {
    wow: summary.wow_compare_date, mom: summary.mom_compare_date,
    qoq: summary.qoq_compare_date, yoy: summary.yoy_compare_date,
    cum: summary.anchor_date,
  }[horizon] : null;
  const getPct = (lob) => {
    if (!summary) return null;
    return summary[`${lob}_${horizon}_pct`];
  };

  if (loading) {
    return <Card><div style={{ color: T.slate500, fontSize: 12 }}>Loading book size…</div></Card>;
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

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
      <Card>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", marginBottom: 14, gap: 8, flexWrap: "wrap" }}>
          <div>
            <div style={{ fontSize: 13, fontWeight: 600, color: T.slate800 }}>
              As of {fmtSnapDate(summary.current_snapshot_date)} <span style={{ color: T.slate400, fontWeight: 400 }}>· {summary.cadence}</span>
            </div>
            <div style={{ fontSize: 11, color: T.slate500, marginTop: 2 }}>
              {horizon === "wow" && summary.cadence !== "weekly"
                ? "WoW unavailable for monthly snapshots"
                : `Comparing ${horizonLabel} (${horizonDate ? fmtSnapDate(horizonDate) : "—"})`}
            </div>
          </div>
          <div style={{ display: "flex", flexWrap: "wrap", gap: 2, background: T.slate100, borderRadius: 8, padding: 3 }}>
            {[
              { id: "wow", label: "WoW" },
              { id: "mom", label: "MoM" },
              { id: "qoq", label: "QoQ" },
              { id: "yoy", label: "YoY" },
              { id: "cum", label: "Since appt" },
            ].map(h => (
              <button key={h.id} onClick={() => setHorizon(h.id)} style={{
                padding: "6px 12px", fontSize: 11,
                fontWeight: horizon === h.id ? 600 : 400,
                color: horizon === h.id ? T.slate900 : T.slate500,
                background: horizon === h.id ? T.white : "transparent",
                border: "none", borderRadius: 6, cursor: "pointer",
                boxShadow: horizon === h.id ? "0 1px 3px rgba(0,0,0,0.08)" : "none",
              }}>{h.label}</button>
            ))}
          </div>
        </div>

        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))", gap: 10 }}>
          <KPICard label="P&C Premium" value={fmt(summary.pc_premium)}
            sub={<span style={{ color: pctColor(getPct("pc")) }}>{fmtPct(getPct("pc"))} {horizonLabel}</span>}
            border={T.blue} />
          <KPICard label="Life Premium" value={fmt(summary.life_premium)}
            sub={<span style={{ color: pctColor(getPct("lh")) }}>{fmtPct(getPct("lh"))} {horizonLabel}</span>}
            border={T.purple} />
          <KPICard label="Households" value={summary.household_count ?? "—"}
            sub={<span style={{ color: pctColor(getPct("hh")) }}>{fmtPct(getPct("hh"))} {horizonLabel}</span>}
            border={T.green} />
          <KPICard label="Auto / HH"
            value={summary.household_count > 0 && summary.auto_pif != null
              ? (summary.auto_pif / summary.household_count).toFixed(2) : "—"}
            sub="Policies per household" border={T.amber} />
        </div>
      </Card>

      <Card>
        <CollapseHeader title="Line-of-business detail" open={showLOB} onToggle={() => setShowLOB(!showLOB)} />
        {showLOB && (
          <div style={{ marginTop: 12, display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(150px, 1fr))", gap: 10 }}>
            {[
              { key: "auto",   label: "Auto",   color: T.blue },
              { key: "fire",   label: "Fire",   color: T.amber },
              { key: "life",   label: "Life",   color: T.purple },
              { key: "health", label: "Health", color: T.green },
            ].map(lob => (
              <div key={lob.key} style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 10, borderTop: `3px solid ${lob.color}`, padding: 14 }}>
                <div style={{ fontSize: 12, fontWeight: 600, color: T.slate700, marginBottom: 8 }}>{lob.label}</div>
                <div style={{ fontSize: 20, fontWeight: 700, color: T.slate900, letterSpacing: "-0.02em" }}>
                  {fmt(summary[`${lob.key}_premium`])}
                </div>
                <div style={{ fontSize: 11, color: pctColor(getPct(lob.key)), marginTop: 4 }}>
                  {fmtPct(getPct(lob.key))} {horizonLabel}
                </div>
                <div style={{ fontSize: 11, color: T.slate400, marginTop: 10, paddingTop: 10, borderTop: `1px solid ${T.slate100}` }}>
                  PIF: <span style={{ color: T.slate700, fontWeight: 600 }}>{summary[`${lob.key}_pif`] ?? "—"}</span>
                  {summary.household_count > 0 && summary[`${lob.key}_pif`] != null && (
                    <span style={{ marginLeft: 6 }}>
                      ({(summary[`${lob.key}_pif`] / summary.household_count).toFixed(2)}/HH)
                    </span>
                  )}
                </div>
              </div>
            ))}
          </div>
        )}
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

const CANONICAL_BUCKETS = ["A","B","C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X-Z"];

// ─── Book Assignments Section ────────────────────────────────
// Snapshot-based alphabet split for service-book assignment.
// One row per (snapshot_date, letter_bucket) in book_alpha_split.
const producerLabel = (m) => {
  if (!m) return "Unassigned";
  const nick = m.nickname || m.first_name || "";
  return (nick + " " + (m.last_name || "")).trim();
};

// Shared styles for editor + buttons (defined once near component)
const bookInputStyle = { padding:"5px 8px", fontSize:12, border:`1px solid ${T.slate200}`, borderRadius:6, background:T.white, color:T.slate800 };
const bookBtnPrimary = { padding:"7px 14px", fontSize:12, fontWeight:600, color:T.white, background:T.blue, border:"none", borderRadius:7, cursor:"pointer" };
const bookBtnSecondary = { padding:"7px 14px", fontSize:12, fontWeight:600, color:T.slate700, background:T.white, border:`1px solid ${T.slate200}`, borderRadius:7, cursor:"pointer" };
const bookBtnDanger = { padding:"6px 12px", fontSize:11, fontWeight:600, color:T.red, background:T.white, border:`1px solid ${T.redLt}`, borderRadius:7, cursor:"pointer" };

const BucketEditor = ({ buckets, draft, setDraft, teamList }) => {
  const update = (bucket, field, value) => {
    setDraft(prev => ({ ...prev, [bucket]: { ...(prev[bucket] || {}), [field]: value } }));
  };
  return (
    <Card>
      <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fill, minmax(240px, 1fr))", gap:8 }}>
        {(buckets || []).map(b => {
          const v = draft?.[b] || { team_member_id: null, account_count: 0 };
          return (
            <div key={b} style={{ border:`1px solid ${T.slate200}`, borderRadius:8, padding:"8px 10px" }}>
              <div style={{ fontSize:12, fontWeight:700, color:T.slate900, marginBottom:6 }}>{b}</div>
              <select
                value={v.team_member_id || ""}
                onChange={e => update(b, "team_member_id", e.target.value || null)}
                style={{ ...bookInputStyle, width:"100%", marginBottom:6 }}
              >
                <option value="">— Unassigned —</option>
                {(teamList || []).map(t => (
                  <option key={t.id} value={t.id}>{producerLabel(t)}</option>
                ))}
              </select>
              <input
                type="number"
                min="0"
                value={v.account_count ?? 0}
                onChange={e => update(b, "account_count", e.target.value)}
                style={{ ...bookInputStyle, width:"100%" }}
              />
            </div>
          );
        })}
      </div>
    </Card>
  );
};

const BookAssignmentsSection = () => {
  const [allRows, setAllRows] = useState([]);
  const [teamList, setTeamList] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [selectedDate, setSelectedDate] = useState(null);
  const [editing, setEditing] = useState(false);
  const [adding, setAdding] = useState(false);
  const [draft, setDraft] = useState({});
  const [newDate, setNewDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [saving, setSaving] = useState(false);

  const load = async () => {
    if (!supabase || !AGENCY_ID) { setLoading(false); return; }
    setLoading(true);
    setError(null);
    const [rowsRes, teamRes] = await Promise.all([
      supabase
        .from("book_alpha_split")
        .select("id, snapshot_date, letter_bucket, team_member_id, account_count, notes")
        .eq("agency_id", AGENCY_ID)
        .order("snapshot_date", { ascending: false }),
      supabase
        .from("team")
        .select("id, first_name, last_name, nickname")
        .eq("agency_id", AGENCY_ID)
        .eq("is_active", true)
        .eq("is_admin_backoffice", false)
        .order("last_name"),
    ]);
    if (rowsRes?.error || teamRes?.error) {
      setError(rowsRes?.error?.message || teamRes?.error?.message);
      setLoading(false);
      return;
    }
    const rows = Array.isArray(rowsRes?.data) ? rowsRes.data : [];
    const team = Array.isArray(teamRes?.data) ? teamRes.data : [];
    setAllRows(rows);
    setTeamList(team);
    setSelectedDate(prev => prev || (rows.length ? rows[0].snapshot_date : null));
    setLoading(false);
  };

  useEffect(() => { load(); }, []);

  const allDates = useMemo(() => {
    const set = new Set((allRows || []).map(r => r.snapshot_date));
    return Array.from(set).sort().reverse();
  }, [allRows]);

  const currentRows = useMemo(() => {
    if (!selectedDate) return [];
    return (allRows || []).filter(r => r.snapshot_date === selectedDate);
  }, [allRows, selectedDate]);

  const allBuckets = useMemo(() => {
    const extra = (currentRows || [])
      .map(r => r.letter_bucket)
      .filter(b => !CANONICAL_BUCKETS.includes(b));
    return [...CANONICAL_BUCKETS, ...Array.from(new Set(extra))];
  }, [currentRows]);

  const priorDate = useMemo(() => {
    const i = allDates.indexOf(selectedDate);
    return i >= 0 && i < allDates.length - 1 ? allDates[i + 1] : null;
  }, [allDates, selectedDate]);

  const priorRows = useMemo(() => {
    if (!priorDate) return [];
    return (allRows || []).filter(r => r.snapshot_date === priorDate);
  }, [allRows, priorDate]);

  const findRow = (rows, bucket) => (rows || []).find(r => r.letter_bucket === bucket);
  const memberById = (id) => (teamList || []).find(t => t.id === id);

  const rollup = useMemo(() => {
    const map = new Map();
    (currentRows || []).forEach(r => {
      const key = r.team_member_id || "_unassigned";
      const cur = map.get(key) || { team_member_id: r.team_member_id, total: 0, letters: [] };
      cur.total += Number(r.account_count) || 0;
      cur.letters.push(r.letter_bucket);
      map.set(key, cur);
    });
    return Array.from(map.values()).sort((a, b) => b.total - a.total);
  }, [currentRows]);

  const grandTotal = useMemo(() => rollup.reduce((s, r) => s + r.total, 0), [rollup]);

  const buildDraftFromRows = (rows) => {
    const d = {};
    allBuckets.forEach(b => {
      const r = findRow(rows, b);
      d[b] = { team_member_id: r?.team_member_id || null, account_count: r?.account_count ?? 0 };
    });
    return d;
  };

  const startEdit = () => { setDraft(buildDraftFromRows(currentRows)); setEditing(true); };
  const cancelEdit = () => { setEditing(false); setDraft({}); };

  const saveEdit = async () => {
    setSaving(true);
    const upserts = Object.entries(draft).map(([bucket, v]) => ({
      agency_id: AGENCY_ID,
      snapshot_date: selectedDate,
      letter_bucket: bucket,
      team_member_id: v.team_member_id || null,
      account_count: Number(v.account_count) || 0,
    }));
    const { error: upErr } = await supabase
      .from("book_alpha_split")
      .upsert(upserts, { onConflict: "agency_id,snapshot_date,letter_bucket" });
    setSaving(false);
    if (upErr) { setError(upErr.message); return; }
    setEditing(false);
    setDraft({});
    await load();
  };

  const startAdd = () => {
    setDraft(buildDraftFromRows(currentRows));
    setNewDate(new Date().toISOString().slice(0, 10));
    setAdding(true);
  };
  const cancelAdd = () => { setAdding(false); setDraft({}); };

  const saveAdd = async () => {
    if (!newDate) return;
    setSaving(true);
    const upserts = Object.entries(draft).map(([bucket, v]) => ({
      agency_id: AGENCY_ID,
      snapshot_date: newDate,
      letter_bucket: bucket,
      team_member_id: v.team_member_id || null,
      account_count: Number(v.account_count) || 0,
    }));
    const { error: upErr } = await supabase
      .from("book_alpha_split")
      .upsert(upserts, { onConflict: "agency_id,snapshot_date,letter_bucket" });
    setSaving(false);
    if (upErr) { setError(upErr.message); return; }
    setAdding(false);
    setDraft({});
    setSelectedDate(newDate);
    await load();
  };

  const deleteSnapshot = async () => {
    if (!selectedDate) return;
    if (!window.confirm(`Delete the ${selectedDate} snapshot entirely? This cannot be undone.`)) return;
    setSaving(true);
    const { error: delErr } = await supabase
      .from("book_alpha_split")
      .delete()
      .eq("agency_id", AGENCY_ID)
      .eq("snapshot_date", selectedDate);
    setSaving(false);
    if (delErr) { setError(delErr.message); return; }
    setSelectedDate(null);
    await load();
  };

  if (loading) return <Card><div style={{ color:T.slate500, fontSize:13 }}>Loading book assignments…</div></Card>;

  if ((allRows || []).length === 0 && !adding) {
    return (
      <Card>
        <div style={{ fontSize:14, fontWeight:600, color:T.slate800, marginBottom:8 }}>No book snapshots yet</div>
        <div style={{ fontSize:12, color:T.slate500, marginBottom:14 }}>
          Capture your first alphabet split — which producer services which letters of the alphabet.
        </div>
        <button onClick={startAdd} style={bookBtnPrimary}>Add first snapshot</button>
      </Card>
    );
  }

  if (adding) {
    return (
      <div>
        <Card style={{ marginBottom:12 }}>
          <div style={{ display:"flex", flexWrap:"wrap", gap:10, alignItems:"center", justifyContent:"space-between" }}>
            <div>
              <div style={{ fontSize:14, fontWeight:600, color:T.slate800 }}>New Book Snapshot</div>
              <div style={{ fontSize:11, color:T.slate500 }}>
                Pre-filled from {selectedDate || "blank"} · adjust producers or counts as needed
              </div>
            </div>
            <div style={{ display:"flex", gap:8, alignItems:"center" }}>
              <label style={{ fontSize:11, color:T.slate500 }}>Date</label>
              <input type="date" value={newDate} onChange={e => setNewDate(e.target.value)} style={bookInputStyle} />
              <button onClick={cancelAdd} style={bookBtnSecondary} disabled={saving}>Cancel</button>
              <button onClick={saveAdd} style={bookBtnPrimary} disabled={saving || !newDate}>
                {saving ? "Saving…" : "Save snapshot"}
              </button>
            </div>
          </div>
        </Card>
        <BucketEditor buckets={allBuckets} draft={draft} setDraft={setDraft} teamList={teamList} />
        {error && (
          <div style={{ marginTop:10, padding:"8px 12px", background:T.redLt, color:T.red, borderRadius:8, fontSize:12 }}>
            {error}
          </div>
        )}
      </div>
    );
  }

  return (
    <div>
      <Card style={{ marginBottom:12 }}>
        <div style={{ display:"flex", flexWrap:"wrap", gap:10, alignItems:"center", justifyContent:"space-between" }}>
          <div style={{ display:"flex", flexWrap:"wrap", alignItems:"center", gap:10 }}>
            <div style={{ fontSize:14, fontWeight:600, color:T.slate800 }}>Service Book Assignments</div>
            <select
              value={selectedDate || ""}
              onChange={e => setSelectedDate(e.target.value)}
              disabled={editing}
              style={bookInputStyle}
            >
              {allDates.map(d => <option key={d} value={d}>{d}</option>)}
            </select>
            <div style={{ fontSize:11, color:T.slate500 }}>
              {allDates.length} snapshot{allDates.length === 1 ? "" : "s"}{priorDate ? ` · prior: ${priorDate}` : " · no prior snapshot"}
            </div>
          </div>
          <div style={{ display:"flex", gap:8 }}>
            {!editing && <button onClick={startEdit} style={bookBtnSecondary}>Edit this snapshot</button>}
            {!editing && <button onClick={startAdd} style={bookBtnPrimary}>Add new snapshot</button>}
            {editing && <button onClick={cancelEdit} style={bookBtnSecondary} disabled={saving}>Cancel</button>}
            {editing && <button onClick={saveEdit} style={bookBtnPrimary} disabled={saving}>{saving ? "Saving…" : "Save"}</button>}
          </div>
        </div>
      </Card>

      <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fill, minmax(200px, 1fr))", gap:10, marginBottom:12 }}>
        {rollup.map((r, i) => {
          const m = memberById(r.team_member_id);
          const priorTotal = (priorRows || [])
            .filter(p => p.team_member_id === r.team_member_id)
            .reduce((s, p) => s + (Number(p.account_count) || 0), 0);
          const delta = priorDate ? r.total - priorTotal : null;
          return (
            <Card key={r.team_member_id || `na-${i}`} style={{ padding:"12px 14px" }}>
              <div style={{ fontSize:11, color:T.slate500 }}>{producerLabel(m)}</div>
              <div style={{ fontSize:22, fontWeight:700, color:T.slate900, lineHeight:1.1, marginTop:2 }}>
                {Number(r.total || 0).toLocaleString()}
              </div>
              <div style={{ fontSize:10, color:T.slate500, marginTop:2 }}>
                {r.letters.length} letter{r.letters.length === 1 ? "" : "s"} · {r.letters.join(", ")}
              </div>
              {delta !== null && (
                <div style={{ fontSize:11, color: delta > 0 ? T.green : delta < 0 ? T.red : T.slate500, marginTop:4 }}>
                  {delta > 0 ? "▲" : delta < 0 ? "▼" : "·"} {Math.abs(delta).toLocaleString()} vs {priorDate}
                </div>
              )}
            </Card>
          );
        })}
        <Card style={{ padding:"12px 14px", background:T.slate50 }}>
          <div style={{ fontSize:11, color:T.slate500 }}>Total accounts</div>
          <div style={{ fontSize:22, fontWeight:700, color:T.slate900, lineHeight:1.1, marginTop:2 }}>
            {Number(grandTotal || 0).toLocaleString()}
          </div>
          <div style={{ fontSize:10, color:T.slate500, marginTop:2 }}>{currentRows.length} buckets</div>
        </Card>
      </div>

      {editing ? (
        <BucketEditor buckets={allBuckets} draft={draft} setDraft={setDraft} teamList={teamList} />
      ) : (
        <Card>
          <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fill, minmax(140px, 1fr))", gap:8 }}>
            {allBuckets.map(b => {
              const r = findRow(currentRows, b);
              const m = memberById(r?.team_member_id);
              const p = findRow(priorRows, b);
              const delta = priorDate && p ? (Number(r?.account_count) || 0) - (Number(p.account_count) || 0) : null;
              return (
                <div key={b} style={{ border:`1px solid ${T.slate200}`, borderRadius:8, padding:"8px 10px", background:T.white }}>
                  <div style={{ display:"flex", justifyContent:"space-between", alignItems:"baseline" }}>
                    <div style={{ fontSize:13, fontWeight:700, color:T.slate900 }}>{b}</div>
                    <div style={{ fontSize:15, fontWeight:600, color:T.slate800 }}>
                      {Number(r?.account_count || 0).toLocaleString()}
                    </div>
                  </div>
                  <div style={{ fontSize:10, color: m ? T.slate600 : T.slate400, marginTop:2 }}>
                    {m ? producerLabel(m) : "Unassigned"}
                  </div>
                  {delta !== null && delta !== 0 && (
                    <div style={{ fontSize:9, color: delta > 0 ? T.green : T.red, marginTop:1 }}>
                      {delta > 0 ? "+" : ""}{delta} vs {priorDate}
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        </Card>
      )}

      {!editing && allDates.length > 0 && (
        <div style={{ marginTop:16, textAlign:"right" }}>
          <button onClick={deleteSnapshot} style={bookBtnDanger} disabled={saving}>Delete this snapshot</button>
        </div>
      )}

      {error && (
        <div style={{ marginTop:10, padding:"8px 12px", background:T.redLt, color:T.red, borderRadius:8, fontSize:12 }}>
          {error}
        </div>
      )}
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
  const [tab, setTab] = useState("size");

  const tabs = [
    { id: "size",        label: "Size" },
    { id: "goals",       label: "Goals" },
    { id: "assignments", label: "Assignments" },
  ];

  const subtitle =
    tab === "size"        ? "Agency-level book size and growth over time" :
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

      <TabBar tabs={tabs} active={tab} onChange={setTab} />

      {tab === "size" && <BookSizeSection />}
      {tab === "goals" && <BookGoalsSection />}
      {tab === "assignments" && <BookAssignmentsSection />}
    </div>
  );
}
