 import { useState, useEffect, useMemo } from "react";
import { supabase, AGENCY_ID } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";
import MarketingPoints from "./MarketingPoints.jsx";

// ============================================================
// Newtworks MARKETING MODULE v1.0
// Newtworks — State Farm Agent Edition
//
// Phase 1 tabs (built 2026-07-10):
//   Overview    — KPIs, envelope status, alerts
//   Sources     — Lead source table w/ CPA, close ratio, ROI
//   Spend       — GL marketing spend by month vs envelope
//   Points      — Team marketing points entry (nested MarketingPoints)
//
// Later phases will add:
//   EverQuote Deep Dive (Phase 2)
//   Referrals + Reviews consolidated (Phase 3)
//   Ideas Backlog kanban (Phase 4)
//
// DATA SOURCES:
//   lead_source_quarterly        Per-source snapshots (weekly + Q-close)
//   journal_lines + coa          Marketing spend (0003 MARKETING + descendants)
//   compute_weekly_marketing_bonus RPC → envelope + pool state
// ============================================================

// ─── Utility helpers ──────────────────────────────────────────
const fmtMoney = (n) => {
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  return `$${v.toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 0 })}`;
};
const fmtMoney2 = (n) => {
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  return `$${v.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
};
const fmtPct = (n, digits = 1) => {
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  return `${(v * 100).toFixed(digits)}%`;
};
const fmtInt = (n) => {
  const v = Number(n);
  if (!Number.isFinite(v)) return "—";
  return v.toLocaleString();
};

// Sunday-anchored week per calendar_conventions core principle.
// Returns Saturday of the current week (or the passed date's week) as YYYY-MM-DD.
function currentWeekSaturday(d = new Date()) {
  const day = d.getDay();               // 0=Sun ... 6=Sat
  const daysUntilSat = (6 - day + 7) % 7;
  const sat = new Date(d);
  sat.setDate(d.getDate() + daysUntilSat);
  return sat.toISOString().slice(0, 10);
}

// ─── Data hook ────────────────────────────────────────────────
function useMarketingData(year, quarter) {
  const [state, setState] = useState({ loading: true, data: null, error: null });

  useEffect(() => {
    let cancelled = false;
    async function load() {
      try {
        const weekEnd = currentWeekSaturday();

        // Time bounds for the selected quarter
        const qStartMonth = (quarter - 1) * 3;                            // 0,3,6,9
        const qStart = new Date(year, qStartMonth, 1).toISOString().slice(0, 10);
        const qEnd = new Date(year, qStartMonth + 3, 0).toISOString().slice(0, 10);
        const ytdStart = `${year}-01-01`;

        const [
          leadSourcesRes,
          spendRes,
          bonusRes,
          coaRes,
        ] = await Promise.all([
          // Lead source snapshots for the selected quarter
          supabase.from("lead_source_quarterly")
            .select("*")
            .eq("agency_id", AGENCY_ID)
            .eq("period_year", year)
            .eq("period_quarter", quarter)
            .order("snapshot_date", { ascending: false }),

          // GL marketing spend YTD by month + account
          supabase.from("journal_lines")
            .select(`
              debit, credit,
              journal_entries!inner(entry_date, agency_id),
              chart_of_accounts!inner(
                id, account_code, account_name, chart_namespace, parent_account_id
              )
            `)
            .eq("agency_id", AGENCY_ID)
            .gte("journal_entries.entry_date", ytdStart)
            .lte("journal_entries.entry_date", qEnd),

          // Marketing bonus pool state for current week
          supabase.rpc("compute_weekly_marketing_bonus", {
            p_agency_id: AGENCY_ID,
            p_week_end_date: weekEnd,
          }),

          // Chart of accounts — identify marketing accounts (0003 + descendants)
          supabase.from("chart_of_accounts")
            .select("id, account_code, account_name, parent_account_id, chart_namespace")
            .eq("agency_id", AGENCY_ID)
            .eq("is_active", true),
        ]);

        if (cancelled) return;

        // Compute marketing account id set (0003 MARKETING + descendants)
        const coaRows = Array.isArray(coaRes?.data) ? coaRes.data : [];
        const rootMarketing = coaRows.find(r => r?.account_name === "0003 MARKETING");
        const rootId = rootMarketing?.id || null;
        const marketingAcctIds = new Set(
          coaRows
            .filter(r => r?.id === rootId || r?.parent_account_id === rootId)
            .map(r => r.id)
        );

        // Filter GL lines to marketing accounts + compute month rollups
        const rawLines = Array.isArray(spendRes?.data) ? spendRes.data : [];
        const marketingLines = rawLines.filter(l => marketingAcctIds.has(l?.chart_of_accounts?.id));
        const byMonth = {};
        const byAccount = {};
        let ytdTotal = 0;
        marketingLines.forEach(l => {
          const dt = l?.journal_entries?.entry_date;
          if (!dt) return;
          const monthKey = dt.slice(0, 7); // YYYY-MM
          const amt = (Number(l.debit) || 0) - (Number(l.credit) || 0);
          byMonth[monthKey] = (byMonth[monthKey] || 0) + amt;
          const acctName = l?.chart_of_accounts?.account_name || "—";
          byAccount[acctName] = (byAccount[acctName] || 0) + amt;
          ytdTotal += amt;
        });

        // Lead sources — collapse to latest snapshot per (source, source_type)
        const rawSources = Array.isArray(leadSourcesRes?.data) ? leadSourcesRes.data : [];
        const latestBySource = {};
        rawSources.forEach(r => {
          const key = `${r.source}::${r.source_type || "lead_source"}`;
          const existing = latestBySource[key];
          if (!existing || (r.snapshot_date > existing.snapshot_date)) {
            latestBySource[key] = r;
          }
        });
        const sources = Object.values(latestBySource);

        setState({
          loading: false,
          error: null,
          data: {
            year,
            quarter,
            qStart,
            qEnd,
            weekEnd,
            sources,
            allSourceSnapshots: rawSources,
            spendByMonth: byMonth,
            spendByAccount: byAccount,
            spendYtd: ytdTotal,
            marketingAcctIds: Array.from(marketingAcctIds),
            bonus: bonusRes?.data || null,
          },
        });
      } catch (err) {
        if (!cancelled) setState({ loading: false, data: null, error: err?.message || String(err) });
      }
    }
    load();
    return () => { cancelled = true; };
  }, [year, quarter]);

  return state;
}

// ─── Reusable primitives ──────────────────────────────────────
function KpiCard({ label, value, sub, tone = "neutral" }) {
  const tones = {
    neutral: { bg: T.white, border: T.slate200, text: T.slate900 },
    good: { bg: T.greenLt, border: "#86EFAC", text: "#065F46" },
    warn: { bg: T.amberLt, border: "#FCD34D", text: "#92400E" },
    bad: { bg: T.redLt, border: "#FCA5A5", text: "#991B1B" },
  };
  const tk = tones[tone] || tones.neutral;
  return (
    <div style={{
      background: tk.bg, border: `1px solid ${tk.border}`, borderRadius: 10,
      padding: "12px 14px", minHeight: 80,
    }}>
      <div style={{ fontSize: 11, color: T.slate500, textTransform: "uppercase", letterSpacing: "0.05em", fontWeight: 600 }}>
        {label}
      </div>
      <div style={{ fontSize: 22, fontWeight: 700, color: tk.text, marginTop: 6, letterSpacing: "-0.02em" }}>
        {value}
      </div>
      {sub && (
        <div style={{ fontSize: 11, color: T.slate500, marginTop: 4, lineHeight: 1.4 }}>
          {sub}
        </div>
      )}
    </div>
  );
}

function SectionTitle({ children }) {
  return (
    <div style={{ fontSize: 13, fontWeight: 700, color: T.slate900, marginTop: 22, marginBottom: 10, letterSpacing: "-0.01em" }}>
      {children}
    </div>
  );
}

function AlertPill({ tone = "warn", children }) {
  const tones = {
    warn: { bg: T.amberLt, border: "#FCD34D", text: "#92400E" },
    bad: { bg: T.redLt, border: "#FCA5A5", text: "#991B1B" },
    info: { bg: T.blueLt, border: T.slate300, text: T.slate700 },
  };
  const tk = tones[tone] || tones.warn;
  return (
    <div style={{
      background: tk.bg, border: `1px solid ${tk.border}`, color: tk.text,
      borderRadius: 8, padding: "9px 12px", fontSize: 12, lineHeight: 1.5,
      display: "flex", gap: 8, alignItems: "flex-start",
    }}>
      <div style={{ fontWeight: 700, flexShrink: 0 }}>
        {tone === "bad" ? "⚠" : tone === "warn" ? "•" : "ⓘ"}
      </div>
      <div>{children}</div>
    </div>
  );
}

// ─── Overview Tab ─────────────────────────────────────────────
function OverviewTab({ state }) {
  const { data, loading, error } = state;
  const vp = useViewport();

  if (loading) return <div style={{ padding: 40, textAlign: "center", color: T.slate500, fontSize: 13 }}>Loading…</div>;
  if (error) return <div style={{ padding: 20, color: "#991B1B", fontSize: 13 }}>Error: {error}</div>;
  if (!data) return null;

  // Rollup metrics
  const sources = data.sources || [];
  const paidSources = sources.filter(s => s.source_type === "lead_source");
  const totalHHs = paidSources.reduce((sum, s) => sum + (Number(s.won_households) || 0), 0);
  const totalPremium = paidSources.reduce((sum, s) => sum + (Number(s.won_premium) || 0), 0);
  const totalCost = paidSources.reduce((sum, s) => sum + (Number(s.cost_total) || 0), 0);
  const blendedCpa = totalHHs > 0 && totalCost > 0 ? totalCost / totalHHs : null;
  const premPerDollar = totalCost > 0 ? totalPremium / totalCost : null;

  // Envelope status
  const bonus = data.bonus || {};
  const env = bonus?.envelope || {};
  const spend = bonus?.spend || {};
  const pool = bonus?.pool || {};
  const envAnnual = Number(env?.annual);
  const envYtdTarget = Number(env?.ytd_target);
  const envWeekly = Number(env?.weekly);
  const spendYtd = Number(spend?.ytd);
  const underspend = Number(pool?.underspend_ytd);
  const poolYtd = Number(pool?.pool_ytd);
  const overBy = Number.isFinite(spendYtd) && Number.isFinite(envYtdTarget) ? spendYtd - envYtdTarget : null;
  const envTone = overBy == null ? "neutral" : overBy > 0 ? "bad" : "good";

  // Dead-source alerts
  const deadSources = paidSources.filter(s => {
    const cost = Number(s.cost_total) || 0;
    const bound = Number(s.won_households) || 0;
    return cost > 0 && bound === 0;
  });

  // Low performers (paid channels binding less than 5% relative to cost target)
  const worstCpa = paidSources
    .filter(s => Number(s.cost_total) > 0 && Number(s.won_households) > 0)
    .map(s => ({ ...s, _cpa: Number(s.cost_total) / Number(s.won_households) }))
    .sort((a, b) => b._cpa - a._cpa)
    .slice(0, 1);

  const kpiCols = vp.isPhone ? "repeat(auto-fit, minmax(140px, 1fr))" : "repeat(auto-fit, minmax(160px, 1fr))";

  return (
    <div>
      <SectionTitle>Envelope + Pool — Week ending {data.weekEnd}</SectionTitle>
      <div style={{ display: "grid", gridTemplateColumns: kpiCols, gap: 10 }}>
        <KpiCard
          label="Envelope YTD"
          value={fmtMoney(envYtdTarget)}
          sub={`${fmtMoney(envAnnual)}/yr · ${fmtMoney(envWeekly)}/wk`}
        />
        <KpiCard
          label="Spend YTD"
          value={fmtMoney(spendYtd)}
          sub={overBy != null ? (overBy > 0 ? `Over by ${fmtMoney(overBy)}` : `Under by ${fmtMoney(-overBy)}`) : "—"}
          tone={envTone}
        />
        <KpiCard
          label="Underspend YTD"
          value={fmtMoney(underspend)}
          sub={underspend > 0 ? "Feeds team pool" : "No pool this week"}
          tone={underspend > 0 ? "good" : "neutral"}
        />
        <KpiCard
          label="Team Pool YTD"
          value={fmtMoney(poolYtd)}
          sub="50% of underspend"
          tone={poolYtd > 0 ? "good" : "neutral"}
        />
      </div>

      <SectionTitle>Q{data.quarter} {data.year} — Paid Channels</SectionTitle>
      <div style={{ display: "grid", gridTemplateColumns: kpiCols, gap: 10 }}>
        <KpiCard label="Households bound" value={fmtInt(totalHHs)} sub={`${paidSources.length} sources`} />
        <KpiCard label="Premium bound" value={fmtMoney(totalPremium)} sub={totalHHs > 0 ? `${fmtMoney(totalPremium / totalHHs)}/HH avg` : ""} />
        <KpiCard label="Cost" value={fmtMoney(totalCost)} sub={totalCost > 0 ? "Reported by SF CRM" : "Cost not yet reported"} />
        <KpiCard
          label="Blended CPA"
          value={blendedCpa != null ? fmtMoney(blendedCpa) : "—"}
          sub={premPerDollar != null ? `${premPerDollar.toFixed(1)}x premium/$` : ""}
        />
      </div>

      <SectionTitle>Alerts</SectionTitle>
      <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
        {overBy != null && overBy > 0 && (
          <AlertPill tone="bad">
            Marketing spend is <strong>{fmtMoney(overBy)}</strong> over the YTD envelope. Team pool sits at $0 until spend drops below <strong>{fmtMoney(envWeekly)}/wk</strong> average.
          </AlertPill>
        )}
        {deadSources.map(s => (
          <AlertPill key={`dead-${s.id}`} tone="bad">
            <strong>{s.source}</strong> — {fmtMoney2(s.cost_total)} spent Q{data.quarter}, 0 households bound. Candidate to cut.
          </AlertPill>
        ))}
        {worstCpa.map(s => (
          <AlertPill key={`cpa-${s.id}`} tone="warn">
            Highest CPA this quarter: <strong>{s.source}</strong> at <strong>{fmtMoney(s._cpa)}/HH</strong> ({s.won_households} bound / {fmtMoney(s.cost_total)}).
          </AlertPill>
        ))}
        {overBy == null && deadSources.length === 0 && worstCpa.length === 0 && (
          <div style={{ fontSize: 12, color: T.slate500, padding: "8px 4px" }}>
            No alerts this cycle.
          </div>
        )}
      </div>

      <SectionTitle>Team Pool Preview — {bonus?.week_end_date || data.weekEnd}</SectionTitle>
      <div style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 10, padding: 12, fontSize: 12 }}>
        {Array.isArray(bonus?.people) && bonus.people.length > 0 ? (
          <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch" }}>
            <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 12 }}>
              <thead>
                <tr style={{ borderBottom: `1px solid ${T.slate200}`, textAlign: "left" }}>
                  <th style={{ padding: "6px 4px", color: T.slate500, fontWeight: 600 }}>Teammate</th>
                  <th style={{ padding: "6px 4px", color: T.slate500, fontWeight: 600, textAlign: "right" }}>Points YTD</th>
                  <th style={{ padding: "6px 4px", color: T.slate500, fontWeight: 600, textAlign: "right" }}>Share</th>
                  <th style={{ padding: "6px 4px", color: T.slate500, fontWeight: 600, textAlign: "right" }}>Earned YTD</th>
                </tr>
              </thead>
              <tbody>
                {(bonus.people || []).map(p => (
                  <tr key={p.team_member_id} style={{ borderBottom: `1px solid ${T.slate100}` }}>
                    <td style={{ padding: "6px 4px" }}>{p.name}</td>
                    <td style={{ padding: "6px 4px", textAlign: "right" }}>{fmtInt(p.points_ytd)}</td>
                    <td style={{ padding: "6px 4px", textAlign: "right" }}>{fmtPct(p.share_pct)}</td>
                    <td style={{ padding: "6px 4px", textAlign: "right" }}>{fmtMoney2(p.earned_ytd)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <div style={{ color: T.slate500 }}>Pool empty — no marketing points logged yet.</div>
        )}
      </div>
    </div>
  );
}

// ─── Lead Sources Tab ─────────────────────────────────────────
function SourcesTab({ state }) {
  const { data, loading, error } = state;
  const vp = useViewport();
  const [showType, setShowType] = useState("all"); // all | paid | opportunity

  if (loading) return <div style={{ padding: 40, textAlign: "center", color: T.slate500, fontSize: 13 }}>Loading…</div>;
  if (error) return <div style={{ padding: 20, color: "#991B1B", fontSize: 13 }}>Error: {error}</div>;
  if (!data) return null;

  const sources = data.sources || [];
  const filtered = sources.filter(s => {
    if (showType === "all") return true;
    if (showType === "paid") return s.source_type === "lead_source";
    if (showType === "opportunity") return s.source_type === "opportunity_type";
    return true;
  });

  // Sort paid by binds desc, then by cost desc
  const sorted = [...filtered].sort((a, b) => {
    const bindsA = Number(a.won_households) || 0;
    const bindsB = Number(b.won_households) || 0;
    if (bindsB !== bindsA) return bindsB - bindsA;
    return (Number(b.cost_total) || 0) - (Number(a.cost_total) || 0);
  });

  return (
    <div>
      <SectionTitle>Q{data.quarter} {data.year} — Lead source performance</SectionTitle>
      <div style={{ fontSize: 12, color: T.slate500, marginBottom: 10 }}>
        Latest snapshot per source. Weekly refresh from SF CRM Analytics + quarterly CPR sheet.
      </div>

      {/* Filter chips */}
      <div style={{
        display: "flex", gap: 6, marginBottom: 12,
        overflowX: "auto", WebkitOverflowScrolling: "touch", whiteSpace: "nowrap",
      }}>
        {[
          { id: "all", label: "All" },
          { id: "paid", label: "Paid + Free Channels" },
          { id: "opportunity", label: "Opportunity Types" },
        ].map(f => (
          <button
            key={f.id}
            onClick={() => setShowType(f.id)}
            style={{
              padding: "6px 12px", fontSize: 12, fontWeight: showType === f.id ? 600 : 400,
              color: showType === f.id ? T.white : T.slate700,
              background: showType === f.id ? T.chromeBgDeep : T.white,
              border: `1px solid ${showType === f.id ? T.chromeBgDeep : T.slate200}`,
              borderRadius: 7, cursor: "pointer", flexShrink: 0,
            }}
          >{f.label}</button>
        ))}
      </div>

      <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch", border: `1px solid ${T.slate200}`, borderRadius: 10, background: T.white }}>
        <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 12, minWidth: 720 }}>
          <thead>
            <tr style={{ background: T.slate50, borderBottom: `1px solid ${T.slate200}` }}>
              <th style={thStyle}>Source</th>
              <th style={thStyle}>Type</th>
              <th style={{ ...thStyle, textAlign: "right" }}>HHs Bound</th>
              <th style={{ ...thStyle, textAlign: "right" }}>Premium</th>
              <th style={{ ...thStyle, textAlign: "right" }}>Prem/HH</th>
              <th style={{ ...thStyle, textAlign: "right" }}>Cost</th>
              <th style={{ ...thStyle, textAlign: "right" }}>CPA</th>
              <th style={{ ...thStyle, textAlign: "right" }}>Prem/$</th>
              <th style={{ ...thStyle, textAlign: "right" }}>Close</th>
              <th style={{ ...thStyle, textAlign: "right" }}>As Of</th>
            </tr>
          </thead>
          <tbody>
            {sorted.length === 0 && (
              <tr><td colSpan={10} style={{ padding: 20, textAlign: "center", color: T.slate500 }}>No snapshots for this filter.</td></tr>
            )}
            {sorted.map(s => {
              const hhs = Number(s.won_households) || 0;
              const prem = Number(s.won_premium) || 0;
              const cost = Number(s.cost_total) || 0;
              const cpa = cost > 0 && hhs > 0 ? cost / hhs : null;
              const premPerDollar = cost > 0 ? prem / cost : null;
              const closeRatio = s.close_ratio != null ? Number(s.close_ratio) : null;
              const premPerHH = hhs > 0 ? prem / hhs : null;
              const isDead = cost > 0 && hhs === 0;
              return (
                <tr key={s.id} style={{ borderBottom: `1px solid ${T.slate100}` }}>
                  <td style={{ ...tdStyle, fontWeight: 600, color: isDead ? "#991B1B" : T.slate900 }}>
                    {s.source}
                    {isDead && <span style={{ marginLeft: 6, fontSize: 10, background: T.redLt, color: "#991B1B", padding: "1px 6px", borderRadius: 4 }}>DEAD</span>}
                  </td>
                  <td style={{ ...tdStyle, color: T.slate500, fontSize: 11 }}>
                    {s.source_type === "lead_source" ? "Lead source" : s.source_type === "opportunity_type" ? "Opp type" : (s.source_type || "—")}
                  </td>
                  <td style={{ ...tdStyle, textAlign: "right" }}>{hhs > 0 ? fmtInt(hhs) : (s.won_households == null ? "—" : "0")}</td>
                  <td style={{ ...tdStyle, textAlign: "right" }}>{prem > 0 ? fmtMoney(prem) : "—"}</td>
                  <td style={{ ...tdStyle, textAlign: "right" }}>{premPerHH != null ? fmtMoney(premPerHH) : "—"}</td>
                  <td style={{ ...tdStyle, textAlign: "right" }}>{cost > 0 ? fmtMoney(cost) : "—"}</td>
                  <td style={{ ...tdStyle, textAlign: "right", fontWeight: cpa != null ? 600 : 400 }}>{cpa != null ? fmtMoney(cpa) : "—"}</td>
                  <td style={{ ...tdStyle, textAlign: "right" }}>{premPerDollar != null ? `${premPerDollar.toFixed(1)}x` : "—"}</td>
                  <td style={{ ...tdStyle, textAlign: "right" }}>{closeRatio != null ? fmtPct(closeRatio) : "—"}</td>
                  <td style={{ ...tdStyle, textAlign: "right", color: T.slate500, fontSize: 11 }}>{s.snapshot_date || "—"}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      <div style={{ marginTop: 14, fontSize: 11, color: T.slate500, lineHeight: 1.6 }}>
        <strong>CPA</strong> = cost ÷ HHs bound. <strong>Prem/$</strong> = premium bound ÷ cost. <strong>Close</strong> = SF CRM close ratio. Sources without cost reported show "—".
      </div>
    </div>
  );
}

const thStyle = { padding: "8px 10px", textAlign: "left", color: T.slate500, fontWeight: 600, fontSize: 11, textTransform: "uppercase", letterSpacing: "0.03em" };
const tdStyle = { padding: "8px 10px", color: T.slate700 };

// ─── Spend Tab ────────────────────────────────────────────────
function SpendTab({ state }) {
  const { data, loading, error } = state;
  const vp = useViewport();
  if (loading) return <div style={{ padding: 40, textAlign: "center", color: T.slate500, fontSize: 13 }}>Loading…</div>;
  if (error) return <div style={{ padding: 20, color: "#991B1B", fontSize: 13 }}>Error: {error}</div>;
  if (!data) return null;

  const byMonth = data.spendByMonth || {};
  const byAccount = data.spendByAccount || {};
  const spendYtd = Number(data.spendYtd) || 0;
  const bonus = data.bonus || {};
  const env = bonus?.envelope || {};
  const envAnnual = Number(env?.annual);
  const envWeekly = Number(env?.weekly);
  const envYtdTarget = Number(env?.ytd_target);

  // Sort months ascending
  const months = Object.keys(byMonth).sort();
  const maxMonth = Math.max(1, ...months.map(m => Math.abs(byMonth[m])));
  const monthlyAvg = months.length > 0 ? spendYtd / months.length : 0;

  // Account rollup — sort by absolute descending
  const accountRows = Object.entries(byAccount)
    .map(([name, amt]) => ({ name, amt }))
    .sort((a, b) => Math.abs(b.amt) - Math.abs(a.amt));

  const kpiCols = vp.isPhone ? "repeat(auto-fit, minmax(140px, 1fr))" : "repeat(auto-fit, minmax(160px, 1fr))";

  return (
    <div>
      <SectionTitle>YTD Marketing Spend</SectionTitle>
      <div style={{ display: "grid", gridTemplateColumns: kpiCols, gap: 10 }}>
        <KpiCard label="YTD Spend" value={fmtMoney(spendYtd)} sub={`${months.length} months`} />
        <KpiCard label="YTD Envelope Target" value={fmtMoney(envYtdTarget)} sub={`${fmtMoney(envAnnual)} annual`} />
        <KpiCard label="Monthly Avg" value={fmtMoney(monthlyAvg)} sub={`vs ${fmtMoney(envWeekly * 4.33)} envelope/mo`} />
        <KpiCard label="Weekly Envelope" value={fmtMoney(envWeekly)} sub="Envelope 10% × (basis − Scorecard)" />
      </div>

      <SectionTitle>Monthly spend — 0003 MARKETING + descendants</SectionTitle>
      <div style={{ background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 10, padding: 14 }}>
        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          {months.length === 0 && (
            <div style={{ color: T.slate500, fontSize: 12, padding: 8 }}>No GL entries this year.</div>
          )}
          {months.map(m => {
            const amt = byMonth[m];
            const w = Math.max(2, (Math.abs(amt) / maxMonth) * 100);
            const label = new Date(`${m}-01`).toLocaleString(undefined, { month: "short", year: "numeric" });
            return (
              <div key={m} style={{ display: "grid", gridTemplateColumns: vp.isPhone ? "64px 1fr 84px" : "80px 1fr 100px", gap: 8, alignItems: "center" }}>
                <div style={{ fontSize: 12, color: T.slate700, fontWeight: 600 }}>{label}</div>
                <div style={{ height: 22, background: T.slate50, borderRadius: 5, position: "relative", overflow: "hidden" }}>
                  <div style={{
                    position: "absolute", left: 0, top: 0, bottom: 0,
                    width: `${w}%`,
                    background: amt < 0 ? T.green : (amt > envWeekly * 4.5 ? T.red : T.chromeBg),
                    borderRadius: 5,
                    transition: "width 0.2s",
                  }} />
                </div>
                <div style={{ fontSize: 12, color: T.slate900, fontWeight: 600, textAlign: "right" }}>{fmtMoney(amt)}</div>
              </div>
            );
          })}
        </div>
      </div>

      <SectionTitle>Spend by account</SectionTitle>
      <div style={{ overflowX: "auto", WebkitOverflowScrolling: "touch", background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 10 }}>
        <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 12, minWidth: 400 }}>
          <thead>
            <tr style={{ background: T.slate50, borderBottom: `1px solid ${T.slate200}` }}>
              <th style={thStyle}>Account</th>
              <th style={{ ...thStyle, textAlign: "right" }}>YTD Amount</th>
              <th style={{ ...thStyle, textAlign: "right" }}>% of Total</th>
            </tr>
          </thead>
          <tbody>
            {accountRows.length === 0 && (
              <tr><td colSpan={3} style={{ padding: 20, textAlign: "center", color: T.slate500 }}>No entries.</td></tr>
            )}
            {accountRows.map(r => (
              <tr key={r.name} style={{ borderBottom: `1px solid ${T.slate100}` }}>
                <td style={tdStyle}>{r.name}</td>
                <td style={{ ...tdStyle, textAlign: "right", fontWeight: 600 }}>{fmtMoney(r.amt)}</td>
                <td style={{ ...tdStyle, textAlign: "right", color: T.slate500 }}>
                  {spendYtd !== 0 ? `${((Math.abs(r.amt) / Math.abs(spendYtd)) * 100).toFixed(0)}%` : "—"}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div style={{ marginTop: 14, fontSize: 11, color: T.slate500, lineHeight: 1.6 }}>
        Source: <strong>0003 MARKETING</strong> account + descendants in the historical chart namespace. Same definition the Marketing Bonus Pool uses. Debits net of credits (refunds show as negative bars in green).
      </div>
    </div>
  );
}

// ─── Points Tab (nests existing MarketingPoints module) ───────
function PointsTab() {
  return <MarketingPoints />;
}

// ─── Main Marketing Module ────────────────────────────────────
const SECTIONS = [
  { id: "overview", label: "Overview" },
  { id: "sources", label: "Lead Sources" },
  { id: "spend", label: "Spend" },
  { id: "points", label: "Points" },
];

export default function Marketing() {
  const vp = useViewport();
  const _pad = vp.isPhone ? "12px" : vp.isTablet ? "16px 18px" : "20px 24px";
  const now = new Date();
  const [year, setYear] = useState(now.getFullYear());
  const [quarter, setQuarter] = useState(Math.floor(now.getMonth() / 3) + 1);
  const [section, setSection] = useState("overview");
  const state = useMarketingData(year, quarter);

  // Year/quarter selector options
  const yearOpts = [now.getFullYear() - 1, now.getFullYear()];
  const qOpts = [1, 2, 3, 4];

  return (
    <div style={{ padding: _pad }}>
      {/* Module Header */}
      <div style={{ display: "flex", alignItems: "flex-start", justifyContent: "space-between", marginBottom: 16, flexWrap: "wrap", gap: 10 }}>
        <div>
          <div style={{ fontSize: 20, fontWeight: 700, color: T.slate900, letterSpacing: "-0.02em" }}>Marketing</div>
          <div style={{ fontSize: 12, color: T.slate500, marginTop: 3 }}>
            Envelope · Lead sources · Spend · Team points
          </div>
        </div>

        {(section === "overview" || section === "sources") && (
          <div style={{ display: "flex", gap: 6, alignItems: "center", flexWrap: "wrap" }}>
            <select
              value={quarter}
              onChange={e => setQuarter(Number(e.target.value))}
              style={{
                padding: "6px 10px", fontSize: 12, fontWeight: 600, color: T.slate700,
                background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 7, cursor: "pointer",
              }}
            >
              {qOpts.map(q => <option key={q} value={q}>Q{q}</option>)}
            </select>
            <select
              value={year}
              onChange={e => setYear(Number(e.target.value))}
              style={{
                padding: "6px 10px", fontSize: 12, fontWeight: 600, color: T.slate700,
                background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 7, cursor: "pointer",
              }}
            >
              {yearOpts.map(y => <option key={y} value={y}>{y}</option>)}
            </select>
          </div>
        )}
      </div>

      {/* Section Nav — scrollable on phone */}
      <div style={{
        display: "flex", gap: 4, background: T.slate100, borderRadius: 10,
        padding: 4, marginBottom: 18,
        overflowX: "auto", WebkitOverflowScrolling: "touch", whiteSpace: "nowrap",
      }}>
        {SECTIONS.map(s => (
          <button
            key={s.id}
            onClick={() => setSection(s.id)}
            style={{
              padding: "7px 14px", fontSize: 12,
              fontWeight: section === s.id ? 600 : 400,
              color: section === s.id ? T.slate900 : T.slate500,
              background: section === s.id ? T.white : "transparent",
              border: "none", borderRadius: 7, cursor: "pointer",
              flexShrink: 0,
              boxShadow: section === s.id ? "0 1px 3px rgba(0,0,0,0.08)" : "none",
              transition: "all 0.12s",
            }}
          >{s.label}</button>
        ))}
      </div>

      {section === "overview" && <OverviewTab state={state} />}
      {section === "sources" && <SourcesTab state={state} />}
      {section === "spend" && <SpendTab state={state} />}
      {section === "points" && <PointsTab />}
    </div>
  );
}
